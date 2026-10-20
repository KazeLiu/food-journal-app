import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/core/data.dart';
import 'package:food_journal/data_management/backup_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../support/test_store.dart';

class _Paths extends PathProviderPlatform {
  final String cache;
  _Paths(this.cache);
  @override
  Future<String> getTemporaryPath() async => cache;
}

class _Backup extends BackupService {
  final File safety;
  _Backup(TestStore store, this.safety)
      : super(store.records, store.services.settings, store.services.chat,
            store.services.images);
  @override
  Future<File> get safetyFile async => safety;
}

Json _copy(Json value) => jsonMap(jsonEncode(value));

void main() {
  late TestStore store;
  late _Backup backup;
  late PathProviderPlatform previousPaths;
  late Directory cache;
  late Directory exports;
  File? picked;
  const channel = MethodChannel('flutter_file_dialog');
  setUp(() async {
    store = await TestStore.create();
    previousPaths = PathProviderPlatform.instance;
    cache = await Directory(p.join(store.directory.path, 'cache')).create();
    exports = await Directory(p.join(store.directory.path, 'exports')).create();
    PathProviderPlatform.instance = _Paths(cache.path);
    backup = _Backup(
        store, File(p.join(store.directory.path, 'before-restore.json')));
    picked = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'saveFile') {
        final args = call.arguments as Map;
        return (await File(args['sourceFilePath'])
                .copy(p.join(exports.path, args['fileName'])))
            .path;
      }
      if (call.method == 'pickFile') {
        return picked == null
            ? null
            : (await picked!.copy(p.join(cache.path, '${newId()}.json'))).path;
      }
      throw StateError('未预期的文件选择器调用 ${call.method}');
    });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    PathProviderPlatform.instance = previousPaths;
    await store.close();
  });

  test('生产快照可完整校验，排除接口、Key、草稿、附件与自动重放载荷', () async {
    await store.services.committer.local(mealInput());
    await store.services.settings
        .set('ai_profile', {'base_url': 'https://example.invalid/v1'});
    await store.services.settings.set('chat_draft', {'text': '私人草稿'});
    await store.services.settings.set('weight_unit', 'kg');
    final op = await store.records
        .enqueue('尚未完成', [], {'manual_action_id': 'input'}, null, null);
    await store.db.update('operations', {'context_json': '{}'},
        where: 'id=?', whereArgs: [op['id']]);
    await store.services.committer.savePlan(op['id'], [
      {...weightInput(), 'action_key': 'pending-weight', 'state': 'ready'}
    ]);
    final data = await backup.snapshot();
    await backup.validate(data);
    expect(data['preferences'], {'weight_unit': 'kg'});
    expect(data.containsKey('chat_attachments'), isFalse);
    expect((data['operations'] as List).every((o) => o['plan_json'] == null),
        isTrue);
    expect(
        (data['operation_actions'] as List)
            .every((a) => a['payload_json'] == null),
        isTrue);
    final pending = (data['operation_actions'] as List)
        .singleWhere((a) => a['action_key'] == 'pending-weight');
    expect(pending['status'], 'failed');
    expect(jsonMap(pending['result_json'])['needs_replan'], isTrue);
  });

  test('日期上下文与引用范围完整备份恢复，非法日期或类型在导入前拒绝', () async {
    final root = await store.records.enqueue('昨天的情况', [],
        {'local_date': '2026-10-19', 'label': '记录或查询 2026-10-19'}, null, null);
    final quote =
        (await store.records.messagesAround(root['message_id'])).single;
    await store.services.chat.send('那午餐呢', [], {}, quote, null);
    final data = await backup.snapshot();
    expect(
        (data['chat_messages'] as List)
            .every((m) => !(m as Map).containsKey('sent_context_json')),
        isTrue);
    await backup.restore(data);
    final message = (await store.records.messages())
        .singleWhere((m) => m['body_text'] == '那午餐呢');
    expect(jsonMap(message['sent_context_json'])['local_date'], '2026-10-19');
    expect(jsonMap(message['quote_snapshot_json'])['context']['local_date'],
        '2026-10-19');
    final invalid = _copy(await backup.snapshot());
    final row = (invalid['chat_messages'] as List)
        .singleWhere((m) => m['quote_snapshot_json'] != null);
    final snapshot = jsonMap(row['quote_snapshot_json']);
    snapshot['context']['local_date'] = 'not-a-date';
    row['quote_snapshot_json'] = jsonEncode(snapshot);
    await expectLater(backup.validate(invalid), throwsA(isA<AppError>()));
    final invalidContext = _copy(await backup.snapshot());
    (invalidContext['operations'] as List).first['context_json'] =
        jsonEncode({'label': 123});
    await expectLater(
        backup.validate(invalidContext), throwsA(isA<AppError>()));
  });

  test('已有字符串依据可备份恢复，不能让详情修复后仍被恢复校验拒绝', () async {
    final first = await store.services.committer.local(mealInput());
    final id = receiptId(first, 'food_items');
    await store.db.update(
        'food_items',
        {
          'nutrition_basis_json': jsonEncode(
              {for (final field in nutritionFields) field: '旧记录的说明文字'})
        },
        where: 'id=?',
        whereArgs: [id]);
    final data = await backup.snapshot();
    await backup.validate(data);
    await backup.restore(data);
    expect(
        jsonMap((await store.records
            .row('food_items', id))!['nutrition_basis_json'])['protein_g'],
        '旧记录的说明文字');
  });

  test('上午下午记录与撤销快照可备份恢复，时段不能携带伪造的精确时间戳', () async {
    await store.services.committer.local({...mealInput(), 'local_time': '下午'});
    final weight = await store.services.committer
        .local({...weightInput(), 'local_time': '上午'});
    final id = receiptId(weight, 'weight_records');
    final changed = await store.services.committer.local({
      'type': 'update_weight',
      'id': id,
      'expected_version': 1,
      'patch': {'local_time': '09:15'}
    });
    await backup.restore(await backup.snapshot());
    await store.services.committer
        .local({'type': 'undo_action', 'action_id': changed['action_id']});
    final row = (await store.records.row('weight_records', id))!;
    expect(row['local_time'], '上午');
    expect(row['occurred_at_ms'], isNull);
    expect(row['utc_offset_minutes'], isNull);
    expect(
        (await store.records.meals('2026-10-20')).single['local_time'], '下午');
    final invalid = _copy(await backup.snapshot());
    (invalid['meals'] as List).single['occurred_at_ms'] = 1;
    await expectLater(backup.validate(invalid), throwsA(isA<AppError>()));
    final badReference = _copy(await backup.snapshot());
    final operation = (badReference['operations'] as List).first;
    final reference = jsonMap(operation['reference_time_json']);
    operation['reference_time_json'] =
        jsonEncode({...reference, 'local_time': '下午'});
    await expectLater(backup.validate(badReference), throwsA(isA<AppError>()));
  });

  test('schema 3 保留思考与回复，schema 1和2备份均可恢复且不备份图片', () async {
    final op = await store.records.enqueue('早餐图片', [], {}, null, null);
    await store.records.assistant(op['id'], '原始自然回复', 'running',
        modelReply: true, reasoningText: '接口返回的测试思考摘要');
    await store.records.assistant(op['id'], '已记录早餐', 'completed');
    await store.services.images.fileFor('preview.jpg').writeAsBytes([1, 2, 3]);
    await store.db.insert('chat_attachments', {
      'id': 'preview',
      'message_id': op['message_id'],
      'relative_path': 'preview.jpg',
      'mime_type': 'image/jpeg',
      'byte_length': 3,
      'state': 'pending',
      'created_at_ms': 1
    });
    final current = await backup.snapshot();
    expect(current['database_schema_version'], 3);
    expect(current.containsKey('chat_attachments'), isFalse);
    await backup.restore(current);
    var message = (await store.records.messages(keyword: '原始自然回复')).single;
    expect(message['model_reply_text'], '原始自然回复');
    expect(message['receipt_text'], '已记录早餐');
    expect(message['reasoning_text'], '接口返回的测试思考摘要');
    expect(
        await store.services.images.fileFor('preview.jpg').exists(), isFalse);
    final second = _copy(current)..['database_schema_version'] = 2;
    for (final row in second['chat_messages'] as List) {
      row.remove('reasoning_text');
    }
    await backup.restore(second);
    message = (await store.records.messages(keyword: '原始自然回复')).single;
    expect(message['reasoning_text'], isNull);
    expect(message['model_reply_text'], '原始自然回复');
    final legacy = _copy(current)..['database_schema_version'] = 1;
    for (final message in legacy['chat_messages'] as List) {
      message.remove('model_reply_text');
      message.remove('receipt_text');
      message.remove('reasoning_text');
    }
    await backup.restore(legacy);
    message = (await store.records.messages(keyword: '原始自然回复')).single;
    expect(message['body_text'], '原始自然回复\n\n已记录早餐');
    expect(message['model_reply_text'], isNull);
    expect(message['reasoning_text'], isNull);
    expect(await store.db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

  test('有效备份整库替换、保留当前 AI 配置与 Key，并先保留可恢复安全副本', () async {
    final first = await store.services.committer.local(mealInput());
    final data = await backup.snapshot();
    await store.services.committer.local(weightInput());
    await store.services.settings
        .set('ai_profile', {'base_url': 'https://current.invalid/v1'});
    FlutterSecureStorage.setMockInitialValues({'ai_credential': '仅测试凭据'});
    final epoch = store.services.chat.dataEpoch;
    await backup.restore(data);
    expect(await store.records.weights(), isEmpty);
    expect((await store.services.settings.get('ai_profile'))['base_url'],
        'https://current.invalid/v1');
    expect(await store.services.settings.secure.read(key: 'ai_credential'),
        '仅测试凭据');
    expect(store.services.chat.dataEpoch, greaterThan(epoch));
    final safety = await backup.readSafety();
    expect(safety['weight_records'], hasLength(1));
    await store.services.committer
        .local({'type': 'undo_action', 'action_id': first['action_id']});
    expect(await store.records.meals('2026-10-20'), isEmpty);
    await backup.restore(safety, fromSafety: true);
    expect(await store.records.weights(), hasLength(1));
    expect(await store.records.meals('2026-10-20'), hasLength(1));
  });

  test('高版本、断引用、重复 ID、非法日期和营养结构在替换当前库前拒绝', () async {
    await store.services.committer.local(mealInput());
    final baseline = await backup.snapshot();
    final invalid = <Json>[];
    invalid.add(_copy(baseline)..['database_schema_version'] = 99);
    final missing = _copy(baseline);
    (missing['food_items'] as List).single['meal_id'] = 'missing-meal';
    invalid.add(missing);
    final duplicate = _copy(baseline);
    (duplicate['meals'] as List)
        .add(Map.of((duplicate['meals'] as List).single));
    invalid.add(duplicate);
    final date = _copy(baseline);
    (date['meals'] as List).single['local_date'] = '2026-02-30';
    invalid.add(date);
    final basis = _copy(baseline);
    (basis['food_items'] as List).single['nutrition_basis_json'] = jsonEncode({
      'calories_kcal': [1],
      'protein_g': null,
      'fat_g': null,
      'carbs_g': null
    });
    invalid.add(basis);
    for (final data in invalid) {
      await expectLater(backup.restore(data), throwsA(isA<AppError>()));
      expect((await backup.snapshot())['meals'], baseline['meals']);
      expect(await backup.safety.exists(), isFalse);
    }
  });

  test('安全副本无法写入时停止替换，原数据完整保留', () async {
    final empty = await backup.snapshot();
    await store.services.committer.local(mealInput());
    final failing = _Backup(store,
        File(p.join(store.directory.path, 'missing-parent', 'before.json')));
    await expectLater(
        failing.restore(empty), throwsA(isA<FileSystemException>()));
    expect(await store.records.meals('2026-10-20'), hasLength(1));
  });

  test('实际插入失败时替换事务回滚，安全副本仍可读取', () async {
    await store.services.committer.local(mealInput());
    final incoming = await backup.snapshot();
    (incoming['meals'] as List).single['raw_description'] = '触发受控失败';
    await store.db.execute(
        "CREATE TRIGGER fail_restore BEFORE INSERT ON meals WHEN NEW.raw_description='触发受控失败' BEGIN SELECT RAISE(ABORT,'controlled failure'); END");
    await expectLater(backup.restore(incoming), throwsException);
    expect((await store.records.meals('2026-10-20')).single['raw_description'],
        '测试早餐');
    expect((await backup.readSafety())['meals'], hasLength(1));
  });

  test('CSV 有 BOM、公式保护和引号换行转义，未知营养保留空字段', () async {
    await store.services.committer.local(mealInput(items: [
      {
        ...foodInput(name: '=1+1', calories: 0, protein: null, fat: 0),
        'note': '逗号,引号"和换行\n保留'
      }
    ]));
    final path = (await backup.exportCsv(false))!;
    final bytes = await File(path).readAsBytes();
    expect(bytes.take(3), [0xef, 0xbb, 0xbf]);
    final csv = utf8.decode(bytes.skip(3).toList());
    expect(csv, contains("\"'=1+1\""));
    expect(csv, contains(',"一份",0,,0.0,20.0,'));
    expect(csv, contains('"逗号,引号""和换行\n保留"'));
    expect(await cache.list().toList(), isEmpty);
  });

  test('真实加密导出可解密；错误密码或篡改被拒绝，不改当前库', () async {
    await store.services.committer.local(mealInput());
    final path = (await backup.exportBackup('test-password'))!;
    picked = File(path);
    final envelope = jsonMap(await picked!.readAsString());
    expect(envelope['kdf']['iterations'], 600000);
    expect(envelope.containsKey('meals'), isFalse);
    expect((await backup.pickBackup('test-password'))!['meals'], hasLength(1));
    await expectLater(
        backup.pickBackup('wrong-password'), throwsA(isA<AppError>()));
    final tag = base64Decode(envelope['tag_base64']);
    tag[0] ^= 1;
    envelope['tag_base64'] = base64Encode(tag);
    await picked!.writeAsString(jsonEncode(envelope));
    await expectLater(
        backup.pickBackup('test-password'), throwsA(isA<AppError>()));
    expect(await store.records.meals('2026-10-20'), hasLength(1));
    expect(await cache.list().toList(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('取消文件选择无副作用，清除只处理内部数据与凭据，不删导出的外部文件', () async {
    expect(await backup.pickBackup(''), isNull);
    await store.services.committer.local(mealInput());
    final external = File((await backup.exportBackup(''))!);
    FlutterSecureStorage.setMockInitialValues({'ai_credential': '测试凭据'});
    await backup.safety.writeAsString(jsonEncode(await backup.snapshot()));
    await store.services.images.fileFor('preview.jpg').writeAsBytes([1, 2, 3]);
    expect(await backup.clearAll(), isEmpty);
    expect(
        await store.services.images.fileFor('preview.jpg').exists(), isFalse);
    expect(await store.records.meals('2026-10-20'), isEmpty);
    expect(await store.services.settings.secure.read(key: 'ai_credential'),
        isNull);
    expect(await backup.safety.exists(), isFalse);
    expect(await external.exists(), isTrue);
  });
}
