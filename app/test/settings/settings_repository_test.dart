import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/core/data.dart';
import 'package:food_journal/settings/settings_repository.dart';

void main() {
  group('Base URL', () {
    test('只去首尾空白和末尾斜杠，不自动添加 v1', () {
      expect(
          SettingsRepository.normalizeUrl(
              '  https://example.invalid/api///  ', false),
          'https://example.invalid/api');
      expect(SettingsRepository.normalizeUrl('https://example.invalid', false),
          'https://example.invalid');
      expect(
          SettingsRepository.normalizeUrl(
              'https://example.invalid/api/openai/v1', false),
          'https://example.invalid/api/openai/v1');
    });
    test('HTTP 必须显式同意', () {
      expect(
          () => SettingsRepository.normalizeUrl(
              'http://example.invalid/v1', false),
          throwsA(isA<AppError>()));
      expect(
          SettingsRepository.normalizeUrl('http://example.invalid/v1/', true),
          'http://example.invalid/v1');
    });
    for (final input in [
      '',
      'example.invalid/v1',
      'file:///v1',
      'https://user:password@example.invalid/v1',
      'https://example.invalid/v1?key=example',
      'https://example.invalid/v1#fragment',
      'https://example.invalid/v1/responses/',
      'https://example.invalid/v1/models',
    ]) {
      test('拒绝非前缀地址或有凭据泄露风险的地址 $input', () {
        expect(() => SettingsRepository.normalizeUrl(input, false),
            throwsA(isA<AppError>()));
      });
    }
  });

  group('按需配置模型', () {
    test('只填写文字主模型有效，不自动补出图片或兜底模型', () {
      final profile = {'text_main': 'text-only'};
      expect(() => SettingsRepository.validateModels(profile), returnsNormally);
      expect(configuredModelRoles(profile, vision: false), ['text_main']);
      expect(
          () => configuredModelRoles(profile, vision: true),
          throwsA(
              isA<AppError>().having((e) => e.code, 'code', 'configuration')));
    });
    test('图片主模型可与文字相同，兜底仅在已配置时启用', () {
      final profile = {
        'text_main': 'multimodal',
        'vision_main': 'multimodal',
        'text_backup': '',
        'vision_backup': 'vision-backup'
      };
      expect(() => SettingsRepository.validateModels(profile), returnsNormally);
      expect(configuredModelRoles(profile, vision: true),
          ['vision_main', 'vision_backup']);
      for (final patch in <Json>[
        {'text_main': ''},
        {'vision_main': ''},
        {'text_backup': 'multimodal'}
      ]) {
        expect(() => SettingsRepository.validateModels({...profile, ...patch}),
            throwsA(isA<AppError>()));
      }
    });
    test('每个角色的思考强度独立校验，旧四模型配置仍有效', () {
      final old = {for (final role in aiModelRoles) role: '$role-model'};
      expect(() => SettingsRepository.validateModels(old), returnsNormally);
      for (final effort in reasoningEfforts) {
        expect(
            () => SettingsRepository.validateModels(
                {...old, 'text_main_effort': effort}),
            returnsNormally);
      }
      expect(
          () => SettingsRepository.validateModels(
              {...old, 'vision_main_effort': 'unsupported'}),
          throwsA(isA<AppError>()));
    });
  });
}
