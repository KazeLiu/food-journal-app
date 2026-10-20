import 'package:flutter/material.dart';

import '../app.dart';
import '../chat/ai_gateway.dart';
import '../chat/prompts.dart';
import '../core/data.dart';
import '../core/widgets.dart';
import 'model_picker_dialog.dart';
import 'settings_repository.dart';

class AiSettingsPage extends StatefulWidget {
  final AppServices s;
  const AiSettingsPage(this.s, {super.key});
  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  final url = TextEditingController();
  final key = TextEditingController();
  final models = {
    for (final role in aiModelRoles) role: TextEditingController()
  };
  final efforts = {for (final role in aiModelRoles) role: ''};
  final labels = {
    'text_main': '文字主模型',
    'text_backup': '文字兜底模型',
    'vision_main': '图片主模型',
    'vision_backup': '图片兜底模型'
  };
  final gateway = AiGateway();
  final token = RequestToken();
  List<String> available = [];
  Map<String, String> results = {};
  bool allowHttp = false;
  bool requestReasoningSummary = false;
  bool visibleKey = false;
  bool busy = false;
  bool loading = true;
  bool savedKey = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profile = await widget.s.settings.get('ai_profile') as Json?;
    if (!mounted) return;
    if (profile != null) {
      url.text = profile['base_url'] as String;
      allowHttp = profile['allow_http'] == true;
      requestReasoningSummary = profile['request_reasoning_summary'] == true;
      for (final role in models.keys) {
        models[role]!.text = profile[role] as String? ?? '';
        efforts[role] = profile['${role}_effort'] as String? ?? '';
      }
      savedKey = true;
    }
    setState(() {
      loading = false;
    });
  }

  @override
  void dispose() {
    token.cancel();
    url.dispose();
    key.dispose();
    for (final c in models.values) {
      c.dispose();
    }
    super.dispose();
  }

  Json profile() => {
        'base_url': SettingsRepository.normalizeUrl(url.text, allowHttp),
        'allow_http': allowHttp,
        'request_reasoning_summary': requestReasoningSummary,
        for (final e in models.entries) e.key: e.value.text.trim(),
        for (final e in efforts.entries)
          if (e.value.isNotEmpty) '${e.key}_effort': e.value,
      };
  Future<String> credential() async => key.text.trim().isNotEmpty
      ? key.text.trim()
      : await widget.s.settings
          .keyFor(SettingsRepository.normalizeUrl(url.text, allowHttp));
  Future<void> _busy(Future<void> Function() action) async {
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

  Future<void> fetchModels() => _busy(() async {
        final list = await gateway.models(
            SettingsRepository.normalizeUrl(url.text, allowHttp),
            await credential(),
            token);
        if (mounted) {
          setState(() {
            available = list;
          });
        }
      });
  Future<void> save() => _busy(() async {
        await widget.s.settings.saveProfile(profile(), await credential());
        if (mounted) {
          key.clear();
          savedKey = true;
          showNotice(context, 'AI 配置已保存');
        }
      });
  Future<void> toggleKey() async {
    if (!visibleKey && key.text.isEmpty && savedKey) {
      key.text = await credential();
    }
    if (mounted) {
      setState(() {
        visibleKey = !visibleKey;
      });
    }
  }

  Future<void> checkModels() => _busy(() async {
        final p = profile();
        SettingsRepository.validateModels(p);
        if (!await confirm(context, '检查已填写的模型？',
            '仅检查已填写的模型，首次失败会在同一模型重试一次。图片检查使用内置非私人图片。请求可能计费，不会保存记录或触发补算。',
            accept: '开始检查')) return;
        final credentialValue = await credential();
        final cache = <String, String>{};
        results.clear();
        for (final role in models.keys) {
          final model = models[role]!.text.trim();
          if (model.isEmpty) continue;
          final vision = role.startsWith('vision');
          final cacheKey =
              '${vision ? 'vision' : 'text'}/$model/${efforts[role]}';
          if (!cache.containsKey(cacheKey)) {
            for (var attempt = 0; attempt < 2; attempt++) {
              token.check();
              if (mounted) {
                setState(() {
                  results[role] = attempt == 0 ? '检查中…' : '检查中 · 重试 1/1';
                });
              }
              try {
                final response = await gateway.generate(
                    baseUrl: p['base_url'] as String,
                    key: credentialValue,
                    model: model,
                    reasoningEffort: p['${role}_effort'] as String?,
                    requestReasoningSummary:
                        p['request_reasoning_summary'] == true,
                    instructions: vision ? visionPrompt : textPrompt,
                    stream: !vision,
                    token: token,
                    deadline: Duration(seconds: vision ? 120 : 90),
                    input: [
                      {
                        'role': 'user',
                        'content': [
                          {
                            'type': 'input_text',
                            'text': vision
                                ? '这是非食物测试图，请返回 non_food 和简短摘要。'
                                : '你好，只聊天，不记录，返回 final 和空 actions、queries、proposals。'
                          },
                          if (vision)
                            {
                              'type': 'input_image',
                              'image_url': 'data:image/png;base64,$_checkImage',
                              'detail': 'auto'
                            }
                        ]
                      }
                    ]);
                if (vision) {
                  require(
                      response['outcome'] == 'non_food' &&
                          response['summary'] is String,
                      '视觉摘要协议不符合要求');
                } else {
                  widget.s.chat.contexts
                      .validateEnvelope(response, lookupAllowed: false);
                  require(
                      (response['actions'] as List).isEmpty, '检查请求不应提出记录动作');
                }
                cache[cacheKey] = '通过';
                break;
              } catch (error) {
                token.check();
                if (attempt == 1) {
                  cache[cacheKey] =
                      error is AppError ? error.message : '协议检查失败';
                }
              }
            }
          }
          if (mounted) {
            setState(() {
              results[role] = cache[cacheKey]!;
            });
          }
        }
      });
  Future<void> selectModel(String role) async {
    final selected = await showModelPickerDialog(context,
        title: '选择${labels[role]}', models: available);
    if (selected != null && mounted) {
      setState(() {
        models[role]!.text = selected;
        results.remove(role);
      });
    }
  }

  Widget modelField(String role) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
            controller: models[role],
            enabled: !busy,
            autocorrect: false,
            onChanged: (_) => setState(() => results.remove(role)),
            decoration: InputDecoration(
                labelText:
                    '${labels[role]}（${role == 'text_main' ? '必填' : '可选'}）',
                hintText: '手动输入模型 ID',
                suffixIcon: available.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '搜索选择',
                        onPressed: busy ? null : () => selectModel(role),
                        icon: const Icon(Icons.search)))),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
            key: ValueKey('effort-$role'),
            value: efforts[role],
            isExpanded: true,
            decoration: const InputDecoration(labelText: '思考强度'),
            items: _effortLabels.entries
                .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                .toList(),
            onChanged: busy || models[role]!.text.trim().isEmpty
                ? null
                : (value) => setState(() {
                      efforts[role] = value!;
                      results.remove(role);
                    })),
        if (results[role] != null)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(results[role]!,
                  style: Theme.of(context).textTheme.bodySmall)),
        const SizedBox(height: 16),
      ]);

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('AI 接口与模型')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              const Text('仅 Responses API',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              const Text('先填文字主模型即可聊天；需要识图时再填图片主模型。兜底可留空。',
                  style: TextStyle(fontSize: 14)),
              const SizedBox(height: 24),
              TextField(
                  controller: url,
                  enabled: !busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                      labelText: 'Base URL',
                      hintText: 'https://example.com/v1',
                      helperText: '接口前缀，不含 /responses；不会自动添加 /v1')),
              const SizedBox(height: 16),
              TextField(
                  controller: key,
                  enabled: !busy,
                  obscureText: !visibleKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                      labelText: 'API Key',
                      hintText: savedKey ? '已安全保存；不更换时留空' : '输入你的 Key',
                      suffixIcon: IconButton(
                          tooltip: visibleKey ? '隐藏 Key' : '显示 Key',
                          onPressed:
                              busy ? null : () => perform(context, toggleKey),
                          icon: Icon(visibleKey
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined)))),
              const SizedBox(height: 8),
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('允许当前地址使用 HTTP'),
                  subtitle: const Text('HTTP 会明文传输 Key 和内容；仅在信任此连接时开启。'),
                  value: allowHttp,
                  onChanged: busy
                      ? null
                      : (v) => setState(() {
                            allowHttp = v;
                          })),
              OutlinedButton.icon(
                  onPressed: busy ? null : () => perform(context, fetchModels),
                  icon: const Icon(Icons.refresh),
                  label: const Text('读取模型列表')),
              const SectionTitle('主模型'),
              modelField('text_main'),
              modelField('vision_main'),
              ExpansionTile(
                  title: const Text('可选兜底模型'),
                  tilePadding: EdgeInsets.zero,
                  initiallyExpanded: models['text_backup']!.text.isNotEmpty ||
                      models['vision_backup']!.text.isNotEmpty,
                  children: [
                    modelField('text_backup'),
                    modelField('vision_backup')
                  ]),
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('思考强度默认跟随服务端；可用档位取决于模型和接口，较高强度通常更慢。',
                      style: TextStyle(fontSize: 14))),
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('请求思考摘要'),
                  subtitle: const Text(
                      '聊天请求添加 reasoning.summary=auto，仅支持该参数的接口开启。接口主动返回的 think 始终显示。'),
                  value: requestReasoningSummary,
                  onChanged: busy
                      ? null
                      : (value) => setState(() {
                            requestReasoningSummary = value;
                            results.clear();
                          })),
              if (busy) const LinearProgressIndicator(),
              FilledButton(
                  onPressed: busy ? null : () => perform(context, save),
                  child: const Text('保存配置')),
              const SizedBox(height: 12),
              OutlinedButton(
                  onPressed: busy ? null : () => perform(context, checkModels),
                  child: const Text('实际能力检查（可能计费）')),
              const SizedBox(height: 24),
              const Text('列表不代表识图或流式能力已通过检查。更换地址需要重新输入 Key；不支持的接口会明确报错，不会切换协议。',
                  style: TextStyle(fontSize: 14)),
            ]));
}

const _checkImage =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9WQAAAAASUVORK5CYII=';

const _effortLabels = {
  '': '默认（跟随服务端）',
  'none': '不思考（none）',
  'minimal': '极低（minimal）',
  'low': '低（low）',
  'medium': '中（medium）',
  'high': '高（high）',
  'xhigh': '更高（xhigh）',
  'max': '最高（max）',
};
