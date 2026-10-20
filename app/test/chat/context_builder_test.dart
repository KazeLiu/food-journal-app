import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/chat/context_builder.dart';
import 'package:food_journal/core/data.dart';
import 'package:food_journal/records/record_repository.dart';
import 'package:food_journal/settings/settings_repository.dart';

// 本文件只覆盖无 I/O 的协议边界；意外访问仓库或配置时应直接失败。
class _NoRecords implements RecordRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('协议单元测试不应访问仓库：${invocation.memberName}');
}

class _NoSettings implements SettingsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('协议单元测试不应访问配置：${invocation.memberName}');
}

Json _envelope(
        {String outcome = 'final',
        List<Json> actions = const [],
        List<Json> queries = const []}) =>
    {
      'protocol_version': 1,
      'outcome': outcome,
      'reply': '正在整理',
      'queries': queries,
      'actions': actions,
      'proposals': <Json>[]
    };

Json _foodPatch() => {
      'action_key': 'a1',
      'state': 'ready',
      'type': 'update_food',
      'id': 'food-1',
      'expected_version': 1,
      'patch': {'portion_text': '半碗'}
    };

Json _labelAction(num energy) => {
      'nutrition': {
        'calories_kcal': {'value': 100, 'source': 'label'}
      },
      'nutrition_basis': {
        'calories_kcal': {
          'base_amount': 100,
          'base_unit': 'g',
          'value_per_base': energy,
          'energy_unit': 'kJ',
          'consumed_amount': 100,
          'consumed_unit': 'g'
        }
      }
    };

void main() {
  late ContextBuilder builder;
  setUp(() => builder = ContextBuilder(_NoRecords(), _NoSettings()));

  group('完整协议边界', () {
    test('普通聊天的空动作协议有效', () {
      expect(() => builder.validateEnvelope(_envelope(), lookupAllowed: true),
          returnsNormally);
    });
    test('重复 action_key 被拒绝，防止计划映射覆盖', () {
      expect(
          () => builder.validateEnvelope(
              _envelope(actions: [_foodPatch(), _foodPatch()]),
              lookupAllowed: true),
          throwsA(isA<AppError>()));
    });
    for (final field in ['action_key', 'type', 'state']) {
      test('动作缺少 $field 时指出具体字段，不能猜测后保存', () {
        final action = _foodPatch()..remove(field);
        expect(
            () => builder.validateEnvelope(_envelope(actions: [action])),
            throwsA(isA<AppError>()
                .having((e) => e.message, 'message', contains(field))));
      });
    }
    test('查询结果轮不允许再发第二轮 lookup', () {
      final response = _envelope(outcome: 'lookup', queries: [
        {'query_id': 'q1', 'type': 'find_food', 'keyword': '面', 'limit': 10}
      ]);
      expect(() => builder.validateEnvelope(response, lookupAllowed: true),
          returnsNormally);
      expect(() => builder.validateEnvelope(response, lookupAllowed: false),
          throwsA(isA<AppError>()));
    });
    test('lookup 不可同时执行写入动作', () {
      expect(
          () => builder.validateEnvelope(
              _envelope(outcome: 'lookup', queries: [
                {'query_id': 'q1', 'type': 'find_food'}
              ], actions: [
                _foodPatch()
              ]),
              lookupAllowed: true),
          throwsA(isA<AppError>()));
    });
  });

  group('操作与目标校验', () {
    test('给定真实 ID 的修改合法，缺版本被拒绝', () {
      expect(() => builder.validateAction(_foodPatch(), {'food-1'}),
          returnsNormally);
      final missingVersion = _foodPatch()..remove('expected_version');
      expect(() => builder.validateAction(missingVersion, {'food-1'}),
          throwsA(isA<AppError>()));
    });
    test('拒绝未提供的真实 ID 和越权字段', () {
      expect(() => builder.validateAction(_foodPatch(), {'different-food'}),
          throwsA(isA<AppError>()));
      final change = _foodPatch()..['patch'] = {'meal_id': 'meal-1'};
      expect(() => builder.validateAction(change, {'food-1', 'meal-1'}),
          throwsA(isA<AppError>()));
    });
    test('拒绝空餐和同一食物的重复餐内修改', () {
      expect(
          () => builder.validateAction({
                'type': 'create_meal',
                'state': 'ready',
                'client_ref': 'new-meal',
                'local_date': '2026-10-19',
                'local_time': null,
                'meal_type': 'lunch',
                'raw_description': '午餐',
                'items': <Json>[]
              }, {}),
          throwsA(isA<AppError>()));
      expect(
          () => builder.validateAction({
                'type': 'modify_meal_contents',
                'state': 'ready',
                'meal_id': 'meal-1',
                'expected_meal_version': 1,
                'changes': [
                  {
                    'type': 'delete_food',
                    'id': 'food-1',
                    'expected_version': 1
                  },
                  {'type': 'delete_food', 'id': 'food-1', 'expected_version': 1}
                ]
              }, {
                'meal-1',
                'food-1'
              }),
          throwsA(isA<AppError>()));
    });
    test('追问必须有问题，候选 ID 仍须来自上下文', () {
      final clarify = {
        'type': 'update_food',
        'state': 'clarify',
        'question': '你指哪一碗？',
        'candidates': [
          {'type': 'food', 'id': 'food-1'}
        ]
      };
      expect(
          () => builder.validateAction(clarify, {'food-1'}), returnsNormally);
      expect(
          () => builder.validateAction(clarify, {}), throwsA(isA<AppError>()));
    });
  });

  test('同一实体只传一份完整值，ref_id 仍可解析为合法操作目标', () {
    final row = {'id': 'food-1', 'name': '米饭', 'version': 2};
    final context = builder.normalize({
      'recent_foods': [row],
      'quoted': row
    });
    expect(context['recent_foods'], [
      {'ref_id': 'food-1'}
    ]);
    expect(context['quoted'], {'ref_id': 'food-1'});
    expect(context['records_by_id'], {'food-1': row});
    expect(builder.allowedIds(context), {'food-1'});
  });

  group('标签原始证据', () {
    final summary = <String, dynamic>{
      'labels': [
        {
          'base_amount': 100,
          'base_unit': 'g',
          'energy_value': 418.4,
          'energy_unit': 'kJ'
        }
      ]
    };
    test('接受本次清晰标签，不接受模型编造的标签数字', () {
      expect(
          () => builder.validateLabelSources(_labelAction(418.4), {}, summary),
          returnsNormally);
      expect(() => builder.validateLabelSources(_labelAction(900), {}, summary),
          throwsA(isA<AppError>()));
    });
    test('补图没有新标签时，仍可使用 previous_summary 的原标签', () {
      expect(
          () => builder.validateLabelSources(_labelAction(418.4), {},
              {'labels': <Json>[], 'previous_summary': summary}),
          returnsNormally);
    });
    test('无原始证据时拒绝 label 来源', () {
      expect(() => builder.validateLabelSources(_labelAction(418.4), {}, null),
          throwsA(isA<AppError>()));
    });
  });

  group('食品资料候选与来源', () {
    Json library(String id,
            {String name = '光明高温杀菌乳', List<String> aliases = const ['光明牛奶']}) =>
        {
          'id': id,
          'name': name,
          'brand': '光明',
          'version': 1,
          'aliases_json': jsonEncode(aliases),
          'base_portion_json': jsonEncode({'amount': 100, 'unit': '毫升'}),
          'nutrition_json': jsonEncode({
            'calories_kcal': 291 / 4.184,
            'protein_g': 3.4,
            'fat_g': 3.9,
            'carbs_g': 5.2
          }),
        };
    test('别名命中排在品牌候选之前，口语品牌表达也能带入候选', () {
      final rows = [
        for (var i = 0; i < 12; i++)
          library('other-$i', name: '光明其他产品$i', aliases: []),
        library('milk')
      ];
      final alias = ContextBuilder.libraryCandidates(rows, '光明牛奶，重新算一下');
      expect(alias.first['id'], 'milk');
      expect(alias.first['library_match'], 'alias');
      final brand =
          ContextBuilder.libraryCandidates([library('milk')], '喝了光明的纯牛奶');
      expect(brand.single['library_match'], 'brand');
      expect(ContextBuilder.libraryCandidates(rows, '完全不相关'), isEmpty);
    });
    test('同款库数据误标label时改为library，不放行未知产品或不明食用量', () {
      Json action(String name, {String unit = '毫升'}) => {
            'name': name,
            'nutrition': {
              'calories_kcal': {'value': 174, 'source': 'label'}
            },
            'nutrition_basis': {
              'calories_kcal': {
                'base_amount': 100,
                'base_unit': '毫升',
                'value_per_base': 291,
                'energy_unit': 'kJ',
                'consumed_amount': 250,
                'consumed_unit': unit,
              }
            },
          };
      final context = builder.normalize({
        'library': [library('milk')]
      });
      final value = action('光明牛奶');
      builder.validateLabelSources(value, context, null);
      expect(value['nutrition']['calories_kcal']['source'], 'library');
      expect(value['nutrition_basis']['calories_kcal']['library_id'], 'milk');
      expect(
          () => builder.validateLabelSources(action('其他品牌牛奶'), context, null),
          throwsA(isA<AppError>()));
      expect(
          () => builder.validateLabelSources(
              action('光明牛奶', unit: '盒'), context, null),
          throwsA(isA<AppError>()));
      final ambiguous = builder.normalize({
        'library': [library('milk'), library('other')]
      });
      expect(
          () => builder.validateLabelSources(action('光明牛奶'), ambiguous, null),
          throwsA(isA<AppError>()));
    });
  });

  test('后续保存包装资料可引用历史图片，保留零值、原标签和独立包装规格', () async {
    final context = <String, dynamic>{
      'recent_image_summaries': [
        {
          'message_id': 'cola-photo',
          'summary': {
            'labels': [
              {
                'product_name': '零度可口可乐',
                'brand': '可口可乐',
                'variant': '零度',
                'base_amount': 100,
                'base_unit': 'ml',
                'energy_value': 0,
                'energy_unit': 'kJ',
                'protein_g': 0,
                'fat_g': 0,
                'carbs_g': 0,
                'package_spec': null,
              }
            ]
          }
        }
      ]
    };
    Json proposal() => {
          'type': 'save_packaged_food',
          'kind': 'packaged_food',
          'name': '零度可口可乐',
          'brand': '可口可乐',
          'variant': '零度',
          'label_message_id': 'cola-photo',
          'base_portion': {'amount': 100, 'unit': '毫升'},
          'package_spec': {'amount': 330, 'unit': 'ml'},
          'source': {'type': 'label'},
        };
    final value = proposal();
    await builder.applyPackageLabel(value, null, context: context);
    expect((value['nutrition'] as Map).values.toSet(), {0});
    expect(value['source']['label_message_id'], 'cola-photo');
    expect(value['source']['label']['base_unit'], 'ml');
    expect(value['package_spec']['amount'], 330);
    await expectLater(
        builder.applyPackageLabel(
            {...proposal(), 'label_message_id': 'unknown'}, null,
            context: context),
        throwsA(isA<AppError>()));
    final wrongUnit = proposal()
      ..['base_portion'] = {'amount': 100, 'unit': 'g'};
    await expectLater(
        builder.applyPackageLabel(wrongUnit, null, context: context),
        throwsA(isA<AppError>()));
  });
}
