import 'package:flutter/material.dart';
import '../core/widgets.dart';

class ReasoningView extends StatefulWidget {
  final String text;
  final bool thinking;
  const ReasoningView({required this.text, this.thinking = false, super.key});

  @override
  State<ReasoningView> createState() => _ReasoningViewState();
}

class _ReasoningViewState extends State<ReasoningView> {
  final scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _followThinking();
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  void _followThinking() {
    if (!widget.thinking) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.thinking && scroll.hasClients) {
        scroll.jumpTo(scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void didUpdateWidget(ReasoningView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.thinking != widget.thinking) {
      _followThinking();
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final style = Theme.of(context).textTheme.bodySmall!.copyWith(
        color: color, fontSize: 13, fontStyle: FontStyle.italic, height: 1.5);
    return CompactDisclosure(
        title: widget.thinking ? '思考中…' : '思考摘要',
        titleStyle: style,
        autoExpanded: widget.thinking,
        collapseOnContentTap: true,
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
                controller: scroll,
                primary: false,
                child: Text(widget.text, style: style))));
  }
}
