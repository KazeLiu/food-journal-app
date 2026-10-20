import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/chat/chat_page.dart';
import 'package:food_journal/chat/message_images.dart';
import 'package:food_journal/chat/reasoning_view.dart';
import 'package:food_journal/app.dart';
import 'package:food_journal/core/theme.dart';
import 'package:food_journal/core/widgets.dart';
import 'package:food_journal/library/library_page.dart';
import 'package:food_journal/records/record_card.dart';

import 'support/test_store.dart';

void main() {
  late TestStore store;
  setUp(() async => store = await TestStore.create());
  tearDown(() async => store.close());

  Future<void> open(WidgetTester tester, Widget child) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester
        .pumpWidget(MaterialApp(theme: journalTheme(true), home: child));
    await tester.pumpAndSettle();
  }

  testWidgets('记忆空态的图标、标题和说明在内容区域居中', (tester) async {
    await open(tester, LibraryPage(store.services, memories: true));
    final icon = find.byIcon(Icons.psychology_outlined);
    final title = find.text('还没有保存长期偏好');
    final description = find.text('只有你同意的内容才会长期保存。');
    for (final finder in [icon, title, description]) {
      expect(tester.getCenter(finder).dx, closeTo(215, 0.5));
    }
    final groupCenter =
        (tester.getTopLeft(icon).dy + tester.getBottomLeft(description).dy) / 2;
    expect(
        groupCenter, closeTo(tester.getCenter(find.byType(EmptyView)).dy, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开明细后不同长度食物和份量保持相同左边界', (tester) async {
    final result = await store.services.committer.local(mealInput(items: [
      foodInput(name: '虾仁'),
      {...foodInput(name: '水煮蛋配一份较长名称的蔬菜'), 'portion_text': '2个（约100克，含浅色蛋白块）'}
    ]));
    await open(
        tester,
        Scaffold(
            body: ListView(children: [
          RecordCard(store.services,
              table: 'meals', id: receiptId(result, 'meals'))
        ])));
    await tester.tap(find.text('展开明细'));
    await tester.pumpAndSettle();
    final left = tester.getTopLeft(find.text('虾仁')).dx;
    expect(
        tester.getTopLeft(find.text('水煮蛋配一份较长名称的蔬菜')).dx, closeTo(left, 0.5));
    expect(tester.getTopLeft(find.text('2个（约100克，含浅色蛋白块）')).dx,
        closeTo(left, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('真实聊天页同时保留自然回复、状态回执和记录卡片', (tester) async {
    final op = await store.records.enqueue('我的早餐', [], {}, null, null);
    final actions = await store.services.committer.savePlan(op['id'], [
      {...mealInput(), 'action_key': 'meal', 'state': 'ready'}
    ]);
    final result = await store.services.committer.commit(actions.single['id']);
    await store.services.committer.settle(op['id']);
    await store.records
        .assistant(op['id'], '早餐搭配不错，下一餐可以补一点蔬菜。', 'running', modelReply: true);
    await store.records.assistant(op['id'], '记录已更新。', 'completed',
        refs: (result['refs'] as List).cast<Map<String, dynamic>>());
    await open(tester, ChatPage(store.services));
    expect(find.text('早餐搭配不错，下一餐可以补一点蔬菜。'), findsOneWidget);
    expect(find.text('记录已更新。'), findsOneWidget);
    expect(find.byType(RecordCard), findsOneWidget);
    expect(find.text('查看详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('旧回执夹带正文时只显示一次正文，保留真正的保存错误', (tester) async {
    final op = await store.records.enqueue('保存标签', [], {}, null, null);
    const reply = '已整理食品资料建议，请核对后保存。';
    const error = '长期资料建议未能保存，已有饮食和体重不受影响。';
    await store.records.assistant(op['id'], reply, 'running', modelReply: true);
    await store.records.assistant(op['id'], '$reply\n$error', 'completed');
    await open(tester, ChatPage(store.services));
    expect(find.text(reply), findsOneWidget);
    expect(find.text(error), findsOneWidget);
    expect(find.text('$reply\n$error'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('已发送图片显示80像素缩略图，点击可放大并返回聊天', (tester) async {
    final file = store.services.images.fileFor('preview.png');
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
    await tester.runAsync(() => file.writeAsBytes(bytes));
    await store.db.insert('chat_attachments', {
      'id': 'preview',
      'relative_path': 'preview.png',
      'mime_type': 'image/png',
      'byte_length': bytes.length,
      'state': 'pending',
      'created_at_ms': 1
    });
    final op = await store.records.enqueue('图片消息', ['preview'], {}, null, null);
    await open(tester, const Scaffold());
    final context = tester.element(find.byType(Scaffold));
    await tester.runAsync(() async {
      await precacheImage(FileImage(file), context);
      await precacheImage(ResizeImage(FileImage(file), width: 240), context);
    });
    await open(
        tester,
        Scaffold(
            body: MessageImages(store.services.images,
                messageId: op['message_id'])));
    expect(tester.getSize(find.byType(Image)), const Size(80, 80));
    await tester.tap(find.byTooltip('查看第 1 张图片'));
    await tester.pumpAndSettle();
    expect(find.text('图片预览'), findsOneWidget);
    expect(
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .maxScale,
        5);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byTooltip('查看第 1 张图片'), findsOneWidget);
    await tester.tap(find.byTooltip('查看第 1 张图片'));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(find.byType(Image)));
    await tester.pumpAndSettle();
    expect(find.byTooltip('查看第 1 张图片'), findsOneWidget);
    await tester.tap(find.byTooltip('查看第 1 张图片'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 150));
    await tester.pumpAndSettle();
    expect(find.byTooltip('查看第 1 张图片'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('追问卡片与回复有8dp间隔', (tester) async {
    final op = await store.records.enqueue('早餐是什么', [], {}, null, null);
    await store.services.committer.savePlan(op['id'], [
      {
        'action_key': 'question',
        'type': 'create_meal',
        'state': 'clarify',
        'question': '这顿吃的是什么？',
        'candidates': []
      }
    ]);
    await store.records
        .assistant(op['id'], '请补充一下早餐。', 'waiting_input', modelReply: true);
    await open(tester, ChatPage(store.services));
    final reply = find
        .ancestor(of: find.text('请补充一下早餐。'), matching: find.byType(Container))
        .first;
    final card =
        find.ancestor(of: find.text('这顿吃的是什么？'), matching: find.byType(Card));
    expect(tester.getTopLeft(card).dy - tester.getBottomLeft(reply).dy,
        closeTo(8, .5));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('AI伙伴标题、顶部留白和只显示图标的底栏', (tester) async {
    await store.services.settings.set('onboarding_completed', true);
    await open(tester, JournalHome(services: store.services));
    expect(
        find.descendant(
            of: find.byType(AppBar).first, matching: find.text('AI伙伴')),
        findsOneWidget);
    expect(find.text('每一餐，轻松记下来。'), findsNothing);
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.labelBehavior, NavigationDestinationLabelBehavior.alwaysHide);
    final overview = find.byKey(const ValueKey('chat-overview'));
    expect(
        tester.getTopLeft(overview).dy -
            tester.getBottomLeft(find.byType(AppBar).first).dy,
        0);
    final card =
        find.descendant(of: overview, matching: find.byType(Card)).first;
    expect(tester.getTopLeft(card).dy - tester.getTopLeft(overview).dy, 8);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('旧版已清理的图片显示明确提示，不产生红屏', (tester) async {
    await open(
        tester,
        Scaffold(
            body: MessageImages(store.services.images,
                messageId: 'old-message')));
    expect(find.text('此消息的图片预览已不可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('思考流式展开，正文开始后折叠，展开后为灰色小字号斜体', (tester) async {
    Widget subject(bool thinking, String text) => MaterialApp(
        theme: journalTheme(false),
        home: Scaffold(
            body: ReasoningView(
                key: const ValueKey('test-reasoning'),
                text: text,
                thinking: thinking)));
    await tester.pumpWidget(subject(true, '接口测试摘要前半段'));
    expect(find.text('接口测试摘要前半段'), findsOneWidget);
    await tester.pumpWidget(subject(true, '接口测试摘要前半段和后半段'));
    expect(find.text('接口测试摘要前半段和后半段'), findsOneWidget);
    final text = tester.widget<Text>(find.text('接口测试摘要前半段和后半段'));
    expect(text.style!.fontSize, 13);
    expect(text.style!.fontStyle, FontStyle.italic);
    expect(text.style!.color, journalTheme(false).colorScheme.onSurfaceVariant);
    await tester.pumpWidget(subject(false, '接口测试摘要前半段和后半段'));
    expect(find.text('接口测试摘要前半段和后半段'), findsNothing);
    await tester.tap(find.text('思考摘要'));
    await tester.pump();
    expect(find.text('接口测试摘要前半段和后半段'), findsOneWidget);
    await tester.tap(find.text('接口测试摘要前半段和后半段'));
    await tester.pump();
    expect(find.text('接口测试摘要前半段和后半段'), findsNothing);
    final header = find.descendant(
        of: find.byType(CompactDisclosure), matching: find.byType(TextButton));
    expect(tester.getSize(header).height, 48);
    expect(tester.takeException(), isNull);
  });

  testWidgets('恢复食品拍照草稿时仍在添加页，不进入聊天或调用模型', (tester) async {
    await store.services.settings.set('onboarding_completed', true);
    await store.services.settings.set('library_editor_draft', {
      'kind': 'packaged_food',
      'values': {'name': '待核对的食品', 'remarks': '配料：生牛乳'},
      'photos': <String>[],
    });
    await open(tester, JournalHome(services: store.services));
    expect(find.byType(LibraryEditor), findsOneWidget);
    expect(find.text('添加食品资料'), findsOneWidget);
    expect(store.services.tab.value, 2);
    expect(await store.db.query('chat_messages'), isEmpty);
    expect(await store.records.library(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('长思考限制展开高度，流式期间可看到末尾，标题仍可折叠', (tester) async {
    final content = List.generate(100, (i) => '思考片段$i').join('\n');
    await tester.pumpWidget(MaterialApp(
        theme: journalTheme(false),
        home: Scaffold(body: ReasoningView(text: content, thinking: true))));
    await tester.pump();
    final viewport = find.byType(SingleChildScrollView);
    expect(tester.getSize(viewport).height, lessThanOrEqualTo(220));
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.pixels, scrollable.position.maxScrollExtent);
    await tester.tap(find.text('思考中…').hitTestable());
    await tester.pump();
    expect(find.text(content), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
