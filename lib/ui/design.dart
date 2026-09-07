import 'package:flutter/material.dart';
import '../domain/medicine.dart';
import '../domain/inventory.dart';

const ink = Color(0xFF173B34);
const muted = Color(0xFF60746C);
const canvas = Color(0xFFF4F7F4);
const lime = Color(0xFFD9F39A);
const green = Color(0xFF237A55);
const red = Color(0xFFBD3F3C);
const amber = Color(0xFF9C680D);

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
    fillColor: Colors.white,
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
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  ),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: Colors.white,
    indicatorColor: lime,
    labelTextStyle: WidgetStateProperty.all(
      const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
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
    padding: padding,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: ink.withValues(alpha: .06)),
      boxShadow: [
        BoxShadow(
          color: ink.withValues(alpha: .045),
          blurRadius: 20,
          offset: const Offset(0, 8),
        ),
      ],
    ),
    child: child,
  );
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.action});
  final String title;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 26, bottom: 14),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (action != null) action!,
      ],
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
      _ => Icons.medication_liquid_outlined,
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
                            'EXP ${dateText(record.expiry!)}',
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
