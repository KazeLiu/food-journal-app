import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/core/theme.dart';
import 'package:food_journal/core/widgets.dart';
import 'package:food_journal/settings/model_picker_dialog.dart';

const _models = ['Text-A', 'text-b', 'vision-a'];

Future<void> _mountPicker(WidgetTester tester,
    {String role = '文字主模型', ValueChanged<String?>? onResult}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 932);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(MaterialApp(
      theme: journalTheme(false),
      home: Scaffold(
          body: Builder(
              builder: (context) => Column(children: [
                    const TextField(
                        decoration: InputDecoration(labelText: 'Base URL')),
                    TextButton(
                        onPressed: () async {
                          final value = await showModelPickerDialog(context,
                              title: '选择$role', models: _models);
                          onResult?.call(value);
                        },
                        child: const Text('打开选择'))
                  ])))));
}

Finder get _search => find.descendant(
    of: find.byType(AlertDialog), matching: find.byType(TextField));

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('打开选择'));
  await tester.pumpAndSettle();
}

void main() {
  for (final role in ['文字主模型', '文字兜底模型', '图片主模型', '图片兜底模型']) {
    testWidgets('$role 可搜索并返回选择，退出动画结束前不释放输入状态', (tester) async {
      String? selected;
      var returned = false;
      await _mountPicker(tester, role: role, onResult: (value) {
        selected = value;
        returned = true;
      });
      await _open(tester);
      expect(find.text('选择$role'), findsOneWidget);
      await tester.enterText(_search, 'TEXT');
      await tester.pump();
      expect(find.text('Text-A'), findsOneWidget);
      expect(find.text('text-b'), findsOneWidget);
      expect(find.text('vision-a'), findsNothing);
      await tester.tap(find.text('Text-A'));
      await tester.pump();
      expect(returned, isFalse);
      await tester.pumpAndSettle();
      expect(returned, isTrue);
      expect(selected, 'Text-A');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('无匹配时显示状态，清空搜索可恢复列表', (tester) async {
    await _mountPicker(tester);
    await _open(tester);
    await tester.enterText(_search, 'missing-model');
    await tester.pump();
    expect(find.text('没有匹配的模型'), findsOneWidget);
    await tester.enterText(_search, '');
    await tester.pump();
    expect(find.text('Text-A'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final dismissal in ['取消', '遮罩', '系统返回']) {
    testWidgets('$dismissal 关闭不改变模型，重新打开搜索状态独立', (tester) async {
      final results = <String?>[];
      await _mountPicker(tester, onResult: results.add);
      await _open(tester);
      await tester.enterText(_search, 'vision');
      await tester.pump();
      switch (dismissal) {
        case '取消':
          await tester.tap(find.text('取消'));
        case '遮罩':
          await tester.tapAt(const Offset(8, 8));
        case '系统返回':
          await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(results, [null]);
      await _open(tester);
      expect(find.text('Text-A'), findsOneWidget);
      expect(tester.widget<TextField>(_search).controller!.text, isEmpty);
      await tester.tap(find.text('text-b'));
      await tester.pumpAndSettle();
      expect(results, [null, 'text-b']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('原页面输入聚焦后打开，键盘收起期间关闭不会使用已释放控制器', (tester) async {
    await _mountPicker(tester);
    await tester.enterText(
        find.byType(TextField), 'https://example.invalid/v1');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    await _open(tester);
    await tester.enterText(_search, 'text');
    await tester.pump();
    await tester.tap(find.text('Text-A'));
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入弹窗返回 false 也要等到实际移除，再由调用方释放控制器', (tester) async {
    final controller = TextEditingController(text: '输入内容');
    var returned = false;
    bool? result;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () async {
                      result = await showInputDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                                  content: TextField(controller: controller),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(context, false),
                                        child: const Text('返回 false'))
                                  ]));
                      returned = true;
                      controller.dispose();
                    },
                    child: const Text('打开输入'))))));
    await tester.tap(find.text('打开输入'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.tap(find.text('返回 false'));
    await tester.pump();
    expect(returned, isFalse);
    expect(controller.text, '输入内容');
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(result, isFalse);
    expect(tester.takeException(), isNull);
  });
}
