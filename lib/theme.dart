import 'package:flutter/material.dart';

/// NexUI design tokens from doc/design/index.md.
abstract final class AppTheme {
  // Brand
  /// var(--primary) = oklch(0.5629 0.1817 262)
  static const Color primary = Color(0xFF356EDE);

  /// Dark-mode primary, measured across the mocks (buttons, accents, dots
  /// all render #3B82F6 in dark) — the design lightens primary for dark
  /// surfaces rather than reusing the light value.
  static const Color primaryDark = Color(0xFF3B82F6);

  // Spectrum gradient — brand accent ONLY (app icon, splash, login mark,
  // avatars, Home tracking-card glow). Never on ordinary buttons.
  static const Color spectrumMagenta = Color(0xFFB023F2);
  static const Color spectrumIndigo = Color(0xFF5B63EC);
  static const Color spectrumBlue = Color(0xFF2F96E6);

  // Status semantics
  static const Color success = Color(0xFF16A34A); // Ready / Granted
  static const Color warning = Color(0xFFD97706); // Queued / Transcribing / Battery
  static const Color recording = Color(0xFFE0245E);

  // Page and card surfaces measured from the mocks (NexUI --background /
  // --card). Without these, Material derives grey-lavender surfaces from the
  // seed and cards lose the design's white-on-near-white look.
  static const Color _pageLight = Color(0xFFFAFBFF);
  static const Color _pageDark = Color(0xFF000114);
  static const Color _cardLight = Color(0xFFFFFFFF);
  // Lifted above the mock's measured #02001F: that value is only ~11 units
  // off the page and vanishes into it on OLED, so cards get a clearly
  // elevated (still blue-tinted) surface for separation in dark mode.
  static const Color _cardDark = Color(0xFF12152E);

  // NexUI muted-foreground for section labels, measured from the home mocks
  // (indigo-cast in light, neutral gray in dark). Stand-in until the real
  // NexUI token values are available.
  static Color mutedLabel(Brightness brightness) =>
      brightness == Brightness.dark
          ? const Color(0xFF85858E)
          : const Color(0xFF6381BE);

  // Shape
  static const double cardRadius = 18;
  static const double controlRadius = 14;

  static ThemeData light() => _theme(Brightness.light);
  static ThemeData dark() => _theme(Brightness.dark);

  static ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final primaryColor = dark ? primaryDark : primary;
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
    ).copyWith(
      // Pin the design's per-mode primary rather than letting fromSeed
      // derive a pastel dark-mode primary.
      primary: primaryColor,
      onPrimary: Colors.white,
    );
    final page = dark ? _pageDark : _pageLight;
    final card = dark ? _cardDark : _cardLight;
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: page,
      // Left-aligned bold titles on both platforms (iOS would center, and
      // M3's default title weight is regular).
      appBarTheme: AppBarTheme(
        backgroundColor: page,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      // Design tabs have no M3 indicator pill: active = flat primary icon +
      // label, inactive = muted outline.
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: card,
        indicatorColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? primaryColor
                : scheme.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? primaryColor
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(controlRadius),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(controlRadius),
          ),
        ),
      ),
    );
  }
}
