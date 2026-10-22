import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'calendar/calendar_page.dart';
import 'chat/chat_coordinator.dart';
import 'chat/chat_page.dart';
import 'core/data.dart';
import 'core/database.dart';
import 'core/image_service.dart';
import 'core/widgets.dart';
import 'data_management/backup_service.dart';
import 'library/library_page.dart';
import 'records/action_committer.dart';
import 'records/editors.dart';
import 'records/record_repository.dart';
import 'settings/settings_page.dart';
import 'settings/settings_repository.dart';

class AppServices {
  final RecordRepository records;
  late final SettingsRepository settings = SettingsRepository(records);
  late final ActionCommitter committer = ActionCommitter(records);
  late final ImageService images = ImageService(records);
  late final ChatCoordinator chat =
      ChatCoordinator(records, settings, images, committer);
  late final BackupService backup =
      BackupService(records, settings, chat, images);
  final ValueNotifier<int> tab = ValueNotifier(0);
  final ValueNotifier<String> day = ValueNotifier(today());
  final ValueNotifier<Json?> chatIntent = ValueNotifier(null);
  final navigation = JournalNavigationObserver();
  AppServices(this.records);

  static Future<AppServices> create() async {
    final database = await AppDatabase.open();
    final services = AppServices(RecordRepository(database));
    await database.normalizeInterrupted();
    services.settings.theme.value =
        await services.settings.get('theme_mode', 'system') as String;
    await services.images.initialize();
    return services;
  }

  void goChat(Json intent) {
    chatIntent.value = intent;
    tab.value = 0;
  }

  void goDay(String value) {
    day.value = value;
    tab.value = 1;
  }
}

class JournalNavigationObserver extends NavigatorObserver {
  Route<dynamic>? top;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      top = route;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      top = previousRoute;
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(top, route)) top = previousRoute;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (identical(top, oldRoute)) top = newRoute;
  }
}

class JournalHome extends StatefulWidget {
  final AppServices services;
  const JournalHome({required this.services, super.key});
  @override
  State<JournalHome> createState() => _JournalHomeState();
}

class _JournalHomeState extends State<JournalHome> with WidgetsBindingObserver {
  static const _shortcuts = MethodChannel('local.foodjournal.app/shortcuts');
  AppServices get s => widget.services;
  bool _shortcutsReady = false;
  bool _handlingShortcut = false;
  bool _shortcutRequested = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _shortcuts.setMethodCallHandler((call) async {
      if (call.method != 'shortcutAvailable') throw MissingPluginException();
      _shortcutRequested = true;
      if (_shortcutsReady) {
        unawaited(perform(context, () async {
          await _drainShortcuts();
        }));
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shortcuts.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      s.chat.lifecycle(state == AppLifecycleState.resumed);

  Future<void> _start() async {
    await _welcome();
    if (!mounted) return;
    _shortcutsReady = true;
    var handledShortcut = false;
    await perform(context, () async {
      handledShortcut = await _drainShortcuts();
    });
    if (!mounted || handledShortcut) return;
    if (s.images.recoveredChatImages) {
      s.goChat({'focus_input': true});
      return;
    }
    final draft = await s.settings.get('library_editor_draft') as Json?;
    if (!mounted || draft == null) return;
    s.tab.value = 2;
    unawaited(Navigator.push(
        context, MaterialPageRoute(builder: (_) => LibraryPage(s))));
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => LibraryEditor(s, recovered: draft)));
  }

  Future<bool> _drainShortcuts() async {
    _shortcutRequested = true;
    if (!mounted || !_shortcutsReady || _handlingShortcut) return false;
    _handlingShortcut = true;
    var handled = false;
    try {
      do {
        _shortcutRequested = false;
        final action = await _shortcuts.invokeMethod<String>('takeShortcut');
        if (!mounted) break;
        if (action != null) {
          handled = true;
          await _openShortcut(action);
          _shortcutRequested = true;
        }
      } while (_shortcutRequested && mounted);
      return handled;
    } finally {
      _handlingShortcut = false;
    }
  }

  Future<void> _openShortcut(String action) async {
    final navigator = Navigator.of(context);
    while (s.navigation.top?.isFirst == false) {
      final current = s.navigation.top;
      await navigator.maybePop();
      if (!mounted || identical(current, s.navigation.top)) return;
    }
    if (!mounted) return;
    switch (action) {
      case 'record_weight':
        final unit = await s.settings.get('weight_unit', 'jin') as String;
        if (!mounted) return;
        s.goDay(today());
        unawaited(navigator.push<void>(MaterialPageRoute(
            builder: (_) =>
                WeightEditor(s, date: today(), defaultUnit: unit))));
      case 'quick_camera':
        s.goChat({'capture_photo': true});
    }
  }

  Future<void> _welcome() async {
    if (await s.settings.get('onboarding_completed', false) == true ||
        !mounted) {
      return;
    }
    var unit = await s.settings.get('weight_unit', 'jin') as String;
    if (!mounted) return;
    Future<void> finish(BuildContext sheet) async {
      await s.settings.set('weight_unit', unit);
      await s.settings.set('privacy_notice_accepted', true);
      await s.settings.set('onboarding_completed', true);
      if (sheet.mounted) Navigator.pop(sheet);
    }

    await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        enableDrag: false,
        builder: (context) => StatefulBuilder(
            builder: (context, setModal) => SafeArea(
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Icon(Icons.auto_awesome_outlined, size: 40),
                          const SizedBox(height: 16),
                          Text('从刚刚吃的一餐开始',
                              style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 12),
                          const Text(
                              '发一句话或一张照片，我来整理饮食和运动。日历里能回看，体重也能随手记。少记一天也没关系。'),
                          const SizedBox(height: 16),
                          const Text('你习惯的体重单位'),
                          SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(value: 'jin', label: Text('斤')),
                                ButtonSegment(value: 'kg', label: Text('公斤'))
                              ],
                              selected: {
                                unit
                              },
                              onSelectionChanged: (v) => setModal(() {
                                    unit = v.single;
                                  })),
                          const SizedBox(height: 16),
                          const Text(
                              '记录保存在本机。使用 AI 时，当前任务所需的文字、图片和相关资料会发送给你配置的服务；服务商可能保留日志。压缩图片预览随聊天保留在本机，删除聊天时一并清理，不进入备份。无接口时可以手动记。'),
                          const SizedBox(height: 24),
                          FilledButton(
                              onPressed: () =>
                                  perform(context, () => finish(context)),
                              child: const Text('知道了，开始记录')),
                          TextButton(
                              onPressed: () =>
                                  perform(context, () => finish(context)),
                              child: const Text('先跳过引导')),
                        ])))));
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
      valueListenable: s.tab,
      builder: (context, index, _) => Scaffold(
          body: IndexedStack(
              index: index,
              children: [ChatPage(s), CalendarPage(s), SettingsPage(s)]),
          bottomNavigationBar: NavigationBar(
              labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
              height: 64,
              selectedIndex: index,
              onDestinationSelected: (i) => s.tab.value = i,
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.auto_awesome_outlined),
                    selectedIcon: Icon(Icons.auto_awesome),
                    label: 'AI伙伴'),
                NavigationDestination(
                    icon: Icon(Icons.calendar_month_outlined),
                    selectedIcon: Icon(Icons.calendar_month),
                    label: '我的记录'),
                NavigationDestination(
                    icon: Icon(Icons.person_outline),
                    selectedIcon: Icon(Icons.person),
                    label: '我的')
              ])));
}
