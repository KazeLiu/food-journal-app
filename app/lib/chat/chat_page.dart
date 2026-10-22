import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/data.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../records/editors.dart';
import '../records/record_card.dart';
import 'action_preview.dart';
import 'message_images.dart';
import 'reasoning_view.dart';
import 'vision_progress.dart';

class ChatPage extends StatefulWidget {
  final AppServices s;
  const ChatPage(this.s, {super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  AppServices get s => widget.s;
  final text = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  List<Json> rows = [];
  List<Json> attachments = [];
  Json directed = {};
  Json? quote;
  String? replyTo;
  bool sending = false;
  bool loading = true;
  bool more = true;
  bool loadingOlder = false;
  bool followLatest = true;
  Json? historyBoundary;
  bool newMessages = false;
  bool draftLoaded = false;
  String? highlighted;
  Timer? draftTimer;

  @override
  void initState() {
    super.initState();
    s.records.addListener(_reload);
    s.chatIntent.addListener(_intent);
    s.chat.addListener(_streamChanged);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    s.records.removeListener(_reload);
    s.chatIntent.removeListener(_intent);
    s.chat.removeListener(_streamChanged);
    draftTimer?.cancel();
    text.dispose();
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    final draft = await s.settings.get('chat_draft') as Json?;
    if (draft != null) {
      text.text = draft['text'] as String? ?? '';
      directed = Map<String, dynamic>.from(draft['context'] as Map? ?? {});
      replyTo = draft['reply_to'] as String?;
      s.chat.setAnswering(replyTo);
      quote = draft['quote'] == null
          ? null
          : Map<String, dynamic>.from(draft['quote'] as Map);
      for (final id in draft['attachments'] as List? ?? []) {
        final attachment =
            await s.records.row('chat_attachments', id as String);
        if (attachment != null) attachments.add(attachment);
      }
    }
    draftLoaded = true;
    await _reload();
    _intent();
  }

  Future<void> _reload() async {
    if (!mounted) return;
    final epoch = s.chat.dataEpoch;
    if (highlighted != null) {
      final target = highlighted;
      final window = rows;
      final windowIds = window.map((m) => m['id']).toSet();
      final refreshed =
          await s.records.messages(through: window.last, limit: window.length);
      if (mounted && epoch == s.chat.dataEpoch && highlighted == target) {
        final updates = {for (final m in refreshed) m['id']: m};
        setState(() {
          rows = [
            for (final m in rows)
              if (!windowIds.contains(m['id']) || updates.containsKey(m['id']))
                updates[m['id']] ?? m
          ];
          if (rows.isEmpty) {
            highlighted = null;
            historyBoundary = null;
          }
          newMessages = true;
        });
      }
      return;
    }
    final latest =
        await s.records.messages(limit: rows.length < 50 ? 50 : rows.length);
    if (!mounted || epoch != s.chat.dataEpoch || highlighted != null) return;
    final gotNew = rows.isNotEmpty &&
        latest.isNotEmpty &&
        _compareMessages(latest.first, rows.last) > 0;
    setState(() {
      if (rows.isEmpty) {
        rows = latest.reversed.toList();
        more = latest.length >= 50;
        historyBoundary = rows.isEmpty ? null : rows.last;
      } else {
        final updates = {
          for (final m in rows) m['id']: m,
          for (final m in latest) m['id']: m
        };
        rows = updates.values.toList()..sort(_compareMessages);
      }
      loading = false;
      newMessages = !followLatest && gotNew || newMessages;
    });
    if (followLatest) _bottom();
  }

  int _compareMessages(Json a, Json b) {
    final time =
        (a['created_at_ms'] as int).compareTo(b['created_at_ms'] as int);
    return time != 0 ? time : (a['id'] as String).compareTo(b['id'] as String);
  }

  Future<void> _older() async {
    if (rows.isEmpty || loadingOlder || !more) return;
    followLatest = false;
    final before = rows.first;
    final epoch = s.chat.dataEpoch;
    setState(() => loadingOlder = true);
    try {
      final older = await s.records.messages(before: before);
      if (!mounted ||
          epoch != s.chat.dataEpoch ||
          rows.isEmpty ||
          rows.first['id'] != before['id']) return;
      setState(() {
        rows = [...older.reversed, ...rows];
        more = older.length == 50;
      });
    } finally {
      if (mounted) setState(() => loadingOlder = false);
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle ||
        notification is ScrollStartNotification &&
            notification.dragDetails != null) {
      followLatest = false;
    } else if (notification is ScrollEndNotification) {
      followLatest = highlighted == null &&
          notification.metrics.pixels >=
              notification.metrics.maxScrollExtent - 1;
    }
    return false;
  }

  void _top() {
    followLatest = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients) {
        scroll.jumpTo(scroll.position.minScrollExtent);
      }
    });
  }

  void _bottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients || !followLatest) return;
      if (scroll.offset != scroll.position.maxScrollExtent) {
        scroll.jumpTo(scroll.position.maxScrollExtent);
      }
      if (newMessages) {
        setState(() {
          newMessages = false;
        });
      }
    });
  }

  Future<void> _showLatest() async {
    if (!mounted) return;
    followLatest = true;
    if (highlighted != null) {
      setState(() {
        highlighted = null;
        rows = [];
        historyBoundary = null;
      });
    }
    await _reload();
    _bottom();
  }

  void _intent() {
    final intent = s.chatIntent.value;
    if (intent == null || !mounted) return;
    if (intent['reset'] == true) {
      draftTimer?.cancel();
      followLatest = true;
      setState(() {
        text.clear();
        attachments = [];
        quote = null;
        directed = {};
        replyTo = null;
        rows = [];
        historyBoundary = null;
        highlighted = null;
        newMessages = false;
      });
      s.chat.setAnswering(null);
      unawaited(_reload());
      return;
    }
    setState(() {
      directed = {...intent}..remove('text');
      replyTo = intent['reply_to_action_id'] as String?;
      if (intent['text'] is String) text.text = intent['text'] as String;
    });
    focus.requestFocus();
    s.chat.setAnswering(replyTo);
    _saveDraft();
  }

  void _streamChanged() {
    if (!mounted || !scroll.hasClients) return;
    if (followLatest && highlighted == null) _bottom();
  }

  void _saveDraft() {
    if (!draftLoaded) return;
    draftTimer?.cancel();
    draftTimer = Timer(
        const Duration(milliseconds: 350),
        () => unawaited(s.settings.set('chat_draft', {
              'text': text.text,
              'attachments': attachments.map((a) => a['id']).toList(),
              'context': directed,
              'quote': quote,
              'reply_to': replyTo
            })));
  }

  Future<void> _send([String? quick]) async {
    if (sending) return;
    setState(() {
      sending = true;
    });
    draftTimer?.cancel();
    try {
      if (quick != null) {
        _saveDraft();
        await s.chat.send(quick, [], {}, null, null, preserveDraft: true);
        await _showLatest();
        return;
      }
      final submittedText = text.text;
      final submittedIds = attachments.map((a) => a['id'] as String).toList();
      final submittedContext = directed;
      final submittedQuote = quote;
      final submittedReplyTo = replyTo;
      await s.chat.send(submittedText, submittedIds, directed, quote, replyTo);
      if (!mounted) return;
      setState(() {
        if (text.text == submittedText) text.clear();
        attachments.removeWhere((a) => submittedIds.contains(a['id']));
        if (identical(quote, submittedQuote)) quote = null;
        if (identical(directed, submittedContext)) directed = {};
        if (replyTo == submittedReplyTo) replyTo = null;
      });
      s.chat.setAnswering(replyTo);
      if (text.text.isNotEmpty ||
          attachments.isNotEmpty ||
          directed.isNotEmpty ||
          quote != null) _saveDraft();
      await _showLatest();
    } finally {
      if (mounted) {
        setState(() {
          sending = false;
        });
      }
    }
  }

  Future<void> _pick(bool camera) async {
    final picked = await s.images.pick(camera, attachments.length);
    if (!mounted) return;
    setState(() {
      attachments.addAll(picked);
    });
    _saveDraft();
  }

  Future<void> _menu(Json message) async {
    final value = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                  leading: const Icon(Icons.copy_outlined),
                  title: const Text('复制文字'),
                  onTap: () => Navigator.pop(context, 'copy')),
              ListTile(
                  leading: const Icon(Icons.reply_outlined),
                  title: const Text('引用回复'),
                  onTap: () => Navigator.pop(context, 'quote')),
              if (message['record_refs_json'] != null &&
                  jsonRows(message['record_refs_json'] as String).any((r) => [
                        'meals',
                        'weight_records',
                        'exercise_records'
                      ].contains(r['table'])))
                ListTile(
                    leading: const Icon(Icons.edit_note),
                    title: const Text('纠正关联记录'),
                    onTap: () => Navigator.pop(context, 'correct')),
              ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('删除聊天'),
                  subtitle: const Text('不会删除饮食、体重或已保存资料'),
                  onTap: () => Navigator.pop(context, 'delete')),
            ])));
    if (!mounted) return;
    switch (value) {
      case 'copy':
        await Clipboard.setData(
            ClipboardData(text: message['body_text'] as String));
      case 'quote':
        setState(() {
          quote = message;
        });
        focus.requestFocus();
        _saveDraft();
      case 'correct':
        final refs = jsonRows(message['record_refs_json'] as String)
            .where((r) => ['meals', 'weight_records', 'exercise_records']
                .contains(r['table']))
            .toList();
        final unique = <String, Json>{};
        for (final ref in refs) {
          final current =
              await s.records.row(ref['table'] as String, ref['id'] as String);
          if (current != null) {
            unique['${ref['table']}/${ref['id']}'] = {
              ...ref,
              'current': current
            };
          }
        }
        if (!mounted) return;
        Json? selected = unique.length == 1 ? unique.values.single : null;
        if (unique.length > 1) {
          selected = await showModalBottomSheet<Json>(
              context: context,
              builder: (context) => SafeArea(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Padding(
                        padding: EdgeInsets.all(16), child: Text('你要纠正哪一条？')),
                    ...unique.values.map((r) {
                      final current = r['current'] as Json;
                      return ListTile(
                          title: Text(r['table'] == 'meals'
                              ? '${mealNames[current['meal_type']]} · ${current['raw_description']}'
                              : r['table'] == 'exercise_records'
                                  ? '运动 · ${current['name']}'
                                  : '体重 · ${current['input_value']} ${current['input_unit'] == 'jin' ? '斤' : '公斤'}'),
                          subtitle: Text(current['local_date'] as String),
                          onTap: () => Navigator.pop(context, r));
                    }),
                  ])));
        }
        if (selected != null && mounted) {
          setState(() {
            directed = {
              'record_table': selected!['table'],
              'record_id': selected['id'],
              'local_date': selected['current']['local_date'],
              'label': '纠正关联记录'
            };
          });
          focus.requestFocus();
          _saveDraft();
        }
      case 'delete':
        await perform(context, () async {
          if (!await confirm(
              context, '删除这条聊天？', '这条消息的图片预览也会删除。饮食、体重、已确认资料和操作历史会保留。')) {
            return;
          }
          if (message['operation_id'] == s.chat.activeOperationId) {
            await s.chat.stop();
          } else if (message['operation_id'] != null) {
            final op = await s.records
                .row('operations', message['operation_id'] as String);
            if (op != null &&
                ['pending', 'interrupted', 'ready'].contains(op['status'])) {
              await s.chat.cancelPending(op['id'] as String);
            }
          }
          await s.records.deleteMessage(message['id'] as String);
          if (mounted) {
            setState(() {
              rows.removeWhere((r) => r['id'] == message['id']);
            });
          }
          await s.images.cleanup();
        });
    }
  }

  Future<void> _search() async {
    final message = await Navigator.push<Json>(
        context, MaterialPageRoute(builder: (_) => MessageSearch(s)));
    if (message == null || !mounted) return;
    final around = await s.records.messagesAround(message['id'] as String);
    final index = around.indexWhere((m) => m['id'] == message['id']);
    if (!mounted) return;
    setState(() {
      rows = around.skip(index).toList();
      historyBoundary = rows.last;
      highlighted = message['id'] as String;
      more = true;
    });
    _top();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
          child: Column(children: [
        AppBar(
            title: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.auto_awesome_outlined,
                  color: Theme.of(context).colorScheme.onPrimaryContainer),
              const SizedBox(width: 8),
              const Text('AI伙伴')
            ]),
            actions: [
              IconButton(
                  tooltip: '搜索聊天',
                  onPressed: _search,
                  icon: const Icon(Icons.search)),
            ]),
        Padding(
            key: const ValueKey('chat-overview'),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _overview()),
        Expanded(
            child: Stack(children: [
          Positioned.fill(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : _timeline()),
          if (newMessages)
            Positioned(
                bottom: 8,
                left: 16,
                right: 16,
                child: Center(
                    child: FilledButton.tonalIcon(
                        onPressed: _showLatest,
                        icon: const Icon(Icons.arrow_downward),
                        label: const Text('有新消息 · 查看最新')))),
        ])),
        _composer(),
      ]));

  Widget _timeline() {
    final header = <Widget>[
      if (highlighted != null)
        TextButton.icon(
            key: const ValueKey('chat-search-position'),
            onPressed: _showLatest,
            icon: const Icon(Icons.arrow_downward),
            label: const Text('正在查看搜索位置 · 回到最新')),
      if (more && rows.isNotEmpty)
        TextButton(
            key: const ValueKey('chat-older'),
            onPressed: loadingOlder ? null : () => perform(context, _older),
            child: Text(loadingOlder ? '正在加载更早聊天…' : '查看更早的聊天')),
      if (rows.isEmpty) const EmptyView('今天吃了什么？', body: '一句话、一张照片，或先手动记一笔。'),
    ];
    final earlier = <Widget>[];
    final later = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      final m = rows[i];
      final date = dateKey(
          DateTime.fromMillisecondsSinceEpoch(m['created_at_ms'] as int));
      final previous = i == 0
          ? null
          : dateKey(DateTime.fromMillisecondsSinceEpoch(
              rows[i - 1]['created_at_ms'] as int));
      final entry = _ChatHistoryItem(
          key: ValueKey('chat-message-${m['id']}'),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (date != previous)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                      child: Text(date,
                          style: Theme.of(context).textTheme.bodySmall))),
            _message(m),
          ]));
      (historyBoundary != null && _compareMessages(m, historyBoundary!) <= 0
              ? earlier
              : later)
          .add(entry);
    }
    // 固定分界点两侧分别生长，翻页和新回复都不依赖估算总高度补偿位置。
    return NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (notification) {
              if (notification.depth == 0 &&
                  followLatest &&
                  highlighted == null) _bottom();
              return false;
            },
            child: NotificationListener<DisclosureInteraction>(
                onNotification: (_) {
                  followLatest = false;
                  return false;
                },
                child: CustomScrollView(
                    controller: scroll,
                    center: const ValueKey('chat-timeline-center'),
                    anchor: historyBoundary == null ? 0 : 1,
                    slivers: [
                      if (historyBoundary != null)
                        SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            sliver: SliverList(
                                delegate: SliverChildListDelegate([
                              ...header,
                              ...earlier
                            ].reversed.toList()))),
                      SliverPadding(
                          key: const ValueKey('chat-timeline-center'),
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          sliver: SliverList(
                              delegate: SliverChildListDelegate([
                            if (historyBoundary == null) ...header,
                            ...later,
                            _processing(),
                          ]))),
                    ]))));
  }

  Widget _processing() => AnimatedBuilder(
      key: const ValueKey('chat-processing'),
      animation: s.chat,
      builder: (context, _) {
        if (s.chat.activeOperationId == null && !s.chat.backfilling) {
          if (s.chat.queueError != null) {
            return Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(s.chat.queueError!)));
          }
          if (s.chat.backfillNotice != null) {
            return Card(
                child: ListTile(
                    title: Text(s.chat.backfillNotice!),
                    trailing: IconButton(
                        tooltip: '关闭补算提示',
                        onPressed: s.chat.dismissBackfillNotice,
                        icon: const Icon(Icons.close))));
          }
          return const SizedBox.shrink();
        }
        return Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        if (s.chat.visionActive)
                          const Icon(Icons.image_search_outlined, size: 20)
                        else
                          const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 12),
                        Expanded(child: Text(s.chat.stageLabel)),
                        TextButton(
                            onPressed: () => perform(context, s.chat.stop),
                            child: const Text('停止')),
                      ]),
                      if (s.chat.visionActive)
                        Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: ImageRequestProgress(
                                uploading: s.chat.visionUploading,
                                sentBytes: s.chat.visionUploadedBytes,
                                totalBytes: s.chat.visionUploadTotal,
                                waitingStartedAt: s.chat.visionStartedAt)),
                      if (s.chat.fallbackReason != null)
                        Text('主模型：${s.chat.fallbackReason}',
                            style: Theme.of(context).textTheme.bodySmall),
                      if (s.chat.liveReasoning.isNotEmpty)
                        ReasoningView(
                            key: ValueKey(
                                'live-reasoning-${s.chat.activeOperationId}'),
                            text: s.chat.liveReasoning,
                            thinking: !s.chat.bodyStarted),
                      if (s.chat.liveReply.isNotEmpty) ...[
                        const Text('生成中 · 尚未保存',
                            style: TextStyle(fontSize: 14)),
                        const SizedBox(height: 8),
                        Text(s.chat.liveReply),
                      ],
                    ])));
      });

  Widget _overview() => AnimatedBuilder(
      animation: s.records,
      builder: (context, _) => DataView<Json>(
          future: s.records.totals(today()),
          builder: (total) => Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: IntrinsicHeight(
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                    Expanded(
                        child: Card(
                            child: InkWell(
                                borderRadius: BorderRadius.circular(20),
                                onTap: () => s.goDay(today()),
                                child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Row(children: [
                                      Expanded(
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                            Text(
                                                '今天 · ${total['meal_count']} 餐${total['other_count'] > 0 ? ' · ${total['other_count']} 次加餐' : ''}',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall),
                                            const SizedBox(height: 4),
                                            Text(calorieText(total),
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleLarge),
                                            if (total['missing_calories_kcal'] >
                                                0)
                                              Text(
                                                  '${total['missing_calories_kcal']} 项热量待估算',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall)
                                          ])),
                                      const Icon(Icons.chevron_right),
                                    ]))))),
                    const SizedBox(width: 8),
                    SizedBox(
                        width: 96,
                        child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 12)),
                            onPressed: () => perform(
                                context, () => _send('请总结今天已经记录的饮食和营养。')),
                            child: const Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.auto_awesome_outlined, size: 24),
                                  SizedBox(height: 4),
                                  Text('今日分析', textAlign: TextAlign.center)
                                ]))),
                  ])))));

  Widget _message(Json m) {
    final user = m['role'] == 'user';
    final reply = m['model_reply_text'] as String?;
    final storedReceipt = m['receipt_text'] as String?;
    final receipt =
        reply?.isNotEmpty == true && storedReceipt?.startsWith(reply!) == true
            ? storedReceipt!.substring(reply!.length).trimLeft()
            : storedReceipt;
    final reasoning = m['reasoning_text'] as String?;
    final sentContext = m['sent_context_json'] == null
        ? <String, dynamic>{}
        : jsonMap(m['sent_context_json'] as String);
    final selectedDate = sentContext['local_date'] as String?;
    final label = sentContext['label'] as String?;
    final contextLabel = selectedDate == null
        ? label
        : label == null
            ? '针对 $selectedDate'
            : label.contains(selectedDate)
                ? label
                : '$label · $selectedDate';
    final quoteSnapshot = m['quote_snapshot_json'] == null
        ? null
        : jsonMap(m['quote_snapshot_json'] as String);
    final quotedDate =
        (quoteSnapshot?['context'] as Map?)?['local_date'] as String?;
    return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
            crossAxisAlignment:
                user ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              GestureDetector(
                  onLongPress: () => _menu(m),
                  child: Container(
                      constraints: BoxConstraints(
                          maxWidth: MediaQuery.sizeOf(context).width * .88),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: highlighted == m['id']
                              ? Theme.of(context).colorScheme.tertiaryContainer
                              : user
                                  ? JournalColors.of(context).userBubble
                                  : Theme.of(context).colorScheme.surface),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (!user && reasoning?.isNotEmpty == true)
                              ReasoningView(
                                  key: ValueKey('reasoning-${m['id']}'),
                                  text: reasoning!),
                            if (user && contextLabel != null) ...[
                              InkWell(
                                  onTap: sentContext['record_id'] != null &&
                                          [
                                            'meals',
                                            'food_items',
                                            'weight_records',
                                            'exercise_records'
                                          ].contains(
                                              sentContext['record_table'])
                                      ? () => openRecord(
                                          context,
                                          s,
                                          sentContext['record_table'] as String,
                                          sentContext['record_id'] as String)
                                      : selectedDate == null
                                          ? null
                                          : () => s.goDay(selectedDate),
                                  child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.link, size: 16),
                                        const SizedBox(width: 6),
                                        Flexible(
                                            child: Text(contextLabel,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall)),
                                      ])),
                              const SizedBox(height: 8),
                            ],
                            if (m['quote_snapshot_json'] != null)
                              InkWell(
                                  onTap: () => perform(context, () async {
                                        require(m['quoted_message_id'] != null,
                                            '原消息已删除');
                                        final around = await s.records
                                            .messagesAround(
                                                m['quoted_message_id']
                                                    as String);
                                        setState(() {
                                          rows = around
                                              .skipWhile((r) =>
                                                  r['id'] !=
                                                  m['quoted_message_id'])
                                              .toList();
                                          historyBoundary = rows.last;
                                          highlighted =
                                              m['quoted_message_id'] as String;
                                        });
                                        _top();
                                      }),
                                  child: Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Text(
                                          '引用${quotedDate == null ? '' : ' $quotedDate'}：${quoteSnapshot!['body_text']}',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall))),
                            Text((m['body_text'] as String).isEmpty
                                ? '已发送 ${m['image_count']} 张图片'
                                : reply?.isNotEmpty == true
                                    ? reply!
                                    : m['body_text'] as String),
                            if (!user &&
                                reply != null &&
                                receipt != null &&
                                receipt.isNotEmpty &&
                                receipt != reply) ...[
                              const SizedBox(height: 8),
                              Text(receipt,
                                  style: Theme.of(context).textTheme.bodySmall),
                            ],
                            if (user && m['image_count'] as int > 0) ...[
                              const SizedBox(height: 8),
                              MessageImages(s.images,
                                  messageId: m['id'] as String),
                            ],
                          ]))),
              if (!user && m['record_refs_json'] != null)
                ..._cards(jsonRows(m['record_refs_json'] as String)),
              if (m['operation_id'] != null && !user)
                OperationPanel(s, operationId: m['operation_id'] as String,
                    onAnswer: (action) {
                  setState(() {
                    replyTo = action['id'] as String;
                    directed = {
                      'label': '回答原问题',
                      'reply_to_action_id': replyTo
                    };
                  });
                  s.chat.setAnswering(replyTo);
                  focus.requestFocus();
                  _saveDraft();
                }),
              if (user && m['operation_id'] != null)
                DataView<Json>(
                    future: _operation(m['operation_id'] as String),
                    builder: (op) => ['pending', 'interrupted', 'ready']
                            .contains(op['status'])
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                                Text(
                                    op['status'] == 'pending'
                                        ? '等待处理'
                                        : op['status'] == 'ready'
                                            ? '等待本地保存'
                                            : '处理已中断',
                                    style:
                                        Theme.of(context).textTheme.bodySmall),
                                if (op['status'] != 'pending')
                                  TextButton(
                                      onPressed: () => perform(
                                          context,
                                          () =>
                                              s.chat.retry(op['id'] as String)),
                                      child: const Text('继续')),
                                TextButton(
                                    onPressed: () => perform(
                                        context,
                                        () => s.chat
                                            .cancelPending(op['id'] as String)),
                                    child: const Text('取消'))
                              ])
                        : const SizedBox.shrink()),
            ]));
  }

  Future<Json> _operation(String id) async =>
      (await s.records.row('operations', id)) ?? {};

  List<Widget> _cards(List<Json> refs) {
    final seen = <String>{};
    return refs
        .where((r) =>
            ['meals', 'weight_records', 'exercise_records']
                .contains(r['table']) &&
            seen.add(r['id'] as String))
        .map((r) => Padding(
            padding: const EdgeInsets.only(top: 8),
            child: RecordCard(s,
                table: r['table'] as String,
                id: r['id'] as String,
                actionId: r['action_id'] as String?)))
        .toList();
  }

  Widget _composer() => Container(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (directed.isNotEmpty)
          ListTile(
              dense: true,
              title: Text(directed['label'] as String? ?? '操作指定记录'),
              trailing: IconButton(
                  tooltip: '退出操作上下文',
                  onPressed: () {
                    setState(() {
                      directed = {};
                      replyTo = null;
                    });
                    s.chat.setAnswering(null);
                    _saveDraft();
                  },
                  icon: const Icon(Icons.close))),
        if (quote != null)
          ListTile(
              dense: true,
              leading: const Icon(Icons.reply),
              title: Text(quote!['body_text'] as String,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                  tooltip: '取消引用',
                  onPressed: () {
                    setState(() {
                      quote = null;
                    });
                    _saveDraft();
                  },
                  icon: const Icon(Icons.close))),
        if (attachments.isNotEmpty)
          SizedBox(
              height: 96,
              child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: attachments
                      .map((a) => Padding(
                          padding: const EdgeInsets.all(4),
                          child: Stack(children: [
                            InkWell(
                                onTap: () => openImagePreview(
                                    context,
                                    s.images
                                        .fileFor(a['relative_path'] as String)),
                                child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Image.file(
                                        s.images.fileFor(
                                            a['relative_path'] as String),
                                        width: 80,
                                        height: 80,
                                        fit: BoxFit.cover))),
                            Positioned(
                                right: 0,
                                top: 0,
                                child: IconButton.filled(
                                    tooltip: '移除图片',
                                    icon: const Icon(Icons.close, size: 18),
                                    onPressed: () => perform(context, () async {
                                          await s.images
                                              .discard(a['id'] as String);
                                          setState(() {
                                            attachments.remove(a);
                                          });
                                          _saveDraft();
                                        }))),
                          ])))
                      .toList())),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          PopupMenuButton<bool>(
              tooltip: '添加图片',
              icon: const Icon(Icons.add_circle_outline),
              onSelected: (camera) => perform(context, () => _pick(camera)),
              itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: true,
                        child: ListTile(
                            leading: Icon(Icons.camera_alt_outlined),
                            title: Text('拍照'))),
                    PopupMenuItem(
                        value: false,
                        child: ListTile(
                            leading: Icon(Icons.photo_library_outlined),
                            title: Text('相册')))
                  ]),
          Expanded(
              child: TextField(
                  controller: text,
                  focusNode: focus,
                  minLines: 1,
                  maxLines: 5,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                      hintText: '说说饮食或运动……',
                      contentPadding: EdgeInsets.all(14)),
                  onChanged: (_) => _saveDraft())),
          const SizedBox(width: 12),
          IconButton.filled(
              tooltip: '发送',
              style: IconButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  disabledBackgroundColor:
                      Theme.of(context).colorScheme.onSurface.withOpacity(.12),
                  disabledForegroundColor:
                      Theme.of(context).colorScheme.onSurface.withOpacity(.38)),
              onPressed: sending ? null : () => perform(context, _send),
              icon: const Icon(Icons.arrow_upward)),
        ]),
      ]));
}

// 保留离屏卡片状态，避免重新读取时的加载占位改变列表高度。
class _ChatHistoryItem extends StatefulWidget {
  final Widget child;
  const _ChatHistoryItem({required this.child, required super.key});
  @override
  State<_ChatHistoryItem> createState() => _ChatHistoryItemState();
}

class _ChatHistoryItemState extends State<_ChatHistoryItem>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class OperationPanel extends StatelessWidget {
  final AppServices s;
  final String operationId;
  final void Function(Json) onAnswer;
  const OperationPanel(this.s,
      {required this.operationId, required this.onAnswer, super.key});

  Future<void> _reselect(bool camera) async {
    final epoch = s.chat.dataEpoch;
    final picked = await s.images.pick(camera, 0);
    if (picked.isEmpty) return;
    final ids = picked.map((p) => p['id'] as String).toList();
    try {
      await s.chat.replaceImages(operationId, ids, epoch);
    } finally {
      for (final id in ids) {
        final row = await s.records.row('chat_attachments', id);
        if (row != null && row['message_id'] == null) {
          await s.images.discard(id);
        }
      }
    }
  }

  Future<void> _manual(BuildContext context, Json action) async {
    final payload = jsonMap(action['payload_json'] as String);
    final type = action['type'] as String;
    final input = await s.records.inputFor(action['operation_id'] as String);
    if (type == 'create_meal') {
      if (context.mounted) {
        await openMealEditor(context, s,
            actionId: action['id'] as String,
            originalText: input['body_text'] as String);
      }
    } else if (type == 'create_exercise') {
      if (context.mounted) {
        await openExerciseEditor(context, s,
            actionId: action['id'] as String,
            date: payload['local_date'] as String?,
            originalText: input['body_text'] as String);
      }
    } else if (['update_exercise', 'delete_exercise'].contains(type)) {
      final current =
          await s.records.row('exercise_records', payload['id'] as String);
      require(current != null, '这次运动已删除，请重新说明');
      if (!context.mounted) return;
      if (type == 'delete_exercise') {
        if (await confirm(context, '删除这次运动？',
            '${current!['local_date']} · ${current['name']}')) {
          await s.chat.manualSave(
              actionId: action['id'] as String,
              save: () => s.committer.local({
                    'type': type,
                    'id': current['id'],
                    'expected_version': current['version']
                  }, actionId: action['id'] as String));
        }
      } else {
        await openExerciseEditor(context, s,
            exercise: current, actionId: action['id'] as String);
      }
    } else if (type == 'create_weight') {
      if (context.mounted) {
        await openWeightEditor(context, s, actionId: action['id'] as String);
      }
    } else if (['update_weight', 'delete_weight'].contains(type)) {
      final current =
          await s.records.row('weight_records', payload['id'] as String);
      require(current != null, '这条体重已删除，请重新说明');
      if (!context.mounted) return;
      if (type == 'delete_weight') {
        if (await confirm(context, '删除这次体重？',
            '${current!['local_date']} · ${current['input_value']} ${current['input_unit'] == 'jin' ? '斤' : 'kg'}')) {
          await s.committer.local({
            'type': type,
            'id': current['id'],
            'expected_version': current['version']
          }, actionId: action['id'] as String);
        }
      } else {
        await openWeightEditor(context, s,
            weight: current, actionId: action['id'] as String);
      }
    } else {
      String mealId;
      Json? food;
      if (['update_food', 'delete_food'].contains(type)) {
        food = await s.records.row('food_items', payload['id'] as String);
        require(food != null, '食物已删除，请重新说明');
        mealId = food!['meal_id'] as String;
      } else {
        mealId = (payload['meal_id'] ?? payload['id']) as String;
      }
      final meal = await s.records.row('meals', mealId);
      require(meal != null, '这餐已删除，请重新说明');
      final items = await s.records.foods(mealId);
      if (!context.mounted) return;
      if (type == 'delete_food' || type == 'delete_meal') {
        if (await confirm(
            context,
            '删除这项饮食？',
            food?['name'] as String? ??
                '${meal!['local_date']}的${mealNames[meal['meal_type']]}')) {
          await s.committer.local({
            'type': type,
            'id': food?['id'] ?? meal!['id'],
            'expected_version': food?['version'] ?? meal!['version']
          }, actionId: action['id'] as String);
        }
      } else {
        await openMealEditor(context, s,
            meal: {...meal!, 'items': items}, actionId: action['id'] as String);
      }
    }
  }

  Future<Json> load() async {
    var operation = await s.records.row('operations', operationId);
    var actions = await s.records.actions(operationId);
    var retryId = operationId;
    if (operation?['status'] == 'completed' &&
        operation?['reply_to_action_id'] is String &&
        actions.isEmpty) {
      final target = await s.records
          .row('operation_actions', operation!['reply_to_action_id'] as String);
      if (target != null) {
        retryId = target['operation_id'] as String;
        actions = [target];
        operation = await s.records.row('operations', retryId);
      }
    }
    return {
      'operation': operation,
      'actions': actions,
      'retry_id': retryId,
      'proposals': await s.records.proposals(operationId: operationId)
    };
  }

  @override
  Widget build(BuildContext context) => DataView<Json>(
      future: load(),
      builder: (data) {
        final op = data['operation'] as Json?;
        if (op == null) return const SizedBox.shrink();
        final actions = (data['actions'] as List).cast<Json>();
        final failed = ['failed', 'interrupted'].contains(op['status']);
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (failed && op['vision_summary_json'] != null)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('图片已识别，可直接重试记录，不用重传图片。')),
              if (failed &&
                  op['vision_summary_json'] == null &&
                  (op['stage'] == 'vision' ||
                      op['error_code'] == 'image_missing'))
                PopupMenuButton<bool>(
                    onSelected: (camera) =>
                        perform(context, () => _reselect(camera)),
                    itemBuilder: (_) => const [
                          PopupMenuItem(value: true, child: Text('拍照')),
                          PopupMenuItem(value: false, child: Text('相册'))
                        ],
                    child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('重选图片并重试'))),
              if (failed || op['status'] == 'partial')
                Wrap(spacing: 8, children: [
                  if ((actions.isEmpty && failed ||
                          actions.any((a) =>
                              ['ready', 'failed'].contains(a['status']))) &&
                      !actions.any((a) => a['status'] == 'conflict'))
                    TextButton.icon(
                        onPressed: () => perform(context,
                            () => s.chat.retry(data['retry_id'] as String)),
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试未完成项')),
                  if (actions.isEmpty && failed)
                    TextButton(
                        onPressed: () => perform(context, () async {
                              final input =
                                  await s.records.inputFor(operationId);
                              if (!context.mounted) return;
                              final kind = await showModalBottomSheet<String>(
                                  context: context,
                                  builder: (sheet) => SafeArea(
                                          child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                            ListTile(
                                                title: const Text('手动记饮食'),
                                                onTap: () => Navigator.pop(
                                                    sheet, 'meal')),
                                            ListTile(
                                                title: const Text('记录运动'),
                                                onTap: () => Navigator.pop(
                                                    sheet, 'exercise')),
                                            ListTile(
                                                title: const Text('记录体重'),
                                                onTap: () => Navigator.pop(
                                                    sheet, 'weight')),
                                          ])));
                              if (!context.mounted) return;
                              if (kind == 'exercise') {
                                await openExerciseEditor(context, s,
                                    originalText: input['body_text'] as String,
                                    operationId: operationId);
                              } else if (kind == 'weight') {
                                await openWeightEditor(context, s,
                                    operationId: operationId);
                              } else if (kind == 'meal') {
                                await openMealEditor(context, s,
                                    originalText: input['body_text'] as String,
                                    operationId: operationId);
                              }
                            }),
                        child: const Text('手动记录')),
                ]),
              for (final a in actions.where((a) =>
                  !['committed', 'undone', 'cancelled'].contains(a['status'])))
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Card(
                        child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Builder(builder: (context) {
                              final payload = a['payload_json'] == null
                                  ? <String, dynamic>{}
                                  : jsonMap(a['payload_json'] as String);
                              final result = a['result_json'] == null
                                  ? <String, dynamic>{}
                                  : jsonMap(a['result_json'] as String);
                              return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(payload['question'] as String? ??
                                        payload['summary'] as String? ??
                                        result['error'] as String? ??
                                        '这项记录尚未完成'),
                                    if (a['status'] == 'waiting_confirmation')
                                      ActionPreview(s, payload),
                                    if (a['status'] == 'conflict' &&
                                        (payload['id'] is String ||
                                            payload['meal_id'] is String))
                                      TextButton(
                                          onPressed: () => openRecord(
                                              context,
                                              s,
                                              (a['type'] as String)
                                                      .contains('weight')
                                                  ? 'weight_records'
                                                  : (a['type'] as String)
                                                          .contains('exercise')
                                                      ? 'exercise_records'
                                                      : [
                                                          'update_food',
                                                          'delete_food'
                                                        ].contains(a['type'])
                                                          ? 'food_items'
                                                          : 'meals',
                                              (payload['id'] ??
                                                      payload['meal_id'])
                                                  as String),
                                          child: const Text('查看当前记录')),
                                    Wrap(spacing: 8, children: [
                                      if (a['status'] == 'waiting_input')
                                        TextButton(
                                            onPressed: () => onAnswer(a),
                                            child: const Text('回答这个问题')),
                                      if (a['status'] == 'waiting_input' &&
                                          payload['optional_follow_up'] == true)
                                        TextButton(
                                            onPressed: () => perform(
                                                context,
                                                () => s.chat
                                                    .dismissExerciseFollowUp(
                                                        a['id'] as String)),
                                            child: const Text('暂不补充')),
                                      if (a['status'] == 'waiting_confirmation')
                                        TextButton(
                                            onPressed: () => perform(
                                                context,
                                                () => s.committer.confirmAction(
                                                    a['id'] as String)),
                                            child: const Text('确认变更')),
                                      if (a['status'] == 'failed' &&
                                          a['payload_json'] != null &&
                                          a['type'] != 'undo_action')
                                        TextButton(
                                            onPressed: () => perform(context,
                                                () => _manual(context, a)),
                                            child: const Text('手动处理这项')),
                                    ]),
                                  ]);
                            })))),
              for (final p in (data['proposals'] as List).cast<Json>())
                ProposalCard(s, p),
            ]);
      });
}

class ProposalCard extends StatelessWidget {
  final AppServices s;
  final Json proposal;
  const ProposalCard(this.s, this.proposal, {super.key});
  String nutritionLine(Map values) => List.generate(
          4,
          (i) =>
              '${nutritionNames[i]} ${values[nutritionFields[i]] == null ? '未知' : '${numberText(values[nutritionFields[i]] as num)} ${i == 0 ? 'kcal' : 'g'}'}')
      .join(' · ');
  String baseLine(Map value) =>
      '每 ${value['amount'] ?? '未注明'} ${value['unit'] ?? ''}';
  @override
  Widget build(BuildContext context) {
    final payload = jsonMap(proposal['payload_json'] as String);
    return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          (proposal['kind'] as String).contains('memory')
                              ? '保存为长期偏好？'
                              : '保存或更新食品资料？',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Text(payload['content'] as String? ??
                          payload['name'] as String? ??
                          '查看资料'),
                      if (payload['nutrition'] is Map)
                        Text(
                            '${payload['base_portion'] is Map ? '${baseLine(payload['base_portion'] as Map)}：' : ''}${nutritionLine(payload['nutrition'] as Map)}',
                            style: Theme.of(context).textTheme.bodySmall),
                      if (proposal['target_id'] != null)
                        DataView<Json>(
                            future: s.records
                                .row(
                                    (proposal['kind'] as String)
                                            .contains('memory')
                                        ? 'ai_memories'
                                        : 'food_library',
                                    proposal['target_id'] as String)
                                .then((v) => v ?? <String, dynamic>{}),
                            builder: (old) => Text(
                                old['nutrition_json'] is String
                                    ? '原资料（${baseLine(jsonMap(old['base_portion_json'] as String))}）：${nutritionLine(jsonMap(old['nutrition_json'] as String))}'
                                    : '原内容：${old['content'] ?? '原资料已改变'}',
                                style: Theme.of(context).textTheme.bodySmall)),
                      Wrap(spacing: 12, children: [
                        TextButton(
                            onPressed: () => perform(
                                context,
                                () => s.committer.resolveProposal(
                                    proposal['id'] as String, true)),
                            child: const Text('保存')),
                        TextButton(
                            onPressed: () => perform(
                                context,
                                () => s.committer.resolveProposal(
                                    proposal['id'] as String, false)),
                            child: const Text('暂不保存'))
                      ]),
                    ]))));
  }
}

class MessageSearch extends StatefulWidget {
  final AppServices s;
  const MessageSearch(this.s, {super.key});
  @override
  State<MessageSearch> createState() => _MessageSearchState();
}

class _MessageSearchState extends State<MessageSearch> {
  final text = TextEditingController();
  List<Json> results = [];
  bool busy = false;
  bool more = false;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> search({bool next = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
    });
    try {
      final rows = text.text.trim().isEmpty
          ? <Json>[]
          : await widget.s.records.messages(
              keyword: text.text.trim(),
              before: next && results.isNotEmpty ? results.last : null);
      if (mounted) {
        setState(() {
          results = next ? [...results, ...rows] : rows;
          more = rows.length == 50;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('搜索聊天')),
      body: Column(children: [
        Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
                controller: text,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => perform(context, search),
                decoration: InputDecoration(
                    labelText: '消息关键词',
                    suffixIcon: IconButton(
                        tooltip: '搜索',
                        onPressed: busy ? null : () => perform(context, search),
                        icon: const Icon(Icons.search))))),
        if (busy) const LinearProgressIndicator(),
        Expanded(
            child: results.isEmpty
                ? const EmptyView('输入关键词查找原消息', icon: Icons.search)
                : ListView.builder(
                    itemCount: results.length + (more ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i == results.length) {
                        return TextButton(
                            onPressed: () =>
                                perform(context, () => search(next: true)),
                            child: const Text('加载更多'));
                      }
                      final m = results[i];
                      return ListTile(
                          title: Text(m['body_text'] as String,
                              maxLines: 3, overflow: TextOverflow.ellipsis),
                          subtitle: Text(dateKey(
                              DateTime.fromMillisecondsSinceEpoch(
                                  m['created_at_ms'] as int))),
                          onTap: () => Navigator.pop(context, m));
                    })),
      ]));
}
