import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

import '../core/data.dart';
import '../records/record_repository.dart';

const aiModelRoles = [
  'text_main',
  'text_backup',
  'vision_main',
  'vision_backup'
];
const reasoningEfforts = [
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max'
];

List<String> configuredModelRoles(Json profile, {required bool vision}) {
  final main = vision ? 'vision_main' : 'text_main';
  final backup = vision ? 'vision_backup' : 'text_backup';
  require(
      (profile[main] as String? ?? '').isNotEmpty,
      vision ? '请先在“我的 → AI 接口与模型”配置图片主模型，也可以手动记录。' : '请先配置文字主模型。',
      'configuration');
  return [main, if ((profile[backup] as String? ?? '').isNotEmpty) backup];
}

class SettingsRepository {
  final RecordRepository records;
  final FlutterSecureStorage secure = const FlutterSecureStorage();
  final ValueNotifier<String> theme = ValueNotifier('system');
  SettingsRepository(this.records);

  Future<dynamic> get(String key, [dynamic defaultValue]) async {
    final rows = await records.db
        .query('app_settings', where: 'key=?', whereArgs: [key]);
    return rows.isEmpty
        ? defaultValue
        : jsonDecode(rows.single['value_json'] as String);
  }

  Future<void> set(String key, dynamic value) async {
    await records.db.insert(
        'app_settings', {'key': key, 'value_json': jsonEncode(value)},
        conflictAlgorithm: ConflictAlgorithm.replace);
    if (key == 'theme_mode') theme.value = value as String;
    records.changed();
  }

  Future<Json> bodyProfile() async => {
        'height_cm': await get('height_cm'),
        'sex': await get('sex'),
      };

  static void validateBodyProfile(Json profile) {
    final height = profile['height_cm'];
    require(
        height == null ||
            height is num && height.isFinite && height > 0 && height <= 300,
        '身高请输入大于 0、不超过 300 的厘米数，或留空清除');
    require([null, 'male', 'female'].contains(profile['sex']), '性别设置不正确');
  }

  static String normalizeUrl(String input, bool allowHttp) {
    final value = input.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(value);
    require(
        uri != null &&
            uri.host.isNotEmpty &&
            ['https', 'http'].contains(uri.scheme),
        '请输入完整的 HTTPS 接口前缀');
    require(uri!.userInfo.isEmpty && !uri.hasQuery && !uri.hasFragment,
        '接口地址不能含用户名、密码、查询参数或片段');
    require(!uri.path.endsWith('/responses') && !uri.path.endsWith('/models'),
        '请填写接口前缀，不含 /responses 或 /models');
    require(uri.scheme == 'https' || allowHttp, 'HTTP 会明文传输 Key，请先确认风险');
    return value;
  }

  Future<void> saveProfile(Json profile, String key) async {
    final url = normalizeUrl(
        profile['base_url'] as String, profile['allow_http'] == true);
    require(key.trim().isNotEmpty, '请输入 API Key');
    validateModels(profile);
    await secure.write(
        key: 'ai_credential',
        value: jsonEncode({'base_url': url, 'key': key.trim()}));
    await set('ai_profile', {...profile, 'base_url': url});
  }

  static void validateModels(Json profile) {
    require(
        profile['request_reasoning_summary'] == null ||
            profile['request_reasoning_summary'] is bool,
        '思考摘要开关格式不正确');
    require((profile['text_main'] as String? ?? '').trim().isNotEmpty,
        '请填写文字主模型 ID');
    for (final role in aiModelRoles) {
      final effort = profile['${role}_effort'];
      require(effort == null || reasoningEfforts.contains(effort), '思考强度不受支持');
    }
    for (final prefix in ['text', 'vision']) {
      final main = (profile['${prefix}_main'] as String? ?? '').trim();
      final backup = (profile['${prefix}_backup'] as String? ?? '').trim();
      require(backup.isEmpty || main.isNotEmpty, '填写图片兜底前，请先填写图片主模型');
      require(backup.isEmpty || backup != main, '同类型的主模型与兜底模型须不同');
    }
  }

  Future<String> keyFor(String baseUrl) async {
    final raw = await secure.read(key: 'ai_credential');
    require(raw != null, '请先配置 AI 接口', 'configuration');
    final entry = jsonMap(raw!);
    require(
        entry['base_url'] == baseUrl, '地址已变更，请重新输入并保存 Key', 'configuration');
    return entry['key'] as String;
  }
}
