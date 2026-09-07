import 'dart:async';
import 'package:flutter/material.dart';
import '../domain/inventory.dart';
import '../domain/search.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';
import 'editor_screen.dart';
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
  Timer? _debounce;
  List<SearchHit> _hits = [];
  bool _loading = true;
  String _error = '';
  int _generation = 0;
  ScanResult? _scan;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    unawaited(_search());
  }

  void _changed() {
    if (mounted) unawaited(_search());
  }

  Future<void> _search() async {
    final generation = ++_generation;
    if (mounted) setState(() => _loading = true);
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

  void _typed(String value) {
    ++_generation;
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(_search()),
    );
  }

  void _setQuery(String value) {
    _debounce?.cancel();
    _query.text = value;
    unawaited(_search());
  }

  Future<void> _scanner() async {
    final result = await Navigator.push<ScanResult>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (result == null || !mounted) return;
    setState(() => _scan = result);
    _setQuery(result.barcode.isNotEmpty ? result.barcode : result.text);
  }

  Future<void> _mic() async {
    final result = await voiceSearch(context);
    if (result != null && mounted) _setQuery(result);
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

  @override
  void dispose() {
    ++_generation;
    widget.controller.removeListener(_changed);
    _debounce?.cancel();
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
    final body = Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(22, widget.embedded ? 24 : 8, 22, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.embedded)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ),
                    IconButton.filled(
                      tooltip: 'Add medicine',
                      onPressed: () => openEditor(context, controller),
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ],
                ),
              if (widget.database)
                const Padding(
                  padding: EdgeInsets.only(top: 6, bottom: 18),
                  child: Text(
                    'Add and Edit and Remove Medicines',
                    style: TextStyle(color: muted, fontSize: 13),
                  ),
                ),
              TextField(
                controller: _query,
                onChanged: _typed,
                maxLength: 30000,
                decoration: InputDecoration(
                  counterText: '',
                  hintText: 'Search medicines…',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _query.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: () => _setQuery(''),
                          icon: const Icon(Icons.close_rounded),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _scanner,
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 19),
                    label: const Text('Scan'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _mic,
                    icon: const Icon(Icons.mic_none_rounded, size: 19),
                    label: const Text('Mic'),
                  ),
                  IconButton(
                    tooltip: 'Paste a full medicine list',
                    onPressed: _bulk,
                    icon: const Icon(Icons.playlist_add_rounded),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 14, bottom: 12),
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
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
              if (_scan != null && widget.database)
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
                    label: const Text('Add as new stock · review draft'),
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
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(_error, style: const TextStyle(color: red)),
          ),
        Expanded(
          child: _hits.isEmpty && !_loading
              ? ListView(
                  padding: const EdgeInsets.all(22),
                  children: [
                    EmptyState(
                      title: _query.text.trim().isEmpty
                          ? 'No medicines here yet'
                          : 'No matching medicines',
                      message: widget.scope == SearchScope.all
                          ? 'Try a name, salt, location, barcode or words from your notes.'
                          : 'There are no matches inside this category. Other categories have not been included.',
                      action: widget.database
                          ? FilledButton.icon(
                              onPressed: () => openEditor(
                                context,
                                controller,
                                barcode: _scan?.barcode ?? '',
                                ocrText: _scan?.text ?? '',
                              ),
                              icon: const Icon(Icons.add),
                              label: const Text('Add medicine'),
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
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(22, 2, 22, 25),
                  itemCount: _hits.length + 1,
                  itemBuilder: (context, index) {
                    if (index == _hits.length)
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          _hits.length == 150 && _query.text.isNotEmpty
                              ? 'Showing the best 150 matches. Refine your search for more.'
                              : '${_hits.length} stock ${_hits.length == 1 ? 'entry' : 'entries'}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12, color: muted),
                        ),
                      );
                    final hit = _hits[index];
                    final record = controller.snapshot.records[hit.id];
                    if (record == null ||
                        !inScope(
                          record,
                          widget.scope,
                          controller.settings,
                          controller.today,
                        ))
                      return const SizedBox.shrink();
                    return MedicineCard(
                      record: record,
                      settings: controller.settings,
                      today: controller.today,
                      onTap: () =>
                          openEditor(context, controller, record: record),
                      matchLabel: hit.uncertain
                          ? 'Possible match · ${hit.reason} · check name & strength'
                          : _query.text.trim().isEmpty
                          ? null
                          : hit.reason,
                    );
                  },
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
