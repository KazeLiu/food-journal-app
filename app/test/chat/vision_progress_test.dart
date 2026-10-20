import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/chat/vision_progress.dart';

void main() {
  test('识图预估在两分钟内逐渐放慢，停在95%而不伪报完成', () {
    final values = [0, 30, 60, 90, 120]
        .map((seconds) => estimatedVisionProgress(Duration(seconds: seconds)))
        .toList();
    expect(values.first, 0);
    expect(values.last, .95);
    final increments = [
      for (var i = 1; i < values.length; i++) values[i] - values[i - 1]
    ];
    for (var i = 1; i < increments.length; i++) {
      expect(increments[i], greaterThan(0));
      expect(increments[i], lessThan(increments[i - 1]));
    }
    expect(estimatedVisionProgress(const Duration(seconds: -1)), 0);
    expect(estimatedVisionProgress(const Duration(days: 1)), .95);
  });

  testWidgets('上传使用实际百分比，上传耗时不提前推进识别预估', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: ImageRequestProgress(
                uploading: true, sentBytes: 250000, totalBytes: 1000000))));
    expect(find.text('上传图片'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(find.byType(VisionProgress), findsNothing);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        .25);
    await tester.pump(const Duration(minutes: 3));
    expect(find.text('这次识别貌似有点长，请耐心等待。'), findsNothing);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ImageRequestProgress(
                uploading: false,
                sentBytes: 1000000,
                totalBytes: 1000000,
                waitingStartedAt: DateTime.now()))));
    expect(find.text('等待识别结果'), findsOneWidget);
    expect(find.textContaining('图片请求已发出'), findsOneWidget);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        lessThan(.01));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('重建按原识图起点恢复，超过两分钟提示等待，新起点重置', (tester) async {
    Future<void> open(DateTime start) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: VisionProgress(startedAt: start))));
    double progress() => tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
        .value!;

    final start = DateTime.now().subtract(const Duration(seconds: 60));
    await open(start);
    expect(progress(), closeTo(.7125, .01));
    await tester.pumpWidget(const SizedBox());
    await open(start);
    expect(progress(), closeTo(.7125, .01));
    expect(find.text('预估进度'), findsOneWidget);
    expect(find.text('这次识别貌似有点长，请耐心等待。'), findsNothing);

    await open(DateTime.now().subtract(const Duration(seconds: 121)));
    expect(progress(), .95);
    expect(find.text('95%'), findsOneWidget);
    expect(find.text('这次识别貌似有点长，请耐心等待。'), findsOneWidget);
    await open(DateTime.now());
    expect(progress(), lessThan(.01));
    expect(find.text('这次识别貌似有点长，请耐心等待。'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 3));
    expect(tester.takeException(), isNull);
  });
}
