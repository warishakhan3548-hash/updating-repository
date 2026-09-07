import 'package:flutter/material.dart';
import '../state/pharmacy_controller.dart';
import '../services/ai_service.dart';
import 'design.dart';
import 'home_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, required this.controller});
  final PharmacyController controller;
  Future<void> _removeAll(BuildContext context) async {
    final first = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove all inventory?'),
        content: const Text(
          'All stock entries will be removed from search, dashboard and totals. They remain in removed history so you can restore them.',
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
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Confirm removal'),
          content: TextField(
            onChanged: (s) => setState(() => phrase = s),
            decoration: const InputDecoration(
              labelText: 'Type REMOVE ALL',
              hintText: 'REMOVE ALL',
            ),
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
    if (confirmed == true) {
      try {
        await controller.archiveAll();
        if (context.mounted)
          showSaved(
            context,
            'Inventory removed. Undo is available in Activity.',
          );
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(22, 26, 22, 30),
    children: [
      Text('Your pharmacy', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 24),
      Surface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: const BoxDecoration(
                color: lime,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.local_pharmacy_rounded,
                color: ink,
                size: 35,
              ),
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
              leading: const Icon(Icons.tune_rounded),
              title: const Text('Expiry warning windows'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showWarningSettings(context, controller),
            ),
            ListTile(
              leading: const Icon(Icons.history_rounded),
              title: const Text('Activity & Undo'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ActivityScreen(controller: controller),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('Removed stock'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => _RemovedScreen(controller: controller),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
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
          'Medicine name is required; other details can stay unknown. Prices use the same unit as stock quantity. Expiry is calculated from your phone’s current date. API keys are excluded from all inventory exports.\n\nInventory is stored locally. Keep exports somewhere you trust before changing phones or uninstalling. Camera OCR and device speech require the relevant permissions.\n\nVersion 1.0.0',
          style: TextStyle(fontSize: 13, color: muted),
        ),
      ),
      const SizedBox(height: 22),
      OutlinedButton.icon(
        onPressed: () => _removeAll(context),
        icon: const Icon(Icons.archive_outlined, color: red),
        label: const Text('Remove all inventory', style: TextStyle(color: red)),
      ),
    ],
  );
}

class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key, required this.controller});
  final PharmacyController controller;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Activity & Undo')),
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(22),
        children: [
          const Text(
            'Latest 200 changes. Undo applies to the most recent saved change, including an entire approved AI import.',
            style: TextStyle(color: muted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: controller.canUndo
                ? () async {
                    try {
                      await controller.undo();
                      if (context.mounted)
                        showSaved(context, 'The last change was undone.');
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  }
                : null,
            icon: const Icon(Icons.undo_rounded),
            label: const Text('Undo last change'),
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

class _RemovedScreen extends StatelessWidget {
  const _RemovedScreen({required this.controller});
  final PharmacyController controller;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Removed stock')),
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final records = controller.records.where((m) => m.archived).toList();
        return ListView(
          padding: const EdgeInsets.all(22),
          children: [
            if (records.isEmpty)
              const EmptyState(
                title: 'No removed stock',
                message:
                    'Removed entries will appear here and can be restored.',
              ),
            ...records.map(
              (m) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Surface(
                  padding: const EdgeInsets.all(10),
                  child: ListTile(
                    title: Text(m.title),
                    subtitle: Text(m.address),
                    trailing: TextButton(
                      onPressed: () async {
                        try {
                          await controller.restoreArchived(m.id);
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                      child: const Text('Restore'),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}
