import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/chat/ai_gateway.dart';
import 'package:food_journal/core/data.dart';

import '../support/local_ai_server.dart';

void main() {
  late LocalAiServer server;
  final gateway = AiGateway();
  Future<Json> generate(
          {bool stream = true,
          RequestToken? token,
          Duration deadline = const Duration(seconds: 5),
          String? reasoningEffort,
          bool requestReasoningSummary = false,
          void Function(String)? onReasoning,
          void Function(String)? onReply}) =>
      server.withClient(() => gateway.generate(
          baseUrl: server.baseUrl,
          key: 'fake-test-key',
          model: 'test-model',
          instructions: '固定测试协议',
          input: [],
          stream: stream,
          token: token ?? RequestToken(),
          deadline: deadline,
          reasoningEffort: reasoningEffort,
          requestReasoningSummary: requestReasoningSummary,
          onReasoning: onReasoning,
          onReply: onReply));
  tearDown(() async => server.close());

  test('模型列表去重排序并忽略非字符串 ID', () async {
    server = await LocalAiServer.start((request, body) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'data': [
          {'id': 'b'},
          {'id': 'a'},
          {'id': 'b'},
          {'id': 1},
          null
        ]
      }));
      await request.response.close();
    });
    expect(
        await server.withClient(() =>
            gateway.models(server.baseUrl, 'fake-test-key', RequestToken())),
        ['a', 'b']);
    expect(server.calls.single['path'], '/v1/models');
  });

  test('默认不发送reasoning，指定强度时使用Responses的reasoning.effort', () async {
    server = await LocalAiServer.start(
        (request, body) => servePayload(request, finalPayload()));
    await generate();
    await generate(reasoningEffort: 'low');
    await generate(reasoningEffort: 'none');
    expect((server.calls[0]['body'] as Map).containsKey('reasoning'), isFalse);
    expect(server.calls[1]['body']['reasoning'], {'effort': 'low'});
    expect(server.calls[2]['body']['reasoning'], {'effort': 'none'});
  });

  test('真实 SSE 输入支持 UTF-8 字节流、CRLF 和最终 completed 对照', () async {
    final payload = finalPayload(reply: '一碗面 🍜，先确认份量。');
    server = await LocalAiServer.start((request, body) async {
      expect(body['store'], isFalse);
      expect(body['stream'], isTrue);
      await servePayload(request, payload);
    });
    final replies = <String>[];
    expect(await generate(onReply: replies.add), payload);
    expect(replies.last, payload['reply']);
    expect(
        replies.every((text) => (payload['reply'] as String).startsWith(text)),
        isTrue);
  });

  test('显式请求摘要才添加summary，不改变原有默认和effort', () async {
    server = await LocalAiServer.start(
        (request, body) => servePayload(request, finalPayload()));
    await generate(requestReasoningSummary: true);
    await generate(requestReasoningSummary: true, reasoningEffort: 'low');
    expect(server.calls[0]['body']['reasoning'], {'summary': 'auto'});
    expect(server.calls[1]['body']['reasoning'],
        {'summary': 'auto', 'effort': 'low'});
  });

  test('思考摘要在正文之前流式到达，不混进业务JSON，done替换而不重复追加', () async {
    final seen = Completer<void>();
    final release = Completer<void>();
    server = await LocalAiServer.start((request, body) async {
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write(sseEvent({
        'type': 'response.reasoning_summary_text.delta',
        'item_id': 'reason',
        'output_index': 0,
        'summary_index': 0,
        'delta': '测试摘要前半段',
      }));
      await request.response.flush();
      await release.future;
      request.response.write(sseEvent({
        'type': 'response.reasoning_summary_text.done',
        'item_id': 'reason',
        'output_index': 0,
        'summary_index': 0,
        'text': '测试摘要前半段，后半段',
      }));
      await servePayload(request, finalPayload(reply: '测试正文'),
          writeHeaders: false);
    });
    final thoughts = <String>[];
    final replies = <String>[];
    final running = generate(
        onReasoning: (value) {
          thoughts.add(value);
          if (!seen.isCompleted) seen.complete();
        },
        onReply: replies.add);
    await seen.future;
    expect(thoughts.single, '测试摘要前半段');
    expect(replies, isEmpty);
    release.complete();
    expect((await running)['reply'], '测试正文');
    expect(thoughts.last, '测试摘要前半段，后半段');
  });

  test('公开reasoning_text及完成摘要均可读取，不显示加密内容', () async {
    server = await LocalAiServer.start((request, body) async {
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write(sseEvent({
        'type': 'response.reasoning_text.delta',
        'item_id': 'r',
        'output_index': 0,
        'content_index': 0,
        'delta': '接口公开返回的测试说明',
      }));
      request.response.write(sseEvent({
        'type': 'response.output_item.done',
        'output_index': 0,
        'item': {
          'id': 'r',
          'type': 'reasoning',
          'encrypted_content': 'never-show-encrypted',
          'summary': [
            {'type': 'summary_text', 'text': '完成的测试摘要'}
          ]
        }
      }));
      await servePayload(request, finalPayload(), writeHeaders: false);
    });
    final thoughts = <String>[];
    await generate(onReasoning: thoughts.add);
    expect(thoughts.first, '接口公开返回的测试说明');
    expect(thoughts.last, '完成的测试摘要');
    expect(thoughts.join(), isNot(contains('never-show-encrypted')));
  });

  test('非流式仍需完成状态，不依赖 output 第一项', () async {
    server = await LocalAiServer.start((request, body) async {
      final response =
          completedResponse(jsonEncode(finalPayload(reply: '视觉摘要示例')));
      (response['output'] as List).insert(0, {'type': 'reasoning'});
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    expect((await generate(stream: false))['reply'], '视觉摘要示例');
  });

  test('收到有效 completed 即返回，不等待服务端关闭长连接', () async {
    final payload = finalPayload(reply: '主模型已完整完成');
    server = await LocalAiServer.start((request, body) =>
        servePayload(request, payload, closeResponse: false));
    expect(await generate().timeout(const Duration(seconds: 2)), payload);
    expect(server.calls, hasLength(1));
  });

  test('断流没有 completed 时失败，不接受已生成的 actions', () async {
    server = await LocalAiServer.start((request, body) =>
        servePayload(request, finalPayload(), completed: false));
    await expectLater(generate(),
        throwsA(isA<AppError>().having((e) => e.code, 'code', 'model')));
  });

  test('delta 与最终响应不同会拒绝，不使用两份回复拼接结果', () async {
    server = await LocalAiServer.start((request, body) => servePayload(
        request, finalPayload(reply: '最终回复'),
        streamedText: jsonEncode(finalPayload(reply: '不同回复'))));
    await expectLater(generate(),
        throwsA(isA<AppError>().having((e) => e.code, 'code', 'model')));
  });

  for (final type in [
    'response.failed',
    'response.incomplete',
    'response.refusal.delta'
  ]) {
    test('$type 作为失败，不把中间输出当成功', () async {
      server = await LocalAiServer.start((request, body) async {
        request.response.write(sseEvent({'type': type}));
        await request.response.close();
      });
      await expectLater(generate(),
          throwsA(isA<AppError>().having((e) => e.code, 'code', 'model')));
    });
  }

  test('401 属于配置错误；重定向不会跟随并泄露 Bearer Key', () async {
    var unauthorized = true;
    server = await LocalAiServer.start((request, body) async {
      request.response.statusCode = unauthorized ? 401 : 302;
      if (!unauthorized) {
        request.response.headers
            .set('location', '${server.baseUrl}/redirect-target');
      }
      await request.response.close();
    });
    await expectLater(
        generate(),
        throwsA(
            isA<AppError>().having((e) => e.code, 'code', 'configuration')));
    unauthorized = false;
    await expectLater(generate(), throwsA(isA<AppError>()));
    expect(server.calls, hasLength(2));
    expect(server.calls.every((c) => c['path'] == '/v1/responses'), isTrue);
  });

  test('取消正在等待的 HTTP 请求会结束 Future，并保留 cancelled 语义', () async {
    final arrived = Completer<void>();
    server = await LocalAiServer.start((request, body) async {
      arrived.complete();
    });
    final token = RequestToken();
    final expected = expectLater(generate(token: token),
        throwsA(isA<AppError>().having((e) => e.code, 'code', 'cancelled')));
    await arrived.future;
    token.cancel();
    await expected;
  });

  test('到期中断连接并返回网络超时，不永久挂住界面', () async {
    server = await LocalAiServer.start((request, body) async {});
    await expectLater(
        generate(deadline: const Duration(milliseconds: 100)),
        throwsA(isA<AppError>()
            .having((e) => e.code, 'code', 'network')
            .having((e) => e.message, 'message', contains('超时'))));
  });
}
