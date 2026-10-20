import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/data.dart';
import '../core/image_service.dart';
import '../records/action_committer.dart';
import '../records/record_repository.dart';
import '../settings/settings_repository.dart';
import 'ai_gateway.dart';
import 'context_builder.dart';
import 'prompts.dart';

class ChatCoordinator extends ChangeNotifier {
  final RecordRepository records;
  final SettingsRepository settings;
  final ImageService images;
  final ActionCommitter committer;
  final AiGateway gateway = AiGateway();
  late final ContextBuilder contexts = ContextBuilder(records, settings);
  bool foreground = true;
  bool _pumping = false;
  bool backfilling = false;
  int dataEpoch = 0;
  String? activeOperationId;
  DateTime? visionStartedAt;
  String stageLabel = '';
  String liveReply = '';
  String liveReasoning = '';
  String _reasoningHistory = '';
  bool bodyStarted = false;
  bool _hasModelAttempt = false;
  String? _reasoningFor(String id) =>
      id == activeOperationId && _hasModelAttempt
          ? [_reasoningHistory, liveReasoning]
              .where((s) => s.isNotEmpty)
              .join('\n\n')
          : null;
  String? fallbackReason;
  String? answeringActionId;
  String? backfillNotice;
  String? queueError;
  RequestToken? _token;
  Completer<void>? _foregroundWait;
  Completer<void>? _idleWait;
  ChatCoordinator(this.records, this.settings, this.images, this.committer);

  void setAnswering(String? id) {
    answeringActionId = id;
    if (id != null && backfilling) _token?.cancel();
  }

  void dismissBackfillNotice() {
    backfillNotice = null;
    notifyListeners();
  }

  Future<T> manualSave<T>(
      {String? actionId,
      String? operationId,
      required Future<T> Function() save}) async {
    if (actionId == null && operationId == null) return save();
    final original = actionId == null
        ? null
        : await records.row('operation_actions', actionId);
    require(actionId == null || original != null, '原事项已不存在');
    final id = operationId ?? original!['operation_id'] as String;
    final active = activeOperationId;
    final token = _token;
    final running =
        active == null ? null : await records.row('operations', active);
    await records.db.transaction((tx) async {
      final op = await records.row('operations', id, executor: tx);
      require(op != null, '原消息已不存在');
      if (actionId == null) {
        final actions = await tx.query('operation_actions',
            columns: ['id'],
            where: 'operation_id=?',
            whereArgs: [id],
            limit: 1);
        require(actions.isEmpty, '原消息已有具体事项，请返回后逐项处理，避免重复记录');
      } else {
        final current =
            await records.row('operation_actions', actionId, executor: tx);
        require(
            current != null &&
                !['committed', 'undone'].contains(current['status']),
            '这项记录已经处理，请查看当前记录');
      }
      final context = jsonMap(op!['context_json'] as String);
      require(!context.containsKey('manual_action_id'), '这项记录正在手动保存');
      context['manual_action_id'] = actionId ?? 'input';
      await tx.update(
          'operations',
          {
            'context_json': jsonEncode(context),
            'request_generation': (op['request_generation'] as int) + 1,
            'status': actionId == null ? 'failed' : 'ready',
            'updated_at_ms': nowMs()
          },
          where: 'id=?',
          whereArgs: [id]);
    });
    if (active == id ||
        actionId != null && running?['reply_to_action_id'] == actionId) {
      token?.cancel();
      if (identical(token, _token)) {
        _foregroundWait?.complete();
        _foregroundWait = null;
      }
    }
    try {
      return await save();
    } finally {
      final op = await records.row('operations', id);
      if (op != null) {
        final context = jsonMap(op['context_json'] as String)
          ..remove('manual_action_id');
        await records.db.update(
            'operations', {'context_json': jsonEncode(context)},
            where: 'id=?', whereArgs: [id]);
      }
    }
  }

  Future<void> send(String text, List<String> attachments, Json context,
      Json? quote, String? replyTo,
      {bool preserveDraft = false}) async {
    require(text.trim().isNotEmpty || attachments.isNotEmpty, '先写点内容或选一张图片');
    require(attachments.length <= 3, '一条消息最多 3 张图');
    if (backfilling) _token?.cancel();
    final snapshot =
        quote == null ? null : RecordRepository.quoteSnapshot(quote);
    final quotedContext = snapshot?['context'] as Json?;
    await records.enqueue(
        text.trim(),
        attachments,
        {
          ...context,
          if (context['local_date'] == null &&
              quotedContext?['local_date'] != null)
            'local_date': quotedContext!['local_date'],
          if (context['local_date'] == null &&
              context['label'] == null &&
              quotedContext?['local_date'] != null)
            'label': '引用 ${quotedContext!['local_date']} 的聊天',
          if (quote != null) 'quoted_message_id': quote['id'],
          if (snapshot != null) 'quote_snapshot': snapshot,
        },
        quote,
        replyTo,
        clearDraft: !preserveDraft);
    unawaited(pump());
  }

  void lifecycle(bool resumed) {
    foreground = resumed;
    if (!resumed && backfilling) _token?.cancel();
    if (resumed) {
      _foregroundWait?.complete();
      _foregroundWait = null;
      unawaited(pump());
    }
    notifyListeners();
  }

  Future<void> replaceImages(
      String id, List<String> attachmentIds, int epoch) async {
    require(epoch == dataEpoch, '数据已替换，请重新打开这条消息');
    require(
        attachmentIds.isNotEmpty && attachmentIds.length <= 3, '请选取 1–3 张图片');
    await records.db.transaction((tx) async {
      final op = await records.row('operations', id, executor: tx);
      require(
          op != null &&
              ['failed', 'interrupted'].contains(op['status']) &&
              op['vision_summary_json'] == null,
          '这条消息不能重新识图，请查看当前处理结果');
      require(
          !jsonMap(op!['context_json'] as String)
              .containsKey('manual_action_id'),
          '该输入正在手动保存');
      final actions = await tx.query('operation_actions',
          columns: ['id'], where: 'operation_id=?', whereArgs: [id], limit: 1);
      require(actions.isEmpty, '已有事项不能整条重跑');
      final messages = await tx.query('chat_messages',
          where: "operation_id=? AND role='user'", whereArgs: [id]);
      require(messages.isNotEmpty, '原消息已删除');
      final messageId = messages.single['id'];
      await tx.update('chat_attachments', {'state': 'delete_pending'},
          where: 'message_id=?', whereArgs: [messageId]);
      for (final attachmentId in attachmentIds) {
        final count = await tx.update(
            'chat_attachments', {'message_id': messageId},
            where: "id=? AND message_id IS NULL AND state='pending'",
            whereArgs: [attachmentId]);
        require(count == 1, '新图片已失效，请重新选择');
      }
      await tx.update('chat_messages',
          {'image_count': attachmentIds.length, 'delivery_status': 'pending'},
          where: 'id=?', whereArgs: [messageId]);
      await tx.update(
          'operations',
          {
            'status': 'pending',
            'stage': 'vision',
            'error_code': null,
            'request_generation': (op['request_generation'] as int) + 1,
            'updated_at_ms': nowMs()
          },
          where: 'id=?',
          whereArgs: [id]);
    });
    var notice = '图片已更新，等待识别。';
    try {
      await images.cleanup();
    } on FileSystemException {
      notice = '图片已更新。旧临时副本尚未清理，重开应用会继续清理。';
    }
    await records.assistant(id, notice, 'pending');
    unawaited(pump());
  }

  Future<void> _awaitForeground(RequestToken token) async {
    if (foreground) {
      token.check();
      return;
    }
    stageLabel = '回到前台后继续';
    notifyListeners();
    _foregroundWait ??= Completer<void>();
    await _foregroundWait!.future;
    token.check();
  }

  Future<void> stop() async {
    _token?.cancel();
    _foregroundWait?.complete();
    _foregroundWait = null;
    final id = activeOperationId;
    if (id == null) return;
    final reasoning = _reasoningFor(id);
    final operation = await records.row('operations', id);
    if (operation == null) return;
    final targetId = operation['reply_to_action_id'] as String?;
    Json? target;
    if (targetId != null) {
      await records.db.update('operation_actions',
          {'status': 'cancelled', 'updated_at_ms': nowMs()},
          where: "id=? AND status NOT IN ('committed','undone')",
          whereArgs: [targetId]);
      target = await records.row('operation_actions', targetId);
      if (target != null) {
        await committer.settle(target['operation_id'] as String);
        await _receipt(target['operation_id'] as String, '已停止当前事项，已保存的项目保留。',
            stopped: true);
      }
    }
    await records.db.update('operations',
        {'request_generation': (operation['request_generation'] as int) + 1},
        where: 'id=?', whereArgs: [id]);
    await records.db.update(
        'operation_actions', {'status': 'cancelled', 'updated_at_ms': nowMs()},
        where: "operation_id=? AND status NOT IN ('committed','undone')",
        whereArgs: [id]);
    await committer.settle(id);
    final actions = await records.actions(id);
    await records.operationState(
        id,
        actions.isNotEmpty &&
                actions
                    .every((a) => ['committed', 'undone'].contains(a['status']))
            ? 'completed'
            : actions.any((a) => ['committed', 'undone'].contains(a['status']))
                ? 'partial'
                : 'cancelled');
    await _receipt(id, '已停止。已保存的项目保留，可逐项撤销。', stopped: true);
    if (reasoning != null) await records.saveReasoning(id, reasoning);
    if (target?['result_json'] != null &&
        ['committed', 'undone'].contains(target!['status'])) {
      final result = jsonMap(target['result_json'] as String);
      await records.operationState(id, 'completed', stage: 'done');
      await records.assistant(id, '操作已经提交，记录已保留；需要时可以撤销。', 'completed',
          refs: (result['refs'] as List).cast<Json>());
    }
  }

  Future<void> cancelPending(String id) async {
    await records.db.transaction((tx) async {
      final count = await tx.update(
          'operations', {'status': 'cancelled', 'updated_at_ms': nowMs()},
          where: "id=? AND status IN ('pending','interrupted','ready')",
          whereArgs: [id]);
      require(count == 1, '这条消息已经开始处理');
      await tx.update('operation_actions',
          {'status': 'cancelled', 'updated_at_ms': nowMs()},
          where: "operation_id=? AND status NOT IN ('committed','undone')",
          whereArgs: [id]);
    });
    final actions = await records.actions(id);
    await records.operationState(
        id,
        actions.any((a) => ['committed', 'undone'].contains(a['status']))
            ? 'partial'
            : 'cancelled');
    await _receipt(id, '已取消这条消息，已保存的项目保留。', stopped: true);
  }

  Future<void> retry(String id) async {
    final op = await records.row('operations', id);
    require(
        op != null &&
            ['failed', 'interrupted', 'ready', 'partial']
                .contains(op['status']),
        '这条消息不能重复处理');
    require(id != activeOperationId, '这条消息正在处理');
    final actions = await records.actions(id);
    require(
        !actions.any((a) => a['status'] == 'conflict'), '记录已修改，请通过聊天重新提出具体变更');
    require(
        actions.isEmpty ||
            actions.any((a) => ['failed', 'ready'].contains(a['status'])),
        '没有可重试的事项，请回答问题或确认变更');
    final count = await records.db.update(
        'operations', {'status': 'pending', 'updated_at_ms': nowMs()},
        where: "id=? AND status IN ('failed','interrupted','ready','partial')",
        whereArgs: [id]);
    require(count == 1, '这条消息已经开始处理');
    records.changed();
    unawaited(pump());
  }

  Future<void> pump() async {
    if (_pumping || !foreground) return;
    _pumping = true;
    queueError = null;
    var canBackfill = false;
    try {
      while (foreground) {
        final queue = await records.pendingOperations();
        if (queue.isEmpty) {
          if (canBackfill) {
            canBackfill = false;
            await _backfill();
            continue;
          }
          break;
        }
        canBackfill = await _run(queue.first) || canBackfill;
      }
    } catch (_) {
      queueError = '本地处理未完成。请检查存储空间，重新打开应用后继续；已提交记录不会重复保存。';
    } finally {
      _pumping = false;
      activeOperationId = null;
      _token = null;
      stageLabel = '';
      liveReply = '';
      notifyListeners();
      _idleWait?.complete();
      _idleWait = null;
    }
  }

  Future<bool> _run(Json operation) async {
    final id = operation['id'] as String;
    final epoch = dataEpoch;
    activeOperationId = id;
    liveReply = '';
    liveReasoning = '';
    _reasoningHistory = '';
    bodyStarted = false;
    _hasModelAttempt = false;
    final token = RequestToken();
    _token = token;
    var rootId = id;
    try {
      final claimed = await records.db.update(
          'operations', {'status': 'running', 'updated_at_ms': nowMs()},
          where: "id=? AND status='pending'", whereArgs: [id]);
      if (claimed != 1) return false;
      token.check();
      require(epoch == dataEpoch, '数据已替换', 'cancelled');
      records.changed();
      final input = await records.inputFor(id);
      var text = input['body_text'] as String;
      Json modelOperation = operation;
      final targetAction = operation['reply_to_action_id'] as String?;
      List<Json> retryScope = [];
      if (targetAction != null) {
        final target = await records.row('operation_actions', targetAction);
        require(target != null && target['status'] == 'waiting_input',
            '原问题已处理或失效，请重新说明要记录什么');
        rootId = target!['operation_id'] as String;
        modelOperation = (await records.row('operations', rootId))!;
        final original = await records.inputFor(rootId);
        retryScope = [target];
        text =
            '原输入：${original['body_text']}\n原待处理事项：${target['payload_json']}\n本次回答：$text';
      }
      final existing = await records.actions(rootId);
      if (targetAction == null && existing.isNotEmpty) {
        final unfinished = existing
            .where((a) => ['ready', 'failed'].contains(a['status']))
            .toList();
        if (unfinished.isNotEmpty &&
            unfinished.every((a) => a['payload_json'] != null)) {
          for (final action in unfinished) {
            token.check();
            require(epoch == dataEpoch, '数据已替换', 'cancelled');
            await records.db.update('operation_actions', {'status': 'ready'},
                where: 'id=?', whereArgs: [action['id']]);
            try {
              await committer.commit(action['id'] as String);
            } catch (error) {
              token.check();
              await committer.fail(action['id'] as String, error);
            }
          }
          await committer.settle(rootId);
          await _receipt(rootId, '已按当前计划重新处理。');
          return false;
        }
        retryScope = existing
            .where((a) => ['ready', 'failed'].contains(a['status']))
            .toList();
        if (retryScope.isEmpty) {
          await committer.settle(rootId);
          await _receipt(rootId, '仍有事项等待补充或确认。');
          return false;
        }
      }
      final profile = await settings.get('ai_profile') as Json?;
      require(profile != null, '请先在“我的 → AI 接口”配置服务，也可以手动记录', 'configuration');
      final key = await settings.keyFor(profile!['base_url'] as String);
      final savedSummary = operation['vision_summary_json'] ??
          modelOperation['vision_summary_json'];
      Json? summary =
          savedSummary == null ? null : jsonMap(savedSummary as String);
      if ((input['image_count'] as int) > 0 &&
          operation['vision_summary_json'] == null) {
        final content = await images.contentFor(input['id'] as String);
        require(content.length == input['image_count'], '图片副本不可用，请重新选择',
            'image_missing');
        final previous = summary;
        summary = await _phase(
            id,
            profile,
            key,
            true,
            visionPrompt,
            [
              {
                'role': 'user',
                'content': [
                  {
                    'type': 'input_text',
                    'text': text.isEmpty ? '请结合这些图片理解本条消息。' : text
                  },
                  ...content
                ]
              }
            ],
            token, (r) {
          require(
              ['recognized', 'clarify', 'non_food'].contains(r['outcome']) &&
                  r['summary'] is String &&
                  (r['summary'] as String).trim().isNotEmpty &&
                  r['foods'] is List &&
                  r['labels'] is List &&
                  r['questions'] is List,
              '图片未能识别成有效摘要',
              'model');
          for (final label in r['labels'] as List) {
            require(label is Map, '标签摘要格式不正确', 'model');
            for (final field in [
              'product_name',
              'brand',
              'variant',
              'base_unit',
              'energy_unit',
              'reason'
            ]) {
              require(label[field] == null || label[field] is String,
                  '标签文字格式不正确', 'model');
            }
            for (final field in [
              'base_amount',
              'energy_value',
              ...nutritionFields.skip(1)
            ]) {
              require(
                  label.containsKey(field) &&
                      (label[field] == null ||
                          label[field] is num &&
                              (label[field] as num).isFinite &&
                              label[field] >= 0),
                  '标签数值格式不正确',
                  'model');
            }
            require(
                label['energy_unit'] == null ||
                    ['kJ', 'kcal'].contains(label['energy_unit']),
                '标签能量单位不正确',
                'model');
          }
        });
        if (targetAction != null && previous != null) {
          summary['previous_summary'] = previous;
        }
        token.check();
        require(epoch == dataEpoch, '数据已替换', 'cancelled');
        await images.saveSummary(id, input['id'] as String, summary);
      }
      if (rootId != id) {
        final context = jsonMap(modelOperation['context_json'] as String);
        final answers = (context['clarification_answers'] as List? ?? [])
            .map((a) => Map<String, dynamic>.from(a as Map))
            .toList();
        if (!answers.any((a) => a['message_id'] == input['id'])) {
          answers.add({
            'message_id': input['id'],
            'action_id': targetAction,
            'text': input['body_text']
          });
        }
        context['clarification_answers'] = answers;
        await records.db.update(
            'operations',
            {
              'context_json': jsonEncode(context),
              if (summary != null) 'vision_summary_json': jsonEncode(summary),
              'updated_at_ms': nowMs()
            },
            where: 'id=?',
            whereArgs: [rootId]);
        modelOperation = {
          ...modelOperation,
          'context_json': jsonEncode(context)
        };
      }
      var context = await contexts.build(modelOperation, text, vision: summary);
      if (retryScope.isNotEmpty) {
        context = await contexts.retryContext(context, retryScope, existing);
      }
      var payload = {
        'user_text': text,
        'vision_summary': summary,
        'context': context
      };
      var response = await _phase(
          id,
          profile,
          key,
          false,
          textPrompt,
          [
            {
              'role': 'user',
              'content': [
                {'type': 'input_text', 'text': jsonEncode(payload)}
              ]
            }
          ],
          token,
          contexts.validateEnvelope);
      if (response['outcome'] == 'lookup') {
        stageLabel = '查询已保存记录';
        notifyListeners();
        final results = <Json>[];
        for (final q in (response['queries'] as List).cast<Json>()) {
          results.add(await records.lookup(q));
        }
        context['lookup_results'] = results;
        context = contexts.normalize(context);
        payload = {...payload, 'context': context, 'lookup_used': true};
        response = await _phase(
            id,
            profile,
            key,
            false,
            textPrompt,
            [
              {
                'role': 'user',
                'content': [
                  {'type': 'input_text', 'text': jsonEncode(payload)}
                ]
              }
            ],
            token,
            (r) => contexts.validateEnvelope(r, lookupAllowed: false));
      }
      token.check();
      require(epoch == dataEpoch, '数据已替换', 'cancelled');
      final actions = (response['actions'] as List).cast<Json>();
      if ((input['image_count'] as int) > 0 &&
          !RegExp(r'修改|改成|更正|记错|只吃|实际|删除|撤销|刚才')
              .hasMatch(input['body_text'] as String)) {
        for (final action in actions) {
          if (action['state'] == 'ready' &&
              !['create_meal', 'create_weight'].contains(action['type'])) {
            action['state'] = 'confirm';
            action['summary'] = '这次图片输入涉及已有记录，请确认下面的变更。';
          }
        }
      }
      if (retryScope.isNotEmpty) {
        final allowed = retryScope.map((a) => a['action_key']).toSet();
        require(actions.every((a) => allowed.contains(a['action_key'])),
            '重试提案超出了未完成范围');
        for (final action in actions) {
          final original = retryScope
              .singleWhere((a) => a['action_key'] == action['action_key']);
          if (recordActionTypes.contains(original['type'])) {
            require(action['type'] == original['type'], '重试不能改变原事项的操作类型');
          }
          if (action['state'] != 'clarify') {
            final result = original['result_json'] == null
                ? <String, dynamic>{}
                : jsonMap(original['result_json'] as String);
            final previous = original['payload_json'] != null
                ? jsonMap(original['payload_json'] as String)
                : result['scope'] as Map? ?? {};
            final oldTarget =
                previous['id'] ?? previous['meal_id'] ?? previous['action_id'];
            if (oldTarget != null) {
              require(
                  (action['id'] ?? action['meal_id'] ?? action['action_id']) ==
                      oldTarget,
                  '重试不能转而修改其他对象');
            }
          }
        }
      }
      stageLabel = '保存到本地';
      liveReply = response['reply'] as String;
      notifyListeners();
      final ids = contexts.allowedIds(context);
      final conflicts = await contexts.conflictingActions(actions);
      final errors = <String, String>{};
      for (final action in actions) {
        try {
          require(
              !conflicts.contains(action['action_key']), '同一记录有互相冲突的操作，请重新说明');
          contexts.validateAction(action, ids);
          contexts.validateLabelSources(action, context, summary);
        } catch (error) {
          errors[action['action_key'] as String] =
              error is AppError ? error.message : '这项操作格式不正确，请重试未完成项';
        }
      }
      token.check();
      require(epoch == dataEpoch, '数据已替换', 'cancelled');
      await records.assistant(id, response['reply'] as String, 'running',
          modelReply: true, reasoningText: _reasoningFor(id));
      final planned = await committer.savePlan(rootId, actions, errors: errors);
      for (final action in planned) {
        if (!actions.any((a) => a['action_key'] == action['action_key'])) {
          continue;
        }
        token.check();
        require(epoch == dataEpoch, '数据已替换', 'cancelled');
        if (action['status'] == 'ready') {
          try {
            await committer.commit(action['id'] as String);
          } catch (error) {
            token.check();
            await committer.fail(action['id'] as String, error,
                needsReplan: error is! Exception ||
                    error is AppError && error.code != 'conflict');
          }
        }
      }
      final proposals = (response['proposals'] as List).cast<Json>();
      final explicitMemory = RegExp(r'^(请你?)?(帮我)?记住')
              .hasMatch((input['body_text'] as String).trim()) &&
          proposals.length == 1 &&
          ['save_memory', 'update_memory'].contains(proposals.single['type']);
      final proposalErrors = <String>{};
      for (final proposal in proposals) {
        try {
          if (proposal['target_id'] != null) {
            require(
                ids.contains(proposal['target_id']) &&
                    proposal['expected_version'] is int,
                '资料建议引用了未提供的目标');
          }
          await contexts.applyPackageLabel(proposal, summary, context: context);
          final requested = explicitMemory ||
              RegExp(r'^(请你?)?(帮我)?(保存|更新|把.+(保存|存到|记到|记成|放进|加入))')
                  .hasMatch((input['body_text'] as String).trim());
          final newProposals =
              await committer.propose(id, [proposal], userRequested: requested);
          if (explicitMemory) {
            for (final proposalId in newProposals) {
              await committer.resolveProposal(proposalId, true);
            }
          }
        } catch (error) {
          proposalErrors.add(error is AppError ? error.message : '资料建议格式不正确');
        }
      }
      await committer.settle(rootId);
      await _receipt(rootId, response['reply'] as String);
      if (proposalErrors.isNotEmpty) {
        final message = await records.db.query('chat_messages',
            where: "operation_id=? AND role='assistant'", whereArgs: [rootId]);
        final state = (await records.row('operations', rootId))!;
        final receipt = message.single['receipt_text'] as String? ?? '';
        final prefix =
            receipt == message.single['model_reply_text'] ? '' : receipt;
        await records.assistant(
            rootId,
            '${prefix.isEmpty ? '' : '$prefix\n'}长期资料建议未能保存：${proposalErrors.join('；')}。已有饮食和体重不受影响。',
            state['status'] as String);
      }
      if (rootId != id) {
        await records.operationState(id, 'completed', stage: 'done');
        final target = await records.row('operation_actions', targetAction!);
        final result = target?['result_json'] == null
            ? <String, dynamic>{}
            : jsonMap(target!['result_json'] as String);
        await records.assistant(id, '已结合你的补充处理原事项。', 'completed',
            refs: result['refs'] is List
                ? (result['refs'] as List).cast<Json>()
                : []);
      }
      final finished = (await records.row('operations', rootId))!;
      return ['completed', 'partial'].contains(finished['status']);
    } catch (error) {
      if (epoch != dataEpoch || token.cancelled) return false;
      final message = error is AppError ? error.message : '处理未完成，请重试；也可手动记录';
      if (liveReply.isNotEmpty) {
        await records.assistant(id, liveReply, 'running',
            modelReply: true, reasoningText: _reasoningFor(id));
      }
      await records.operationState(id, 'failed',
          error: error is AppError ? error.code : 'processing');
      await records.assistant(id, '$message\n本次处理未完成，未通过校验的内容没有保存。', 'failed',
          reasoningText: _reasoningFor(id));
      return false;
    } finally {
      activeOperationId = null;
      liveReply = '';
      liveReasoning = '';
      _reasoningHistory = '';
      bodyStarted = false;
      _hasModelAttempt = false;
      fallbackReason = null;
      _token = null;
      notifyListeners();
    }
  }

  Future<Json> _phase(
      String id,
      Json profile,
      String key,
      bool vision,
      String prompt,
      List<Json> input,
      RequestToken token,
      void Function(Json) validate) async {
    final role = vision ? 'vision' : 'text';
    final modelRoles = configuredModelRoles(profile, vision: vision);
    fallbackReason = null;
    String? validationError;
    try {
      for (var attempt = 0; attempt < modelRoles.length * 2; attempt++) {
        final modelRole = modelRoles[attempt ~/ 2];
        await _awaitForeground(token);
        if (vision) visionStartedAt ??= DateTime.now();
        stageLabel = '${vision ? '识别图片' : '整理回复'}'
            '${attempt >= 2 ? ' · 使用兜底模型' : ''}'
            '${attempt.isOdd ? ' · 重试 1/1' : ''}';
        liveReply = '';
        liveReasoning = '';
        bodyStarted = false;
        notifyListeners();
        final op = (await records.row('operations', id))!;
        await records.operationState(id, 'running',
            stage: role, generation: (op['request_generation'] as int) + 1);
        try {
          _hasModelAttempt = true;
          final result = await gateway.generate(
              baseUrl: profile['base_url'] as String,
              key: key,
              model: profile[modelRole] as String,
              reasoningEffort: profile['${modelRole}_effort'] as String?,
              requestReasoningSummary:
                  profile['request_reasoning_summary'] == true,
              instructions: validationError == null
                  ? prompt
                  : '$prompt\n上次输出未通过客户端协议校验：$validationError。'
                      '请重新输出完整 JSON，严格使用上述字段、层级和枚举，不省略必填字段。',
              input: input,
              stream: !vision,
              token: token,
              deadline: Duration(seconds: vision ? 120 : 90),
              onReasoning: (text) {
                if (token.cancelled) return;
                liveReasoning = text;
                notifyListeners();
              },
              onReply: (text) {
                if (token.cancelled) return;
                bodyStarted = true;
                liveReply = text;
                notifyListeners();
              });
          try {
            validate(result);
          } on AppError catch (error) {
            validationError = error.message;
            if (kDebugMode) {
              debugPrint('AI协议校验失败 [$role，尝试 ${attempt + 1}]：${error.message}');
            }
            rethrow;
          }
          if (liveReasoning.isNotEmpty) {
            _reasoningHistory = [
              _reasoningHistory,
              '$stageLabel\n$liveReasoning'
            ].where((s) => s.isNotEmpty).join('\n\n');
            liveReasoning = '';
          }
          return result;
        } catch (error) {
          token.check();
          if (attempt == modelRoles.length * 2 - 1 ||
              error is AppError && error.code == 'cancelled') rethrow;
          if (attempt == 1) {
            fallbackReason = error is AppError ? error.message : '主模型未完成有效响应';
          }
        }
      }
      throw const AppError('模型未完成回复');
    } finally {
      if (vision) {
        visionStartedAt = null;
        notifyListeners();
      }
    }
  }

  Future<void> _receipt(String id, String reply, {bool stopped = false}) async {
    final actions = await records.actions(id);
    final refs = <Json>[];
    final committed = actions
        .where((a) => ['committed', 'undone'].contains(a['status']))
        .length;
    for (final action in actions) {
      if (action['result_json'] == null) continue;
      final result = jsonMap(action['result_json'] as String);
      if (result['refs'] is List) {
        refs.addAll((result['refs'] as List).cast<Json>());
      }
    }
    final op = (await records.row('operations', id))!;
    final suffix = actions.isEmpty
        ? ''
        : '\n${committed > 0 ? '已处理 $committed 项。' : ''}'
            '${actions.any((a) => a['status'] == 'waiting_input') ? '有事项需要你补充。' : ''}'
            '${actions.any((a) => a['status'] == 'waiting_confirmation') ? '有变更等待确认。' : ''}'
            '${actions.any((a) => [
                  'failed',
                  'conflict'
                ].contains(a['status'])) ? '有事项未保存，请查看下方。' : ''}';
    await records.assistant(
        id,
        actions.isEmpty || stopped
            ? reply
            : '${committed > 0 ? '记录已更新。' : '这次还没有变更记录。'}$suffix',
        op['status'] as String,
        refs: refs,
        reasoningText: _reasoningFor(id));
  }

  Future<void> _backfill() async {
    if (!foreground || (await records.pendingOperations()).isNotEmpty) return;
    if (answeringActionId != null) return;
    final missing = await records.missingNutrition();
    if (missing.isEmpty) return;
    final profile = await settings.get('ai_profile') as Json?;
    if (profile == null) return;
    final token = RequestToken();
    final epoch = dataEpoch;
    backfillNotice = null;
    _token = token;
    backfilling = true;
    var updated = 0;
    try {
      final key = await settings.keyFor(profile['base_url'] as String);
      final modelRoles = configuredModelRoles(profile, vision: false);
      for (var start = 0; start < missing.length; start += 10) {
        token.check();
        require(foreground && (await records.pendingOperations()).isEmpty,
            '补算已让出', 'cancelled');
        final batch = <Json>[];
        for (final original in missing.skip(start).take(10)) {
          final current =
              await records.row('food_items', original['id'] as String);
          if (current == null ||
              await records.row('meals', current['meal_id'] as String) ==
                  null) {
            continue;
          }
          final fields =
              nutritionFields.where((f) => current[f] == null).toList();
          if (fields.isNotEmpty) {
            batch.add({...current, 'missing_fields': fields});
          }
        }
        if (batch.isEmpty) continue;
        Json? result;
        final library = await records.library();
        for (var attempt = 0; attempt < modelRoles.length * 2; attempt++) {
          final modelRole = modelRoles[attempt ~/ 2];
          token.check();
          require(foreground, '补算已暂停', 'cancelled');
          stageLabel = '补充缺失营养 · 已更新 $updated 项'
              '${attempt >= 2 ? ' · 使用兜底模型' : ''}'
              '${attempt.isOdd ? ' · 重试 1/1' : ''}';
          notifyListeners();
          try {
            result = await gateway.generate(
                baseUrl: profile['base_url'] as String,
                key: key,
                model: profile[modelRole] as String,
                reasoningEffort: profile['${modelRole}_effort'] as String?,
                instructions: backfillPrompt,
                input: [
                  {
                    'role': 'user',
                    'content': [
                      {
                        'type': 'input_text',
                        'text': jsonEncode({'foods': batch, 'library': library})
                      }
                    ]
                  }
                ],
                stream: false,
                token: token,
                deadline: const Duration(seconds: 90));
            require(
                result['outcome'] == 'estimates' && result['estimates'] is List,
                '补算协议不正确',
                'model');
            final values = (result['estimates'] as List).cast<Json>();
            for (final estimate in values) {
              final requested =
                  batch.where((f) => f['id'] == estimate['food_id']).toList();
              require(
                  requested.length == 1 &&
                      estimate['expected_version'] ==
                          requested.single['version'] &&
                      estimate['values'] is Map,
                  '补算对象或版本不匹配',
                  'model');
              final fields =
                  (requested.single['missing_fields'] as List).cast<String>();
              final estimates = estimate['values'] as Map;
              require(
                  estimates.length == fields.length &&
                      fields.every(estimates.containsKey),
                  '补算字段不完整',
                  'model');
              for (final entry in estimates.entries) {
                final n = entry.value;
                require(
                    n is Map &&
                        (n['value'] == null ||
                            n['value'] is num &&
                                (n['value'] as num).isFinite &&
                                n['value'] >= 0) &&
                        ['ai', 'library', 'unknown'].contains(n['source']) &&
                        (n['value'] == null) == (n['source'] == 'unknown') &&
                        (entry.key != 'calories_kcal' ||
                            n['value'] == null ||
                            n['value'] is int),
                    '补算营养值不正确',
                    'model');
                if (n['source'] == 'library') {
                  final basis = estimate['nutrition_basis'];
                  require(
                      basis is Map &&
                          basis[entry.key] is Map &&
                          library.any((l) =>
                              l['id'] == basis[entry.key]['library_id'] &&
                              l['version'] ==
                                  basis[entry.key]['library_version']),
                      '补算引用了未提供的食品资料',
                      'model');
                }
              }
            }
            require(
                values.length == batch.length &&
                    values.map((v) => v['food_id']).toSet().length ==
                        batch.length &&
                    values.every(
                        (v) => batch.any((f) => f['id'] == v['food_id'])),
                '补算没有逐项对应请求',
                'model');
            break;
          } catch (error) {
            token.check();
            if (attempt == modelRoles.length * 2 - 1 ||
                error is AppError && error.code == 'cancelled') {
              rethrow;
            }
          }
        }
        for (final estimate in (result!['estimates'] as List).cast<Json>()) {
          token.check();
          final requested =
              batch.singleWhere((f) => f['id'] == estimate['food_id']);
          try {
            await committer.local({
              ...estimate,
              'type': 'backfill',
              'missing_fields': requested['missing_fields']
            });
            if ((estimate['values'] as Json)
                .values
                .any((v) => v['value'] != null)) updated++;
          } on AppError catch (error) {
            if (error.code != 'conflict') rethrow;
          }
        }
      }
      stageLabel = '补算完成 · 更新 $updated 项食物';
    } catch (error) {
      stageLabel = token.cancelled
          ? '补算已停止 · 已更新 $updated 项'
          : '补算未完成 · 已更新 $updated 项，剩余值仍保留为空';
    } finally {
      if (epoch == dataEpoch) backfillNotice = stageLabel;
      _token = null;
      backfilling = false;
      notifyListeners();
    }
  }

  void invalidate() {
    dataEpoch++;
    backfillNotice = null;
    _token?.cancel();
    _foregroundWait?.complete();
    _foregroundWait = null;
  }

  Future<void> suspend() async {
    foreground = false;
    invalidate();
    if (_pumping) {
      _idleWait ??= Completer<void>();
      await _idleWait!.future;
    }
  }
}
