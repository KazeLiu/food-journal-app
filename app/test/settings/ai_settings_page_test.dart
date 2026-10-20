import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/core/theme.dart';
import 'package:food_journal/settings/ai_settings_page.dart';
import 'package:food_journal/settings/settings_repository.dart';

import '../support/local_ai_server.dart';
import '../support/test_store.dart';

Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label);

void main() {
  late TestStore store;
  LocalAiServer? server;
  setUp(() async {
    store = await TestStore.create();
    server = null;
  });
  tearDown(() async {
    await server?.close();
    await store.close();
  });

  Future<dynamic> open(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 932);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: journalTheme(false), home: AiSettingsPage(store.services)));
    await tester.pumpAndSettle();
    addTearDown(() async => tester.pumpWidget(const SizedBox()));
    return tester.state(find.byType(AiSettingsPage));
  }

  testWidgets('只填文字主模型即可保存，思考强度持久化，兜底默认收起', (tester) async {
    await open(tester);
    await tester.enterText(field('Base URL'), 'https://example.invalid/v1');
    await tester.enterText(field('API Key'), 'fake-test-key');
    await tester.scrollUntilVisible(field('文字主模型（必填）'), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(field('文字主模型（必填）'), 'text-only');
    final effort = find.byKey(const ValueKey('effort-text_main'));
    await tester.ensureVisible(effort);
    await tester.tap(effort);
    await tester.pumpAndSettle();
    await tester.tap(find.text('低（low）').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('可选兜底模型'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(
        tester
            .widget<ExpansionTile>(find.byType(ExpansionTile))
            .initiallyExpanded,
        isFalse);
    expect(field('文字兜底模型（可选）'), findsNothing);
    await tester.scrollUntilVisible(find.text('保存配置'), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(find.text('AI 配置已保存'), findsOneWidget);
    final saved = await store.services.settings.get('ai_profile') as Map;
    expect(saved['text_main'], 'text-only');
    expect(saved['vision_main'], '');
    expect(saved['text_backup'], '');
    expect(saved['vision_backup'], '');
    expect(saved['text_main_effort'], 'low');
    expect(saved.containsKey('vision_main_effort'), isFalse);
    await tester.pumpWidget(const SizedBox());
    final dynamic reloaded = await open(tester);
    expect(reloaded.models['text_main'].text, 'text-only');
    expect(reloaded.efforts['text_main'], 'low');
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧四模型配置保留原ID，未设置思考强度时跟随服务端', (tester) async {
    final old = {for (final role in aiModelRoles) role: '$role-model'};
    await store.services.settings.saveProfile(
        {'base_url': 'https://example.invalid/v1', 'allow_http': false, ...old},
        'fake-test-key');
    final dynamic editor = await open(tester);
    for (final role in aiModelRoles) {
      expect(editor.models[role].text, old[role]);
      expect(editor.efforts[role], '');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('能力检查只请求已填写模型，并携带该角色的思考强度', (tester) async {
    server = await LocalAiServer.start(
        (request, body) => servePayload(request, finalPayload()));
    await store.services.settings.saveProfile({
      'base_url': server!.baseUrl,
      'allow_http': true,
      'text_main': 'text-only',
      'text_main_effort': 'low',
    }, 'fake-test-key');
    final dynamic editor = await open(tester);
    late Future<void> running;
    await tester.runAsync(() async {
      running = server!.withClient(() async => await editor.checkModels());
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('检查已填写的模型？'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('开始检查'));
      await running;
    });
    await tester.pumpAndSettle();
    expect(server!.calls, hasLength(1));
    expect(server!.calls.single['body']['model'], 'text-only');
    expect(server!.calls.single['body']['reasoning'], {'effort': 'low'});
    expect(editor.results['text_main'], '通过');
    expect(await store.db.query('meals'), isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('四个已填模型各自失败后再试一次，通过即停，失败不妨碍后续模型检查', (tester) async {
    final counts = <String, int>{};
    server = await LocalAiServer.start((request, body) async {
      final model = body['model'] as String;
      final count =
          counts.update(model, (value) => value + 1, ifAbsent: () => 1);
      if (count == 1 || model.endsWith('backup')) {
        request.response.statusCode = count == 1 ? 401 : 500;
        await request.response.close();
      } else if (model.startsWith('vision')) {
        await servePayload(request,
            {'protocol_version': 1, 'outcome': 'non_food', 'summary': '非食物'},
            stream: false);
      } else {
        await servePayload(request, finalPayload());
      }
    });
    await store.services.settings.saveProfile({
      'base_url': server!.baseUrl,
      'allow_http': true,
      'text_main': 'text-main',
      'text_backup': 'text-backup',
      'vision_main': 'vision-main',
      'vision_backup': 'vision-backup',
    }, 'fake-test-key');
    final dynamic editor = await open(tester);
    late Future<void> running;
    await tester.runAsync(() async {
      running = server!.withClient(() async => await editor.checkModels());
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      await tester.tap(find.text('开始检查'));
      await running;
    });
    await tester.pumpAndSettle();
    expect(counts, {
      'text-main': 2,
      'text-backup': 2,
      'vision-main': 2,
      'vision-backup': 2
    });
    expect(editor.results['text_main'], '通过');
    expect(editor.results['vision_main'], '通过');
    expect(editor.results['text_backup'], contains('HTTP 500'));
    expect(editor.results['vision_backup'], contains('HTTP 500'));
    expect(tester.takeException(), isNull);
  });
}
