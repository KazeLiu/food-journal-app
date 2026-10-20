import 'dart:convert';
import 'dart:io';

import 'package:food_journal/core/data.dart';

class _TestHttpOverrides extends HttpOverrides {}

/// 仅绑定本机随机端口；替代远端服务，不替换生产 HTTP / SSE 解析器。
class LocalAiServer {
  final HttpServer server;
  final List<Json> calls = [];
  LocalAiServer._(this.server);
  String get baseUrl => 'http://127.0.0.1:${server.port}/v1';

  // Flutter 测试默认将 HttpClient 替换为固定 400；仅本地服务用例解除该替身。
  Future<T> withClient<T>(Future<T> Function() action) =>
      HttpOverrides.runWithHttpOverrides(action, _TestHttpOverrides());

  static Future<LocalAiServer> start(
      Future<void> Function(HttpRequest request, Json body) handler) async {
    final result =
        LocalAiServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    result.server.listen((request) async {
      final text = await utf8.decoder.bind(request).join();
      final body = text.isEmpty ? <String, dynamic>{} : jsonMap(text);
      result.calls.add(
          {'method': request.method, 'path': request.uri.path, 'body': body});
      await handler(request, body);
    });
    return result;
  }

  Future<void> close() async => server.close(force: true);
}

Json finalPayload({String reply = '已理解', List<Json> actions = const []}) => {
      'protocol_version': 1,
      'outcome': 'final',
      'reply': reply,
      'queries': <Json>[],
      'actions': actions,
      'proposals': <Json>[]
    };

Json completedResponse(String text) => {
      'status': 'completed',
      'output': [
        {
          'id': 'assistant-result',
          'type': 'message',
          'role': 'assistant',
          'status': 'completed',
          'content': [
            {'type': 'output_text', 'text': text}
          ]
        }
      ]
    };

String sseEvent(Json event) =>
    'event: ${event['type']}\r\ndata: ${jsonEncode(event)}\r\n\r\n';

Future<void> servePayload(HttpRequest request, Json payload,
    {bool stream = true,
    bool completed = true,
    String? streamedText,
    bool closeResponse = true,
    bool writeHeaders = true}) async {
  final text = jsonEncode(payload);
  if (!stream) {
    if (writeHeaders) request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(completedResponse(text)));
  } else {
    if (writeHeaders) {
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
    }
    final delta = streamedText ?? text;
    final midpoint = delta.length ~/ 2;
    final events = [
      sseEvent({
        'type': 'response.output_item.added',
        'item': {
          'id': 'assistant-result',
          'type': 'message',
          'role': 'assistant'
        }
      }),
      for (final part in [
        delta.substring(0, midpoint),
        delta.substring(midpoint)
      ])
        sseEvent({
          'type': 'response.output_text.delta',
          'item_id': 'assistant-result',
          'content_index': 0,
          'delta': part
        }),
      if (completed)
        sseEvent(
            {'type': 'response.completed', 'response': completedResponse(text)})
    ].join();
    await request.response.addStream(
        Stream.fromIterable(utf8.encode(events).map((byte) => [byte])));
  }
  if (closeResponse) {
    await request.response.close();
  } else {
    await request.response.flush();
  }
}
