import 'package:flutter/material.dart';

import '../app.dart';
import '../core/data.dart';
import '../core/widgets.dart';

class ActionPreview extends StatelessWidget {
  final AppServices s;
  final Json action;
  const ActionPreview(this.s, this.action, {super.key});
  Future<Json> current() async {
    final type = action['type'] as String;
    final id = action['id'] ?? action['meal_id'] ?? action['action_id'];
    if (id is! String) return {};
    final table = type == 'undo_action'
        ? 'operation_actions'
        : type.contains('weight')
            ? 'weight_records'
            : type.contains('exercise')
                ? 'exercise_records'
                : type.endsWith('food')
                    ? 'food_items'
                    : 'meals';
    return await s.records.row(table, id) ?? {};
  }

  @override
  Widget build(BuildContext context) => DataView<Json>(
      future: current(),
      builder: (old) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (old.isNotEmpty)
              Text(
                  '当前：${old['name'] ?? old['raw_description'] ?? '指定操作'}${old['portion_text'] == null ? '' : ' · ${old['portion_text']}'}${old['local_date'] == null ? '' : ' · ${old['local_date']}'}',
                  style: Theme.of(context).textTheme.bodySmall),
            if ((action['type'] as String).startsWith('delete_'))
              const Text('准备删除这条记录，删除后可以撤销。')
            else if (action['type'] == 'undo_action')
              const Text('准备撤销这项操作；后续已修改的记录不会被覆盖。')
            else
              ..._describe(action).map((line) => Padding(
                  padding: const EdgeInsets.only(top: 4), child: Text(line))),
          ])));
  List<String> _describe(Json a) {
    final patch =
        a['patch'] is Map ? Map<String, dynamic>.from(a['patch'] as Map) : a;
    final lines = <String>[];
    const labels = {
      'name': '食物',
      'portion_text': '份量',
      'local_date': '日期',
      'local_time': '时刻',
      'input_value': '体重',
      'input_unit': '单位',
      'meal_type': '餐别',
      'duration_minutes': '时长（分钟）',
      'distance_meters': '距离（米）',
      'intensity': '强度',
      'calories_kcal': '运动消耗（kcal）',
      'calories_source': '消耗来源'
    };
    for (final entry in labels.entries) {
      if (!patch.containsKey(entry.key)) continue;
      final value = patch[entry.key];
      final shown = entry.key == 'meal_type'
          ? mealNames[value]
          : entry.key == 'input_unit'
              ? (value == 'jin' ? '斤' : '公斤')
              : value;
      lines.add(
          '${entry.key == 'name' && (a['type'] as String).contains('exercise') ? '运动' : entry.value} → ${shown ?? '未注明'}');
    }
    if (patch['nutrition'] is Map) {
      final nutrition = patch['nutrition'] as Map;
      for (var i = 0; i < 4; i++) {
        final value = nutrition[nutritionFields[i]];
        if (value is Map) {
          lines.add(
              '${nutritionNames[i]} → ${value['value'] ?? '未知'}${value['value'] == null ? '' : i == 0 ? ' kcal' : ' g'}');
        }
      }
    }
    if (a['items'] is List) {
      for (final item in (a['items'] as List).whereType<Map>()) {
        lines.add('添加：${item['name']} · ${item['portion_text'] ?? '自然份量'}');
      }
    }
    if (a['item'] is Map) {
      lines.add(
          '添加：${a['item']['name']} · ${a['item']['portion_text'] ?? '自然份量'}');
    }
    if (a['changes'] is List) {
      for (final change in (a['changes'] as List).whereType<Map>()) {
        lines.addAll(_describe(Map<String, dynamic>.from(change)));
      }
    }
    return lines;
  }
}
