import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

@immutable
class JournalColors extends ThemeExtension<JournalColors> {
  final Color userBubble;
  final Color success;
  final Color foodMark;
  final Color weightMark;
  final Color exerciseMark;
  const JournalColors(
      {required this.userBubble,
      required this.success,
      required this.foodMark,
      required this.weightMark,
      required this.exerciseMark});

  static JournalColors of(BuildContext context) =>
      Theme.of(context).extension<JournalColors>()!;

  @override
  JournalColors copyWith(
          {Color? userBubble,
          Color? success,
          Color? foodMark,
          Color? weightMark,
          Color? exerciseMark}) =>
      JournalColors(
          userBubble: userBubble ?? this.userBubble,
          success: success ?? this.success,
          foodMark: foodMark ?? this.foodMark,
          weightMark: weightMark ?? this.weightMark,
          exerciseMark: exerciseMark ?? this.exerciseMark);

  @override
  JournalColors lerp(covariant JournalColors? other, double t) => other == null
      ? this
      : JournalColors(
          userBubble: Color.lerp(userBubble, other.userBubble, t)!,
          success: Color.lerp(success, other.success, t)!,
          foodMark: Color.lerp(foodMark, other.foodMark, t)!,
          weightMark: Color.lerp(weightMark, other.weightMark, t)!,
          exerciseMark: Color.lerp(exerciseMark, other.exerciseMark, t)!);
}

ThemeData journalTheme(bool dark) {
  final background = Color(dark ? 0xFF191A1C : 0xFFF5F5F3);
  final surface = Color(dark ? 0xFF252629 : 0xFFFFFFFF);
  final secondarySurface = Color(dark ? 0xFF2D2E32 : 0xFFEEEEEB);
  final input = Color(dark ? 0xFF2B2C30 : 0xFFFFFFFF);
  final ink = Color(dark ? 0xFFF0EFED : 0xFF292A2C);
  final muted = Color(dark ? 0xFFB6B5B8 : 0xFF696B70);
  const coral = Color(0xFFF19A80);
  final accentInk = Color(dark ? 0xFFFFB19B : 0xFF914833);
  final bar = Color(dark ? 0xFF202124 : 0xFFFAFAF8);
  final navigation = Color(dark ? 0xFF242427 : 0xFFFAFAF8);
  final scheme = ColorScheme.fromSeed(
          seedColor: coral,
          brightness: dark ? Brightness.dark : Brightness.light)
      .copyWith(
          primary: coral,
          onPrimary: const Color(0xFF292A2C),
          primaryContainer: Color(dark ? 0xFF44312F : 0xFFF5E2DB),
          onPrimaryContainer: accentInk,
          secondary: muted,
          onSecondary: surface,
          secondaryContainer: secondarySurface,
          onSecondaryContainer: ink,
          tertiary: Color(dark ? 0xFF7FC6BA : 0xFF357F78),
          onTertiary: surface,
          tertiaryContainer: Color(dark ? 0xFF2D4852 : 0xFFDCEAF0),
          onTertiaryContainer: ink,
          surface: surface,
          onSurface: ink,
          surfaceVariant: secondarySurface,
          onSurfaceVariant: muted,
          background: background,
          onBackground: ink,
          surfaceTint: Colors.transparent,
          outline: Color(dark ? 0xFF62636B : 0xFFBCBDB7),
          outlineVariant: Color(dark ? 0xFF3A3B40 : 0xFFE6E5E1),
          error: Color(dark ? 0xFFF28A86 : 0xFFB74747),
          onError: Color(dark ? 0xFF421918 : 0xFFFFFFFF),
          errorContainer: Color(dark ? 0xFF542D2D : 0xFFF9E3E1),
          onErrorContainer: ink,
          inverseSurface: Color(dark ? 0xFFE5E5E1 : 0xFF303135),
          onInverseSurface: Color(dark ? 0xFF292A2C : 0xFFF0EFED),
          inversePrimary: Color(dark ? 0xFF914833 : 0xFFFFB19B));
  final rounded =
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
  final fieldShape = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none);
  final disabledInk = ink.withOpacity(.38);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    canvasColor: surface,
    disabledColor: disabledInk,
    hintColor: muted,
    extensions: [
      JournalColors(
          userBubble: scheme.primaryContainer,
          success: Color(dark ? 0xFF65C69A : 0xFF267B59),
          foodMark: Color(dark ? 0xFFEDAB92 : 0xFFB76549),
          weightMark: Color(dark ? 0xFFB2AFDA : 0xFF7B79A8),
          exerciseMark: scheme.tertiary)
    ],
    textTheme: TextTheme(
        bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: ink),
        bodyMedium: TextStyle(fontSize: 16, height: 1.5, color: ink),
        bodySmall: TextStyle(fontSize: 14, height: 1.4, color: muted),
        titleLarge:
            TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: ink)),
    appBarTheme: AppBarTheme(
        backgroundColor: bar,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: bar,
            statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
            statusBarBrightness: dark ? Brightness.dark : Brightness.light,
            systemNavigationBarColor: navigation,
            systemNavigationBarIconBrightness:
                dark ? Brightness.light : Brightness.dark)),
    cardTheme: CardTheme(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: input,
        hintStyle: TextStyle(color: muted),
        labelStyle: TextStyle(color: muted),
        floatingLabelStyle: TextStyle(color: accentInk),
        contentPadding: const EdgeInsets.all(16),
        border: fieldShape,
        enabledBorder: fieldShape,
        focusedBorder: fieldShape.copyWith(
            borderSide: BorderSide(color: accentInk, width: 1.5)),
        errorBorder:
            fieldShape.copyWith(borderSide: BorderSide(color: scheme.error)),
        focusedErrorBorder: fieldShape.copyWith(
            borderSide: BorderSide(color: scheme.error, width: 1.5)),
        errorStyle: TextStyle(color: scheme.error)),
    textSelectionTheme: TextSelectionThemeData(
        cursorColor: accentInk,
        selectionColor: coral.withOpacity(.3),
        selectionHandleColor: accentInk),
    filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
                disabledForegroundColor: disabledInk,
                disabledBackgroundColor: ink.withOpacity(.12),
                minimumSize: const Size(48, 48),
                shape: rounded)
            .copyWith(overlayColor: MaterialStateProperty.resolveWith((states) {
      if (states.contains(MaterialState.pressed) ||
          states.contains(MaterialState.focused)) return ink.withOpacity(.1);
      if (states.contains(MaterialState.hovered)) return ink.withOpacity(.06);
      return null;
    }))),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
            foregroundColor: ink,
            disabledForegroundColor: disabledInk,
            side: BorderSide(color: scheme.outline),
            minimumSize: const Size(48, 48),
            shape: rounded)),
    textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
            foregroundColor: accentInk,
            disabledForegroundColor: disabledInk,
            minimumSize: const Size(48, 48))),
    iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48))),
    iconTheme: IconThemeData(color: muted),
    navigationBarTheme: NavigationBarThemeData(
        backgroundColor: navigation,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        indicatorColor: secondarySurface,
        iconTheme: MaterialStateProperty.resolveWith((states) => IconThemeData(
            color:
                states.contains(MaterialState.selected) ? accentInk : muted))),
    listTileTheme: ListTileThemeData(iconColor: muted, textColor: ink),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
    dialogTheme: DialogTheme(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        modalBackgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)))),
    popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(color: ink, fontSize: 16),
        shape: rounded),
    dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
            backgroundColor: MaterialStatePropertyAll(surface),
            surfaceTintColor:
                const MaterialStatePropertyAll(Colors.transparent))),
    datePickerTheme: DatePickerThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: secondarySurface,
        headerForegroundColor: ink,
        todayForegroundColor: MaterialStateProperty.resolveWith((states) =>
            states.contains(MaterialState.selected)
                ? scheme.onPrimary
                : accentInk)),
    timePickerTheme: TimePickerThemeData(
        backgroundColor: surface,
        dialBackgroundColor: secondarySurface,
        dialHandColor: coral,
        dialTextColor: MaterialStateColor.resolveWith((states) =>
            states.contains(MaterialState.selected) ? scheme.onPrimary : ink),
        hourMinuteColor: MaterialStateColor.resolveWith((states) =>
            states.contains(MaterialState.selected)
                ? scheme.primaryContainer
                : secondarySurface),
        hourMinuteTextColor: MaterialStateColor.resolveWith((states) =>
            states.contains(MaterialState.selected) ? accentInk : ink),
        dayPeriodColor: MaterialStateColor.resolveWith((states) =>
            states.contains(MaterialState.selected)
                ? scheme.primaryContainer
                : surface),
        dayPeriodTextColor: MaterialStateColor.resolveWith(
            (states) => states.contains(MaterialState.selected) ? accentInk : ink)),
    segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
            minimumSize: const MaterialStatePropertyAll(Size(48, 48)),
            foregroundColor: MaterialStateProperty.resolveWith((states) =>
                states.contains(MaterialState.selected) ? accentInk : ink),
            backgroundColor: MaterialStateProperty.resolveWith((states) =>
                states.contains(MaterialState.selected)
                    ? scheme.primaryContainer
                    : surface))),
    progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accentInk, linearTrackColor: secondarySurface),
    snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        contentTextStyle:
            TextStyle(color: scheme.onInverseSurface, fontSize: 14),
        actionTextColor: scheme.inversePrimary),
  );
}
