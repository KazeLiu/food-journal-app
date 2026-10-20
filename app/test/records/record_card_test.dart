import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/core/data.dart';
import 'package:food_journal/core/theme.dart';
import 'package:food_journal/records/record_card.dart';

Json _food(Json basis) => {
      'name': '早餐食物',
      'portion_text': '一份',
      'calories_kcal': 160,
      'protein_g': 5.0,
      'fat_g': 1.2,
      'carbs_g': 26.0,
      'nutrition_sources_json':
          jsonEncode({for (final field in nutritionFields) field: 'ai'}),
      'nutrition_basis_json': jsonEncode(basis),
      'estimation_note': '按常见早餐份量估算',
      'note': null
    };

void main() {
  testWidgets('已保存的字符串依据可打开详情并展开，不会把 String 强制转 Map', (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: journalTheme(true),
        home: Scaffold(
            body: ListView(children: [
          FoodNutrition(
              _food({
                'calories_kcal': '按常见食物和一份早餐估算',
                'protein_g': '主要来自鸡蛋',
                'fat_g': '包含常见烹调用油',
                'carbs_g': '按主食份量估算'
              }),
              detailed: true)
        ]))));
    expect(find.text('早餐食物'), findsOneWidget);
    expect(find.text('蛋白质 5 g · AI 估算'), findsOneWidget);
    expect(find.text('脂肪 1.2 g · AI 估算'), findsOneWidget);
    expect(find.text('碳水 26 g · AI 估算'), findsOneWidget);
    await tester.tap(find.text('估算与来源依据'));
    await tester.pumpAndSettle();
    expect(find.text('热量：按常见食物和一份早餐估算'), findsOneWidget);
    expect(find.text('蛋白质：主要来自鸡蛋'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('结构化依据、热量区间和空依据仍可展示', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListView(children: [
      FoodNutrition(
          _food({
            'calories_kcal': {
              'note': '按一份估算',
              'lower_kcal': 140,
              'upper_kcal': 180
            },
            'protein_g': {
              'base_amount': 100,
              'base_unit': 'g',
              'value_per_base': 10,
              'consumed_amount': 50,
              'consumed_unit': 'g'
            },
            'fat_g': null,
            'carbs_g': null
          }),
          detailed: true)
    ]))));
    await tester.tap(find.text('估算与来源依据'));
    await tester.pumpAndSettle();
    expect(find.text('热量：按一份估算；参考区间 140–180 kcal'), findsOneWidget);
    expect(find.textContaining('每 100 g 含 10，本次 50 g'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('缺失营养与真实零值分别统计，卡片不将未知说成完整合计', () {
    final items = <Json>[
      {'calories_kcal': null, 'protein_g': null, 'fat_g': 0, 'carbs_g': 0},
      {'calories_kcal': 100, 'protein_g': 5, 'fat_g': null, 'carbs_g': 10}
    ];
    final totals = sumItems(items);
    expect(totals['calories_kcal'], 100);
    expect(totals['missing_calories_kcal'], 1);
    expect(totals['missing_fat_g'], 1);
    expect(totals['missing_carbs_g'], 0);
    expect(calorieText(totals), '已记录约 100 kcal');
    expect(calorieText(sumItems([])), '还没有饮食记录');
    expect(calorieText(sumItems([items.first])), '热量待估算');
  });
}
