import 'dart:ui';

import 'package:flutter/material.dart';

import '../domain/medicine.dart';
import '../domain/date_input.dart';
import '../domain/inventory.dart';

const ink = Color(0xFF173B34);
const muted = Color(0xFF60746C);
const canvas = Color(0xFFF3F8F5);
const lime = Color(0xFFD9F39A);
const green = Color(0xFF237A55);
const red = Color(0xFFBD3F3C);
const amber = Color(0xFF9C680D);

/// The fixed, lightweight colour field behind every route. The glows are
/// painted once instead of blurring large full-screen widgets while scrolling.
class PharmacyBackdrop extends StatelessWidget {
  const PharmacyBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: canvas,
    child: Stack(
      fit: StackFit.expand,
      children: [
        const RepaintBoundary(
          child: IgnorePointer(
            child: CustomPaint(painter: _AmbientGlowPainter()),
          ),
        ),
        BackdropGroup(child: child),
      ],
    ),
  );
}

class _AmbientGlowPainter extends CustomPainter {
  const _AmbientGlowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    void glow(Offset center, double radius, Color color) {
      final bounds = Rect.fromCircle(center: center, radius: radius);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
          ).createShader(bounds),
      );
    }

    glow(
      Offset(size.width * .10, size.height * .08),
      size.shortestSide * .72,
      const Color(0x385EF0C1),
    );
    glow(
      Offset(size.width * .95, size.height * .33),
      size.shortestSide * .68,
      const Color(0x2D88D8FF),
    );
    glow(
      Offset(size.width * .36, size.height * .94),
      size.shortestSide * .78,
      const Color(0x26DDF59D),
    );
  }

  @override
  bool shouldRepaint(_AmbientGlowPainter oldDelegate) => false;
}

/// One shared glass recipe for dashboard tiles, cards, sheets and navigation.
///
/// [blurSigma] is intentionally opt-in for dense scrolling content. The
/// translucent gradient still reads as glass without making every list row a
/// costly backdrop-filter layer.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.tint = Colors.white,
    this.radius = 24,
    this.padding = EdgeInsets.zero,
    this.dark = false,
    this.blurSigma = 14,
    this.elevation = 1,
  });

  final Widget child;
  final Color tint;
  final double radius;
  final EdgeInsets padding;
  final bool dark;
  final double blurSigma;
  final double elevation;

  @override
  Widget build(BuildContext context) {
    final highContrast = MediaQuery.highContrastOf(context);
    final borderRadius = BorderRadius.circular(radius);
    final effectiveBlur = highContrast ? 0.0 : blurSigma;
    final baseAlpha = highContrast ? (dark ? .98 : .96) : (dark ? .91 : .70);
    final top = Color.alphaBlend(
      Colors.white.withValues(alpha: dark ? .12 : .64),
      tint,
    ).withValues(alpha: baseAlpha);
    final middle = Color.alphaBlend(
      Colors.white.withValues(alpha: dark ? .035 : .24),
      tint,
    ).withValues(alpha: baseAlpha);
    final bottom = Color.alphaBlend(
      (dark ? Colors.black : ink).withValues(alpha: dark ? .09 : .035),
      tint,
    ).withValues(alpha: baseAlpha);
    final panel = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0, .48, 1],
          colors: [top, middle, bottom],
        ),
        border: Border.all(
          color: highContrast
              ? (dark ? Colors.white : ink).withValues(alpha: .64)
              : Colors.white.withValues(alpha: dark ? .22 : .90),
          width: highContrast ? 1.5 : 1.15,
        ),
      ),
      child: child,
    );
    final filtered = effectiveBlur <= 0
        ? panel
        : BackdropFilter.grouped(
            filter: ImageFilter.blur(
              sigmaX: effectiveBlur,
              sigmaY: effectiveBlur,
              tileMode: TileMode.decal,
            ),
            child: panel,
          );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: elevation <= 0
            ? const []
            : [
                BoxShadow(
                  color: (dark ? Colors.black : ink).withValues(
                    alpha: dark ? .24 : .085 * elevation.clamp(0, 1.5),
                  ),
                  blurRadius: 18 + (8 * elevation),
                  spreadRadius: -5,
                  offset: Offset(0, 8 + (5 * elevation)),
                ),
                BoxShadow(
                  color: tint.withValues(
                    alpha: dark ? .06 : .12 * elevation.clamp(0, 1.5),
                  ),
                  blurRadius: 18,
                  spreadRadius: -7,
                  offset: const Offset(0, 8),
                ),
                BoxShadow(
                  color: Colors.white.withValues(alpha: dark ? .035 : .82),
                  blurRadius: 9,
                  spreadRadius: -6,
                  offset: const Offset(-4, -4),
                ),
              ],
      ),
      child: ClipRRect(borderRadius: borderRadius, child: filtered),
    );
  }
}

class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.size = 44,
    this.tint = const Color(0xFFE4F3EE),
    this.color = ink,
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
      radius: size * .5,
      blurSigma: 0,
      elevation: .65,
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

BoxDecoration depthDecoration(Color color, {double radius = 24}) {
  final dark = color.computeLuminance() < .15;
  return BoxDecoration(
    borderRadius: BorderRadius.circular(radius),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.alphaBlend(
          Colors.white.withValues(alpha: dark ? .10 : .58),
          color,
        ),
        color,
        Color.alphaBlend(ink.withValues(alpha: dark ? .09 : .035), color),
      ],
    ),
    border: Border.all(
      color: dark
          ? Colors.white.withValues(alpha: .12)
          : Colors.white.withValues(alpha: .88),
      width: 1.1,
    ),
    boxShadow: [
      BoxShadow(
        color: ink.withValues(alpha: dark ? .22 : .09),
        blurRadius: 26,
        spreadRadius: -5,
        offset: const Offset(0, 13),
      ),
      BoxShadow(
        color: Colors.white.withValues(alpha: dark ? .04 : .78),
        blurRadius: 9,
        spreadRadius: -6,
        offset: const Offset(-4, -4),
      ),
    ],
  );
}

class DepthIcon extends StatelessWidget {
  const DepthIcon(
    this.icon, {
    super.key,
    this.color = green,
    this.background = const Color(0xFFE3F2E4),
    this.size = 48,
  });
  final IconData icon;
  final Color color, background;
  final double size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: GlassPanel(
      tint: background,
      radius: size * .32,
      blurSigma: 0,
      elevation: .65,
      child: SizedBox(
        width: size,
        height: size,
        child: Icon(icon, color: color, size: size * .52),
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
    this.color = green,
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
            tint: i == current ? lime : Colors.white,
            radius: 14,
            blurSigma: 0,
            elevation: i == current ? .55 : .3,
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
  colorScheme:
      ColorScheme.fromSeed(
        seedColor: ink,
        brightness: Brightness.light,
      ).copyWith(
        primary: ink,
        secondary: green,
        surface: const Color(0xFFF8FCFA),
        error: red,
      ),
  scaffoldBackgroundColor: Colors.transparent,
  fontFamily: 'Manrope',
  fontFamilyFallback: const ['NotoSansDevanagari'],
  textTheme: const TextTheme(
    headlineLarge: TextStyle(
      fontSize: 34,
      fontWeight: FontWeight.w800,
      letterSpacing: -1.1,
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
    bodyLarge: TextStyle(fontSize: 16, height: 1.4, color: ink),
    bodyMedium: TextStyle(fontSize: 14, height: 1.4, color: ink),
    bodySmall: TextStyle(fontSize: 12, height: 1.4, color: muted),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.transparent,
    foregroundColor: ink,
    centerTitle: false,
    elevation: 0,
    scrolledUnderElevation: 0,
    surfaceTintColor: Colors.transparent,
    titleTextStyle: TextStyle(
      fontFamily: 'Manrope',
      fontSize: 19,
      fontWeight: FontWeight.w800,
      color: ink,
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white.withValues(alpha: .66),
    floatingLabelStyle: const TextStyle(
      color: green,
      fontWeight: FontWeight.w700,
    ),
    helperMaxLines: 3,
    errorMaxLines: 3,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide(color: Colors.white.withValues(alpha: .86)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide(color: Colors.white.withValues(alpha: .88)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: green, width: 1.8),
    ),
    disabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide(color: Colors.white.withValues(alpha: .52)),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style:
        FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          backgroundColor: ink,
          foregroundColor: Colors.white,
          disabledBackgroundColor: ink.withValues(alpha: .16),
          disabledForegroundColor: ink.withValues(alpha: .42),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(17),
            side: BorderSide(color: Colors.white.withValues(alpha: .22)),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          elevation: 5,
          shadowColor: ink.withValues(alpha: .28),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ).copyWith(
          elevation: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? 0
                : states.contains(WidgetState.pressed)
                ? 1
                : 5,
          ),
        ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style:
        OutlinedButton.styleFrom(
          minimumSize: const Size(48, 50),
          foregroundColor: ink,
          backgroundColor: Colors.white.withValues(alpha: .58),
          disabledBackgroundColor: Colors.white.withValues(alpha: .26),
          side: BorderSide(
            color: Colors.white.withValues(alpha: .90),
            width: 1.1,
          ),
          elevation: 3,
          shadowColor: ink.withValues(alpha: .14),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(17),
          ),
        ).copyWith(
          elevation: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? 0
                : states.contains(WidgetState.pressed)
                ? 0
                : 3,
          ),
        ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(
      minimumSize: const Size(44, 44),
      foregroundColor: ink,
      backgroundColor: Colors.white.withValues(alpha: .38),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
        side: BorderSide(color: Colors.white.withValues(alpha: .68)),
      ),
    ),
  ),
  iconButtonTheme: IconButtonThemeData(
    style: IconButton.styleFrom(
      foregroundColor: ink,
      backgroundColor: Colors.white.withValues(alpha: .48),
      disabledBackgroundColor: Colors.white.withValues(alpha: .18),
      padding: const EdgeInsets.all(11),
      shape: CircleBorder(
        side: BorderSide(color: Colors.white.withValues(alpha: .72)),
      ),
    ),
  ),
  listTileTheme: const ListTileThemeData(
    iconColor: green,
    textColor: ink,
    minVerticalPadding: 14,
    titleTextStyle: TextStyle(
      fontFamily: 'Manrope',
      fontSize: 15,
      fontWeight: FontWeight.w700,
      color: ink,
    ),
    subtitleTextStyle: TextStyle(
      fontFamily: 'Manrope',
      fontSize: 12,
      height: 1.45,
      color: muted,
    ),
  ),
  chipTheme: ChipThemeData(
    backgroundColor: Colors.white.withValues(alpha: .58),
    selectedColor: lime,
    disabledColor: Colors.white.withValues(alpha: .26),
    side: BorderSide(color: Colors.white.withValues(alpha: .84)),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    labelStyle: const TextStyle(
      color: ink,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
    elevation: 2,
    pressElevation: 0,
    shadowColor: ink.withValues(alpha: .12),
  ),
  dialogTheme: DialogThemeData(
    backgroundColor: const Color(0xF2F8FCFA),
    surfaceTintColor: Colors.transparent,
    elevation: 18,
    shadowColor: ink.withValues(alpha: .22),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
  ),
  bottomSheetTheme: BottomSheetThemeData(
    backgroundColor: Colors.white.withValues(alpha: .92),
    surfaceTintColor: Colors.transparent,
    showDragHandle: true,
    elevation: 18,
    shadowColor: ink.withValues(alpha: .20),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
  ),
  cardTheme: CardThemeData(
    color: Colors.white.withValues(alpha: .72),
    surfaceTintColor: Colors.transparent,
    elevation: 4,
    shadowColor: ink.withValues(alpha: .12),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
      side: BorderSide(color: Colors.white.withValues(alpha: .84)),
    ),
  ),
  popupMenuTheme: PopupMenuThemeData(
    color: const Color(0xF4F8FCFA),
    surfaceTintColor: Colors.transparent,
    elevation: 12,
    shadowColor: ink.withValues(alpha: .18),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
  ),
  snackBarTheme: SnackBarThemeData(
    backgroundColor: ink.withValues(alpha: .95),
    contentTextStyle: const TextStyle(color: Colors.white),
    elevation: 10,
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  ),
  progressIndicatorTheme: const ProgressIndicatorThemeData(color: green),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    height: 76,
    indicatorColor: lime,
    indicatorShape: const StadiumBorder(),
    labelTextStyle: WidgetStateProperty.all(
      const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
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
    blurSigma: 0,
    elevation: 1,
    padding: padding,
    child: Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
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
    tint: Color.alphaBlend(color.withValues(alpha: .12), Colors.white),
    radius: 30,
    blurSigma: 0,
    elevation: .3,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
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
    final accent = switch (state.status) {
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
    final cardTint = switch (state.status) {
      StockStatus.sold => const Color(0xFFFFF3D7),
      StockStatus.expired => const Color(0xFFFFE9E7),
      StockStatus.shortExpiry => const Color(0xFFECF8E5),
      StockStatus.monthExpiry => const Color(0xFFEAF7F3),
      _ => Colors.white,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
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
                : const Color(0xFFDAE5DC),
            timeline ||
                state.status == StockStatus.expired ||
                state.status == StockStatus.sold,
          ),
          child: GlassPanel(
            tint: cardTint,
            radius: 22,
            blurSigma: 0,
            elevation: 1,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(22),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GlassPanel(
                            tint: Color.alphaBlend(
                              accent.withValues(alpha: .13),
                              cardTint,
                            ),
                            radius: 14,
                            blurSigma: 0,
                            elevation: .45,
                            child: SizedBox(
                              width: 46,
                              height: 46,
                              child: Icon(
                                state.status == StockStatus.sold
                                    ? Icons.check_rounded
                                    : icon,
                                color: accent,
                                size: 25,
                              ),
                            ),
                          ),
                          const SizedBox(width: 13),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  record.name,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                if (record.strength.isNotEmpty ||
                                    record.brand.isNotEmpty)
                                  Text(
                                    [
                                      record.strength,
                                      record.brand,
                                    ].where((s) => s.isNotEmpty).join(' · '),
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
                            Icons.arrow_outward_rounded,
                            color: muted,
                            size: 20,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          StatusPill(state.label, color: accent),
                          if (record.expiry != null)
                            Text(
                              'EXP ${inputDateText(record.expiry!, monthOnly: record.expiryMonthOnly)}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: muted,
                                fontWeight: FontWeight.w500,
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
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(22)),
      );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strong ? 2 : 1
      ..color = base;
    canvas.drawPath(path, paint);
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
          background: Color(0xFFE5F3E8),
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
  if (context.mounted)
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
}
