import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/chat/chat_page.dart';
import 'package:food_journal/chat/vision_progress.dart';
import 'package:food_journal/core/data.dart';
import 'package:food_journal/core/theme.dart';
import 'package:food_journal/core/widgets.dart';
import 'package:food_journal/records/record_card.dart';

import '../support/test_store.dart';

String _body(int i) => '历史消息$i：这是一条用于阅读和翻页的聊天内容。' * (i % 3 + 1);

void main() {
  late TestStore store;
  setUp(() async => store = await TestStore.create());
  tearDown(() async => store.close());

  Future<void> seed(int count, {String? mealId}) =>
      store.db.transaction((tx) async {
        for (var i = 0; i < count; i++) {
          await tx.insert('chat_messages', {
            'id': 'history-${i.toString().padLeft(3, '0')}',
            'role': mealId == null ? 'user' : 'assistant',
            'content_kind': 'text',
            'body_text': _body(i),
            'delivery_status': 'completed',
            'created_at_ms': 1000 + i,
            if (mealId != null)
              'record_refs_json': jsonEncode([
                {'table': 'meals', 'id': mealId}
              ])
          });
        }
      });

  Future<ScrollableState> open(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 932);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: journalTheme(true),
        home: Scaffold(body: ChatPage(store.services))));
    await tester.pumpAndSettle();
    addTearDown(() async => tester.pumpWidget(const SizedBox()));
    return tester.state<ScrollableState>(find
        .descendant(
            of: find.byType(ChatPage), matching: find.byType(Scrollable))
        .first);
  }

  double distanceFromLatest(ScrollPosition position) =>
      position.axisDirection == AxisDirection.up
          ? position.pixels - position.minScrollExtent
          : position.maxScrollExtent - position.pixels;

  testWidgets('日历日期发送后保留在消息里，重开聊天仍可辨认并返回该日', (tester) async {
    store.services
        .goChat({'local_date': '2026-10-19', 'label': '记录或查询 2026-10-19'});
    await open(tester);
    await tester.enterText(find.byType(TextField), '吃得算多吗？');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    final label = find.text('记录或查询 2026-10-19');
    expect(label, findsOneWidget);
    expect(find.ancestor(of: label, matching: find.byType(ListTile)),
        findsNothing);
    expect(find.text('吃得算多吗？'), findsOneWidget);
    store.services.chatIntent.value = null;
    await tester.pumpWidget(const SizedBox());
    await open(tester);
    expect(label, findsOneWidget);
    await tester.tap(label);
    expect(store.services.tab.value, 1);
    expect(store.services.day.value, '2026-10-19');
    expect(tester.takeException(), isNull);
  });

  testWidgets('引用原话显示原日期，同时能辨认本句新选定的日期', (tester) async {
    final root = await store.records
        .enqueue('原问题', [], {'local_date': '2026-10-19'}, null, null);
    final quote =
        (await store.records.messagesAround(root['message_id'])).single;
    await store.services.chat
        .send('另一天呢？', [], {'local_date': '2026-10-20'}, quote, null);
    await open(tester);
    expect(find.text('针对 2026-10-20'), findsOneWidget);
    expect(find.text('引用 2026-10-19：原问题'), findsOneWidget);
    expect(find.text('另一天呢？'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索定位的旧消息重试后刷新原气泡，不插入最新消息或退出定位', (tester) async {
    await seed(120);
    await store.db.update(
        'chat_messages',
        {
          'role': 'assistant',
          'body_text': '待重试的旧回复',
        },
        where: 'id=?',
        whereArgs: ['history-030']);
    await open(tester);
    await tester.tap(find.byTooltip('搜索聊天'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '待重试的旧回复');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.text('待重试的旧回复'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-search-position')), findsOneWidget);
    await store.db.update(
        'chat_messages',
        {
          'body_text': '已按资料库更新原食物。\n记录已更新。',
          'model_reply_text': '已按资料库更新原食物。',
          'receipt_text': '记录已更新。',
          'reasoning_text': '接口返回的思考摘要',
        },
        where: 'id=?',
        whereArgs: ['history-030']);
    store.records.changed();
    await tester.pumpAndSettle();
    expect(find.text('待重试的旧回复'), findsNothing);
    expect(find.text('已按资料库更新原食物。'), findsOneWidget);
    expect(find.text('记录已更新。'), findsOneWidget);
    expect(find.text('思考摘要'), findsOneWidget);
    expect(find.text('接口返回的思考摘要'), findsNothing);
    expect(find.byKey(const ValueKey('chat-search-position')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('chat-message-history-119')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('标题栏只保留搜索，三个快捷按钮等宽铺满且宽屏时居中限宽', (tester) async {
    await open(tester);
    expect(tester.widget<AppBar>(find.byType(AppBar)).actions, hasLength(1));
    expect(find.byTooltip('搜索聊天'), findsOneWidget);
    expect(find.byTooltip('更多'), findsNothing);
    final buttons = ['记录饮食', '记录体重', '今日分析']
        .map((label) => find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is OutlinedButton)))
        .toList();

    for (final width in [320.0, 430.0, 1000.0]) {
      tester.view.physicalSize = Size(width, 932);
      await tester.pumpAndSettle();
      final rects = buttons.map(tester.getRect).toList();
      final expectedWidth = width > 588 ? 180.0 : (width - 32 - 16) / 3;
      for (final rect in rects) {
        expect(rect.width, closeTo(expectedWidth, .5));
      }
      expect(rects[1].left - rects[0].right, closeTo(8, .5));
      expect(rects[2].left - rects[1].right, closeTo(8, .5));
      expect((rects.first.left + rects.last.right) / 2, closeTo(width / 2, .5));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('识图卡显示预估与超时提示，进入文字阶段后移除', (tester) async {
    await open(tester);
    final chat = store.services.chat;
    chat.activeOperationId = 'local-vision-test';
    chat.stageLabel = '识别图片 · 使用兜底模型';
    chat.visionStartedAt =
        DateTime.now().subtract(const Duration(seconds: 121));
    chat.lifecycle(false);
    await tester.pump();
    await tester.pump();
    expect(find.byType(VisionProgress), findsOneWidget);
    expect(find.text('95%'), findsOneWidget);
    expect(find.text('这次识别貌似有点长，请耐心等待。'), findsOneWidget);
    chat.visionStartedAt = null;
    chat.stageLabel = '整理回复';
    chat.lifecycle(false);
    await tester.pump();
    await tester.pump();
    expect(find.byType(VisionProgress), findsNothing);
    chat.activeOperationId = null;
    chat.lifecycle(false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('今日概览与快捷入口固定在顶部，聊天上翻时不移动且统计继续更新', (tester) async {
    await seed(60);
    final scrollable = await open(tester);
    final overview = find.byKey(const ValueKey('chat-overview'));
    final before = tester.getRect(overview);
    expect(find.ancestor(of: overview, matching: find.byType(Scrollable)),
        findsNothing);
    await tester.sendEventToBinding(PointerScrollEvent(
        position: tester.getCenter(find.byType(CustomScrollView)),
        scrollDelta: const Offset(0, -400)));
    await tester.pumpAndSettle();
    expect(distanceFromLatest(scrollable.position), greaterThan(100));
    expect(tester.getRect(overview), before);
    for (final text in ['记录饮食', '记录体重', '今日分析']) {
      expect(find.text(text).hitTestable(), findsOneWidget);
    }
    await store.services.committer.local(mealInput(date: today()));
    await tester.pumpAndSettle();
    expect(find.text('今天 · 1 餐'), findsOneWidget);
    expect(find.text('已记录约 100 kcal'), findsOneWidget);
    expect(tester.getRect(overview), before);
    await tester.tap(find.text('今天 · 1 餐'));
    expect(store.services.tab.value, 1);
    expect(store.services.day.value, today());
    expect(tester.takeException(), isNull);
  });

  testWidgets('键盘打开时概览仍置顶，输入框与独立聊天区域可用', (tester) async {
    await seed(60);
    await open(tester);
    await tester.tap(find.text('记录饮食'));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-overview')).hitTestable(),
        findsOneWidget);
    expect(find.byTooltip('发送').hitTestable(), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue);
    expect(
        tester.getSize(find.byType(CustomScrollView)).height, greaterThan(80));
    expect(tester.takeException(), isNull);
  });

  testWidgets('鼠标滚轮刚离开底部时，状态通知不将阅读位置拉回', (tester) async {
    await seed(60);
    final scrollable = await open(tester);
    await tester.sendEventToBinding(PointerScrollEvent(
        position: tester.getCenter(find.byType(CustomScrollView)),
        scrollDelta: const Offset(0, -60)));
    await tester.pump();
    final distance = distanceFromLatest(scrollable.position);
    expect(distance, greaterThan(10));
    store.services.chat.lifecycle(false);
    await tester.pump();
    await tester.pump();
    expect(distanceFromLatest(scrollable.position), closeTo(distance, 0.5));
  });

  testWidgets('拖拽期间的异步刷新和流式通知不会中断手势或跳到底部', (tester) async {
    await seed(60);
    final scrollable = await open(tester);
    // 先排入自动滚动回调，再开始上翻，覆盖回调晚于手势执行的情况。
    store.services.chat.lifecycle(false);
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(CustomScrollView)));
    await gesture.moveBy(const Offset(0, 60));
    store.records.changed();
    store.services.chat.lifecycle(false);
    await tester.pump();
    await tester.pump();
    expect(distanceFromLatest(scrollable.position), greaterThan(10));
    expect(scrollable.position.isScrollingNotifier.value, isTrue);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('向上加载历史不按估算总高度跳位，连点也不会重复插入', (tester) async {
    await seed(120);
    await open(tester);
    final scrollable = find
        .descendant(
            of: find.byType(ChatPage), matching: find.byType(Scrollable))
        .first;
    final older = find.text('查看更早的聊天');
    await tester.scrollUntilVisible(older, -500,
        scrollable: scrollable, maxScrolls: 40);
    await tester.pumpAndSettle();
    await tester.ensureVisible(older);
    await tester.pumpAndSettle();
    final anchor = find.text(_body(70));
    final before = tester.getTopLeft(anchor).dy;
    await tester.tap(older);
    await tester.tap(older);
    await tester.pumpAndSettle();
    expect(anchor, findsOneWidget);
    expect(tester.getTopLeft(anchor).dy, closeTo(before, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片离屏再返回保留展开状态，不重新变成加载占位', (tester) async {
    final result = await store.services.committer.local(mealInput());
    await seed(30, mealId: receiptId(result, 'meals'));
    final scrollable = await open(tester);
    final entry = find.byKey(const ValueKey('chat-message-history-029'));
    final expansion =
        find.descendant(of: entry, matching: find.byType(CompactDisclosure));
    await tester.ensureVisible(expansion);
    await tester.tap(find.descendant(of: entry, matching: find.text('展开明细')));
    await tester.pumpAndSettle();
    final state = tester.state(expansion);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 1800));
    await tester.pumpAndSettle();
    expect(distanceFromLatest(scrollable.position), greaterThan(800));
    scrollable.position.jumpTo(
        scrollable.position.axisDirection == AxisDirection.up
            ? scrollable.position.minScrollExtent
            : scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(identical(tester.state(expansion), state), isTrue);
    expect(find.descendant(of: entry, matching: find.byType(FoodNutrition)),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('阅读历史时只提示新消息，点击查看最新才切回底部', (tester) async {
    await seed(60);
    final scrollable = await open(tester);
    await tester.sendEventToBinding(PointerScrollEvent(
        position: tester.getCenter(find.byType(CustomScrollView)),
        scrollDelta: const Offset(0, -400)));
    await tester.pumpAndSettle();
    final visible = find
        .byWidgetPredicate(
            (w) => w is Text && w.data?.startsWith('历史消息') == true)
        .hitTestable()
        .first;
    final text = tester.widget<Text>(visible).data!;
    final before = tester.getTopLeft(find.text(text)).dy;
    await store.db.insert('chat_messages', {
      'id': 'new-message',
      'role': 'user',
      'content_kind': 'text',
      'body_text': '刚到的新消息',
      'delivery_status': 'completed',
      'created_at_ms': 2000
    });
    store.records.changed();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text(text)).dy, closeTo(before, 1));
    await tester.tap(find.text('有新消息 · 查看最新'));
    await tester.pumpAndSettle();
    expect(distanceFromLatest(scrollable.position), closeTo(0, 1));
    expect(find.text('刚到的新消息').hitTestable(), findsOneWidget);
  });

  testWidgets('阅读历史时底部流式文本变长不移动当前消息，回到底部后继续跟随', (tester) async {
    await seed(60);
    final scrollable = await open(tester);
    await tester.sendEventToBinding(PointerScrollEvent(
        position: tester.getCenter(find.byType(CustomScrollView)),
        scrollDelta: const Offset(0, -400)));
    await tester.pumpAndSettle();
    final visible = find
        .byWidgetPredicate(
            (w) => w is Text && w.data?.startsWith('历史消息') == true)
        .hitTestable()
        .first;
    final text = tester.widget<Text>(visible).data!;
    final before = tester.getTopLeft(find.text(text)).dy;
    store.services.chat.activeOperationId = 'local-stream-test';
    store.services.chat.stageLabel = '整理回复';
    store.services.chat.liveReply = '正在生成的回复\n' * 20;
    store.services.chat.lifecycle(false);
    await tester.pump();
    await tester.pump();
    expect(tester.getTopLeft(find.text(text)).dy, closeTo(before, 1));
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pump();
    store.services.chat.liveReply = '正在生成的回复\n' * 40;
    store.services.chat.lifecycle(false);
    await tester.pump();
    await tester.pump();
    expect(distanceFromLatest(scrollable.position), closeTo(0, 1));
    store.services.chat.activeOperationId = null;
    store.services.chat.lifecycle(false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
