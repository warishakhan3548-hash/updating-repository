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
  final _input = TextEditingController();
  BackupReview? _review;
  bool _sharing = false;
  bool _reading = false;
  bool _restoring = false;
  String _error = '';

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await _service.share(widget.controller.createBackup());
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _pick() async {
    if (_reading) return;
    setState(() => _reading = true);
    try {
      final text = await _service.pickBackupText();
      if (text != null && mounted) {
        _input.text = text;
        await _reviewInput();
      }
    } on MissingPluginException {
      if (mounted) {
        setState(
          () => _error = 'File selection is available in the Android app. Paste backup JSON here on this device.',
        );
      }
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    _input.text = data?.text ?? '';
    setState(() => _review = null);
  }

  Future<void> _reviewInput() async {
    if (_restoring || (_reading && _input.text.isEmpty)) return;
    final input = _input.text;
    setState(() {
      _reading = true;
      _error = '';
      _review = null;
    });
    try {
      final review = await widget.controller.reviewBackup(input);
      if (mounted && _input.text == input) setState(() => _review = review);
    } catch (error) {
      if (mounted && _input.text == input) {
        setState(
          () => _error = error.toString().replaceFirst(
            RegExp(r'^(FormatException|Bad state):\s*'),
            '',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _restore() async {
    final review = _review;
    if (review == null || _restoring) return;
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
                  'The backup becomes the active inventory. Current medicines not present in it move to Removed stock; they are not silently destroyed. Current sale events not in the backup are replaced.',
                ),
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
              const Icon(Icons.shield_outlined, color: lime, size: 30),
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
                'Export medicines, removed stock, warning settings and aggregate sales. The file never contains an AI API key.',
                style: TextStyle(color: Color(0xFFC5D8CC), fontSize: 12),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: lime,
                  foregroundColor: ink,
                ),
                onPressed: _sharing ? null : () => unawaited(_share()),
                icon: const Icon(Icons.ios_share_rounded),
                label: Text(_sharing ? 'Preparing…' : 'Export full backup'),
              ),
            ],
          ),
        ),
        const SectionHeading('Restore a backup'),
        FlowSteps(const [
          'Choose file',
          'Review',
          'Restore',
        ], current: _review == null ? 0 : 1),
        const Text(
          'Choose your Aaris backup file, or paste its contents. Review the summary before you restore.',
          style: TextStyle(color: muted, fontSize: 13),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: _reading ? null : () => unawaited(_pick()),
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Choose backup file'),
            ),
            OutlinedButton.icon(
              onPressed: _reading ? null : () => unawaited(_paste()),
              icon: const Icon(Icons.content_paste_rounded),
              label: const Text('Paste'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _input,
          minLines: 5,
          maxLines: 10,
          maxLength: maxBackupCharacters,
          onChanged: (_) => setState(() => _review = null),
          decoration: const InputDecoration(
            hintText: 'Aaris Pharmacy backup JSON',
            counterText: '',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _reading || _input.text.trim().isEmpty
              ? null
              : () => unawaited(_reviewInput()),
          icon: const Icon(Icons.fact_check_outlined),
          label: Text(_reading ? 'Checking backup…' : 'Review backup'),
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Surface(
              color: const Color(0xFFFFEDEA),
              child: Text(_error, style: const TextStyle(color: red)),
            ),
          ),
        if (_review != null) ...[
          const SectionHeading('Backup summary'),
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_review!.activeMedicines} active stock entries',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text('${_review!.removedMedicines} removed entries'),
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
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _restoring ? null : () => unawaited(_restore()),
            icon: const Icon(Icons.restore_rounded),
            label: Text(_restoring ? 'Restoring…' : 'Restore reviewed backup'),
          ),
        ],
      ],
    ),
  );
}
