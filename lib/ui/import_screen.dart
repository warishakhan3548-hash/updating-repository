import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/inventory.dart';
import '../domain/search.dart';
import '../services/backup_service.dart';
import '../services/media_import_service.dart';
import '../services/scan_service.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'editor_screen.dart';
import 'scanner_screen.dart';

class ImportCenterScreen extends StatefulWidget {
  const ImportCenterScreen({super.key, required this.controller});

  final PharmacyController controller;

  @override
  State<ImportCenterScreen> createState() => _ImportCenterScreenState();
}

class _ImportCenterScreenState extends State<ImportCenterScreen> {
  final _media = MediaImportService();
  final _files = BackupService();
  bool _busy = false;
  int _done = 0;
  int _total = 0;
  int _generation = 0;

  @override
  void dispose() {
    ++_generation;
    super.dispose();
  }

  Future<void> _scan() async {
    final result = await Navigator.push<ScanResult>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (result == null || !mounted) return;
    await _openInbox([
      ScanEvidence(
        barcode: result.barcode,
        text: result.text,
        source: 'Live camera',
      ),
    ]);
  }

  Future<void> _photo() async {
    if (_busy) return;
    final generation = ++_generation;
    PickedImportSource? picked;
    final vision = MedicineVisionService();
    setState(() {
      _busy = true;
      _done = 0;
      _total = 1;
    });
    try {
      final source = await _media.pick('image');
      picked = source;
      if (source == null || !mounted || generation != _generation) return;
      final evidence = await vision.analyzeFile(
        source.path,
        source: source.name,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _done = 1);
      await _openInbox([evidence]);
    } catch (error) {
      if (mounted && generation == _generation) showError(context, error);
    } finally {
      try {
        await vision.close();
      } catch (_) {}
      if (picked != null) {
        try {
          await _media.cleanup([picked.path]);
        } catch (_) {}
      }
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _video() async {
    if (_busy) return;
    final generation = ++_generation;
    PickedImportSource? picked;
    var sampledFrames = <String>[];
    final vision = MedicineVisionService();
    setState(() {
      _busy = true;
      _done = 0;
      _total = 0;
    });
    try {
      final source = await _media.pick('video');
      picked = source;
      if (source == null || !mounted || generation != _generation) return;
      final frames = await _media.sampleVideo(source.path);
      sampledFrames = frames;
      if (!mounted || generation != _generation) return;
      setState(() => _total = frames.length);
      final evidence = <ScanEvidence>[];
      for (var index = 0; index < frames.length; index++) {
        if (!mounted || generation != _generation) return;
        try {
          final result = await vision.analyzeFile(
            frames[index],
            source: '${source.name} · frame ${index + 1}',
          );
          if (result.text.isNotEmpty || result.barcode.isNotEmpty) {
            evidence.add(result);
          }
        } catch (_) {
          // One unreadable frame must not discard the rest of a long video.
        }
        if (mounted && generation == _generation) {
          setState(() => _done = index + 1);
        }
      }
      if (evidence.isEmpty) {
        throw StateError(
          'No medicine text was found. Try a steadier video with closer labels and more light.',
        );
      }
      if (!mounted || generation != _generation) return;
      await _openInbox(evidence);
    } catch (error) {
      if (mounted && generation == _generation) showError(context, error);
    } finally {
      try {
        await vision.close();
      } catch (_) {}
      try {
        await _media.cleanup([
          if (picked != null) picked.path,
          ...sampledFrames,
        ]);
      } catch (_) {}
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _textFile() async {
    if (_busy) return;
    final generation = ++_generation;
    setState(() => _busy = true);
    try {
      final text = await _files.pickBackupText();
      if (text == null || !mounted || generation != _generation) return;
      if (text.contains('aaris.pharmacy.backup.v1')) {
        throw const FormatException(
          'This is a full backup. Open Profile → Backup & Restore so it can be validated safely.',
        );
      }
      await _openInbox([
        ScanEvidence(text: text, source: 'Imported text file'),
      ]);
    } on MissingPluginException {
      if (mounted) {
        showError(
          context,
          'File import is available in the installed Android app.',
        );
      }
    } catch (error) {
      if (mounted && generation == _generation) showError(context, error);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _pasteList() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      showError(context, 'Clipboard has no medicine text.');
      return;
    }
    await _openInbox([ScanEvidence(text: text, source: 'Clipboard')]);
  }

  Future<void> _openInbox(List<ScanEvidence> evidence) async {
    if (evidence.every(
      (item) => item.barcode.isEmpty && item.text.trim().isEmpty,
    )) {
      throw const FormatException('No barcode or medicine text was captured.');
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ImportInboxScreen(
          controller: widget.controller,
          evidence: evidence,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Add / Import')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 30),
      children: [
        const ScreenIntro(
          title: 'Add your medicines',
          message: 'Choose the easiest way to start. Review captured details before saving.',
          icon: Icons.add_box_outlined,
        ),
        const FlowSteps(['Add or scan', 'Review', 'Save']),
        _ImportAction(
          icon: Icons.edit_note_rounded,
          title: 'Add manually',
          detail: 'Only medicine name is required.',
          onTap: _busy ? null : () => openEditor(context, widget.controller),
        ),
        _ImportAction(
          icon: Icons.qr_code_scanner_rounded,
          title: 'Scan medicine',
          detail: 'Barcode and packaging text together.',
          onTap: _busy ? null : _scan,
        ),
        _ImportAction(
          icon: Icons.add_photo_alternate_outlined,
          title: 'Upload photo',
          detail: 'Read an existing label or medicine-list photo.',
          onTap: _busy ? null : _photo,
        ),
        _ImportAction(
          icon: Icons.video_library_outlined,
          title: 'Upload video',
          detail: 'Read medicine packs from a video on your phone.',
          onTap: _busy ? null : _video,
        ),
        _ImportAction(
          icon: Icons.upload_file_outlined,
          title: 'Upload text file',
          detail: 'Choose a medicine list, then review its matches.',
          onTap: _busy ? null : _textFile,
        ),
        _ImportAction(
          icon: Icons.content_paste_rounded,
          title: 'Paste medicine list',
          detail: 'Invoices and long lists can be matched in one pass.',
          onTap: _busy ? null : _pasteList,
        ),
        if (_busy) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
          const SizedBox(height: 10),
          Text(
            _total == 0
                ? 'Preparing local import…'
                : 'Reading frame $_done of $_total locally…',
            textAlign: TextAlign.center,
            style: const TextStyle(color: muted, fontSize: 12),
          ),
          TextButton(
            onPressed: () {
              ++_generation;
              setState(() => _busy = false);
            },
            child: const Text('Cancel'),
          ),
        ],
      ],
    ),
  );
}

class _ImportAction extends StatelessWidget {
  const _ImportAction({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 11),
    child: Surface(
      padding: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        leading: DepthIcon(icon),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(detail),
        trailing: const Icon(Icons.chevron_right_rounded),
        enabled: onTap != null,
        onTap: onTap,
      ),
    ),
  );
}

class ImportInboxScreen extends StatefulWidget {
  const ImportInboxScreen({
    super.key,
    required this.controller,
    required this.evidence,
  });

  final PharmacyController controller;
  final List<ScanEvidence> evidence;

  @override
  State<ImportInboxScreen> createState() => _ImportInboxScreenState();
}

class _ImportInboxScreenState extends State<ImportInboxScreen> {
  List<SearchHit> _hits = const [];
  String _consensusText = '';
  String _barcode = '';
  String _error = '';
  bool _loading = true;
  int _generation = 0;
  int _inventoryRevision = -1;

  @override
  void initState() {
    super.initState();
    _inventoryRevision = widget.controller.snapshot.revision;
    widget.controller.addListener(_inventoryChanged);
    unawaited(_prepare());
  }

  @override
  void dispose() {
    ++_generation;
    widget.controller.removeListener(_inventoryChanged);
    super.dispose();
  }

  void _inventoryChanged() {
    if (!mounted) return;
    if (_inventoryRevision == widget.controller.snapshot.revision) {
      setState(() {});
      return;
    }
    _inventoryRevision = widget.controller.snapshot.revision;
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final barcodeCounts = <String, int>{};
      final lineCounts = <String, int>{};
      final originals = <String, String>{};
      for (final evidence in widget.evidence) {
        if (evidence.barcode.isNotEmpty) {
          barcodeCounts[evidence.barcode] =
              (barcodeCounts[evidence.barcode] ?? 0) + 1;
        }
        final boundedText = evidence.text.length > 30000
            ? evidence.text.substring(0, 30000)
            : evidence.text;
        for (final line in boundedText.split('\n').take(1000)) {
          final normalized = searchText(line);
          if (normalized.length < 2) continue;
          lineCounts[normalized] = (lineCounts[normalized] ?? 0) + 1;
          originals.putIfAbsent(normalized, () => line.trim());
        }
      }
      final orderedLines = lineCounts.keys.toList()
        ..sort((a, b) {
          final count = lineCounts[b]!.compareTo(lineCounts[a]!);
          return count != 0 ? count : a.compareTo(b);
        });
      final consensus = orderedLines
          .take(500)
          .map((key) => originals[key]!)
          .join('\n');
      final primaryBarcode = barcodeCounts.keys.isEmpty
          ? ''
          : (barcodeCounts.keys.toList()..sort(
                  (a, b) => barcodeCounts[b]!.compareTo(barcodeCounts[a]!),
                ))
                .first;
      final found = <String, SearchHit>{};
      for (final barcode in barcodeCounts.keys.take(20)) {
        for (final hit in await widget.controller.search(
          barcode,
          SearchScope.all,
        )) {
          found[hit.id] = hit;
        }
      }
      if (consensus.isNotEmpty) {
        for (final hit in await widget.controller.search(
          consensus,
          SearchScope.all,
        )) {
          if (found[hit.id] == null || found[hit.id]!.score < hit.score) {
            found[hit.id] = hit;
          }
        }
      }
      final hits = found.values.toList()
        ..sort((a, b) => b.score.compareTo(a.score));
      if (mounted && generation == _generation) {
        setState(() {
          _hits = hits;
          _consensusText = consensus;
          _barcode = primaryBarcode;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = 'The import inbox could not rank these scans. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _hits.where((hit) => !hit.uncertain).toList();
    final review = _hits.where((hit) => hit.uncertain).toList();
    final unidentified =
        _hits.isEmpty && (_consensusText.isNotEmpty || _barcode.isNotEmpty)
        ? 1
        : 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Review import')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 30),
              children: [
                const FlowSteps(['Add or scan', 'Review', 'Save'], current: 1),
                Surface(
                  color: ink,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'LOCAL REVIEW',
                        style: TextStyle(
                          color: inverseMuted,
                          fontSize: 10,
                          letterSpacing: 1.4,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${ready.length} ready · ${review.length} need review · $unidentified raw group',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Matches open existing records. New stock opens a draft; you confirm every field before saving.',
                        style: TextStyle(color: inverseMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (_error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(_error, style: const TextStyle(color: red)),
                  ),
                if (ready.isNotEmpty) ...[
                  const SectionHeading('High-confidence existing matches'),
                  for (final hit in ready) _hit(context, hit),
                ],
                if (review.isNotEmpty) ...[
                  const SectionHeading('Needs review'),
                  for (final hit in review) _hit(context, hit),
                ],
                const SectionHeading('Captured evidence'),
                Surface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_barcode.isNotEmpty) ...[
                        const Text(
                          'BARCODE',
                          style: TextStyle(
                            color: muted,
                            fontSize: 10,
                            letterSpacing: 1.2,
                          ),
                        ),
                        SelectableText(_barcode),
                        const SizedBox(height: 12),
                      ],
                      SelectableText(
                        _consensusText.isEmpty
                            ? 'No readable packaging text.'
                            : _consensusText,
                        maxLines: 20,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: () => openEditor(
                    context,
                    widget.controller,
                    barcode: _barcode,
                    ocrText: _consensusText,
                  ),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Create new stock draft'),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    'OCR text stays separate from your personal note. Low-confidence text never fills medical facts automatically.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, fontSize: 11),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _hit(BuildContext context, SearchHit hit) {
    final record = widget.controller.snapshot.records[hit.id];
    if (record == null || record.archived) return const SizedBox.shrink();
    return MedicineCard(
      record: record,
      settings: widget.controller.settings,
      today: widget.controller.today,
      onTap: () => openEditor(context, widget.controller, record: record),
      matchLabel: hit.uncertain
          ? '${hit.confidence} confidence · ${hit.reason} · verify before editing'
          : '${hit.confidence} confidence · ${hit.reason} · matched from import',
    );
  }
}
