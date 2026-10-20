import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/chat/ai_gateway.dart';
import 'package:food_journal/core/data.dart';
import 'package:food_journal/core/theme.dart';
import 'package:food_journal/library/food_photo_recognizer.dart';
import 'package:food_journal/library/library_page.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../support/local_ai_server.dart';
import '../support/test_store.dart';

Json photoResponse() => {
      'protocol_version': 1,
      'outcome': 'recognized',
      'kind': 'packaged_food',
      'name': '测试酸奶',
      'brand': '测试品牌',
      'variant': '原味',
      'package_spec': '每瓶250g',
      'base_amount': 100,
      'base_unit': 'g',
      'portion_description': '标签每100克',
      'energy_value': 418.4,
      'energy_unit': 'kJ',
      'protein_g': 10,
      'fat_g': 0,
      'carbs_g': null,
      'note': '碳水一栏看不清',
    };

class _TestPaths extends PathProviderPlatform {
  final String root;
  _TestPaths(this.root);
  @override
  Future<String?> getTemporaryPath() async => '$root/camera-cache';
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _TestCompressor extends UnsupportedFlutterImageCompress {
  @override
  Future<Uint8List> compressWithList(Uint8List image,
          {int minWidth = 1920,
          int minHeight = 1080,
          int quality = 95,
          int rotate = 0,
          int inSampleSize = 1,
          bool autoCorrectionAngle = true,
          CompressFormat format = CompressFormat.jpeg,
          bool keepExif = false}) async =>
      image;
}

Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label);

void main() {
  late TestStore store;
  LocalAiServer? server;
  const cameraChannel = MethodChannel('plugins.flutter.io/image_picker');
  setUp(() async {
    store = await TestStore.create();
    server = null;
  });
  tearDown(() async {
    await server?.close();
    await store.close();
  });

  Future<void> configure([Json overrides = const {}]) async {
    await store.services.settings.set('ai_profile', {
      'base_url': server!.baseUrl,
      'allow_http': true,
      'text_main': 'text-main',
      'text_backup': 'text-backup',
      'vision_main': 'vision-main',
      'vision_backup': 'vision-backup',
      ...overrides,
    });
    FlutterSecureStorage.setMockInitialValues({
      'ai_credential':
          jsonEncode({'base_url': server!.baseUrl, 'key': 'fake-test-key'})
    });
  }

  Future<File> cameraFile() async {
    final previousPaths = PathProviderPlatform.instance;
    final previousCompressor = FlutterImageCompressPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(store.directory.path);
    FlutterImageCompressPlatform.instance = _TestCompressor();
    addTearDown(() {
      PathProviderPlatform.instance = previousPaths;
      FlutterImageCompressPlatform.instance = previousCompressor;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(cameraChannel, null);
    });
    await Directory('${store.directory.path}/camera-cache').create();
    return File('${store.directory.path}/camera-cache/captured.png')
        .writeAsBytes(base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='));
  }

  Future<void> open(WidgetTester tester, {Json? original}) async {
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
                        context,
                        MaterialPageRoute(
                            builder: (_) => LibraryEditor(store.services,
                                original: original))),
                    child: const Text('打开表单'))))));
    await tester.tap(find.text('打开表单'));
    await tester.pumpAndSettle();
    addTearDown(() async => tester.pumpWidget(const SizedBox()));
  }

  test('标签保留100g基准，kJ由客户端换算，未知与真实零值不混淆', () {
    final draft = parseFoodPhoto(photoResponse());
    expect(draft['base_portion']['amount'], 100);
    expect(draft['base_portion']['unit'], 'g');
    expect(draft['package_spec'], '每瓶250g');
    expect(draft['nutrition'],
        {'calories_kcal': 100, 'protein_g': 10, 'fat_g': 0, 'carbs_g': null});
    expect(draft['source']['type'], 'label');
    expect(draft['source']['label']['energy_value'], 418.4);
    expect(draft['source']['label']['energy_unit'], 'kJ');
    expect(draft['remarks'], '碳水一栏看不清');
    validateLibrarySource(draft['source']);
    final unknownBase =
        parseFoodPhoto({...photoResponse(), 'base_amount': null});
    expect((unknownBase['nutrition'] as Map).values, everyElement(isNull));
    final unknownEnergy =
        parseFoodPhoto({...photoResponse(), 'energy_unit': null});
    expect(unknownEnergy['nutrition']['calories_kcal'], isNull);
    expect(unknownEnergy['nutrition']['protein_g'], 10);
    final meal = parseFoodPhoto({
      ...photoResponse(),
      'kind': 'common_meal',
      'base_amount': 1,
      'base_unit': '份',
      'energy_unit': 'kcal'
    });
    expect(meal['source']['type'], 'ai');
    expect(meal['source'].containsKey('label'), isFalse);
  });

  test('拒绝错误文字、负数、无效基准与非食品，不能把响应当写库动作', () {
    for (final patch in <Json>[
      {'name': []},
      {'protein_g': '10'},
      {'fat_g': -1},
      {'base_amount': 0},
      {'energy_unit': 'J'},
      {'outcome': 'unrecognized'},
      {'outcome': 'ambiguous'},
      {'kind': 'delete_library'},
    ]) {
      expect(() => parseFoodPhoto({...photoResponse(), ...patch}),
          throwsA(isA<AppError>()));
    }
  });

  test('未配置图片模型时明确提示，不影响手动表单', () async {
    await expectLater(
        FoodPhotoRecognizer.create(store.services.settings),
        throwsA(
            isA<AppError>().having((e) => e.code, 'code', 'configuration')));
  });

  test('图片兜底留空主模型失败后再试一次，并传递图片思考强度', () async {
    server = await LocalAiServer.start((request, body) async {
      request.response.statusCode = 500;
      await request.response.close();
    });
    await configure({'vision_backup': '', 'vision_main_effort': 'low'});
    final file =
        await store.services.images.fileFor('test.jpg').writeAsBytes([1, 2, 3]);
    final recognizer =
        await FoodPhotoRecognizer.create(store.services.settings);
    var fallbacks = 0;
    await expectLater(
        server!.withClient(() => recognizer.recognize(file, RequestToken(),
            onFallback: (_) => fallbacks++)),
        throwsA(isA<AppError>()));
    expect(server!.calls, hasLength(2));
    expect(
        server!.calls.every((c) => c['body']['reasoning']['effort'] == 'low'),
        isTrue);
    expect(fallbacks, 0);
  });

  test('主图片模型失败后只用图片兜底，不调用文字模型或写入记录', () async {
    final reasons = <String>[];
    server = await LocalAiServer.start((request, body) async {
      if (body['model'] == 'vision-main') {
        request.response.statusCode = 500;
        await request.response.close();
      } else {
        await servePayload(request, photoResponse(), stream: false);
      }
    });
    await configure();
    final file =
        await store.services.images.fileFor('test.jpg').writeAsBytes([1, 2, 3]);
    final recognizer =
        await FoodPhotoRecognizer.create(store.services.settings);
    final draft = await server!.withClient(() =>
        recognizer.recognize(file, RequestToken(), onFallback: reasons.add));
    expect(draft['name'], '测试酸奶');
    expect(server!.calls.map((c) => c['body']['model']),
        ['vision-main', 'vision-main', 'vision-backup']);
    expect(
        server!.calls.every(
            (c) => c['body']['stream'] == false && c['body']['store'] == false),
        isTrue);
    expect(reasons, hasLength(1));
    for (final table in [
      'food_library',
      'meals',
      'chat_messages',
      'operations'
    ]) {
      expect(await store.db.query(table), isEmpty);
    }
  });

  for (final successAt in <int?>[2, 4, null]) {
    test('食品拍照按主主备备尝试，第${successAt ?? "全部失败"}次结束', () async {
      server = await LocalAiServer.start((request, body) async {
        if (server!.calls.length == successAt) {
          await servePayload(request, photoResponse(), stream: false);
        } else {
          request.response.statusCode = 500;
          await request.response.close();
        }
      });
      await configure();
      final file = await store.services.images
          .fileFor('test.jpg')
          .writeAsBytes([1, 2, 3]);
      final recognizer =
          await FoodPhotoRecognizer.create(store.services.settings);
      var fallbacks = 0;
      var retries = 0;
      final running = server!.withClient(() => recognizer.recognize(
          file, RequestToken(),
          onFallback: (_) => fallbacks++, onRetry: () => retries++));
      if (successAt == null) {
        await expectLater(running, throwsA(isA<AppError>()));
      } else {
        expect((await running)['name'], '测试酸奶');
      }
      expect(
          server!.calls.map((c) => c['body']['model']),
          ['vision-main', 'vision-main', 'vision-backup', 'vision-backup']
              .take(successAt ?? 4));
      expect(fallbacks, successAt == 2 ? 0 : 1);
      expect(retries, (successAt ?? 4) ~/ 2);
    });
  }

  test('最多三张照片合并到同一次识图，备注随草稿返回，不进入聊天', () async {
    server = await LocalAiServer.start((request, body) => servePayload(
        request, {...photoResponse(), 'note': '配料：生牛乳；需冷藏'},
        stream: false));
    await configure();
    final file = await store.services.images
        .fileFor('three.jpg')
        .writeAsBytes([1, 2, 3]);
    final recognizer =
        await FoodPhotoRecognizer.create(store.services.settings);
    final draft = await server!.withClient(() => recognizer
        .recognizeMany([file, file, file], RequestToken(), onFallback: (_) {}));
    final content = server!.calls.single['body']['input'][0]['content'] as List;
    expect(content.where((p) => p['type'] == 'input_image'), hasLength(3));
    expect(draft['remarks'], '配料：生牛乳；需冷藏');
    await expectLater(
        recognizer.recognizeMany([file, file, file, file], RequestToken(),
            onFallback: (_) {}),
        throwsA(isA<AppError>()));
    expect(server!.calls, hasLength(1));
    expect(await store.db.query('chat_messages'), isEmpty);
    expect(await store.records.library(), isEmpty);
  });

  testWidgets('识别模态框阻止返回与遮罩退出，完成后仍在表单且提示手动保存', (tester) async {
    final arrived = Completer<void>();
    final release = Completer<void>();
    server = await LocalAiServer.start((request, body) async {
      arrived.complete();
      await release.future;
      await servePayload(request, photoResponse(), stream: false);
    });
    await configure();
    final camera = (await tester.runAsync(cameraFile))!;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(cameraChannel, (_) async => camera.path);
    await open(tester);
    final dynamic editor = tester.state(find.byType(LibraryEditor));
    await tester.runAsync(() async => await editor.capturePhoto());
    Future<void>? running;
    await tester.runAsync(() async {
      running = server!.withClient(() async => await editor.recognizePhoto());
      await arrived.future;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('正在识别食品资料'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.tapAt(const Offset(5, 100));
    await tester.pump();
    expect(find.text('正在识别食品资料'), findsOneWidget);
    release.complete();
    await tester.runAsync(() => running!);
    await tester.pumpAndSettle();
    expect(find.byType(LibraryEditor), findsOneWidget);
    expect(find.text('正在识别食品资料'), findsNothing);
    expect(find.textContaining('点击“保存资料”才会保存'), findsOneWidget);
    expect(await store.records.library(), isEmpty);
    expect(await store.db.query('chat_messages'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  test('非食品不重复切换兜底，主动停止会中断请求', () async {
    var waiting = false;
    final arrived = Completer<void>();
    server = await LocalAiServer.start((request, body) async {
      if (waiting) {
        arrived.complete();
      } else {
        await servePayload(
            request, {...photoResponse(), 'outcome': 'unrecognized'},
            stream: false);
      }
    });
    await configure();
    final file =
        await store.services.images.fileFor('test.jpg').writeAsBytes([1, 2, 3]);
    final recognizer =
        await FoodPhotoRecognizer.create(store.services.settings);
    await expectLater(
        server!.withClient(() =>
            recognizer.recognize(file, RequestToken(), onFallback: (_) {})),
        throwsA(
            isA<AppError>().having((e) => e.code, 'code', 'photo_content')));
    expect(server!.calls, hasLength(1));
    waiting = true;
    final token = RequestToken();
    final running = server!.withClient(
        () => recognizer.recognize(file, token, onFallback: (_) {}));
    await arrived.future;
    token.cancel();
    await expectLater(running,
        throwsA(isA<AppError>().having((e) => e.code, 'code', 'cancelled')));
    expect(server!.calls, hasLength(2));
  });

  testWidgets('拍照识别只填写表单，核对后人工保存，识图副本随流程清理', (tester) async {
    server = await LocalAiServer.start((request, body) =>
        servePayload(request, photoResponse(), stream: false));
    await configure();
    final camera = (await tester.runAsync(cameraFile))!;
    var captures = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(cameraChannel, (call) async {
      expect(call.method, 'pickImage');
      expect(call.arguments['source'], 0);
      captures++;
      return camera.path;
    });
    await open(tester);
    expect(find.text('AI 拍照识别'), findsOneWidget);
    final dynamic editor = tester.state(find.byType(LibraryEditor));
    await tester.runAsync(
        () => server!.withClient(() async => await editor.recognizePhoto()));
    await tester.pumpAndSettle();
    expect(captures, 1);
    expect(tester.widget<TextField>(field('名称')).controller!.text, '测试酸奶');
    expect(find.text('识别结果已填入，请核对后点击“保存资料”。'), findsOneWidget);
    expect(await store.records.library(), isEmpty);
    expect(await store.db.query('chat_messages'), isEmpty);
    expect(await store.db.query('chat_attachments'), hasLength(1));
    expect(
        await store.services.settings.get('library_editor_draft'), isNotNull);
    expect(await tester.runAsync(camera.exists), isFalse);
    await tester.enterText(field('名称'), '核对后的酸奶');
    await tester.scrollUntilVisible(find.text('保存资料'), 300,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('保存资料'));
    await tester.pumpAndSettle();
    final saved = (await store.records.library()).single;
    expect(saved['name'], '核对后的酸奶');
    expect(jsonMap(saved['base_portion_json'])['amount'], 100);
    expect(jsonMap(saved['nutrition_json'])['calories_kcal'], 100);
    expect(jsonMap(saved['source_json'])['type'], 'label');
    expect(jsonMap(saved['source_json'])['remarks'], '碳水一栏看不清');
    expect(await store.db.query('chat_attachments'), isEmpty);
    expect(await store.services.settings.get('library_editor_draft'), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未配置AI仍可手动保存，拍照配置失败不会覆盖手填内容', (tester) async {
    await open(tester);
    await tester.enterText(field('名称'), '手动食品');
    await tester.tap(find.text('AI 拍照识别'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请先在“我的 → AI 接口与模型”配置图片模型'), findsOneWidget);
    expect(tester.widget<TextField>(field('名称')).controller!.text, '手动食品');
    await tester.scrollUntilVisible(find.text('保存资料'), 300,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('保存资料'));
    await tester.pumpAndSettle();
    expect((await store.records.library()).single['name'], '手动食品');
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消拍照不清表单、不调用模型，并释放按钮', (tester) async {
    server = await LocalAiServer.start((request, body) =>
        servePayload(request, photoResponse(), stream: false));
    await configure();
    final previous =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    previous.setMockMethodCallHandler(cameraChannel, (_) async => null);
    addTearDown(() => previous.setMockMethodCallHandler(cameraChannel, null));
    await open(tester);
    final dynamic editor = tester.state(find.byType(LibraryEditor));
    await tester.runAsync(() async => await editor.recognizePhoto());
    await tester.pumpAndSettle();
    expect(server!.calls, isEmpty);
    expect(editor.recognizing, isFalse);
    expect(tester.widget<TextField>(field('基准数量')).controller!.text, '1');
    expect(await store.db.query('chat_attachments'), isEmpty);
    expect(await store.services.settings.get('library_photo_capture'), isNull);
  });

  testWidgets('相机权限被拒绝后释放按钮，表单仍能手动填写', (tester) async {
    server = await LocalAiServer.start((request, body) =>
        servePayload(request, photoResponse(), stream: false));
    await configure();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(cameraChannel,
        (_) async => throw PlatformException(code: 'camera_access_denied'));
    addTearDown(() => messenger.setMockMethodCallHandler(cameraChannel, null));
    await open(tester);
    final dynamic editor = tester.state(find.byType(LibraryEditor));
    await tester.runAsync(() => expectLater(
        editor.recognizePhoto(),
        throwsA(isA<AppError>()
            .having((e) => e.message, 'message', contains('相机访问')))));
    await tester.pumpAndSettle();
    expect(editor.recognizing, isFalse);
    expect(server!.calls, isEmpty);
    await tester.enterText(field('名称'), '仍可手动填写');
    expect(tester.widget<TextField>(field('名称')).controller!.text, '仍可手动填写');
    expect(await store.services.settings.get('library_photo_capture'), isNull);
    expect(tester.takeException(), isNull);
  });

  test('食品表单拍照的进程恢复不把照片塞进聊天草稿，原草稿不变', () async {
    final camera = await cameraFile();
    await store.services.settings
        .set('chat_draft', {'text': '原草稿', 'attachments': []});
    await store.services.settings.set('library_photo_capture', true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            cameraChannel,
            (_) async => {
                  'type': 'image',
                  'path': camera.path,
                  'pathList': [camera.path]
                });
    await store.services.images.initialize();
    expect(await store.services.settings.get('chat_draft'),
        {'text': '原草稿', 'attachments': []});
    expect(await store.services.settings.get('library_photo_capture'), isNull);
    final photos = await store.db.query('chat_attachments');
    expect(photos, hasLength(1));
    final draft =
        await store.services.settings.get('library_editor_draft') as Json;
    expect(draft['photos'], [photos.single['id']]);
    expect(await camera.exists(), isFalse);
  });

  test('聊天拍照的进程恢复仍按原约定追加到聊天草稿', () async {
    final camera = await cameraFile();
    await store.services.settings
        .set('chat_draft', {'text': '原草稿', 'attachments': []});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            cameraChannel,
            (_) async => {
                  'type': 'image',
                  'path': camera.path,
                  'pathList': [camera.path]
                });
    await store.services.images.initialize();
    final draft = await store.services.settings.get('chat_draft') as Json;
    expect(draft['text'], '原草稿');
    expect(draft['attachments'], hasLength(1));
    final attachment = (await store.db.query('chat_attachments')).single;
    expect(draft['attachments'], [attachment['id']]);
    expect(attachment['message_id'], isNull);
    expect(
        await store.services.images
            .fileFor(attachment['relative_path'] as String)
            .exists(),
        isTrue);
    expect(await camera.exists(), isFalse);
  });
}
