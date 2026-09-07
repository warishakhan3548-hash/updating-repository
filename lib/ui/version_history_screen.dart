import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/medicine.dart';
import '../domain/date_input.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';

class VersionHistoryScreen extends StatelessWidget {
  const VersionHistoryScreen({
    super.key,
    required this.controller,
    required this.medicineId,
  });

  final PharmacyController controller;
  final String medicineId;

  Future<void> _restore(BuildContext context, MedicineVersion version) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore this version?'),
        content: Text(
          'Medicine facts will return to the state saved before “${version.label}”. Dashboard, search and Tracking will recalculate immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore version'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await controller.restoreVersion(version);
      if (context.mounted) Navigator.pop(context, true);
    } catch (error) {
      if (context.mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final versions = controller.versionsFor(medicineId);
    return Scaffold(
      appBar: AppBar(title: const Text('Version history')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(22, 8, 22, 30),
        children: [
          const ScreenIntro(
            title: 'Previous versions',
            message: 'Compare saved details and restore the version you need. Each restore is recorded.',
            icon: Icons.history_rounded,
          ),
          if (versions.isEmpty)
            const EmptyState(
              title: 'No earlier version',
              message: 'Edits to this stock entry will appear here.',
            ),
          for (final version in versions)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Surface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            version.record.title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        StatusPill('v${version.record.revision}'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Before: ${version.label}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      version.time.toLocal().toString().split('.').first,
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 7,
                      children: [
                        _Fact(
                          'Expiry',
                          version.record.expiry == null
                              ? 'Not provided'
                              : inputDateText(
                                  version.record.expiry!,
                                  monthOnly: version.record.expiryMonthOnly,
                                ),
                        ),
                        _Fact(
                          'Quantity',
                          version.record.quantity?.toString() ?? 'Unknown',
                        ),
                        _Fact(
                          'Unit cost',
                          version.record.unitPricePaise == null
                              ? 'Unknown'
                              : money(version.record.unitPricePaise!),
                        ),
                        _Fact(
                          'Location',
                          version.record.address.isEmpty
                              ? 'Not provided'
                              : version.record.address,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_restore(context, version)),
                      icon: const Icon(Icons.restore_rounded),
                      label: const Text('Restore this version'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 230),
    child: Text(
      '$label: $value',
      style: const TextStyle(fontSize: 11, color: muted),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    ),
  );
}
