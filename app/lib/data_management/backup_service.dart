import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../chat/chat_coordinator.dart';
import '../core/data.dart';
import '../core/database.dart';
import '../core/image_service.dart';
import '../records/record_repository.dart';
import '../settings/settings_repository.dart';

class BackupService {
  static const maxBytes = 100 * 1024 * 1024;
  static const preferenceKeys = [
    'weight_unit',
    'theme_mode',
    'onboarding_completed'
  ];
  final RecordRepository records;
  final SettingsRepository settings;
  final ChatCoordinator chat;
  final ImageService images;
  BackupService(this.records, this.settings, this.chat, this.images);

  Future<File> get safetyFile async => File(p.join(
      (await getApplicationSupportDirectory()).path, 'before-restore.json'));

  Future<Json> snapshot() => records.db.transaction((tx) async {
        final data = <String, dynamic>{
          'format': 'food-journal-backup',
          'format_version': 1,
          'database_schema_version': AppDatabase.schemaVersion,
          'exported_at': DateTime.now().toUtc().toIso8601String(),
          'preferences': <String, dynamic>{}
        };
        for (final table in AppDatabase.businessTables) {
          final rows = (await tx.query(table))
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          if (table == 'operations') {
            for (final row in rows) {
              row['plan_json'] = null;
              if (!['completed', 'cancelled'].contains(row['status'])) {
                row['status'] = 'interrupted';
              }
              final context = jsonMap(row['context_json'] as String);
              context.remove('attachments');
              context.remove('image_paths');
              context.remove('manual_action_id');
              row['context_json'] = jsonEncode(context);
            }
          }
          if (table == 'operation_actions') {
            for (final row in rows) {
              final result = row['result_json'] == null
                  ? <String, dynamic>{}
                  : jsonMap(row['result_json'] as String);
              final scope = row['payload_json'] == null
                  ? result['scope']
                  : actionScope(jsonMap(row['payload_json'] as String));
              if (!['committed', 'undone', 'cancelled']
                  .contains(row['status'])) {
                row['status'] = 'failed';
                row['result_json'] = jsonEncode({
                  ...result,
                  'needs_replan': true,
                  'error': '恢复后请重新说明未完成事项',
                  if (scope != null) 'scope': scope
                });
              } else if (row['status'] == 'cancelled' && scope != null) {
                row['result_json'] = jsonEncode({...result, 'scope': scope});
              }
              row['payload_json'] = null;
            }
          }
          data[table] = rows;
        }
        final preferences = data['preferences'] as Json;
        for (final key in preferenceKeys) {
          final rows =
              await tx.query('app_settings', where: 'key=?', whereArgs: [key]);
          if (rows.isNotEmpty) {
            preferences[key] = jsonDecode(rows.single['value_json'] as String);
          }
        }
        return data;
      });

  Future<String?> exportBackup(String password) async {
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(await snapshot())));
    require(plain.length <= maxBytes, '备份超过 100 MiB，暂不能导出');
    final bytes = password.isEmpty
        ? plain
        : utf8.encode(jsonEncode(await _encrypt(plain, password)));
    require(bytes.length <= maxBytes, '备份文件超过 100 MiB，无法生成可导入的文件');
    return _save(bytes,
        'food-journal-${today()}${password.isEmpty ? '.json' : '.enc.json'}');
  }

  Future<String?> exportCsv(bool weights) async {
    final rows = weights
        ? await records.db.query('weight_records',
            where: 'deleted_at_ms IS NULL',
            orderBy: 'local_date,local_time,created_at_ms')
        : await records.db.rawQuery(
            '''SELECT f.*,m.local_date,m.local_time,m.meal_type FROM food_items f JOIN meals m ON f.meal_id=m.id
      WHERE f.deleted_at_ms IS NULL AND m.deleted_at_ms IS NULL ORDER BY m.local_date,m.local_time,f.created_at_ms''');
    final lines = <List<dynamic>>[];
    if (weights) {
      lines.add(['日期', '时间', '原始数值', '原单位', '统一公斤']);
      for (final row in rows) {
        lines.add([
          row['local_date'],
          row['local_time'],
          row['input_value'],
          row['input_unit'] == 'jin' ? '斤' : '公斤',
          (row['grams'] as int) / 1000
        ]);
      }
    } else {
      lines.add([
        '日期',
        '时间',
        '餐别',
        '食物',
        '份量',
        '热量_kcal',
        '蛋白质_g',
        '脂肪_g',
        '碳水_g',
        ...nutritionNames.map((n) => '$n来源'),
        '备注'
      ]);
      for (final row in rows) {
        final source = jsonMap(row['nutrition_sources_json'] as String);
        lines.add([
          row['local_date'],
          row['local_time'],
          mealNames[row['meal_type']],
          row['name'],
          row['portion_text'],
          ...nutritionFields.map((f) => row[f]),
          ...nutritionFields.map((f) => sources[source[f]]),
          row['note']
        ]);
      }
    }
    final content = lines.map((line) => line.map(_csv).join(',')).join('\r\n');
    return _save([0xef, 0xbb, 0xbf, ...utf8.encode(content)],
        '${weights ? '体重' : '饮食'}-${today()}.csv');
  }

  String _csv(dynamic value) {
    if (value == null) return '';
    if (value is num) return value.toString();
    var text = value.toString();
    if (text.startsWith('\t') ||
        text.startsWith('\r') ||
        RegExp(r'^[=+\-@]').hasMatch(text.trimLeft())) text = "'$text";
    return '"${text.replaceAll('"', '""')}"';
  }

  Future<String?> _save(List<int> bytes, String name) async {
    final file =
        File(p.join((await getTemporaryDirectory()).path, '${newId()}-$name'));
    try {
      await file.writeAsBytes(bytes, flush: true);
      return await FlutterFileDialog.saveFile(
          params:
              SaveFileDialogParams(sourceFilePath: file.path, fileName: name));
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Future<Json?> pickBackup(String password) async {
    final path = await FlutterFileDialog.pickFile(
        params: const OpenFileDialogParams(copyFileToCacheDir: true));
    if (path == null) return null;
    final file = File(path);
    try {
      require(await file.length() <= maxBytes, '文件超过 100 MiB');
      Json data;
      try {
        data = jsonMap(await file.readAsString());
      } on FormatException {
        throw const AppError('文件不是有效的 JSON 备份');
      }
      if (data['format'] == 'food-journal-encrypted') {
        require(password.isNotEmpty, '这是加密备份，请输入密码');
        data = jsonMap(utf8.decode(await _decrypt(data, password)));
      }
      await validate(data);
      return data;
    } finally {
      final cache = (await getTemporaryDirectory()).path;
      if (p.isWithin(cache, file.path) && await file.exists()) {
        await file.delete();
      }
    }
  }

  Json _metadata(String salt, String nonce) => {
        'format': 'food-journal-encrypted',
        'version': 1,
        'kdf': {
          'algorithm': 'PBKDF2-HMAC-SHA256',
          'iterations': 600000,
          'bits': 256
        },
        'cipher': 'AES-256-GCM',
        'salt_base64': salt,
        'nonce_base64': nonce
      };

  Future<SecretKey> _derive(String password, List<int> salt) =>
      Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 600000, bits: 256)
          .deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

  Future<Json> _encrypt(List<int> plain, String password) async {
    final cipher = AesGcm.with256bits();
    final salt = cipher.newSecretKey();
    final saltBytes = (await (await salt).extractBytes()).take(16).toList();
    final nonce = cipher.newNonce();
    final metadata = _metadata(base64Encode(saltBytes), base64Encode(nonce));
    final box = await cipher.encrypt(plain,
        secretKey: await _derive(password, saltBytes),
        nonce: nonce,
        aad: utf8.encode(jsonEncode(metadata)));
    return {
      ...metadata,
      'ciphertext_base64': base64Encode(box.cipherText),
      'tag_base64': base64Encode(box.mac.bytes)
    };
  }

  Future<List<int>> _decrypt(Json envelope, String password) async {
    require(envelope['version'] == 1 && envelope['cipher'] == 'AES-256-GCM',
        '不支持的加密备份版本');
    require(envelope['kdf'] is Map, '加密参数不完整');
    final kdf = envelope['kdf'] as Map;
    require(
        kdf['algorithm'] == 'PBKDF2-HMAC-SHA256' &&
            kdf['iterations'] == 600000 &&
            kdf['bits'] == 256,
        '不支持的密钥派生参数');
    try {
      final salt = base64Decode(envelope['salt_base64'] as String);
      final nonce = base64Decode(envelope['nonce_base64'] as String);
      final tag = base64Decode(envelope['tag_base64'] as String);
      final cipher = base64Decode(envelope['ciphertext_base64'] as String);
      require(
          salt.length == 16 &&
              nonce.length == 12 &&
              tag.length == 16 &&
              cipher.length <= maxBytes,
          '加密文件格式不正确');
      final plain = await AesGcm.with256bits().decrypt(
          SecretBox(cipher, nonce: nonce, mac: Mac(tag)),
          secretKey: await _derive(password, salt),
          aad: utf8.encode(jsonEncode(_metadata(
              envelope['salt_base64'] as String,
              envelope['nonce_base64'] as String))));
      require(plain.length <= maxBytes, '解密内容超过 100 MiB');
      return plain;
    } on SecretBoxAuthenticationError {
      throw const AppError('密码错误或备份文件已损坏');
    } on FormatException {
      throw const AppError('加密文件格式不正确');
    }
  }

  Future<void> validate(Json data) async {
    require(
        data['format'] == 'food-journal-backup' &&
            data['format_version'] == 1 &&
            [1, 2, AppDatabase.schemaVersion]
                .contains(data['database_schema_version']),
        '不支持的备份格式或数据库版本');
    require(
        data['preferences'] is Map &&
            data['exported_at'] is String &&
            DateTime.tryParse(data['exported_at'] as String) != null,
        '备份元数据不完整');
    final preferences = data['preferences'] as Map;
    require(preferences.keys.every(preferenceKeys.contains), '备份包含不允许导入的设置');
    require(
        !preferences.containsKey('weight_unit') ||
            ['jin', 'kg'].contains(preferences['weight_unit']),
        '体重单位不正确');
    require(
        !preferences.containsKey('theme_mode') ||
            ['system', 'light', 'dark'].contains(preferences['theme_mode']),
        '外观设置不正确');
    require(
        !preferences.containsKey('onboarding_completed') ||
            preferences['onboarding_completed'] is bool,
        '引导设置不正确');
    final staging = await openDatabase(inMemoryDatabasePath,
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          for (final sql in AppDatabase.schema.split(';')) {
            if (sql.trim().isNotEmpty) await db.execute(sql);
          }
        });
    final shapes = <String, List<Json>>{};
    try {
      for (final table in AppDatabase.businessTables) {
        require(data[table] is List, '备份缺少 $table');
        final columns = await staging.rawQuery('PRAGMA table_info($table)');
        shapes[table] =
            columns.map((c) => Map<String, dynamic>.from(c)).toList();
        final names = columns.map((c) => c['name']).toSet();
        for (final raw in data[table] as List) {
          if (data['database_schema_version'] == 1 &&
              table == 'chat_messages' &&
              raw is Map) {
            raw.putIfAbsent('model_reply_text', () => null);
            raw.putIfAbsent('receipt_text', () => null);
          }
          if ((data['database_schema_version'] as int) < 3 &&
              table == 'chat_messages' &&
              raw is Map) {
            raw.putIfAbsent('reasoning_text', () => null);
          }
          require(
              raw is Map &&
                  raw.keys.toSet().difference(names).isEmpty &&
                  names.difference(raw.keys.toSet()).isEmpty,
              '$table 字段不完整或含未知字段');
          final row = Map<String, dynamic>.from(raw as Map);
          require(row['id'] is String && (row['id'] as String).isNotEmpty,
              '$table 缺少有效 ID');
          for (final column in columns) {
            final key = column['name'] as String;
            final value = row[key];
            require(
                value != null || column['notnull'] == 0, '$table.$key 不能为空');
            if (value == null) continue;
            require(
                switch (column['type']) {
                  'INTEGER' => value is int,
                  'REAL' => value is num && value.isFinite,
                  'TEXT' => value is String,
                  _ => false
                },
                '$table.$key 数据类型不正确');
            if (key.endsWith('_json')) {
              try {
                jsonDecode(value as String);
              } on FormatException {
                throw AppError('$table.$key 不是有效 JSON');
              }
            }
          }
          if (RecordRepository.entityTables.contains(table)) {
            require(row['version'] is int && row['version'] >= 1, '记录版本不正确');
          }
          if (['meals', 'weight_records'].contains(table)) {
            validateDate(
                row['local_date'] as String, row['local_time'] as String?);
            require(
                isClockTime(row['local_time'] as String?) ==
                    (row['occurred_at_ms'] != null),
                '发生时间字段不一致');
          }
          if (table == 'food_items') {
            final source = jsonMap(row['nutrition_sources_json'] as String);
            final basis = jsonMap(row['nutrition_basis_json'] as String);
            for (final field in nutritionFields) {
              require(
                  source.containsKey(field) &&
                      basis.containsKey(field) &&
                      sources.containsKey(source[field]) &&
                      (row[field] == null) == (source[field] == 'unknown'),
                  '营养来源与空值不一致');
            }
          }
          if (table == 'weight_records') {
            require(
                weightGrams(row['input_value'] as String,
                        row['input_unit'] as String) ==
                    row['grams'],
                '体重换算不一致');
          }
          if (table == 'operations') {
            require(
                !['pending', 'running', 'ready'].contains(row['status']) &&
                    row['plan_json'] == null,
                '备份包含可自动重放任务');
          }
          if (table == 'operation_actions') {
            require(
                row['payload_json'] == null &&
                    !['planned', 'ready'].contains(row['status']),
                '备份包含未失效操作');
          }
        }
      }
      final ids = {
        for (final table in AppDatabase.businessTables)
          table: (data[table] as List)
              .map((r) => (r as Map)['id'] as String)
              .toSet()
      };
      final mealRows = {
        for (final raw in data['meals'] as List) (raw as Map)['id']: raw
      };
      final activeCounts = <String, int>{};
      for (final raw in data['food_items'] as List) {
        final food = raw as Map;
        final meal = mealRows[food['meal_id']];
        require(meal != null, '食物所属餐缺失');
        if (food['deleted_at_ms'] == null) {
          require(meal!['deleted_at_ms'] == null, '已删除的餐仍有有效食物');
          final id = food['meal_id'] as String;
          activeCounts[id] = (activeCounts[id] ?? 0) + 1;
        }
      }
      for (final meal in mealRows.values) {
        if ((meal)['deleted_at_ms'] == null) {
          require((activeCounts[meal['id']] ?? 0) > 0, '有效餐不能没有食物');
        }
      }
      for (final table in AppDatabase.businessTables) {
        for (final raw in data[table] as List) {
          _validateRelations(
              table, Map<String, dynamic>.from(raw as Map), ids, shapes);
        }
      }
      await staging.transaction((tx) => _insertBusiness(tx, data));
      require((await staging.rawQuery('PRAGMA foreign_key_check')).isEmpty,
          '备份关联不完整');
    } on DatabaseException {
      throw const AppError('备份字段、唯一 ID 或引用关系无效');
    } on FormatException {
      throw const AppError('备份中的 JSON 字段格式无效');
    } on TypeError {
      throw const AppError('备份字段结构或数据类型无效');
    } finally {
      await staging.close();
    }
  }

  void _validateMessageContext(Json context) {
    for (final field in ['local_date', 'label', 'record_table', 'record_id']) {
      require(
          context[field] == null || context[field] is String, '聊天上下文字段格式不正确');
    }
    if (context['local_date'] != null) {
      validateDate(context['local_date'] as String, null);
    }
    require(
        context['record_table'] == null ||
            RecordRepository.entityTables.contains(context['record_table']),
        '聊天关联记录类型不正确');
  }

  void _validateRelations(String table, Json row, Map<String, Set<String>> ids,
      Map<String, List<Json>> shapes) {
    void references(dynamic raw) {
      require(raw is List, '记录引用必须是列表');
      for (final value in raw as List) {
        require(
            value is Map &&
                RecordRepository.entityTables.contains(value['table']) &&
                value['id'] is String &&
                ids[value['table']]!.contains(value['id']) &&
                value['action_id'] is String &&
                ids['operation_actions']!.contains(value['action_id']),
            '备份记录引用缺失');
      }
    }

    if (table == 'chat_messages') {
      if (row['record_refs_json'] != null) {
        references(jsonDecode(row['record_refs_json'] as String));
      }
      if (row['quote_snapshot_json'] != null) {
        final quote = jsonMap(row['quote_snapshot_json'] as String);
        require(quote['body_text'] is String, '引用摘要格式不正确');
        if (quote['context'] != null) {
          require(quote['context'] is Map, '引用上下文格式不正确');
          _validateMessageContext(
              Map<String, dynamic>.from(quote['context'] as Map));
        }
        if (quote['record_refs_json'] != null) {
          references(jsonDecode(quote['record_refs_json'] as String));
        }
      }
    }
    if (table == 'operations') {
      final reference = jsonMap(row['reference_time_json'] as String);
      require(
          reference['local_date'] is String &&
              reference['timestamp_ms'] is int &&
              reference['utc_offset_minutes'] is int,
          '任务参考时间不完整');
      validateDate(reference['local_date'] as String,
          reference['local_time'] as String?);
      require(
          reference['local_time'] == null ||
              isClockTime(reference['local_time'] as String?),
          '任务参考时间必须是具体时刻');
      _validateMessageContext(jsonMap(row['context_json'] as String));
      if (row['reply_to_action_id'] != null) {
        require(ids['operation_actions']!.contains(row['reply_to_action_id']),
            '待回答事项引用缺失');
      }
      if (row['vision_summary_json'] != null) {
        final summary = jsonMap(row['vision_summary_json'] as String);
        require(
            summary['protocol_version'] == 1 &&
                ['recognized', 'clarify', 'non_food']
                    .contains(summary['outcome']) &&
                summary['summary'] is String,
            '视觉摘要格式不正确');
      }
    }
    if (table == 'operation_actions') {
      if (row['result_json'] != null) {
        final result = jsonMap(row['result_json'] as String);
        if (result['refs'] != null) references(result['refs']);
        if (result['scope'] != null) {
          require(result['scope'] is Map, '未完成事项范围无效');
          final scope = result['scope'] as Map;
          require(scope['type'] == row['type'], '未完成事项类型不一致');
          for (final key in ['id', 'meal_id', 'action_id']) {
            if (scope[key] != null) {
              require(scope[key] is String, '未完成事项的定位字段无效');
            }
          }
        }
      }
      final snapshots = <String, Set<String>>{};
      for (final field in ['before_json', 'after_json']) {
        if (row[field] == null) continue;
        final entries = jsonRows(row[field] as String);
        final keys = <String>{};
        for (final entry in entries) {
          final entity = entry['table'];
          final id = entry['id'];
          require(
              RecordRepository.entityTables.contains(entity) &&
                  id is String &&
                  ids[entity]!.contains(id),
              '操作快照指向不存在的记录');
          require(keys.add('$entity/$id'), '操作快照重复');
          final snapshot = entry['row'];
          if (snapshot == null) {
            require(field == 'before_json', '提交后快照不能缺失');
            continue;
          }
          require(
              snapshot is Map &&
                  snapshot['id'] == id &&
                  snapshot['version'] is int &&
                  snapshot['version'] >= 1,
              '操作快照格式不正确');
          final record = Map<String, dynamic>.from(snapshot as Map);
          final columns = shapes[entity]!;
          final names = columns.map((c) => c['name']).toSet();
          require(
              record.keys.toSet().difference(names).isEmpty &&
                  names.difference(record.keys.toSet()).isEmpty,
              '快照包含未知字段或缺少字段');
          for (final column in columns) {
            final value = record[column['name']];
            require(value != null || column['notnull'] == 0, '快照必填字段缺失');
            if (value == null) continue;
            require(
                switch (column['type']) {
                  'INTEGER' => value is int,
                  'REAL' => value is num && value.isFinite,
                  'TEXT' => value is String,
                  _ => false
                },
                '快照字段类型不正确');
          }
          if (record['origin_action_id'] != null) {
            require(
                ids['operation_actions']!.contains(record['origin_action_id']),
                '快照的原操作缺失');
          }
          if (record['meal_id'] != null) {
            require(ids['meals']!.contains(record['meal_id']), '快照所属餐缺失');
          }
          _validateRelations(entity as String, record, ids, shapes);
        }
        snapshots[field] = keys;
      }
      if (['committed', 'undone'].contains(row['status'])) {
        require(
            snapshots.length == 2 &&
                snapshots['before_json']!
                    .difference(snapshots['after_json']!)
                    .isEmpty &&
                snapshots['after_json']!
                    .difference(snapshots['before_json']!)
                    .isEmpty,
            '操作前后快照不完整');
      }
    }
    if (table == 'meals' || table == 'weight_records') {
      if (table == 'meals') {
        require(mealNames.containsKey(row['meal_type']), '快照餐别不正确');
      }
      validateDate(row['local_date'] as String, row['local_time'] as String?);
      if (isClockTime(row['local_time'] as String?)) {
        require(
            row['utc_offset_minutes'] is int &&
                (row['utc_offset_minutes'] as int).abs() <= 840,
            '时区偏移无效');
        final expected =
            timeColumns(row, {'utc_offset_minutes': row['utc_offset_minutes']});
        require(expected['occurred_at_ms'] == row['occurred_at_ms'],
            '发生时间与日期、时区不一致');
      } else {
        require(
            row['occurred_at_ms'] == null && row['utc_offset_minutes'] == null,
            '时段或未知时间不能带精确时间戳');
      }
    }
    if (table == 'weight_records') {
      require(
          weightGrams(
                  row['input_value'] as String, row['input_unit'] as String) ==
              row['grams'],
          '快照体重换算不一致');
    }
    if (table == 'food_items') {
      require(
          (row['name'] as String).trim().isNotEmpty &&
              (row['calories_kcal'] == null || row['calories_kcal'] is int),
          '食物名称或热量格式不正确');
      final source = jsonMap(row['nutrition_sources_json'] as String);
      final basis = jsonMap(row['nutrition_basis_json'] as String);
      require(
          source.keys.toSet().difference(nutritionFields.toSet()).isEmpty &&
              basis.keys.toSet().difference(nutritionFields.toSet()).isEmpty,
          '营养来源字段无效');
      for (final field in nutritionFields) {
        require(
            source.containsKey(field) &&
                basis.containsKey(field) &&
                sources.containsKey(source[field]) &&
                (row[field] == null) == (source[field] == 'unknown') &&
                (basis[field] == null ||
                    basis[field] is Map ||
                    basis[field] is String &&
                        ['ai', 'user'].contains(source[field])),
            '营养来源结构不一致');
        require(
            row[field] == null ||
                row[field] is num &&
                    (row[field] as num).isFinite &&
                    row[field] >= 0,
            '快照营养值不正确');
      }
    }
    if (table == 'food_library') {
      require((row['name'] as String).trim().isNotEmpty, '食品资料名称为空');
      final aliases = jsonDecode(row['aliases_json'] as String);
      require(
          aliases is List && aliases.every((e) => e is String), '食品别名格式不正确');
      final base = jsonMap(row['base_portion_json'] as String);
      require(
          base['amount'] is num &&
              (base['amount'] as num).isFinite &&
              base['amount'] > 0 &&
              base['unit'] is String,
          '食品基准不正确');
      final nutrition = jsonMap(row['nutrition_json'] as String);
      require(
          nutritionFields.every(nutrition.containsKey) &&
              nutrition.keys.every(nutritionFields.contains) &&
              nutrition.values
                  .every((n) => n == null || n is num && n.isFinite && n >= 0),
          '食品资料营养格式不正确');
      validateLibrarySource(jsonMap(row['source_json'] as String));
    }
    if (table == 'ai_memories') {
      require((row['content'] as String).trim().isNotEmpty, '记忆内容为空');
    }
    if (table == 'consent_proposals') {
      require(
          [
            'save_common_food',
            'save_packaged_food',
            'update_library',
            'save_memory',
            'update_memory'
          ].contains(row['kind']),
          '资料建议类型不正确');
      final proposal = jsonMap(row['payload_json'] as String);
      require(proposal['type'] == row['kind'], '资料建议类型与内容不一致');
      validateProposal(proposal);
    }
  }

  Future<void> _insertBusiness(DatabaseExecutor tx, Json data) async {
    final deferred = <Json>[];
    for (final table in AppDatabase.businessTables) {
      for (final raw in data[table] as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        final key = table == 'operation_actions'
            ? 'undo_of_action_id'
            : table == 'chat_messages'
                ? 'quoted_message_id'
                : null;
        if (key != null && row[key] != null) {
          deferred.add(
              {'table': table, 'id': row['id'], 'key': key, 'value': row[key]});
          row[key] = null;
        }
        await tx.insert(table, row);
      }
    }
    for (final reference in deferred) {
      await tx.update(reference['table'] as String,
          {reference['key'] as String: reference['value']},
          where: 'id=?', whereArgs: [reference['id']]);
    }
  }

  Future<void> restore(Json data, {bool fromSafety = false}) async {
    await validate(data);
    final wasForeground = chat.foreground;
    await chat.suspend();
    try {
      final before = await snapshot();
      final file = await safetyFile;
      // 安全副本本身恢复时也先读入内存，再替换磁盘上的上一份。
      final temporary = File('${file.path}.pending');
      await temporary.writeAsString(jsonEncode(before), flush: true);
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
      await records.db.transaction((tx) async {
        await tx.delete('chat_attachments');
        for (final table in AppDatabase.businessTables.reversed) {
          if (table == 'operation_actions') {
            await tx.update(table, {'undo_of_action_id': null});
          }
          if (table == 'chat_messages') {
            await tx.update(table, {'quoted_message_id': null});
          }
          await tx.delete(table);
        }
        await _insertBusiness(tx, data);
        for (final key in [
          ...preferenceKeys,
          'chat_draft',
          'library_editor_draft',
          'library_photo_capture'
        ]) {
          await tx.delete('app_settings', where: 'key=?', whereArgs: [key]);
        }
        for (final entry in (data['preferences'] as Map).entries) {
          await tx.insert('app_settings',
              {'key': entry.key, 'value_json': jsonEncode(entry.value)});
        }
      });
      await images.cleanup();
      records.changed();
    } finally {
      chat.lifecycle(wasForeground);
    }
  }

  Future<Json> readSafety() async {
    final file = await safetyFile;
    require(await file.exists(), '还没有替换前安全副本');
    final data = jsonMap(await file.readAsString());
    await validate(data);
    return data;
  }

  Future<List<String>> clearAll() async {
    final resumed = chat.foreground;
    await chat.suspend();
    final failed = <String>[];
    try {
      try {
        await records.db.transaction((tx) async {
          await tx.delete('chat_attachments');
          for (final table in AppDatabase.businessTables.reversed) {
            if (table == 'operation_actions') {
              await tx.update(table, {'undo_of_action_id': null});
            }
            if (table == 'chat_messages') {
              await tx.update(table, {'quoted_message_id': null});
            }
            await tx.delete(table);
          }
          await tx.delete('app_settings');
        });
      } catch (_) {
        failed.add('本地数据库');
      }
      try {
        await settings.secure.delete(key: 'ai_credential');
      } catch (_) {
        failed.add('安全凭据');
      }
      try {
        await for (final file in images.root.list(followLinks: false)) {
          if (file is File) await file.delete();
        }
      } catch (_) {
        failed.add('图片预览');
      }
      try {
        final file = await safetyFile;
        if (await file.exists()) await file.delete();
      } catch (_) {
        failed.add('内部安全副本');
      }
      records.changed();
      return failed;
    } finally {
      chat.lifecycle(resumed);
    }
  }
}
