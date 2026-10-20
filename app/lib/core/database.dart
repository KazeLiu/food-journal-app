import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'data.dart';

class AppDatabase {
  static const schemaVersion = 3;
  final Database db;
  AppDatabase._(this.db);

  static Future<AppDatabase> open() async {
    final path = p.join(await getDatabasesPath(), 'food-journal.db');
    final db = await openDatabase(path,
        version: schemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          for (final statement in schema.split(';')) {
            if (statement.trim().isNotEmpty) await db.execute(statement);
          }
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
                'ALTER TABLE chat_messages ADD COLUMN model_reply_text TEXT');
            await db.execute(
                'ALTER TABLE chat_messages ADD COLUMN receipt_text TEXT');
          }
          if (oldVersion < 3) {
            await db.execute(
                'ALTER TABLE chat_messages ADD COLUMN reasoning_text TEXT');
          }
        });
    return AppDatabase._(db);
  }

  Future<void> normalizeInterrupted() async {
    await db.update(
        'operations', {'status': 'interrupted', 'updated_at_ms': nowMs()},
        where: "status IN ('running','pending')");
    final rows = await db.query('operations',
        columns: ['id', 'context_json'],
        where: 'context_json LIKE ?',
        whereArgs: ['%"manual_action_id"%']);
    for (final row in rows) {
      final context = jsonMap(row['context_json'] as String);
      if (context.remove('manual_action_id') != null) {
        await db.update('operations', {'context_json': jsonEncode(context)},
            where: 'id=?', whereArgs: [row['id']]);
      }
    }
  }

  static const businessTables = [
    'operations',
    'operation_actions',
    'chat_messages',
    'meals',
    'food_items',
    'weight_records',
    'food_library',
    'ai_memories',
    'consent_proposals'
  ];

  static const schema = '''
CREATE TABLE operations (
 id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN ('chat','manual','backfill','undo')),
 status TEXT NOT NULL CHECK(status IN ('pending','running','waiting_input','waiting_confirmation','ready','completed','partial','failed','interrupted','cancelled')),
 stage TEXT NOT NULL CHECK(stage IN ('vision','text','lookup','local','done')),
 reference_time_json TEXT NOT NULL, context_json TEXT NOT NULL, queue_order INTEGER UNIQUE,
 reply_to_action_id TEXT, request_generation INTEGER NOT NULL DEFAULT 0,
 vision_summary_json TEXT, plan_json TEXT, receipt_json TEXT, error_code TEXT,
 created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL);
CREATE TABLE operation_actions (
 id TEXT PRIMARY KEY, operation_id TEXT NOT NULL REFERENCES operations(id), action_key TEXT NOT NULL,
 type TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('planned','waiting_input','waiting_confirmation','ready','committed','failed','conflict','cancelled','undone')),
 payload_json TEXT, before_json TEXT, after_json TEXT, result_json TEXT,
 undo_of_action_id TEXT REFERENCES operation_actions(id), created_at_ms INTEGER NOT NULL,
 updated_at_ms INTEGER NOT NULL, UNIQUE(operation_id,action_key));
CREATE TABLE chat_messages (
 id TEXT PRIMARY KEY, operation_id TEXT REFERENCES operations(id) ON DELETE SET NULL,
 role TEXT NOT NULL CHECK(role IN ('user','assistant')), content_kind TEXT NOT NULL,
 body_text TEXT NOT NULL, model_reply_text TEXT, receipt_text TEXT, reasoning_text TEXT,
 delivery_status TEXT NOT NULL, image_count INTEGER NOT NULL DEFAULT 0 CHECK(image_count BETWEEN 0 AND 3),
 record_refs_json TEXT, quoted_message_id TEXT REFERENCES chat_messages(id) ON DELETE SET NULL,
 quote_snapshot_json TEXT, created_at_ms INTEGER NOT NULL, UNIQUE(operation_id,role));
CREATE TABLE chat_attachments (
 id TEXT PRIMARY KEY, message_id TEXT REFERENCES chat_messages(id) ON DELETE CASCADE,
 relative_path TEXT NOT NULL UNIQUE, mime_type TEXT NOT NULL, byte_length INTEGER NOT NULL CHECK(byte_length>0),
 state TEXT NOT NULL CHECK(state IN ('pending','delete_pending')), created_at_ms INTEGER NOT NULL);
CREATE TABLE meals (
 id TEXT PRIMARY KEY, origin_action_id TEXT NOT NULL REFERENCES operation_actions(id), client_ref TEXT NOT NULL,
 source_message_id TEXT REFERENCES chat_messages(id) ON DELETE SET NULL,
 local_date TEXT NOT NULL, local_time TEXT, occurred_at_ms INTEGER, utc_offset_minutes INTEGER,
 meal_type TEXT NOT NULL CHECK(meal_type IN ('breakfast','lunch','dinner','other')), raw_description TEXT NOT NULL,
 note TEXT, version INTEGER NOT NULL DEFAULT 1 CHECK(version>=1), deleted_at_ms INTEGER,
 created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, UNIQUE(origin_action_id,client_ref));
CREATE TABLE food_items (
 id TEXT PRIMARY KEY, meal_id TEXT NOT NULL REFERENCES meals(id), origin_action_id TEXT NOT NULL REFERENCES operation_actions(id),
 client_ref TEXT NOT NULL, name TEXT NOT NULL CHECK(length(trim(name))>0), portion_text TEXT,
 calories_kcal INTEGER CHECK(calories_kcal>=0), protein_g REAL CHECK(protein_g>=0),
 fat_g REAL CHECK(fat_g>=0), carbs_g REAL CHECK(carbs_g>=0), nutrition_sources_json TEXT NOT NULL,
 nutrition_basis_json TEXT NOT NULL, estimation_note TEXT, note TEXT,
 version INTEGER NOT NULL DEFAULT 1 CHECK(version>=1), deleted_at_ms INTEGER,
 created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, UNIQUE(origin_action_id,client_ref));
CREATE TABLE weight_records (
 id TEXT PRIMARY KEY, origin_action_id TEXT NOT NULL REFERENCES operation_actions(id), client_ref TEXT NOT NULL,
 source_message_id TEXT REFERENCES chat_messages(id) ON DELETE SET NULL, local_date TEXT NOT NULL,
 local_time TEXT, occurred_at_ms INTEGER, utc_offset_minutes INTEGER, input_value TEXT NOT NULL,
 input_unit TEXT NOT NULL CHECK(input_unit IN ('jin','kg')), grams INTEGER NOT NULL CHECK(grams>0),
 raw_description TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 1 CHECK(version>=1), deleted_at_ms INTEGER,
 created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, UNIQUE(origin_action_id,client_ref));
CREATE TABLE food_library (
 id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN ('common_meal','packaged_food')), name TEXT NOT NULL,
 aliases_json TEXT NOT NULL, brand TEXT, variant TEXT, package_spec_json TEXT, base_portion_json TEXT NOT NULL,
 nutrition_json TEXT NOT NULL, source_json TEXT NOT NULL, consent_action_id TEXT NOT NULL REFERENCES operation_actions(id),
 version INTEGER NOT NULL DEFAULT 1, deleted_at_ms INTEGER, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL);
CREATE TABLE ai_memories (
 id TEXT PRIMARY KEY, category TEXT NOT NULL, content TEXT NOT NULL,
 consent_action_id TEXT NOT NULL REFERENCES operation_actions(id), version INTEGER NOT NULL DEFAULT 1,
 deleted_at_ms INTEGER, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL);
CREATE TABLE consent_proposals (
 id TEXT PRIMARY KEY, operation_id TEXT REFERENCES operations(id), kind TEXT NOT NULL, dedupe_key TEXT NOT NULL,
 target_id TEXT, expected_version INTEGER, payload_json TEXT NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('pending','accepted','rejected','expired')),
 created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL);
CREATE TABLE app_settings (key TEXT PRIMARY KEY,value_json TEXT NOT NULL);
CREATE INDEX idx_messages_time ON chat_messages(created_at_ms,id);
CREATE INDEX idx_actions_operation ON operation_actions(operation_id,status);
CREATE INDEX idx_meals_day ON meals(local_date,deleted_at_ms,meal_type);
CREATE INDEX idx_food_meal ON food_items(meal_id,deleted_at_ms);
CREATE INDEX idx_weight_day ON weight_records(local_date,deleted_at_ms,local_time);
CREATE INDEX idx_library_name ON food_library(name,deleted_at_ms);
CREATE INDEX idx_proposals_key ON consent_proposals(dedupe_key,status);
CREATE INDEX idx_attachment_state ON chat_attachments(state);
''';
}
