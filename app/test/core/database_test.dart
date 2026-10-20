import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:food_journal/core/database.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../support/test_store.dart';

void main() {
  for (final version in [1, 2]) {
    test('已有 schema $version 数据库原地升级，保留聊天并增加思考字段', () async {
      final store = await TestStore.create();
      final directory =
          await Directory(p.join(store.directory.path, 'legacy')).create();
      try {
        await databaseFactory.setDatabasesPath(directory.path);
        const newColumns = ', model_reply_text TEXT, receipt_text TEXT';
        expect(AppDatabase.schema, contains(newColumns));
        var schema =
            AppDatabase.schema.replaceFirst(', reasoning_text TEXT', '');
        if (version == 1) schema = schema.replaceFirst(newColumns, '');
        final old = await openDatabase(
            p.join(directory.path, 'food-journal.db'),
            version: version, onCreate: (db, _) async {
          for (final statement in schema.split(';')) {
            if (statement.trim().isNotEmpty) await db.execute(statement);
          }
        });
        try {
          await old.insert('chat_messages', {
            'id': 'old-message',
            'role': 'assistant',
            'content_kind': 'text',
            'body_text': '升级前的回复',
            'delivery_status': 'completed',
            'created_at_ms': 1
          });
        } finally {
          await old.close();
        }
        final upgraded = await AppDatabase.open();
        try {
          expect(await upgraded.db.getVersion(), 3);
          final row = (await upgraded.db.query('chat_messages')).single;
          expect(row['body_text'], '升级前的回复');
          expect(row.containsKey('model_reply_text'), isTrue);
          expect(row['model_reply_text'], isNull);
          expect(row['receipt_text'], isNull);
          expect(row.containsKey('reasoning_text'), isTrue);
          expect(row['reasoning_text'], isNull);
        } finally {
          await upgraded.db.close();
        }
      } finally {
        await databaseFactory.setDatabasesPath(store.directory.path);
        await store.close();
      }
    });
  }
}
