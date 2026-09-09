import 'package:flutter/material.dart';

import '../state/pharmacy_controller.dart';
import '../services/ai_service.dart';
import 'backup_screen.dart';
import 'design.dart';
import 'home_screen.dart';
import 'removed_stock_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, required this.controller});
  final PharmacyController controller;

  Future<void> _removeAll(BuildContext context) async {
    final review = controller.reviewArchiveAll();
    if (review.activeCount == 0) {
      showSaved(context, 'There is no active inventory to remove.');
      return;
    }
    final first = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove all inventory?'),
        content: Text(
          '${review.activeCount} active stock ${review.activeCount == 1 ? 'entry' : 'entries'} will be removed from search, dashboard and totals. They remain in removed history so you can restore them. The exact reviewed inventory snapshot must still match when you confirm.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue', style: TextStyle(color: red)),
          ),
        ],
      ),
    );
    if (first != true || !context.mounted) return;
    var phrase = '';
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Confirm removal'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Final check: this action targets the ${review.activeCount} stock ${review.activeCount == 1 ? 'entry' : 'entries'} reviewed before the first confirmation. If anything changed in inventory since then, Aaris will reject the operation instead of removing a different snapshot.',
              ),
              const SizedBox(height: 14),
              TextField(
                autofocus: true,
                onChanged: (s) => setState(() => phrase = s),
                decoration: const InputDecoration(
                  labelText: 'Type REMOVE ALL',
                  hintText: 'REMOVE ALL',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: phrase == 'REMOVE ALL'
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: const Text('Remove all'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && context.mounted) {
      try {
        await controller.applyArchiveAll(review);
        if (context.mounted) {
          showSaved(
            context,
            '${review.activeCount} stock ${review.activeCount == 1 ? 'entry' : 'entries'} removed. Undo is available in Activity.',
          );
        }
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => ListView(
      key: const PageStorageKey('profile-scroll'),
      padding: const EdgeInsets.fromLTRB(22, 26, 22, 30),
      children: [
        const ScreenIntro(
          title: 'Your pharmacy',
          message: 'Manage warnings, backups and your saved activity.',
          icon: Icons.local_pharmacy_outlined,
        ),
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const DepthIcon(
                Icons.local_pharmacy_rounded,
                background: primarySoft,
                color: ink,
                size: 64,
              ),
              const SizedBox(height: 18),
              Text(
                'Aaris Pharmacy',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'A private workspace on this device. Your inventory works offline; AI connections are optional.',
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 14),
              const StatusPill('No account required'),
            ],
          ),
        ),
        const SectionHeading('Make it yours'),
        Surface(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              ListTile(
                leading: const DepthIcon(Icons.tune_rounded, size: 40),
                title: const Text('Expiry warning windows'),
                subtitle: Text(
                  '${controller.settings.shortDays} days · ${controller.settings.months} months',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showWarningSettings(context, controller),
              ),
              ListTile(
                leading: const DepthIcon(Icons.history_rounded, size: 40),
                title: const Text('Activity & Undo'),
                subtitle: const Text('See changes and undo the latest one'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ActivityScreen(controller: controller),
                  ),
                ),
              ),
              ListTile(
                leading: const DepthIcon(
                  Icons.archive_outlined,
                  size: 40,
                  color: amber,
                  background: warningSoft,
                ),
                title: const Text('Removed stock'),
                subtitle: const Text(
                  'Search history and review an exact row before restoring',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => RemovedStockScreen(controller: controller),
                  ),
                ),
              ),
              ListTile(
                leading: const DepthIcon(Icons.shield_outlined, size: 40),
                title: const Text('Backup & Restore'),
                subtitle: const Text('Full local data backup'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => BackupScreen(controller: controller),
                  ),
                ),
              ),
              ListTile(
                leading: const DepthIcon(Icons.ios_share_rounded, size: 40),
                title: const Text('Export pharmacy inventory'),
                subtitle: const Text('TXT facts and AI import instructions'),
                onTap: () async {
                  try {
                    await sharePharmacy(controller.export());
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
            ],
          ),
        ),
        const SectionHeading('About your data'),
        const Surface(
          child: Text(
            'Medicine name is required; other details can stay unknown. Inventory costs use the same unit as stock quantity; sale revenue is recorded separately. Expiry is calculated from your phone’s current date. API keys are excluded from all inventory exports.\n\nInventory is stored locally. Keep exports somewhere you trust before changing phones or uninstalling. Camera OCR and device speech require the relevant permissions.\n\nVersion 1.0.0',
            style: TextStyle(fontSize: 13, color: muted),
          ),
        ),
        const SizedBox(height: 22),
        OutlinedButton.icon(
          onPressed: () => _removeAll(context),
          icon: const Icon(Icons.archive_outlined, color: red),
          label: const Text(
            'Remove all inventory',
            style: TextStyle(color: red),
          ),
        ),
      ],
    ),
  );
}

class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key, required this.controller});
  final PharmacyController controller;

  Future<void> _undoLast(BuildContext context) async {
    if (!controller.canUndo || controller.snapshot.events.isEmpty) return;
    final event = controller.snapshot.events.first;
    final label = '${event['label']}';
    final revision = event['revision'];
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Undo the latest change?'),
            content: Text(
              'Aaris will reverse the latest saved change only:\n\n$label\n\nRevision $revision is still current. If inventory changes before the commit, the undo is rejected instead of touching a newer state.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.undo_rounded),
                label: const Text('Undo latest change'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !context.mounted) return;
    try {
      await controller.undo();
      if (context.mounted) showSaved(context, 'The last change was undone.');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Activity & Undo')),
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(22),
        children: [
          const ScreenIntro(
            title: 'Your recent activity',
            message:
                'See the latest 200 changes. Undo reverses only the most recent current change, including an approved import.',
            icon: Icons.history_rounded,
          ),
          FilledButton.icon(
            onPressed: controller.canUndo ? () => _undoLast(context) : null,
            icon: const Icon(Icons.undo_rounded),
            label: const Text('Review & undo last change'),
          ),
          const SizedBox(height: 22),
          if (controller.snapshot.events.isEmpty)
            const EmptyState(
              title: 'A clean slate',
              message: 'Your saved changes will appear here.',
            ),
          ...controller.snapshot.events.map(
            (e) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Surface(
                padding: const EdgeInsets.all(18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      e['undone'] == true
                          ? Icons.undo_rounded
                          : Icons.check_circle_outline,
                      color: green,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${e['label']}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${e['time']}'
                                .replaceFirst('T', ' ')
                                .split('.')
                                .first,
                            style: const TextStyle(fontSize: 12, color: muted),
                          ),
                          if (e['undone'] == true)
                            const Text(
                              'Undone',
                              style: TextStyle(color: amber, fontSize: 12),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
