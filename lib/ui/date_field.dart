import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/date_input.dart';
import '../domain/medicine.dart';

/// Inserts separators while keeping edits, selections and IME composition usable.
class DateInputFormatter extends TextInputFormatter {
  const DateInputFormatter({this.monthOnly = false});
  final bool monthOnly;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!newValue.composing.isCollapsed) return newValue;
    var raw = normalizeDateDigits(newValue.text);
    if (raw == oldValue.text) return newValue;
    final isoPattern = RegExp(monthOnly
        ? r'^\d{4}-\d{2}$'
        : r'^\d{4}-\d{2}-\d{2}$');
    if (isoPattern.hasMatch(raw)) {
      // Preserve invalid dates for visible validation instead of inventing a day.
      final pieces = raw.split('-');
      final text = monthOnly
          ? '${pieces[1]}/${pieces[0]}'
          : '${pieces[2]}/${pieces[1]}/${pieces[0]}';
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    if (RegExp(r'[^0-9/\s.\\-]').hasMatch(raw)) return oldValue;
    var digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    final limit = monthOnly ? 6 : 8;
    if (digits.length > limit) return oldValue;
    int countBefore(int offset) => raw
        .substring(0, offset.clamp(0, raw.length))
        .replaceAll(RegExp(r'[^0-9]'), '')
        .length;
    var base = countBefore(newValue.selection.baseOffset);
    var extent = countBefore(newValue.selection.extentOffset);
    final deleting = newValue.text.length < oldValue.text.length;
    // Backspacing over an inserted slash also removes its preceding digit.
    if (deleting &&
        oldValue.selection.isCollapsed &&
        newValue.selection.isCollapsed &&
        oldValue.text.length - newValue.text.length == 1 &&
        digits == oldValue.text.replaceAll(RegExp(r'[^0-9]'), '') &&
        base > 0 &&
        newValue.selection.baseOffset < oldValue.selection.baseOffset) {
      digits = digits.substring(0, base - 1) + digits.substring(base);
      base--;
      extent = base;
    }
    final boundaries = monthOnly ? const [2] : const [2, 4];
    final buffer = StringBuffer();
    final offsets = <int>[0];
    for (var i = 0; i < digits.length; i++) {
      buffer.write(digits[i]);
      if (boundaries.contains(i + 1) &&
          (i + 1 < digits.length || !deleting)) buffer.write('/');
      offsets.add(buffer.length);
    }
    return TextEditingValue(
      text: buffer.toString(),
      selection: newValue.selection.isValid
          ? TextSelection(
              baseOffset: offsets[base.clamp(0, digits.length)],
              extentOffset: offsets[extent.clamp(0, digits.length)],
              affinity: newValue.selection.affinity,
              isDirectional: newValue.selection.isDirectional,
            )
          : TextSelection.collapsed(offset: buffer.length),
    );
  }
}

class DateEntryField extends StatelessWidget {
  const DateEntryField({
    super.key,
    required this.controller,
    required this.label,
    this.monthOnly = false,
    this.enabled = true,
    this.required = false,
    this.onChanged,
    this.firstDate,
    this.lastDate,
  });
  final TextEditingController controller;
  final String label;
  final bool monthOnly, enabled, required;
  final ValueChanged<String>? onChanged;
  final DateTime? firstDate, lastDate;

  String? _validate(String? value) {
    try {
      final iso = inputDateToIso(value ?? '', monthOnly: monthOnly);
      if (iso == null) return required ? 'Enter a date.' : null;
      final date = parseDate(iso, monthEnd: monthOnly)!;
      if (firstDate != null && date.isBefore(civilDay(firstDate!))) {
        return 'Choose ${inputDateText(firstDate!)} or later.';
      }
      if (lastDate != null && date.isAfter(civilDay(lastDate!))) {
        return 'Choose ${inputDateText(lastDate!)} or earlier.';
      }
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  Future<void> _calendar(BuildContext context) async {
    DateTime local(DateTime d) => DateTime(d.year, d.month, d.day);
    final first = local(firstDate ?? DateTime(1900));
    final last = local(lastDate ?? DateTime(2200, 12, 31));
    var initial = DateTime.now();
    try {
      initial = parseDate(inputDateToIso(controller.text, monthOnly: monthOnly),
              monthEnd: monthOnly) ?? initial;
    } on FormatException { /* An incomplete entry can still open the calendar. */ }
    initial = local(initial);
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final chosen = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      initialEntryMode: DatePickerEntryMode.calendarOnly,
      helpText: monthOnly ? 'Choose a day in the printed month' : label,
    );
    if (chosen == null || !context.mounted) return;
    final text = inputDateText(chosen, monthOnly: monthOnly);
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    onChanged?.call(text);
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    enabled: enabled,
    keyboardType: TextInputType.number,
    textInputAction: TextInputAction.next,
    autocorrect: false,
    enableSuggestions: false,
    inputFormatters: [DateInputFormatter(monthOnly: monthOnly)],
    autovalidateMode: AutovalidateMode.onUserInteraction,
    validator: _validate,
    onChanged: onChanged,
    onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
    decoration: InputDecoration(
      labelText: label,
      hintText: monthOnly ? 'MM/YYYY' : 'DD/MM/YYYY',
      helperText: monthOnly
          ? 'Type 042026 → 04/2026. Valid through the end of the month.'
          : 'Type 04092026 → 04/09/2026. Slashes are added for you.',
      helperMaxLines: 3,
      errorMaxLines: 3,
      suffixIcon: IconButton(
        tooltip: 'Choose $label from calendar',
        onPressed: enabled ? () => _calendar(context) : null,
        icon: const Icon(Icons.calendar_month_outlined),
      ),
    ),
  );
}

Future<DateTimeRange?> showDateEntryDialog({
  required BuildContext context,
  required String title,
  required DateTime firstDate,
  required DateTime lastDate,
  required DateTime initialDate,
  DateTime? initialEnd,
}) => showDialog<DateTimeRange>(
  context: context,
  builder: (_) => _DateEntryDialog(
    title: title, firstDate: firstDate, lastDate: lastDate,
    initialDate: initialDate, initialEnd: initialEnd,
  ),
);

class _DateEntryDialog extends StatefulWidget {
  const _DateEntryDialog({required this.title, required this.firstDate,
    required this.lastDate, required this.initialDate, this.initialEnd});
  final String title;
  final DateTime firstDate, lastDate, initialDate;
  final DateTime? initialEnd;
  @override
  State<_DateEntryDialog> createState() => _DateEntryDialogState();
}

class _DateEntryDialogState extends State<_DateEntryDialog> {
  final form = GlobalKey<FormState>();
  late final start = TextEditingController(text: inputDateText(widget.initialDate));
  late final end = TextEditingController(text: inputDateText(widget.initialEnd ?? widget.initialDate));
  String? error;
  @override
  void dispose() { start.dispose(); end.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: Form(
        key: form,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          DateEntryField(controller: start,
            label: widget.initialEnd == null ? 'Date' : 'From date',
            required: true, firstDate: widget.firstDate, lastDate: widget.lastDate),
          if (widget.initialEnd != null) ...[
            const SizedBox(height: 20),
            DateEntryField(controller: end, label: 'To date', required: true,
              firstDate: widget.firstDate, lastDate: widget.lastDate),
          ],
          if (error != null) Padding(padding: const EdgeInsets.only(top: 12),
            child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        ]),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () {
        if (!form.currentState!.validate()) return;
        final from = parseDate(inputDateToIso(start.text))!;
        final to = widget.initialEnd == null ? from : parseDate(inputDateToIso(end.text))!;
        if (to.isBefore(from)) {
          setState(() => error = 'To date must be on or after From date.');
          return;
        }
        Navigator.pop(context, DateTimeRange(start: from, end: to));
      }, child: const Text('Use date')),
    ],
  );
}
