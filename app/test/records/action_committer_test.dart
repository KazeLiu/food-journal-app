import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/core/data.dart';

import '../support/test_store.dart';

void main() {
  late TestStore store;
  setUp(() async => store = await TestStore.create());
  tearDown(() async => store.close());

  Future<String> chatOperation() async =>
      (await store.records.createOperation(kind: 'chat', reference: {
        'local_date': '2026-10-20',
        'local_time': '08:45',
        'timestamp_ms':
            DateTime.utc(2026, 10, 20, 12, 45).millisecondsSinceEpoch,
        'utc_offset_minutes': -240
      }))['id'] as String;

  test('今天未说时间的饮食和体重在计划中固定为发送时刻，重试不改时间', () async {
    final op = await chatOperation();
    final actions = await store.services.committer.savePlan(op, [
      {...mealInput(), 'action_key': 'meal', 'state': 'ready'},
      {...weightInput(), 'action_key': 'weight', 'state': 'ready'}
    ]);
    for (final action in actions) {
      expect(jsonMap(action['payload_json'])['local_time'], '08:45');
      final receipt = await store.services.committer.commit(action['id']);
      expect(await store.services.committer.commit(action['id']), receipt);
    }
    final meal = (await store.records.meals('2026-10-20')).single;
    final weight = (await store.records.weights()).single;
    for (final row in [meal, weight]) {
      expect(row['local_time'], '08:45');
      expect(row['occurred_at_ms'],
          DateTime.utc(2026, 10, 20, 12, 45).millisecondsSinceEpoch);
    }
  });

  test('昨天无时间只记日期，前天下午保留时段，明确时刻不被当前时间替换', () async {
    final op = await chatOperation();
    final actions = await store.services.committer.savePlan(op, [
      {
        ...mealInput(date: '2026-10-19'),
        'action_key': 'yesterday',
        'state': 'ready'
      },
      {
        ...mealInput(date: '2026-10-18'),
        'local_time': '下午',
        'action_key': 'period',
        'state': 'ready'
      },
      {
        ...weightInput(),
        'local_time': '07:10',
        'action_key': 'clock',
        'state': 'ready'
      }
    ]);
    for (final action in actions) {
      await store.services.committer.commit(action['id']);
    }
    final yesterday = (await store.records.meals('2026-10-19')).single;
    expect(yesterday['local_time'], isNull);
    final period = (await store.records.meals('2026-10-18')).single;
    expect(period['local_time'], '下午');
    expect(period['occurred_at_ms'], isNull);
    expect(period['utc_offset_minutes'], isNull);
    expect((await store.records.weights()).single['local_time'], '07:10');
  });

  test('一餐多食物完整提交，四营养汇总与快照一致', () async {
    final result = await store.services.committer.local(mealInput(items: [
      foodInput(),
      foodInput(name: '鸡蛋', calories: 80, carbs: null)
    ]));
    final totals = await store.records.totals('2026-10-20');
    expect(totals['item_count'], 2);
    expect(totals['calories_kcal'], 180);
    expect(totals['missing_carbs_g'], 1);
    final action =
        (await store.records.row('operation_actions', result['action_id']))!;
    expect(action['status'], 'committed');
    expect(
        jsonRows(action['before_json']).every((s) => s['row'] == null), isTrue);
    expect(jsonRows(action['after_json']), hasLength(3));
    expect(await store.db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

  test('同一 action 重复提交返回原回执，不重复新增记录', () async {
    final op = await store.records.createOperation();
    final actions = await store.services.committer.savePlan(op['id'], [
      {...mealInput(), 'action_key': 'a1', 'state': 'ready'}
    ]);
    final first = await store.services.committer.commit(actions.single['id']);
    final second = await store.services.committer.commit(actions.single['id']);
    expect(second, first);
    expect(await store.records.meals('2026-10-20'), hasLength(1));
  });

  test('餐内后一项非法时整餐回滚，不留下空餐或前一项食物', () async {
    await expectLater(
        store.services.committer
            .local(mealInput(items: [foodInput(), foodInput(name: '')])),
        throwsA(isA<AppError>()));
    expect(await store.db.query('meals'), isEmpty);
    expect(await store.db.query('food_items'), isEmpty);
    expect(
        (await store.db.query('operation_actions')).single['status'], 'failed');
  });

  test('一项失败不丢失另一项成功，部分完成可见', () async {
    final op = await store.records.createOperation();
    final actions = await store.services.committer.savePlan(op['id'], [
      {...mealInput(), 'action_key': 'meal', 'state': 'ready'},
      {...weightInput(value: '0'), 'action_key': 'weight', 'state': 'ready'}
    ]);
    await store.services.committer.commit(actions.first['id']);
    try {
      await store.services.committer.commit(actions.last['id']);
      fail('无效体重应失败');
    } on AppError catch (error) {
      await store.services.committer.fail(actions.last['id'], error);
    }
    await store.services.committer.settle(op['id']);
    expect((await store.records.row('operations', op['id']))!['status'],
        'partial');
    expect(await store.records.meals('2026-10-20'), hasLength(1));
    expect(await store.records.weights(), isEmpty);
  });

  test('旧版本修改被拒绝，不覆盖后续内容', () async {
    final first = await store.services.committer.local(mealInput());
    final id = receiptId(first, 'food_items');
    await store.services.committer.local({
      'type': 'update_food',
      'id': id,
      'expected_version': 1,
      'patch': {'note': '已经更新'}
    });
    await expectLater(
        store.services.committer.local({
          'type': 'update_food',
          'id': id,
          'expected_version': 1,
          'patch': {'note': '过时内容'}
        }),
        throwsA(isA<AppError>().having((e) => e.code, 'code', 'conflict')));
    expect((await store.records.row('food_items', id))!['note'], '已经更新');
  });

  test('撤销新增可重复点击但只生成一次逆操作', () async {
    final first = await store.services.committer.local(mealInput());
    final payload = {'type': 'undo_action', 'action_id': first['action_id']};
    final undo = await store.services.committer.local(payload);
    expect(await store.services.committer.local(payload), undo);
    expect(await store.records.meals('2026-10-20'), isEmpty);
    expect(
        (await store.db.query('operation_actions',
            where: 'undo_of_action_id=?', whereArgs: [first['action_id']])),
        hasLength(1));
  });

  test('删除最后一项会隐藏空餐，撤销同时恢复餐与食物', () async {
    final first = await store.services.committer.local(mealInput());
    final deleted = await store.services.committer.local({
      'type': 'delete_food',
      'id': receiptId(first, 'food_items'),
      'expected_version': 1
    });
    expect(await store.records.meals('2026-10-20'), isEmpty);
    await store.services.committer
        .local({'type': 'undo_action', 'action_id': deleted['action_id']});
    final meals = await store.records.meals('2026-10-20');
    expect(meals, hasLength(1));
    expect(meals.single['items'], hasLength(1));
  });

  test('目标有后续修改时撤销明确冲突，不回退当前值', () async {
    final first = await store.services.committer.local(mealInput());
    final id = receiptId(first, 'food_items');
    await store.services.committer.local({
      'type': 'update_food',
      'id': id,
      'expected_version': 1,
      'patch': {'note': '保留当前内容'}
    });
    await expectLater(
        store.services.committer
            .local({'type': 'undo_action', 'action_id': first['action_id']}),
        throwsA(isA<AppError>().having((e) => e.code, 'code', 'conflict')));
    expect((await store.records.row('food_items', id))!['note'], '保留当前内容');
  });

  test('已成功事项不被重试计划覆盖，非法事项不保留可执行 payload', () async {
    final op = await store.records.createOperation();
    final meal = {...mealInput(), 'action_key': 'meal', 'state': 'ready'};
    final actions = await store.services.committer.savePlan(op['id'], [meal]);
    await store.services.committer.commit(actions.single['id']);
    final retry = await store.services.committer.savePlan(op['id'], [
      {...meal, 'raw_description': '不应重写'},
      {...weightInput(), 'action_key': 'bad', 'state': 'ready'}
    ], errors: {
      'bad': '非法事项'
    });
    expect(retry.first['status'], 'committed');
    expect(jsonMap(retry.first['payload_json'])['raw_description'], '测试早餐');
    expect(retry.last['status'], 'failed');
    expect(retry.last['payload_json'], isNull);
    expect(jsonMap(retry.last['result_json'])['needs_replan'], isTrue);
  });

  test('字符串估算依据写入为 note 对象，非法依据类型在写库前拒绝', () async {
    final first = await store.services.committer.local(mealInput(items: [
      foodInput(source: 'ai', basis: {'calories_kcal': '按一份早餐估算'})
    ]));
    final row = (await store.records
        .row('food_items', receiptId(first, 'food_items')))!;
    expect(jsonMap(row['nutrition_basis_json'])['calories_kcal'],
        {'note': '按一份早餐估算'});
    for (final bad in [
      123,
      <String>[],
      {'note': 123}
    ]) {
      await expectLater(
          store.services.committer.local(mealInput(items: [
            foodInput(basis: {'calories_kcal': bad})
          ])),
          throwsA(isA<AppError>()));
    }
    expect(await store.records.meals('2026-10-20'), hasLength(1));
  });

  test('补算只填空值；已有真实零值和用户数据不能覆盖', () async {
    final first = await store.services.committer.local(
        mealInput(items: [foodInput(calories: 0, protein: null, fat: null)]));
    final id = receiptId(first, 'food_items');
    await store.services.committer.local({
      'type': 'backfill',
      'food_id': id,
      'expected_version': 1,
      'missing_fields': ['protein_g', 'fat_g'],
      'values': {
        'protein_g': {'value': 5, 'source': 'ai'},
        'fat_g': {'value': null, 'source': 'unknown'}
      },
      'estimation_note': '缺脂肪依据'
    });
    final row = (await store.records.row('food_items', id))!;
    expect(row['calories_kcal'], 0);
    expect(row['protein_g'], 5);
    expect(row['fat_g'], isNull);
    expect(jsonMap(row['nutrition_sources_json'])['calories_kcal'], 'user');
    await expectLater(
        store.services.committer.local({
          'type': 'backfill',
          'food_id': id,
          'expected_version': row['version'],
          'missing_fields': ['calories_kcal'],
          'values': {
            'calories_kcal': {'value': 200, 'source': 'ai'}
          }
        }),
        throwsA(isA<AppError>()));
    expect((await store.records.row('food_items', id))!['calories_kcal'], 0);
  });

  test('食品资料换算读取已保存的基准，不采用模型复制的旧数值', () async {
    final saved = await store.services.committer.local({
      'type': 'save_library',
      'kind': 'packaged_food',
      'name': '测试牛奶',
      'base_portion': {'amount': 100, 'unit': 'ml'},
      'nutrition': {
        'calories_kcal': 60,
        'protein_g': 3,
        'fat_g': 2,
        'carbs_g': 5
      }
    });
    final libraryId = receiptId(saved, 'food_library');
    final first = await store.services.committer.local(mealInput(items: [
      foodInput(source: 'library', basis: {
        for (final field in nutritionFields)
          field: {
            'library_id': libraryId,
            'library_version': 1,
            'base_amount': 999,
            'base_unit': 'ml',
            'value_per_base': 999,
            'consumed_amount': 250,
            'consumed_unit': 'ml'
          }
      })
    ]));
    final food = (await store.records
        .row('food_items', receiptId(first, 'food_items')))!;
    expect(food['calories_kcal'], 150);
    expect(food['protein_g'], 7.5);
    expect(
        jsonMap(food['nutrition_basis_json'])['calories_kcal']['base_amount'],
        100);
  });

  test('同意才保存长期资料，拒绝抑制重复建议且不影响已记录餐', () async {
    await store.services.committer.local(mealInput());
    final op = await store.records.createOperation();
    final proposal = {
      'type': 'save_memory',
      'content': '不喝牛奶',
      'category': 'preference'
    };
    final ids = await store.services.committer.propose(op['id'], [proposal]);
    expect(await store.records.memories(), isEmpty);
    await store.services.committer.resolveProposal(ids.single, false);
    expect(
        await store.services.committer.propose(op['id'], [proposal]), isEmpty);
    final requested = await store.services.committer
        .propose(op['id'], [proposal], userRequested: true);
    await store.services.committer.resolveProposal(requested.single, true);
    expect(await store.records.memories(), hasLength(1));
    await expectLater(
        store.services.committer.resolveProposal(requested.single, true),
        throwsA(isA<AppError>()));
    expect(await store.records.memories(), hasLength(1));
    expect(await store.records.meals('2026-10-20'), hasLength(1));
  });
}
