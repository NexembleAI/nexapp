import 'package:flutter/material.dart';

/// NexUI design tokens from doc/design/index.md.
abstract final class AppTheme {
  // Brand
  /// var(--primary) = oklch(0.5629 0.1817 262)
  static const Color primary = Color(0xFF356EDE);

  // Spectrum gradient — brand accent ONLY (app icon, splash, login mark,
  // avatars, Home tracking-card glow). Never on ordinary buttons.
  static const Color spectrumMagenta = Color(0xFFB023F2);
  static const Color spectrumIndigo = Color(0xFF5B63EC);
  static const Color spectrumBlue = Color(0xFF2F96E6);

  // Status semantics
  static const Color success = Color(0xFF16A34A); // Ready / Granted
  static const Color warning = Color(0xFFD97706); // Queued / Transcribing / Battery
  static const Color recording = Color(0xFFE0245E);

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
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
    ).copyWith(
      // The design uses the same flat primary on buttons in BOTH modes
      // (dark mode flips surfaces, not the primary), so pin it rather than
      // letting fromSeed derive a pastel dark-mode primary.
      primary: primary,
      onPrimary: Colors.white,
    );
    return ThemeData(
      colorScheme: scheme,
      // Design tabs have no M3 indicator pill: active = flat primary icon +
      // label, inactive = muted outline.
      navigationBarTheme: NavigationBarThemeData(
        indicatorColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? primary
                : scheme.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      cardTheme: CardThemeData(
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
