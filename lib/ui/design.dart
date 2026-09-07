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

BoxDecoration depthDecoration(Color color, {double radius = 24}) {
  final dark = color.computeLuminance() < .15;
  return BoxDecoration(
    borderRadius: BorderRadius.circular(radius),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.alphaBlend(
          Colors.white.withValues(alpha: dark ? .06 : .42),
          color,
        ),
        color,
        Color.alphaBlend(ink.withValues(alpha: dark ? .06 : .025), color),
      ],
    ),
    border: Border.all(
      color: dark
          ? Colors.white.withValues(alpha: .12)
          : const Color(0xFFDCE9E0),
    ),
    boxShadow: [
      BoxShadow(
        color: ink.withValues(alpha: dark ? .17 : .07),
        blurRadius: 22,
        offset: const Offset(0, 9),
      ),
      BoxShadow(
        color: ink.withValues(alpha: .035),
        blurRadius: 3,
        offset: const Offset(0, 2),
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
    child: Container(
      width: size,
      height: size,
      decoration: depthDecoration(background, radius: size * .32),
      child: Icon(icon, color: color, size: size * .52),
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: i == current ? lime : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFD8E8DD)),
            ),
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
  colorScheme: ColorScheme.fromSeed(
    seedColor: ink,
    brightness: Brightness.light,
  ).copyWith(primary: ink, secondary: green, surface: canvas, error: red),
  scaffoldBackgroundColor: canvas,
  fontFamily: 'Manrope',
  fontFamilyFallback: const ['NotoSansDevanagari'],
  textTheme: const TextTheme(
    headlineLarge: TextStyle(
      fontSize: 34,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.1,
      color: ink,
    ),
    headlineMedium: TextStyle(
      fontSize: 27,
      fontWeight: FontWeight.w700,
      letterSpacing: -.7,
      color: ink,
    ),
    titleLarge: TextStyle(
      fontSize: 21,
      fontWeight: FontWeight.w700,
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
    backgroundColor: canvas,
    foregroundColor: ink,
    centerTitle: false,
    elevation: 0,
    scrolledUnderElevation: 0,
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xFFFBFDFC),
    floatingLabelStyle: const TextStyle(
      color: green,
      fontWeight: FontWeight.w700,
    ),
    helperMaxLines: 3,
    errorMaxLines: 3,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: Color(0xFFDDE6DF)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: Color(0xFFDDE6DF)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: green, width: 1.7),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(48, 52),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      elevation: 2,
      shadowColor: ink.withValues(alpha: .18),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 50),
      foregroundColor: ink,
      backgroundColor: Colors.white.withValues(alpha: .65),
      side: const BorderSide(color: Color(0xFFC9DDD0)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
    backgroundColor: Colors.white,
    selectedColor: lime,
    side: const BorderSide(color: Color(0xFFD5E5DA)),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    labelStyle: const TextStyle(
      color: ink,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
  ),
  dialogTheme: DialogThemeData(
    backgroundColor: canvas,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
  ),
  bottomSheetTheme: const BottomSheetThemeData(
    backgroundColor: canvas,
    surfaceTintColor: Colors.transparent,
    showDragHandle: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
  ),
  progressIndicatorTheme: const ProgressIndicatorThemeData(color: green),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: Colors.white,
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
  Widget build(BuildContext context) => Container(
    decoration: depthDecoration(color),
    child: Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
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
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(30),
    ),
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
          child: Material(
            color: Colors.white,
            elevation: 3,
            shadowColor: ink.withValues(alpha: .16),
            surfaceTintColor: Colors.transparent,
            borderRadius: BorderRadius.circular(22),
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
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: .09),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            state.status == StockStatus.sold
                                ? Icons.check_rounded
                                : icon,
                            color: accent,
                            size: 25,
                          ),
                        ),
                        const SizedBox(width: 13),
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
        Container(
          padding: const EdgeInsets.all(22),
          decoration: const BoxDecoration(
            color: Color(0xFFE6EEE3),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.inventory_2_outlined, size: 36, color: green),
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
