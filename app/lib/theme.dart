import 'package:material_ui/material_ui.dart';

/// Approved light palette. Screens read colors through [FauxneticColors] (`context.colors`), never from here.
class Palette {
  static const paper = Color(0xFFEEF0F4);
  static const ink = Color(0xFF141822);
  static const real = Color(0xFF0E7C66);
  static const clone = Color(0xFFC21C7A);
  static const muted = Color(0xFF6B7385);
  static const rule = Color(0xFFD5D9E2);
  static const card = Color(0xFFF8F9FB);
}

/// The app's named colors for the current theme. Teal ([real]) only ever means the person's real voice;
/// magenta ([clone]) only the clone.
class FauxneticColors extends ThemeExtension<FauxneticColors> {
  const FauxneticColors({
    required this.paper,
    required this.card,
    required this.ink,
    required this.muted,
    required this.rule,
    required this.real,
    required this.clone,
    required this.uncertainFill,
    required this.uncertainBorder,
    required this.raised,
    required this.soft,
    required this.making,
    required this.failed,
    required this.excited,
    required this.annoyed,
    required this.worried,
  });

  final Color paper, card, ink, muted, rule, real, clone, uncertainFill, uncertainBorder;

  /// Speak screen redesign (owner-approved mockup, 2026-11-23): color carries meaning, not only
  /// magenta. [raised]: buttons and controls on a card. [soft]: secondary text that still reads as
  /// enabled (muted looked disabled). [making]: a line being made. [failed]: a line that failed.
  /// [excited], [annoyed], [worried]: each mood's own color on its chips and tags.
  final Color raised, soft, making, failed, excited, annoyed, worried;

  static const light = FauxneticColors(
    paper: Palette.paper,
    card: Palette.card,
    ink: Palette.ink,
    muted: Palette.muted,
    rule: Palette.rule,
    real: Palette.real,
    clone: Palette.clone,
    uncertainFill: Color(0xFFFFF1C2),
    uncertainBorder: Color(0xFFE0B000),
    raised: Color(0xFFE4E7EE),
    soft: Color(0xFF3B4252),
    making: Color(0xFF9A6700),
    failed: Color(0xFFC9302C),
    excited: Color(0xFFB85A00),
    annoyed: Color(0xFFC0392B),
    worried: Color(0xFF5B4BD6),
  );

  /// "Ink night", picked by the owner (2026-11-15).
  static const dark = FauxneticColors(
    paper: Color(0xFF10131A),
    card: Color(0xFF181C25),
    ink: Color(0xFFE8EBF2),
    muted: Color(0xFF8A93A6),
    rule: Color(0xFF2A303C),
    real: Color(0xFF2BC4A3),
    clone: Color(0xFFF0559F),
    uncertainFill: Color(0xFF3A3115),
    uncertainBorder: Color(0xFFE0B000),
    raised: Color(0xFF232936),
    soft: Color(0xFFC3C9D6),
    making: Color(0xFFF2B84B),
    failed: Color(0xFFFF6B6B),
    excited: Color(0xFFFF9F43),
    annoyed: Color(0xFFF25F5C),
    worried: Color(0xFF9B8CFF),
  );

  @override
  FauxneticColors copyWith({
    Color? paper,
    Color? card,
    Color? ink,
    Color? muted,
    Color? rule,
    Color? real,
    Color? clone,
    Color? uncertainFill,
    Color? uncertainBorder,
    Color? raised,
    Color? soft,
    Color? making,
    Color? failed,
    Color? excited,
    Color? annoyed,
    Color? worried,
  }) => FauxneticColors(
    paper: paper ?? this.paper,
    card: card ?? this.card,
    ink: ink ?? this.ink,
    muted: muted ?? this.muted,
    rule: rule ?? this.rule,
    real: real ?? this.real,
    clone: clone ?? this.clone,
    uncertainFill: uncertainFill ?? this.uncertainFill,
    uncertainBorder: uncertainBorder ?? this.uncertainBorder,
    raised: raised ?? this.raised,
    soft: soft ?? this.soft,
    making: making ?? this.making,
    failed: failed ?? this.failed,
    excited: excited ?? this.excited,
    annoyed: annoyed ?? this.annoyed,
    worried: worried ?? this.worried,
  );

  @override
  FauxneticColors lerp(FauxneticColors? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return FauxneticColors(
      paper: c(paper, other.paper),
      card: c(card, other.card),
      ink: c(ink, other.ink),
      muted: c(muted, other.muted),
      rule: c(rule, other.rule),
      real: c(real, other.real),
      clone: c(clone, other.clone),
      uncertainFill: c(uncertainFill, other.uncertainFill),
      uncertainBorder: c(uncertainBorder, other.uncertainBorder),
      raised: c(raised, other.raised),
      soft: c(soft, other.soft),
      making: c(making, other.making),
      failed: c(failed, other.failed),
      excited: c(excited, other.excited),
      annoyed: c(annoyed, other.annoyed),
      worried: c(worried, other.worried),
    );
  }
}

extension FauxneticTheme on BuildContext {
  FauxneticColors get colors => Theme.of(this).extension<FauxneticColors>() ?? FauxneticColors.light;
}

const kFontFamily = 'AtkinsonHyperlegibleNext';

ThemeData buildTheme(Brightness brightness) {
  final m = brightness == Brightness.dark ? FauxneticColors.dark : FauxneticColors.light;
  final base = ThemeData(
    useMaterial3: true,
    fontFamily: kFontFamily,
    colorScheme: ColorScheme.fromSeed(
      seedColor: m.ink,
      brightness: brightness,
      surface: m.paper,
      onSurface: m.ink,
      primary: m.ink,
      // Light keeps today's white text on ink buttons; dark uses paper-colored text on light ink.
      onPrimary: brightness == Brightness.dark ? m.paper : Colors.white,
      secondary: m.real,
      tertiary: m.clone,
      outline: m.rule,
    ),
    scaffoldBackgroundColor: m.paper,
    extensions: [m],
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: kFontFamily, bodyColor: m.ink, displayColor: m.ink),
    appBarTheme: AppBarTheme(backgroundColor: m.paper, foregroundColor: m.ink, elevation: 0, scrolledUnderElevation: 0),
    dividerTheme: DividerThemeData(color: m.rule, thickness: 1),
    // Off reads as off, not as disabled: Material's default outlined it in the faint rule grey
    // (owner, 2026-11-23). Disabled stays faded.
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.disabled)) return m.rule;
        return s.contains(WidgetState.selected) ? m.paper : m.muted;
      }),
      trackColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.disabled)) return m.card;
        return s.contains(WidgetState.selected) ? m.ink : m.card;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.disabled)) return m.rule;
        return s.contains(WidgetState.selected) ? m.ink : m.muted;
      }),
    ),
  );
}
