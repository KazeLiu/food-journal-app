import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/core/data.dart';

void main() {
  group('体重换算', () {
    test('斤和公斤统一存整数克，保留两位小数输入', () {
      expect(weightGrams('132', 'jin'), 66000);
      expect(weightGrams('66', 'kg'), 66000);
      expect(weightGrams('132.01', 'jin'), 66005);
      expect(weightGrams('66.01', 'kg'), 66010);
      expect(weightGrams('0.01', 'jin'), 5);
    });
    for (final input in ['0', '-1', '1.001', 'NaN', '1e2', '', ' 66 ']) {
      test('拒绝无效体重 "$input"', () {
        expect(() => weightGrams(input, 'kg'), throwsA(isA<AppError>()));
      });
    }
    test('拒绝未支持的单位', () {
      expect(() => weightGrams('66', 'lb'), throwsA(isA<AppError>()));
    });
  });

  group('日期与发生时间', () {
    test('时段直接保留，不换算为精确时间戳；无时间只显示日期', () {
      for (final period in timePeriods) {
        expect(() => validateDate('2026-10-19', period), returnsNormally);
        final row =
            timeColumns({'local_date': '2026-10-19', 'local_time': period}, {});
        expect(row['local_time'], period);
        expect(row['occurred_at_ms'], isNull);
        expect(row['utc_offset_minutes'], isNull);
        expect(recordDateTime(row), '2026-10-19 · $period');
      }
      expect(recordDateTime({'local_date': '2026-10-19', 'local_time': null}),
          '2026-10-19');
      expect(
          () => validateDate('2026-10-19', '随便一个时刻'), throwsA(isA<AppError>()));
    });
    test('合法闰日和未知时刻可用', () {
      expect(() => validateDate('2024-02-29', null), returnsNormally);
      expect(() => validateDate('2026-10-19', '23:59'), returnsNormally);
    });
    for (final date in [
      '2026-02-29',
      '2026-04-31',
      '2026-1-01',
      '0000-01-01'
    ]) {
      test('拒绝无效日期 $date，不接受 DateTime 自动溢出修正', () {
        expect(() => validateDate(date, null), throwsA(isA<AppError>()));
      });
    }
    for (final time in ['24:00', '12:60', '9:05', '12:30:00']) {
      test('拒绝无效时刻 $time', () {
        expect(
            () => validateDate('2026-10-19', time), throwsA(isA<AppError>()));
      });
    }
    test('未注明时刻不伪造时间戳或时区偏移', () {
      expect(
          timeColumns({'local_date': '2026-10-18', 'local_time': null},
              {'utc_offset_minutes': -240}),
          {
            'local_date': '2026-10-18',
            'local_time': null,
            'occurred_at_ms': null,
            'utc_offset_minutes': null
          });
    });
    test('换算使用提交时的时区偏移，跨 UTC 午夜仍保留发生日期', () {
      final result = timeColumns(
          {'local_date': '2026-10-18', 'local_time': '23:30'},
          {'utc_offset_minutes': -240});
      expect(result['local_date'], '2026-10-18');
      expect(result['occurred_at_ms'],
          DateTime.utc(2026, 10, 19, 3, 30).millisecondsSinceEpoch);
    });
  });

  group('营养空值与来源', () {
    test('真实零值和未知空值都合法，但含义不同', () {
      expect(() => validateNutrient('fat_g', {'value': 0, 'source': 'user'}),
          returnsNormally);
      expect(
          () => validateNutrient('fat_g', {'value': null, 'source': 'unknown'}),
          returnsNormally);
    });
    for (final value in <Json>[
      {'value': null, 'source': 'ai'},
      {'value': 0, 'source': 'unknown'},
      {'value': -1, 'source': 'user'},
      {'value': double.nan, 'source': 'ai'},
      {'value': double.infinity, 'source': 'ai'},
      {'value': 2, 'source': 'internet'},
      {'source': 'unknown'},
    ]) {
      test('拒绝无效数值或来源 $value', () {
        expect(() => validateNutrient('protein_g', value),
            throwsA(isA<AppError>()));
      });
    }
    test('热量只能是整数，克数可保留小数', () {
      expect(
          () => validateNutrient(
              'calories_kcal', {'value': 25.5, 'source': 'ai'}),
          throwsA(isA<AppError>()));
      expect(
          () =>
              validateNutrient('protein_g', {'value': 2.5, 'source': 'label'}),
          returnsNormally);
    });
    test('拒绝额外营养字段', () {
      expect(() => validateNutrient('sugar_g', {'value': 0, 'source': 'user'}),
          throwsA(isA<AppError>()));
    });
  });

  test('重试 scope 保留事项身份与描述，不保留可执行 patch 或营养数值', () {
    final scope = actionScope({
      'type': 'update_food',
      'id': 'food-1',
      'meal_id': 'meal-1',
      'expected_version': 3,
      'raw_description': '那碗只吃了一半',
      'patch': {'portion_text': '半碗', 'calories_kcal': 200},
      'items': [
        {'name': '米饭', 'portion_text': '半碗', 'calories_kcal': 200}
      ]
    });
    expect(scope, {
      'type': 'update_food',
      'id': 'food-1',
      'meal_id': 'meal-1',
      'raw_description': '那碗只吃了一半',
      'foods': [
        {'name': '米饭', 'portion_text': '半碗'}
      ]
    });
  });
}
