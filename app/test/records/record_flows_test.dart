import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/core/data.dart';
import 'package:food_journal/core/theme.dart';
import 'package:food_journal/records/editors.dart';
import 'package:food_journal/records/record_card.dart';

import '../support/test_store.dart';

Finder _field(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label);

Future<void> _open(WidgetTester tester, Widget Function() page) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 932);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      theme: journalTheme(true),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => page())),
                  child: const Text('打开页面'))))));
  await tester.tap(find.text('打开页面'));
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  late TestStore store;
  setUp(() async => store = await TestStore.create());
  tearDown(() async => store.close());

  testWidgets('手动新增饮食默认打开表单时的当前时间，保存后不丢失', (tester) async {
    final before = clockTime(DateTime.now());
    await _open(tester, () => MealEditor(store.services, date: '2026-10-20'));
    final time =
        tester.widget<DateTimeFields>(find.byType(DateTimeFields)).time;
    expect([before, clockTime(DateTime.now())], contains(time));
    await tester.enterText(_field('名称（必填）'), '早餐');
    await _tapVisible(tester, '保存这餐');
    expect(
        (await store.records.meals('2026-10-20')).single['local_time'], time);
  });

  testWidgets('手动新增体重默认当前时间，仍可明确清空只记日期', (tester) async {
    final before = clockTime(DateTime.now());
    await _open(
        tester,
        () => WeightEditor(store.services,
            date: '2026-10-20', defaultUnit: 'jin'));
    final time =
        tester.widget<DateTimeFields>(find.byType(DateTimeFields)).time;
    expect([before, clockTime(DateTime.now())], contains(time));
    await tester.enterText(_field('体重'), '132');
    await _tapVisible(tester, '保存这次体重');
    expect((await store.records.weights()).single['local_time'], time);
    await _open(
        tester,
        () => WeightEditor(store.services,
            date: '2026-10-20', defaultUnit: 'jin'));
    await tester.tap(find.byTooltip('清除时间'));
    await tester.pumpAndSettle();
    await tester.enterText(_field('体重'), '131');
    await _tapVisible(tester, '保存这次体重');
    expect(
        (await store.records.weights())
            .singleWhere((w) => w['input_value'] == '131')['local_time'],
        isNull);
  });

  testWidgets('编辑旧记录不自动改时间，上午下午可以打开时间选择器', (tester) async {
    await store.services.committer.local({...mealInput(), 'local_time': '下午'});
    final meal = (await store.records.meals('2026-10-20')).single;
    await _open(tester,
        () => MealEditor(store.services, date: '2026-10-20', meal: meal));
    expect(
        tester.widget<DateTimeFields>(find.byType(DateTimeFields)).time, '下午');
    await tester.tap(find.text('发生时间'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await _tapVisible(tester, '保存这餐');
    expect(
        (await store.records.meals('2026-10-20')).single['local_time'], '下午');
    expect(tester.takeException(), isNull);
  });

  testWidgets('实际详情入口读取旧字符串依据，不阻断展开、来源和操作按钮', (tester) async {
    final receipt = await store.services.committer.local(mealInput(items: [
      foodInput(source: 'ai', calories: 160, protein: 5, fat: 1.2, carbs: 26)
    ]));
    final foodId = receiptId(receipt, 'food_items');
    await store.db.update(
        'food_items',
        {
          'nutrition_basis_json': jsonEncode(
              {for (final field in nutritionFields) field: '旧版本保存的说明文字'})
        },
        where: 'id=?',
        whereArgs: [foodId]);
    await _open(tester,
        () => RecordDetail(store.services, table: 'food_items', id: foodId));
    expect(find.text('记录详情'), findsOneWidget);
    expect(find.text('早餐'), findsOneWidget);
    await _tapVisible(tester, '估算与来源依据');
    expect(find.text('热量：旧版本保存的说明文字'), findsOneWidget);
    final more = find.byTooltip('更多操作');
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.tap(find.text('直接编辑'));
    await tester.pumpAndSettle();
    expect(find.text('编辑这餐'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空名称保存给出可恢复提示，补全后正常保存退出，不锁死按钮', (tester) async {
    await _open(tester, () => MealEditor(store.services, date: '2026-10-20'));
    await _tapVisible(tester, '保存这餐');
    expect(find.text('食物名称不能为空'), findsOneWidget);
    expect(await store.records.meals('2026-10-20'), isEmpty);
    await tester.ensureVisible(_field('名称（必填）'));
    await tester.enterText(_field('名称（必填）'), '牛肉面');
    await _tapVisible(tester, '保存这餐');
    expect(find.text('打开页面'), findsOneWidget);
    expect(find.text('放弃未保存的内容？'), findsNothing);
    final meal = (await store.records.meals('2026-10-20')).single;
    expect((meal['items'] as List).single['calories_kcal'], isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('表单返回先确认，取消继续编辑，放弃后可退出', (tester) async {
    await _open(tester, () => MealEditor(store.services, date: '2026-10-20'));
    await tester.enterText(_field('名称（必填）'), '未保存内容');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的内容？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(_field('名称（必填）')).controller!.text, '未保存内容');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();
    expect(find.text('打开页面'), findsOneWidget);
    expect(await store.records.meals('2026-10-20'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑食物身份清空旧营养，保存后原 ID 不变且详情仍可打开', (tester) async {
    final receipt = await store.services.committer.local(mealInput());
    final original = (await store.records.meals('2026-10-20')).single;
    await _open(tester,
        () => MealEditor(store.services, date: '2026-10-20', meal: original));
    await tester.enterText(_field('名称（必填）'), '炒面');
    await tester.pump();
    expect(
        tester.widget<TextField>(_field('热量（未知留空）')).controller!.text, isEmpty);
    await _tapVisible(tester, '保存这餐');
    final food = (await store.records
        .row('food_items', receiptId(receipt, 'food_items')))!;
    expect(food['name'], '炒面');
    expect(food['calories_kcal'], isNull);
    expect(jsonMap(food['nutrition_sources_json'])['calories_kcal'], 'unknown');
    expect(await store.records.meals('2026-10-20'), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入中的多食物删除一项不破坏保留项或使用已释放控制器', (tester) async {
    await _open(tester, () => MealEditor(store.services, date: '2026-10-20'));
    tester.view.physicalSize = const Size(430, 1600);
    await tester.pumpAndSettle();
    await tester.enterText(_field('名称（必填）'), '要删除的食物');
    await _tapVisible(tester, '再加一种食物');
    await tester.ensureVisible(_field('名称（必填）').last);
    await tester.enterText(_field('名称（必填）').last, '要保留的食物');
    final remove = find.byTooltip('移除这项食物').first;
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(_field('名称（必填）'), findsOneWidget);
    expect(
        tester.widget<TextField>(_field('名称（必填）')).controller!.text, '要保留的食物');
    await _tapVisible(tester, '保存这餐');
    final items =
        (await store.records.meals('2026-10-20')).single['items'] as List;
    expect(items.single['name'], '要保留的食物');
    expect(tester.takeException(), isNull);
  });

  testWidgets('体重输入错误后可修正，单位切换不丢半克精度，保存正常退出', (tester) async {
    await _open(
        tester,
        () => WeightEditor(store.services,
            date: '2026-10-20', defaultUnit: 'jin'));
    await tester.enterText(_field('体重'), '0');
    await _tapVisible(tester, '保存这次体重');
    expect(find.text('体重必须大于 0'), findsOneWidget);
    await tester.enterText(_field('体重'), '132.01');
    await _tapVisible(tester, '公斤');
    expect(tester.widget<TextField>(_field('体重')).controller!.text, '66.005');
    await _tapVisible(tester, '保存这次体重');
    expect(find.text('打开页面'), findsOneWidget);
    expect((await store.records.weights()).single['grams'], 66005);
    expect(tester.takeException(), isNull);
  });
}
