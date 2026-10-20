import 'package:flutter/material.dart';

import 'data.dart';

Future<void> perform(
    BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (error) {
    if (context.mounted) {
      showNotice(
          context, error is AppError ? error.message : '操作未完成，请检查存储或配置后重试');
    }
  }
}

void showNotice(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));

/// 等输入弹窗退出并移除后再返回，调用方此时才能释放输入控制器。
Future<T?> showInputDialog<T>(
    {required BuildContext context, required WidgetBuilder builder}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<T>(
      context: context,
      builder: builder,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop);
  final result = await navigator.push(route);
  await route.completed;
  return result;
}

Future<bool> confirm(BuildContext context, String title, String body,
        {String accept = '确认'}) async =>
    await showDialog<bool>(
        context: context,
        builder: (context) =>
            AlertDialog(title: Text(title), content: Text(body), actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(accept)),
            ])) ??
    false;

class DisclosureInteraction extends Notification {}

class CompactDisclosure extends StatefulWidget {
  final String title;
  final Widget child;
  final bool autoExpanded;
  final bool collapseOnContentTap;
  final TextStyle? titleStyle;
  const CompactDisclosure(
      {required this.title,
      required this.child,
      this.autoExpanded = false,
      this.collapseOnContentTap = false,
      this.titleStyle,
      super.key});

  @override
  State<CompactDisclosure> createState() => _CompactDisclosureState();
}

class _CompactDisclosureState extends State<CompactDisclosure> {
  late bool expanded = widget.autoExpanded;

  void _change(bool value, {bool manual = true}) {
    final scrolling = Scrollable.maybeOf(context);
    final box = context.findRenderObject() as RenderBox?;
    final viewport = scrolling?.context.findRenderObject() as RenderBox?;
    final before = box?.localToGlobal(Offset.zero).dy;
    final top = viewport?.localToGlobal(Offset.zero).dy;
    final target = before == null || top == null
        ? before
        : before.clamp(
            top, top + (viewport!.size.height - 48).clamp(0, double.infinity));
    if (manual) DisclosureInteraction().dispatch(context);
    setState(() => expanded = value);
    if (scrolling == null || target == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scrolling.mounted || !scrolling.position.hasPixels) {
        return;
      }
      final current = context.findRenderObject() as RenderBox;
      final delta = current.localToGlobal(Offset.zero).dy - target;
      final position = scrolling.position;
      if (delta.abs() < .5) return;
      final direction = position.axisDirection == AxisDirection.up ? -1 : 1;
      position.jumpTo((position.pixels + delta * direction)
          .clamp(position.minScrollExtent, position.maxScrollExtent));
    });
  }

  @override
  void didUpdateWidget(CompactDisclosure oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.autoExpanded != widget.autoExpanded) {
      _change(widget.autoExpanded, manual: false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
                expanded: expanded,
                child: TextButton(
                    style: TextButton.styleFrom(
                        foregroundColor:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                        minimumSize: const Size(0, 48),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        alignment: Alignment.centerLeft),
                    onPressed: () => _change(!expanded),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(
                          child: Text(widget.title,
                              style: widget.titleStyle ??
                                  Theme.of(context).textTheme.bodySmall)),
                      const SizedBox(width: 4),
                      Icon(expanded ? Icons.expand_less : Icons.expand_more,
                          size: 18),
                    ]))),
            if (expanded)
              widget.collapseOnContentTap
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _change(false),
                      child: widget.child)
                  : widget.child,
          ]);
}

class EmptyView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;
  const EmptyView(this.title,
      {this.icon = Icons.spa_outlined, this.body, this.action, super.key});
  @override
  Widget build(BuildContext context) => Center(
      child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(title,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center),
            if (body != null) ...[
              const SizedBox(height: 8),
              Text(body!,
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center)
            ],
            if (action != null) ...[const SizedBox(height: 16), action!]
          ])));
}

class ConfirmExit extends StatefulWidget {
  final Future<bool> Function() onExit;
  final Widget child;
  const ConfirmExit({required this.onExit, required this.child, super.key});
  @override
  State<ConfirmExit> createState() => _ConfirmExitState();
}

class _ConfirmExitState extends State<ConfirmExit> {
  bool asking = false;
  @override
  Widget build(BuildContext context) => PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop || asking) return;
        asking = true;
        try {
          final exit = await widget.onExit();
          if (exit && context.mounted) Navigator.pop(context);
        } finally {
          asking = false;
        }
      },
      child: widget.child);
}

class DataView<T> extends StatelessWidget {
  final Future<T> future;
  final Widget Function(T) builder;
  const DataView({required this.future, required this.builder, super.key});
  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const EmptyView('内容暂时无法读取',
              body: '返回后重试，或检查设备存储空间。', icon: Icons.info_outline);
        }
        if (!snapshot.hasData) {
          return const Center(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator()));
        }
        return builder(snapshot.data as T);
      });
}

class SectionTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const SectionTitle(this.title, {this.trailing, super.key});
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 12),
      child: Row(children: [
        Expanded(
            child: Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600))),
        if (trailing != null) trailing!
      ]));
}

class NutritionSummary extends StatelessWidget {
  final Json totals;
  const NutritionSummary(this.totals, {super.key});
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final cells = List.generate(3, (index) {
          final field = nutritionFields[index + 1];
          final missing = totals['missing_$field'] as int? ?? 0;
          return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primaryContainer
                      .withOpacity(.45),
                  borderRadius: BorderRadius.circular(16)),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(nutritionNames[index + 1],
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 4),
                    Text(
                        totals['item_count'] == missing
                            ? '待估算'
                            : '${numberText(totals[field] as num)} g',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (missing > 0)
                      Text('$missing 项待估算',
                          style: Theme.of(context).textTheme.bodySmall),
                  ]));
        });
        if (MediaQuery.textScalerOf(context).scale(16) > 22 ||
            constraints.maxWidth < 300) {
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: cells
                  .map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8), child: e))
                  .toList());
        }
        return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: cells
                .map((e) => Expanded(
                    child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: e)))
                .toList());
      });
}
