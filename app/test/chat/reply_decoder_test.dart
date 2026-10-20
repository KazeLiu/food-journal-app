import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/chat/ai_gateway.dart';
import 'package:food_journal/core/data.dart';

void main() {
  group('流式 reply 解码', () {
    test('只读取顶层 reply，不泄露嵌套字段或 actions', () {
      expect(
          ReplyDecoder.read(jsonEncode({
            'context': {'reply': '不显示'},
            'reply': '正在整理',
            'actions': [
              {'reply': '也不显示', 'id': 'private-record'}
            ]
          })),
          '正在整理');
    });
    test('缺少或尚未开始 reply 时不显示协议', () {
      for (final input in [
        '',
        '{',
        '{"protocol_version":1,"rep',
        '{"reply":',
        '{"reply":null}',
        '{"actions":[{"reply":"不显示"}]}',
      ]) {
        expect(ReplyDecoder.read(input), '', reason: input);
      }
    });
    test('引号、反斜杠、换行和 Unicode 代理对在任意边界均保持有效前缀', () {
      const input = r'{"reply":"你说：\"半碗\"\n好\\的 \uD83C\uDF5C","actions":[]}';
      const expected = '你说："半碗"\n好\\的 🍜';
      for (var end = 0; end <= input.length; end++) {
        final decoded = ReplyDecoder.read(input.substring(0, end));
        expect(expected.startsWith(decoded), isTrue, reason: '截断位置 $end');
      }
      expect(ReplyDecoder.read(input), expected);
    });
    test('未完成的 Unicode 和代理对不提前输出半个字符', () {
      expect(ReplyDecoder.read(r'{"reply":"好\u4F'), '好');
      expect(ReplyDecoder.read(r'{"reply":"好\uD83C'), '好');
      expect(ReplyDecoder.read(r'{"reply":"好\uD83C\uDF'), '好');
      expect(ReplyDecoder.read(r'{"reply":"好\uD83C\uDF5C'), '好🍜');
    });
    test('普通文字中的花括号和字段名不改变结构判断', () {
      const reply = '我看到 {半碗}，不是 "reply" 字段。';
      expect(ReplyDecoder.read(jsonEncode({'reply': reply, 'actions': []})),
          reply);
    });
  });

  test('停止令牌可重复取消，后续检查统一返回 cancelled', () {
    final token = RequestToken()
      ..cancel()
      ..cancel();
    expect(token.check,
        throwsA(isA<AppError>().having((e) => e.code, 'code', 'cancelled')));
  });
}
