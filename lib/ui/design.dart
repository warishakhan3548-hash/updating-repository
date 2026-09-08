import 'dart:ui';

import 'package:flutter/material.dart';

import '../domain/date_input.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';

// Shared palette: brand colors communicate actions; status colors communicate stock.
const primary = Color(0xFF245BD6);
const primaryDeep = Color(0xFF183F99);
const primarySoft = Color(0xFFEAF0FF);
const accent = Color(0xFF0D747C);
const accentSoft = Color(0xFFE8F5F5);
const ink = Color(0xFF182A44);
const muted = Color(0xFF596A82);

// Same calm off-white canvas recipe used by the reference ledger app.
const canvas = Color(0xFFF3F5F8);
const outline = Color(0xFFD9E2F0);
const inverseMuted = Color(0xFFD5E2FF);
const green = Color(0xFF1D7653);
const red = Color(0xFFB63843);
const amber = Color(0xFF90600C);
const successSoft = Color(0xFFEDF7F1);
const warningSoft = Color(0xFFFFF5E3);
const errorSoft = Color(0xFFFFEFF1);

/// Premium page canvas: a clean ceramic-white base with restrained ambient
/// light. This is painted once behind the entire app rather than adding a
/// decorative background layer to every screen.
class PharmacyBackdrop extends StatelessWidget {
  const PharmacyBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      const RepaintBoundary(child: CustomPaint(painter: _PharmacyAmbientPainter())),
      BackdropGroup(child: child),
    ],
  );
}

class _PharmacyAmbientPainter extends CustomPainter {
  const _PharmacyAmbientPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = canvasColor);
    _paintGlow(
      canvas,
      bounds,
      center: const Alignment(-1.15, -1.2),
      radius: .88,
      color: green.withAlpha(28),
    );
    _paintGlow(
      canvas,
      bounds,
      center: const Alignment(1.15, 1.18),
      radius: .96,
      color: primary.withAlpha(24),
    );
    _paintGlow(
      canvas,
      bounds,
      center: const Alignment(.08, 1.24),
      radius: .68,
      color: amber.withAlpha(10),
    );
  }

  static const canvasColor = canvas;

  void _paintGlow(
    Canvas canvas,
    Rect bounds, {
    required Alignment center,
    required double radius,
    required Color color,
  }) {
    canvas.drawRect(
      bounds,
      Paint()
        ..blendMode = BlendMode.srcOver
        ..shader = RadialGradient(
          center: center,
          radius: radius,
          colors: [
            color,
            color.withValues(alpha: color.a * .35),
            Colors.transparent,
          ],
          stops: const [0, .45, 1],
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(covariant _PharmacyAmbientPainter oldDelegate) => false;
}

int _scaledAlpha(int alpha, double elevation) =>
    (alpha * elevation.clamp(.25, 1.5)).round().clamp(0, 255);

Color _ambientHue(Color color) =>
    Color.lerp(color, const Color(0xFF172033), .045)!;

List<BoxShadow> _ceramicDepth(double elevation) {
  final e = elevation.clamp(.25, 1.5);
  return [
    BoxShadow(
      color: Colors.white.withAlpha(_scaledAlpha(248, e)),
      blurRadius: 18,
      spreadRadius: -5,
      offset: const Offset(-6, -6),
    ),
    BoxShadow(
      color: const Color(0xFF243247).withAlpha(_scaledAlpha(38, e)),
      blurRadius: 3.5,
      spreadRadius: -1,
      offset: const Offset(0, 4),
    ),
    BoxShadow(
      color: const Color(0xFF243247).withAlpha(_scaledAlpha(24, e)),
      blurRadius: 25,
      spreadRadius: -7,
      offset: const Offset(8, 12),
    ),
  ];
}

List<BoxShadow> _jewelDepth(Color color, double elevation) {
  final e = elevation.clamp(.25, 1.5);
  return [
    BoxShadow(
      color: Colors.white.withAlpha(_scaledAlpha(238, e)),
      blurRadius: 11,
      spreadRadius: -4,
      offset: const Offset(-4, -4),
    ),
    BoxShadow(
      color: color.withAlpha(_scaledAlpha(40, e)),
      blurRadius: 15,
      spreadRadius: -5,
      offset: const Offset(2, 5),
    ),
    BoxShadow(
      color: Colors.black.withAlpha(_scaledAlpha(28, e)),
      blurRadius: 3.5,
      spreadRadius: -1,
      offset: const Offset(0, 4),
    ),
    BoxShadow(
      color: Colors.black.withAlpha(_scaledAlpha(17, e)),
      blurRadius: 18,
      spreadRadius: -7,
      offset: const Offset(6, 9),
    ),
  ];
}

/// Core raised-card primitive used by dashboard tiles, medicine rows, sheets,
/// status chips and navigation surfaces. The light recipe deliberately mirrors
/// the reference app's three-stop ceramic face, bevel light and physical depth.
/// No screen-specific wrapper is required.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.tint = Colors.white,
    this.radius = 24,
    this.padding = EdgeInsets.zero,
    this.dark = false,
    this.blurSigma = 0,
    this.elevation = 1,
    this.accentColor,
    this.shadowColor,
  });

  final Widget child;
  final Color tint;
  final double radius;
  final EdgeInsets padding;
  final bool dark;
  final double blurSigma;
  final double elevation;
  final Color? accentColor;
  final Color? shadowColor;

  @override
  Widget build(BuildContext context) {
    final highContrast = MediaQuery.highContrastOf(context);
    final strongColor = dark || tint.computeLuminance() < .20;
    final borderRadius = BorderRadius.circular(radius);
    final semantic = shadowColor ?? accentColor ??
        (tint == Colors.white ? null : tint);

    final List<Color> surfaceColors = strongColor
        ? [
            Color.alphaBlend(Colors.white.withValues(alpha: .075), tint),
            tint,
            Color.lerp(tint, Colors.black, .12)!,
          ]
        : tint == Colors.white
        ? const [
            Color(0xFFFFFFFF),
            Color(0xFFFAFCFE),
            Color(0xFFEEF2F6),
          ]
        : [
            Color.lerp(Colors.white, tint, .040)!,
            Color.lerp(const Color(0xFFFAFCFE), tint, .028)!,
            Color.lerp(const Color(0xFFEEF2F6), tint, .018)!,
          ];

    final resolvedBorder = highContrast
        ? (strongColor ? Colors.white : ink)
        : strongColor
        ? Colors.white.withValues(alpha: .17)
        : semantic == null
        ? Colors.white
        : Color.alphaBlend(
            semantic.withValues(alpha: .067),
            const Color(0xF0FFFFFF),
          );

    final shadows = <BoxShadow>[];
    if (elevation > 0) {
      if (strongColor) {
        final glow = _ambientHue(semantic ?? tint);
        shadows.addAll([
          BoxShadow(
            color: glow.withAlpha(_scaledAlpha(62, elevation)),
            blurRadius: 25,
            spreadRadius: -6,
            offset: const Offset(1, 8),
          ),
          BoxShadow(
            color: Colors.white.withAlpha(_scaledAlpha(24, elevation)),
            blurRadius: 13,
            spreadRadius: -6,
            offset: const Offset(-6, -6),
          ),
          BoxShadow(
            color: Colors.black.withAlpha(_scaledAlpha(92, elevation)),
            blurRadius: 4,
            spreadRadius: -1,
            offset: const Offset(0, 5),
          ),
          BoxShadow(
            color: Colors.black.withAlpha(_scaledAlpha(56, elevation)),
            blurRadius: 24,
            spreadRadius: -7,
            offset: const Offset(8, 13),
          ),
        ]);
      } else {
        if (semantic != null) {
          final glow = _ambientHue(semantic);
          shadows.add(
            BoxShadow(
              color: glow.withAlpha(_scaledAlpha(46, elevation)),
              blurRadius: 25,
              spreadRadius: -6,
              offset: const Offset(1, 7),
            ),
          );
          if (tint != Colors.white) {
            shadows.add(
              BoxShadow(
                color: glow.withAlpha(_scaledAlpha(21, elevation)),
                blurRadius: 42,
                spreadRadius: -13,
                offset: const Offset(5, 13),
              ),
            );
          }
        }
        shadows.addAll(_ceramicDepth(elevation));
        shadows.add(
          BoxShadow(
            color: const Color(0xFF243247).withAlpha(
              _scaledAlpha(9, elevation),
            ),
            blurRadius: 19,
            spreadRadius: -9,
            offset: const Offset(8, 13),
          ),
        );
      }
    }

    final panel = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0, .52, 1],
          colors: surfaceColors,
        ),
        borderRadius: borderRadius,
      ),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          border: Border.all(
            color: resolvedBorder,
            width: highContrast ? 1.5 : 1,
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      stops: const [0, .23, .69, 1],
                      colors: [
                        Color.fromARGB(148, 255, 255, 255),
                        Colors.transparent,
                        Colors.transparent,
                        Color.fromARGB(12, 0, 0, 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (semantic != null && !strongColor)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.bottomRight,
                        radius: 1.28,
                        colors: [
                          semantic.withValues(alpha: .055),
                          Colors.transparent,
                        ],
                        stops: const [0, .72],
                      ),
                    ),
                  ),
                ),
              ),
            Padding(padding: padding, child: child),
          ],
        ),
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: shadows,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: highContrast || blurSigma <= 0
            ? panel
            : BackdropFilter.grouped(
                filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
                child: panel,
              ),
      ),
    );
  }
}

class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.size = 48,
    this.tint = primarySoft,
    this.color = primary,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;
  final double size;
  final Color tint;
  final Color color;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: GlassPanel(
      tint: tint,
      accentColor: color,
      shadowColor: color,
      radius: size * .5,
      blurSigma: 0,
      elevation: 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(size * .5),
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, color: color, size: size * .48),
          ),
        ),
      ),
    ),
  );
}

BoxDecoration depthDecoration(Color color, {double radius = 22}) {
  final strongColor = color.computeLuminance() < .20;
  return BoxDecoration(
    gradient: strongColor
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(Colors.white.withValues(alpha: .07), color),
              color,
              Color.lerp(color, Colors.black, .10)!,
            ],
          )
        : const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFFFFFF), Color(0xFFFAFCFE), Color(0xFFEEF2F6)],
          ),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(
      color: strongColor
          ? Colors.white.withValues(alpha: .16)
          : Colors.white,
    ),
    boxShadow: strongColor
        ? [
            BoxShadow(
              color: color.withValues(alpha: .18),
              blurRadius: 22,
              spreadRadius: -6,
              offset: const Offset(1, 7),
            ),
            BoxShadow(
              color: ink.withValues(alpha: .16),
              blurRadius: 4,
              spreadRadius: -1,
              offset: const Offset(0, 5),
            ),
          ]
        : _ceramicDepth(1),
  );
}

class DepthIcon extends StatelessWidget {
  const DepthIcon(
    this.icon, {
    super.key,
    this.color = primary,
    this.background = primarySoft,
    this.size = 48,
  });

  final IconData icon;
  final Color color, background;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: GlassPanel(
      tint: background,
      accentColor: color,
      shadowColor: color,
      radius: size * .34,
      blurSigma: 0,
      elevation: 1.05,
      child: SizedBox(
        width: size,
        height: size,
        child: Icon(
          icon,
          color: color,
          size: size * .52,
          shadows: [
            Shadow(color: color.withValues(alpha: .18), blurRadius: 10),
          ],
        ),
      ),
    ),
  );
}

class ScreenIntro extends StatelessWidget {
  const ScreenIntro({
    super.key,
    required this.title,
    required this.message,
    required this.icon,
    this.color = primary,
  });

  final String title, message;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 7),
              Text(
                message,
                style: const TextStyle(color: muted, fontSize: 13, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        DepthIcon(icon, color: color),
      ],
    ),
  );
}

class FlowSteps extends StatelessWidget {
  const FlowSteps(this.steps, {super.key, this.current = 0});

  final List<String> steps;
  final int current;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < steps.length; i++)
          GlassPanel(
            tint: i == current ? primarySoft : Colors.white,
            accentColor: i == current ? primary : null,
            radius: 14,
            blurSigma: 0,
            elevation: i == current ? .85 : .55,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Text(
              '${i + 1}  ${steps[i]}',
              style: TextStyle(
                color: i == current ? ink : muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    ),
  );
}

class ResponsivePair extends StatelessWidget {
  const ResponsivePair({super.key, required this.first, required this.second});

  final Widget first, second;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 300 ||
          MediaQuery.textScalerOf(context).scale(14) > 20) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [first, const SizedBox(height: 12), second],
        );
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: first),
            const SizedBox(width: 12),
            Expanded(child: second),
          ],
        ),
      );
    },
  );
}

class FormSection extends StatelessWidget {
  const FormSection({
    super.key,
    required this.title,
    required this.message,
    required this.icon,
    required this.children,
  });

  final String title, message;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Surface(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DepthIcon(icon, size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(message, style: const TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 18),
          ...children,
        ],
      ),
    ),
  );
}

ThemeData pharmacyTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: primary).copyWith(
    primary: primary,
    onPrimary: Colors.white,
    primaryContainer: primarySoft,
    onPrimaryContainer: primaryDeep,
    secondary: accent,
    onSecondary: Colors.white,
    secondaryContainer: accentSoft,
    onSecondaryContainer: accent,
    surface: Colors.white,
    onSurface: ink,
    onSurfaceVariant: muted,
    error: red,
    onError: Colors.white,
    outline: outline,
  ),
  scaffoldBackgroundColor: Colors.transparent,
  canvasColor: Colors.white,
  fontFamily: 'Manrope',
  fontFamilyFallback: const ['NotoSansDevanagari'],
  textTheme: const TextTheme(
    headlineLarge: TextStyle(
      fontSize: 34,
      fontWeight: FontWeight.w800,
      letterSpacing: -1,
      color: ink,
    ),
    headlineMedium: TextStyle(
      fontSize: 27,
      fontWeight: FontWeight.w800,
      letterSpacing: -.7,
      color: ink,
    ),
    titleLarge: TextStyle(
      fontSize: 21,
      fontWeight: FontWeight.w800,
      letterSpacing: -.4,
      color: ink,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w700,
      color: ink,
    ),
    bodyLarge: TextStyle(fontSize: 16, height: 1.45, color: ink),
    bodyMedium: TextStyle(fontSize: 14, height: 1.45, color: ink),
    bodySmall: TextStyle(fontSize: 12, height: 1.45, color: muted),
  ),
  appBarTheme: AppBarTheme(
    backgroundColor: Colors.white.withValues(alpha: .90),
    foregroundColor: ink,
    centerTitle: false,
    elevation: 2,
    scrolledUnderElevation: 4,
    shadowColor: ink.withValues(alpha: .10),
    surfaceTintColor: Colors.transparent,
    titleTextStyle: const TextStyle(
      fontFamily: 'Manrope',
      fontFamilyFallback: ['NotoSansDevanagari'],
      fontSize: 19,
      fontWeight: FontWeight.w800,
      color: ink,
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xFFFCFDFE),
    floatingLabelStyle: const TextStyle(
      color: primary,
      fontWeight: FontWeight.w700,
    ),
    hintStyle: const TextStyle(color: muted),
    helperMaxLines: 3,
    errorMaxLines: 3,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: outline),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: Colors.white.withValues(alpha: .95)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: primary, width: 2),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: red),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: red, width: 2),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(48, 56),
      backgroundColor: primary,
      foregroundColor: Colors.white,
      disabledBackgroundColor: outline,
      disabledForegroundColor: muted,
      shadowColor: primaryDeep.withValues(alpha: .34),
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      textStyle: const TextStyle(
        fontFamily: 'Manrope',
        fontFamilyFallback: ['NotoSansDevanagari'],
        fontSize: 15,
        fontWeight: FontWeight.w800,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 52),
      foregroundColor: primaryDeep,
      backgroundColor: Colors.white,
      side: BorderSide(color: primary.withValues(alpha: .18)),
      shadowColor: ink.withValues(alpha: .16),
      elevation: 2,
      textStyle: const TextStyle(
        fontFamily: 'Manrope',
        fontFamilyFallback: ['NotoSansDevanagari'],
        fontSize: 14,
        fontWeight: FontWeight.w800,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(
      minimumSize: const Size(48, 48),
      foregroundColor: primary,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: const TextStyle(fontWeight: FontWeight.w800),
    ),
  ),
  iconButtonTheme: IconButtonThemeData(
    style: IconButton.styleFrom(
      minimumSize: const Size(48, 48),
      foregroundColor: primary,
      padding: const EdgeInsets.all(12),
    ),
  ),
  listTileTheme: const ListTileThemeData(
    iconColor: primary,
    textColor: ink,
    minVerticalPadding: 14,
    titleTextStyle: TextStyle(
      fontFamily: 'Manrope',
      fontFamilyFallback: ['NotoSansDevanagari'],
      fontSize: 15,
      fontWeight: FontWeight.w700,
      color: ink,
    ),
    subtitleTextStyle: TextStyle(
      fontFamily: 'Manrope',
      fontFamilyFallback: ['NotoSansDevanagari'],
      fontSize: 12,
      height: 1.45,
      color: muted,
    ),
  ),
  chipTheme: ChipThemeData(
    backgroundColor: Colors.white,
    selectedColor: primarySoft,
    side: BorderSide(color: primary.withValues(alpha: .10)),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    labelStyle: const TextStyle(
      fontFamily: 'Manrope',
      fontFamilyFallback: ['NotoSansDevanagari'],
      color: ink,
      fontSize: 13,
      fontWeight: FontWeight.w700,
    ),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
    elevation: 1,
    pressElevation: 2,
    shadowColor: ink.withValues(alpha: .10),
  ),
  dialogTheme: DialogThemeData(
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    elevation: 10,
    shadowColor: ink.withValues(alpha: .18),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
  ),
  bottomSheetTheme: BottomSheetThemeData(
    backgroundColor: canvas,
    surfaceTintColor: Colors.transparent,
    elevation: 12,
    shadowColor: ink.withValues(alpha: .18),
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
    ),
  ),
  cardTheme: CardThemeData(
    color: Colors.white,
    surfaceTintColor: Colors.transparent,
    elevation: 6,
    shadowColor: ink.withValues(alpha: .18),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
      side: const BorderSide(color: Colors.white),
    ),
  ),
  popupMenuTheme: PopupMenuThemeData(
    color: Colors.white,
    surfaceTintColor: Colors.transparent,
    elevation: 8,
    shadowColor: ink.withValues(alpha: .18),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
  ),
  snackBarTheme: SnackBarThemeData(
    backgroundColor: ink,
    contentTextStyle: const TextStyle(color: Colors.white),
    behavior: SnackBarBehavior.floating,
    elevation: 8,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  ),
  dividerTheme: DividerThemeData(
    color: ink.withValues(alpha: .08),
    thickness: 1,
    space: 1,
  ),
  progressIndicatorTheme: const ProgressIndicatorThemeData(color: primary),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: Colors.white.withValues(alpha: .92),
    surfaceTintColor: Colors.transparent,
    elevation: 8,
    shadowColor: ink.withValues(alpha: .12),
    height: 72,
    indicatorColor: primarySoft,
    indicatorShape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    ),
    iconTheme: WidgetStateProperty.resolveWith(
      (states) => IconThemeData(
        color: states.contains(WidgetState.selected) ? primary : muted,
      ),
    ),
    labelTextStyle: WidgetStateProperty.resolveWith(
      (states) => TextStyle(
        fontSize: 11,
        fontWeight: states.contains(WidgetState.selected)
            ? FontWeight.w800
            : FontWeight.w600,
        color: states.contains(WidgetState.selected) ? primary : muted,
      ),
    ),
  ),
);

class Surface extends StatelessWidget {
  const Surface({
    super.key,
    required this.child,
    this.color = Colors.white,
    this.padding = const EdgeInsets.all(20),
  });

  final Widget child;
  final Color color;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => GlassPanel(
    tint: color,
    accentColor: color == Colors.white ? null : color,
    shadowColor: color == Colors.white ? null : color,
    blurSigma: 0,
    elevation: 1,
    padding: padding,
    child: Material(type: MaterialType.transparency, child: child),
  );
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 26, bottom: 14),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final heading = Text(
          title,
          style: Theme.of(context).textTheme.titleLarge,
        );
        if (action != null &&
            (constraints.maxWidth < 350 ||
                MediaQuery.textScalerOf(context).scale(14) > 20)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [heading, const SizedBox(height: 8), action!],
          );
        }
        return Row(
          children: [
            Expanded(child: heading),
            if (action != null) action!,
          ],
        );
      },
    ),
  );
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.text, {super.key, this.color = green});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => GlassPanel(
    tint: Color.alphaBlend(color.withValues(alpha: .10), Colors.white),
    accentColor: color,
    shadowColor: color,
    radius: 30,
    blurSigma: 0,
    elevation: .55,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800),
    ),
  );
}

class MedicineCard extends StatelessWidget {
  const MedicineCard({
    super.key,
    required this.record,
    required this.settings,
    required this.today,
    required this.onTap,
    this.matchLabel,
  });

  final Medicine record;
  final WarningSettings settings;
  final DateTime today;
  final VoidCallback onTap;
  final String? matchLabel;

  @override
  Widget build(BuildContext context) {
    final state = statusOf(record, settings, today);
    final statusColor = switch (state.status) {
      StockStatus.sold => amber,
      StockStatus.expired => red,
      _ => green,
    };
    final icon = switch (record.form) {
      'Syrup' => Icons.water_drop_outlined,
      'Capsule' => Icons.medication_outlined,
      'Injection' => Icons.vaccines_outlined,
      'Cream' || 'Ointment' => Icons.sanitizer_outlined,
      'Drops' => Icons.water_drop_outlined,
      _ => Icons.medication_rounded,
    };
    final timeline =
        state.status == StockStatus.shortExpiry ||
        state.status == StockStatus.monthExpiry;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Semantics(
        label: '${record.title}, ${state.label}, ${record.address}',
        button: true,
        child: CustomPaint(
          foregroundPainter: _ExpiryBorder(
            timeline
                ? state.redFraction
                : state.status == StockStatus.expired
                ? 1
                : 0,
            state.status == StockStatus.sold
                ? amber
                : timeline
                ? green
                : Colors.transparent,
            timeline ||
                state.status == StockStatus.expired ||
                state.status == StockStatus.sold,
          ),
          child: GlassPanel(
            tint: Colors.white,
            accentColor: statusColor,
            shadowColor: statusColor,
            radius: 28,
            blurSigma: 0,
            elevation: 1,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(28),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 17,
                    vertical: 15,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GlassPanel(
                            tint: Color.alphaBlend(
                              statusColor.withValues(alpha: .10),
                              Colors.white,
                            ),
                            accentColor: statusColor,
                            shadowColor: statusColor,
                            radius: 18,
                            blurSigma: 0,
                            elevation: .95,
                            child: SizedBox(
                              width: 52,
                              height: 52,
                              child: Icon(
                                state.status == StockStatus.sold
                                    ? Icons.check_rounded
                                    : icon,
                                color: statusColor,
                                size: 27,
                                shadows: [
                                  Shadow(
                                    color: statusColor.withValues(alpha: .16),
                                    blurRadius: 10,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  record.name,
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                if (record.strength.isNotEmpty ||
                                    record.brand.isNotEmpty)
                                  Text(
                                    [record.strength, record.brand]
                                        .where((s) => s.isNotEmpty)
                                        .join(' · '),
                                    style: const TextStyle(
                                      color: muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                if (record.manufacturer.isNotEmpty)
                                  Text(
                                    record.manufacturer,
                                    style: const TextStyle(
                                      color: muted,
                                      fontSize: 12,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                if (record.salt.isNotEmpty)
                                  Text(
                                    record.salt,
                                    style: const TextStyle(
                                      color: muted,
                                      fontSize: 12,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: muted,
                            size: 24,
                          ),
                        ],
                      ),
                      const SizedBox(height: 15),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          StatusPill(state.label, color: statusColor),
                          if (record.expiry != null)
                            Text(
                              'EXP ${inputDateText(record.expiry!, monthOnly: record.expiryMonthOnly)}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: muted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                      if (record.address.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.location_on_outlined,
                                size: 15,
                                color: muted,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  record.address,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: muted,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (matchLabel != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            matchLabel!,
                            style: const TextStyle(fontSize: 12, color: amber),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExpiryBorder extends CustomPainter {
  _ExpiryBorder(this.fraction, this.base, this.strong);

  final double fraction;
  final Color base;
  final bool strong;

  @override
  void paint(Canvas canvas, Size size) {
    if (!strong) return;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(28)),
      );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = base;
    if (base != Colors.transparent) canvas.drawPath(path, paint);
    if (fraction > 0) {
      final metric = path.computeMetrics().first;
      canvas.drawPath(
        metric.extractPath(0, metric.length * fraction),
        paint
          ..color = red
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_ExpiryBorder old) =>
      fraction != old.fraction || base != old.base || strong != old.strong;
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.message,
    this.action,
  });

  final String title, message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 12),
    child: Column(
      children: [
        const DepthIcon(
          Icons.inventory_2_outlined,
          size: 76,
          background: primarySoft,
        ),
        const SizedBox(height: 18),
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: muted),
        ),
        if (action != null)
          Padding(padding: const EdgeInsets.only(top: 20), child: action!),
      ],
    ),
  );
}

void showError(BuildContext context, Object error) {
  if (!context.mounted) return;
  final text = error.toString().replaceFirst(
    RegExp(r'^(FormatException|Bad state|StateError):\s*'),
    '',
  );
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(text),
      backgroundColor: red,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 7),
    ),
  );
}

void showSaved(BuildContext context, String message) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }
}
