import 'dart:convert';

import 'package:uuid/uuid.dart';

typedef Json = Map<String, dynamic>;

String newId() => const Uuid().v4();
int nowMs() => DateTime.now().millisecondsSinceEpoch;
Json jsonMap(String value) =>
    Map<String, dynamic>.from(jsonDecode(value) as Map);
List<Json> jsonRows(String value) => (jsonDecode(value) as List)
    .map((e) => Map<String, dynamic>.from(e as Map))
    .toList();
String dateKey(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
String today() => dateKey(DateTime.now());
String portionUnit(String unit) => switch (unit.trim().toLowerCase()) {
      'ml' || '毫升' => 'ml',
      'g' || '克' => 'g',
      final value => value,
    };
String numberText(num value, [int digits = 1]) => digits == 0
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(digits).replaceFirst(RegExp(r'\.?0+$'), '');
const nutritionFields = ['calories_kcal', 'protein_g', 'fat_g', 'carbs_g'];
const nutritionNames = ['热量', '蛋白质', '脂肪', '碳水'];
const mealNames = {
  'breakfast': '早餐',
  'lunch': '午餐',
  'dinner': '晚餐',
  'other': '加餐 / 其他'
};
const sources = {
  'unknown': '未知',
  'ai': 'AI 估算',
  'user': '用户填写',
  'label': '包装标签',
  'library': '食品资料'
};
const recordActionTypes = [
  'create_meal',
  'add_food',
  'update_food',
  'modify_meal_contents',
  'update_meal',
  'delete_food',
  'delete_meal',
  'create_weight',
  'update_weight',
  'delete_weight',
  'create_exercise',
  'update_exercise',
  'delete_exercise',
  'undo_action'
];

class AppError implements Exception {
  final String message;
  final String code;
  const AppError(this.message, [this.code = 'invalid']);
  @override
  String toString() => message;
}

void require(bool condition, String message, [String code = 'invalid']) {
  if (!condition) throw AppError(message, code);
}

void validateNutrient(String field, Json n) {
  require(n.containsKey('value') && n.containsKey('source'), '营养字段缺少数值或来源');
  require(nutritionFields.contains(field), '不支持的营养字段');
  final value = n['value'];
  require(value == null || value is num && value.isFinite && value >= 0,
      '营养数值必须是非负数或未知');
  require(sources.containsKey(n['source']), '营养来源不正确');
  require(
      (value == null) == (n['source'] == 'unknown'), '未知营养须使用空值和 unknown 来源');
  if (field == 'calories_kcal' && value != null) {
    require(value is int, '热量须为整数 kcal');
  }
}

Json actionScope(Json action) => {
      'type': action['type'],
      for (final key in [
        'id',
        'meal_id',
        'action_id',
        'local_date',
        'meal_type',
        'raw_description',
        'question',
        'input_value',
        'input_unit',
        'name'
      ])
        if (action[key] is String) key: action[key],
      if (action['items'] is List)
        'foods': (action['items'] as List)
            .whereType<Map>()
            .where((f) => f['name'] is String)
            .map((f) => {
                  'name': f['name'],
                  if (f['portion_text'] is String)
                    'portion_text': f['portion_text']
                })
            .toList(),
      if (action['candidates'] is List)
        'candidates': (action['candidates'] as List)
            .whereType<Map>()
            .where((c) => c['id'] is String && c['type'] is String)
            .map((c) => {'id': c['id'], 'type': c['type']})
            .toList(),
    };

const exerciseFields = [
  'name',
  'duration_minutes',
  'distance_meters',
  'intensity',
  'calories_kcal',
  'calories_source',
  'calories_basis',
  'note'
];

void validateExercise(Json record) {
  require(
      record['name'] is String && (record['name'] as String).trim().isNotEmpty,
      '运动名称不能为空');
  for (final field in ['duration_minutes', 'distance_meters']) {
    final value = record[field];
    require(
        value == null ||
            value is num &&
                value.isFinite &&
                (field == 'duration_minutes' ? value > 0 : value >= 0),
        field == 'duration_minutes' ? '运动时长须大于 0，未知留空' : '运动距离须为非负数，未知留空');
  }
  for (final field in ['intensity', 'note']) {
    require(record[field] == null || record[field] is String, '运动说明格式不正确');
  }
  final value = record['calories_kcal'];
  final source = record['calories_source'];
  final basis = record['calories_basis'];
  require(value == null || value is int && value >= 0, '运动消耗须为非负整数 kcal');
  require(
      ['unknown', 'user', 'ai'].contains(source) &&
          (value == null) == (source == 'unknown'),
      '运动消耗与来源不一致');
  require(
      basis == null ||
          basis is Map && (source == 'unknown' || basis['note'] is String),
      '运动消耗依据须包含文字说明');
  if (source == 'ai') {
    require(
        record['duration_minutes'] is num && basis is Map, '估算运动消耗需要运动时长与依据');
    if (basis['method'] == 'range_midpoint') {
      require(
          basis['lower_kcal'] is num &&
              (basis['lower_kcal'] as num).isFinite &&
              basis['lower_kcal'] >= 0 &&
              basis['upper_kcal'] is num &&
              (basis['upper_kcal'] as num).isFinite &&
              basis['upper_kcal'] >= basis['lower_kcal'],
          '运动消耗估算区间须为非负数且上限不小于下限');
    } else {
      require(
          record['intensity'] is String &&
              (record['intensity'] as String).trim().isNotEmpty &&
              basis['weight_record_id'] is String &&
              basis['weight_version'] is int &&
              basis['weight_grams'] is int &&
              basis['weight_grams'] > 0 &&
              basis['met'] is num &&
              (basis['met'] as num).isFinite &&
              basis['met'] > 0,
          '估算运动消耗需要明确时长、强度、参考体重与 MET 依据');
    }
  }
}

String exerciseEnergy(Json row) => row['calories_kcal'] == null
    ? '消耗未知'
    : '${row['calories_source'] == 'ai' ? '约 ' : ''}${row['calories_kcal']} kcal';

String exerciseAmount(Json row) => [
      if (row['duration_minutes'] != null)
        '${numberText(row['duration_minutes'] as num)} 分钟',
      if (row['distance_meters'] != null)
        '${numberText(row['distance_meters'] as num)} 米',
      if (row['intensity'] != null && row['intensity'] != '')
        row['intensity'] as String,
    ].join(' · ');

void validateStoredExercise(Json row) {
  final basis = jsonMap(row['calories_basis_json'] as String);
  validateExercise({...row, 'calories_basis': basis});
  if (row['calories_source'] == 'ai') {
    require(
        basis['method'] is String &&
            basis['duration_minutes'] == row['duration_minutes'] &&
            basis['intensity'] == row['intensity'],
        '运动估算快照不完整');
    if (basis['method'] == 'range_midpoint') {
      require(
          ((basis['lower_kcal'] as num) / 2 + (basis['upper_kcal'] as num) / 2)
                  .round() ==
              row['calories_kcal'],
          '运动消耗须取估算区间中值');
      return;
    }
    require(basis['weight_local_date'] is String, '运动估算缺少参考体重日期');
    validateDate(basis['weight_local_date'] as String, null);
    require(
        (basis['weight_local_date'] as String)
                .compareTo(row['local_date'] as String) <=
            0,
        '运动估算不能使用之后的体重');
    require(
        ((basis['met'] as num) *
                    (basis['weight_grams'] as int) /
                    1000 *
                    (row['duration_minutes'] as num) /
                    60)
                .round() ==
            row['calories_kcal'],
        '运动估算换算不一致');
  }
}

void validateProposal(Json proposal) {
  final type = proposal['type'];
  require(
      [
        'save_common_food',
        'save_packaged_food',
        'update_library',
        'save_memory',
        'update_memory'
      ].contains(type),
      '不支持的资料建议');
  if ((type as String).endsWith('memory')) {
    require(
        proposal['content'] is String &&
            (proposal['content'] as String).trim().isNotEmpty,
        '偏好建议内容为空');
  } else {
    require(
        proposal['name'] is String &&
            (proposal['name'] as String).trim().isNotEmpty,
        '食品资料名称为空');
    final base = proposal['base_portion'];
    final nutrition = proposal['nutrition'];
    require(
        base is Map &&
            base['amount'] is num &&
            (base['amount'] as num).isFinite &&
            base['amount'] > 0 &&
            base['unit'] is String,
        '食品资料缺少有效基准');
    require(
        nutrition is Map &&
            nutritionFields.every(nutrition.containsKey) &&
            nutrition.keys.every(nutritionFields.contains) &&
            nutrition.values
                .every((n) => n == null || n is num && n.isFinite && n >= 0),
        '食品资料营养值不正确');
    for (final key in ['brand', 'variant']) {
      require(proposal[key] == null || proposal[key] is String, '食品资料文字格式不正确');
    }
    if (proposal['aliases'] != null) {
      require(
          proposal['aliases'] is List &&
              (proposal['aliases'] as List).every((a) => a is String),
          '食品别名格式不正确');
    }
    final spec = proposal['package_spec'];
    require(spec == null || spec is String || spec is Map, '包装规格格式不正确');
    if (spec is Map) {
      for (final key in ['unit', 'description']) {
        require(spec[key] == null || spec[key] is String, '包装规格文字格式不正确');
      }
    }
  }
  if ((type).startsWith('update_')) {
    require(
        proposal['target_id'] is String && proposal['expected_version'] is int,
        '资料更新缺少目标或版本');
  }
  if (proposal['source'] != null) {
    require(proposal['source'] is Map, '资料来源格式不正确');
    validateLibrarySource(Map<String, dynamic>.from(proposal['source'] as Map));
  }
}

void validateLibrarySource(Json source) {
  require(
      source['label_message_id'] == null ||
          source['label_message_id'] is String,
      '标签消息引用格式不正确');
  require(
      ['ai', 'user', 'label'].contains(source['type']), '食品资料来源须为用户、标签或 AI 估算');
  require(source['note'] == null || source['note'] is String, '资料来源说明格式不正确');
  require(
      source['remarks'] == null || source['remarks'] is String, '食品备注格式不正确');
  if (source['label'] != null) {
    require(source['label'] is Map, '原标签数据格式不正确');
    final label = source['label'] as Map;
    require(
        label['energy_value'] == null ||
            label['energy_value'] is num &&
                (label['energy_value'] as num).isFinite &&
                label['energy_value'] >= 0,
        '原标签能量格式不正确');
    require(
        label['energy_unit'] == null ||
            ['kJ', 'kcal'].contains(label['energy_unit']),
        '原标签能量单位无效');
  }
}

const timePeriods = ['凌晨', '早上', '上午', '中午', '下午', '傍晚', '晚上', '深夜'];

bool isClockTime(String? time) =>
    time != null && RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(time);

String clockTime(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

String recordDateTime(Json row) =>
    '${row['local_date']}${row['local_time'] == null ? '' : ' · ${row['local_time']}'}';

void validateDate(String date, String? time) {
  final parsed = DateTime.tryParse(date);
  require(
      RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) &&
          parsed != null &&
          parsed.year >= 1 &&
          parsed.year <= 9999 &&
          dateKey(parsed) == date,
      '日期格式不正确');
  require(time == null || isClockTime(time) || timePeriods.contains(time),
      '时间格式不正确');
}

int weightGrams(String value, String unit) {
  require(['jin', 'kg'].contains(unit), '请选择斤或公斤');
  require(RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(value), '体重需为正数，最多两位小数');
  final parts = value.split('.');
  final hundredths = int.parse(parts[0]) * 100 +
      (parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0);
  require(hundredths > 0, '体重必须大于 0');
  return hundredths * (unit == 'jin' ? 5 : 10);
}

Json referenceTime() {
  final time = DateTime.now();
  return {
    'local_date': dateKey(time),
    'local_time': clockTime(time),
    'timestamp_ms': time.millisecondsSinceEpoch,
    'utc_offset_minutes': time.timeZoneOffset.inMinutes
  };
}

Json timeColumns(Json input, Json reference) {
  final date = input['local_date'] as String;
  final time = input['local_time'] as String?;
  validateDate(date, time);
  final precise = isClockTime(time);
  final offset = precise ? reference['utc_offset_minutes'] as int : null;
  final occurred = precise
      ? DateTime.parse('${date}T$time:00Z').millisecondsSinceEpoch -
          offset! * 60000
      : null;
  return {
    'local_date': date,
    'local_time': time,
    'occurred_at_ms': occurred,
    'utc_offset_minutes': offset
  };
}
