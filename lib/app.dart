import 'package:flutter/material.dart';

import 'state/pharmacy_controller.dart';
import 'domain/inventory.dart';
import 'ui/design.dart';
import 'ui/home_screen.dart';
import 'ui/search_screen.dart';
import 'ui/ai_screen.dart';
import 'ui/stats_screen.dart';
import 'ui/profile_screen.dart';

class PharmacyApp extends StatefulWidget {
  const PharmacyApp({super.key, required this.controller});
  final PharmacyController controller;
  @override
  State<PharmacyApp> createState() => _PharmacyAppState();
}

class _PharmacyAppState extends State<PharmacyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.controller.refreshDay();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Aaris Pharmacy',
    debugShowCheckedModeBanner: false,
    theme: pharmacyTheme(),
    home: _Shell(controller: widget.controller),
  );
}

class _Shell extends StatefulWidget {
  const _Shell({required this.controller});
  final PharmacyController controller;
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  int tab = 0;
  final _visited = <int, Widget>{};

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
        2 => AiScreen(controller: c),
        3 => StatsScreen(controller: c),
        _ => ProfileScreen(controller: c),
      },
    );
    return Scaffold(
      body: SafeArea(
        child: Center(
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
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(
              color: ink.withValues(alpha: .08),
              blurRadius: 22,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (index) => setState(() => tab = index),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.inventory_2_outlined),
                selectedIcon: Icon(Icons.inventory_2_rounded),
                label: 'Database',
              ),
              NavigationDestination(
                icon: Icon(Icons.auto_awesome_outlined),
                selectedIcon: Icon(Icons.auto_awesome),
                label: 'AI',
              ),
              NavigationDestination(
                icon: Icon(Icons.calculate_outlined),
                selectedIcon: Icon(Icons.calculate_rounded),
                label: 'Calculator',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(Icons.person_rounded),
                label: 'Profile',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
