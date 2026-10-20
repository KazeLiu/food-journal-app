import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/core/data.dart';
import 'package:food_journal/records/record_repository.dart';

import '../support/test_store.dart';

void main() {
  late TestStore store;
  setUp(() async => store = await TestStore.create());
  tearDown(() async => store.close());

  test('列表、搜索和定位都保留已发送的日期上下文，引用快照不递归携带历史', () async {
    final op = await store.records.enqueue(
        '吃得多吗？',
        [],
        {
          'local_date': '2026-10-19',
          'label': '记录或查询 2026-10-19',
          'quote_snapshot': {'body_text': '更早的引用'}
        },
        null,
        null);
    final messages = await store.records.messages();
    final found = await store.records.messages(keyword: '吃得多');
    final around = await store.records.messagesAround(op['message_id']);
    for (final message in [messages.single, found.single, around.single]) {
      expect(jsonMap(message['sent_context_json'])['local_date'], '2026-10-19');
    }
    final snapshot = RecordRepository.quoteSnapshot(found.single);
    expect(snapshot['body_text'], '吃得多吗？');
    expect(snapshot['context'],
        {'local_date': '2026-10-19', 'label': '记录或查询 2026-10-19'});
    expect((snapshot['context'] as Map).containsKey('quote_snapshot'), isFalse);
  });

  test('上午、中午、下午按时段排列，不按中文字符顺序排列', () async {
    for (final time in ['下午', '中午', '上午']) {
      await store.services.committer
          .local({...mealInput(), 'local_time': time});
    }
    expect(
        (await store.records.meals('2026-10-20')).map((m) => m['local_time']),
        ['上午', '中午', '下午']);
  });

  test('记录回执与后续状态更新不覆盖模型原回复，搜索仍能找到原文', () async {
    final op = await store.records.enqueue('早餐', [], {}, null, null);
    await store.records
        .assistant(op['id'], '鸡蛋和蔬菜搭配不错。', 'running', modelReply: true);
    await store.records.assistant(op['id'], '已记录早餐。', 'completed');
    await store.records.assistant(op['id'], '已撤销记录。', 'completed');
    final messages = await store.records.messages(keyword: '鸡蛋和蔬菜');
    expect(messages, hasLength(1));
    final message = messages.single;
    expect(message['model_reply_text'], '鸡蛋和蔬菜搭配不错。');
    expect(message['receipt_text'], '已撤销记录。');
    expect(message['body_text'], '鸡蛋和蔬菜搭配不错。\n\n已撤销记录。');
  });

  test('同日同餐别可多次记录，餐数按餐别去重，体重测量各自保留', () async {
    await store.services.committer.local(mealInput());
    await store.services.committer.local(mealInput());
    await store.services.committer.local(mealInput(type: 'other'));
    await store.services.committer.local(weightInput());
    await store.services.committer.local(weightInput(value: '131.5'));
    expect(await store.records.meals('2026-10-20'), hasLength(3));
    expect(await store.records.weights(date: '2026-10-20'), hasLength(2));
    final totals = await store.records.totals('2026-10-20');
    expect(totals['meal_count'], 1);
    expect(totals['other_count'], 1);
    final marks = await store.records.monthMarks(DateTime(2026, 10));
    expect(marks['food'], {'2026-10-20'});
    expect(marks['weight'], {'2026-10-20'});
    expect(
        (await store.records.monthMarks(DateTime(2026, 11)))['food'], isEmpty);
  });

  test('入队失败完整回滚，保留草稿；快捷分析可不消费草稿', () async {
    await store.services.settings
        .set('chat_draft', {'text': '尚未发送', 'attachments': []});
    await expectLater(
        store.records.enqueue('带失效图片', ['missing'], {}, null, null),
        throwsException);
    expect(await store.db.query('operations'), isEmpty);
    expect(await store.db.query('chat_messages'), isEmpty);
    expect((await store.services.settings.get('chat_draft'))['text'], '尚未发送');
    await store.records.enqueue('今日分析', [], {}, null, null, clearDraft: false);
    expect((await store.services.settings.get('chat_draft'))['text'], '尚未发送');
    await store.records.enqueue('正式发送', [], {}, null, null);
    expect(await store.services.settings.get('chat_draft'), isNull);
  });

  test('关键词中的通配符按原文查询，同毫秒分页不漏项也不重复', () async {
    for (var i = 0; i < 7; i++) {
      final op = await store.records
          .enqueue(i == 3 ? r'100%_原文\' : '消息$i', [], {}, null, null);
      await store.db.update(
          'chat_messages', {'id': 'message-$i', 'created_at_ms': 1000},
          where: 'id=?', whereArgs: [op['message_id']]);
    }
    final first = await store.records.messages(limit: 3);
    final second = await store.records.messages(before: first.last, limit: 3);
    final third = await store.records.messages(before: second.last, limit: 3);
    expect([...first, ...second, ...third].map((m) => m['id']).toSet(),
        hasLength(7));
    expect([...first, ...second, ...third], hasLength(7));
    expect(await store.records.messages(keyword: r'%_原文\'), hasLength(1));
    final around = await store.records.messagesAround('message-3');
    expect(around.map((m) => m['id']), contains('message-3'));
  });

  test('删除聊天不删业务事实，原消息缺失后仍可撤销修改', () async {
    final op = await store.records.enqueue('早餐', [], {}, null, null);
    final actions = await store.services.committer.savePlan(op['id'], [
      {...mealInput(), 'action_key': 'meal', 'state': 'ready'}
    ]);
    final first = await store.services.committer.commit(actions.single['id']);
    final foodId = receiptId(first, 'food_items');
    final modified = await store.services.committer.local({
      'type': 'update_food',
      'id': foodId,
      'expected_version': 1,
      'patch': {'note': '临时修改'}
    });
    await store.records.deleteMessage(op['message_id']);
    expect(await store.records.meals('2026-10-20'), hasLength(1));
    await store.services.committer
        .local({'type': 'undo_action', 'action_id': modified['action_id']});
    expect((await store.records.row('food_items', foodId))!['note'], isNull);
    final meal = (await store.records.meals('2026-10-20')).single;
    expect(meal['source_message_id'], isNull);
    expect(await store.db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

  test('重启将运行与排队任务标为可恢复，并清除临时手动占用标记', () async {
    final op = await store.records.enqueue('早餐', [], {}, null, null);
    await store.db.update(
        'operations',
        {
          'status': 'running',
          'context_json': jsonEncode(
              {'manual_action_id': 'input', 'local_date': '2026-10-20'})
        },
        where: 'id=?',
        whereArgs: [op['id']]);
    await store.database.normalizeInterrupted();
    final saved = (await store.records.row('operations', op['id']))!;
    expect(saved['status'], 'interrupted');
    expect(jsonDecode(saved['context_json']), {'local_date': '2026-10-20'});
    expect(await store.records.pendingOperations(), isEmpty);
  });
}
