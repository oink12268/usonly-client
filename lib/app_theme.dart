import 'package:flutter/material.dart';

import 'widgets/app_input.dart';

/// 앱 전역 테마. 미니멀 흑백 톤 + [AppInput] 입력 스타일을 한곳에 모아둔다.
/// (프리뷰/테스트에서도 같은 테마를 그대로 쓸 수 있게 main.dart에서 분리했다.)

const appLightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF1A1A1A),
  onPrimary: Colors.white,
  primaryContainer: Color(0xFFE8E8E8),
  onPrimaryContainer: Color(0xFF1A1A1A),
  secondary: Color(0xFF555555),
  onSecondary: Colors.white,
  secondaryContainer: Color(0xFFEEEEEE),
  onSecondaryContainer: Color(0xFF1A1A1A),
  tertiary: Color(0xFF777777),
  onTertiary: Colors.white,
  tertiaryContainer: Color(0xFFF0F0F0),
  onTertiaryContainer: Color(0xFF1A1A1A),
  error: Color(0xFFBA1A1A),
  onError: Colors.white,
  errorContainer: Color(0xFFFFDAD6),
  onErrorContainer: Color(0xFF410002),
  surface: Color(0xFFF5F5F5),
  onSurface: Color(0xFF1A1A1A),
  surfaceContainerHighest: Color(0xFFE0E0E0),
  surfaceContainerHigh: Color(0xFFE8E8E8),
  surfaceContainer: Color(0xFFEEEEEE),
  surfaceContainerLow: Color(0xFFF2F2F2),
  surfaceContainerLowest: Colors.white,
  onSurfaceVariant: Color(0xFF666666),
  outline: Color(0xFFAAAAAA),
  outlineVariant: Color(0xFFDDDDDD),
  shadow: Colors.black,
  scrim: Colors.black,
  inverseSurface: Color(0xFF2A2A2A),
  onInverseSurface: Color(0xFFF0F0F0),
  inversePrimary: Color(0xFFCCCCCC),
);

const appDarkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFE0E0E0),
  onPrimary: Color(0xFF1A1A1A),
  primaryContainer: Color(0xFF3A3A3A),
  onPrimaryContainer: Color(0xFFE0E0E0),
  secondary: Color(0xFFBBBBBB),
  onSecondary: Color(0xFF1A1A1A),
  secondaryContainer: Color(0xFF3D3D3D),
  onSecondaryContainer: Color(0xFFE0E0E0),
  tertiary: Color(0xFF999999),
  onTertiary: Color(0xFF1A1A1A),
  tertiaryContainer: Color(0xFF454545),
  onTertiaryContainer: Color(0xFFE0E0E0),
  error: Color(0xFFFFB4AB),
  onError: Color(0xFF690005),
  errorContainer: Color(0xFF93000A),
  onErrorContainer: Color(0xFFFFDAD6),
  surface: Color(0xFF1A1A1A),
  onSurface: Color(0xFFE8E8E8),
  surfaceContainerHighest: Color(0xFF383838),
  surfaceContainerHigh: Color(0xFF2E2E2E),
  surfaceContainer: Color(0xFF272727),
  surfaceContainerLow: Color(0xFF222222),
  surfaceContainerLowest: Color(0xFF161616),
  onSurfaceVariant: Color(0xFFAAAAAA),
  outline: Color(0xFF666666),
  outlineVariant: Color(0xFF3A3A3A),
  shadow: Colors.black,
  scrim: Colors.black,
  inverseSurface: Color(0xFFE8E8E8),
  onInverseSurface: Color(0xFF1A1A1A),
  inversePrimary: Color(0xFF404040),
);

final ThemeData appLightTheme = ThemeData(
    fontFamily: 'Pretendard',
    scaffoldBackgroundColor: const Color(0xFFF5F5F5),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFFF5F5F5),
      foregroundColor: Color(0xFF1A1A1A),
      elevation: 0,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Colors.white,
      selectedItemColor: Color(0xFF1A1A1A),
      unselectedItemColor: Color(0xFFAAAAAA),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF1A1A1A),
      foregroundColor: Colors.white,
    ),
    iconTheme: const IconThemeData(opticalSize: 24, weight: 300),
    colorScheme: appLightScheme,
    inputDecorationTheme: AppInput.theme(appLightScheme),
);

final ThemeData appDarkTheme = ThemeData(
    fontFamily: 'Pretendard',
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF1A1A1A),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF1A1A1A),
      foregroundColor: Color(0xFFE8E8E8),
      elevation: 0,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Color(0xFF202020),
      selectedItemColor: Color(0xFFE8E8E8),
      unselectedItemColor: Color(0xFF555555),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFFE0E0E0),
      foregroundColor: Color(0xFF1A1A1A),
    ),
    iconTheme: const IconThemeData(opticalSize: 24, weight: 300),
    colorScheme: appDarkScheme,
    inputDecorationTheme: AppInput.theme(appDarkScheme),
);
