import 'package:flutter/material.dart';

ThemeData journalTheme(bool dark) {
  final background = Color(dark ? 0xFF211E25 : 0xFFFFF8F2);
  final surface = Color(dark ? 0xFF302A34 : 0xFFFFFFFF);
  final ink = Color(dark ? 0xFFF4EDF2 : 0xFF35313D);
  final muted = Color(dark ? 0xFFC6B8C5 : 0xFF746774);
  final scheme = ColorScheme.fromSeed(
          seedColor: const Color(0xFFF29B83),
          brightness: dark ? Brightness.dark : Brightness.light)
      .copyWith(
          primary: Color(dark ? 0xFFF4AD97 : 0xFFA84C38),
          primaryContainer: Color(dark ? 0xFF563C39 : 0xFFFCE6DF),
          onPrimaryContainer: ink,
          surface: surface,
          onSurface: ink,
          onSurfaceVariant: muted,
          background: background,
          onBackground: ink,
          outlineVariant: Color(dark ? 0xFF514550 : 0xFFF1E2DE));
  return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      textTheme: TextTheme(
          bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: ink),
          bodyMedium: TextStyle(fontSize: 16, height: 1.5, color: ink),
          bodySmall: TextStyle(fontSize: 14, height: 1.4, color: muted),
          titleLarge:
              TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: ink)),
      appBarTheme: AppBarTheme(
          backgroundColor: background,
          foregroundColor: ink,
          elevation: 0,
          centerTitle: false),
      cardTheme: CardTheme(
          color: surface,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
      inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          contentPadding: const EdgeInsets.all(16),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none)),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
              minimumSize: const Size(48, 48),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)))),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)))),
      iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(minimumSize: const Size(48, 48))),
      navigationBarTheme: NavigationBarThemeData(
          backgroundColor: surface, indicatorColor: scheme.primaryContainer));
}
