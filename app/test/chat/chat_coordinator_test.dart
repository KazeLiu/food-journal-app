import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/core/data.dart';

import '../support/local_ai_server.dart';
import '../support/test_store.dart';

void main() {
  late TestStore store;
  LocalAiServer? server;
  setUp(() async {
    store = await TestStore.create();
    server = null;
  });
  tearDown(() async {
    await store.services.chat.suspend();
    await server?.close();
    await store.close();
  });
  Future<void> configure([Json overrides = const {}]) async {
    final url = server!.baseUrl;
    await store.services.settings.set('ai_profile', {
      'base_url': url,
      'allow_http': true,
      'text_main': 'text-main',
      'text_backup': 'text-backup',
      'vision_main': 'vision-main',
      'vision_backup': 'vision-backup',
      ...overrides,
    });
    FlutterSecureStorage.setMockInitialValues({
      'ai_credential': jsonEncode({'base_url': url, 'key': 'fake-test-key'})
    });
  }

  Future<void> pump() async {
    store.services.chat.foreground = true;
    if (server == null) {
      await store.services.chat.pump();
    } else {
      await server!.withClient(store.services.chat.pump);
    }
  }

  Future<Json> imageOperation() async {
    await store.services.images.fileFor('progress.jpg').writeAsBytes([1, 2, 3]);
    await store.db.insert('chat_attachments', {
      'id': 'progress-image',
      'relative_path': 'progress.jpg',
      'mime_type': 'image/jpeg',
      'byte_length': 3,
      'state': 'pending',
      'created_at_ms': 1
    });
    return store.records.enqueue('早餐图片', ['progress-image'], {}, null, null);
  }

  test('正文已流出但最终资料协议失败时保留原话和错误，不冒充保存成功', () async {
    server =
        await LocalAiServer.start((request, body) => servePayload(request, {
              ...finalPayload(reply: '我正在整理营养标签的资料建议。'),
              'proposals': '错误结构',
            }));
    await configure();
    final op = await store.records.enqueue('把营养表保存到资料库', [], {}, null, null);
    await pump();
    final reply = (await store.db.query('chat_messages',
            where: "operation_id=? AND role='assistant'",
            whereArgs: [op['id']]))
        .single;
    expect(reply['model_reply_text'], '我正在整理营养标签的资料建议。');
    expect(reply['receipt_text'], contains('未通过校验的内容没有保存'));
    expect(reply['delivery_status'], 'failed');
    expect(server!.calls, hasLength(4));
    expect(await store.records.library(), isEmpty);
    expect(await store.db.query('consent_proposals'), isEmpty);
  });

  test('只填文字主模型时最多请求两次，未配图片模型不发空模型请求', () async {
    server = await LocalAiServer.start((request, body) async {
      request.response.statusCode = 500;
      await request.response.close();
    });
    await configure({
      'text_backup': '',
      'vision_main': '',
      'vision_backup': '',
      'text_main_effort': 'low'
    });
    final text = await store.records.enqueue('普通问题', [], {}, null, null);
    await pump();
    expect(server!.calls, hasLength(2));
    expect(
        server!.calls.every((c) => c['body']['reasoning']['effort'] == 'low'),
        isTrue);
    expect((await store.records.row('operations', text['id']))!['status'],
        'failed');
    store.services.chat.foreground = false;
    final image = await imageOperation();
    await pump();
    expect(server!.calls, hasLength(2));
    expect((await store.records.row('operations', image['id']))!['error_code'],
        'configuration');
  });

  test('自动补算的兜底留空时不重试空模型，沿用文字主模型的思考强度', () async {
    final food = foodInput(protein: null);
    food['nutrition']['protein_g']['source'] = 'unknown';
    final created =
        await store.services.committer.local(mealInput(items: [food]));
    server = await LocalAiServer.start((request, body) async {
      if (body['stream'] == false) {
        request.response.statusCode = 500;
        await request.response.close();
      } else {
        await servePayload(request, finalPayload());
      }
    });
    await configure({
      'text_backup': '',
      'vision_main': '',
      'vision_backup': '',
      'text_main_effort': 'low'
    });
    await store.records.enqueue('普通聊天', [], {}, null, null);
    await pump();
    expect(server!.calls, hasLength(3));
    expect(
        server!.calls.every((c) =>
            c['body']['model'] == 'text-main' &&
            c['body']['reasoning']['effort'] == 'low'),
        isTrue);
    expect(store.services.chat.backfillNotice, contains('补算未完成'));
    expect(
        (await store.records
            .row('food_items', receiptId(created, 'food_items')))!['protein_g'],
        isNull);
  });

  test('主备分别传递自己的思考强度，默认值不代替显式档位', () async {
    server = await LocalAiServer.start((request, body) async {
      if (body['model'] == 'text-main') {
        request.response.statusCode = 500;
        await request.response.close();
      } else {
        await servePayload(request, finalPayload());
      }
    });
    await configure({'text_main_effort': 'high', 'text_backup_effort': 'low'});
    await store.records.enqueue('普通问题', [], {}, null, null);
    await pump();
    expect(server!.calls.map((c) => c['body']['reasoning']), [
      {'effort': 'high'},
      {'effort': 'high'},
      {'effort': 'low'}
    ]);
  });

  for (final successAt in <int?>[2, 4, null]) {
    test('文字按主主备备尝试，第${successAt ?? "全部失败"}次结束后不再请求', () async {
      final stages = <String>[];
      server = await LocalAiServer.start((request, body) async {
        stages.add(store.services.chat.stageLabel);
        if (server!.calls.length == successAt) {
          await servePayload(request, finalPayload());
        } else {
          request.response.statusCode = 500;
          await request.response.close();
        }
      });
      await configure();
      final op = await store.records.enqueue('普通问题', [], {}, null, null);
      await pump();
      expect(
          server!.calls.map((c) => c['body']['model']),
          ['text-main', 'text-main', 'text-backup', 'text-backup']
              .take(successAt ?? 4));
      expect(stages[1], contains('重试 1/1'));
      expect(stages[1], isNot(contains('兜底')));
      if (stages.length > 2) expect(stages[2], contains('使用兜底模型'));
      expect((await store.records.row('operations', op['id']))!['status'],
          successAt == null ? 'failed' : 'completed');
    });
  }

  test('协议失败在原模型重试，HTTP授权失败也遵守四次上限', () async {
    var rejectAuth = false;
    server = await LocalAiServer.start((request, body) async {
      if (rejectAuth) {
        request.response.statusCode = 401;
        await request.response.close();
      } else {
        await servePayload(request, {
          ...finalPayload(),
          if (server!.calls.length == 1) 'protocol_version': 2,
        });
      }
    });
    await configure();
    await store.records.enqueue('协议检查', [], {}, null, null);
    await pump();
    expect(server!.calls.map((c) => c['body']['model']),
        ['text-main', 'text-main']);
    rejectAuth = true;
    final failed = await store.records.enqueue('授权失败', [], {}, null, null);
    await pump();
    expect(server!.calls.skip(2).map((c) => c['body']['model']),
        ['text-main', 'text-main', 'text-backup', 'text-backup']);
    expect((await store.records.row('operations', failed['id']))!['error_code'],
        'configuration');
  });

  test('补算主模型两次失败后，备用第二次成功只更新一次营养', () async {
    final food = foodInput(protein: null);
    food['nutrition']['protein_g']['source'] = 'unknown';
    final created =
        await store.services.committer.local(mealInput(items: [food]));
    var backfillAttempts = 0;
    server = await LocalAiServer.start((request, body) async {
      if (body['stream'] == true) {
        await servePayload(request, finalPayload());
      } else if (++backfillAttempts < 4) {
        request.response.statusCode = 500;
        await request.response.close();
      } else {
        final foods =
            jsonMap(body['input'][0]['content'][0]['text'])['foods'] as List;
        await servePayload(
            request,
            {
              'protocol_version': 1,
              'outcome': 'estimates',
              'estimates': [
                for (final f in foods)
                  {
                    'food_id': f['id'],
                    'expected_version': f['version'],
                    'values': {
                      'protein_g': {'value': 10, 'source': 'ai'}
                    }
                  }
              ]
            },
            stream: false);
      }
    });
    await configure();
    await store.records.enqueue('普通聊天', [], {}, null, null);
    await pump();
    expect(server!.calls.skip(1).map((c) => c['body']['model']),
        ['text-main', 'text-main', 'text-backup', 'text-backup']);
    final saved = (await store.records
        .row('food_items', receiptId(created, 'food_items')))!;
    expect(saved['protein_g'], 10);
    expect(saved['version'], 2);
  });

  test('改同餐两份量时格式缺字段，原模型收到校验反馈后修正且只修改原餐', () async {
    final created = await store.services.committer.local(mealInput(
        date: '2026-10-18',
        items: [
          foodInput(name: '蔬菜沙拉', calories: 140),
          foodInput(name: '干炒牛河', calories: 680)
        ]));
    final mealId = receiptId(created, 'meals');
    final foods = await store.records.foods(mealId);
    final valid = {
      'action_key': 'adjust',
      'type': 'modify_meal_contents',
      'state': 'ready',
      'meal_id': mealId,
      'expected_meal_version': 1,
      'changes': [
        for (final f in foods)
          {
            'type': 'update_food',
            'id': f['id'],
            'expected_version': 1,
            'patch': {
              'portion_text': f['name'] == '蔬菜沙拉' ? '半碗' : '两碗',
              'nutrition': foodInput(
                  calories: f['name'] == '蔬菜沙拉' ? 70 : 1360)['nutrition']
            }
          }
      ]
    };
    server = await LocalAiServer.start((request, body) async {
      final first = server!.calls.length == 1;
      if (first) {
        expect((await store.records.foods(mealId)).map((f) => f['version']),
            [1, 1]);
      } else {
        expect(body['instructions'], contains('第 1 项操作的 state'));
        expect(body['input'], server!.calls.first['body']['input']);
      }
      await servePayload(
          request,
          finalPayload(actions: [
            first ? ({...valid}..remove('state')) : valid
          ]));
    });
    await configure();
    final op = await store.records.enqueue(
        '沙拉半碗，牛河两碗',
        [],
        {
          'local_date': '2026-10-18',
          'record_table': 'meals',
          'record_id': mealId
        },
        null,
        null);
    await pump();
    expect(server!.calls.map((c) => c['body']['model']),
        ['text-main', 'text-main']);
    expect(await store.records.meals('2026-10-18'), hasLength(1));
    final updated = await store.records.foods(mealId);
    expect(updated.map((f) => f['version']), [2, 2]);
    expect(
        updated.singleWhere((f) => f['name'] == '蔬菜沙拉')['portion_text'], '半碗');
    expect(
        updated.singleWhere((f) => f['name'] == '干炒牛河')['portion_text'], '两碗');
    expect((await store.records.row('operations', op['id']))!['status'],
        'completed');
  });

  test('选中昨天后模型获得该日完整合计，空日期也不借用今天的数据', () async {
    await store.services.committer.local(
        mealInput(date: '2026-10-19', items: [foodInput(calories: 200)]));
    await store.services.committer.local(
        mealInput(date: '2026-10-20', items: [foodInput(calories: 4431)]));
    final time = DateTime(2026, 10, 20, 12);
    final reference = jsonEncode({
      'local_date': '2026-10-20',
      'local_time': '12:00',
      'timestamp_ms': time.millisecondsSinceEpoch,
      'utc_offset_minutes': time.timeZoneOffset.inMinutes
    });
    final old = await store.records
        .enqueue('之前的问题', [], {'local_date': '2026-10-19'}, null, null);
    await store.db.update(
        'operations', {'reference_time_json': reference, 'status': 'completed'},
        where: 'id=?', whereArgs: [old['id']]);
    await store.records
        .assistant(old['id'], '今天的合计', 'completed', modelReply: true);
    Json? context;
    server = await LocalAiServer.start((request, body) async {
      context =
          jsonMap(body['input'][0]['content'][0]['text'])['context'] as Json;
      await servePayload(
          request,
          finalPayload(
              reply:
                  '${context!['selected_date']}合计${context!['selected_day_totals']?['calories_kcal'] ?? 0} kcal'));
    });
    await configure({'text_backup': ''});
    final op = await store.records.enqueue('吃得算多吗？', [],
        {'local_date': '2026-10-19', 'label': '记录或查询 2026-10-19'}, null, null);
    await store.db.update('operations', {'reference_time_json': reference},
        where: 'id=?', whereArgs: [op['id']]);
    await pump();
    expect(context!['selected_date'], '2026-10-19');
    expect(context!['reference_time']['local_date'], '2026-10-20');
    expect(context!['selected_day_totals']['calories_kcal'], 200);
    final historical = (context!['recent_messages'] as List)
        .singleWhere((m) => m['body_text'] == '今天的合计');
    expect(historical['sent_date'], '2026-10-20');
    expect(historical['selected_date'], '2026-10-19');
    final reply = (await store.records.messages()).singleWhere(
        (m) => m['operation_id'] == op['id'] && m['role'] == 'assistant');
    expect(reply['model_reply_text'], '2026-10-19合计200 kcal');
    final empty = await store.records
        .enqueue('那天空吗', [], {'local_date': '2026-10-18'}, null, null);
    final emptyContext = await store.services.chat.contexts
        .build({...empty, 'reference_time_json': reference}, '那天空吗');
    expect(emptyContext['selected_date'], '2026-10-18');
    expect(emptyContext['selected_day'], isEmpty);
    expect(emptyContext['selected_day_totals']['item_count'], 0);
    expect(emptyContext['selected_day_totals']['calories_kcal'], 0);
  });

  test('牛奶别名带入资料，误标label的同款资料按库原值换算后更新原食物', () async {
    final library = await store.services.committer.local({
      'type': 'save_library',
      'kind': 'packaged_food',
      'name': '光明高温杀菌乳',
      'brand': '光明',
      'aliases': ['光明牛奶'],
      'base_portion': {'amount': 100, 'unit': '毫升'},
      'nutrition': {
        'calories_kcal': 291 / 4.184,
        'protein_g': 3.4,
        'fat_g': 3.9,
        'carbs_g': 5.2
      },
    });
    final libraryId = receiptId(library, 'food_library');
    final meal = await store.services.committer.local(mealInput(
        date: '2026-10-17', items: [foodInput(name: '光明纯牛奶', calories: 160)]));
    final milkId = receiptId(meal, 'food_items');
    server = await LocalAiServer.start((request, body) async {
      final context =
          jsonMap(body['input'][0]['content'][0]['text'])['context'];
      expect(context['library'], [
        {'ref_id': libraryId}
      ]);
      expect(context['records_by_id'][libraryId]['library_match'], 'alias');
      await servePayload(
          request,
          finalPayload(actions: [
            {
              'action_key': 'milk',
              'type': 'update_food',
              'state': 'ready',
              'id': milkId,
              'expected_version': 1,
              'patch': {
                'name': '光明高温杀菌乳',
                'portion_text': '250毫升',
                'nutrition': {
                  for (final field in nutritionFields)
                    field: {'value': 999, 'source': 'label'}
                },
                'nutrition_basis': {
                  for (final field in nutritionFields)
                    field: {
                      'base_amount': 100,
                      'base_unit': '毫升',
                      'value_per_base': 999,
                      'energy_unit': 'kJ',
                      'consumed_amount': 250,
                      'consumed_unit': '毫升'
                    }
                }
              }
            }
          ]));
    });
    await configure();
    final op = await store.records.enqueue(
        '改成光明牛奶，重新计算',
        [],
        {
          'local_date': '2026-10-17',
          'record_table': 'food_items',
          'record_id': milkId
        },
        null,
        null);
    await pump();
    final saved = (await store.records.row('food_items', milkId))!;
    expect(saved['version'], 2);
    expect(saved['calories_kcal'], 174);
    expect(saved['protein_g'], 8.5);
    expect(saved['fat_g'], 9.75);
    expect(saved['carbs_g'], 13);
    expect(
        jsonMap(saved['nutrition_sources_json']).values.toSet(), {'library'});
    expect(
        jsonMap(saved['nutrition_basis_json'])['calories_kcal']['library_id'],
        libraryId);
    expect((await store.records.row('operations', op['id']))!['status'],
        'completed');
    expect(await store.records.meals('2026-10-17'), hasLength(1));
  });

  test('思考摘要单独保存，回执不覆盖，也不加入后续模型上下文', () async {
    server = await LocalAiServer.start((request, body) async {
      request.response.headers
          .set('content-type', 'text/event-stream; charset=utf-8');
      request.response.write(sseEvent({
        'type': 'response.reasoning_summary_text.delta',
        'item_id': 'reason',
        'output_index': 0,
        'summary_index': 0,
        'delta': '测试思考摘要专用标记',
      }));
      await servePayload(request, finalPayload(reply: '正文专用标记'),
          writeHeaders: false);
    });
    await configure();
    final op = await store.records.enqueue('普通对话', [], {}, null, null);
    await pump();
    final message = (await store.records.messages())
        .singleWhere((m) => m['role'] == 'assistant');
    expect(message['reasoning_text'], contains('测试思考摘要专用标记'));
    expect(message['body_text'], isNot(contains('测试思考摘要专用标记')));
    await store.records.assistant(op['id'], '新的回执', 'completed');
    final kept = (await store.records.messages())
        .singleWhere((m) => m['role'] == 'assistant');
    expect(kept['reasoning_text'], message['reasoning_text']);
    final next = await store.records.enqueue('后续问题', [], {}, null, null);
    final context = await store.services.chat.contexts.build(next, '后续问题');
    expect(jsonEncode(context), isNot(contains('测试思考摘要专用标记')));
    final quoted = await store.records.enqueue(
        '引用这条回复', [], {'quoted_message_id': message['id']}, null, null);
    final withQuote =
        await store.services.chat.contexts.build(quoted, '引用这条回复');
    expect(jsonEncode(withQuote), isNot(contains('测试思考摘要专用标记')));
  });

  test('保存资料失败保留具体原因，回执不重复自然回复', () async {
    server =
        await LocalAiServer.start((request, body) => servePayload(request, {
              ...finalPayload(reply: '测试原回复只应出现一次'),
              'proposals': [
                {
                  'type': 'save_packaged_food',
                  'kind': 'packaged_food',
                  'name': '无图片依据的食品',
                  'source': {'type': 'label'},
                  'base_portion': {'amount': 100, 'unit': 'ml'},
                }
              ]
            }));
    await configure();
    await store.records.enqueue('保存到资料库', [], {}, null, null);
    await pump();
    final message = (await store.records.messages())
        .singleWhere((m) => m['role'] == 'assistant');
    expect('测试原回复只应出现一次'.allMatches(message['body_text'] as String).length, 1);
    expect(message['receipt_text'], contains('长期标签资料缺少唯一的图片依据'));
    expect(message['receipt_text'], isNot(contains('测试原回复只应出现一次')));
  });

  test('发图后下一条保存资料可用真实历史摘要，仍需人工确认而不自动入库', () async {
    final photo = await imageOperation();
    await store.db.update(
        'operations',
        {
          'status': 'completed',
          'vision_summary_json': jsonEncode({
            'protocol_version': 1,
            'outcome': 'recognized',
            'summary': '测试饮料标签',
            'labels': [
              {
                'product_name': '测试零度饮料',
                'brand': '测试品牌',
                'variant': '零度',
                'base_amount': 100,
                'base_unit': 'ml',
                'energy_value': 0,
                'energy_unit': 'kJ',
                'protein_g': 0,
                'fat_g': 0,
                'carbs_g': 0,
                'package_spec': null
              }
            ],
          })
        },
        where: 'id=?',
        whereArgs: [photo['id']]);
    server = await LocalAiServer.start((request, body) async {
      final context =
          jsonMap(body['input'][0]['content'][0]['text'])['context'];
      expect(context['recent_image_summaries'][0]['message_id'],
          photo['message_id']);
      await servePayload(request, {
        ...finalPayload(),
        'proposals': [
          {
            'type': 'save_packaged_food',
            'kind': 'packaged_food',
            'name': '测试零度饮料',
            'brand': '测试品牌',
            'variant': '零度',
            'label_message_id': photo['message_id'],
            'aliases': [],
            'base_portion': {'amount': 100, 'unit': '毫升'},
            'package_spec': {'amount': 330, 'unit': '毫升'},
            'source': {'type': 'label'},
          }
        ]
      });
    });
    await configure();
    await store.records.enqueue('保存这份330ml的饮料资料', [], {}, null, null);
    await pump();
    final proposals = await store.records.proposals();
    expect(proposals, hasLength(1));
    final saved = jsonMap(proposals.single['payload_json']);
    expect((saved['nutrition'] as Map).values.toSet(), {0});
    expect(saved['source']['label_message_id'], photo['message_id']);
    expect(await store.records.library(), isEmpty);
  });

  test('停止时保留已经返回的思考，不继续请求或保存动作', () async {
    final seen = Completer<void>();
    store.services.chat.addListener(() {
      if (store.services.chat.liveReasoning.isNotEmpty && !seen.isCompleted) {
        seen.complete();
      }
    });
    server = await LocalAiServer.start((request, body) async {
      request.response.headers
          .set('content-type', 'text/event-stream; charset=utf-8');
      request.response.write(sseEvent({
        'type': 'response.reasoning_summary_text.delta',
        'item_id': 'reason',
        'output_index': 0,
        'summary_index': 0,
        'delta': '停止前的测试摘要',
      }));
      await request.response.flush();
    });
    await configure();
    final op = await store.records.enqueue('等候中的对话', [], {}, null, null);
    final running = pump();
    await seen.future;
    await store.services.chat.stop();
    await running;
    final message = (await store.records.messages())
        .singleWhere((m) => m['role'] == 'assistant');
    expect(message['reasoning_text'], contains('停止前的测试摘要'));
    expect((await store.records.row('operations', op['id']))!['status'],
        'cancelled');
    expect(await store.records.actions(op['id']), isEmpty);
    expect(server!.calls, hasLength(1));
  });

  test('引用带日期的消息沿用该日，新的显式日期上下文优先', () async {
    final root = await store.records.enqueue('吃得多吗', [],
        {'local_date': '2026-10-19', 'label': '记录或查询 2026-10-19'}, null, null);
    final quote =
        (await store.records.messagesAround(root['message_id'])).single;
    await store.services.chat.send('那午餐呢', [], {}, quote, null);
    final first = (await store.records.messages())
        .singleWhere((m) => m['body_text'] == '那午餐呢');
    expect(jsonMap(first['sent_context_json'])['local_date'], '2026-10-19');
    expect(jsonMap(first['quote_snapshot_json'])['context']['local_date'],
        '2026-10-19');
    await store.services.chat
        .send('换另一天', [], {'local_date': '2026-10-20'}, quote, null);
    final next = (await store.records.messages())
        .singleWhere((m) => m['body_text'] == '换另一天');
    expect(jsonMap(next['sent_context_json'])['local_date'], '2026-10-20');
    expect(jsonMap(next['sent_context_json'])['label'], isNull);
  });

  for (final backupSucceeds in [true, false]) {
    test('识图主备共享起点，${backupSucceeds ? '完成转文字' : '均失败'}后清除进度', () async {
      final visionStarts = <DateTime?>[];
      final textStarts = <DateTime?>[];
      server = await LocalAiServer.start((request, body) async {
        if ((body['model'] as String).startsWith('vision-')) {
          visionStarts.add(store.services.chat.visionStartedAt);
          if (body['model'] == 'vision-main' || !backupSucceeds) {
            request.response.statusCode = 500;
            await request.response.close();
          } else {
            await servePayload(
                request,
                {
                  'protocol_version': 1,
                  'outcome': 'recognized',
                  'summary': '一份早餐',
                  'foods': <Json>[],
                  'labels': <Json>[],
                  'questions': <String>[]
                },
                stream: false);
          }
        } else {
          textStarts.add(store.services.chat.visionStartedAt);
          await servePayload(request, finalPayload());
        }
      });
      await configure();
      final op = await imageOperation();
      await pump();
      expect(visionStarts, hasLength(backupSucceeds ? 3 : 4));
      expect(visionStarts.first, isNotNull);
      expect(
          visionStarts.every((start) => start == visionStarts.first), isTrue);
      expect(textStarts, backupSucceeds ? [null] : isEmpty);
      expect(store.services.chat.visionStartedAt, isNull);
      expect((await store.records.row('operations', op['id']))!['status'],
          backupSucceeds ? 'completed' : 'failed');
    });
  }

  test('识图中停止会清除进度，未完成响应不生成摘要', () async {
    final arrived = Completer<void>();
    server = await LocalAiServer.start((request, body) async {
      arrived.complete();
    });
    await configure();
    final op = await imageOperation();
    final running = pump();
    await arrived.future;
    expect(store.services.chat.visionStartedAt, isNotNull);
    await store.services.chat.stop();
    await running;
    expect(store.services.chat.visionStartedAt, isNull);
    final saved = (await store.records.row('operations', op['id']))!;
    expect(saved['status'], 'cancelled');
    expect(saved['vision_summary_json'], isNull);
  });

  test('前条主备失败后继续独立后条，不永久阻塞队列', () async {
    server = await LocalAiServer.start((request, body) async {
      final text = jsonMap(body['input'][0]['content'][0]['text'])['user_text'];
      if (text == '第一条') {
        request.response.statusCode = 500;
        await request.response.close();
      } else {
        await servePayload(request, finalPayload(reply: '第二条回复'));
      }
    });
    await configure();
    final first = await store.records.enqueue('第一条', [], {}, null, null);
    final next = await store.records.enqueue('第二条', [], {}, null, null);
    await pump();
    expect(server!.calls.map((c) => c['body']['model']).toList(),
        ['text-main', 'text-main', 'text-backup', 'text-backup', 'text-main']);
    expect((await store.records.row('operations', first['id']))!['status'],
        'failed');
    expect((await store.records.row('operations', next['id']))!['status'],
        'completed');
    expect(await store.records.pendingOperations(), isEmpty);
    expect(store.services.chat.activeOperationId, isNull);
  });

  test('主模型失败、兜底成功只保存一份餐和一条最终回复', () async {
    final reasons = <String>[];
    store.services.chat.addListener(() {
      final reason = store.services.chat.fallbackReason;
      if (reason != null) reasons.add(reason);
    });
    server = await LocalAiServer.start((request, body) async {
      if (body['model'] == 'text-main') {
        request.response.statusCode = 500;
        await request.response.close();
      } else {
        await servePayload(
            request,
            finalPayload(actions: [
              {...mealInput(), 'action_key': 'meal', 'state': 'ready'}
            ]));
      }
    });
    await configure();
    final op = await store.records.enqueue('早餐', [], {}, null, null);
    await pump();
    expect(await store.records.meals('2026-10-20'), hasLength(1));
    expect(
        await store.db.query('chat_messages',
            where: "operation_id=? AND role='assistant'",
            whereArgs: [op['id']]),
        hasLength(1));
    expect(server!.calls, hasLength(3));
    expect(reasons, contains('AI 服务请求失败（HTTP 500）'));
    expect(store.services.chat.fallbackReason, isNull);
  });

  test('主模型完整响应后长连接未关闭，不调用兜底、不覆盖自然回复', () async {
    server = await LocalAiServer.start((request, body) => servePayload(
        request,
        finalPayload(reply: '早餐搭配不错，已帮你记下。', actions: [
          {...mealInput(), 'action_key': 'meal', 'state': 'ready'}
        ]),
        closeResponse: false));
    await configure();
    final op = await store.records.enqueue('早餐', [], {}, null, null);
    await pump().timeout(const Duration(seconds: 5));
    expect(server!.calls.map((c) => c['body']['model']), ['text-main']);
    expect(await store.records.meals('2026-10-20'), hasLength(1));
    final message = (await store.db.query('chat_messages',
            where: "operation_id=? AND role='assistant'",
            whereArgs: [op['id']]))
        .single;
    expect(message['model_reply_text'], '早餐搭配不错，已帮你记下。');
    expect(message['receipt_text'], contains('记录已更新'));
    expect(message['record_refs_json'], isNotNull);
  });

  test('有效本地计划重试不调用模型，也不重复已成功项', () async {
    final op = await store.records.enqueue('早餐和体重', [], {}, null, null);
    final actions = await store.services.committer.savePlan(op['id'], [
      {...mealInput(), 'action_key': 'meal', 'state': 'ready'},
      {...weightInput(), 'action_key': 'weight', 'state': 'ready'}
    ]);
    await store.services.committer.commit(actions.first['id']);
    await store.services.committer
        .fail(actions.last['id'], const AppError('暂时写入失败'));
    await store.services.committer.settle(op['id']);
    await store.services.chat.retry(op['id']);
    await pump();
    expect(await store.records.meals('2026-10-20'), hasLength(1));
    expect(await store.records.weights(), hasLength(1));
    expect((await store.records.row('operations', op['id']))!['status'],
        'completed');
    await expectLater(
        store.services.chat.retry(op['id']), throwsA(isA<AppError>()));
  });

  test('补充回答更新原卡片，原回复和本次自然回复各自保留', () async {
    var clarification = true;
    server = await LocalAiServer.start((request, body) async {
      await servePayload(
          request,
          clarification
              ? finalPayload(reply: '这餐是哪一种食物？', actions: [
                  {
                    'type': 'create_meal',
                    'action_key': 'meal',
                    'state': 'clarify',
                    'question': '请补充食物名称'
                  }
                ])
              : finalPayload(reply: '明白，是水煮蛋，我按这份记录。', actions: [
                  {
                    ...mealInput(items: [foodInput(name: '水煮蛋')]),
                    'action_key': 'meal',
                    'state': 'ready'
                  }
                ]));
    });
    await configure();
    final root = await store.records.enqueue('吃了一碗', [], {}, null, null);
    await pump();
    final action = (await store.records.actions(root['id'])).single;
    expect(action['status'], 'waiting_input');
    clarification = false;
    final answer =
        await store.records.enqueue('水煮蛋', [], {}, null, action['id']);
    await pump();
    final replies =
        await store.db.query('chat_messages', where: "role='assistant'");
    expect(
        replies.singleWhere(
            (m) => m['operation_id'] == root['id'])['model_reply_text'],
        '这餐是哪一种食物？');
    final message =
        replies.singleWhere((m) => m['operation_id'] == answer['id']);
    expect(message['model_reply_text'], '明白，是水煮蛋，我按这份记录。');
    expect(message['receipt_text'], '已结合你的补充处理原事项。');
    expect(await store.records.meals('2026-10-20'), hasLength(1));
    expect((await store.records.actions(root['id'])).single['status'],
        'committed');
  });

  test('失败消息手动接管仍关联原 operation，异常退出释放占用后可再保存', () async {
    final op = await store.records.enqueue('早餐', [], {}, null, null);
    await store.records.operationState(op['id'], 'failed');
    await expectLater(
        store.services.chat.manualSave(
            operationId: op['id'],
            save: () async => throw const AppError('受控失败')),
        throwsA(isA<AppError>()));
    expect(
        jsonMap((await store.records
                .row('operations', op['id']))!['context_json'])
            .containsKey('manual_action_id'),
        isFalse);
    await store.services.chat.manualSave(
        operationId: op['id'],
        save: () async {
          await expectLater(
              store.services.committer.savePlan(op['id'], [
                {...mealInput(), 'action_key': 'unexpected', 'state': 'ready'}
              ]),
              throwsA(isA<AppError>()));
          return store.services.committer
              .local(mealInput(), sourceOperationId: op['id']);
        });
    expect(await store.records.actions(op['id']), hasLength(1));
    expect((await store.records.row('operations', op['id']))!['status'],
        'completed');
    expect(await store.records.meals('2026-10-20'), hasLength(1));
    await expectLater(
        store.services.chat
            .manualSave(operationId: op['id'], save: () async {}),
        throwsA(isA<AppError>()));
  });

  test('停止当前请求后继续后条；未完成响应不产生记录', () async {
    final arrived = Completer<void>();
    server = await LocalAiServer.start((request, body) async {
      final text = jsonMap(body['input'][0]['content'][0]['text'])['user_text'];
      if (text == '等待停止') {
        arrived.complete();
        return;
      }
      await servePayload(
          request,
          finalPayload(actions: [
            {...mealInput(), 'action_key': 'meal', 'state': 'ready'}
          ]));
    });
    await configure();
    final first = await store.records.enqueue('等待停止', [], {}, null, null);
    final next = await store.records.enqueue('后续消息', [], {}, null, null);
    final running = pump();
    await arrived.future;
    await store.services.chat.stop();
    await running;
    expect((await store.records.row('operations', first['id']))!['status'],
        'cancelled');
    expect((await store.records.row('operations', next['id']))!['status'],
        'completed');
    expect(await store.records.meals('2026-10-20'), hasLength(1));
  });

  test('停止已有部分提交的事项保留成功项，只取消未完成项', () async {
    final op = await store.records.enqueue('早餐和体重', [], {}, null, null);
    final actions = await store.services.committer.savePlan(op['id'], [
      {...mealInput(), 'action_key': 'meal', 'state': 'ready'},
      {...weightInput(), 'action_key': 'weight', 'state': 'ready'}
    ]);
    await store.services.committer.commit(actions.first['id']);
    store.services.chat.activeOperationId = op['id'];
    await store.services.chat.stop();
    expect(
        (await store.records.actions(op['id']))
            .map((a) => a['status'])
            .toList(),
        ['committed', 'cancelled']);
    expect((await store.records.row('operations', op['id']))!['status'],
        'partial');
    expect(await store.records.meals('2026-10-20'), hasLength(1));
    expect(await store.records.weights(), isEmpty);
  });

  test('图片摘要已保存后重试只调用文字模型，兼容旧版已清理的图片', () async {
    server = await LocalAiServer.start(
        (request, body) => servePayload(request, finalPayload()));
    await configure();
    final op = await store.records.enqueue('早餐图片', [], {}, null, null);
    final summary = {
      'protocol_version': 1,
      'outcome': 'recognized',
      'summary': '一份早餐',
      'foods': <Json>[],
      'labels': <Json>[],
      'questions': <String>[]
    };
    await store.db.update('chat_messages', {'image_count': 1},
        where: 'id=?', whereArgs: [op['message_id']]);
    await store.db.update('operations',
        {'status': 'failed', 'vision_summary_json': jsonEncode(summary)},
        where: 'id=?', whereArgs: [op['id']]);
    await store.services.chat.retry(op['id']);
    await pump();
    expect(server!.calls.single['body']['model'], 'text-main');
    expect((await store.records.row('operations', op['id']))!['status'],
        'completed');
  });

  test('恢复前挂起会取消旧请求，旧任务不能在新 dataEpoch 下提交', () async {
    final arrived = Completer<void>();
    server = await LocalAiServer.start((request, body) async {
      arrived.complete();
    });
    await configure();
    await store.records.enqueue('旧请求', [], {}, null, null);
    final running = pump();
    await arrived.future;
    final epoch = store.services.chat.dataEpoch;
    await store.services.chat.suspend();
    await running;
    expect(store.services.chat.dataEpoch, greaterThan(epoch));
    expect(store.services.chat.activeOperationId, isNull);
    expect(await store.db.query('food_items'), isEmpty);
  });
}
