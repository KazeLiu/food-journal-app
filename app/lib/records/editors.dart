import 'package:flutter/material.dart';

import '../app.dart';
import '../core/data.dart';
import '../core/widgets.dart';

Future<void> openMealEditor(BuildContext context, AppServices s,
    {String? date,
    Json? meal,
    String? originalText,
    String? actionId,
    String? operationId}) async {
  await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => MealEditor(s,
              date: date ?? today(),
              meal: meal,
              originalText: originalText,
              actionId: actionId,
              operationId: operationId)));
}

Future<void> openWeightEditor(BuildContext context, AppServices s,
    {String? date, Json? weight, String? actionId, String? operationId}) async {
  final unit = await s.settings.get('weight_unit', 'jin') as String;
  if (!context.mounted) return;
  await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => WeightEditor(s,
              date: date ?? today(),
              weight: weight,
              defaultUnit: unit,
              actionId: actionId,
              operationId: operationId)));
}

Future<void> openExerciseEditor(BuildContext context, AppServices s,
        {String? date,
        Json? exercise,
        String? originalText,
        String? actionId,
        String? operationId}) =>
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ExerciseEditor(s,
                date: date ?? today(),
                exercise: exercise,
                originalText: originalText,
                actionId: actionId,
                operationId: operationId)));

Future<void> _finishManual(
    AppServices s, Json receipt, String? operationId) async {
  final action =
      await s.records.row('operation_actions', receipt['action_id'] as String);
  final id = operationId ?? action!['operation_id'] as String;
  final operation = await s.records.row('operations', id);
  if (operation?['kind'] != 'chat') return;
  final messages = await s.records.db.query('chat_messages',
      where: "operation_id=? AND role='assistant'", whereArgs: [id]);
  final message = messages.isEmpty ? null : messages.single;
  await s.records.assistant(
      id,
      '这项已手动处理。${message?['receipt_text'] ?? '记录已保存。'}',
      operation!['status'] as String,
      refs: message == null
          ? (receipt['refs'] as List).cast<Json>()
          : jsonRows(message['record_refs_json'] as String));
}

class DateTimeFields extends StatelessWidget {
  final String date;
  final String? time;
  final void Function(String, String?) onChanged;
  const DateTimeFields(
      {required this.date,
      required this.time,
      required this.onChanged,
      super.key});
  @override
  Widget build(BuildContext context) => Column(children: [
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.calendar_today_outlined),
            title: const Text('日期'),
            trailing: Text(date),
            onTap: () async {
              final picked = await showDatePicker(
                  context: context,
                  initialDate: DateTime.parse(date),
                  firstDate: DateTime(1),
                  lastDate: DateTime(9999, 12, 31));
              if (picked != null) onChanged(dateKey(picked), time);
            }),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule),
            title: const Text('发生时间'),
            subtitle: Text(time ?? '仅记录日期'),
            trailing: time == null
                ? null
                : IconButton(
                    tooltip: '清除时间',
                    onPressed: () => onChanged(date, null),
                    icon: const Icon(Icons.close)),
            onTap: () async {
              final picked = await showTimePicker(
                  context: context,
                  initialTime: !isClockTime(time)
                      ? TimeOfDay.now()
                      : TimeOfDay(
                          hour: int.parse(time!.split(':')[0]),
                          minute: int.parse(time!.split(':')[1])));
              if (picked != null) {
                onChanged(date,
                    '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}');
              }
            }),
      ]);
}

class _FoodFields {
  final Json? original;
  late final TextEditingController name =
      TextEditingController(text: original?['name'] as String? ?? '');
  late final TextEditingController portion =
      TextEditingController(text: original?['portion_text'] as String? ?? '');
  late final TextEditingController note =
      TextEditingController(text: original?['note'] as String? ?? '');
  late final List<TextEditingController> nutrients = nutritionFields
      .map((f) => TextEditingController(text: original?[f]?.toString() ?? ''))
      .toList();
  bool cleared = false;
  _FoodFields([this.original]);
  void changedIdentity() {
    if (original == null || cleared) return;
    if (name.text != original!['name'] ||
        portion.text != (original!['portion_text'] ?? '')) {
      cleared = true;
      for (final field in nutrients) {
        field.clear();
      }
    }
  }

  Json payload() {
    final nutrition = <String, dynamic>{};
    final source = original == null
        ? <String, dynamic>{}
        : jsonMap(original!['nutrition_sources_json'] as String);
    final basis = original == null
        ? <String, dynamic>{}
        : jsonMap(original!['nutrition_basis_json'] as String);
    for (var i = 0; i < nutritionFields.length; i++) {
      final raw = nutrients[i].text.trim();
      final value = raw.isEmpty ? null : num.tryParse(raw);
      require(raw.isEmpty || value != null && value.isFinite && value >= 0,
          '${nutritionNames[i]}请输入非负数，未知留空');
      require(i != 0 || value == null || value == value.roundToDouble(),
          '热量请输入整数 kcal');
      final field = nutritionFields[i];
      final unchanged =
          original != null && !cleared && original![field] == value;
      basis[field] = value == null
          ? null
          : unchanged
              ? basis[field]
              : {'note': '用户本次填写'};
      nutrition[field] = {
        'value': i == 0 ? value?.toInt() : value,
        'source': value == null
            ? 'unknown'
            : unchanged
                ? source[field]
                : 'user'
      };
    }
    require(name.text.trim().isNotEmpty, '食物名称不能为空');
    return {
      'client_ref': newId(),
      if (original != null) 'id': original!['id'],
      if (original != null) 'expected_version': original!['version'],
      'name': name.text.trim(),
      'portion_text': portion.text.trim().isEmpty ? null : portion.text.trim(),
      'nutrition': nutrition,
      'nutrition_basis': basis,
      'note': note.text.trim().isEmpty ? null : note.text.trim(),
      'estimation_note': cleared ? null : original?['estimation_note']
    };
  }

  void dispose() {
    name.dispose();
    portion.dispose();
    note.dispose();
    for (final c in nutrients) {
      c.dispose();
    }
  }
}

class MealEditor extends StatefulWidget {
  final AppServices s;
  final String date;
  final Json? meal;
  final String? originalText;
  final String? actionId;
  final String? operationId;
  const MealEditor(this.s,
      {required this.date,
      this.meal,
      this.originalText,
      this.actionId,
      this.operationId,
      super.key});
  @override
  State<MealEditor> createState() => _MealEditorState();
}

class _MealEditorState extends State<MealEditor> {
  late String date = widget.meal?['local_date'] as String? ?? widget.date;
  late String? time = widget.meal == null
      ? clockTime(DateTime.now())
      : widget.meal!['local_time'] as String?;
  late String type = widget.meal?['meal_type'] as String? ?? 'other';
  late final List<_FoodFields> items = widget.meal == null
      ? [_FoodFields()]
      : (widget.meal!['items'] as List)
          .cast<Json>()
          .map(_FoodFields.new)
          .toList();
  bool busy = false;
  bool dirty = false;
  @override
  void dispose() {
    for (final item in items) {
      item.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      busy = true;
    });
    try {
      final payload = <String, dynamic>{
        'type': widget.meal == null ? 'create_meal' : 'edit_meal',
        if (widget.meal != null) 'id': widget.meal!['id'],
        if (widget.meal != null) 'expected_version': widget.meal!['version'],
        'client_ref': newId(),
        'local_date': date,
        'local_time': time,
        'meal_type': type,
        'raw_description':
            widget.originalText ?? items.map((i) => i.name.text).join('、'),
        'items': items.map((i) => i.payload()).toList()
      };
      final receipt = await widget.s.chat.manualSave<Json>(
          actionId: widget.actionId,
          operationId: widget.operationId,
          save: () => widget.s.committer.local(payload,
              actionId: widget.actionId,
              sourceOperationId: widget.operationId));
      await _finishManual(widget.s, receipt, widget.operationId);
      if (mounted) {
        dirty = false;
        Navigator.pop(context);
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ConfirmExit(
      onExit: () async =>
          !busy &&
          (!dirty ||
              await confirm(context, '放弃未保存的内容？', '退出后，本次表单内容不会保存。',
                  accept: '放弃')),
      child: Scaffold(
          appBar: AppBar(title: Text(widget.meal == null ? '手动记录饮食' : '编辑这餐')),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            if (widget.originalText != null)
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('原消息：${widget.originalText}'))),
            DateTimeFields(
                date: date,
                time: time,
                onChanged: (d, t) => setState(() {
                      date = d;
                      time = t;
                      dirty = true;
                    })),
            DropdownButtonFormField<String>(
                value: type,
                decoration: const InputDecoration(labelText: '餐别'),
                items: mealNames.entries
                    .map((e) =>
                        DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => setState(() {
                      type = v!;
                      dirty = true;
                    })),
            ...items.asMap().entries.map((entry) {
              final i = entry.value;
              return Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Card(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(children: [
                            Row(children: [
                              Expanded(
                                  child: Text('食物 ${entry.key + 1}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium)),
                              if (items.length > 1)
                                IconButton(
                                    tooltip: '移除这项食物',
                                    onPressed: () => setState(() {
                                          items.remove(i);
                                          i.dispose();
                                          dirty = true;
                                        }),
                                    icon: const Icon(Icons.close))
                            ]),
                            TextField(
                                controller: i.name,
                                decoration:
                                    const InputDecoration(labelText: '名称（必填）'),
                                onChanged: (_) => setState(() {
                                      i.changedIdentity();
                                      dirty = true;
                                    })),
                            const SizedBox(height: 12),
                            TextField(
                                controller: i.portion,
                                decoration: const InputDecoration(
                                    labelText: '份量', hintText: '如：一碗、半盒'),
                                onChanged: (_) => setState(() {
                                      i.changedIdentity();
                                      dirty = true;
                                    })),
                            const SizedBox(height: 12),
                            TextField(
                                controller: i.nutrients[0],
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: false),
                                decoration: const InputDecoration(
                                    labelText: '热量（未知留空）', suffixText: 'kcal'),
                                onChanged: (_) {
                                  dirty = true;
                                }),
                            if (i.cleared)
                              const Padding(
                                  padding: EdgeInsets.only(top: 8),
                                  child:
                                      Text('食物或份量已改变，原营养已清空。可填写新值，或留空等待估算。')),
                            ExpansionTile(
                                tilePadding: EdgeInsets.zero,
                                title: const Text('更多营养与备注'),
                                children: [
                                  for (var j = 1; j < 4; j++)
                                    Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 12),
                                        child: TextField(
                                            controller: i.nutrients[j],
                                            keyboardType: const TextInputType
                                                .numberWithOptions(
                                                decimal: true),
                                            decoration: InputDecoration(
                                                labelText: nutritionNames[j],
                                                suffixText: 'g'),
                                            onChanged: (_) {
                                              dirty = true;
                                            })),
                                  TextField(
                                      controller: i.note,
                                      decoration: const InputDecoration(
                                          labelText: '备注'),
                                      onChanged: (_) {
                                        dirty = true;
                                      }),
                                ]),
                          ]))));
            }),
            const SizedBox(height: 16),
            OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => setState(() {
                          items.add(_FoodFields());
                          dirty = true;
                        }),
                icon: const Icon(Icons.add),
                label: const Text('再加一种食物')),
            const SizedBox(height: 24),
            FilledButton(
                onPressed: busy ? null : () => perform(context, save),
                child: Text(busy ? '保存中…' : '保存这餐')),
            const SizedBox(height: 24),
          ])));
}

class WeightEditor extends StatefulWidget {
  final AppServices s;
  final String date;
  final Json? weight;
  final String defaultUnit;
  final String? actionId;
  final String? operationId;
  const WeightEditor(this.s,
      {required this.date,
      this.weight,
      required this.defaultUnit,
      this.actionId,
      this.operationId,
      super.key});
  @override
  State<WeightEditor> createState() => _WeightEditorState();
}

class ExerciseEditor extends StatefulWidget {
  final AppServices s;
  final String date;
  final Json? exercise;
  final String? originalText;
  final String? actionId;
  final String? operationId;
  const ExerciseEditor(this.s,
      {required this.date,
      this.exercise,
      this.originalText,
      this.actionId,
      this.operationId,
      super.key});
  @override
  State<ExerciseEditor> createState() => _ExerciseEditorState();
}

class _ExerciseEditorState extends State<ExerciseEditor> {
  late String date = widget.exercise?['local_date'] as String? ?? widget.date;
  late String? time = widget.exercise == null
      ? clockTime(DateTime.now())
      : widget.exercise!['local_time'] as String?;
  late final name =
      TextEditingController(text: widget.exercise?['name'] as String? ?? '');
  late final duration = TextEditingController(
      text: widget.exercise?['duration_minutes'] == null
          ? ''
          : widget.exercise!['duration_minutes'].toString());
  late final distance = TextEditingController(
      text: widget.exercise?['distance_meters'] == null
          ? ''
          : widget.exercise!['distance_meters'].toString());
  late final intensity = TextEditingController(
      text: widget.exercise?['intensity'] as String? ?? '');
  late final calories = TextEditingController(
      text: widget.exercise?['calories_kcal']?.toString() ?? '');
  late final note =
      TextEditingController(text: widget.exercise?['note'] as String? ?? '');
  bool dirty = false;
  bool busy = false;
  bool clearedEstimate = false;

  @override
  void dispose() {
    for (final c in [name, duration, distance, intensity, calories, note]) {
      c.dispose();
    }
    super.dispose();
  }

  void changedParameters() {
    dirty = true;
    if (widget.exercise?['calories_source'] == 'ai' && !clearedEstimate) {
      calories.clear();
      setState(() => clearedEstimate = true);
    }
  }

  num? numeric(TextEditingController field, String label,
      {bool positive = false, bool integer = false}) {
    final raw = field.text.trim();
    if (raw.isEmpty) return null;
    final value = num.tryParse(raw);
    require(
        value != null && value.isFinite && (positive ? value > 0 : value >= 0),
        '$label请输入${positive ? '正数' : '非负数'}，未知留空');
    require(!integer || value == value!.roundToDouble(), '$label请输入整数');
    return integer ? value!.toInt() : value;
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      final energy = numeric(calories, '消耗', integer: true);
      final old = widget.exercise;
      final preserve =
          old != null && !clearedEstimate && old['calories_kcal'] == energy;
      final patch = <String, dynamic>{
        'local_date': date,
        'local_time': time,
        'name': name.text.trim(),
        'duration_minutes': numeric(duration, '时长', positive: true),
        'distance_meters': numeric(distance, '距离'),
        'intensity':
            intensity.text.trim().isEmpty ? null : intensity.text.trim(),
        'calories_kcal': energy,
        'calories_source': energy == null
            ? 'unknown'
            : preserve
                ? old['calories_source']
                : 'user',
        'calories_basis': energy == null
            ? null
            : preserve
                ? jsonMap(old['calories_basis_json'] as String)
                : {'note': '用户本次填写'},
        'note': note.text.trim().isEmpty ? null : note.text.trim()
      };
      validateExercise(patch);
      final payload = old == null
          ? <String, dynamic>{
              'type': 'create_exercise',
              ...patch,
              'client_ref': newId(),
              'raw_description': widget.originalText ?? name.text.trim()
            }
          : <String, dynamic>{
              'type': 'update_exercise',
              'id': old['id'],
              'expected_version': old['version'],
              'patch': patch
            };
      final receipt = await widget.s.chat.manualSave<Json>(
          actionId: widget.actionId,
          operationId: widget.operationId,
          save: () => widget.s.committer.local(payload,
              actionId: widget.actionId,
              sourceOperationId: widget.operationId));
      await _finishManual(widget.s, receipt, widget.operationId);
      if (mounted) {
        dirty = false;
        Navigator.pop(context);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ConfirmExit(
      onExit: () async =>
          !busy &&
          (!dirty ||
              await confirm(context, '放弃未保存的运动？', '本次内容不会保存。', accept: '放弃')),
      child: Scaffold(
          appBar:
              AppBar(title: Text(widget.exercise == null ? '记录运动' : '编辑运动')),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            if (widget.originalText != null)
              Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text('原消息：${widget.originalText}')),
            TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: '运动名称（必填）', hintText: '如：游泳、散步'),
                onChanged: (_) => changedParameters()),
            const SizedBox(height: 16),
            TextField(
                controller: duration,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: '时长（未知留空）', suffixText: '分钟'),
                onChanged: (_) => changedParameters()),
            const SizedBox(height: 16),
            TextField(
                controller: calories,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: '消耗（未知留空）', suffixText: 'kcal'),
                onChanged: (_) => dirty = true),
            if (clearedEstimate)
              const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('运动参数已改变，原估算已清空。可填写设备读数，或稍后通过 AI 补充。')),
            const SizedBox(height: 16),
            TextField(
                controller: distance,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: '距离（可选）', suffixText: '米'),
                onChanged: (_) => dirty = true),
            const SizedBox(height: 16),
            TextField(
                controller: intensity,
                decoration: const InputDecoration(
                    labelText: '强度（可选）', hintText: '如：轻松、中等、快速'),
                onChanged: (_) => changedParameters()),
            const SizedBox(height: 16),
            TextField(
                controller: note,
                decoration: const InputDecoration(labelText: '备注（可选）'),
                onChanged: (_) => dirty = true),
            DateTimeFields(
                date: date,
                time: time,
                onChanged: (d, t) => setState(() {
                      if (d != date) changedParameters();
                      date = d;
                      time = t;
                      dirty = true;
                    })),
            const SizedBox(height: 24),
            FilledButton(
                onPressed: busy ? null : () => perform(context, save),
                child: Text(busy ? '保存中…' : '保存运动')),
            const SizedBox(height: 24),
          ])));
}

class _WeightEditorState extends State<WeightEditor> {
  Json? convertedInput;
  late final TextEditingController value = TextEditingController(
      text: widget.weight?['input_value'] as String? ?? '');
  late String unit =
      widget.weight?['input_unit'] as String? ?? widget.defaultUnit;
  late String date = widget.weight?['local_date'] as String? ?? widget.date;
  late String? time = widget.weight == null
      ? clockTime(DateTime.now())
      : widget.weight!['local_time'] as String?;
  bool busy = false;
  bool dirty = false;
  @override
  void dispose() {
    value.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      busy = true;
    });
    try {
      final patch = {
        'local_date': date,
        'local_time': time,
        'input_value': convertedInput?['input_value'] ?? value.text.trim(),
        'input_unit': convertedInput?['input_unit'] ?? unit
      };
      weightGrams(
          patch['input_value'] as String, patch['input_unit'] as String);
      final Json payload = widget.weight == null
          ? {
              'type': 'create_weight',
              ...patch,
              'client_ref': newId(),
              'raw_description': '${value.text} $unit'
            }
          : {
              'type': 'update_weight',
              'id': widget.weight!['id'],
              'expected_version': widget.weight!['version'],
              'patch': patch
            };
      final receipt = await widget.s.chat.manualSave<Json>(
          actionId: widget.actionId,
          operationId: widget.operationId,
          save: () => widget.s.committer.local(payload,
              actionId: widget.actionId,
              sourceOperationId: widget.operationId));
      await _finishManual(widget.s, receipt, widget.operationId);
      if (mounted) {
        dirty = false;
        Navigator.pop(context);
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ConfirmExit(
      onExit: () async =>
          !busy &&
          (!dirty ||
              await confirm(context, '放弃未保存的体重？', '本次内容不会保存。', accept: '放弃')),
      child: Scaffold(
          appBar: AppBar(title: Text(widget.weight == null ? '记录体重' : '编辑体重')),
          body: ListView(padding: const EdgeInsets.all(24), children: [
            const Text('记下这一次，不用和昨天比较。'),
            const SizedBox(height: 24),
            TextField(
                controller: value,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style:
                    const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                    labelText: '体重', suffixText: unit == 'jin' ? '斤' : 'kg'),
                onChanged: (_) {
                  convertedInput = null;
                  dirty = true;
                }),
            const SizedBox(height: 16),
            SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'jin', label: Text('斤')),
                  ButtonSegment(value: 'kg', label: Text('公斤'))
                ],
                selected: {
                  unit
                },
                onSelectionChanged: (v) => perform(context, () async {
                      final grams = value.text.trim().isEmpty
                          ? null
                          : convertedInput == null
                              ? weightGrams(value.text.trim(), unit)
                              : weightGrams(
                                  convertedInput!['input_value'] as String,
                                  convertedInput!['input_unit'] as String);
                      setState(() {
                        if (grams != null) {
                          convertedInput ??= {
                            'input_value': value.text.trim(),
                            'input_unit': unit
                          };
                        }
                        unit = v.single;
                        if (grams != null) {
                          value.text = numberText(
                              grams / (unit == 'jin' ? 500 : 1000), 3);
                        }
                        dirty = true;
                      });
                    })),
            const SizedBox(height: 16),
            DateTimeFields(
                date: date,
                time: time,
                onChanged: (d, t) => setState(() {
                      date = d;
                      time = t;
                      dirty = true;
                    })),
            const SizedBox(height: 24),
            FilledButton(
                onPressed: busy ? null : () => perform(context, save),
                child: Text(busy ? '保存中…' : '保存这次体重')),
          ])));
}
