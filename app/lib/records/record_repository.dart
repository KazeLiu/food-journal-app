import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../core/data.dart';
import '../core/database.dart';

class RecordRepository extends ChangeNotifier {
  // 时段只参与粗略排序，不据此生成或保存精确时间戳。
  static const _timeOrder = """CASE local_time
    WHEN '凌晨' THEN '00:00' WHEN '早上' THEN '06:00' WHEN '上午' THEN '09:00'
    WHEN '中午' THEN '12:00' WHEN '下午' THEN '13:00' WHEN '傍晚' THEN '17:00'
    WHEN '晚上' THEN '19:00' WHEN '深夜' THEN '23:00' ELSE local_time END""";
  final AppDatabase database;
  Database get db => database.db;
  RecordRepository(this.database);
  void changed() => notifyListeners();

  Future<Json?> row(String table, String id,
      {DatabaseExecutor? executor, bool includeDeleted = false}) async {
    require([...AppDatabase.businessTables, 'chat_attachments'].contains(table),
        '不支持的数据类型');
    final rows = await (executor ?? db).query(table,
        where: 'id=?'
            '${includeDeleted || !entityTables.contains(table) ? '' : ' AND deleted_at_ms IS NULL'}',
        whereArgs: [id]);
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.single);
  }

  static const entityTables = [
    'meals',
    'food_items',
    'weight_records',
    'food_library',
    'ai_memories'
  ];

  Future<List<Json>> meals(String date) async {
    final rows = await db.query('meals',
        where: 'local_date=? AND deleted_at_ms IS NULL',
        whereArgs: [date],
        orderBy: 'local_time IS NULL,$_timeOrder,created_at_ms');
    return Future.wait(rows.map(
        (row) async => {...row, 'items': await foods(row['id'] as String)}));
  }

  Future<List<Json>> foods(String mealId) async => db.query('food_items',
      where: 'meal_id=? AND deleted_at_ms IS NULL',
      whereArgs: [mealId],
      orderBy: 'created_at_ms,id');

  Future<List<Json>> weights(
          {String? date, int? limit = 100, int offset = 0}) =>
      db.query('weight_records',
          where:
              'deleted_at_ms IS NULL${date == null ? '' : ' AND local_date=?'}',
          whereArgs: date == null ? [] : [date],
          orderBy:
              'occurred_at_ms IS NULL,occurred_at_ms DESC,created_at_ms DESC,id DESC',
          limit: limit,
          offset: offset);

  Future<Json> totals(String from, [String? to]) async {
    final rows = await db.rawQuery('''SELECT COUNT(*) item_count,
      ${nutritionFields.map((f) => 'COALESCE(SUM(f.$f),0) $f,COALESCE(SUM(CASE WHEN f.$f IS NULL THEN 1 ELSE 0 END),0) missing_$f').join(',')}
      FROM food_items f JOIN meals m ON m.id=f.meal_id
      WHERE m.local_date BETWEEN ? AND ? AND m.deleted_at_ms IS NULL AND f.deleted_at_ms IS NULL''',
        [from, to ?? from]);
    final count =
        await db.rawQuery('''SELECT meal_type,COUNT(*) count FROM meals m
      WHERE m.local_date BETWEEN ? AND ? AND m.deleted_at_ms IS NULL
      AND EXISTS(SELECT 1 FROM food_items f WHERE f.meal_id=m.id AND f.deleted_at_ms IS NULL)
      GROUP BY meal_type''', [from, to ?? from]);
    return {
      ...rows.single,
      'meal_count': count.where((e) => e['meal_type'] != 'other').length,
      'other_count': count
          .where((e) => e['meal_type'] == 'other')
          .fold<int>(0, (a, e) => a + (e['count'] as int))
    };
  }

  Future<Map<String, Set<String>>> monthMarks(DateTime month) async {
    final start = dateKey(DateTime(month.year, month.month));
    final end = dateKey(DateTime(month.year, month.month + 1, 0));
    final meals = await db.rawQuery(
        '''SELECT DISTINCT local_date FROM meals m WHERE local_date BETWEEN ? AND ?
      AND deleted_at_ms IS NULL AND EXISTS(SELECT 1 FROM food_items f WHERE f.meal_id=m.id AND f.deleted_at_ms IS NULL)''',
        [start, end]);
    final weights = await db.rawQuery(
        'SELECT DISTINCT local_date FROM weight_records WHERE local_date BETWEEN ? AND ? AND deleted_at_ms IS NULL',
        [start, end]);
    return {
      'food': meals.map((e) => e['local_date'] as String).toSet(),
      'weight': weights.map((e) => e['local_date'] as String).toSet()
    };
  }

  Future<List<Json>> messages(
      {Json? before, Json? through, String? keyword, int limit = 50}) {
    final conditions = <String>[];
    final args = <Object?>[];
    if (before != null) {
      conditions.add('(c.created_at_ms<? OR (c.created_at_ms=? AND c.id<?))');
      args.addAll(
          [before['created_at_ms'], before['created_at_ms'], before['id']]);
    }
    if (through != null) {
      conditions.add('(c.created_at_ms<? OR (c.created_at_ms=? AND c.id<=?))');
      args.addAll(
          [through['created_at_ms'], through['created_at_ms'], through['id']]);
    }
    if (keyword != null) {
      conditions.add("c.body_text LIKE ? ESCAPE '\\'");
      args.add('%${escapeLike(keyword)}%');
    }
    return _messageRows(
        where: conditions.isEmpty ? null : conditions.join(' AND '),
        whereArgs: args,
        limit: limit);
  }

  Future<List<Json>> _messageRows(
          {String? where,
          List<Object?> whereArgs = const [],
          String orderBy = 'c.created_at_ms DESC,c.id DESC',
          int limit = 50}) =>
      db.rawQuery('''SELECT c.*,o.context_json AS sent_context_json
        FROM chat_messages c LEFT JOIN operations o ON o.id=c.operation_id
        ${where == null ? '' : 'WHERE $where'} ORDER BY $orderBy LIMIT ?''',
          [...whereArgs, limit]);

  static String escapeLike(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');

  Future<List<Json>> messagesAround(String id) async {
    final targets =
        await _messageRows(where: 'c.id=?', whereArgs: [id], limit: 1);
    final target = targets.isEmpty ? null : targets.single;
    require(target != null, '这条消息已删除');
    final older = await messages(before: target, limit: 25);
    final newer = await _messageRows(
        where: '(c.created_at_ms>? OR (c.created_at_ms=? AND c.id>?))',
        whereArgs: [target!['created_at_ms'], target['created_at_ms'], id],
        orderBy: 'c.created_at_ms,c.id',
        limit: 25);
    return [...older.reversed, target, ...newer];
  }

  static Json quoteSnapshot(Json message) {
    final context = message['sent_context_json'] == null
        ? <String, dynamic>{}
        : jsonMap(message['sent_context_json'] as String);
    final scope = <String, dynamic>{
      for (final key in ['local_date', 'label', 'record_table', 'record_id'])
        if (context[key] != null) key: context[key],
    };
    return {
      'body_text': message['body_text'],
      'record_refs_json': message['record_refs_json'],
      if (scope.isNotEmpty) 'context': scope,
    };
  }

  Future<Json> createOperation(
      {String kind = 'manual',
      String status = 'ready',
      Json? reference,
      Json context = const {},
      String? replyTo,
      DatabaseExecutor? executor}) async {
    final now = nowMs();
    final row = <String, dynamic>{
      'id': newId(),
      'kind': kind,
      'status': status,
      'stage': kind == 'chat' ? 'text' : 'local',
      'reference_time_json': jsonEncode(reference ?? referenceTime()),
      'context_json': jsonEncode(context),
      'reply_to_action_id': replyTo,
      'request_generation': 0,
      'created_at_ms': now,
      'updated_at_ms': now
    };
    await (executor ?? db).insert('operations', row);
    return row;
  }

  Future<Json> enqueue(String text, List<String> attachments, Json context,
      Json? quote, String? replyTo,
      {bool clearDraft = true}) async {
    final reference = referenceTime();
    final result = await db.transaction((tx) async {
      final operation = await createOperation(
          kind: 'chat',
          status: 'pending',
          reference: reference,
          context: context,
          replyTo: replyTo,
          executor: tx);
      final last = Sqflite.firstIntValue(await tx
          .rawQuery('SELECT COALESCE(MAX(queue_order),0) FROM operations'))!;
      await tx.update('operations', {'queue_order': last + 1},
          where: 'id=?', whereArgs: [operation['id']]);
      final messageId = newId();
      final quoteExists = quote != null &&
          await row('chat_messages', quote['id'] as String, executor: tx) !=
              null;
      await tx.insert('chat_messages', {
        'id': messageId,
        'operation_id': operation['id'],
        'role': 'user',
        'content_kind': 'text',
        'body_text': text,
        'delivery_status': 'pending',
        'image_count': attachments.length,
        'quoted_message_id': quoteExists ? quote['id'] : null,
        'quote_snapshot_json':
            quote == null ? null : jsonEncode(quoteSnapshot(quote)),
        'created_at_ms': nowMs()
      });
      for (final id in attachments) {
        final count = await tx.update(
            'chat_attachments', {'message_id': messageId},
            where: 'id=? AND message_id IS NULL', whereArgs: [id]);
        require(count == 1, '图片已失效，请重新选择');
      }
      if (clearDraft) {
        await tx
            .delete('app_settings', where: 'key=?', whereArgs: ['chat_draft']);
      }
      return {...operation, 'message_id': messageId};
    });
    changed();
    return result;
  }

  Future<List<Json>> pendingOperations() => db.query('operations',
      where: "kind='chat' AND status='pending'",
      orderBy:
          'CASE WHEN reply_to_action_id IS NOT NULL THEN 0 ELSE 1 END,queue_order');

  Future<Json> inputFor(String operationId) async {
    final rows = await db.query('chat_messages',
        where: "operation_id=? AND role='user'", whereArgs: [operationId]);
    require(rows.isNotEmpty, '原消息已删除，不能继续处理');
    return Map<String, dynamic>.from(rows.single);
  }

  Future<void> operationState(String id, String status,
      {String? stage, String? error, int? generation}) async {
    await db.update(
        'operations',
        {
          'status': status,
          'updated_at_ms': nowMs(),
          'error_code': error,
          if (stage != null) 'stage': stage,
          if (generation != null) 'request_generation': generation
        },
        where: 'id=?',
        whereArgs: [id]);
    changed();
  }

  Future<void> assistant(String operationId, String text, String status,
      {List<Json>? refs,
      bool modelReply = false,
      String? reasoningText}) async {
    if (refs != null) {
      await db.update('chat_messages', {'record_refs_json': jsonEncode(refs)},
          where: "operation_id=? AND role='user'", whereArgs: [operationId]);
    }
    final rows = await db.query('chat_messages',
        where: "operation_id=? AND role='assistant'", whereArgs: [operationId]);
    final reply = modelReply
        ? text
        : rows.isEmpty
            ? null
            : rows.single['model_reply_text'] as String?;
    final receipt = modelReply ? null : text;
    final values = <String, dynamic>{
      'body_text': reply == null || reply.isEmpty
          ? text
          : receipt == null || receipt.isEmpty || receipt == reply
              ? reply
              : '$reply\n\n$receipt',
      'model_reply_text': reply,
      'receipt_text': receipt,
      'delivery_status': status,
      if (reasoningText != null) 'reasoning_text': reasoningText,
      if (refs != null) 'record_refs_json': jsonEncode(refs)
    };
    if (rows.isEmpty) {
      await db.insert('chat_messages', {
        ...values,
        'id': newId(),
        'operation_id': operationId,
        'role': 'assistant',
        'content_kind': 'text',
        'created_at_ms': nowMs()
      });
    } else {
      await db.update('chat_messages', values,
          where: 'id=?', whereArgs: [rows.single['id']]);
    }
    changed();
  }

  Future<void> saveReasoning(String operationId, String text) async {
    await db.update('chat_messages', {'reasoning_text': text},
        where: "operation_id=? AND role='assistant'", whereArgs: [operationId]);
    changed();
  }

  Future<List<Json>> actions(String operationId) async {
    final rows = await db.query('operation_actions',
        where: 'operation_id=?',
        whereArgs: [operationId],
        orderBy: 'created_at_ms,id');
    final operation = await row('operations', operationId);
    if (operation?['plan_json'] == null) return rows;
    final plan = jsonRows(operation!['plan_json'] as String);
    final order = {
      for (var i = 0; i < plan.length; i++) plan[i]['action_key']: i
    };
    final result = rows.map((r) => Map<String, dynamic>.from(r)).toList();
    result.sort((a, b) =>
        (order[a['action_key']] ?? -1).compareTo(order[b['action_key']] ?? -1));
    return result;
  }

  Future<List<Json>> recordHistory(String id) => db.query('operation_actions',
      where:
          "(before_json LIKE ? OR after_json LIKE ?) AND status IN ('committed','undone')",
      whereArgs: ['%"$id"%', '%"$id"%'],
      orderBy: 'created_at_ms DESC',
      limit: 20);

  Future<void> deleteMessage(String id) async {
    await db.transaction((tx) async {
      await tx.update('chat_attachments', {'state': 'delete_pending'},
          where: 'message_id=?', whereArgs: [id]);
      // 保留待删附件行，文件删除后才能移除清理依据。
      await tx.update('chat_attachments', {'message_id': null},
          where: 'message_id=?', whereArgs: [id]);
      await tx.delete('chat_messages', where: 'id=?', whereArgs: [id]);
    });
    changed();
  }

  Future<List<Json>> library(
          {String keyword = '',
          int limit = 100,
          String? brand,
          String? variant,
          String? packageSpec}) =>
      db.query('food_library',
          where:
              "deleted_at_ms IS NULL AND (name LIKE ? ESCAPE '\\' OR brand LIKE ? ESCAPE '\\' OR aliases_json LIKE ? ESCAPE '\\' OR variant LIKE ? ESCAPE '\\' OR package_spec_json LIKE ? ESCAPE '\\')"
              "${brand == null ? '' : " AND brand LIKE ? ESCAPE '\\'"}${variant == null ? '' : " AND variant LIKE ? ESCAPE '\\'"}${packageSpec == null ? '' : " AND package_spec_json LIKE ? ESCAPE '\\'"}",
          whereArgs: [
            ...List.filled(5, '%${escapeLike(keyword)}%'),
            if (brand != null) '%${escapeLike(brand)}%',
            if (variant != null) '%${escapeLike(variant)}%',
            if (packageSpec != null) '%${escapeLike(packageSpec)}%'
          ],
          orderBy: 'updated_at_ms DESC,id',
          limit: limit);

  Future<List<Json>> memories() => db.query('ai_memories',
      where: 'deleted_at_ms IS NULL', orderBy: 'updated_at_ms DESC');
  Future<List<Json>> proposals({String? operationId}) => db.query(
      'consent_proposals',
      where:
          "status='pending'${operationId == null ? '' : ' AND operation_id=?'}",
      whereArgs: operationId == null ? [] : [operationId],
      orderBy: 'created_at_ms');

  Future<List<Json>> missingNutrition() => db.rawQuery(
      '''SELECT f.*,m.local_date FROM food_items f JOIN meals m ON f.meal_id=m.id
    WHERE f.deleted_at_ms IS NULL AND m.deleted_at_ms IS NULL
    AND (${nutritionFields.map((f) => 'f.$f IS NULL').join(' OR ')}) ORDER BY f.created_at_ms''');

  Future<Json> lookup(Json query) async {
    final limit = query['limit'] as int? ?? 10;
    require(limit >= 1 && limit <= 50, '历史查询条数超出范围');
    final from = query['date_from'] as String? ?? '0001-01-01';
    final to = query['date_to'] as String? ?? '9999-12-31';
    validateDate(from, null);
    validateDate(to, null);
    require(from.compareTo(to) <= 0, '查询日期范围不正确');
    List<Json> rows;
    switch (query['type']) {
      case 'find_food':
        rows = await db.rawQuery(
            '''SELECT f.*,m.local_date,m.meal_type,m.version meal_version FROM food_items f
          JOIN meals m ON m.id=f.meal_id WHERE f.deleted_at_ms IS NULL AND m.deleted_at_ms IS NULL
          AND m.local_date BETWEEN ? AND ? AND f.name LIKE ? ESCAPE '\\'
          ORDER BY m.local_date DESC,f.created_at_ms DESC LIMIT ?''',
            [
              from,
              to,
              '%${escapeLike(query['keyword'] as String)}%',
              limit + 1
            ]);
      case 'list_meals':
        final type = query['meal_type'] as String?;
        if (type != null) require(mealNames.containsKey(type), '餐别不正确');
        final meals = await db.query('meals',
            where:
                'deleted_at_ms IS NULL AND local_date BETWEEN ? AND ?${type == null ? '' : ' AND meal_type=?'}',
            whereArgs: [from, to, if (type != null) type],
            orderBy: 'local_date DESC,created_at_ms DESC',
            limit: limit + 1);
        rows = await Future.wait(meals
            .map((m) async => {...m, 'items': await foods(m['id'] as String)}));
      case 'recent_weights':
        rows = await db.query('weight_records',
            where: 'deleted_at_ms IS NULL AND local_date BETWEEN ? AND ?',
            whereArgs: [from, to],
            orderBy: 'local_date DESC,$_timeOrder DESC,created_at_ms DESC',
            limit: limit + 1);
      case 'nutrition_totals':
        rows = [await totals(from, to)];
      case 'find_library':
        rows = await library(
            keyword: query['keyword'] as String? ?? '',
            limit: limit + 1,
            brand: query['brand'] as String?,
            variant: query['variant'] as String?,
            packageSpec: query['package_spec'] as String?);
      default:
        throw const AppError('不支持的历史查询类型');
    }
    return {
      'query_id': query['query_id'],
      'rows': rows.take(limit).toList(),
      'returned_count': rows.take(limit).length,
      'truncated': rows.length > limit
    };
  }
}
