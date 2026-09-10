import 'dart:async';

import 'package:flutter/material.dart';

import 'domain/app_brain.dart';
import 'domain/inventory.dart';
import 'state/autopilot_supervisor.dart';
import 'state/pharmacy_controller.dart';
import 'ui/attention_screen.dart';
import 'ui/autopilot_beacon.dart';
import 'ui/brain_screen.dart';
import 'ui/design.dart';
import 'ui/home_screen.dart';
import 'ui/profile_screen.dart';
import 'ui/search_screen.dart';
import 'ui/stats_screen.dart';

ThemeData _appTheme() {
  final base = pharmacyTheme();
  return base.copyWith(
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      floatingLabelBehavior: FloatingLabelBehavior.never,
      labelStyle: const TextStyle(color: muted),
      floatingLabelStyle: const TextStyle(color: muted),
    ),
  );
}

class PharmacyApp extends StatefulWidget {
  const PharmacyApp({super.key, required this.controller});
  final PharmacyController controller;
  @override
  State<PharmacyApp> createState() => _PharmacyAppState();
}

class _PharmacyAppState extends State<PharmacyApp> with WidgetsBindingObserver {
  late AarisAutopilotSupervisor _autopilot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _autopilot = AarisAutopilotSupervisor(widget.controller);
    _autopilot.setLifecycleActive(_isForeground);
  }

  bool get _isForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didUpdateWidget(covariant PharmacyApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _autopilot.dispose();
      _autopilot = AarisAutopilotSupervisor(widget.controller);
      _autopilot.setLifecycleActive(_isForeground);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh the civil business day first; the resumed Autopilot pass then
      // observes the final authoritative day/revision instead of doing two
      // expensive isolate evaluations.
      widget.controller.refreshDay();
      _autopilot.setLifecycleActive(true);
      return;
    }
    _autopilot.setLifecycleActive(false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autopilot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Aaris Pharmacy',
    debugShowCheckedModeBanner: false,
    theme: _appTheme(),
    builder: (context, child) =>
        PharmacyBackdrop(child: child ?? const SizedBox.shrink()),
    home: _Shell(controller: widget.controller, autopilot: _autopilot),
  );
}

class _Shell extends StatefulWidget {
  const _Shell({required this.controller, required this.autopilot});
  final PharmacyController controller;
  final AarisAutopilotSupervisor autopilot;
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  int tab = 0;
  final _visited = <int, Widget>{};

  void _openSection(AppSection section) {
    final next = switch (section) {
      AppSection.home => 0,
      AppSection.stock => 1,
      AppSection.ai => 2,
      AppSection.calculator => 3,
      AppSection.profile => 4,
    };
    if (next != tab) setState(() => tab = next);
  }

  void _openAutopilotQueue() {
    if (!mounted) return;
    widget.autopilot.refreshNow();
    unawaited(
      Navigator.of(context)
          .push<void>(
            MaterialPageRoute(
              builder: (_) => AttentionScreen(controller: widget.controller),
            ),
          )
          .whenComplete(() {
            if (mounted) widget.autopilot.refreshNow();
          }),
    );
  }

  @override
  void didUpdateWidget(covariant _Shell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _visited.clear();
      tab = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    // Keep visited tab drafts and scroll position; initialize each tab only once.
    _visited.putIfAbsent(
      tab,
      () => switch (tab) {
        0 => HomeScreen(
          controller: c,
          onDatabase: () => setState(() => tab = 1),
        ),
        1 => SearchScreen(
          controller: c,
          scope: SearchScope.all,
          database: true,
          embedded: true,
        ),
        2 => BrainScreen(controller: c, onOpenSection: _openSection),
        3 => StatsScreen(controller: c),
        _ => ProfileScreen(controller: c),
      },
    );

    return Scaffold(
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: IndexedStack(
                  index: tab,
                  children: [
                    for (var index = 0; index < 5; index++)
                      TickerMode(
                        enabled: index == tab,
                        child: _visited[index] ?? const SizedBox.shrink(),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 12,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: AarisAutopilotBeacon(
                  supervisor: widget.autopilot,
                  onOpenWorkQueue: _openAutopilotQueue,
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: GlassPanel(
          tint: Colors.white,
          radius: 24,
          blurSigma: 10,
          elevation: .65,
          child: AnimatedBuilder(
            animation: widget.autopilot,
            builder: (context, _) {
              final digest = widget.autopilot.digest;
              final issues = digest.isReady ? digest.navigationBadgeCount : 0;
              final badgeCount = issues > 99 ? 99 : issues;
              return NavigationBar(
                selectedIndex: tab,
                onDestinationSelected: (index) => setState(() => tab = index),
                destinations: [
                  const NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home_rounded),
                    label: 'Home',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.inventory_2_outlined),
                    selectedIcon: Icon(Icons.inventory_2_rounded),
                    label: 'Stock',
                  ),
                  NavigationDestination(
                    icon: Badge.count(
                      count: badgeCount,
                      isLabelVisible: issues > 0,
                      child: const Icon(Icons.psychology_alt_outlined),
                    ),
                    selectedIcon: Badge.count(
                      count: badgeCount,
                      isLabelVisible: issues > 0,
                      child: const Icon(Icons.psychology_alt_rounded),
                    ),
                    label: 'Aaris Brain',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.calculate_outlined),
                    selectedIcon: Icon(Icons.calculate_rounded),
                    label: 'Calculator',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.person_outline_rounded),
                    selectedIcon: Icon(Icons.person_rounded),
                    label: 'Profile',
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
