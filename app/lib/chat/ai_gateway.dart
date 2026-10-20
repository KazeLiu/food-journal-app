import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/data.dart';

class RequestToken {
  bool cancelled = false;
  void Function()? _abort;
  void cancel() {
    cancelled = true;
    _abort?.call();
  }

  void check() => require(!cancelled, '已停止当前任务', 'cancelled');
}

class _ReasoningOutput {
  final summary = <String, Map<int, String>>{};
  final content = <String, Map<int, String>>{};
  final order = <String, int>{};

  bool event(Json event) {
    final type = event['type'];
    if (['response.output_item.added', 'response.output_item.done']
        .contains(type)) {
      if (event['item'] is Map && event['item']['type'] == 'reasoning') {
        item(event['item'] as Map,
            event['output_index'] as int? ?? order.length);
        return true;
      }
      return false;
    }
    final isSummary = [
      'response.reasoning_summary_text.delta',
      'response.reasoning_summary_text.done'
    ].contains(type);
    if (!isSummary &&
        !['response.reasoning_text.delta', 'response.reasoning_text.done']
            .contains(type)) return false;
    final id = event['item_id'];
    final index = event[isSummary ? 'summary_index' : 'content_index'];
    final text = event[(type as String).endsWith('.delta') ? 'delta' : 'text'];
    if (id is! String || index is! int || text is! String) return false;
    order[id] = event['output_index'] as int? ?? order[id] ?? order.length;
    final parts = (isSummary ? summary : content).putIfAbsent(id, () => {});
    parts[index] =
        type.endsWith('.delta') ? '${parts[index] ?? ''}$text' : text;
    return true;
  }

  void item(Map item, int index) {
    if (item['type'] != 'reasoning' || item['id'] is! String) return;
    final id = item['id'] as String;
    order[id] = index;
    for (final entry in {'summary': summary, 'content': content}.entries) {
      final parts = item[entry.key];
      if (parts is! List) continue;
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        if (part is Map &&
            ['summary_text', 'reasoning_text'].contains(part['type']) &&
            part['text'] is String) {
          entry.value.putIfAbsent(id, () => {})[i] = part['text'] as String;
        }
      }
    }
  }

  String get text {
    final ids = order.keys.toList()
      ..sort((a, b) => order[a]!.compareTo(order[b]!));
    String join(Map<int, String> parts) =>
        (parts.keys.toList()..sort()).map((i) => parts[i]!).join('\n\n');
    return ids
        .map((id) {
          final short = join(summary[id] ?? {});
          return short.isNotEmpty ? short : join(content[id] ?? {});
        })
        .where((s) => s.isNotEmpty)
        .join('\n\n');
  }
}

class AiGateway {
  Future<List<String>> models(
      String baseUrl, String key, RequestToken token) async {
    final response = await _request(
        baseUrl, key, 'models', null, token, const Duration(seconds: 30));
    final body = jsonMap(response);
    require(body['data'] is List, '模型列表格式不正确');
    return (body['data'] as List)
        .whereType<Map>()
        .map((e) => e['id'])
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();
  }

  Future<Json> generate(
      {required String baseUrl,
      required String key,
      required String model,
      required String instructions,
      required List<Json> input,
      required bool stream,
      required RequestToken token,
      required Duration deadline,
      String? reasoningEffort,
      bool requestReasoningSummary = false,
      void Function(String)? onReasoning,
      void Function(String)? onReply}) async {
    final client =
        IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 30));
    token.check();
    token._abort = client.close;
    var timedOut = false;
    final timer = Timer(deadline, () {
      timedOut = true;
      client.close();
    });
    try {
      final request = http.Request('POST', Uri.parse('$baseUrl/responses'))
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer $key',
          'Content-Type': 'application/json'
        })
        ..body = jsonEncode({
          'model': model,
          'store': false,
          'stream': stream,
          if (reasoningEffort != null || requestReasoningSummary)
            'reasoning': {
              if (reasoningEffort != null) 'effort': reasoningEffort,
              if (requestReasoningSummary) 'summary': 'auto',
            },
          'instructions': instructions,
          'input': input
        });
      final response = await client.send(request);
      _checkHttp(response.statusCode);
      Json? finalResponse;
      final reasoning = _ReasoningOutput();
      var lastReasoning = '';
      void emitReasoning() {
        final value = reasoning.text;
        if (value != lastReasoning) {
          lastReasoning = value;
          onReasoning?.call(value);
        }
      }

      final chunks = <String, Map<int, String>>{};
      final excludedItems = <String>{};
      if (!stream) {
        finalResponse = jsonMap(await response.stream.bytesToString());
      } else {
        final data = <String>[];
        void event() {
          if (data.isEmpty) return;
          final raw = data.join('\n');
          data.clear();
          if (raw == '[DONE]') return;
          final e = jsonMap(raw);
          final type = e['type'];
          if (reasoning.event(e)) emitReasoning();
          if (type == 'response.output_item.added' && e['item'] is Map) {
            final item = e['item'] as Map;
            if (item['type'] != 'message' ||
                item['role'] != 'assistant' ||
                item['phase'] == 'commentary') {
              excludedItems.add(item['id'] as String);
            }
          }
          if (type == 'response.output_text.delta') {
            if (excludedItems.contains(e['item_id'])) return;
            final parts = chunks.putIfAbsent(
                e['item_id'] as String, () => <int, String>{});
            final index = e['content_index'] as int;
            parts[index] = (parts[index] ?? '') + (e['delta'] as String);
            onReply?.call(ReplyDecoder.read(_joinParts(parts)));
          }
          if (type == 'response.completed') {
            finalResponse = Map<String, dynamic>.from(e['response'] as Map);
          }
          if (['response.failed', 'response.incomplete', 'error']
                  .contains(type) ||
              type == 'response.refusal.delta') {
            throw const AppError('模型没有完成有效回复', 'model');
          }
        }

        await for (final line in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          token.check();
          if (line.isEmpty) {
            event();
            if (finalResponse != null) break;
          } else if (line.startsWith('data:')) {
            data.add(line.substring(5).trimLeft());
          }
        }
        event();
      }
      token.check();
      require(finalResponse != null && finalResponse!['status'] == 'completed',
          '回复中断或未完成', 'model');
      require(!timedOut, '模型请求超时', 'network');
      if (finalResponse!['output'] is List) {
        final items = finalResponse!['output'] as List;
        for (var i = 0; i < items.length; i++) {
          if (items[i] is Map) reasoning.item(items[i] as Map, i);
        }
        emitReasoning();
      }
      final (itemId, text) = _finalText(finalResponse!);
      if (stream) {
        require(
            chunks.containsKey(itemId) && _joinParts(chunks[itemId]!) == text,
            '流式文本与完成响应不一致',
            'model');
      }
      final result = jsonMap(text);
      require(result['protocol_version'] == 1, '模型返回了不支持的协议版本', 'model');
      return result;
    } on AppError {
      rethrow;
    } on FormatException {
      throw const AppError('模型回复不符合 JSON 协议', 'model');
    } on TypeError {
      throw const AppError('模型响应字段或类型不正确', 'model');
    } on IOException {
      token.check();
      throw AppError(timedOut ? '模型请求超时' : '网络连接失败，请检查服务地址', 'network');
    } on http.ClientException {
      token.check();
      throw AppError(timedOut ? '模型请求超时' : '网络请求已中断', 'network');
    } finally {
      timer.cancel();
      token._abort = null;
      client.close();
    }
  }

  Future<String> _request(String baseUrl, String key, String path, Json? body,
      RequestToken token, Duration duration) async {
    final client =
        IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 30));
    token.check();
    token._abort = client.close;
    final timer = Timer(duration, client.close);
    try {
      final request = http.Request(
          body == null ? 'GET' : 'POST', Uri.parse('$baseUrl/$path'))
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer $key';
      final response = await client.send(request);
      _checkHttp(response.statusCode);
      final value = await response.stream.bytesToString();
      token.check();
      return value;
    } on IOException {
      token.check();
      throw const AppError('无法读取模型列表');
    } on http.ClientException {
      token.check();
      throw const AppError('模型列表请求中断');
    } finally {
      timer.cancel();
      token._abort = null;
      client.close();
    }
  }

  void _checkHttp(int code) {
    require(
        code >= 200 && code < 300,
        code == 401 || code == 403
            ? 'AI 授权失败（HTTP $code），请检查 Key 和服务权限'
            : code >= 300 && code < 400
                ? '服务发生重定向，为保护 Key 已拒绝跟随'
                : 'AI 服务请求失败（HTTP $code）',
        code == 401 || code == 403 ? 'configuration' : 'model');
  }

  String _joinParts(Map<int, String> parts) {
    final indices = parts.keys.toList()..sort();
    return indices.map((i) => parts[i]).join();
  }

  (String, String) _finalText(Json response) {
    require(response['output'] is List, '模型没有返回 output', 'model');
    final messages = (response['output'] as List)
        .whereType<Map>()
        .where((e) =>
            e['type'] == 'message' &&
            e['role'] == 'assistant' &&
            e['phase'] != 'commentary' &&
            e['status'] == 'completed')
        .toList();
    require(messages.isNotEmpty, '模型没有返回完成的助手消息', 'model');
    final content = messages.last['content'] as List;
    require(!content.any((e) => e['type'] == 'refusal'), '模型拒绝了本次请求', 'model');
    final text = content
        .where((e) => e['type'] == 'output_text')
        .map((e) => e['text'] as String)
        .join();
    require(text.trim().isNotEmpty, '模型返回了空回复', 'model');
    return (messages.last['id'] as String, text);
  }
}

/// 只读取顶层 reply 字符串。未完成的转义和 Unicode 代理对留待下一段。
class ReplyDecoder {
  static String read(String input) {
    var depth = 0;
    var i = 0;
    while (i < input.length) {
      final c = input[i];
      if (c == '{' || c == '[') {
        depth++;
        i++;
        continue;
      }
      if (c == '}' || c == ']') {
        depth--;
        i++;
        continue;
      }
      if (c != '"') {
        i++;
        continue;
      }
      final start = i++;
      var escaped = false;
      var closed = false;
      while (i < input.length) {
        final v = input[i++];
        if (escaped) {
          escaped = false;
          continue;
        }
        if (v == '\\') {
          escaped = true;
          continue;
        }
        if (v == '"') {
          closed = true;
          break;
        }
      }
      if (!closed) return '';
      if (depth != 1 || jsonDecode(input.substring(start, i)) != 'reply') {
        continue;
      }
      while (i < input.length && input[i].trim().isEmpty) {
        i++;
      }
      if (i >= input.length || input[i++] != ':') continue;
      while (i < input.length && input[i].trim().isEmpty) {
        i++;
      }
      if (i >= input.length || input[i++] != '"') return '';
      final buffer = StringBuffer();
      while (i < input.length) {
        var code = input.codeUnitAt(i++);
        if (code == 34) break;
        if (code == 92) {
          if (i >= input.length) break;
          final escape = input[i++];
          if (escape == 'u') {
            if (i + 4 > input.length) break;
            final parsed = int.tryParse(input.substring(i, i + 4), radix: 16);
            if (parsed == null) break;
            code = parsed;
            i += 4;
            if (code >= 0xD800 && code <= 0xDBFF) {
              if (i + 6 > input.length || input.substring(i, i + 2) != r'\u') {
                break;
              }
              final low =
                  int.tryParse(input.substring(i + 2, i + 6), radix: 16);
              if (low == null || low < 0xDC00 || low > 0xDFFF) break;
              buffer.writeCharCode(code);
              buffer.writeCharCode(low);
              i += 6;
              continue;
            }
          } else {
            final mapping = {
              '"': 34,
              '\\': 92,
              '/': 47,
              'b': 8,
              'f': 12,
              'n': 10,
              'r': 13,
              't': 9
            };
            if (!mapping.containsKey(escape)) break;
            code = mapping[escape]!;
          }
        }
        if (code >= 0xD800 && code <= 0xDBFF && i == input.length) break;
        buffer.writeCharCode(code);
      }
      return buffer.toString();
    }
    return '';
  }
}
