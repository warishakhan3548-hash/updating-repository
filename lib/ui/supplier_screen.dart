import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/medicine.dart';
import '../domain/supplier.dart';
import '../state/pharmacy_controller.dart';
import '../services/supplier_return_service.dart';
import 'design.dart';
import 'editor_screen.dart';
import 'supplier_editor.dart';

class SupplierScreen extends StatefulWidget {
  const SupplierScreen({super.key, required this.controller});

  final PharmacyController controller;

  @override
  State<SupplierScreen> createState() => _SupplierScreenState();
}

class _SupplierScreenState extends State<SupplierScreen> {
  PharmacyController get controller => widget.controller;

  bool _routeOpening = false;

  Future<void> _runExclusiveRoute(Future<void> Function() action) async {
    if (_routeOpening || !mounted) return;
    setState(() => _routeOpening = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _routeOpening = false);
    }
  }

  Future<void> _add() => _runExclusiveRoute(() async {
    final id = await openSupplierEditor(context, controller);
    if (!mounted || id == null) return;
    final supplier = controller.snapshot.suppliers[id];
    if (supplier == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SupplierDetailScreen(
          controller: controller,
          supplierId: supplier.id,
        ),
      ),
    );
  });

  Future<void> _openSupplier(Supplier supplier) => _runExclusiveRoute(
    () => Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SupplierDetailScreen(
          controller: controller,
          supplierId: supplier.id,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Supplier details')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _routeOpening ? null : () => unawaited(_add()),
      icon: const Icon(Icons.add_rounded),
      label: const Text('Add supplier'),
    ),
    body: SafeArea(
      top: false,
      child: ActiveListenableBuilder(
        listenable: controller,
        // Directory rows and return windows depend only on linked medicine
        // facts, supplier metadata and the civil day.
        rebuildToken: () => (
          controller.snapshot.records,
          controller.snapshot.suppliers,
          controller.today,
        ),
        builder: (context, _) {
          final suppliers = controller.suppliers.toList(growable: false)
            ..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            );
          final due = controller.supplierReturns;
          final dueCounts = <String, int>{};
          for (final item in due) {
            dueCounts[item.supplier.id] =
                (dueCounts[item.supplier.id] ?? 0) + 1;
          }

          if (suppliers.isEmpty) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(22, 26, 22, 120),
              children: [
                const ScreenIntro(
                  title: 'No suppliers yet',
                  message:
                      'Add a supplier once, set its return-before-expiry window, then link exact stock entries from Medicine Details.',
                  icon: Icons.local_shipping_outlined,
                ),
                FilledButton.icon(
                  onPressed: _routeOpening ? null : () => unawaited(_add()),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add first supplier'),
                ),
              ],
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 110),
            itemCount: suppliers.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '${suppliers.length} supplier${suppliers.length == 1 ? '' : 's'} · '
                    '${due.length} return due',
                    style: const TextStyle(color: muted, fontSize: 13),
                  ),
                );
              }

              final supplier = suppliers[index - 1];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Card(
                  elevation: 0,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: _routeOpening
                        ? null
                        : () => unawaited(_openSupplier(supplier)),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const DepthIcon(
                            Icons.local_shipping_outlined,
                            size: 42,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  supplier.name,
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Return ${supplier.returnBeforeExpiryDays} days before expiry'
                                  ' · ${dueCounts[supplier.id] ?? 0} due',
                                  style: const TextStyle(
                                    color: muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    ),
  );
}

class SupplierDetailScreen extends StatefulWidget {
  const SupplierDetailScreen({
    super.key,
    required this.controller,
    required this.supplierId,
  });

  final PharmacyController controller;
  final String supplierId;

  @override
  State<SupplierDetailScreen> createState() => _SupplierDetailScreenState();
}

class _SupplierDetailScreenState extends State<SupplierDetailScreen> {
  final _returnService = SupplierReturnService();
  bool _dueOnly = true;
  bool _returning = false;

  Future<void> _edit(Supplier supplier) async {
    await openSupplierEditor(
      context,
      widget.controller,
      supplier: supplier,
    );
  }

  Future<void> _prepareReturn(
    Supplier supplier,
    Set<String> dueIds,
  ) async {
    if (_returning || dueIds.isEmpty) return;
    setState(() => _returning = true);
    try {
      final review = widget.controller.reviewSupplierReturn(
        supplier.id,
        dueIds,
      );
      final shared = await _returnService.share(review);
      if (!mounted || !shared) return;

      final confirm = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Supplier को stock दे दिया?'),
          content: Text(
            '${review.lines.length} stock entries की return list share हो गई है. '
            'सिर्फ तभी Returned करें जब physical stock supplier को सच में hand over हो चुका हो. '
            'इसके बाद ये entries active stock से हटकर Removed history में रहेंगी.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('अभी नहीं'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Mark returned'),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
      await widget.controller.applySupplierReturn(review);
      if (!mounted) return;
      showSaved(
        context,
        '${review.lines.length} stock entries supplier return में move हो गईं.',
      );
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _returning = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Supplier')),
    body: SafeArea(
      top: false,
      child: ActiveListenableBuilder(
        listenable: widget.controller,
        rebuildToken: () => (
          widget.controller.snapshot.records,
          widget.controller.snapshot.suppliers,
          widget.controller.today,
        ),
        builder: (context, _) {
          final supplier =
              widget.controller.snapshot.suppliers[widget.supplierId];
          if (supplier == null) {
            return const Center(child: Text('Supplier is no longer available.'));
          }

          final all = widget.controller.records
              .where(
                (medicine) =>
                    !medicine.archived &&
                    medicine.supplierId == supplier.id,
              )
              .toList(growable: false)
            ..sort((a, b) {
              final left = a.expiry;
              final right = b.expiry;
              if (left == null && right != null) return 1;
              if (left != null && right == null) return -1;
              if (left != null && right != null) {
                final order = left.compareTo(right);
                if (order != 0) return order;
              }
              return a.title.compareTo(b.title);
            });
          final dueItems = widget.controller.supplierReturns
              .where((item) => item.supplier.id == supplier.id)
              .toList(growable: false);
          final dueIds = dueItems.map((item) => item.medicine.id).toSet();
          final returnableIds = dueItems
              .where(
                (item) =>
                    item.medicine.quantity != null &&
                    item.medicine.quantity! > 0,
              )
              .map((item) => item.medicine.id)
              .toSet();
          final unknownQuantityDue = dueIds.length - returnableIds.length;
          final visible = _dueOnly
              ? all.where((medicine) => dueIds.contains(medicine.id)).toList()
              : all;

          // A supplier can own hundreds or thousands of exact stock lots. Keep
          // the deterministic projection up front, but materialize cards only
          // as they approach the viewport so opening this route stays smooth.
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 30),
            itemCount: visible.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Surface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const DepthIcon(
                                Icons.local_shipping_outlined,
                                size: 42,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      supplier.name,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleLarge,
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      'Return ${supplier.returnBeforeExpiryDays} days before expiry',
                                      style: const TextStyle(
                                        color: primary,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: 'Edit supplier',
                                onPressed: () => _edit(supplier),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                            ],
                          ),
                          if (supplier.address.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Text(
                              supplier.address,
                              style: const TextStyle(
                                color: muted,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                          if (supplier.gstin.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              'GSTIN · ${supplier.gstin}',
                              style: const TextStyle(
                                color: muted,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                          if (supplier.drugLicenceNo.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              'Drug licence · ${supplier.drugLicenceNo}',
                              style: const TextStyle(
                                color: muted,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                          for (final field in supplier.customFields) ...[
                            const SizedBox(height: 6),
                            Text(
                              '${field.label} · ${field.value.isEmpty ? '—' : field.value}',
                              style: const TextStyle(
                                color: muted,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: Text('Return due · ${dueIds.length}'),
                          selected: _dueOnly,
                          onSelected: (_) => setState(() => _dueOnly = true),
                        ),
                        ChoiceChip(
                          label: Text('All stock · ${all.length}'),
                          selected: !_dueOnly,
                          onSelected: (_) => setState(() => _dueOnly = false),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (returnableIds.isNotEmpty)
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _returning
                              ? null
                              : () => _prepareReturn(supplier, returnableIds),
                          icon: _returning
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.picture_as_pdf_outlined),
                          label: Text(
                            _returning
                                ? 'Preparing return…'
                                : 'Prepare return · ${returnableIds.length}',
                          ),
                        ),
                      ),
                    if (unknownQuantityDue > 0) ...[
                      const SizedBox(height: 8),
                      Text(
                        '$unknownQuantityDue due stock ${unknownQuantityDue == 1 ? 'entry needs' : 'entries need'} a quantity count before it can be added to the return PDF.',
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    ],
                    if (dueIds.isNotEmpty) const SizedBox(height: 14),
                    if (visible.isEmpty)
                      Surface(
                        child: Text(
                          _dueOnly
                              ? 'No linked medicine has reached this supplier’s return window yet.'
                              : 'No active stock is linked to this supplier yet.',
                          style: const TextStyle(color: muted),
                        ),
                      ),
                  ],
                );
              }

              final medicine = visible[index - 1];
              return _SupplierMedicineRow(
                key: ValueKey(medicine.id),
                medicine: medicine,
                today: widget.controller.today,
                due: dueIds.contains(medicine.id),
                onTap: () => openEditor(
                  context,
                  widget.controller,
                  record: medicine,
                ),
              );
            },
          );
        },
      ),
    ),
  );
}

class _SupplierMedicineRow extends StatelessWidget {
  const _SupplierMedicineRow({
    super.key,
    required this.medicine,
    required this.today,
    required this.due,
    required this.onTap,
  });

  final Medicine medicine;
  final DateTime today;
  final bool due;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final daysLeft = medicine.daysLeft(today);
    final cue = <String>[
      if (medicine.batchNumber.isNotEmpty) 'Batch ${medicine.batchNumber}',
      if (medicine.expiry != null)
        'EXP ${medicine.expiryMonthOnly ? dateText(medicine.expiry!).substring(0, 7) : dateText(medicine.expiry!)}',
      if (medicine.quantity != null) '${medicine.quantity} units',
      if (medicine.address.isNotEmpty) medicine.address,
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: 9),
      elevation: 0,
      child: ListTile(
        onTap: onTap,
        leading: Icon(
          due ? Icons.assignment_return_outlined : Icons.medication_outlined,
          color: primary,
        ),
        title: Text(medicine.title),
        subtitle: Text(
          [
            cue,
            if (due && daysLeft != null)
              'Return window active · $daysLeft days left',
          ].where((value) => value.isNotEmpty).join('\n'),
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}
