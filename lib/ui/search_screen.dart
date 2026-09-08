import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/inventory.dart';
import '../domain/medicine_discovery.dart';
import '../domain/search.dart';
import '../services/medicine_catalog_service.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'editor_screen.dart';
import 'import_screen.dart';
import 'scanner_screen.dart';
import 'voice_sheet.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.controller,
    required this.scope,
    this.database = false,
    this.embedded = false,
  });
  final PharmacyController controller;
  final SearchScope scope;
  final bool database, embedded;
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  final _catalog = MedicineCatalogService();
  Timer? _debounce;
  List<SearchHit> _hits = [];
  List<MedicineCatalogCandidate> _catalogHits = [];
  bool _loading = true, _catalogLoading = false, _voiceOpening = false;
  String _error = '', _catalogError = '';
  int _generation = 0, _catalogGeneration = 0;
  ScanResult? _scan;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    unawaited(_search());
  }

  void _changed() {
    _debounce?.cancel();
    if (mounted) unawaited(_search());
  }

  Future<void> _search() async {
    final generation = ++_generation;
    if (!mounted) return;
    setState(() {
      _loading = true;
      _hits = [];
      _error = '';
    });
    try {
      final hits = await widget.controller.search(_query.text, widget.scope);
      if (mounted && generation == _generation)
        setState(() {
          _hits = hits;
          _error = '';
          _loading = false;
        });
    } catch (e) {
      if (mounted && generation == _generation)
        setState(() {
          _error = 'Search could not finish. Please try again.';
          _loading = false;
        });
    }
  }

  void _clearCatalog() {
    ++_catalogGeneration;
    _catalogHits = [];
    _catalogLoading = false;
    _catalogError = '';
  }

  void _typed(String value) {
    ++_generation;
    _debounce?.cancel();
    setState(() {
      _hits = [];
      _loading = true;
      _error = '';
      _scan = null;
      _clearCatalog();
    });
    _debounce = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(_search()),
    );
  }

  void _setQuery(String value) {
    _debounce?.cancel();
    setState(() {
      _query.text = value;
      _scan = null;
      _clearCatalog();
    });
    unawaited(_search());
  }

  bool _scanHasConfidentLocalMatch(ScanResult scan) {
    if (scan.barcode.isNotEmpty) {
      final exactBarcode = widget.controller.records.any(
        (medicine) =>
            !medicine.archived &&
            medicine.barcode.trim() == scan.barcode.trim(),
      );
      if (exactBarcode) return true;
    }
    return _hits.any((hit) => hit.score >= .90);
  }

  Future<void> _discoverOnline(ScanResult scan) async {
    if (!widget.database || !mounted) return;
    final generation = ++_catalogGeneration;
    setState(() {
      _catalogLoading = true;
      _catalogHits = [];
      _catalogError = '';
    });
    try {
      final candidates = await _catalog.search(
        barcode: scan.barcode,
        text: scan.text,
      );
      if (!mounted || generation != _catalogGeneration) return;
      setState(() {
        _catalogHits = candidates;
        _catalogLoading = false;
        _catalogError = candidates.isEmpty
            ? 'No reliable public-catalog identity was found for this scan.'
            : '';
      });
    } catch (_) {
      if (!mounted || generation != _catalogGeneration) return;
      setState(() {
        _catalogLoading = false;
        _catalogError = 'Online medicine lookup is unavailable right now.';
      });
    }
  }

  Future<void> _scanner() async {
    final result = await Navigator.push<ScanResult>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (result == null || !mounted) return;
    _debounce?.cancel();
    ++_catalogGeneration;
    setState(() {
      _scan = result;
      _query.text = result.barcode.isNotEmpty ? result.barcode : result.text;
      _catalogHits = [];
      _catalogError = '';
      _catalogLoading = false;
    });
    await _search();
    if (!mounted || !widget.database || _scanHasConfidentLocalMatch(result)) {
      return;
    }
    await _discoverOnline(result);
  }

  Future<void> _mic() async {
    if (_voiceOpening) return;
    setState(() => _voiceOpening = true);
    try {
      final result = await voiceSearch(context);
      if (result != null && mounted) _setQuery(result);
    } finally {
      if (mounted) setState(() => _voiceOpening = false);
    }
  }

  Future<void> _bulk() async {
    final text = TextEditingController(text: _query.text);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Search a medicine list'),
        content: SizedBox(
          width: 500,
          child: TextField(
            controller: text,
            minLines: 6,
            maxLines: 12,
            maxLength: 30000,
            decoration: const InputDecoration(
              hintText:
                  'Paste text from an invoice or a medicine list. Put each medicine on its own line.',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, text.text),
            child: const Text('Find medicines'),
          ),
        ],
      ),
    );
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 300), text.dispose),
    );
    if (result != null && mounted) _setQuery(result);
  }

  void _openCatalogCandidate(MedicineCatalogCandidate candidate) {
    final scan = _scan;
    final seed = candidate.seed.withScanBarcode(scan?.barcode ?? '');
    openEditor(
      context,
      widget.controller,
      seed: seed,
      barcode: scan?.barcode ?? '',
      ocrText: scan?.text ?? '',
    );
  }

  @override
  void dispose() {
    ++_generation;
    ++_catalogGeneration;
    widget.controller.removeListener(_changed);
    _debounce?.cancel();
    _catalog.close();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final title = widget.database
        ? 'Medicine Database'
        : widget.scope == SearchScope.all
        ? 'Scan & Search'
        : scopeTitle(widget.scope, controller.settings);

    Widget blueAction({
      required IconData icon,
      required String label,
      required VoidCallback? onPressed,
    }) => RaisedActionButton(
      icon: icon,
      label: label,
      onPressed: onPressed,
    );

    final body = CustomScrollView(
      key: PageStorageKey('search-${widget.scope}-${widget.database}'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(22, widget.embedded ? 24 : 8, 22, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.embedded)
                  ScreenIntro(
                    title: title,
                    message:
                        'Find a medicine to edit, record a sale or remove stock.',
                    icon: Icons.inventory_2_outlined,
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      widget.scope == SearchScope.all
                          ? 'Search your whole inventory by name, salt, location or notes.'
                          : 'Browse this category, or scan to find a medicine inside it.',
                      style: const TextStyle(color: muted, fontSize: 13),
                    ),
                  ),
                if (widget.database) ...[
                  Row(
                    children: [
                      Expanded(
                        child: blueAction(
                          icon: Icons.add_rounded,
                          label: 'Add medicine',
                          onPressed: () => openEditor(context, controller),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Tooltip(
                          message: 'Add / Import medicines',
                          child: blueAction(
                            icon: Icons.file_upload_outlined,
                            label: 'Import stock',
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    ImportCenterScreen(controller: controller),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                GlassPanel(
                  tint: Colors.white,
                  radius: 18,
                  elevation: 1.12,
                  child: TextField(
                    controller: _query,
                    onChanged: _typed,
                    maxLength: 30000,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _setQuery,
                    onTapOutside: (_) =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                    decoration: InputDecoration(
                      filled: false,
                      counterText: '',
                      hintText: 'Search medicines…',
                      prefixIcon: const Icon(Icons.search_rounded),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(
                          color: primary.withValues(alpha: .08),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: const BorderSide(
                          color: primary,
                          width: 1.5,
                        ),
                      ),
                      suffixIcon: _query.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () => _setQuery(''),
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: blueAction(
                        icon: Icons.qr_code_scanner_rounded,
                        label: 'Scan',
                        onPressed: _scanner,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: blueAction(
                        icon: Icons.mic_none_rounded,
                        label: 'Voice',
                        onPressed: _voiceOpening ? null : _mic,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: blueAction(
                        icon: Icons.playlist_add_rounded,
                        label: 'Paste list',
                        onPressed: _bulk,
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Searching: ${scopeTitle(widget.scope, controller.settings)}${widget.scope == SearchScope.all ? '' : ' only'}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: muted,
                            fontWeight: FontWeight.w600,
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
                ),
                if (_scan != null &&
                    widget.database &&
                    !_catalogLoading &&
                    _catalogHits.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: OutlinedButton.icon(
                      onPressed: () => openEditor(
                        context,
                        controller,
                        barcode: _scan!.barcode,
                        ocrText: _scan!.text,
                      ),
                      icon: const Icon(Icons.add),
                      label: const Text('Add manually from this scan'),
                    ),
                  ),
                if (_scan != null &&
                    _scan!.barcode.isNotEmpty &&
                    _scan!.text.isNotEmpty)
                  TextButton(
                    onPressed: () => _setQuery(_scan!.text),
                    child: const Text('Search the scanned text instead'),
                  ),
              ],
            ),
          ),
        ),
        if (_catalogLoading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(22, 2, 22, 14),
              child: Surface(
                color: accentSoft,
                padding: EdgeInsets.all(16),
                child: Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Not found confidently in your database. Looking up the medicine identity online…',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_catalogHits.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 2, 22, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Choose the medicine found online',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Internet is used only to prefill identity fields such as name, brand, salt, strength, form and manufacturer. Expiry and your stock details stay blank.',
                    style: TextStyle(color: muted, fontSize: 12, height: 1.45),
                  ),
                  const SizedBox(height: 14),
                  for (final candidate in _catalogHits)
                    _CatalogCandidateCard(
                      candidate: candidate,
                      onTap: () => _openCatalogCandidate(candidate),
                    ),
                ],
              ),
            ),
          ),
        if (_catalogError.isNotEmpty && _scan != null && widget.database)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
              child: Text(
                _catalogError,
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            ),
          ),
        if (_error.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Surface(
                color: errorSoft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_error, style: const TextStyle(color: red)),
                    TextButton(
                      onPressed: _search,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_hits.isEmpty &&
            !_loading &&
            _catalogHits.isEmpty &&
            !_catalogLoading)
          SliverToBoxAdapter(
            child: EmptyState(
              title: _query.text.trim().isEmpty
                  ? 'No medicines here yet'
                  : 'No matching medicines',
              message: _scan != null && widget.database
                  ? 'This scan was not matched confidently in your database or public medicine catalogs. You can still add it manually and review the pack.'
                  : widget.scope == SearchScope.all
                  ? 'Try a name, salt, location, barcode or words from your notes.'
                  : 'No matches in this category. You can also search the whole inventory.',
              action: widget.database
                  ? SizedBox(
                      width: 230,
                      child: RaisedActionButton(
                        icon: Icons.add_rounded,
                        label: 'Add medicine',
                        height: 56,
                        radius: 20,
                        onPressed: () => openEditor(
                          context,
                          controller,
                          barcode: _scan?.barcode ?? '',
                          ocrText: _scan?.text ?? '',
                        ),
                      ),
                    )
                  : widget.scope != SearchScope.all
                  ? OutlinedButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => SearchScreen(
                            controller: controller,
                            scope: SearchScope.all,
                          ),
                        ),
                      ),
                      child: const Text('Search all medicines'),
                    )
                  : null,
            ),
          )
        else if (_hits.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(22, 2, 22, 0),
            sliver: SliverList.builder(
              itemCount: _hits.length,
              itemBuilder: (context, index) {
                final hit = _hits[index];
                final record = controller.snapshot.records[hit.id];
                if (record == null ||
                    !inScope(
                      record,
                      widget.scope,
                      controller.settings,
                      controller.today,
                    )) {
                  return const SizedBox.shrink();
                }
                return MedicineCard(
                  record: record,
                  settings: controller.settings,
                  today: controller.today,
                  onTap: () => openEditor(context, controller, record: record),
                  matchLabel: hit.uncertain
                      ? '${hit.confidence} confidence · ${hit.reason} · check name & strength'
                      : _query.text.trim().isEmpty
                      ? null
                      : '${hit.confidence} confidence · ${hit.reason}',
                );
              },
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 30),
            child: Text(
              _hits.length == 150 && _query.text.isNotEmpty
                  ? 'Showing the best 150 matches. Refine your search for more.'
                  : '${_hits.length} stock ${_hits.length == 1 ? 'entry' : 'entries'}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: muted),
            ),
          ),
        ),
      ],
    );
    return widget.embedded
        ? body
        : Scaffold(
            appBar: AppBar(title: Text(title)),
            body: SafeArea(child: body),
          );
  }
}

class _CatalogCandidateCard extends StatelessWidget {
  const _CatalogCandidateCard({required this.candidate, required this.onTap});

  final MedicineCatalogCandidate candidate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final seed = candidate.seed;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Surface(
        color: Colors.white,
        padding: EdgeInsets.zero,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const DepthIcon(Icons.public_rounded, size: 42),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        seed.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (candidate.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          candidate.subtitle,
                          style: const TextStyle(color: muted, fontSize: 12),
                        ),
                      ],
                      if (seed.brand.isNotEmpty && seed.brand != seed.name)
                        Text(
                          'Brand · ${seed.brand}',
                          style: const TextStyle(color: muted, fontSize: 12),
                        ),
                      if (seed.manufacturer.isNotEmpty)
                        Text(
                          seed.manufacturer,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: muted, fontSize: 12),
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          StatusPill(candidate.confidence),
                          Text(
                            candidate.provider,
                            style: const TextStyle(
                              color: muted,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_forward_rounded, color: green),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
