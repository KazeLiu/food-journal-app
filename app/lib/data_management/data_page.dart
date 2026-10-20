import 'package:flutter/material.dart';

import '../app.dart';
import '../core/data.dart';
import '../core/widgets.dart';

class DataPage extends StatefulWidget {
  final AppServices s;
  const DataPage(this.s, {super.key});
  @override
  State<DataPage> createState() => _DataPageState();
}

class _DataPageState extends State<DataPage> {
  bool busy = false;
  Future<void> _work(Future<void> Function() action) async {
    setState(() {
      busy = true;
    });
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  Future<String?> password({required bool exporting}) async {
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;
    final result = await showInputDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                    title: Text(exporting ? '备份密码（可选）' : '备份密码'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(exporting
                          ? '留空将导出私人明文文件。密码不会保存，忘记后无法解密。'
                          : '明文备份可留空；加密备份需填写原密码。'),
                      const SizedBox(height: 16),
                      TextField(
                          controller: first,
                          obscureText: true,
                          decoration: InputDecoration(
                              labelText: '密码', errorText: error)),
                      if (exporting) ...[
                        const SizedBox(height: 12),
                        TextField(
                            controller: second,
                            obscureText: true,
                            decoration:
                                const InputDecoration(labelText: '再次输入密码'))
                      ],
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () {
                            if (exporting && first.text != second.text) {
                              update(() {
                                error = '两次密码不一致';
                              });
                              return;
                            }
                            Navigator.pop(context, first.text);
                          },
                          child: const Text('继续'))
                    ])));
    first.dispose();
    second.dispose();
    return result;
  }

  Future<void> export() async {
    final pass = await password(exporting: true);
    if (pass == null) return;
    final path = await widget.s.backup.exportBackup(pass);
    if (mounted && path != null) showNotice(context, '完整备份已保存');
  }

  Future<void> restore({bool safety = false}) async {
    Json? data;
    if (safety) {
      data = await widget.s.backup.readSafety();
    } else {
      final pass = await password(exporting: false);
      if (pass == null) return;
      data = await widget.s.backup.pickBackup(pass);
    }
    if (data == null || !mounted) return;
    final dates = (data['meals'] as List)
        .map((m) => m['local_date'] as String)
        .toList()
      ..sort();
    if (!await confirm(
        context,
        '用这份备份替换本机记录？',
        '备份时间：${data['exported_at']}\n'
            '${dates.isEmpty ? '没有饮食记录' : '${dates.first} 至 ${dates.last}'}\n'
            '${(data['chat_messages'] as List).length} 条聊天，${(data['food_items'] as List).length} 项食物，${(data['weight_records'] as List).length} 次体重，${(data['food_library'] as List).length} 份食品资料，${(data['ai_memories'] as List).length} 项记忆。\n\n'
            '整库替换，不合并，当前聊天的图片预览会清除且无法从备份找回。当前 AI 地址、模型与 Key 保持不变。替换前会保存一份不含图片的内部安全副本。',
        accept: '确认替换')) return;
    await widget.s.backup.restore(data, fromSafety: safety);
    widget.s.settings.theme.value =
        await widget.s.settings.get('theme_mode', 'system') as String;
    widget.s.chatIntent.value = {'reset': true};
    if (mounted) showNotice(context, '恢复完成，未自动重放任何 AI 请求');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('数据管理')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (busy) const LinearProgressIndicator(),
        const SectionTitle('导出便于查看的 CSV'),
        const Text('未知营养留空。CSV 不包含完整聊天和撤销关系，不能用于恢复。',
            style: TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        OutlinedButton.icon(
            onPressed: busy
                ? null
                : () => perform(
                    context,
                    () => _work(() async {
                          final path = await widget.s.backup.exportCsv(false);
                          if (context.mounted && path != null) {
                            showNotice(context, '饮食 CSV 已保存');
                          }
                        })),
            icon: const Icon(Icons.table_view_outlined),
            label: const Text('导出饮食 CSV')),
        const SizedBox(height: 8),
        OutlinedButton(
            onPressed: busy
                ? null
                : () => perform(
                    context,
                    () => _work(() async {
                          final path = await widget.s.backup.exportCsv(true);
                          if (context.mounted && path != null) {
                            showNotice(context, '体重 CSV 已保存');
                          }
                        })),
            child: const Text('导出体重 CSV')),
        const SectionTitle('完整备份与恢复'),
        const Text(
            '包含记录、聊天、操作历史、食品资料和授权记忆，不包含 Key、AI 连接配置或图片预览。恢复会替换当前聊天，本机预览也会清除。',
            style: TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        FilledButton.icon(
            onPressed:
                busy ? null : () => perform(context, () => _work(export)),
            icon: const Icon(Icons.save_outlined),
            label: const Text('创建完整备份')),
        const SizedBox(height: 12),
        OutlinedButton.icon(
            onPressed:
                busy ? null : () => perform(context, () => _work(restore)),
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('从文件恢复')),
        const SizedBox(height: 8),
        TextButton(
            onPressed: busy
                ? null
                : () =>
                    perform(context, () => _work(() => restore(safety: true))),
            child: const Text('恢复上次替换前的数据')),
        const Text('内部安全副本只保留一份，卸载或清除数据后会丢失，不能替代外部备份。',
            style: TextStyle(fontSize: 14)),
        const SectionTitle('清除全部数据'),
        const Text('删除本机聊天、记录、资料、记忆、设置、Key、图片预览与安全副本。外部导出文件不会自动删除。',
            style: TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: busy
                ? null
                : () => perform(
                    context,
                    () => _work(() async {
                          if (!await confirm(
                              context, '清除本机全部数据？', '此操作无法撤销。只有你自行保存的外部备份可以恢复。',
                              accept: '清除全部')) return;
                          final failed = await widget.s.backup.clearAll();
                          widget.s.settings.theme.value = await widget
                              .s.settings
                              .get('theme_mode', 'system') as String;
                          if (!failed.contains('本地数据库')) {
                            widget.s.chatIntent.value = {'reset': true};
                          }
                          if (context.mounted) {
                            showNotice(
                                context,
                                failed.isEmpty
                                    ? '本机数据已清除'
                                    : '以下内容未能清除：${failed.join('、')}，请重试清除');
                          }
                        })),
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('清除本机全部数据')),
      ]));
}
