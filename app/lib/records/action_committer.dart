import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/data.dart';
import 'record_repository.dart';

class ActionCommitter {
  final RecordRepository records;
  ActionCommitter(this.records);

  Future<List<Json>> savePlan(String operationId, List<Json> actions,
      {Map<String, String> errors = const {}}) async {
    await records.db.transaction((tx) async {
      final operation =
          await records.row('operations', operationId, executor: tx);
      require(operation != null && operation['status'] != 'cancelled',
          '这项任务已经取消', 'cancelled');
      require(
          !jsonMap(operation!['context_json'] as String)
              .containsKey('manual_action_id'),
          '该输入正在手动处理',
          'cancelled');
      if (operation['kind'] == 'chat') {
        final reference = jsonMap(operation['reference_time_json'] as String);
        actions = actions
            .map((input) => ['create_meal', 'create_weight', 'create_exercise']
                        .contains(input['type']) &&
                    input['state'] != 'clarify' &&
                    input['local_date'] == reference['local_date'] &&
                    input['local_time'] == null
                ? {...input, 'local_time': reference['local_time']}
                : input)
            .toList();
      }
      var updated = false;
      for (final input in actions) {
        final key = input['action_key'] as String;
        final old = await tx.query('operation_actions',
            where: 'operation_id=? AND action_key=?',
            whereArgs: [operationId, key]);
        if (old.isNotEmpty &&
            ['committed', 'undone', 'cancelled']
                .contains(old.single['status'])) {
          continue;
        }
        updated = true;
        final error = errors[key];
        final status = error != null
            ? 'failed'
            : switch (input['state']) {
                'clarify' => 'waiting_input',
                'confirm' => 'waiting_confirmation',
                _ => 'ready'
              };
        if (old.isEmpty) {
          await tx.insert('operation_actions', {
            'id': newId(),
            'operation_id': operationId,
            'action_key': key,
            'type': input['type'],
            'status': status,
            'payload_json': error == null ? jsonEncode(input) : null,
            if (error != null)
              'result_json': jsonEncode({
                'error': error,
                'needs_replan': true,
                'scope': actionScope(input)
                  ..remove('id')
                  ..remove('meal_id')
                  ..remove('action_id')
                  ..remove('candidates')
              }),
            'created_at_ms': nowMs(),
            'updated_at_ms': nowMs()
          });
        } else {
          await tx.update(
              'operation_actions',
              {
                'type': input['type'],
                'status': status,
                'payload_json': error == null ? jsonEncode(input) : null,
                if (error != null)
                  'result_json': jsonEncode({
                    'error': error,
                    'needs_replan': true,
                    'scope': actionScope(input)
                      ..remove('id')
                      ..remove('meal_id')
                      ..remove('action_id')
                      ..remove('candidates')
                  }),
                'updated_at_ms': nowMs()
              },
              where: 'id=?',
              whereArgs: [old.single['id']]);
        }
      }
      if (updated || actions.isEmpty) {
        await tx.update(
            'operations',
            {
              'plan_json': jsonEncode(actions
                  .map((a) => errors.containsKey(a['action_key'])
                      ? {
                          'action_key': a['action_key'],
                          'type': a['type'],
                          'error': errors[a['action_key']]
                        }
                      : a)
                  .toList()),
              'status': 'ready',
              'updated_at_ms': nowMs()
            },
            where: 'id=?',
            whereArgs: [operationId]);
      }
    });
    records.changed();
    return records.actions(operationId);
  }

  Future<Json> local(Json payload,
      {String? actionId, String? sourceOperationId}) async {
    if (payload['type'] == 'undo_action') {
      final previous = await records.db.query('operation_actions',
          where: "undo_of_action_id=? AND status='committed'",
          whereArgs: [payload['action_id']],
          limit: 1);
      if (previous.isNotEmpty) {
        return jsonMap(previous.single['result_json'] as String);
      }
    }
    Json action;
    if (actionId != null) {
      final current = await records.row('operation_actions', actionId);
      require(
          current != null &&
              !['committed', 'undone'].contains(current['status']),
          '这项记录已经处理');
      action = current!;
      await records.db.update(
          'operation_actions',
          {
            'payload_json': jsonEncode({...payload, 'state': 'ready'}),
            'type': payload['type'],
            'status': 'ready'
          },
          where: 'id=?',
          whereArgs: [actionId]);
    } else if (sourceOperationId != null) {
      action = await records.db.transaction((tx) async {
        final op =
            await records.row('operations', sourceOperationId, executor: tx);
        require(
            op != null &&
                jsonMap(op['context_json'] as String)['manual_action_id'] ==
                    'input',
            '原输入未进入手动处理状态');
        final existing = await tx.query('operation_actions',
            columns: ['id'],
            where: 'operation_id=?',
            whereArgs: [sourceOperationId],
            limit: 1);
        require(existing.isEmpty, '原输入已经有处理事项，不能重复新增');
        final action = <String, dynamic>{
          'id': newId(),
          'operation_id': sourceOperationId,
          'action_key': 'manual_input',
          'type': payload['type'],
          'status': 'ready',
          'payload_json': jsonEncode(payload),
          'created_at_ms': nowMs(),
          'updated_at_ms': nowMs()
        };
        await tx.insert('operation_actions', action);
        await tx.update('operations',
            {'status': 'ready', 'stage': 'local', 'updated_at_ms': nowMs()},
            where: 'id=?', whereArgs: [sourceOperationId]);
        return action;
      });
    } else {
      final operation = await records.createOperation(
          kind: payload['type'] == 'backfill'
              ? 'backfill'
              : payload['type'] == 'undo_action'
                  ? 'undo'
                  : 'manual');
      action = (await savePlan(operation['id'] as String, [
        {...payload, 'action_key': 'local', 'state': 'ready'}
      ]))
          .single;
    }
    try {
      final result = await commit(action['id'] as String, localAuthority: true);
      await settle(action['operation_id'] as String);
      return result;
    } catch (error) {
      await fail(action['id'] as String, error);
      await settle(action['operation_id'] as String);
      rethrow;
    }
  }

  Future<Json> commit(String actionId,
      {String? acceptedProposalId, bool localAuthority = false}) async {
    final result = await records.db.transaction((tx) async {
      final action =
          (await records.row('operation_actions', actionId, executor: tx))!;
      if (['committed', 'undone'].contains(action['status'])) {
        return jsonMap(action['result_json'] as String);
      }
      if (acceptedProposalId != null) {
        final proposal = await records
            .row('consent_proposals', acceptedProposalId, executor: tx);
        require(
            proposal != null && proposal['status'] == 'pending', '这项建议已经处理');
      }
      require(action['status'] == 'ready', '这项操作尚未准备好');
      require(action['payload_json'] != null, '此操作需要重新生成提案');
      final payload = jsonMap(action['payload_json'] as String);
      final operation = (await records
          .row('operations', action['operation_id'] as String, executor: tx))!;
      require(
          localAuthority ||
              !jsonMap(operation['context_json'] as String)
                  .containsKey('manual_action_id'),
          '该事项正在手动处理',
          'cancelled');
      final reference = jsonMap(operation['reference_time_json'] as String);
      final inputMessages = await tx.query('chat_messages',
          where: "operation_id=? AND role='user'",
          whereArgs: [operation['id']]);
      final mutation = _Mutation(
          records,
          tx,
          actionId,
          inputMessages.isEmpty ? null : inputMessages.single['id'] as String?,
          reference);
      if (payload['type'] == 'undo_action') {
        await _undo(mutation, payload['action_id'] as String);
      } else {
        await _apply(mutation, payload);
      }
      final after = await mutation.after();
      final receipt = {
        'action_id': actionId,
        'type': payload['type'],
        'refs': after
            .where((e) => e['row'] != null)
            .map((e) =>
                {'table': e['table'], 'id': e['id'], 'action_id': actionId})
            .toList()
      };
      await tx.update(
          'operation_actions',
          {
            'status': 'committed',
            'before_json': jsonEncode(mutation.before.values.toList()),
            'after_json': jsonEncode(after),
            'result_json': jsonEncode(receipt),
            'updated_at_ms': nowMs(),
            if (payload['type'] == 'undo_action')
              'undo_of_action_id': payload['action_id']
          },
          where: 'id=?',
          whereArgs: [actionId]);
      if (payload['type'] == 'create_exercise' &&
          payload['follow_up_question'] is String) {
        final exercise =
            after.singleWhere((e) => e['table'] == 'exercise_records')['row']
                as Json;
        await tx.insert('operation_actions', {
          'id': newId(),
          'operation_id': action['operation_id'],
          'action_key': 'exercise_follow_up_$actionId',
          'type': 'update_exercise',
          'status': 'waiting_input',
          'payload_json': jsonEncode({
            'type': 'update_exercise',
            'state': 'clarify',
            'id': exercise['id'],
            'expected_version': exercise['version'],
            'question': payload['follow_up_question'],
            'optional_follow_up': true,
            'candidates': [
              {'type': 'exercise', 'id': exercise['id']}
            ]
          }),
          'created_at_ms': nowMs(),
          'updated_at_ms': nowMs()
        });
      }
      if (acceptedProposalId != null) {
        await tx.update('consent_proposals',
            {'status': 'accepted', 'updated_at_ms': nowMs()},
            where: 'id=?', whereArgs: [acceptedProposalId]);
      }
      return receipt;
    });
    records.changed();
    return result;
  }

  Future<void> fail(String actionId, Object error,
      {bool needsReplan = false}) async {
    final action = await records.row('operation_actions', actionId);
    final scope = action?['payload_json'] == null
        ? null
        : actionScope(jsonMap(action!['payload_json'] as String));
    await records.db.update(
        'operation_actions',
        {
          'status': error is AppError && error.code == 'conflict'
              ? 'conflict'
              : 'failed',
          'result_json': jsonEncode({
            'error': error is AppError ? error.message : '本地未保存，请重试保存',
            if (needsReplan) 'needs_replan': true,
            if (scope != null) 'scope': scope,
          }),
          if (needsReplan) 'payload_json': null,
          'updated_at_ms': nowMs()
        },
        where: "id=? AND status NOT IN ('committed','undone')",
        whereArgs: [actionId]);
    records.changed();
  }

  Future<void> settle(String operationId) async {
    final actions = await records.actions(operationId);
    final complete = actions.every((a) =>
        ['committed', 'undone'].contains(a['status']) ||
        ['waiting_input', 'cancelled'].contains(a['status']) &&
            a['payload_json'] != null &&
            jsonMap(a['payload_json'] as String)['optional_follow_up'] == true);
    final partial =
        actions.any((a) => ['committed', 'undone'].contains(a['status']));
    final status = complete
        ? 'completed'
        : partial
            ? 'partial'
            : actions.any((a) => a['status'] == 'waiting_input')
                ? 'waiting_input'
                : actions.any((a) => a['status'] == 'waiting_confirmation')
                    ? 'waiting_confirmation'
                    : 'failed';
    await records.operationState(operationId, status,
        stage: complete ? 'done' : 'local');
    final messages = await records.db.query('chat_messages',
        where: "operation_id=? AND role='assistant'", whereArgs: [operationId]);
    if (messages.isNotEmpty && actions.isNotEmpty) {
      final refs = <Json>[];
      for (final action in actions
          .where((a) => ['committed', 'undone'].contains(a['status']))) {
        if (action['result_json'] != null) {
          final receipt = jsonMap(action['result_json'] as String);
          if (receipt['refs'] is List) {
            refs.addAll((receipt['refs'] as List).cast<Json>());
          }
        }
      }
      await records.assistant(
          operationId,
          complete
              ? '事项已全部处理，记录以卡片中的当前值为准。'
              : '已完成 ${actions.where((a) => [
                    'committed',
                    'undone'
                  ].contains(a['status'])).length} 项，其余事项见下方。',
          status,
          refs: refs);
    }
  }

  Future<void> confirmAction(String id) async {
    final action = await records.row('operation_actions', id);
    require(action != null && action['status'] == 'waiting_confirmation',
        '这项确认已经失效');
    await records.db.update('operation_actions', {'status': 'ready'},
        where: 'id=?', whereArgs: [id]);
    try {
      await commit(id);
    } catch (error) {
      await fail(id, error);
      rethrow;
    }
    await settle(action!['operation_id'] as String);
  }

  Future<List<String>> propose(String operationId, List<Json> proposals,
      {bool userRequested = false}) async {
    final created = <String>[];
    String normalized(dynamic value) => (value as String? ?? '')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
    for (final proposal in proposals) {
      validateProposal(proposal);
      final spec = proposal['package_spec'];
      final label = (proposal['source'] as Map?)?['type'] == 'label';
      final key = jsonEncode([
        proposal['type'],
        proposal['target_id'],
        normalized(proposal['content'] ?? proposal['name']),
        normalized(proposal['brand']),
        normalized(proposal['variant']),
        proposal['base_portion'] is Map
            ? proposal['base_portion']['amount']
            : null,
        proposal['base_portion'] is Map
            ? normalized(proposal['base_portion']['unit'])
            : null,
        spec is Map
            ? [
                spec['amount'],
                normalized(spec['unit']),
                spec['count'],
                normalized(spec['description'])
              ]
            : normalized(spec),
        if (label && proposal['nutrition'] is Map)
          for (final field in nutritionFields) proposal['nutrition'][field]
      ]);
      final old = await records.db
          .query('consent_proposals', where: 'dedupe_key=?', whereArgs: [key]);
      if (old.isNotEmpty) {
        if (!userRequested || old.any((p) => p['status'] == 'pending')) {
          continue;
        }
        var active = false;
        for (final previous in old.where((p) => p['status'] == 'accepted')) {
          final table = (proposal['type'] as String).endsWith('memory')
              ? 'ai_memories'
              : 'food_library';
          final rows = await records.db.query(table,
              columns: ['id'],
              where: 'consent_action_id=? AND deleted_at_ms IS NULL',
              whereArgs: [previous['id']],
              limit: 1);
          active = active || rows.isNotEmpty;
        }
        if (active) continue;
      }
      final id = newId();
      await records.db.insert('consent_proposals', {
        'id': id,
        'operation_id': operationId,
        'kind': proposal['type'],
        'dedupe_key': key,
        'target_id': proposal['target_id'],
        'expected_version': proposal['expected_version'],
        'payload_json': jsonEncode(proposal),
        'status': 'pending',
        'created_at_ms': nowMs(),
        'updated_at_ms': nowMs()
      });
      created.add(id);
    }
    records.changed();
    return created;
  }

  Future<void> resolveProposal(String id, bool accepted) async {
    final operationId = await records.db.transaction((tx) async {
      final proposal = await records.row('consent_proposals', id, executor: tx);
      require(proposal != null && proposal['status'] == 'pending', '这项建议已经处理');
      if (!accepted) {
        await tx.update('consent_proposals',
            {'status': 'rejected', 'updated_at_ms': nowMs()},
            where: 'id=?', whereArgs: [id]);
        return null;
      }
      final payload = jsonMap(proposal!['payload_json'] as String);
      final kind = proposal['kind'] as String;
      final memory = kind.endsWith('memory');
      final current = proposal['target_id'] == null
          ? null
          : await records.row(memory ? 'ai_memories' : 'food_library',
              proposal['target_id'] as String,
              executor: tx);
      final existing = await records.row('operation_actions', id, executor: tx);
      final operation = existing == null
          ? await records.createOperation(executor: tx)
          : (await records.row('operations', existing['operation_id'] as String,
              executor: tx))!;
      final action = {
        'type': memory ? 'save_memory' : 'save_library',
        ...payload,
        'id': proposal['target_id'],
        'expected_version': proposal['expected_version'],
        'kind': payload['kind'] ??
            current?['kind'] ??
            (kind == 'save_packaged_food' ? 'packaged_food' : 'common_meal')
      };
      action['type'] = memory ? 'save_memory' : 'save_library';
      if (existing == null) {
        await tx.insert('operation_actions', {
          'id': id,
          'operation_id': operation['id'],
          'action_key': 'consent',
          'type': action['type'],
          'status': 'ready',
          'payload_json': jsonEncode(action),
          'created_at_ms': nowMs(),
          'updated_at_ms': nowMs()
        });
      } else if (!['committed', 'undone'].contains(existing['status'])) {
        await tx.update('operation_actions', {'status': 'ready'},
            where: 'id=?', whereArgs: [id]);
      }
      return operation['id'] as String;
    });
    if (accepted && operationId != null) {
      try {
        await commit(id, acceptedProposalId: id);
      } catch (error) {
        await fail(id, error);
        rethrow;
      }
      await settle(operationId);
    }
    records.changed();
  }

  Future<void> _apply(_Mutation m, Json a) async {
    switch (a['type']) {
      case 'create_meal':
        require(mealNames.containsKey(a['meal_type']), '餐别不正确');
        final items = (a['items'] as List).cast<Json>();
        require(items.isNotEmpty, '一餐至少要有一种食物');
        final mealId = newId();
        await m.insert('meals', {
          ...m.origin(a['client_ref'] as String),
          'id': mealId,
          ...timeColumns(a, m.reference),
          'meal_type': a['meal_type'],
          'raw_description': a['raw_description'],
          'note': a['note']
        });
        for (final item in items) {
          await _addFood(m, mealId, item);
        }
      case 'create_weight':
        await m.insert('weight_records', {
          ...m.origin(a['client_ref'] as String),
          'id': newId(),
          ...timeColumns(a, m.reference),
          'input_value': a['input_value'],
          'input_unit': a['input_unit'],
          'grams': weightGrams(
              a['input_value'] as String, a['input_unit'] as String),
          'raw_description': a['raw_description']
        });
      case 'create_exercise':
        await m.insert('exercise_records', {
          ...m.origin(a['client_ref'] as String),
          'id': newId(),
          ...timeColumns(a, m.reference),
          ...await _exerciseValues(m, a),
          'raw_description': a['raw_description']
        });
      case 'update_exercise':
        final row = await m.check(
            'exercise_records', a['id'] as String, a['expected_version']);
        final patch = a['patch'] as Json;
        require(
            patch.isNotEmpty &&
                patch.keys.every(
                    [...exerciseFields, 'local_date', 'local_time'].contains),
            '不支持的运动修改字段');
        final merged = {
          ...row,
          'calories_basis': jsonMap(row['calories_basis_json'] as String),
          ...patch
        };
        if (patch.containsKey('local_date') && !patch.containsKey('local_time'))
          merged['local_time'] = null;
        final estimateChanged = [
          'name',
          'duration_minutes',
          'intensity',
          'local_date'
        ].any((f) => patch.containsKey(f) && patch[f] != row[f]);
        if (row['calories_source'] == 'ai' && estimateChanged) {
          require(
              patch.containsKey('calories_kcal') &&
                  patch.containsKey('calories_source') &&
                  patch.containsKey('calories_basis'),
              '运动参数已改变，请重新估算消耗或清空');
        }
        await m.update('exercise_records', row['id'] as String, {
          if (patch.containsKey('local_date') ||
              patch.containsKey('local_time'))
            ...timeColumns(merged, m.reference),
          ...await _exerciseValues(m, merged,
              verifyWeight: estimateChanged ||
                  patch.containsKey('calories_kcal') &&
                      patch['calories_kcal'] != row['calories_kcal'] ||
                  patch.containsKey('calories_source') &&
                      patch['calories_source'] != row['calories_source'] ||
                  patch.containsKey('calories_basis') &&
                      jsonEncode(patch['calories_basis']) !=
                          row['calories_basis_json'])
        });
      case 'delete_exercise':
        await m.check(
            'exercise_records', a['id'] as String, a['expected_version']);
        await m.update(
            'exercise_records', a['id'] as String, {'deleted_at_ms': nowMs()});
      case 'edit_meal':
        final meal =
            await m.check('meals', a['id'] as String, a['expected_version']);
        final mealId = meal['id'] as String;
        await m.mealUnit(mealId);
        require(mealNames.containsKey(a['meal_type']), '餐别不正确');
        final items = (a['items'] as List).cast<Json>();
        require(items.isNotEmpty, '一餐至少保留一种食物');
        final original = await m.tx.query('food_items',
            where: 'meal_id=? AND deleted_at_ms IS NULL', whereArgs: [mealId]);
        final kept = items.map((e) => e['id']).whereType<String>().toSet();
        for (final food in original) {
          if (!kept.contains(food['id'])) {
            await m.update(
                'food_items', food['id'] as String, {'deleted_at_ms': nowMs()});
          }
        }
        for (final item in items) {
          if (item['id'] == null) {
            await _addFood(m, mealId, item);
          } else {
            require(original.any((f) => f['id'] == item['id']), '食物不属于这餐');
            await _updateFood(
                m,
                {
                  'id': item['id'],
                  'expected_version': item['expected_version'],
                  'patch': {...item}
                    ..remove('id')
                    ..remove('expected_version')
                    ..remove('client_ref')
                },
                bumpMeal: false);
          }
        }
        await m.update('meals', mealId, {
          if (a['local_date'] != meal['local_date'] ||
              a['local_time'] != meal['local_time'])
            ...timeColumns(a, m.reference),
          'meal_type': a['meal_type']
        });
      case 'add_food':
        final mealId = a['meal_id'] as String;
        await m.check('meals', mealId, a['expected_meal_version']);
        await m.mealUnit(mealId);
        await _addFood(m, mealId, a['item'] as Json);
        await m.update('meals', mealId, {});
      case 'update_food':
        await _updateFood(m, a);
      case 'modify_meal_contents':
        final mealId = a['meal_id'] as String;
        await m.check('meals', mealId, a['expected_meal_version']);
        await m.mealUnit(mealId);
        for (final change in (a['changes'] as List).cast<Json>()) {
          require(
              ['add_food', 'update_food', 'delete_food']
                  .contains(change['type']),
              '不支持的餐内修改');
          if (change['type'] == 'add_food') {
            await _addFood(m, mealId, change['item'] as Json);
          } else {
            final food = await m.check('food_items', change['id'] as String,
                change['expected_version']);
            require(food['meal_id'] == mealId, '不能修改另一餐的食物');
            if (change['type'] == 'delete_food') {
              await m.update('food_items', food['id'] as String,
                  {'deleted_at_ms': nowMs()});
            } else {
              await _updateFood(m, change, bumpMeal: false);
            }
          }
        }
        await _finishMeal(m, mealId);
      case 'update_meal':
        final row =
            await m.check('meals', a['id'] as String, a['expected_version']);
        await m.mealUnit(row['id'] as String);
        final patch = a['patch'] as Json;
        require(
            patch.keys
                .every(['local_date', 'local_time', 'meal_type'].contains),
            '不支持的餐字段');
        final merged = {...row, ...patch};
        if (patch.containsKey('local_date') &&
            !patch.containsKey('local_time')) {
          merged['local_time'] = null;
        }
        require(mealNames.containsKey(merged['meal_type']), '餐别不正确');
        await m.update('meals', row['id'] as String, {
          if (patch.containsKey('local_date') ||
              patch.containsKey('local_time'))
            ...timeColumns(merged, m.reference),
          'meal_type': merged['meal_type']
        });
      case 'delete_food':
        final row = await m.check(
            'food_items', a['id'] as String, a['expected_version']);
        await m.mealUnit(row['meal_id'] as String);
        await m.update(
            'food_items', row['id'] as String, {'deleted_at_ms': nowMs()});
        await _finishMeal(m, row['meal_id'] as String);
      case 'delete_meal':
        final row =
            await m.check('meals', a['id'] as String, a['expected_version']);
        await m.mealUnit(row['id'] as String);
        final items = await m.tx.query('food_items',
            where: 'meal_id=? AND deleted_at_ms IS NULL',
            whereArgs: [row['id']]);
        for (final item in items) {
          await m.update(
              'food_items', item['id'] as String, {'deleted_at_ms': nowMs()});
        }
        await m
            .update('meals', row['id'] as String, {'deleted_at_ms': nowMs()});
      case 'update_weight':
        final row = await m.check(
            'weight_records', a['id'] as String, a['expected_version']);
        final patch = a['patch'] as Json;
        require(
            patch.keys.every([
              'input_value',
              'input_unit',
              'local_date',
              'local_time'
            ].contains),
            '不支持的体重字段');
        final merged = {...row, ...patch};
        if (patch.containsKey('local_date') &&
            !patch.containsKey('local_time')) {
          merged['local_time'] = null;
        }
        await m.update('weight_records', row['id'] as String, {
          if (patch.containsKey('local_date') ||
              patch.containsKey('local_time'))
            ...timeColumns(merged, m.reference),
          'input_value': merged['input_value'],
          'input_unit': merged['input_unit'],
          'grams': weightGrams(
              merged['input_value'] as String, merged['input_unit'] as String)
        });
      case 'delete_weight':
        await m.check(
            'weight_records', a['id'] as String, a['expected_version']);
        await m.update(
            'weight_records', a['id'] as String, {'deleted_at_ms': nowMs()});
      case 'save_library':
        await _saveLibrary(m, a);
      case 'save_memory':
        require((a['content'] as String).trim().isNotEmpty, '记忆内容不能为空');
        final values = {
          'category': a['category'] ?? 'preference',
          'content': (a['content'] as String).trim(),
          'consent_action_id': m.actionId
        };
        if (a['id'] == null) {
          await m.insert('ai_memories', {'id': newId(), ...values});
        } else {
          await m.check(
              'ai_memories', a['id'] as String, a['expected_version']);
          await m.update('ai_memories', a['id'] as String, values);
        }
      case 'delete_library':
        await m.check('food_library', a['id'] as String, a['expected_version']);
        await m.update(
            'food_library', a['id'] as String, {'deleted_at_ms': nowMs()});
      case 'delete_memory':
        await m.check('ai_memories', a['id'] as String, a['expected_version']);
        await m.update(
            'ai_memories', a['id'] as String, {'deleted_at_ms': nowMs()});
      case 'backfill':
        final row = await m.check(
            'food_items', a['food_id'] as String, a['expected_version']);
        await m.mealUnit(row['meal_id'] as String);
        final values = a['values'] as Json;
        final allowed = (a['missing_fields'] as List).cast<String>();
        require(values.keys.every(allowed.contains), '补算返回了未请求的字段');
        final changes = <String, dynamic>{};
        final normalized = await _nutrition(
            m,
            {
              'nutrition': values,
              'nutrition_basis': a['nutrition_basis'] ?? {},
              'estimation_note': a['estimation_note']
            },
            row);
        for (final field in values.keys) {
          require(row[field] == null, '这项营养已有新值，跳过补算', 'conflict');
          final n = values[field] as Json;
          validateNutrient(field, n);
          if (n['value'] != null) {
            require(['ai', 'library'].contains(n['source']), '补算来源不正确');
            changes[field] = normalized[field];
          }
        }
        if (changes.isNotEmpty || a['estimation_note'] is String) {
          await m.update('food_items', row['id'] as String, {
            ...changes,
            'nutrition_sources_json': normalized['nutrition_sources_json'],
            'nutrition_basis_json': normalized['nutrition_basis_json'],
            'estimation_note': a['estimation_note'] ?? row['estimation_note']
          });
          await m.update('meals', row['meal_id'] as String, {});
        }
      default:
        throw const AppError('不支持的记录操作');
    }
  }

  Future<Json> _nutrition(_Mutation m, Json input,
      [Json? old, bool preserveUnchanged = true]) async {
    final raw = input['nutrition'] as Json;
    require(raw.keys.every(nutritionFields.contains), '不支持的营养字段');
    if (old == null) {
      require(nutritionFields.every(raw.containsKey), '食物须给出四项营养，未知可留空');
    }
    final values = <String, dynamic>{};
    final source = old == null
        ? <String, dynamic>{}
        : jsonMap(old['nutrition_sources_json'] as String);
    final basis = old == null
        ? <String, dynamic>{}
        : jsonMap(old['nutrition_basis_json'] as String);
    final newBasis = input['nutrition_basis'] as Json? ?? {};
    for (final field in raw.keys) {
      final n = raw[field] as Json;
      validateNutrient(field, n);
      dynamic value = n['value'];
      if (old != null &&
          preserveUnchanged &&
          value == old[field] &&
          n['source'] == source[field]) {
        values[field] = old[field];
        continue;
      }
      final rawBasis = newBasis[field];
      require(rawBasis == null || rawBasis is String || rawBasis is Map,
          '营养依据须为说明文字或结构化对象');
      final b =
          rawBasis is String ? <String, dynamic>{'note': rawBasis} : rawBasis;
      if (b is Map) {
        require(b['note'] == null || b['note'] is String, '营养依据说明须为文字');
      }
      if (n['source'] == 'label' || n['source'] == 'library') {
        require(b is Map, '标签或资料来源缺少换算依据');
        if (n['source'] == 'label' && field == 'calories_kcal') {
          require(
              ['kJ', 'kcal'].contains(b['energy_unit']), '标签能量单位未知，不能作为标签热量换算');
        }
        if (n['source'] == 'library') {
          final library = await m.check(
              'food_library', b['library_id'] as String, b['library_version']);
          final saved = jsonMap(library['nutrition_json'] as String);
          final base = jsonMap(library['base_portion_json'] as String);
          require(saved[field] is num, '食品资料中该营养值未知，不能按资料换算');
          b['value_per_base'] = saved[field];
          b['base_amount'] = base['amount'];
          b['base_unit'] = base['unit'];
          if (field == 'calories_kcal') b['energy_unit'] = 'kcal';
        }
        require(
            b['base_amount'] is num &&
                b['base_amount'] > 0 &&
                b['consumed_amount'] is num &&
                b['consumed_amount'] >= 0 &&
                b['value_per_base'] is num,
            '无法按标签基准换算实际食用量');
        require(
            b['base_unit'] is String &&
                b['consumed_unit'] is String &&
                portionUnit(b['base_unit'] as String) ==
                    portionUnit(b['consumed_unit'] as String),
            '缺少可靠换算关系，不能直接换算不同单位');
        b['consumed_unit'] = b['base_unit'];
        num calculated =
            b['value_per_base'] * b['consumed_amount'] / b['base_amount'];
        if (field == 'calories_kcal' && b['energy_unit'] == 'kJ') {
          calculated /= 4.184;
        }
        value = field == 'calories_kcal' ? calculated.round() : calculated;
      }
      if (b is Map && b['lower_kcal'] != null) {
        require(
            field == 'calories_kcal' &&
                b['lower_kcal'] is num &&
                b['upper_kcal'] is num &&
                b['lower_kcal'] >= 0 &&
                b['lower_kcal'] <= value &&
                b['upper_kcal'] >= value,
            '热量区间不正确');
      }
      values[field] = value;
      source[field] = n['source'];
      basis[field] = value == null
          ? null
          : b ??
              {
                'note': n['source'] == 'user'
                    ? '用户本次填写'
                    : input['estimation_note'] ?? '按常见份量估算'
              };
    }
    return {
      ...values,
      'nutrition_sources_json': jsonEncode(source),
      'nutrition_basis_json': jsonEncode(basis)
    };
  }

  Future<Json> _exerciseValues(_Mutation m, Json input,
      {bool verifyWeight = true}) async {
    validateExercise(input);
    var calories = input['calories_kcal'];
    Json basis =
        Map<String, dynamic>.from(input['calories_basis'] as Map? ?? {});
    if (input['calories_source'] == 'ai' &&
        basis['method'] == 'range_midpoint') {
      calories =
          ((basis['lower_kcal'] as num) / 2 + (basis['upper_kcal'] as num) / 2)
              .round();
      basis = {
        ...basis,
        'duration_minutes': input['duration_minutes'],
        'intensity': input['intensity']
      };
    } else if (input['calories_source'] == 'ai' && verifyWeight) {
      final weight = await records.exerciseWeight(input['local_date'] as String,
          executor: m.tx);
      require(
          weight != null &&
              weight['id'] == basis['weight_record_id'] &&
              weight['version'] == basis['weight_version'] &&
              weight['grams'] == basis['weight_grams'],
          '参考体重已变化或不属于运动日及此前最近一次，请重新估算',
          'conflict');
      calories = ((basis['met'] as num) *
              (weight!['grams'] as int) /
              1000 *
              (input['duration_minutes'] as num) /
              60)
          .round();
      basis = {
        ...basis,
        'method': 'MET × kg × hours（含静息消耗）',
        'duration_minutes': input['duration_minutes'],
        'intensity': input['intensity'],
        'weight_local_date': weight['local_date']
      };
    }
    return {
      for (final field in [
        'name',
        'duration_minutes',
        'distance_meters',
        'intensity',
        'note'
      ])
        field: input[field],
      'calories_kcal': calories,
      'calories_source': input['calories_source'],
      'calories_basis_json': jsonEncode(input['calories_source'] == 'unknown'
          ? {}
          : basis.isEmpty
              ? {'note': '用户明确提供'}
              : basis)
    };
  }

  Future<void> _addFood(_Mutation m, String mealId, Json food) async {
    require((food['name'] as String).trim().isNotEmpty, '请填写食物名称');
    final origin = m.origin(food['client_ref'] as String)
      ..remove('source_message_id');
    await m.insert('food_items', {
      ...origin,
      'id': newId(),
      'meal_id': mealId,
      'name': (food['name'] as String).trim(),
      'portion_text': food['portion_text'],
      ...await _nutrition(m, food),
      'estimation_note': food['estimation_note'],
      'note': food['note']
    });
  }

  Future<void> _updateFood(_Mutation m, Json a, {bool bumpMeal = true}) async {
    final row =
        await m.check('food_items', a['id'] as String, a['expected_version']);
    await m.mealUnit(row['meal_id'] as String);
    final patch = a['patch'] as Json;
    require(
        patch.keys.every([
          'name',
          'portion_text',
          'nutrition',
          'nutrition_basis',
          'estimation_note',
          'note'
        ].contains),
        '不支持的食物字段');
    if (patch.containsKey('name')) {
      require((patch['name'] as String).trim().isNotEmpty, '食物名称不能为空');
    }
    final identityChanged =
        (patch.containsKey('name') && patch['name'] != row['name']) ||
            (patch.containsKey('portion_text') &&
                patch['portion_text'] != row['portion_text']);
    if (identityChanged) {
      require(
          patch['nutrition'] is Map &&
              nutritionFields.every((patch['nutrition'] as Map).containsKey),
          '更改食物或份量时须处理全部受影响营养');
    }
    final changes = {...patch}
      ..remove('nutrition')
      ..remove('nutrition_basis');
    if (patch.containsKey('nutrition')) {
      changes.addAll(await _nutrition(m, patch, row, !identityChanged));
    }
    await m.update('food_items', row['id'] as String, changes);
    if (bumpMeal) await m.update('meals', row['meal_id'] as String, {});
  }

  Future<void> _finishMeal(_Mutation m, String id) async {
    final rows = await m.tx.query('food_items',
        columns: ['id'],
        where: 'meal_id=? AND deleted_at_ms IS NULL',
        whereArgs: [id],
        limit: 1);
    await m.update('meals', id, {if (rows.isEmpty) 'deleted_at_ms': nowMs()});
  }

  Future<void> _saveLibrary(_Mutation m, Json a) async {
    require((a['name'] as String).trim().isNotEmpty, '资料名称不能为空');
    require(['common_meal', 'packaged_food'].contains(a['kind']), '资料类型不正确');
    final base = a['base_portion'] as Json;
    require(
        base['amount'] is num &&
            base['amount'] > 0 &&
            base['unit'] is String &&
            (base['unit'] as String).isNotEmpty,
        '请填写有效营养基准');
    final nutrition = a['nutrition'] as Json;
    require(
        nutritionFields.every(nutrition.containsKey) &&
            nutrition.keys.every(nutritionFields.contains) &&
            nutrition.values
                .every((n) => n == null || n is num && n.isFinite && n >= 0),
        '资料营养值不正确');
    final values = {
      'kind': a['kind'],
      'name': a['name'],
      'aliases_json': jsonEncode(a['aliases'] ?? []),
      'brand': a['brand'],
      'variant': a['variant'],
      'package_spec_json': jsonEncode(a['package_spec']),
      'base_portion_json': jsonEncode(base),
      'nutrition_json': jsonEncode(nutrition),
      'source_json': jsonEncode(a['source'] ?? {'type': 'user'}),
      'consent_action_id': m.actionId
    };
    if (a['id'] == null) {
      await m.insert('food_library', {'id': newId(), ...values});
    } else {
      await m.check('food_library', a['id'] as String, a['expected_version']);
      await m.update('food_library', a['id'] as String, values);
    }
  }

  Future<void> _undo(_Mutation m, String id) async {
    final action = await records.row('operation_actions', id, executor: m.tx);
    require(action != null, '找不到这项操作');
    if (action!['status'] == 'undone') return;
    require(
        action['status'] == 'committed' && action['undo_of_action_id'] == null,
        '这项操作不能撤销');
    final before = jsonRows(action['before_json'] as String);
    final after = jsonRows(action['after_json'] as String);
    for (final entry in after) {
      final current = await records.row(
          entry['table'] as String, entry['id'] as String,
          executor: m.tx, includeDeleted: true);
      require(
          current != null &&
              current['version'] == (entry['row'] as Json)['version'],
          '记录之后已修改，请打开当前记录后重新编辑',
          'conflict');
    }
    for (final entry in before) {
      final table = entry['table'] as String;
      final entityId = entry['id'] as String;
      final previous = entry['row'] as Json?;
      if (previous == null) {
        await m.update(table, entityId, {'deleted_at_ms': nowMs()});
      } else {
        if (previous['source_message_id'] is String &&
            await records.row(
                    'chat_messages', previous['source_message_id'] as String,
                    executor: m.tx) ==
                null) {
          previous['source_message_id'] = null;
        }
        await m.update(
            table,
            entityId,
            {...previous}
              ..remove('id')
              ..remove('version')
              ..remove('updated_at_ms'));
      }
    }
    await m.tx.update(
        'operation_actions', {'status': 'undone', 'updated_at_ms': nowMs()},
        where: 'id=?', whereArgs: [id]);
  }
}

class _Mutation {
  final RecordRepository records;
  final Transaction tx;
  final String actionId;
  final String? messageId;
  final Json reference;
  final Map<String, Json> before = {};
  _Mutation(
      this.records, this.tx, this.actionId, this.messageId, this.reference);

  Json origin(String clientRef) => {
        'origin_action_id': actionId,
        'client_ref': clientRef,
        'source_message_id': messageId
      };

  Future<Json> check(String table, String id, dynamic version) async {
    final row = await records.row(table, id, executor: tx);
    require(row != null, '目标记录已删除或不存在', 'conflict');
    require(version is int && row!['version'] == version, '记录已经更新，请查看当前内容后重试',
        'conflict');
    return row!;
  }

  Future<void> capture(String table, String id) async {
    final key = '$table/$id';
    if (!before.containsKey(key)) {
      before[key] = {
        'table': table,
        'id': id,
        'row': await records.row(table, id, executor: tx, includeDeleted: true)
      };
    }
  }

  Future<void> mealUnit(String id) async {
    final meal = await records.row('meals', id, executor: tx);
    require(meal != null, '这餐已经删除', 'conflict');
    await capture('meals', id);
    for (final food
        in await tx.query('food_items', where: 'meal_id=?', whereArgs: [id])) {
      await capture('food_items', food['id'] as String);
    }
  }

  Future<void> insert(String table, Json row) async {
    final id = row['id'] as String;
    await capture(table, id);
    await tx.insert(table, {
      ...row,
      'version': 1,
      'created_at_ms': nowMs(),
      'updated_at_ms': nowMs()
    });
  }

  Future<void> update(String table, String id, Json patch) async {
    await capture(table, id);
    final current =
        (await records.row(table, id, executor: tx, includeDeleted: true))!;
    await tx.update(
        table,
        {
          ...patch,
          'version': (current['version'] as int) + 1,
          'updated_at_ms': nowMs()
        },
        where: 'id=? AND version=?',
        whereArgs: [id, current['version']]);
  }

  Future<List<Json>> after() async =>
      Future.wait(before.values.map((e) async => {
            'table': e['table'],
            'id': e['id'],
            'row': await records.row(e['table'] as String, e['id'] as String,
                executor: tx, includeDeleted: true)
          }));
}
