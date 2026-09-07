import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/date_input.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/medicine_discovery.dart';
import '../state/pharmacy_controller.dart';
import 'date_field.dart';
import 'design.dart';
import 'version_history_screen.dart';

Future<void> openEditor(
  BuildContext context,
  PharmacyController controller, {
  Medicine? record,
  MedicineDraftSeed? seed,
  String barcode = '',
  String ocrText = '',
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => EditorScreen(
      controller: controller,
      record: record,
      seed: seed,
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
    this.seed,
    this.barcode = '',
    this.ocrText = '',
  });

  final PharmacyController controller;
  final Medicine? record;
  final MedicineDraftSeed? seed;
  final String barcode, ocrText;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final fields = <String, TextEditingController>{};
  final _extraSaltControllers = <TextEditingController>[];
  final _formKey = GlobalKey<FormState>();
  late final int _baseRevision;

  bool _expiryMonthOnly = true;
  String _form = '', _error = '';
  bool _busy = false, _restocking = false, _dirty = false, _allowPop = false;

  @override
  void initState() {
    super.initState();
    _baseRevision = widget.controller.snapshot.revision;
    final seed = widget.seed;
    final data =
        widget.record?.toJson() ??
        <String, dynamic>{
          'name': seed?.name ?? '',
          'brand': seed?.brand ?? '',
          'manufacturer': seed?.manufacturer ?? '',
          'salt': seed?.salt ?? '',
          'strength': seed?.strength ?? '',
          'barcode': seed?.barcode.isNotEmpty == true
              ? seed!.barcode
              : widget.barcode,
          'ocrText': widget.ocrText,
        };

    // Keep legacy/automatic metadata in the model so existing records and
    // catalog-prefilled identity data are never destroyed. Only the small set
    // of fields a pharmacist needs day-to-day is rendered in the editor.
    for (final field in [
      'name',
      'brand',
      'manufacturer',
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

    // Multiple salts stay backward-compatible with the existing single `salt`
    // model field. We serialize visible salt boxes as "Salt A + Salt B + Salt C"
    // so existing search/index/backup logic keeps seeing one searchable string.
    final storedSalt = fields['salt']!.text.trim();
    final saltParts = storedSalt.isEmpty
        ? const <String>[]
        : storedSalt
              .split(RegExp(r'\s+\+\s+'))
              .map((part) => part.trim())
              .where((part) => part.isNotEmpty)
              .toList();
    if (saltParts.length > 1) {
      fields['salt']!.text = saltParts.first;
      for (final part in saltParts.skip(1)) {
        _extraSaltControllers.add(TextEditingController(text: part));
      }
    }

    _form = widget.record?.form ?? seed?.form ?? '';
    final record = widget.record;
    _expiryMonthOnly = record?.expiry == null || record!.expiryMonthOnly;
    if (record?.expiry != null) {
      fields['expiry']!.text = inputDateText(
        record!.expiry!,
        monthOnly: _expiryMonthOnly,
      );
    }
    if (record?.mfg != null) fields['mfg']!.text = inputDateText(record!.mfg!);
  }

  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    for (final controller in _extraSaltControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  String get _saltValue => [
    fields['salt']!.text,
    ..._extraSaltControllers.map((controller) => controller.text),
  ].map((value) => value.trim()).where((value) => value.isNotEmpty).join(' + ');

  void _addSalt() {
    if (_busy) return;
    setState(() {
      _extraSaltControllers.add(TextEditingController());
      _dirty = true;
    });
  }

  void _removeSalt(int index) {
    if (_busy || index < 0 || index >= _extraSaltControllers.length) return;
    final controller = _extraSaltControllers.removeAt(index);
    controller.dispose();
    setState(() => _dirty = true);
  }

  Widget _saltField({TextEditingController? controller, int? extraIndex}) {
    final isPrimary = controller == null;
    final textController = controller ?? fields['salt']!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: textController,
        enabled: !_busy,
        onChanged: (_) => setState(() => _dirty = true),
        textInputAction: TextInputAction.next,
        onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
        decoration: InputDecoration(
          labelText: isPrimary ? 'Salt name · optional' : 'Another salt · optional',
          hintText: isPrimary ? 'e.g. Paracetamol' : 'e.g. Caffeine',
          helperText: isPrimary
              ? 'Some medicines contain 2 or 3 salts. Tap + only when you need another one.'
              : null,
          suffixIcon: isPrimary
              ? IconButton(
                  tooltip: 'Add another salt',
                  onPressed: _busy ? null : _addSalt,
                  icon: const Icon(Icons.add_circle_outline_rounded),
                )
              : IconButton(
                  tooltip: 'Remove this salt',
                  onPressed: _busy || extraIndex == null
                      ? null
                      : () => _removeSalt(extraIndex),
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                ),
        ),
      ),
    );
  }

  Medicine _draft() {
    final old = widget.record;
    final quantityText = fields['quantity']!.text.trim();
    final quantity = quantityText.isEmpty ? null : int.tryParse(quantityText);
    if (quantityText.isNotEmpty && quantity == null) {
      throw const FormatException('Quantity must be a whole number.');
    }

    final data = <String, dynamic>{
      ...?old?.toJson(),
      for (final entry in fields.entries)
        if (!{'price', 'quantity', 'salt'}.contains(entry.key))
          entry.key: entry.value.text.trim(),
      'salt': _saltValue,
      'expiry': inputDateToIso(
        fields['expiry']!.text,
        monthOnly: _expiryMonthOnly,
      ),
      'mfg': inputDateToIso(fields['mfg']!.text),
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
    if (!(_formKey.currentState?.validate() ?? false)) {
      showError(context, 'Check the highlighted fields before saving.');
      return;
    }
    setState(() => _busy = true);
    try {
      var draft = _draft();
      if (sold) {
        if (!await _confirm(
          'Mark this stock sold?',
          'This marks the entire stock entry out of stock and adds it to the reorder list. It does not record a customer sale.',
          'Mark sold',
        )) {
          return;
        }
        if (!mounted) return;
        draft = Medicine.fromJson({
          ...draft.toJson(),
          'sold': true,
          'quantity': 0,
          'soldAt': widget.controller.clock().toIso8601String(),
          'soldQuantity': draft.quantity,
          'soldUnitPricePaise': draft.unitPricePaise,
          'revision': (widget.record?.revision ?? 0) + 1,
        });
      }

      if (widget.record == null) {
        var matches = widget.controller.records
            .where(
              (m) =>
                  !m.archived &&
                  (m.identity == draft.identity ||
                      (draft.barcode.isNotEmpty && m.barcode == draft.barcode)),
            )
            .toList();
        var matchKind = 'share this medicine or barcode';
        if (matches.isEmpty) {
          final hits = await widget.controller.search(
            '${draft.name} ${draft.strength}',
            SearchScope.all,
          );
          matches = hits
              .where((hit) => hit.score >= .90)
              .take(3)
              .map((hit) => widget.controller.snapshot.records[hit.id])
              .whereType<Medicine>()
              .toList();
          matchKind = 'look very similar';
          if (!mounted) return;
        }
        if (matches.isNotEmpty &&
            !await _confirm(
              'Matching medicine already exists',
              '${matches.map((match) => match.title).join(', ')} $matchKind. Save a separate stock entry only if this has a different expiry, location or physical stock.',
              'Add separate stock',
            )) {
          return;
        }
      }

      if (!mounted) return;
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
      if (mounted) showError(context, e);
      if (mounted) {
        setState(
          () => _error = e.toString().replaceFirst(
            RegExp(r'^(FormatException|Bad state):\s*'),
            '',
          ),
        );
      }
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
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await widget.controller.archive(
        record.id,
        reason,
        expectedRevision: _baseRevision,
      );
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

  Future<void> _recordSale() async {
    final record = widget.record;
    if (record == null || record.sold || record.archived || _busy) return;
    if (_dirty) {
      showError(
        context,
        'Save edited medicine details before recording a sale.',
      );
      return;
    }

    final quantity = TextEditingController(text: '1');
    final amount = TextEditingController();
    var markSoldOut = false;
    DateTime? occurredAt;
    String error = '';

    final result = await showDialog<_SaleInput>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Record sale · ${record.name}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: quantity,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Quantity sold *',
                    helperText: record.quantity == null
                        ? 'Current stock quantity is unknown.'
                        : '${record.quantity} units currently recorded',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Total sale amount · ₹ · optional',
                    helperText: 'Leave blank when the amount is not recorded.',
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () async {
                    final today = widget.controller.today;
                    final chosen = await showDateEntryDialog(
                      context: ctx,
                      title: 'Choose sale date',
                      firstDate: DateTime(
                        today.year - 10,
                        today.month,
                        today.day,
                      ),
                      lastDate: today,
                      initialDate: occurredAt ?? today,
                    );
                    if (chosen != null && ctx.mounted) {
                      setDialogState(() => occurredAt = chosen.start);
                    }
                  },
                  icon: const Icon(Icons.event_outlined),
                  label: Text(
                    occurredAt == null
                        ? 'Sale date · today'
                        : 'Sale date · ${inputDateText(occurredAt!)}',
                  ),
                ),
                const SizedBox(height: 10),
                CheckboxListTile(
                  value: markSoldOut,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Stock is completely finished'),
                  subtitle: const Text(
                    'Explicitly mark this entry SOLD and add it to reorder.',
                  ),
                  onChanged: (value) => setDialogState(
                    () => markSoldOut = value == true,
                  ),
                ),
                const Text(
                  'Only aggregate medicine movement is saved. No customer or patient details are collected.',
                  style: TextStyle(fontSize: 11, color: muted),
                ),
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error,
                      style: const TextStyle(color: red, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final units = int.tryParse(quantity.text.trim());
                  if (units == null || units < 1) {
                    throw const FormatException(
                      'Enter a positive whole-number quantity.',
                    );
                  }
                  final total = parseMoney(amount.text);
                  if (markSoldOut &&
                      record.quantity != null &&
                      units != record.quantity) {
                    throw FormatException(
                      'Enter all ${record.quantity} remaining units to mark this stock sold.',
                    );
                  }
                  Navigator.pop(
                    ctx,
                    _SaleInput(
                      quantity: units,
                      amountPaise: total,
                      markSoldOut: markSoldOut,
                      occurredAt: occurredAt,
                    ),
                  );
                } catch (e) {
                  setDialogState(
                    () => error = e.toString().replaceFirst(
                      'FormatException: ',
                      '',
                    ),
                  );
                }
              },
              child: const Text('Record sale'),
            ),
          ],
        ),
      ),
    );

    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        quantity.dispose();
        amount.dispose();
      }),
    );
    if (result == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await widget.controller.recordSale(
        record.id,
        quantity: result.quantity,
        totalAmountPaise: result.amountPaise,
        markSoldOut: result.markSoldOut,
        occurredAt: result.occurredAt,
        expectedRevision: _baseRevision,
      );
      if (mounted) {
        setState(() => _allowPop = true);
        Navigator.pop(context);
        showSaved(
          context,
          result.markSoldOut
              ? 'Sale recorded and stock added to reorder.'
              : 'Sale recorded. Tracking and stock are updated.',
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _history() async {
    final record = widget.record;
    if (record == null || _busy) return;
    final restored = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => VersionHistoryScreen(
          controller: widget.controller,
          medicineId: record.id,
        ),
      ),
    );
    if (restored == true && mounted) {
      setState(() => _allowPop = true);
      Navigator.pop(context);
      showSaved(context, 'Previous version restored.');
    }
  }

  void _changeExpiryFormat(bool monthOnly) {
    if (_expiryMonthOnly == monthOnly) return;
    final text = fields['expiry']!.text.trim();
    String next = '';
    if (text.isNotEmpty) {
      try {
        final date = parseDate(
          inputDateToIso(text, monthOnly: _expiryMonthOnly),
          monthEnd: _expiryMonthOnly,
        )!;
        next = inputDateText(date, monthOnly: monthOnly);
      } on FormatException {
        showError(
          context,
          'Finish or clear the expiry date before changing its format.',
        );
        return;
      }
    }
    setState(() {
      _expiryMonthOnly = monthOnly;
      fields['expiry']!.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
      _dirty = true;
    });
  }

  Widget _field(
    String key,
    String label, {
    String? hint,
    int lines = 1,
    TextInputType? keyboard,
    int? max,
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      controller: fields[key],
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: key == 'name'
          ? (value) => (value?.trim().isEmpty ?? true)
                ? 'Enter the medicine name.'
                : null
          : null,
      enabled: !_busy,
      onChanged: (_) => setState(() => _dirty = true),
      maxLines: lines,
      maxLength: max,
      keyboardType: keyboard,
      textInputAction: lines > 1
          ? TextInputAction.newline
          : TextInputAction.next,
      onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
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
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(20, 10, 20, 12),
          child: FilledButton.icon(
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
        ),
        body: SafeArea(
          child: Form(
            key: _formKey,
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(22, 10, 22, 30),
              children: [
                if (record != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _history,
                      icon: const Icon(Icons.history_rounded),
                      label: const Text('Version history'),
                    ),
                  ),
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
                                : (record.daysLeft(widget.controller.today) ?? 1) < 0
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
                      onPressed: _busy
                          ? null
                          : () {
                              setState(() {
                                _restocking = true;
                                _dirty = true;
                                fields['quantity']!.clear();
                                _expiryMonthOnly = true;
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
                    child: StatusPill(
                      'New stock · add the dates you know and save',
                    ),
                  ),
                if (record == null && widget.seed != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: Surface(
                      color: accentSoft,
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.auto_awesome_rounded, color: accent),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Useful identity data captured',
                                  style: TextStyle(fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'From ${widget.seed!.source}. Extra identity metadata stays in the record for search without making this form longer. Verify the pack dates yourself.',
                                  style: const TextStyle(
                                    color: muted,
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Text(
                  record == null
                      ? 'Add only what helps you later.'
                      : 'Keep the stock entry simple.',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Only the medicine name is required. Add one or more salts when useful; scanner/OCR text can stay messy on purpose so future searches still match the pack.',
                  style: TextStyle(color: muted, fontSize: 13, height: 1.45),
                ),
                const SizedBox(height: 24),
                FormSection(
                  title: 'Medicine details',
                  message: 'One short form for the information pharmacists actually use.',
                  icon: Icons.medication_outlined,
                  children: [
                    _field(
                      'name',
                      'Medicine name *',
                      hint: 'e.g. Paracetamol',
                    ),
                    _saltField(),
                    for (var i = 0; i < _extraSaltControllers.length; i++)
                      _saltField(
                        controller: _extraSaltControllers[i],
                        extraIndex: i,
                      ),
                    DateEntryField(
                      controller: fields['mfg']!,
                      label: 'Manufacturing date · optional',
                      enabled: !_busy,
                      onChanged: (_) => setState(() => _dirty = true),
                    ),
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Text(
                          'Expiry format',
                          style: TextStyle(
                            color: muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        for (final monthOnly in [true, false])
                          ChoiceChip(
                            label: Text(
                              monthOnly ? 'Month / year' : 'Full date',
                            ),
                            selected: _expiryMonthOnly == monthOnly,
                            onSelected: _busy
                                ? null
                                : (_) => _changeExpiryFormat(monthOnly),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    DateEntryField(
                      key: ValueKey('expiry-$_expiryMonthOnly'),
                      controller: fields['expiry']!,
                      label: 'Expiry date · optional',
                      monthOnly: _expiryMonthOnly,
                      enabled: !_busy,
                      onChanged: (_) => setState(() => _dirty = true),
                    ),
                    const SizedBox(height: 18),
                    _field(
                      'strength',
                      'Strength · optional',
                      hint: 'e.g. 500 mg or 650 mg',
                    ),
                    _field(
                      'location',
                      'Location · optional',
                      hint: 'Anything you recognise: Room 2, Rack B, Shelf 4…',
                      lines: 2,
                    ),
                    _field(
                      'barcode',
                      'Barcode · optional',
                      hint: 'Filled automatically when scanned',
                    ),
                    _field(
                      'ocrText',
                      'Captured search text · optional',
                      hint: 'Scanner/OCR words from the pack can stay here even if messy',
                      helper: 'This is intentionally broad search text. OCR can fill it automatically so the medicine is easier to find later.',
                      lines: 4,
                      max: 30000,
                    ),
                  ],
                ),
                if (_error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: Text(_error, style: const TextStyle(color: red)),
                  ),
                if (record != null) const SectionHeading('Stock actions'),
                if (record != null && !record.sold)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _recordSale,
                      icon: const Icon(Icons.point_of_sale_outlined),
                      label: const Text('Record sale / stock movement'),
                    ),
                  ),
                if (record != null && !record.sold)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _save(sold: true),
                      icon: const Icon(
                        Icons.check_circle_outline,
                        color: amber,
                      ),
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
      ),
    );
  }
}

class _SaleInput {
  const _SaleInput({
    required this.quantity,
    required this.amountPaise,
    required this.markSoldOut,
    required this.occurredAt,
  });

  final int quantity;
  final int? amountPaise;
  final bool markSoldOut;
  final DateTime? occurredAt;
}
