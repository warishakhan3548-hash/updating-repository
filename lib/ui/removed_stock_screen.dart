import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/app_brain.dart';
import '../domain/medicine.dart';
import '../domain/search.dart';
import '../state/operational_context.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';

/// Read-only discovery plus explicit reviewed recovery for archived stock.
///
/// Removed rows remain in the one authoritative medicine database. This screen
/// never owns a copy of inventory and never restores from a fuzzy match without
/// an exact row review + confirmation.
class RemovedStockScreen extends StatefulWidget {
  const RemovedStockScreen({
    super.key,
    required this.controller,
    this.initialQuery = '',
  });

  final PharmacyController controller;
  final String initialQuery;

  @override
  State<RemovedStockScreen> createState() => _RemovedStockScreenState();
}

class _RemovedStockScreenState extends State<RemovedStockScreen> {
  static const _browsePageSize = 120;

  late final TextEditingController _query;
  String? _initialContextRestoreId;
  Timer? _debounce;
  SearchHitPublication _publishedHits = SearchHitPublication.empty;
  List<SearchHit> get _hits => _publishedHits.hits;
  bool _loading = true;
  String _error = '';
  int _generation = 0;
  late Object _observedSnapshot;
  bool _controllerListening = false;
  bool _refreshWhenActive = false;
  bool _browseExhausted = false;
  int _browseLimit = _browsePageSize;
  Future<void> _searchTail = Future<void>.value();

  @override
  void initState() {
    super.initState();

    // Aaris Brain may route a command such as “restore it” after the exact row
    // was removed moments earlier. Resolve only the session-bound archived ID;
    // never reinterpret a pronoun through fuzzy medicine-name search. The
    // visible search text remains human-readable while the scheduled review
    // below is anchored to the exact ID and archive provenance.
    final rawInitial = widget.initialQuery.trim();
    final contextual = isAppBrainContextReference(rawInitial)
        ? widget.controller.archivedOperationalTarget
        : null;
    _initialContextRestoreId = contextual?.id;
    _query = TextEditingController(
      text: contextual == null
          ? widget.initialQuery
          : _contextSearchText(contextual),
    );

    _observedSnapshot = widget.controller.snapshot;
    unawaited(_search());
    if (_initialContextRestoreId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_reviewInitialContextRestore());
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (active == _controllerListening) return;

    if (!active) {
      widget.controller.removeListener(_inventoryChanged);
      _controllerListening = false;

      // A covered recovery screen must become genuinely idle. Retire pending
      // debounce/in-flight generations now; if work was interrupted, rebuild
      // the same query exactly once when this route becomes visible again.
      final workPending = _loading || (_debounce?.isActive ?? false);
      _debounce?.cancel();
      if (workPending) {
        ++_generation;
        _refreshWhenActive = true;
      }
      return;
    }

    widget.controller.addListener(_inventoryChanged);
    _controllerListening = true;
    final currentSnapshot = widget.controller.snapshot;
    if (_refreshWhenActive ||
        !identical(currentSnapshot, _observedSnapshot)) {
      final preserveResults = _publishedHits.canPreserveAgainst(
        currentSnapshot.records,
      );
      _observedSnapshot = currentSnapshot;
      _refreshWhenActive = false;
      _debounce?.cancel();
      unawaited(_search(preserveResults: preserveResults));
    }
  }

  @override
  void didUpdateWidget(covariant RemovedStockScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;

    if (_controllerListening) {
      oldWidget.controller.removeListener(_inventoryChanged);
      widget.controller.addListener(_inventoryChanged);
    }
    _observedSnapshot = widget.controller.snapshot;
    _resetBrowseWindow();
    _publishedHits = SearchHitPublication.empty;
    ++_generation;
    _debounce?.cancel();
    if (_controllerListening) {
      _refreshWhenActive = false;
      unawaited(_search());
    } else {
      _refreshWhenActive = true;
    }
  }

  String _contextSearchText(Medicine record) {
    if (record.barcode.trim().isNotEmpty) return record.barcode.trim();
    if (record.batchNumber.trim().isNotEmpty) {
      return '${record.title} ${record.batchNumber.trim()}'.trim();
    }
    return record.title;
  }

  Future<void> _reviewInitialContextRestore() async {
    final id = _initialContextRestoreId;
    _initialContextRestoreId = null;
    if (id == null || !mounted) return;
    final record = widget.controller.snapshot.records[id];
    if (record == null || !record.archived) {
      // Context already became stale or the row was restored elsewhere. The
      // normal removed-stock search remains available; no substitute is chosen.
      return;
    }
    await _reviewRestore(record);
  }

  void _inventoryChanged() {
    final currentSnapshot = widget.controller.snapshot;
    if (identical(currentSnapshot, _observedSnapshot)) return;
    final preserveResults = _publishedHits.canPreserveAgainst(
      currentSnapshot.records,
    );
    _observedSnapshot = currentSnapshot;
    _debounce?.cancel();
    if (mounted) {
      unawaited(_search(preserveResults: preserveResults));
    }
  }

  void _typed(String _) {
    ++_generation;
    _debounce?.cancel();
    _resetBrowseWindow();
    if (mounted) {
      setState(() {
        // Query meaning changed. Never leave a removed-stock row from the
        // previous query tappable while the debounce/new search is pending.
        _publishedHits = SearchHitPublication.empty;
        _loading = true;
        _error = '';
      });
    }
    _debounce = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(_search()),
    );
  }

  Future<void> _search({bool preserveResults = false}) {
    final generation = ++_generation;
    final query = _query.text;
    if (!mounted) return Future<void>.value();
    setState(() {
      _loading = true;
      if (!preserveResults) _publishedHits = SearchHitPublication.empty;
      _error = '';
    });

    // The shared search worker serializes expensive fuzzy work. Coalesce again
    // at this screen boundary so superseded removed-stock queries are discarded
    // before they can enter that queue. One already-running search may finish;
    // after it drains, only the newest queued generation performs real work.
    final operation = _searchTail.then<void>(
      (_) => _runSearch(generation: generation, query: query),
    );
    _searchTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<void> _runSearch({
    required int generation,
    required String query,
  }) async {
    if (!mounted || generation != _generation) return;
    try {
      final browsing = query.trim().isEmpty;
      final requestedBrowseLimit = _browseLimit;
      final probeLimit = browsing
          ? requestedBrowseLimit >= 100000
                ? 100000
                : requestedBrowseLimit + 1
          : requestedBrowseLimit;
      final hits = browsing
          ? await widget.controller.browseArchived(limit: probeLimit)
          : await widget.controller.searchArchived(query);
      if (!mounted || generation != _generation) return;
      final hasMoreBrowseRows =
          browsing && hits.length > requestedBrowseLimit;
      final visibleHits = hasMoreBrowseRows
          ? hits.take(requestedBrowseLimit).toList(growable: false)
          : hits;
      setState(() {
        _publishedHits = SearchHitPublication.capture(
          visibleHits,
          widget.controller.snapshot.records,
        );
        _browseExhausted = browsing && !hasMoreBrowseRows;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _publishedHits = SearchHitPublication.empty;
        _loading = false;
        _error = 'Removed-stock search could not finish. Please try again.';
      });
    }
  }

  void _resetBrowseWindow() {
    _browseLimit = _browsePageSize;
    _browseExhausted = false;
  }

  void _expandBrowse() {
    if (_loading || _browseExhausted) return;
    _browseLimit += _browsePageSize;
    unawaited(_search(preserveResults: true));
  }

  Future<void> _reviewRestore(Medicine record) async {
    late final ReviewedArchivedRestore review;
    try {
      review = widget.controller.reviewArchivedRestore(record.id);
    } catch (error) {
      if (mounted) showError(context, error);
      return;
    }

    final live = widget.controller.snapshot.records[review.stockId];
    if (live == null || !live.archived || !mounted) return;
    final facts = <String>[
      if (live.batchNumber.trim().isNotEmpty) 'Batch ${live.batchNumber.trim()}',
      live.expiry == null
          ? 'EXP not recorded'
          : 'EXP ${live.expiryMonthOnly ? dateText(live.expiry!).substring(0, 7) : dateText(live.expiry!)}',
      live.quantity == null ? 'Quantity unknown' : '${live.quantity} units',
      if (live.address.trim().isNotEmpty) live.address.trim(),
    ];
    final removedWhen = live.archivedAt == null
        ? 'Removal time not available'
        : 'Removed ${live.archivedAt!.toLocal().toString().split('.').first}';
    final reason = live.archiveReason.trim().isEmpty
        ? 'Legacy removal reason not available'
        : live.archiveReason.trim();

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Restore this removed stock?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  live.title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                if (facts.isNotEmpty)
                  Text(
                    facts.join(' · '),
                    style: const TextStyle(color: muted),
                  ),
                const SizedBox(height: 10),
                Text('$reason · $removedWhen'),
                const SizedBox(height: 14),
                const Text(
                  'This returns the same archived row to the Medicine Database. Existing SOLD, expiry, quantity and batch facts are preserved; Aaris does not invent or reset them. If inventory changes before confirmation, the restore is rejected and must be reviewed again.',
                  style: TextStyle(fontSize: 12, color: muted, height: 1.4),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.restore_rounded),
                label: const Text('Restore stock'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    try {
      await widget.controller.applyArchivedRestore(review);
      if (!mounted) return;

      // Recovery is a lifecycle transition of the exact same row. Move session
      // context back to the active side only after the revision-bound restore
      // commits successfully. This enables safe follow-ups such as “edit it”
      // without caching inventory facts or performing another fuzzy lookup.
      widget.controller.clearArchivedOperationalTarget(live.id);
      final restored = widget.controller.snapshot.records[live.id];
      if (restored != null && !restored.archived) {
        widget.controller.rememberOperationalTarget(restored.id);
      }
      showSaved(
        context,
        '${live.title} restored to the Medicine Database. Undo is available in Activity.',
      );
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  void dispose() {
    ++_generation;
    if (_controllerListening) {
      widget.controller.removeListener(_inventoryChanged);
    }
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text.trim();
    final rows = <(SearchHit, Medicine)>[];
    for (final hit in _hits) {
      final medicine = widget.controller.snapshot.records[hit.id];
      if (medicine != null && medicine.archived) rows.add((hit, medicine));
    }

    final canExpandBrowse =
        query.isEmpty && !_browseExhausted && rows.isNotEmpty;

    // Keep the fixed controls eager, but materialize archived stock cards only
    // near the viewport. Removed history is intentionally bounded upstream;
    // this keeps rendering cost proportional to visible rows as that bound grows.
    return Scaffold(
      appBar: AppBar(title: const Text('Removed stock')),
      body: ListView.builder(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(22, 8, 22, 30),
        itemCount: rows.length + 1 + (canExpandBrowse ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ScreenIntro(
                  title: 'Find & restore removed stock',
                  message:
                      'Search local removed history by medicine, brand, salt, barcode, batch, expiry, location or scanned keywords. Restoring always requires an exact-row review.',
                  icon: Icons.inventory_2_outlined,
                  color: amber,
                ),
                Surface(
                  padding: EdgeInsets.zero,
                  child: TextField(
                    controller: _query,
                    onChanged: _typed,
                    maxLength: 300,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => unawaited(_search()),
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: 'Search removed medicines…',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () {
                                _query.clear();
                                _typed('');
                              },
                              icon: const Icon(Icons.close_rounded),
                            ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        query.isEmpty && canExpandBrowse
                            ? 'Showing ${rows.length} removed stock entries'
                            : query.isEmpty
                            ? '${rows.length} removed stock ${rows.length == 1 ? 'entry' : 'entries'}'
                            : '${rows.length} local ${rows.length == 1 ? 'match' : 'matches'} for “$query”',
                        style: const TextStyle(
                          color: muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (_loading)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Surface(
                    color: errorSoft,
                    child: Text(_error, style: const TextStyle(color: red)),
                  ),
                ],
                if (!_loading && _error.isEmpty && rows.isEmpty) ...[
                  const SizedBox(height: 18),
                  EmptyState(
                    title: query.isEmpty ? 'No removed stock' : 'No removed match',
                    message: query.isEmpty
                        ? 'Removed entries will appear here and remain recoverable.'
                        : 'Try the medicine name, barcode, batch number, strength or storage location. Aaris will not guess a different row.',
                  ),
                ],
                const SizedBox(height: 8),
              ],
            );
          }

          if (canExpandBrowse && index == rows.length + 1) {
            return Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: Center(
                child: TextButton(
                  onPressed: _loading ? null : _expandBrowse,
                  child: Text(_loading ? 'Loading more…' : 'Load more'),
                ),
              ),
            );
          }

          final entry = rows[index - 1];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _RemovedStockCard(
              hit: entry.$1,
              record: entry.$2,
              showConfidence: query.isNotEmpty,
              onRestore: () => _reviewRestore(entry.$2),
            ),
          );
        },
      ),
    );
  }
}

class _RemovedStockCard extends StatelessWidget {
  const _RemovedStockCard({
    required this.hit,
    required this.record,
    required this.showConfidence,
    required this.onRestore,
  });

  final SearchHit hit;
  final Medicine record;
  final bool showConfidence;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      if (record.batchNumber.trim().isNotEmpty)
        'Batch ${record.batchNumber.trim()}',
      if (record.expiry != null)
        'EXP ${record.expiryMonthOnly ? dateText(record.expiry!).substring(0, 7) : dateText(record.expiry!)}',
      record.quantity == null ? 'Qty unknown' : 'Qty ${record.quantity}',
      if (record.address.trim().isNotEmpty) record.address.trim(),
    ];
    final removal = <String>[
      if (record.archiveReason.trim().isNotEmpty) record.archiveReason.trim(),
      if (record.archivedAt != null)
        'Removed ${record.archivedAt!.toLocal().toString().split('.').first}',
    ];

    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const DepthIcon(
                Icons.archive_outlined,
                size: 40,
                color: amber,
                background: warningSoft,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.title,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    if (details.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        details.join(' · '),
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    ],
                    if (removal.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        removal.join(' · '),
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (showConfidence) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                StatusPill('${hit.confidence} match'),
                StatusPill(hit.reason),
              ],
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onRestore,
              icon: const Icon(Icons.restore_rounded),
              label: const Text('Review restore'),
            ),
          ),
        ],
      ),
    );
  }
}
