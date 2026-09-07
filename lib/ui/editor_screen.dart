import 'package:flutter/material.dart';
import '../domain/medicine.dart';
import '../domain/inventory.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';

Future<void> openEditor(
  BuildContext context,
  PharmacyController controller, {
  Medicine? record,
  String barcode = '',
  String ocrText = '',
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => EditorScreen(
      controller: controller,
      record: record,
      barcode: barcode,
      ocrText: ocrText,
    ),
  ),
);

class EditorScreen extends StatefulWidget {
  const EditorScreen({
    super.key,
    required this.controller,
    this.record,
    this.barcode = '',
    this.ocrText = '',
  });
  final PharmacyController controller;
  final Medicine? record;
  final String barcode, ocrText;
  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final fields = <String, TextEditingController>{};
  late final int _baseRevision;
  String _form = '', _error = '';
  bool _busy = false, _restocking = false, _dirty = false, _allowPop = false;
  @override
  void initState() {
    super.initState();
    _baseRevision = widget.controller.snapshot.revision;
    final data =
        widget.record?.toJson() ??
        <String, dynamic>{'barcode': widget.barcode, 'ocrText': widget.ocrText};
    for (final field in [
      'name',
      'brand',
      'salt',
      'strength',
      'mfg',
      'expiry',
      'quantity',
      'barcode',
      'block',
      'row',
      'vertical',
      'location',
      'notes',
      'ocrText',
    ]) {
      fields[field] = TextEditingController(
        text: data[field]?.toString() ?? '',
      );
    }
    fields['price'] = TextEditingController(
      text: widget.record?.unitPricePaise == null
          ? ''
          : (widget.record!.unitPricePaise! / 100).toStringAsFixed(2),
    );
    _form = widget.record?.form ?? '';
  }

  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Medicine _draft() {
    final old = widget.record;
    final quantityText = fields['quantity']!.text.trim();
    final quantity = quantityText.isEmpty ? null : int.tryParse(quantityText);
    if (quantityText.isNotEmpty && quantity == null)
      throw const FormatException('Quantity must be a whole number.');
    if (_restocking && (quantity == null || quantity <= 0))
      throw const FormatException(
        'Enter a positive quantity for the new stock.',
      );
    final data = <String, dynamic>{
      ...?old?.toJson(),
      for (final entry in fields.entries)
        if (!{'price', 'quantity'}.contains(entry.key))
          entry.key: entry.value.text.trim(),
      'id': old?.id ?? newId(),
      'form': _form,
      'quantity': quantity,
      'unitPricePaise': parseMoney(fields['price']!.text),
      'revision': (old?.revision ?? 0) + 1,
      if (_restocking) ...{
        'sold': false,
        'soldAt': null,
        'soldQuantity': null,
        'soldUnitPricePaise': null,
      },
    };
    return Medicine.fromJson(data);
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _save({bool sold = false}) async {
    if (_busy) return;
    try {
      var draft = _draft();
      if (sold) {
        if (!await _confirm(
          'Mark this stock sold?',
          'This marks the entire stock entry out of stock and adds it to the reorder list. It does not record a customer sale.',
          'Mark sold',
        ))
          return;
        draft = draft.patch({
          'sold': true,
          'quantity': 0,
          'soldAt': DateTime.now().toIso8601String(),
          'soldQuantity': draft.quantity,
          'soldUnitPricePaise': draft.unitPricePaise,
        });
      }
      if (widget.record == null) {
        final matches = widget.controller.records
            .where(
              (m) =>
                  !m.archived &&
                  (m.identity == draft.identity ||
                      (draft.barcode.isNotEmpty && m.barcode == draft.barcode)),
            )
            .toList();
        if (matches.isNotEmpty &&
            !await _confirm(
              'Matching medicine already exists',
              '${matches.length} stock entries share this medicine or barcode. Save a separate stock entry only if this is different stock, expiry or location.',
              'Add separate stock',
            ))
          return;
      }
      if (!mounted) return;
      setState(() => _busy = true);
      await widget.controller.save(draft, expectedRevision: _baseRevision);
      if (mounted) {
        setState(() => _allowPop = true);
        Navigator.pop(context);
        showSaved(
          context,
          sold
              ? 'Marked sold. Your reorder list is updated.'
              : 'Medicine saved. All views are up to date.',
        );
      }
    } catch (e) {
      if (mounted)
        setState(
          () => _error = e.toString().replaceFirst(
            RegExp(r'^(FormatException|Bad state):\s*'),
            '',
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final record = widget.record;
    if (record == null || _busy) return;
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Why remove this stock?'),
        children: [
          for (final reason in [
            'Sold / stock finished',
            'Expired',
            'Damaged',
            'Returned',
            'Correction',
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, reason),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
              child: Text(reason),
            ),
        ],
      ),
    );
    if (reason == null || !mounted) return;
    if (reason.startsWith('Sold')) {
      await _save(sold: true);
      return;
    }
    if (!await _confirm(
      'Remove ${record.name}?',
      'This stock entry will disappear from inventory, search and totals. It remains in removed history and can be restored.',
      'Remove',
    ))
      return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await widget.controller.archive(record.id, reason);
      if (mounted) {
        setState(() => _allowPop = true);
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(
    String key,
    String label, {
    String? hint,
    int lines = 1,
    TextInputType? keyboard,
    int? max,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: fields[key],
      onChanged: (_) => setState(() => _dirty = true),
      maxLines: lines,
      maxLength: max,
      keyboardType: keyboard,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        alignLabelWithHint: lines > 1,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    return PopScope(
      canPop: _allowPop || (!_dirty && !_busy),
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _busy) return;
        if (await _confirm(
              'Discard unsaved changes?',
              'Your saved inventory will remain as it was.',
              'Discard',
            ) &&
            context.mounted) {
          setState(() => _allowPop = true);
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(record == null ? 'Add medicine' : 'Medicine details'),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 10, 22, 30),
            children: [
              if (record != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Surface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          record.title,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 10),
                        StatusPill(
                          statusOf(
                            record,
                            widget.controller.settings,
                            widget.controller.today,
                          ).label,
                          color: record.sold
                              ? amber
                              : (record.daysLeft(widget.controller.today) ??
                                        1) <
                                    0
                              ? red
                              : green,
                        ),
                        if (record.sold)
                          const Padding(
                            padding: EdgeInsets.only(top: 10),
                            child: Text(
                              'This entry is in your reorder list.',
                              style: TextStyle(color: muted, fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              if (record?.sold == true && !_restocking)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: FilledButton.icon(
                    onPressed: () {
                      setState(() {
                        _restocking = true;
                        _dirty = true;
                        fields['quantity']!.clear();
                        fields['expiry']!.clear();
                        fields['mfg']!.clear();
                      });
                    },
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: const Text('Restock this medicine'),
                  ),
                ),
              if (_restocking)
                const Padding(
                  padding: EdgeInsets.only(bottom: 18),
                  child: StatusPill('New stock · review expiry and quantity'),
                ),
              Text(
                record == null
                    ? 'Give it a place in your inventory.'
                    : 'Edit the master stock entry.',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Only the medicine name is required. Leave information blank when it is unknown.',
                style: TextStyle(color: muted, fontSize: 13),
              ),
              const SizedBox(height: 24),
              _field('name', 'Medicine name *', hint: 'e.g. Paracetamol'),
              _field('brand', 'Brand · optional', hint: 'e.g. Dolo'),
              _field('salt', 'Salt / composition · optional'),
              _field('strength', 'Strength · optional', hint: 'e.g. 650mg'),
              DropdownButtonFormField<String>(
                initialValue: _form,
                decoration: const InputDecoration(
                  labelText: 'Medicine form · optional',
                ),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('Not specified'),
                  ),
                  ...forms.map(
                    (f) => DropdownMenuItem(value: f, child: Text(f)),
                  ),
                ],
                onChanged: (v) => setState(() {
                  _form = v ?? '';
                  _dirty = true;
                }),
              ),
              const SectionHeading('Dates & stock'),
              _field(
                'expiry',
                'Expiry date · optional',
                hint: 'YYYY-MM-DD or printed YYYY-MM',
                keyboard: TextInputType.datetime,
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: Text(
                  'A printed expiry month is treated as valid through its last day.',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ),
              _field(
                'mfg',
                'Manufacturing date · optional',
                hint: 'YYYY-MM-DD',
                keyboard: TextInputType.datetime,
              ),
              _field(
                'quantity',
                'Stock quantity · optional',
                hint: 'Number of units you count',
                keyboard: TextInputType.number,
              ),
              _field(
                'price',
                'Price per counted unit · ₹ · optional',
                hint: 'e.g. 2.50',
                keyboard: const TextInputType.numberWithOptions(decimal: true),
              ),
              const Text(
                'Use the same unit for quantity and price: tablets with tablet price, bottles with bottle price, or strips with strip price.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const SectionHeading('Where to find it'),
              _field('block', 'Block · optional'),
              _field('row', 'Row · optional'),
              _field('vertical', 'Vertical · optional'),
              _field(
                'location',
                'Location · optional',
                hint: 'Room, shelf, drawer or box',
                lines: 2,
              ),
              _field(
                'notes',
                'Your notes · optional',
                hint: 'Anything that helps you find or remember this medicine',
                lines: 3,
                max: 10000,
              ),
              const SectionHeading('Scan & search details'),
              _field('barcode', 'Barcode · optional'),
              _field(
                'ocrText',
                'Scanned text / search keywords · optional',
                lines: 4,
                max: 30000,
              ),
              if (_error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Text(_error, style: const TextStyle(color: red)),
                ),
              FilledButton.icon(
                onPressed: _busy ? null : () => _save(),
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(_restocking ? 'Save new stock' : 'Save medicine'),
              ),
              if (record != null && !record.sold)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _save(sold: true),
                    icon: const Icon(Icons.check_circle_outline, color: amber),
                    label: const Text(
                      'Mark stock SOLD',
                      style: TextStyle(color: amber),
                    ),
                  ),
                ),
              if (record != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextButton.icon(
                    onPressed: _busy ? null : _remove,
                    icon: const Icon(Icons.archive_outlined, color: red),
                    label: const Text(
                      'Remove stock entry',
                      style: TextStyle(color: red),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
