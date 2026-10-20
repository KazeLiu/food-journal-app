import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../chat/ai_gateway.dart';
import '../chat/message_images.dart';
import '../chat/vision_progress.dart';
import '../core/data.dart';
import '../core/widgets.dart';
import 'food_photo_recognizer.dart';

class LibraryPage extends StatefulWidget {
  final AppServices s;
  final bool memories;
  const LibraryPage(this.s, {this.memories = false, super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final search = TextEditingController();
  int limit = 50;
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(widget.memories ? 'AI 记忆' : '食品资料库')),
      floatingActionButton: FloatingActionButton(
          tooltip: widget.memories ? '添加偏好' : '添加食品资料',
          onPressed: () => _edit(),
          child: const Icon(Icons.add)),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!widget.memories)
          Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                  controller: search,
                  decoration: const InputDecoration(
                      labelText: '搜索名称、品牌或别名', prefixIcon: Icon(Icons.search)),
                  onChanged: (_) => setState(() {
                        limit = 50;
                      }))),
        Expanded(
            child: AnimatedBuilder(
                animation: widget.s.records,
                builder: (context, _) => DataView<List<Json>>(
                    future: widget.memories
                        ? widget.s.records.memories()
                        : widget.s.records
                            .library(keyword: search.text, limit: limit + 1),
                    builder: (rows) => rows.isEmpty
                        ? EmptyView(widget.memories ? '还没有保存长期偏好' : '还没有食品资料',
                            body: '只有你同意的内容才会长期保存。',
                            icon: widget.memories
                                ? Icons.psychology_outlined
                                : Icons.menu_book_outlined)
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                            itemCount: rows.length,
                            itemBuilder: (context, i) {
                              if (!widget.memories && i == limit) {
                                return TextButton(
                                    onPressed: () => setState(() {
                                          limit += 50;
                                        }),
                                    child: const Text('加载更多资料'));
                              }
                              final row = rows[i];
                              return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Card(
                                      child: ListTile(
                                          contentPadding:
                                              const EdgeInsets.all(16),
                                          title: Text(widget.memories
                                              ? row['content'] as String
                                              : row['name'] as String),
                                          subtitle: widget.memories
                                              ? null
                                              : Text(
                                                  '${row['kind'] == 'packaged_food' ? '包装食品' : '常用餐食'}${row['brand'] == null ? '' : ' · ${row['brand']}'}${row['variant'] == null ? '' : ' · ${row['variant']}'}'),
                                          trailing:
                                              const Icon(Icons.chevron_right),
                                          onTap: () => _edit(row))));
                            })))),
      ]));
  Future<void> _edit([Json? row]) async {
    if (widget.memories) {
      final text =
          TextEditingController(text: row?['content'] as String? ?? '');
      final saved = await showInputDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: Text(row == null ? '添加长期偏好' : '编辑长期偏好'),
                  content: TextField(
                      controller: text,
                      minLines: 2,
                      maxLines: 6,
                      decoration: const InputDecoration(labelText: '偏好或交流习惯')),
                  actions: [
                    if (row != null)
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('删除')),
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('保存'))
                  ]));
      final content = text.text.trim();
      text.dispose();
      if (saved == null || !mounted) return;
      await perform(context, () async {
        if (saved) {
          await widget.s.committer.local({
            'type': 'save_memory',
            'content': content,
            'category': row?['category'] ?? 'preference',
            if (row != null) 'id': row['id'],
            if (row != null) 'expected_version': row['version']
          });
        } else if (await confirm(context, '删除这项偏好？', '之后不会再将它发送给 AI。')) {
          await widget.s.committer.local({
            'type': 'delete_memory',
            'id': row!['id'],
            'expected_version': row['version']
          });
        }
      });
    } else {
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => LibraryEditor(widget.s, original: row)));
    }
  }
}

class LibraryEditor extends StatefulWidget {
  final AppServices s;
  final Json? original;
  final Json? recovered;
  const LibraryEditor(this.s, {this.original, this.recovered, super.key});
  @override
  State<LibraryEditor> createState() => _LibraryEditorState();
}

class _LibraryEditorState extends State<LibraryEditor> {
  late String kind = widget.original?['kind'] as String? ?? 'common_meal';
  late final name =
      TextEditingController(text: widget.original?['name'] as String? ?? '');
  late final brand =
      TextEditingController(text: widget.original?['brand'] as String? ?? '');
  late final variant =
      TextEditingController(text: widget.original?['variant'] as String? ?? '');
  late final dynamic originalSpec =
      widget.original?['package_spec_json'] == null
          ? null
          : jsonDecode(widget.original!['package_spec_json'] as String);
  String specDescription(dynamic spec) => spec is String
      ? spec
      : spec is Map
          ? spec['description'] as String? ??
              '${spec['amount'] ?? ''} ${spec['unit'] ?? ''}'.trim()
          : '';
  late final package =
      TextEditingController(text: specDescription(originalSpec));
  late final aliases = TextEditingController(
      text: widget.original == null
          ? ''
          : (jsonMap('{"items":${widget.original!['aliases_json']}}')['items']
                  as List)
              .join('、'));
  late final base = widget.original == null
      ? <String, dynamic>{'amount': 1, 'unit': '份'}
      : jsonMap(widget.original!['base_portion_json'] as String);
  late final amount = TextEditingController(text: '${base['amount']}');
  late final unit = TextEditingController(text: base['unit'] as String);
  late final description =
      TextEditingController(text: base['description'] as String? ?? '');
  late final nutrition = widget.original == null
      ? <String, dynamic>{}
      : jsonMap(widget.original!['nutrition_json'] as String);
  late final fields = nutritionFields
      .map((f) => TextEditingController(text: nutrition[f]?.toString() ?? ''))
      .toList();
  late final remarks = TextEditingController(
      text: widget.original == null
          ? ''
          : jsonMap(widget.original!['source_json'] as String)['remarks']
                  as String? ??
              '');
  List<Json> photos = [];
  bool capturing = false;
  bool restoring = false;
  bool busy = false;
  bool recognizing = false;
  bool get locked => busy || recognizing || capturing || restoring;
  RequestToken? photoToken;
  Json? photoDraft;
  late final String baseline;
  List<TextEditingController> get controllers => [
        name,
        brand,
        variant,
        package,
        aliases,
        amount,
        unit,
        description,
        remarks,
        ...fields
      ];
  Map<String, TextEditingController> get formFields => {
        'name': name,
        'brand': brand,
        'variant': variant,
        'package': package,
        'aliases': aliases,
        'amount': amount,
        'unit': unit,
        'description': description,
        'remarks': remarks,
        for (var i = 0; i < nutritionFields.length; i++)
          nutritionFields[i]: fields[i]
      };
  String formState() => jsonEncode([kind, ...controllers.map((c) => c.text)]);
  @override
  void initState() {
    super.initState();
    baseline = formState();
    final recovered = widget.recovered;
    if (recovered != null) {
      kind = recovered['kind'] as String? ?? kind;
      final values = recovered['values'] as Map;
      for (final entry in formFields.entries) {
        if (values[entry.key] is String) {
          entry.value.text = values[entry.key] as String;
        }
      }
      photoDraft = recovered['photo_draft'] as Json?;
      restoring = true;
      unawaited(_restorePhotos(recovered));
    }
  }

  Future<void> _restorePhotos(Json draft) async {
    final restored = <Json>[];
    for (final id in draft['photos'] as List) {
      final photo =
          await widget.s.records.row('chat_attachments', id as String);
      if (photo != null) restored.add(photo);
    }
    if (!mounted) return;
    setState(() {
      photos = restored;
      restoring = false;
    });
    showNotice(context, draft['notice'] as String? ?? '已恢复未保存的食品资料，请核对后继续。');
  }

  Future<void> _saveDraft() async {
    if (widget.original != null) return;
    await widget.s.settings.set('library_editor_draft', {
      'kind': kind,
      'values': {
        for (final entry in formFields.entries) entry.key: entry.value.text
      },
      'photos': photos.map((p) => p['id']).toList(),
      'photo_draft': photoDraft,
    });
  }

  Future<void> _clearDraft() async {
    if (widget.original != null) return;
    await widget.s.records.db.delete('app_settings',
        where: 'key=?', whereArgs: ['library_editor_draft']);
    for (final photo in photos) {
      await widget.s.images.discard(photo['id'] as String);
    }
  }

  @override
  void dispose() {
    photoToken?.cancel();
    for (final c in [
      name,
      brand,
      variant,
      package,
      aliases,
      amount,
      unit,
      description,
      remarks,
      ...fields
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<bool> canExit() async {
    if (locked) return false;
    final exit = formState() == baseline && photos.isEmpty ||
        await confirm(context, '放弃未保存的食品资料？', '退出后，本次修改不会保存。', accept: '放弃');
    if (exit) await _clearDraft();
    return exit;
  }

  Future<void> capturePhoto() async {
    if (locked) return;
    require(photos.length < 3, '最多拍摄3张同一食品的照片');
    FocusScope.of(context).unfocus();
    setState(() => capturing = true);
    try {
      await FoodPhotoRecognizer.create(widget.s.settings);
      await _saveDraft();
      final picked =
          await widget.s.images.pick(true, photos.length, restoreToChat: false);
      if (!mounted) return;
      setState(() => photos.addAll(picked));
      await _saveDraft();
    } on PlatformException catch (error) {
      if (error.code == 'camera_access_denied') {
        throw const AppError('无法使用相机，请在系统设置中允许相机访问，或继续手动填写。');
      }
      if (error.code == 'no_available_camera') {
        throw const AppError('当前设备没有可用相机，请继续手动填写。');
      }
      rethrow;
    } finally {
      if (mounted) setState(() => capturing = false);
    }
  }

  Future<void> removePhoto(Json photo) async {
    if (locked) return;
    setState(() => photos.remove(photo));
    await _saveDraft();
    await widget.s.images.discard(photo['id'] as String);
  }

  Future<void> recognizePhoto() async {
    if (locked) return;
    if (photos.isEmpty) await capturePhoto();
    if (photos.isEmpty || !mounted) return;
    if (formState() != baseline &&
        !await confirm(context, '用新照片重新填写？', '识别成功后会替换当前表单，请先确认没有需要保留的内容。',
            accept: '拍照识别')) return;
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    final token = RequestToken();
    late final FoodPhotoRecognizer recognizer;
    setState(() => busy = true);
    try {
      recognizer = await FoodPhotoRecognizer.create(widget.s.settings);
      await _saveDraft();
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (!mounted) return;
    final progress = ValueNotifier<Json>({});
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('正在识别食品资料'),
              content: ValueListenableBuilder<Json>(
                  valueListenable: progress,
                  builder: (context, state, _) => Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                                '正在综合 ${photos.length} 张照片${state['fallback'] == true ? ' · 使用兜底模型' : ''}${state['retry'] == true ? ' · 重试 1/1' : ''}'),
                            const SizedBox(height: 12),
                            ImageRequestProgress(
                                uploading: state['waiting_started_at'] == null,
                                sentBytes: state['sent'] as int? ?? 0,
                                totalBytes: state['total'] as int?,
                                waitingStartedAt:
                                    state['waiting_started_at'] as DateTime?),
                            if (state['reason'] != null)
                              Text('主模型：${state['reason']}',
                                  style: Theme.of(context).textTheme.bodySmall),
                          ])),
              actions: [
                TextButton(onPressed: token.cancel, child: const Text('停止识别'))
              ],
            )));
    setState(() {
      recognizing = true;
      photoToken = token;
    });
    unawaited(navigator.push(route));
    try {
      token.check();
      final draft = await recognizer.recognizeMany(
          photos
              .map((p) => widget.s.images.fileFor(p['relative_path'] as String))
              .toList(),
          token, onFallback: (reason) {
        if (mounted && !token.cancelled) {
          progress.value = {'fallback': true, 'reason': reason};
        }
      }, onRetry: () {
        if (mounted && !token.cancelled) {
          progress.value = {
            ...progress.value,
            'retry': true,
            'sent': 0,
            'total': null,
            'waiting_started_at': null
          };
        }
      }, onUploadProgress: (sent, total) {
        if (mounted && !token.cancelled) {
          progress.value = {
            ...progress.value,
            'sent': sent,
            'total': total,
            'waiting_started_at': sent < total
                ? null
                : progress.value['waiting_started_at'] ?? DateTime.now()
          };
        }
      });
      token.check();
      if (!mounted) return;
      setState(() {
        kind = draft['kind'] as String;
        name.text = draft['name'] as String;
        brand.text = draft['brand'] as String? ?? '';
        variant.text = draft['variant'] as String? ?? '';
        package.text = draft['package_spec'] as String? ?? '';
        aliases.text = (draft['aliases'] as List<String>).join('、');
        amount.text = draft['base_portion']['amount']?.toString() ?? '';
        unit.text = draft['base_portion']['unit'] as String? ?? '';
        description.text =
            draft['base_portion']['description'] as String? ?? '';
        remarks.text = draft['remarks'] as String? ?? '';
        for (var i = 0; i < nutritionFields.length; i++) {
          fields[i].text =
              draft['nutrition'][nutritionFields[i]]?.toString() ?? '';
        }
        photoDraft = draft;
      });
      await _saveDraft();
    } on AppError {
      if (!token.cancelled) rethrow;
    } finally {
      if (route.isActive) {
        navigator.removeRoute(route);
      }
      unawaited(route.completed.then((_) => progress.dispose()));
      photoToken = null;
      if (mounted) {
        setState(() {
          recognizing = false;
        });
      }
    }
    if (mounted && photoDraft != null && !token.cancelled) {
      showNotice(context, '识别结果已填入，请核对后点击“保存资料”才会保存。');
    }
  }

  Future<void> save() async {
    setState(() {
      busy = true;
    });
    try {
      final values = <String, dynamic>{};
      for (var i = 0; i < 4; i++) {
        final raw = fields[i].text.trim();
        final n = raw.isEmpty ? null : num.tryParse(raw);
        require(raw.isEmpty || n != null && n.isFinite && n >= 0,
            '${nutritionNames[i]}数值不正确');
        values[nutritionFields[i]] = n;
      }
      var source = <String, dynamic>{'type': 'user', 'note': '用户确认保存的食品资料'};
      if (photoDraft != null &&
          kind == photoDraft!['kind'] &&
          nutritionFields
              .every((f) => values[f] == photoDraft!['nutrition'][f]) &&
          num.tryParse(amount.text) == photoDraft!['base_portion']['amount'] &&
          unit.text.trim() == photoDraft!['base_portion']['unit']) {
        source = photoDraft!['source'] as Json;
      } else if (widget.original != null &&
          nutritionFields.every((f) => values[f] == nutrition[f]) &&
          num.tryParse(amount.text) == base['amount'] &&
          unit.text.trim() == base['unit']) {
        source = jsonMap(widget.original!['source_json'] as String);
      }
      source = {...source, 'remarks': remarks.text.trim()};
      await widget.s.committer.local({
        'type': 'save_library',
        'kind': kind,
        'name': name.text.trim(),
        'brand': brand.text.trim().isEmpty ? null : brand.text.trim(),
        'variant': variant.text.trim().isEmpty ? null : variant.text.trim(),
        'aliases': aliases.text
            .split('、')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        'base_portion': {
          'amount': num.tryParse(amount.text),
          'unit': unit.text.trim(),
          'description': description.text.trim()
        },
        'nutrition': values,
        'package_spec': package.text == specDescription(originalSpec)
            ? originalSpec
            : package.text.trim().isEmpty
                ? null
                : {'description': package.text.trim()},
        'source': source,
        if (widget.original != null) 'id': widget.original!['id'],
        if (widget.original != null)
          'expected_version': widget.original!['version']
      });
      await _clearDraft();
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  List<Widget> sourceDetails(BuildContext context, Json source) {
    final label = source['label'];
    return [
      Text(
          source['note'] as String? ??
              (source['type'] == 'ai' ? 'AI 估算，用户确认保存' : '用户确认的资料'),
          style: Theme.of(context).textTheme.bodySmall),
      if (source['type'] == 'label' && label is Map) ...[
        const SizedBox(height: 8),
        Text('原标签：${label['product_name'] ?? '包装食品'}',
            style: Theme.of(context).textTheme.bodySmall),
        Text(
            '每 ${label['base_amount'] ?? '未注明'} ${label['base_unit'] ?? ''} · 能量 ${label['energy_value'] ?? '未知'} ${label['energy_unit'] ?? '单位未注明'}',
            style: Theme.of(context).textTheme.bodySmall),
      ]
    ];
  }

  @override
  Widget build(BuildContext context) => ConfirmExit(
      onExit: canExit,
      child: Scaffold(
          appBar: AppBar(
              title: Text(widget.original == null ? '添加食品资料' : '食品资料详情'),
              actions: [
                if (widget.original == null)
                  TextButton.icon(
                      onPressed: locked
                          ? null
                          : photos.length >= 3
                              ? null
                              : () => perform(context, capturePhoto),
                      icon:
                          const Icon(Icons.document_scanner_outlined, size: 18),
                      label: const Text('AI 拍照识别')),
                if (widget.original != null)
                  IconButton(
                      tooltip: '删除资料',
                      onPressed: busy
                          ? null
                          : () => perform(context, () async {
                                if (!await confirm(
                                    context, '删除这份资料？', '历史饮食数值不会随之改变。')) {
                                  return;
                                }
                                await widget.s.committer.local({
                                  'type': 'delete_library',
                                  'id': widget.original!['id'],
                                  'expected_version':
                                      widget.original!['version']
                                });
                                if (context.mounted) Navigator.pop(context);
                              }),
                      icon: const Icon(Icons.delete_outline))
              ]),
          body: Column(children: [
            Expanded(
                child: AbsorbPointer(
                    absorbing: locked,
                    child:
                        ListView(padding: const EdgeInsets.all(16), children: [
                      if (photos.isNotEmpty) ...[
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          for (var i = 0; i < photos.length; i++)
                            Stack(children: [
                              InkWell(
                                  onTap: () => openImagePreview(
                                      context,
                                      widget.s.images.fileFor(photos[i]
                                          ['relative_path'] as String)),
                                  child: ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: Image.file(
                                          widget.s.images.fileFor(photos[i]
                                              ['relative_path'] as String),
                                          width: 80,
                                          height: 80,
                                          cacheWidth: 240,
                                          fit: BoxFit.cover,
                                          semanticLabel: '食品资料第${i + 1}张照片',
                                          errorBuilder: (_, __, ___) =>
                                              const SizedBox(
                                                  width: 80,
                                                  height: 80,
                                                  child: Icon(
                                                      Icons.broken_image_outlined))))),
                              Positioned(
                                  top: 0,
                                  right: 0,
                                  child: IconButton.filledTonal(
                                      tooltip: '移除第${i + 1}张照片',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () => perform(context,
                                          () => removePhoto(photos[i])),
                                      icon: const Icon(Icons.close, size: 16))),
                            ]),
                        ]),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, children: [
                          TextButton.icon(
                              onPressed: photos.length < 3
                                  ? () => perform(context, capturePhoto)
                                  : null,
                              icon: const Icon(Icons.add_a_photo_outlined,
                                  size: 18),
                              label: Text('继续拍照（${photos.length}/3）')),
                          FilledButton.tonal(
                              onPressed: () => perform(context, recognizePhoto),
                              child: const Text('开始识别')),
                        ]),
                        const SizedBox(height: 16),
                      ],
                      if (photoDraft != null)
                        const Padding(
                            padding: EdgeInsets.only(bottom: 16),
                            child: Text('识别结果已填入，请核对后点击“保存资料”。')),
                      DropdownButtonFormField<String>(
                          value: kind,
                          decoration: const InputDecoration(labelText: '资料类型'),
                          items: const [
                            DropdownMenuItem(
                                value: 'common_meal', child: Text('常用餐食')),
                            DropdownMenuItem(
                                value: 'packaged_food', child: Text('包装食品'))
                          ],
                          onChanged: (v) => setState(() {
                                kind = v!;
                              })),
                      const SizedBox(height: 16),
                      TextField(
                          controller: name,
                          decoration: const InputDecoration(labelText: '名称')),
                      const SizedBox(height: 16),
                      TextField(
                          controller: aliases,
                          decoration:
                              const InputDecoration(labelText: '别名（用顿号分隔）')),
                      if (kind == 'packaged_food') ...[
                        const SizedBox(height: 16),
                        TextField(
                            controller: brand,
                            decoration: const InputDecoration(labelText: '品牌')),
                        const SizedBox(height: 16),
                        TextField(
                            controller: variant,
                            decoration: const InputDecoration(labelText: '口味')),
                        const SizedBox(height: 16),
                        TextField(
                            controller: package,
                            decoration: const InputDecoration(
                                labelText: '包装规格', hintText: '如：每瓶 250 ml')),
                      ],
                      const SectionTitle('营养基准'),
                      TextField(
                          controller: amount,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: '基准数量', hintText: '如 100 或 1')),
                      const SizedBox(height: 16),
                      TextField(
                          controller: unit,
                          decoration: const InputDecoration(
                              labelText: '基准单位', hintText: 'g、ml、份、包装')),
                      const SizedBox(height: 16),
                      TextField(
                          controller: description,
                          decoration: const InputDecoration(
                              labelText: '份量 / 规格说明',
                              hintText: '如：普通外卖盒、整瓶 250 ml')),
                      for (var i = 0; i < 4; i++)
                        Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: TextField(
                                controller: fields[i],
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                                decoration: InputDecoration(
                                    labelText: '每基准${nutritionNames[i]}',
                                    suffixText: i == 0 ? 'kcal' : 'g'))),
                      const SizedBox(height: 16),
                      TextField(
                          controller: remarks,
                          minLines: 2,
                          maxLines: 6,
                          decoration: const InputDecoration(
                              labelText: '备注',
                              hintText: '配料表、过敏原或其他说明，可由AI填写后修改')),
                      if (widget.original != null || photoDraft != null) ...[
                        const SectionTitle('来源'),
                        ...sourceDetails(
                            context,
                            photoDraft?['source'] as Json? ??
                                jsonMap(
                                    widget.original!['source_json'] as String)),
                      ],
                      const SizedBox(height: 24),
                      const Text('只用于之后匹配的食物。修改资料不会重算历史记录。',
                          style: TextStyle(fontSize: 14)),
                      const SizedBox(height: 16),
                      FilledButton(
                          onPressed:
                              locked ? null : () => perform(context, save),
                          child: Text(busy ? '保存中…' : '保存资料')),
                      const SizedBox(height: 24),
                    ]))),
          ])));
}
