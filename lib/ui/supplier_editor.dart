import 'package:flutter/material.dart';

import '../domain/medicine.dart';
import '../domain/supplier.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';

String? _supplierCustomFieldLabelError(String value) {
  final clean = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.isEmpty) return 'Enter a field name.';
  if (clean.length > 100) return 'Use 100 characters or fewer.';
  if (isReservedSupplierCustomFieldLabel(clean)) {
    return 'This is already a built-in supplier or stock field.';
  }
  return null;
}

Future<String?> openSupplierEditor(
  BuildContext context,
  PharmacyController controller, {
  Supplier? supplier,
}) => Navigator.of(context).push<String>(
  MaterialPageRoute(
    builder: (_) => SupplierEditorScreen(
      controller: controller,
      supplier: supplier,
    ),
  ),
);

class SupplierEditorScreen extends StatefulWidget {
  const SupplierEditorScreen({
    super.key,
    required this.controller,
    this.supplier,
  });

  final PharmacyController controller;
  final Supplier? supplier;

  @override
  State<SupplierEditorScreen> createState() => _SupplierEditorScreenState();
}

class _SupplierEditorScreenState extends State<SupplierEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _returnDays;
  late final TextEditingController _address;
  late final TextEditingController _gstin;
  late final TextEditingController _drugLicenceNo;
  final List<_CustomFieldDraft> _custom = <_CustomFieldDraft>[];
  bool _busy = false, _dirty = false, _allowPop = false;

  @override
  void initState() {
    super.initState();
    final supplier = widget.supplier;
    _name = TextEditingController(text: supplier?.name ?? '');
    _returnDays = TextEditingController(
      text: supplier?.returnBeforeExpiryDays.toString() ?? '30',
    );
    _address = TextEditingController(text: supplier?.address ?? '');
    _gstin = TextEditingController(text: supplier?.gstin ?? '');
    _drugLicenceNo = TextEditingController(
      text: supplier?.drugLicenceNo ?? '',
    );
    for (final field in supplier?.customFields ?? const <SupplierCustomField>[]) {
      _custom.add(
        _CustomFieldDraft(
          id: field.id,
          label: TextEditingController(text: field.label),
          value: TextEditingController(text: field.value),
        ),
      );
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _returnDays.dispose();
    _address.dispose();
    _gstin.dispose();
    _drugLicenceNo.dispose();
    for (final field in _custom) {
      field.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (_dirty || _busy) return;
    setState(() => _dirty = true);
  }

  Future<bool> _confirmDiscard() async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard unsaved supplier changes?'),
          content: const Text(
            'Your saved supplier details will remain as they were.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _addMore() async {
    if (_busy) return;
    final label = TextEditingController();
    String error = '';
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add supplier field'),
          content: TextField(
            controller: label,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Field name',
              hintText: 'e.g. State code',
              errorText: error.isEmpty ? null : error,
            ),
            onSubmitted: (_) {
              final clean = label.text.replaceAll(RegExp(r'\s+'), ' ').trim();
              final issue = _supplierCustomFieldLabelError(clean);
              if (issue != null) {
                setDialogState(() => error = issue);
                return;
              }
              Navigator.pop(ctx, clean);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final clean = label.text.replaceAll(RegExp(r'\s+'), ' ').trim();
                final issue = _supplierCustomFieldLabelError(clean);
                if (issue != null) {
                  setDialogState(() => error = issue);
                  return;
                }
                Navigator.pop(ctx, clean);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    label.dispose();
    if (result == null || !mounted) return;
    setState(() {
      _custom.add(
        _CustomFieldDraft(
          id: newId(),
          label: TextEditingController(text: result),
          value: TextEditingController(),
        ),
      );
      _dirty = true;
    });
  }

  Future<void> _save() async {
    if (_busy || !(_formKey.currentState?.validate() ?? false)) return;
    final returnDays = int.tryParse(_returnDays.text.trim());
    if (returnDays == null || returnDays < 0 || returnDays > 3650) {
      showError(context, 'Return window must be between 0 and 3650 days.');
      return;
    }

    var completed = false;
    setState(() => _busy = true);
    try {
      final old = widget.supplier;
      final supplier = Supplier.fromJson(<String, dynamic>{
        'id': old?.id ?? newId(),
        'name': _name.text,
        'returnBeforeExpiryDays': returnDays,
        'address': _address.text,
        'gstin': _gstin.text,
        'drugLicenceNo': _drugLicenceNo.text,
        'customFields': [
          for (final field in _custom)
            <String, dynamic>{
              'id': field.id,
              'label': field.label.text,
              'value': field.value.text,
            },
        ],
        'revision': (old?.revision ?? 0) + 1,
      });
      await widget.controller.saveSupplier(
        supplier,
        expectedRevision: widget.controller.snapshot.revision,
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      completed = true;
      setState(() => _allowPop = true);
      Navigator.pop(context, supplier.id);
      showSavedWithMessenger(
        messenger,
        old == null ? 'Supplier added.' : 'Supplier updated.',
      );
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (!completed && mounted) setState(() => _busy = false);
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    TextInputType? keyboardType,
    int maxLines = 1,
    String? Function(String?)? validator,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: GlassPanel(
      tint: Colors.white,
      radius: 18,
      elevation: 1.05,
      child: TextFormField(
        controller: controller,
        enabled: !_busy,
        keyboardType: keyboardType,
        maxLines: maxLines,
        validator: validator,
        onChanged: (_) => _markDirty(),
        textInputAction:
            maxLines > 1 ? TextInputAction.newline : TextInputAction.next,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop || (!_dirty && !_busy),
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop || _busy || !_dirty) return;
      if (!await _confirmDiscard() || !context.mounted) return;
      setState(() => _allowPop = true);
      Navigator.pop(context);
    },
    child: Scaffold(
    appBar: AppBar(
      title: Text(widget.supplier == null ? 'Add supplier' : 'Supplier details'),
    ),
    bottomNavigationBar: SafeArea(
      minimum: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      child: FilledButton.icon(
        onPressed: _busy ? null : _save,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.check_rounded),
        label: const Text('Save supplier'),
      ),
    ),
    body: SafeArea(
      child: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 30),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            const ScreenIntro(
              title: 'Supplier details',
              message:
                  'Keep only the details you actually use. Stock stays in the Medicine Database; this profile only owns supplier facts and its return window.',
              icon: Icons.local_shipping_outlined,
            ),
            GlassPanel(
              tint: Colors.white,
              radius: 28,
              elevation: 1.06,
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  _field(
                    _name,
                    'Supplier name *',
                    hint: 'e.g. ABC Pharma Distributor',
                    validator: (value) => value?.trim().isEmpty == true
                        ? 'Enter the supplier name.'
                        : null,
                  ),
                  _field(
                    _returnDays,
                    'Return before expiry · days *',
                    hint: '30',
                    keyboardType: TextInputType.number,
                    validator: (value) {
                      final number = int.tryParse(value?.trim() ?? '');
                      if (number == null || number < 0 || number > 3650) {
                        return 'Enter 0 to 3650 days.';
                      }
                      return null;
                    },
                  ),
                  _field(
                    _address,
                    'Address',
                    hint: 'Optional',
                    maxLines: 2,
                  ),
                  _field(_gstin, 'GSTIN', hint: 'Optional'),
                  _field(
                    _drugLicenceNo,
                    'Drug licence no.',
                    hint: 'Optional',
                  ),
                  for (var index = 0; index < _custom.length; index++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Surface(
                        padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: _custom[index].label,
                                    enabled: !_busy,
                                    validator: (value) =>
                                        _supplierCustomFieldLabelError(
                                          value ?? '',
                                        ),
                                    onChanged: (_) => _markDirty(),
                                    decoration: const InputDecoration(
                                      labelText: 'Field name',
                                      filled: false,
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Remove field',
                                  onPressed: _busy
                                      ? null
                                      : () {
                                          final removed = _custom.removeAt(index);
                                          removed.dispose();
                                          setState(() => _dirty = true);
                                        },
                                  icon: const Icon(Icons.close_rounded),
                                ),
                              ],
                            ),
                            TextFormField(
                              controller: _custom[index].value,
                              enabled: !_busy,
                              maxLines: 2,
                              onChanged: (_) => _markDirty(),
                              decoration: const InputDecoration(
                                labelText: 'Value',
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _busy ? null : _addMore,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add more'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    ),
  );
}

class _CustomFieldDraft {
  _CustomFieldDraft({
    required this.id,
    required this.label,
    required this.value,
  });

  final String id;
  final TextEditingController label;
  final TextEditingController value;

  void dispose() {
    label.dispose();
    value.dispose();
  }
}
