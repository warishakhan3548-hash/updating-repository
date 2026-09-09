import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/date_input.dart';
import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/medicine_discovery.dart';
import '../domain/medicine_understanding.dart';
import '../state/operational_context.dart';
import '../state/pharmacy_controller.dart';
import 'date_field.dart';
import 'design.dart';
import 'version_history_screen.dart';

Future<void> openEditor(
  BuildContext context,
  PharmacyController controller, {
  Medicine? record,
  MedicineDraftSeed? seed,
  MedicineScanDraft? scanDraft,
  String barcode = '',
  String ocrText = '',
}) {
  if (record != null && !record.archived) {
    controller.rememberOperationalTarget(record.id);
  }
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => EditorScreen(
        controller: controller,
        record: record,
        seed: seed,
        scanDraft: scanDraft,
        barcode: barcode,
        ocrText: ocrText,
      ),
    ),
  );
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({
    super.key,
    required this.controller,
    this.record,
    this.seed,
    this.scanDraft,
    this.barcode = '',
    this.ocrText = '',
  });

  final PharmacyController controller;
  final Medicine? record;
  final MedicineDraftSeed? seed;
  final MedicineScanDraft? scanDraft;
  final String barcode, ocrText;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final fields = <String, TextEditingController>{};
  final _extraSaltControllers = <TextEditingController>[];
  final _formKey = GlobalKey<FormState>();
  late final int _baseRevision;

  bool _mfgMonthOnly = false, _expiryMonthOnly = true;
  String _form = '', _error = '';
  bool _busy = false, _restocking = false, _dirty = false, _allowPop = false;

  @override
  void initState() {
    super.initState();
    _baseRevision = widget.controller.snapshot.revision;
    final seed = widget.seed;
    final scan = widget.scanDraft;
    String identityValue(String? catalog, String scanned) =>
        catalog?.trim().isNotEmpty == true ? catalog!.trim() : scanned;
    final data =
        widget.record?.toJson() ??
        <String, dynamic>{
          'name': identityValue(seed?.name, scan?.name ?? ''),
          'brand': identityValue(seed?.brand, scan?.brand ?? ''),
          'manufacturer': identityValue(
            seed?.manufacturer,
            scan?.manufacturer ?? '',
          ),
          'salt': identityValue(seed?.salt, scan?.salt ?? ''),
          'strength': identityValue(seed?.strength, scan?.strength ?? ''),
          'mfg': scan?.mfg ?? '',
          'expiry': scan?.expiry ?? '',
          'batchNumber': scan?.batchNumber ?? '',
          'barcode': seed?.barcode.isNotEmpty == true
              ? seed!.barcode
              : scan?.barcode.isNotEmpty == true
              ? scan!.barcode
              : widget.barcode,
          'ocrText': widget.ocrText.trim().isNotEmpty
              ? widget.ocrText
              : scan?.searchableOcrText ?? '',
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
      'batchNumber',
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

    final record = widget.record;
    _form = record?.form ?? identityValue(seed?.form, scan?.form ?? '');
    _mfgMonthOnly = record?.mfg == null
        ? scan?.mfgMonthOnly ?? false
        : record!.mfgMonthOnly;
    _expiryMonthOnly = record?.expiry == null || record!.expiryMonthOnly;
    if (record?.expiry == null && scan?.expiry.isNotEmpty == true) {
      _expiryMonthOnly = scan!.expiryMonthOnly;
      final value = parseDate(scan.expiry, monthEnd: _expiryMonthOnly);
      if (value != null) {
        fields['expiry']!.text = inputDateText(
          value,
          monthOnly: _expiryMonthOnly,
        );
      }
    }
    if (record?.expiry != null) {
      fields['expiry']!.text = inputDateText(
        record!.expiry!,
        monthOnly: _expiryMonthOnly,
      );
    }
    if (record?.mfg != null) {
      fields['mfg']!.text = inputDateText(
        record!.mfg!,
        monthOnly: record.mfgMonthOnly,
      );
    } else if (scan?.mfg.isNotEmpty == true) {
      final value = parseDate(scan!.mfg, monthStart: _mfgMonthOnly);
      if (value != null) {
        fields['mfg']!.text = inputDateText(value, monthOnly: _mfgMonthOnly);
      }
    }
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

  OutlineInputBorder _editorBorder({Color? color, double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: color == null
            ? BorderSide.none
            : BorderSide(color: color, width: width),
      );

  InputDecoration _editorDecoration({
    required String label,
    String? hint,
    Widget? suffixIcon,
    bool multiline = false,
  }) => InputDecoration(
    labelText: label,
    hintText: hint,
    filled: false,
    counterText: '',
    alignLabelWithHint: multiline,
    border: _editorBorder(),
    enabledBorder: _editorBorder(color: primary.withValues(alpha: .08)),
    focusedBorder: _editorBorder(color: primary, width: 1.4),
    suffixIcon: suffixIcon,
  );

  Widget _raisedFieldSurface(Widget child) =>
      GlassPanel(tint: Colors.white, radius: 18, elevation: 1.12, child: child);

  Widget _saltField({TextEditingController? controller, int? extraIndex}) {
    final isPrimary = controller == null;
    final textController = controller ?? fields['salt']!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _raisedFieldSurface(
        TextFormField(
          controller: textController,
          enabled: !_busy,
          onChanged: (_) => setState(() => _dirty = true),
          textInputAction: TextInputAction.next,
          onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          decoration: _editorDecoration(
            label: isPrimary ? 'Salt name' : 'Another salt',
            hint: isPrimary ? 'e.g. Paracetamol' : 'e.g. Caffeine',
            suffixIcon: isPrimary
                ? IconButton(
                    tooltip: 'Add another salt',
                    onPressed: _busy ? null : _addSalt,
                    icon: const Icon(Icons.add_circle_rounded, color: primary),
                  )
                : IconButton(
                    tooltip: 'Remove this salt',
                    onPressed: _busy || extraIndex == null
                        ? null
                        : () => _removeSalt(extraIndex),
                    icon: const Icon(
                      Icons.remove_circle_outline_rounded,
                      color: red,
                    ),
                  ),
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
      'mfg': inputDateToIso(fields['mfg']!.text, monthOnly: _mfgMonthOnly),
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
      widget.controller.rememberOperationalTarget(draft.id);
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
      widget.controller.clearOperationalTarget(record.id);
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

    final today = widget.controller.today;
    final expiredNow = isExpiredOn(record, today);
    final preferred = widget.controller.preferredDispensingStock(record.id);
    final earlierStock = preferred != null && preferred.id != record.id
        ? preferred
        : null;

    String stockCue(Medicine medicine) {
      final expiry = medicine.expiry == null
          ? 'EXP unknown'
          : 'EXP ${medicine.expiryMonthOnly ? dateText(medicine.expiry!).substring(0, 7) : dateText(medicine.expiry!)}';
      return [
        expiry,
        if (medicine.batchNumber.isNotEmpty) 'Batch ${medicine.batchNumber}',
        if (medicine.address.isNotEmpty) medicine.address,
      ].join(' · ');
    }

    final String? safetyMessage = expiredNow
        ? 'This entry expired ${dateText(record.expiry!)}. A current sale is blocked; only enter a genuine historical sale dated on or before expiry.'
        : earlierStock != null
        ? 'FEFO: use ${earlierStock.title} (${stockCue(earlierStock)}) first to reduce expiry waste.'
        : record.expiry == null
        ? 'Expiry is not recorded. Verify the physical pack before dispensing.'
        : null;

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
                if (safetyMessage != null)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: (expiredNow ? red : amber).withValues(alpha: .09),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: (expiredNow ? red : amber).withValues(
                          alpha: .32,
                        ),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          expiredNow
                              ? Icons.block_rounded
                              : Icons.warning_amber_rounded,
                          color: expiredNow ? red : amber,
                          size: 20,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            safetyMessage,
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                      ],
                    ),
                  ),
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
                  onChanged: (value) =>
                      setDialogState(() => markSoldOut = value == true),
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
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: _raisedFieldSurface(
      TextFormField(
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
        decoration: _editorDecoration(
          label: label,
          hint: hint,
          multiline: lines > 1,
        ),
      ),
    ),
  );

  Widget _dateField({
    required TextEditingController controller,
    required String label,
    bool monthOnly = false,
    Key? key,
  }) => GlassPanel(
    key: key,
    tint: Colors.white,
    radius: 18,
    elevation: 1.12,
    child: DateEntryField(
      controller: controller,
      label: label,
      monthOnly: monthOnly,
      enabled: !_busy,
      showHelper: false,
      surfaceStyle: true,
      iconColor: green,
      onChanged: (_) => setState(() => _dirty = true),
    ),
  );

  Widget _expiryMode(bool monthOnly) {
    final selected = _expiryMonthOnly == monthOnly;
    return GlassPanel(
      tint: selected ? primarySoft : Colors.white,
      accentColor: primary,
      shadowColor: selected ? primary : null,
      radius: 18,
      elevation: selected ? 1.12 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _busy ? null : () => _changeExpiryFormat(monthOnly),
          borderRadius: BorderRadius.circular(18),
          splashColor: primary.withValues(alpha: .10),
          highlightColor: primary.withValues(alpha: .05),
          child: SizedBox(
            height: 54,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (selected) ...[
                  const Icon(Icons.check_rounded, color: primary, size: 20),
                  const SizedBox(width: 7),
                ],
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      monthOnly ? 'Month / year' : 'Full date',
                      maxLines: 1,
                      style: TextStyle(
                        color: selected ? primaryDeep : ink,
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w700,
                      ),
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

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final expiredNow =
        record != null &&
        !record.sold &&
        isExpiredOn(record, widget.controller.today);
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
                      onPressed: _busy
                          ? null
                          : () {
                              setState(() {
                                _restocking = true;
                                _dirty = true;
                                fields['quantity']!.clear();
                                _expiryMonthOnly = true;
                                _mfgMonthOnly = false;
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
                GlassPanel(
                  tint: Colors.white,
                  radius: 28,
                  elevation: 1.06,
                  padding: const EdgeInsets.all(12),
                  child: Column(
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
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _dateField(
                              controller: fields['mfg']!,
                              label: 'MFG date',
                              monthOnly: _mfgMonthOnly,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _dateField(
                              key: ValueKey('expiry-$_expiryMonthOnly'),
                              controller: fields['expiry']!,
                              label: 'EXP date',
                              monthOnly: _expiryMonthOnly,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: _expiryMode(true)),
                          const SizedBox(width: 10),
                          Expanded(child: _expiryMode(false)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _field(
                              'strength',
                              'Strength',
                              hint: '500 mg',
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _field(
                              'price',
                              'Amount (₹)',
                              hint: '0.00',
                              keyboard: const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                      _field(
                        'location',
                        'Location',
                        hint: 'Room 2, Rack B, Shelf 4…',
                      ),
                      _field('barcode', 'Barcode', hint: 'Scan or type'),
                      _field(
                        'batchNumber',
                        'Batch / lot number',
                        hint: 'Read from the medicine pack',
                      ),
                      _field(
                        'ocrText',
                        'Captured search text',
                        hint: 'Scanner/OCR words from the pack',
                        lines: 2,
                        max: 30000,
                      ),
                    ],
                  ),
                ),
                if (_error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 14, bottom: 18),
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
                    child: Tooltip(
                      message: expiredNow
                          ? 'Expired stock must be removed with reason Expired.'
                          : 'Mark the whole entry out of stock.',
                      child: OutlinedButton.icon(
                        onPressed: _busy || expiredNow
                            ? null
                            : () => _save(sold: true),
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
                  ),
                if (expiredNow)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Expired stock stays in the expiry workflow. Remove it with reason Expired; do not relabel it SOLD.',
                      style: TextStyle(color: red, fontSize: 12),
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
