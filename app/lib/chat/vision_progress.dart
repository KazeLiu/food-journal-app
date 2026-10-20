import 'dart:async';

import 'package:flutter/material.dart';

const visionProgressDuration = Duration(minutes: 2);

double estimatedVisionProgress(Duration elapsed) {
  final fraction =
      (elapsed.inMilliseconds / visionProgressDuration.inMilliseconds)
          .clamp(0.0, 1.0);
  return .95 * (1 - (1 - fraction) * (1 - fraction));
}

class VisionProgress extends StatefulWidget {
  final DateTime startedAt;
  const VisionProgress({required this.startedAt, super.key});

  @override
  State<VisionProgress> createState() => _VisionProgressState();
}

class _VisionProgressState extends State<VisionProgress> {
  Timer? _timer;
  late Duration _elapsed;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(VisionProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startedAt != widget.startedAt) _start();
  }

  void _start() {
    _timer?.cancel();
    _elapsed = DateTime.now().difference(widget.startedAt);
    if (_elapsed >= visionProgressDuration) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsed = DateTime.now().difference(widget.startedAt));
      if (_elapsed >= visionProgressDuration) _timer?.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = estimatedVisionProgress(_elapsed);
    final percent = (progress * 100).floor();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('预估进度', style: TextStyle(fontSize: 14)),
        Text('$percent%', style: const TextStyle(fontSize: 14)),
      ]),
      const SizedBox(height: 8),
      ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              semanticsLabel: '预估识图进度',
              semanticsValue: '$percent%')),
      if (_elapsed >= visionProgressDuration) ...[
        const SizedBox(height: 8),
        Semantics(liveRegion: true, child: const Text('这次识别貌似有点长，请耐心等待。')),
      ],
    ]);
  }
}
