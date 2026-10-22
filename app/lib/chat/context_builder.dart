import 'dart:convert';

import '../core/data.dart';
import '../records/record_repository.dart';
import '../settings/settings_repository.dart';

class ContextBuilder {
  final RecordRepository records;
  final SettingsRepository settings;
  ContextBuilder(this.records, this.settings);

  static String _foodName(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  static List<Json> libraryCandidates(List<Json> library, String text,
      {String? directedId}) {
    final input = _foodName(text);
    final matches = <({Json row, int rank, int order})>[];
    for (var i = 0; i < library.length; i++) {
      final row = library[i];
      final aliases =
          (jsonDecode(row['aliases_json'] as String) as List).cast<String>();
      bool mentioned(String value) =>
          value.trim().isNotEmpty && input.contains(_foodName(value));
      final rank = directedId == row['id']
          ? 0
          : mentioned(row['name'] as String)
              ? 1
              : aliases.any(mentioned)
                  ? 2
                  : row['brand'] is String && mentioned(row['brand'] as String)
                      ? 3
                      : 4;
      if (rank < 4) {
        matches.add((
          row: {
            ...row,
            'library_match': ['directed', 'name', 'alias', 'brand'][rank]
          },
          rank: rank,
          order: i
        ));
      }
    }
    matches.sort((a, b) => a.rank == b.rank
        ? a.order.compareTo(b.order)
        : a.rank.compareTo(b.rank));
    return matches.take(10).map((e) => e.row).toList();
  }

  Iterable<Json> _summaryChain(Json? summary) sync* {
    while (summary != null) {
      yield summary;
      summary = summary['previous_summary'] as Json?;
    }
  }

  Future<void> applyPackageLabel(Json proposal, Json? summary,
      {Json context = const {}}) async {
    if (proposal['type'] == 'update_library' &&
        proposal['target_id'] is String) {
      final current =
          await records.row('food_library', proposal['target_id'] as String);
      proposal['kind'] ??= current?['kind'];
    }
    if (proposal['type'] != 'save_packaged_food' &&
        proposal['kind'] != 'packaged_food') return;
    final source = proposal['source'] as Map?;
    if (source?['type'] == 'user') return;
    String? labelMessageId;
    final requestedLabel = proposal['label_message_id'];
    require(requestedLabel == null || requestedLabel is String, '标签消息引用格式不正确');
    if (requestedLabel != null || summary == null) {
      final candidates = (context['recent_image_summaries'] as List? ?? [])
          .cast<Json>()
          .where((entry) {
        if (requestedLabel != null) {
          return entry['message_id'] == requestedLabel;
        }
        final labels = (entry['summary']['labels'] as List).cast<Json>();
        return labels.any((label) =>
            label['product_name'] is String &&
                _foodName(label['product_name'] as String) ==
                    _foodName(proposal['name'] as String) ||
            label['brand'] != null &&
                label['variant'] != null &&
                proposal['brand'] == label['brand'] &&
                proposal['variant'] == label['variant']);
      }).toList();
      if (requestedLabel != null) {
        require(candidates.length == 1, '只能引用本次上下文提供的图片标签');
      }
      if (candidates.length == 1) {
        summary = candidates.single['summary'] as Json;
        labelMessageId = candidates.single['message_id'] as String;
      }
    }
    var labels = <Map>[];
    for (final level in _summaryChain(summary)) {
      labels = (level['labels'] as List? ?? [])
          .whereType<Map>()
          .where((label) =>
              (label['brand'] == null ||
                  proposal['brand'] == null ||
                  label['brand'] == proposal['brand']) &&
              (label['variant'] == null ||
                  proposal['variant'] == null ||
                  label['variant'] == proposal['variant']))
          .toList();
      if (labels.length > 1) {
        final exact = labels
            .where((label) => label['product_name'] == proposal['name'])
            .toList();
        if (exact.isNotEmpty) labels = exact;
      }
      if (labels.isNotEmpty) break;
    }
    if (labels.length != 1) {
      require(source?['type'] != 'label', '长期标签资料缺少唯一的图片依据，请引用要保存的图片消息');
      return;
    }
    final label = labels.single;
    final base = proposal['base_portion'] as Map?;
    final sameBase = base != null &&
        base['amount'] == label['base_amount'] &&
        base['unit'] is String &&
        label['base_unit'] is String &&
        portionUnit(base['unit'] as String) ==
            portionUnit(label['base_unit'] as String) &&
        label['base_amount'] is num;
    if (!sameBase) {
      require(source?['type'] != 'label', '标签资料的营养基准不一致');
      return;
    }
    final energy = ['kJ', 'kcal'].contains(label['energy_unit'])
        ? label['energy_value'] as num?
        : null;
    proposal['nutrition'] = {
      'calories_kcal': energy == null
          ? null
          : label['energy_unit'] == 'kJ'
              ? energy / 4.184
              : energy,
      for (final field in nutritionFields.skip(1)) field: label[field]
    };
    proposal['source'] = {
      'type': 'label',
      'note': labelMessageId == null ? '本次包装营养标签' : '先前图片中的包装营养标签',
      'label': label,
      if (labelMessageId != null) 'label_message_id': labelMessageId,
    };
    proposal['package_spec'] ??= label['package_spec'];
  }

  Future<Json> build(Json operation, String text, {Json? vision}) async {
    final reference = jsonMap(operation['reference_time_json'] as String);
    final directed = jsonMap(operation['context_json'] as String);
    final day =
        directed['local_date'] as String? ?? reference['local_date'] as String;
    final recent = await records.lookup({
      'type': 'find_food',
      'query_id': 'recent',
      'keyword': '',
      'limit': 20
    });
    final weights = await records.weights(limit: 10);
    final meals = await records.meals(day);
    final history = await records.db.rawQuery('''SELECT c.role,c.body_text,
        o.context_json,o.reference_time_json FROM chat_messages c
      JOIN operations o ON o.id=c.operation_id
      WHERE c.operation_id<>? AND o.status IN ('completed','partial','waiting_input','waiting_confirmation')
      ORDER BY c.created_at_ms DESC,c.id DESC LIMIT 12''', [operation['id']]);
    final datedHistory = history.reversed.map((message) {
      final sentAt = jsonMap(message['reference_time_json'] as String);
      final scope = jsonMap(message['context_json'] as String);
      return {
        'role': message['role'],
        'body_text': message['body_text'],
        'sent_date': sentAt['local_date'],
        'selected_date': scope['local_date'] ?? sentAt['local_date'],
      };
    }).toList();
    final quotedId = directed['quoted_message_id'] as String?;
    final quotedRow = quotedId == null
        ? directed['quote_snapshot'] as Json?
        : await records.row('chat_messages', quotedId) ??
            directed['quote_snapshot'] as Json?;
    final quoted = quotedRow == null
        ? null
        : (Map<String, dynamic>.from(quotedRow)..remove('reasoning_text'));
    final imageRows = await records.db.rawQuery(
        '''SELECT c.id AS message_id,o.vision_summary_json
      FROM operations o JOIN chat_messages c ON c.operation_id=o.id
      WHERE c.role='user' AND c.image_count>0 AND o.vision_summary_json IS NOT NULL AND o.id<>?
      ORDER BY CASE WHEN c.id=? THEN 0 ELSE 1 END,c.created_at_ms DESC LIMIT 3''',
        [operation['id'], quotedId]);
    final recentImages = imageRows
        .map((row) => {
              'message_id': row['message_id'],
              'summary': jsonMap(row['vision_summary_json'] as String),
            })
        .toList();
    final quotedRecords = <Json>[];
    if (quoted?['record_refs_json'] is String) {
      for (final ref in jsonRows(quoted!['record_refs_json'] as String)) {
        if (RecordRepository.entityTables.contains(ref['table'])) {
          final current =
              await records.row(ref['table'] as String, ref['id'] as String);
          if (current != null) {
            final items = ref['table'] == 'meals'
                ? await records.foods(current['id'] as String)
                : <Json>[];
            quotedRecords.add({
              ...current,
              'table': ref['table'],
              if (ref['table'] == 'meals') 'items': items.take(50).toList(),
              if (items.length > 50) 'truncated': true
            });
          }
        }
      }
    }
    final target = directed['record_id'] as String?;
    final targetTable = directed['record_table'] as String?;
    Json? current;
    if (target != null && RecordRepository.entityTables.contains(targetTable)) {
      current = await records.row(targetTable!, target);
    }
    final allLibrary = await records.library();
    final lookupText = '$text ${vision?['summary'] ?? ''}';
    final relevantLibrary = libraryCandidates(allLibrary, lookupText,
        directedId: directed['library_id'] as String?);
    final recentActions = await records.db.query('operation_actions',
        columns: ['id', 'type', 'status', 'result_json'],
        where: "status IN ('committed','undone') AND undo_of_action_id IS NULL",
        orderBy: 'created_at_ms DESC',
        limit: 10);
    final unresolved = await records.db.rawQuery(
        '''SELECT o.id,o.status,c.body_text FROM operations o JOIN chat_messages c ON c.operation_id=o.id
      WHERE c.role='user' AND o.status IN ('failed','cancelled','waiting_input','partial') ORDER BY o.created_at_ms DESC LIMIT 5''');
    var remaining = 50;
    var truncated = false;
    final selected = <Json>[];
    for (final meal in meals) {
      final items = (meal['items'] as List).cast<Json>();
      final visible = items.take(remaining).toList();
      remaining -= visible.length;
      if (visible.length < items.length) truncated = true;
      if (visible.isNotEmpty) {
        selected.add({
          ...meal,
          'items': visible,
          if (visible.length < items.length) 'truncated': true
        });
      }
    }
    return normalize({
      'reference_time': reference,
      'weight_unit': await settings.get('weight_unit', 'jin'),
      'directed_context': directed,
      'directed_current_record': current,
      'recent_messages': datedHistory,
      'recent_image_summaries': recentImages,
      'recent_foods': recent,
      'recent_weights': weights,
      'selected_day': selected,
      'selected_date': day,
      'selected_date_source':
          directed['local_date'] == null ? 'send_date' : 'user_selected',
      'selected_day_totals': {'local_date': day, ...await records.totals(day)},
      'selected_day_truncated': truncated,
      'selected_day_exercises': await records.exercises(day),
      'selected_day_exercise_totals': {
        'local_date': day,
        ...await records.exerciseTotals(day)
      },
      'exercise_reference_weight': await records.exerciseWeight(day),
      'quoted_message': quoted,
      'quoted_records': quotedRecords,
      'library': relevantLibrary,
      'confirmed_memories': await records.memories(),
      'recent_actions': recentActions,
      'unresolved_inputs': unresolved
    });
  }
      'body_profile': await settings.bodyProfile(),

  Json normalize(Json context) {
    final registry = <String, dynamic>{
      ...context['records_by_id'] as Map<String, dynamic>? ?? {}
    };
    dynamic visit(dynamic value) {
      if (value is List) return value.map(visit).toList();
      if (value is! Map) return value;
      final row = <String, dynamic>{
        for (final entry in value.entries)
          entry.key as String: visit(entry.value)
      };
      if (row['id'] is String) {
        final id = row['id'] as String;
        registry[id] = {...registry[id] as Map<String, dynamic>? ?? {}, ...row};
        return {'ref_id': id};
      }
      return row;
    }

    final body = {...context}..remove('records_by_id');
    return {...visit(body) as Json, 'records_by_id': registry};
  }

  Future<Json> retryContext(
      Json context, List<Json> pending, List<Json> all) async {
    final scopes = <Json>[];
    final targets = <Json>[];
    Future<void> target(String table, dynamic id) async {
      if (id is! String) return;
      final row = await records.row(table, id);
      if (row == null) return;
      targets.add(row);
      if (table == 'food_items') {
        final meal = await records.row('meals', row['meal_id'] as String);
        if (meal != null) targets.add(meal);
      } else if (table == 'meals') {
        targets.addAll((await records.foods(id)).take(50));
      }
    }

    for (final action in pending) {
      final result = action['result_json'] == null
          ? <String, dynamic>{}
          : jsonMap(action['result_json'] as String);
      final scope = action['payload_json'] == null
          ? Map<String, dynamic>.from(
              result['scope'] as Map? ?? {'type': action['type']})
          : actionScope(jsonMap(action['payload_json'] as String));
      final type = action['type'] as String;
      if (scope['id'] is String) {
        await target(
            type.contains('weight')
                ? 'weight_records'
                : type.contains('exercise')
                    ? 'exercise_records'
                    : ['update_food', 'delete_food'].contains(type)
                        ? 'food_items'
                        : 'meals',
            scope['id']);
      }
      await target('meals', scope['meal_id']);
      for (final candidate
          in (scope['candidates'] as List? ?? []).whereType<Map>()) {
        final table = {
          'food': 'food_items',
          'meal': 'meals',
          'weight': 'weight_records',
          'exercise': 'exercise_records'
        }[candidate['type']];
        if (table != null) await target(table, candidate['id']);
      }
      scopes.add({
        'action_id': action['id'],
        'action_key': action['action_key'],
        'type': type,
        'scope': scope
      });
    }
    final completed = <Json>[];
    for (final action in all.where(
        (a) => ['committed', 'undone', 'cancelled'].contains(a['status']))) {
      final after = action['after_json'] == null
          ? <Json>[]
          : jsonRows(action['after_json'] as String);
      completed.add({
        'completed_action_id': action['id'],
        'action_key': action['action_key'],
        'type': action['type'],
        'status': action['status'],
        'description': after
            .map((e) => e['row'] is Map
                ? (e['row'] as Map)['name'] ??
                    (e['row'] as Map)['raw_description']
                : null)
            .whereType<String>()
            .toList()
      });
    }
    return normalize({
      ...context,
      'retry_scope': scopes,
      'completed_scope': completed,
      'retry_current_records': targets
    });
  }

  void validateEnvelope(Json response, {bool lookupAllowed = true}) {
    require(
        response['protocol_version'] == 1 &&
            ['final', if (lookupAllowed) 'lookup']
                .contains(response['outcome']) &&
            response['reply'] is String &&
            response['actions'] is List &&
            response['proposals'] is List &&
            response['queries'] is List,
        '模型返回的业务协议不完整',
        'model');
    final queries = response['queries'] as List;
    require(
        queries.length <= 5 &&
            (response['outcome'] != 'lookup' ||
                queries.isNotEmpty && (response['actions'] as List).isEmpty),
        '历史查询格式不正确',
        'model');
    final actions = response['actions'] as List;
    for (var i = 0; i < actions.length; i++) {
      final action = actions[i];
      final at = '第 ${i + 1} 项操作';
      require(action is Map, '$at必须是 JSON 对象', 'model');
      require(action['action_key'] is String, '$at缺少 action_key 字符串', 'model');
      require(action['type'] is String, '$at缺少 type 字符串', 'model');
      require(['ready', 'clarify', 'confirm'].contains(action['state']),
          '$at的 state 必须是 ready、clarify 或 confirm', 'model');
    }
    require(
        actions.map((a) => a['action_key']).toSet().length == actions.length,
        '模型返回了重复操作编号',
        'model');
    require(
        (response['proposals'] as List).every((p) =>
            p is Map &&
            [
              'save_common_food',
              'save_packaged_food',
              'update_library',
              'save_memory',
              'update_memory'
            ].contains(p['type'])),
        '资料建议格式不正确',
        'model');
  }

  Set<String> allowedIds(Json context) {
    final ids = <String>{};
    void visit(dynamic value) {
      if (value is Map) {
        if (value['id'] is String) ids.add(value['id'] as String);
        for (final e in value.entries) {
          if (['meal_id', 'action_id', 'library_id', 'weight_record_id']
                  .contains(e.key) &&
              e.value is String) ids.add(e.value as String);
          visit(e.value);
        }
      } else if (value is List) {
        for (final e in value) {
          visit(e);
        }
      }
    }

    visit(context);
    return ids;
  }

  void validateAction(Json action, Set<String> ids) {
    require(recordActionTypes.contains(action['type']), '模型提出了不支持的操作');
    void check(dynamic v) {
      if (v is Map) {
        for (final e in v.entries) {
          if (['id', 'meal_id', 'action_id', 'library_id', 'weight_record_id']
                  .contains(e.key) &&
              e.value != null) require(ids.contains(e.value), '模型引用了未提供的记录');
          check(e.value);
        }
      } else if (v is List) {
        for (final e in v) {
          check(e);
        }
      }
    }

    check(action);
    if (action['state'] == 'clarify') {
      require(
          action['question'] is String &&
              (action['question'] as String).isNotEmpty,
          '追问缺少问题');
      return;
    }
    final type = action['type'] as String;
    void nutrition(dynamic value) {
      require(value is Map, '营养格式不正确');
      final values = value as Map;
      require(values.keys.every(nutritionFields.contains), '不支持的营养字段');
      for (final entry in values.entries) {
        require(entry.value is Map, '营养字段格式不正确');
        validateNutrient(
            entry.key as String, Map<String, dynamic>.from(entry.value as Map));
      }
    }

    void foodPatch(dynamic value) {
      require(value is Map, '食物变更格式不正确');
      final patch = value as Map;
      require(
          patch.keys.every([
            'name',
            'portion_text',
            'nutrition',
            'nutrition_basis',
            'estimation_note'
          ].contains),
          '不支持的食物修改字段');
      if (patch.containsKey('name')) {
        require(
            patch['name'] is String &&
                (patch['name'] as String).trim().isNotEmpty,
            '食物名称不能为空');
      }
      if (patch.containsKey('portion_text')) {
        require(
            patch['portion_text'] == null || patch['portion_text'] is String,
            '份量格式不正确');
      }
      if (patch.containsKey('nutrition')) nutrition(patch['nutrition']);
      if (patch.containsKey('nutrition_basis')) {
        require(patch['nutrition_basis'] is Map, '营养依据格式不正确');
      }
    }

    void food(dynamic raw) {
      require(raw is Map, '食物格式不正确');
      final f = raw as Map;
      require(
          f['client_ref'] is String &&
              f['name'] is String &&
              (f['name'] as String).trim().isNotEmpty &&
              (f['portion_text'] == null || f['portion_text'] is String) &&
              f['nutrition'] is Map,
          '食物资料不完整');
      final n = f['nutrition'] as Map;
      require(nutritionFields.every(n.containsKey), '食物须包含四项营养，未知可为空');
      nutrition(n);
    }

    if (['create_meal', 'create_weight', 'create_exercise'].contains(type)) {
      require(
          action['client_ref'] is String &&
              action['local_date'] is String &&
              (action['local_time'] == null ||
                  action['local_time'] is String) &&
              action['raw_description'] is String,
          '新增记录字段不完整');
      validateDate(
          action['local_date'] as String, action['local_time'] as String?);
    }
    if (type == 'create_meal') {
      require(
          mealNames.containsKey(action['meal_type']) &&
              action['items'] is List &&
              (action['items'] as List).isNotEmpty,
          '一餐至少包含一个食物');
      for (final f in action['items'] as List) {
        food(f);
      }
    } else if (type == 'create_exercise') {
      validateExercise(action);
      require(
          action['follow_up_question'] == null ||
              action['follow_up_question'] is String &&
                  (action['follow_up_question'] as String).trim().isNotEmpty,
          '运动补充问题格式不正确');
    } else if (type == 'create_weight') {
      require(action['input_value'] is String && action['input_unit'] is String,
          '体重输入格式不正确');
      weightGrams(
          action['input_value'] as String, action['input_unit'] as String);
    } else if (['add_food', 'modify_meal_contents'].contains(type)) {
      require(
          action['meal_id'] is String && action['expected_meal_version'] is int,
          '缺少当前餐 ID 或版本');
      if (type == 'add_food') {
        food(action['item']);
      } else {
        require(
            action['changes'] is List && (action['changes'] as List).isNotEmpty,
            '餐内修改不能为空');
        final targets = <String>{};
        for (final raw in action['changes'] as List) {
          require(raw is Map, '餐内修改格式不正确');
          final change = Map<String, dynamic>.from(raw as Map);
          if (change['type'] == 'add_food') {
            food(change['item']);
          } else {
            require(
                ['update_food', 'delete_food'].contains(change['type']) &&
                    change['id'] is String &&
                    change['expected_version'] is int,
                '餐内修改字段不完整');
            require(targets.add(change['id'] as String), '同一食物出现重复修改');
            if (change['type'] == 'update_food') {
              require(change['patch'] is Map, '缺少食物变更');
              foodPatch(change['patch']);
            }
          }
        }
      }
    } else if (type == 'undo_action') {
      require(action['action_id'] is String, '缺少要撤销的操作');
    } else if (!type.startsWith('create_')) {
      require(action['id'] is String && action['expected_version'] is int,
          '缺少目标记录 ID 或版本');
      if (type.startsWith('update_')) {
        require(action['patch'] is Map && (action['patch'] as Map).isNotEmpty,
            '缺少需要修改的字段');
        if (type == 'update_food') foodPatch(action['patch']);
        if (type == 'update_exercise') {
          require(
              (action['patch'] as Map).keys.every(
                  [...exerciseFields, 'local_date', 'local_time'].contains),
              '不支持的运动修改字段');
        }
      }
    }
  }

  Future<Set<String>> conflictingActions(List<Json> actions) async {
    final owners = <String, String>{};
    final conflicts = <String>{};
    for (final action in actions.where((a) => a['state'] != 'clarify')) {
      final targets = <String>{};
      final type = action['type'] as String;
      if (['update_food', 'delete_food'].contains(type) &&
          action['id'] is String) {
        final food = await records.row('food_items', action['id'] as String);
        targets.add(food?['meal_id'] as String? ?? action['id'] as String);
      } else if (action['meal_id'] is String || action['id'] is String) {
        targets.add((action['meal_id'] ?? action['id']) as String);
      } else if (type == 'undo_action' && action['action_id'] is String) {
        final original = await records.row(
            'operation_actions', action['action_id'] as String);
        if (original?['after_json'] != null) {
          for (final e in jsonRows(original!['after_json'] as String)) {
            targets.add(e['id'] as String);
          }
        }
      }
      for (final target in targets) {
        final key = action['action_key'] as String;
        if (owners.containsKey(target)) {
          conflicts.add(owners[target]!);
          conflicts.add(key);
        } else {
          owners[target] = key;
        }
      }
    }
    return conflicts;
  }

  void validateLabelSources(Json action, Json context, Json? summary) {
    final byId = context['records_by_id'] as Map? ?? {};
    final library = byId.values
        .whereType<Map>()
        .where((row) =>
            row['nutrition_json'] is String &&
            row['base_portion_json'] is String &&
            row['aliases_json'] is String)
        .toList();
    final evidence = <Json>[];
    for (final label in _summaryChain(summary)
        .expand((level) => (level['labels'] as List? ?? []).whereType<Map>())) {
      for (final field in nutritionFields) {
        evidence.add({
          'field': field,
          'base_amount': label['base_amount'],
          'base_unit': label['base_unit'],
          'value':
              field == 'calories_kcal' ? label['energy_value'] : label[field],
          'energy_unit': label['energy_unit']
        });
      }
    }
    void prior(dynamic value) {
      if (value is Map) {
        if (value['nutrition_sources_json'] is String &&
            value['nutrition_basis_json'] is String) {
          final source = jsonMap(value['nutrition_sources_json'] as String);
          final basis = jsonMap(value['nutrition_basis_json'] as String);
          for (final field in nutritionFields) {
            if (source[field] == 'label' && basis[field] is Map) {
              final b = basis[field] as Map;
              evidence.add({
                'field': field,
                'base_amount': b['base_amount'],
                'base_unit': b['base_unit'],
                'value': b['value_per_base'],
                'energy_unit': b['energy_unit']
              });
            }
          }
        }
        for (final v in value.values) {
          prior(v);
        }
      } else if (value is List) {
        for (final v in value) {
          prior(v);
        }
      }
    }

    prior(context);
    void validate(dynamic value, [String? foodName]) {
      if (value is Map) {
        final current = byId[value['id']];
        final name = value['name'] as String? ??
            (current is Map ? current['name'] as String? : null) ??
            foodName;
        if (value['nutrition'] is Map) {
          final nutrition = value['nutrition'] as Map;
          final basis = value['nutrition_basis'] as Map? ?? {};
          for (final field in nutrition.keys) {
            if (nutrition[field] is Map &&
                nutrition[field]['source'] == 'label') {
              final b = basis[field];
              final knownLabel = b is Map &&
                  evidence.any((e) =>
                      e['field'] == field &&
                      e['value'] != null &&
                      e['base_amount'] == b['base_amount'] &&
                      e['base_unit'] == b['base_unit'] &&
                      e['value'] == b['value_per_base'] &&
                      (field != 'calories_kcal' ||
                          e['energy_unit'] == b['energy_unit']));
              if (knownLabel) continue;
              // 复用库里已确认的同款标签时，保存为 library，并让提交器读取库原值换算。
              final matches = name == null
                  ? <Map>[]
                  : library.where((row) {
                      final names = [
                        row['name'] as String,
                        ...(jsonDecode(row['aliases_json'] as String) as List)
                            .cast<String>()
                      ];
                      return names.any((n) => _foodName(n) == _foodName(name));
                    }).toList();
              require(b is Map && matches.length == 1,
                  '标签数值缺少本次识别依据；复用食品资料请使用 library 来源、资料 ID 和版本');
              final saved = matches.single;
              final base = jsonMap(saved['base_portion_json'] as String);
              final nutrients = jsonMap(saved['nutrition_json'] as String);
              require(
                  nutrients[field] is num &&
                      b['consumed_amount'] is num &&
                      (b['consumed_amount'] as num).isFinite &&
                      b['consumed_amount'] >= 0 &&
                      b['consumed_unit'] is String &&
                      portionUnit(b['consumed_unit'] as String) ==
                          portionUnit(base['unit'] as String),
                  '食品资料换算缺少可靠的实际食用量，请使用资料基准的单位');
              nutrition[field]['source'] = 'library';
              b['library_id'] = saved['id'];
              b['library_version'] = saved['version'];
            }
          }
        }
        for (final v in value.values) {
          validate(v, name);
        }
      } else if (value is List) {
        for (final v in value) {
          validate(v, foodName);
        }
      }
    }

    validate(action);
  }
}
