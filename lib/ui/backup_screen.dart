import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/backup.dart';
import '../services/backup_service.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.controller});

  final PharmacyController controller;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _service = BackupService();
  BackupReview? _review;
  BackupFileReference? _pickedFile;
  BackupExportResult? _lastExport;
  bool _sharing = false;
  bool _reading = false;
  bool _restoring = false;
  String _error = '';

  Future<void> _share() async {
    if (_sharing) return;
    setState(() {
      _sharing = true;
      _error = '';
    });
    try {
      final result = await _service.exportAndShare(
        widget.controller.createBackup(),
      );
      if (!mounted) return;
      setState(() => _lastExport = result);
      final location = result.savedLocation == null
          ? 'a temporary share file'
          : result.savedLocation!;
      showSaved(
        context,
        result.shareOpened
            ? 'Backup saved to $location. Share menu opened.'
            : 'Backup saved to $location.',
      );
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _pick() async {
    if (_reading || _restoring) return;
    setState(() {
      _reading = true;
      _error = '';
      _review = null;
      _pickedFile = null;
    });
    try {
      final picked = await _service.pickBackupFile();
      if (!mounted || picked == null) return;
      setState(() => _pickedFile = picked);
      await _reviewFile(picked);
    } on MissingPluginException {
      if (mounted) {
        setState(
          () => _error =
              'The Android document picker is unavailable on this device.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst(
            RegExp(r'^(FormatException|Bad state|StateError):\s*'),
            '',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _reviewFile(BackupFileReference picked) async {
    final backup = await _service.readBackupFile(picked);
    if (!mounted || _pickedFile?.path != picked.path) return;

    final current = widget.controller.snapshot;
    final revision = current.revision;
    final impact = await compareBackupImpactCooperatively(
      backup: backup,
      currentRecords: current.records,
      currentSuppliers: current.suppliers,
      currentSales: current.sales,
      currentSettings: current.settings,
      currentSoldValue: current.soldValue,
      currentUnknownSold: current.unknownSold,
    );
    if (!mounted || _pickedFile?.path != picked.path) return;
    if (widget.controller.snapshot.revision != revision) {
      setState(
        () => _error =
            'Inventory changed while this backup was being reviewed. Choose the file again to compare it with the latest master stock.',
      );
      return;
    }

    setState(
      () => _review = BackupReview(
        backup: backup,
        currentRevision: revision,
        impact: impact,
      ),
    );
  }

  String _fileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(1)} GB';
  }

  Widget _impactRow(IconData icon, String text, {Color color = ink}) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: 13),
          ),
        ),
      ],
    ),
  );

  Future<void> _restore() async {
    final review = _review;
    if (review == null || _restoring) return;
    final impact = review.impact;
    var phrase = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Restore this backup?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'The reviewed backup becomes the active inventory. Current stock missing from it moves to Removed stock instead of being silently destroyed.',
                ),
                if (impact.activeEntriesMovingToRemoved > 0) ...[
                  const SizedBox(height: 14),
                  Text(
                    '${impact.activeEntriesMovingToRemoved} current active ${impact.activeEntriesMovingToRemoved == 1 ? 'entry moves' : 'entries move'} to Removed stock.',
                    style: const TextStyle(
                      color: amber,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                if (impact.removedSaleEvents > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${impact.removedSaleEvents} current sale ${impact.removedSaleEvents == 1 ? 'event is' : 'events are'} not in this backup and will be replaced.',
                    style: const TextStyle(
                      color: amber,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                if (review.legacyFormat) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'This is an older backup format. Its pharmacy facts were validated, but it predates the content-integrity seal used by current backups.',
                    style: TextStyle(color: amber, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 16),
                const Text(
                  'Export your current backup first if you may need it later.',
                  style: TextStyle(color: amber, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                TextField(
                  onChanged: (value) => setState(() => phrase = value),
                  decoration: const InputDecoration(
                    labelText: 'Type RESTORE',
                    hintText: 'RESTORE',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: phrase == 'RESTORE'
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: const Text('Restore backup'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _restoring = true);
    try {
      await widget.controller.restoreBackup(review);
      if (mounted) {
        Navigator.pop(context);
        showSaved(context, 'Backup restored. All live views are updated.');
      }
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Backup & Restore')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 30),
      children: [
        const ScreenIntro(
          title: 'Keep a safe copy',
          message:
              'Save a full backup, or review a saved file before restoring it.',
          icon: Icons.shield_outlined,
        ),
        Surface(
          color: ink,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.shield_outlined, color: primarySoft, size: 30),
              const SizedBox(height: 14),
              const Text(
                'Keep your pharmacy portable',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Creates a verified .txt backup, saves a local copy first, then opens the share menu. Medicines, removed stock, supplier details, warning settings and aggregate sales are included; AI API keys are never included.',
                style: TextStyle(color: inverseMuted, fontSize: 12),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: primarySoft,
                  foregroundColor: ink,
                ),
                onPressed: _sharing ? null : () => unawaited(_share()),
                icon: const Icon(Icons.ios_share_rounded),
                label: Text(_sharing ? 'Creating backup…' : 'Export full backup'),
              ),
            ],
          ),
        ),
        if (_lastExport != null) ...[
          const SizedBox(height: 10),
          Surface(
            color: primary.withAlpha(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.check_circle_outline_rounded, color: primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "${_lastExport!.fileName}\n${_fileSize(_lastExport!.sizeBytes)}"
                    " · ${_lastExport!.savedLocation ?? 'share file ready'}"
                    "${_lastExport!.warning == null ? '' : '\n${_lastExport!.warning}'}",
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SectionHeading('Restore a backup'),
        FlowSteps(
          const ['Choose file', 'Review', 'Restore'],
          current: _restoring ? 2 : _review == null ? 0 : 1,
        ),
        const Text(
          'Choose the backup file directly. Aaris reads and verifies the file without pasting its JSON into the screen, then prepares the restore review automatically.',
          style: TextStyle(color: muted, fontSize: 13),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _reading ? null : () => unawaited(_pick()),
            icon: const Icon(Icons.file_open_outlined),
            label: Text(
              _reading ? 'Reading & verifying backup…' : 'Import backup file',
            ),
          ),
        ),
        if (_pickedFile != null) ...[
          const SizedBox(height: 12),
          Surface(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _review != null
                      ? Icons.verified_file_outlined
                      : Icons.description_outlined,
                  color: _review != null ? primary : muted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _pickedFile!.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: ink,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        "${_fileSize(_pickedFile!.sizeBytes)} · "
                        "${_review != null ? 'Ready for next step' : _reading ? 'Checking file…' : 'Not reviewed'}",
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Surface(
              color: errorSoft,
              child: Text(_error, style: const TextStyle(color: red)),
            ),
          ),
        if (_review != null) ...[
          const SectionHeading('Backup summary'),
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _review!.integrityVerified
                          ? Icons.verified_user_outlined
                          : Icons.history_rounded,
                      color: _review!.integrityVerified ? primary : amber,
                      size: 20,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        _review!.integrityVerified
                            ? 'Integrity verified'
                            : 'Legacy backup · validated without an integrity seal',
                        style: TextStyle(
                          color: _review!.integrityVerified ? primary : amber,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  '${_review!.activeMedicines} active stock entries',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text('${_review!.removedMedicines} removed entries'),
                Text('${_review!.suppliers} suppliers'),
                Text('${_review!.sales} aggregate sale events'),
                Text(
                  'Warnings: ${_review!.backup.settings.shortDays} days · ${_review!.backup.settings.months} months',
                ),
                const SizedBox(height: 8),
                Text(
                  'Created ${_review!.backup.createdAt.toLocal().toString().split('.').first}',
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SectionHeading('Restore impact'),
          Surface(
            child: Builder(
              builder: (context) {
                final impact = _review!.impact;
                if (!impact.hasMaterialChange) {
                  return _impactRow(
                    Icons.check_circle_outline_rounded,
                    'No material stock, supplier, sales, warning or sold-total difference was found against the reviewed live snapshot.',
                    color: primary,
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (impact.newStockEntries > 0)
                      _impactRow(
                        Icons.add_box_outlined,
                        '${impact.newStockEntries} new stock ${impact.newStockEntries == 1 ? 'entry' : 'entries'} will be added.',
                      ),
                    if (impact.changedStockEntries > 0)
                      _impactRow(
                        Icons.edit_note_rounded,
                        '${impact.changedStockEntries} existing stock ${impact.changedStockEntries == 1 ? 'entry has' : 'entries have'} different saved facts in this backup.',
                      ),
                    if (impact.reactivatedStockEntries > 0)
                      _impactRow(
                        Icons.restore_from_trash_outlined,
                        '${impact.reactivatedStockEntries} removed stock ${impact.reactivatedStockEntries == 1 ? 'entry returns' : 'entries return'} to active stock.',
                      ),
                    if (impact.activeEntriesMovingToRemoved > 0)
                      _impactRow(
                        Icons.inventory_2_outlined,
                        '${impact.activeEntriesMovingToRemoved} current active ${impact.activeEntriesMovingToRemoved == 1 ? 'entry moves' : 'entries move'} to Removed stock because it is not in this backup.',
                        color: amber,
                      ),
                    if (impact.newSuppliers > 0 ||
                        impact.changedSuppliers > 0 ||
                        impact.removedSuppliers > 0)
                      _impactRow(
                        Icons.local_shipping_outlined,
                        'Suppliers: ${impact.newSuppliers} new · ${impact.changedSuppliers} changed · ${impact.removedSuppliers} removed.',
                        color: impact.removedSuppliers > 0 ? amber : ink,
                      ),
                    if (impact.newSaleEvents > 0 ||
                        impact.changedSaleEvents > 0 ||
                        impact.removedSaleEvents > 0)
                      _impactRow(
                        Icons.receipt_long_outlined,
                        'Sale history: ${impact.newSaleEvents} new · ${impact.changedSaleEvents} changed · ${impact.removedSaleEvents} removed.',
                        color: impact.removedSaleEvents > 0 ? amber : ink,
                      ),
                    if (impact.warningSettingsChange)
                      _impactRow(
                        Icons.notifications_active_outlined,
                        'Expiry warning windows will change to ${_review!.backup.settings.shortDays} days and ${_review!.backup.settings.months} months.',
                      ),
                    if (impact.soldTotalsChange)
                      _impactRow(
                        Icons.calculate_outlined,
                        'Saved sold-stock totals will be restored from this backup.',
                      ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _restoring ? null : () => unawaited(_restore()),
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(_restoring ? 'Restoring…' : 'Next'),
          ),
        ],
      ],
    ),
  );
}
