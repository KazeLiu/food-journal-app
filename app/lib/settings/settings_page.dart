import 'package:flutter/material.dart';

import '../app.dart';
import '../core/data.dart';
import '../core/widgets.dart';
import '../data_management/data_page.dart';
import '../library/library_page.dart';
import 'ai_settings_page.dart';
import 'settings_repository.dart';

class SettingsPage extends StatelessWidget {
  final AppServices s;
  const SettingsPage(this.s, {super.key});
  @override
  Widget build(BuildContext context) => SafeArea(
          child: Column(children: [
        AppBar(title: const Text('我的')),
        Expanded(
            child: AnimatedBuilder(
                animation: s.records,
                builder: (context, _) => DataView<Json>(
                    future: _load(),
                    builder: (data) => ListView(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                            children: [
                              const SectionTitle('日常设置'),
                              Card(
                                  child: Column(children: [
                                ListTile(
                                    leading:
                                        const Icon(Icons.auto_awesome_outlined),
                                    title: const Text('AI 接口与模型'),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) =>
                                                AiSettingsPage(s)))),
                                ListTile(
                                    leading: const Icon(
                                        Icons.monitor_weight_outlined),
                                    title: const Text('体重单位'),
                                    trailing: DropdownButton<String>(
                                        value: data['unit'] as String,
                                        items: const [
                                          DropdownMenuItem(
                                              value: 'jin', child: Text('斤')),
                                          DropdownMenuItem(
                                              value: 'kg', child: Text('公斤'))
                                        ],
                                        onChanged: (v) => perform(
                                            context,
                                            () => s.settings
                                                .set('weight_unit', v)))),
                                ListTile(
                                    leading: const Icon(Icons.palette_outlined),
                                    title: const Text('外观'),
                                    trailing: DropdownButton<String>(
                                        value: data['theme'] as String,
                                        items: const [
                                          DropdownMenuItem(
                                              value: 'system',
                                              child: Text('跟随系统')),
                                          DropdownMenuItem(
                                              value: 'light',
                                              child: Text('浅色')),
                                          DropdownMenuItem(
                                              value: 'dark', child: Text('深色'))
                                        ],
                                        onChanged: (v) => perform(
                                            context,
                                            () => s.settings
                                                .set('theme_mode', v)))),
                              ])),
                              const SectionTitle('估算参考（可选）'),
                              Card(
                                  child: Column(children: [
                                ListTile(
                                    leading: const Icon(Icons.height),
                                    title: const Text('身高'),
                                    trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(data['body']['height_cm'] == null
                                              ? '未设置'
                                              : '${numberText(data['body']['height_cm'] as num, 2)} cm'),
                                          const Icon(Icons.chevron_right)
                                        ]),
                                    onTap: () => perform(
                                        context,
                                        () => _editHeight(
                                            context,
                                            data['body']['height_cm']
                                                as num?))),
                                ListTile(
                                    leading: const Icon(Icons.person_outline),
                                    title: const Text('性别'),
                                    trailing: DropdownButton<String>(
                                        value: data['body']['sex'] as String? ??
                                            'unset',
                                        items: const [
                                          DropdownMenuItem(
                                              value: 'unset',
                                              child: Text('未设置')),
                                          DropdownMenuItem(
                                              value: 'male', child: Text('男')),
                                          DropdownMenuItem(
                                              value: 'female', child: Text('女'))
                                        ],
                                        onChanged: (v) => perform(
                                            context,
                                            () => s.settings.set('sex',
                                                v == 'unset' ? null : v)))),
                              ])),
                              const SectionTitle('只保存你同意的资料'),
                              Card(
                                  child: Column(children: [
                                ListTile(
                                    leading:
                                        const Icon(Icons.menu_book_outlined),
                                    title: const Text('食品资料库'),
                                    subtitle: const Text('常用餐食与包装食品'),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => LibraryPage(s)))),
                                ListTile(
                                    leading:
                                        const Icon(Icons.psychology_outlined),
                                    title: const Text('AI 记忆'),
                                    subtitle: const Text('查看、修改或删除已确认偏好'),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => LibraryPage(s,
                                                memories: true)))),
                              ])),
                              const SectionTitle('你的数据'),
                              Card(
                                  child: ListTile(
                                      leading:
                                          const Icon(Icons.folder_outlined),
                                      title: const Text('导出、备份与恢复'),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: () => Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                              builder: (_) => DataPage(s))))),
                              const SizedBox(height: 24),
                              const Text(
                                  'AI 减脂伙伴 · 0.1.20\n本地保存，无账号、广告或分析上传。\nAI 估算用于个人记录，不替代专业营养或医疗建议。',
                                  style: TextStyle(fontSize: 14),
                                  textAlign: TextAlign.center),
                            ])))),
      ]));
  Future<Json> _load() async => {
        'unit': await s.settings.get('weight_unit', 'jin'),
        'theme': await s.settings.get('theme_mode', 'system'),
        'body': await s.settings.bodyProfile()
      };

  Future<void> _editHeight(BuildContext context, num? height) async {
    final controller = TextEditingController(text: height?.toString() ?? '');
    String? error;
    Json? result;
    try {
      result = await showInputDialog<Json>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
              builder: (context, setModal) => AlertDialog(
                      title: const Text('身高'),
                      content: TextField(
                          controller: controller,
                          autofocus: true,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: InputDecoration(
                              labelText: '身高',
                              suffixText: 'cm',
                              helperText: '可留空清除。',
                              errorMaxLines: 3,
                              errorText: error)),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('取消')),
                        FilledButton(
                            onPressed: () {
                              final raw = controller.text.trim();
                              final value =
                                  raw.isEmpty ? null : num.tryParse(raw);
                              try {
                                require(raw.isEmpty || value != null,
                                    '请输入有效的身高（厘米）');
                                SettingsRepository.validateBodyProfile(
                                    {'height_cm': value});
                              } on AppError catch (e) {
                                setModal(() => error = e.message);
                                return;
                              }
                              Navigator.pop(
                                  dialogContext, {'height_cm': value});
                            },
                            child: const Text('保存'))
                      ])));
    } finally {
      controller.dispose();
    }
    if (result != null) {
      await s.settings.set('height_cm', result['height_cm']);
    }
  }
}
