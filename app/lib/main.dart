import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app.dart';
import 'core/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const JournalBootstrap());
}

class JournalBootstrap extends StatefulWidget {
  const JournalBootstrap({super.key});
  @override
  State<JournalBootstrap> createState() => _JournalBootstrapState();
}

class _JournalBootstrapState extends State<JournalBootstrap> {
  late Future<AppServices> loading = AppServices.create();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppServices>(
        future: loading,
        builder: (context, snapshot) {
          final services = snapshot.data;
          if (services == null) {
            return MaterialApp(
                theme: journalTheme(false),
                darkTheme: journalTheme(true),
                debugShowCheckedModeBanner: false,
                home: Scaffold(
                    body: Center(
                        child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: snapshot.hasError
                                ? Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                        const Icon(Icons.info_outline,
                                            size: 40),
                                        const SizedBox(height: 16),
                                        const Text(
                                            '本地初始化未完成，已有数据已保留。请检查存储空间或重新打开应用。',
                                            textAlign: TextAlign.center),
                                        const SizedBox(height: 16),
                                        FilledButton(
                                            onPressed: () => setState(() {
                                                  loading =
                                                      AppServices.create();
                                                }),
                                            child: const Text('重新打开')),
                                      ])
                                : const CircularProgressIndicator()))));
          }
          return ValueListenableBuilder<String>(
              valueListenable: services.settings.theme,
              builder: (context, mode, _) => MaterialApp(
                  title: 'AI 减脂伙伴',
                  debugShowCheckedModeBanner: false,
                  theme: journalTheme(false),
                  darkTheme: journalTheme(true),
                  themeMode: switch (mode) {
                    'light' => ThemeMode.light,
                    'dark' => ThemeMode.dark,
                    _ => ThemeMode.system
                  },
                  locale: const Locale('zh', 'CN'),
                  supportedLocales: const [Locale('zh', 'CN')],
                  localizationsDelegates: const [
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate
                  ],
                  home: JournalHome(services: services)));
        });
  }
}
