import 'package:flutter/material.dart';

import '../app.dart';
import '../core/data.dart';
import '../core/widgets.dart';
import 'editors.dart';

Json sumItems(List<Json> items) => {
      'item_count': items.length,
      for (final field in nutritionFields) ...{
        field: items.fold<num>(0, (sum, i) => sum + (i[field] as num? ?? 0)),
        'missing_$field': items.where((i) => i[field] == null).length
      }
    };

String calorieText(Json totals) => totals['item_count'] == 0
    ? '还没有饮食记录'
    : totals['missing_calories_kcal'] == totals['item_count']
        ? '热量待估算'
        : '已记录约 ${totals['calories_kcal']} kcal';

Future<void> openRecord(
        BuildContext context, AppServices s, String table, String id) =>
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => RecordDetail(s, table: table, id: id)));

class RecordCard extends StatelessWidget {
  final AppServices s;
  final String table;
  final String id;
  final String? actionId;
  const RecordCard(this.s,
      {required this.table, required this.id, this.actionId, super.key});
  Future<Json> load() async {
    final row = await s.records.row(table, id, includeDeleted: true);
    if (row == null) return {};
    return {
      ...row,
      if (table == 'meals') 'items': await s.records.foods(id),
      'can_undo': actionId != null && await s.records.canUndo(actionId!)
    };
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: s.records,
      builder: (context, _) => DataView<Json>(
          future: load(),
          builder: (row) {
            if (row.isEmpty || row['deleted_at_ms'] != null) {
              return Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        const Icon(Icons.remove_circle_outline),
                        const SizedBox(width: 8),
                        const Expanded(child: Text('这条记录已删除')),
                        TextButton(
                            onPressed: () => openRecord(context, s, table, id),
                            child: const Text('查看操作'))
                      ])));
            }
            final isMeal = table == 'meals';
            final isExercise = table == 'exercise_records';
            final items =
                isMeal ? (row['items'] as List).cast<Json>() : <Json>[];
            final totals = sumItems(items);
            return Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(
                                isMeal
                                    ? Icons.restaurant_outlined
                                    : isExercise
                                        ? Icons.directions_run_outlined
                                        : Icons.monitor_weight_outlined,
                                color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(
                                    isMeal
                                        ? '${mealNames[row['meal_type']]} · ${items.length} 种食物'
                                        : isExercise
                                            ? row['name'] as String
                                            : '体重记录',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600))),
                            const Icon(Icons.check_circle_outline,
                                size: 20,
                                semanticLabel: '已保存',
                                color: Color(0xFF4F9874))
                          ]),
                          const SizedBox(height: 12),
                          Text(
                              isMeal
                                  ? calorieText(totals)
                                  : isExercise
                                      ? exerciseEnergy(row)
                                      : '${numberText((row['grams'] as int) / (row['input_unit'] == 'jin' ? 500 : 1000), 2)} ${row['input_unit'] == 'jin' ? '斤' : 'kg'}',
                              style: Theme.of(context).textTheme.titleLarge),
                          if (isMeal) ...[
                            const SizedBox(height: 8),
                            Text(items.map((i) => i['name']).join('、'))
                          ],
                          if (isExercise) ...[
                            const SizedBox(height: 8),
                            Text(exerciseAmount(row).isEmpty
                                ? '时长可稍后补充'
                                : exerciseAmount(row)),
                          ],
                          const SizedBox(height: 8),
                          Text(recordDateTime(row),
                              style: Theme.of(context).textTheme.bodySmall),
                          if (isMeal && totals['missing_calories_kcal'] > 0)
                            Text('${totals['missing_calories_kcal']} 项热量待估算',
                                style: Theme.of(context).textTheme.bodySmall),
                          if (isMeal)
                            CompactDisclosure(
                                title: '展开明细',
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: items
                                        .map((i) => FoodNutrition(i))
                                        .toList())),
                          Wrap(spacing: 8, children: [
                            TextButton(
                                onPressed: () =>
                                    openRecord(context, s, table, id),
                                child: const Text('查看详情')),
                            TextButton(
                                onPressed: () {
                                  s.goChat({
                                    'local_date': row['local_date'],
                                    'record_table': table,
                                    'record_id': id,
                                    'label': '修改${row['local_date']}的记录'
                                  });
                                },
                                child: const Text('AI 修改')),
                            if (row['can_undo'] == true)
                              TextButton(
                                  onPressed: () => perform(context, () async {
                                        await s.committer.local({
                                          'type': 'undo_action',
                                          'action_id': actionId
                                        });
                                        if (context.mounted) {
                                          showNotice(context, '已撤销这项操作');
                                        }
                                      }),
                                  child: const Text('撤销'))
                          ]),
                        ])));
          }));
}

class FoodNutrition extends StatelessWidget {
  final Json food;
  final bool detailed;
  const FoodNutrition(this.food, {this.detailed = false, super.key});
  @override
  Widget build(BuildContext context) {
    final source = jsonMap(food['nutrition_sources_json'] as String);
    final basis = jsonMap(food['nutrition_basis_json'] as String);
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(food['name'] as String,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (food['portion_text'] != null)
            Text(food['portion_text'] as String,
                style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(
              spacing: 16,
              runSpacing: 8,
              children: List.generate(4, (i) {
                final field = nutritionFields[i];
                return Text(
                    '${nutritionNames[i]} ${food[field] == null ? '未知' : '${numberText(food[field] as num)} ${i == 0 ? 'kcal' : 'g'}'}${detailed ? ' · ${sources[source[field]]}' : ''}',
                    style: Theme.of(context).textTheme.bodySmall);
              })),
          if (detailed)
            CompactDisclosure(
                title: '估算与来源依据',
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (food['estimation_note'] != null)
                        Align(
                            alignment: Alignment.centerLeft,
                            child: Text(food['estimation_note'] as String)),
                      for (var i = 0; i < 4; i++)
                        if (basis[nutritionFields[i]] != null)
                          Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                      '${nutritionNames[i]}：${_basisText(basis[nutritionFields[i]])}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall))),
                    ])),
          if (detailed && food['note'] != null) Text('备注：${food['note']}'),
        ]));
  }

  String _basisText(dynamic value) {
    if (value is String) return value;
    final basis = value as Json;
    final text = basis['note'] as String? ??
        (basis['base_amount'] == null
            ? '没有更多依据'
            : '每 ${basis['base_amount']} ${basis['base_unit']} 含 ${basis['value_per_base']}，本次 ${basis['consumed_amount']} ${basis['consumed_unit'] ?? basis['base_unit']}');
    return basis['lower_kcal'] == null
        ? text
        : '$text；参考区间 ${basis['lower_kcal']}–${basis['upper_kcal']} kcal';
  }
}

class RecordDetail extends StatelessWidget {
  final AppServices s;
  final String table;
  final String id;
  const RecordDetail(this.s,
      {required this.table, required this.id, super.key});
  Future<Json> load() async {
    var row = await s.records.row(table, id, includeDeleted: true);
    var effectiveTable = table;
    if (table == 'food_items' && row != null) {
      row = await s.records
          .row('meals', row['meal_id'] as String, includeDeleted: true);
      effectiveTable = 'meals';
    }
    if (row == null) return {};
    return {
      'table': effectiveTable,
      'row': row,
      'items': effectiveTable == 'meals'
          ? await s.records.foods(row['id'] as String)
          : <Json>[],
      'history': await s.records.recordHistory(row['id'] as String)
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('记录详情')),
      body: AnimatedBuilder(
          animation: s.records,
          builder: (context, _) => DataView<Json>(
              future: load(),
              builder: (data) {
                if (data.isEmpty) return const EmptyView('记录不存在');
                final row = data['row'] as Json;
                final table = data['table'] as String;
                final meal = table == 'meals';
                final exercise = table == 'exercise_records';
                final deleted = row['deleted_at_ms'] != null;
                return ListView(padding: const EdgeInsets.all(16), children: [
                  Text(recordDateTime(row),
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Text(
                      deleted
                          ? '这条记录已删除'
                          : meal
                              ? mealNames[row['meal_type']]!
                              : exercise
                                  ? row['name'] as String
                                  : '${numberText((row['grams'] as int) / 1000, 2)} kg',
                      style: Theme.of(context).textTheme.headlineSmall),
                  if (!deleted && meal) ...[
                    const SizedBox(height: 16),
                    NutritionSummary(
                        sumItems((data['items'] as List).cast<Json>())),
                    ...(data['items'] as List)
                        .cast<Json>()
                        .map((i) => FoodNutrition(i, detailed: true)),
                  ],
                  if (!deleted && exercise) ...[
                    const SizedBox(height: 16),
                    Text(exerciseEnergy(row),
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(exerciseAmount(row).isEmpty
                        ? '时长、距离与强度未补充'
                        : exerciseAmount(row)),
                    Text('消耗来源：${sources[row['calories_source']]}',
                        style: Theme.of(context).textTheme.bodySmall),
                    if (jsonMap(row['calories_basis_json'] as String)
                        .isNotEmpty)
                      CompactDisclosure(
                          title: '消耗估算依据', child: ExerciseBasis(row)),
                    if (row['note'] != null) Text('备注：${row['note']}'),
                  ],
                  if (!deleted) ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                        onPressed: () {
                          s.goChat({
                            'local_date': row['local_date'],
                            'record_id': row['id'],
                            'record_table': table,
                            'label': '修改${row['local_date']}的记录'
                          });
                          Navigator.popUntil(context, (route) => route.isFirst);
                        },
                        icon: const Icon(Icons.auto_awesome_outlined),
                        label: const Text('通过 AI 修改')),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                          child: OutlinedButton(
                              onPressed: () => perform(context, () async {
                                    if (!await confirm(
                                        context, '删除这条记录？', '删除后可在操作历史中撤销。')) {
                                      return;
                                    }
                                    await s.committer.local({
                                      'type': meal
                                          ? 'delete_meal'
                                          : exercise
                                              ? 'delete_exercise'
                                              : 'delete_weight',
                                      'id': row['id'],
                                      'expected_version': row['version']
                                    });
                                  }),
                              child: const Text('删除'))),
                      const SizedBox(width: 8),
                      PopupMenuButton<String>(
                          tooltip: '更多操作',
                          onSelected: (_) {
                            if (meal) {
                              openMealEditor(context, s,
                                  meal: {...row, 'items': data['items']});
                            } else if (exercise) {
                              openExerciseEditor(context, s, exercise: row);
                            } else {
                              openWeightEditor(context, s, weight: row);
                            }
                          },
                          itemBuilder: (_) => [
                                const PopupMenuItem(
                                    value: 'edit', child: Text('直接编辑'))
                              ])
                    ]),
                  ],
                  const SectionTitle('最近操作'),
                  ...(data['history'] as List).cast<Json>().map((a) => Card(
                      child: ListTile(
                          title: Text(_actionTitle(a['type'] as String)),
                          subtitle: Text(
                              '${DateTime.fromMillisecondsSinceEpoch(a['created_at_ms'] as int).toLocal()}'
                                  .split('.')
                                  .first),
                          trailing: a['status'] == 'undone'
                              ? const Text('已撤销')
                              : a['undo_of_action_id'] != null
                                  ? const Text('已执行')
                                  : TextButton(
                                      onPressed: () =>
                                          perform(context, () async {
                                            await s.committer.local({
                                              'type': 'undo_action',
                                              'action_id': a['id']
                                            });
                                          }),
                                      child: const Text('撤销'))))),
                ]);
              })));
}

String _actionTitle(String type) => switch (type) {
      'create_meal' => '新增饮食',
      'create_weight' => '新增体重',
      'create_exercise' => '新增运动',
      'update_exercise' => '补充 / 修改运动',
      'delete_exercise' => '删除运动',
      'delete_meal' || 'delete_food' => '删除饮食',
      'delete_weight' => '删除体重',
      'undo_action' => '撤销操作',
      'backfill' => '补充营养',
      _ => '修改记录'
    };

class ExerciseBasis extends StatelessWidget {
  final Json row;
  const ExerciseBasis(this.row, {super.key});
  @override
  Widget build(BuildContext context) {
    final basis = jsonMap(row['calories_basis_json'] as String);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (basis['note'] != null) Text(basis['note'] as String),
      if (row['calories_source'] == 'ai') ...[
        const SizedBox(height: 8),
        Text(
            '参考体重 ${numberText((basis['weight_grams'] as int) / 1000, 2)} kg（${basis['weight_local_date']}） · MET ${basis['met']}'),
        Text('${basis['duration_minutes']} 分钟 · ${basis['intensity']}'),
        Text(basis['method'] as String,
            style: Theme.of(context).textTheme.bodySmall),
      ]
    ]);
  }
}
