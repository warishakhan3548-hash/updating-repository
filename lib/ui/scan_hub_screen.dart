import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/medicine.dart';
import '../state/pharmacy_brain_controller.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'editor_screen.dart';
import 'import_screen.dart';
import 'scanner_screen.dart';

class ScanHubScreen extends StatefulWidget {
  const ScanHubScreen({super.key, required this.controller});

  final PharmacyController controller;

  @override
  State<ScanHubScreen> createState() => _ScanHubScreenState();
}

class _ScanHubScreenState extends State<ScanHubScreen> {
  late final PharmacyBrainController _brain = PharmacyBrainController(
    widget.controller,
  );
  ScanResult? _lastScan;
  PharmacyBrainOutcome? _outcome;
  bool _busy = false;
  String _message = '', _error = '';

  Future<void> _scan() async {
    if (_busy) return;
    final result = await Navigator.of(context).push<ScanResult>(
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (!mounted || result == null) return;
    final query = result.barcode.trim().isNotEmpty
        ? result.barcode.trim()
        : result.text.trim();
    setState(() {
      _busy = true;
      _lastScan = result;
      _outcome = null;
      _message = '';
      _error = '';
    });
    try {
      if (query.isEmpty) {
        setState(
          () => _message =
              'No searchable barcode/text was captured. Review the pack and add it manually if needed.',
        );
        return;
      }
      final outcome = await _brain.interpret('find $query');
      if (!mounted) return;
      final exact = outcome.exact;
      if (exact != null) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => EditorScreen(
              controller: widget.controller,
              record: exact.record,
            ),
          ),
        );
        if (!mounted) return;
        setState(() {
          _outcome = null;
          _message = 'Exact inventory stock opened from the scan.';
        });
        return;
      }
      setState(() {
        _outcome = outcome;
        _message = outcome.message;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openMedicine(Medicine medicine) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => EditorScreen(controller: widget.controller, record: medicine),
      ),
    );
  }

  Future<void> _addFromScan() async {
    final scan = _lastScan;
    if (scan == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => EditorScreen(
          controller: widget.controller,
          barcode: scan.barcode,
          ocrText: scan.text,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _outcome?.candidates ?? const <PharmacyBrainCandidate>[];
    return ListView(
      key: const PageStorageKey('scan-hub-scroll'),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: [
        const ScreenIntro(
          title: 'Scan',
          message:
              'Barcode + OCR identify existing stock first. Ambiguous batches always require your choice before editing.',
          icon: Icons.qr_code_scanner_rounded,
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                primary.withValues(alpha: .11),
                const Color(0xFF7857D8).withValues(alpha: .08),
              ],
            ),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: primary.withValues(alpha: .12)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const DepthIcon(Icons.document_scanner_outlined, size: 48),
              const SizedBox(height: 14),
              const Text(
                'Fast medicine capture',
                style: TextStyle(
                  color: ink,
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'The scanner searches your local database before creating anything new, which helps prevent duplicate stock entries.',
                style: TextStyle(color: muted, fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _scan,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.qr_code_scanner_rounded),
                  label: Text(_busy ? 'Matching stock…' : 'Scan medicine'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => ImportCenterScreen(controller: widget.controller),
                    ),
                  ),
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: const Text('Import multiple medicines / media'),
        ),
        if (_message.isNotEmpty) ...[
          const SizedBox(height: 16),
          _ScanMessage(text: _message),
        ],
        if (_error.isNotEmpty) ...[
          const SizedBox(height: 16),
          _ScanMessage(text: _error, error: true),
        ],
        if (candidates.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            'Choose the exact stock entry',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          const Text(
            'The scan resembles more than one medicine/batch. Aaris will not guess.',
            style: TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          for (final candidate in candidates)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                onTap: () => _openMedicine(candidate.record),
                leading: const Icon(Icons.medication_outlined, color: primary),
                title: Text(candidate.record.title),
                subtitle: Text(
                  [
                    candidate.hit.reason,
                    if (candidate.record.expiry != null)
                      'EXP ${candidate.record.expiryMonthOnly ? dateText(candidate.record.expiry!).substring(0, 7) : dateText(candidate.record.expiry!)}',
                    if (candidate.record.batchNumber.isNotEmpty)
                      'Batch ${candidate.record.batchNumber}',
                    if (candidate.record.address.isNotEmpty) candidate.record.address,
                  ].join(' · '),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
              ),
            ),
        ],
        if (_lastScan != null && _outcome?.exact == null) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _addFromScan,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add a new stock entry from this scan'),
          ),
          const SizedBox(height: 6),
          const Text(
            'Only add a new entry after checking that none of the suggested batches is the same physical stock.',
            textAlign: TextAlign.center,
            style: TextStyle(color: muted, fontSize: 10.8),
          ),
        ],
      ],
    );
  }
}

class _ScanMessage extends StatelessWidget {
  const _ScanMessage({required this.text, this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: (error ? red : primary).withValues(alpha: .07),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: (error ? red : primary).withValues(alpha: .15),
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          error ? Icons.error_outline_rounded : Icons.info_outline_rounded,
          color: error ? red : primary,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 12.5, height: 1.4)),
        ),
      ],
    ),
  );
}
