import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/core/data.dart';

import '../support/test_store.dart';

void main() {
  late TestStore store;
  setUp(() async => store = await TestStore.create());
  tearDown(() async => store.close());

  Future<String> attachment(String name) async {
    final id = newId();
    await store.services.images.fileFor(name).writeAsBytes([1, 2, 3]);
    await store.db.insert('chat_attachments', {
      'id': id,
      'relative_path': name,
      'mime_type': 'image/jpeg',
      'byte_length': 3,
      'state': 'pending',
      'created_at_ms': 1
    });
    return id;
  }

  test('有效摘要保留压缩预览，删除聊天才清理且不删除相册原图', () async {
    final gallery = await File('${store.directory.path}/gallery-original.jpg')
        .writeAsBytes([4, 5, 6]);
    final id = await attachment('private-copy.jpg');
    final op = await store.records.enqueue('早餐图片', [id], {}, null, null);
    final summary = {
      'protocol_version': 1,
      'outcome': 'recognized',
      'summary': '一份早餐'
    };
    await store.services.images
        .saveSummary(op['id'], op['message_id'], summary);
    expect(
        (await store.records
            .row('operations', op['id']))!['vision_summary_json'],
        isNotNull);
    expect(await store.services.images.fileFor('private-copy.jpg').exists(),
        isTrue);
    expect(await gallery.exists(), isTrue);
    expect(
        await store.services.images.forMessage(op['message_id']), hasLength(1));
    await store.records.deleteMessage(op['message_id']);
    await store.services.images.cleanup();
    expect(await store.services.images.fileFor('private-copy.jpg').exists(),
        isFalse);
    expect(await store.db.query('chat_attachments'), isEmpty);
    expect(await gallery.exists(), isTrue);
  });

  test('重开清理孤儿但保留草稿引用图片和已绑定的待识别图片', () async {
    final draft = await attachment('draft.jpg');
    await attachment('orphan.jpg');
    final pending = await attachment('pending.jpg');
    await store.records.enqueue('待识别', [pending], {}, null, null);
    await store.services.settings.set('chat_draft', {
      'text': '',
      'attachments': [draft]
    });
    await store.services.images.fileFor('unregistered.jpg').writeAsBytes([9]);
    await store.services.images.cleanup(orphanDrafts: true);
    expect(await store.services.images.fileFor('draft.jpg').exists(), isTrue);
    expect(await store.services.images.fileFor('pending.jpg').exists(), isTrue);
    expect(await store.services.images.fileFor('orphan.jpg').exists(), isFalse);
    expect(await store.services.images.fileFor('unregistered.jpg').exists(),
        isFalse);
  });

  test('取消已发送消息和重开清理不删除聊天预览', () async {
    final id = await attachment('cancelled-preview.jpg');
    final op = await store.records.enqueue('取消处理但保留聊天', [id], {}, null, null);
    await store.services.chat.cancelPending(op['id']);
    await store.services.images.cleanup(orphanDrafts: true);
    expect(
        await store.services.images.fileFor('cancelled-preview.jpg').exists(),
        isTrue);
    expect(
        await store.services.images.forMessage(op['message_id']), hasLength(1));
  });

  test('图片缺失可明确重选，原文字消息仍保留', () async {
    final id = await attachment('missing.jpg');
    final op = await store.records.enqueue('不能丢失的文字', [id], {}, null, null);
    await store.services.images.fileFor('missing.jpg').delete();
    await expectLater(
        store.services.images.contentFor(op['message_id']),
        throwsA(
            isA<AppError>().having((e) => e.code, 'code', 'image_missing')));
    expect((await store.records.inputFor(op['id']))['body_text'], '不能丢失的文字');
  });

  test('删除消息后仍保留清理依据，且不能通过路径穿越操作私有目录外文件', () async {
    final id = await attachment('deleted.jpg');
    final op = await store.records.enqueue('待删除消息', [id], {}, null, null);
    await store.records.deleteMessage(op['message_id']);
    final row = (await store.records.row('chat_attachments', id))!;
    expect(row['state'], 'delete_pending');
    expect(row['message_id'], isNull);
    await store.services.images.cleanup();
    expect(
        await store.services.images.fileFor('deleted.jpg').exists(), isFalse);
    expect(() => store.services.images.fileFor('../outside.jpg'),
        throwsA(isA<AppError>()));
    expect(() => store.services.images.fileFor(store.directory.absolute.path),
        throwsA(isA<AppError>()));
  });
}
