import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:food_journal/app.dart';
import 'package:food_journal/core/data.dart';
import 'package:food_journal/core/database.dart';
import 'package:food_journal/records/record_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 通过生产建库入口创建独立临时库，不替换 SQL、事务或提交器。
class TestStore {
  final Directory directory;
  final AppDatabase database;
  final AppServices services;
  final DatabaseFactory? previousFactory;
  TestStore._(
      this.directory, this.database, this.services, this.previousFactory);

  RecordRepository get records => services.records;
  Database get db => database.db;

  static Future<TestStore> create() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    sqfliteFfiInit();
    final previous = databaseFactoryOrNull;
    final factory = createDatabaseFactoryFfi(noIsolate: true);
    databaseFactoryOrNull = factory;
    final directory =
        await Directory.systemTemp.createTemp('food-journal-test-');
    await factory.setDatabasesPath(directory.path);
    final database = await AppDatabase.open();
    final services = AppServices(RecordRepository(database));
    services.images.root =
        await Directory(p.join(directory.path, 'pending-images')).create();
    services.chat.foreground = false;
    return TestStore._(directory, database, services, previous);
  }

  Future<void> close() async {
    await services.chat.suspend();
    await db.close();
    services.chat.dispose();
    services.settings.theme.dispose();
    records.dispose();
    services.tab.dispose();
    services.day.dispose();
    services.chatIntent.dispose();
    databaseFactoryOrNull = previousFactory;
    await directory.delete(recursive: true);
  }
}

Json foodInput(
        {String name = '米饭',
        num? calories = 100,
        num? protein = 5,
        num? fat = 1,
        num? carbs = 20,
        Json? basis,
        String source = 'user'}) =>
    {
      'client_ref': newId(),
      'name': name,
      'portion_text': '一份',
      'nutrition': {
        for (final entry in <String, num?>{
          'calories_kcal': calories,
          'protein_g': protein,
          'fat_g': fat,
          'carbs_g': carbs
        }.entries)
          entry.key: {
            'value': entry.value,
            'source': entry.value == null ? 'unknown' : source
          }
      },
      'nutrition_basis': basis ?? {},
      'estimation_note': '固定测试数据'
    };

Json mealInput(
        {List<Json>? items,
        String date = '2026-10-20',
        String type = 'breakfast'}) =>
    {
      'type': 'create_meal',
      'client_ref': newId(),
      'local_date': date,
      'local_time': null,
      'meal_type': type,
      'raw_description': '测试早餐',
      'items': items ?? [foodInput()]
    };

Json weightInput({String value = '132', String date = '2026-10-20'}) => {
      'type': 'create_weight',
      'client_ref': newId(),
      'local_date': date,
      'local_time': null,
      'input_value': value,
      'input_unit': 'jin',
      'raw_description': '测试体重'
    };

String receiptId(Json receipt, String table) => (receipt['refs'] as List)
    .cast<Json>()
    .firstWhere((ref) => ref['table'] == table)['id'] as String;
