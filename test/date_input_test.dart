import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/ui/date_field.dart';
import 'date_input_contract.dart';

TextEditingValue _value(String text, {int? offset}) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: offset ?? text.length),
);

void main() {
  for (final entry in dateInputContract().entries) {
    test(entry.key, entry.value);
  }

  test('typing month digits inserts the slash immediately after 04', () {
    const formatter = DateInputFormatter(monthOnly: true);
    var value = _value('');
    final displayed = <String>[];
    for (final digit in '042026'.split('')) {
      value = formatter.formatEditUpdate(value, _value(value.text + digit));
      displayed.add(value.text);
      expect(value.selection.extentOffset, value.text.length);
    }
    expect(displayed, ['0', '04/', '04/2', '04/20', '04/202', '04/2026']);
  });
  test('typing a full date inserts both slashes', () {
    const formatter = DateInputFormatter();
    var value = _value('');
    for (final digit in '04092026'.split('')) {
      value = formatter.formatEditUpdate(value, _value(value.text + digit));
    }
    expect(value.text, '04/09/2026');
    expect(value.selection.extentOffset, 10);
  });
  test('backspace crosses automatic slash and can clear the field', () {
    const formatter = DateInputFormatter(monthOnly: true);
    var value = formatter.formatEditUpdate(_value('04/'), _value('04'));
    expect(value.text, '0');
    expect(value.selection.extentOffset, 1);
    value = formatter.formatEditUpdate(value, _value(''));
    expect(value.text, '');
  });
  test('replace selected month without moving the year', () {
    const formatter = DateInputFormatter();
    const old = TextEditingValue(
      text: '04/09/2026',
      selection: TextSelection(baseOffset: 3, extentOffset: 5),
    );
    final result = formatter.formatEditUpdate(
      old,
      _value('04/12/2026', offset: 5),
    );
    expect(result.text, '04/12/2026');
    expect(result.selection.extentOffset, 6);
  });
  test('paste supports ISO with whitespace and normal date separators', () {
    const formatter = DateInputFormatter();
    for (final text in [
      '2026-09-04',
      ' 2026-09-04\n',
      '04/09/2026',
      '04-09-2026',
      '०४०९२०२६',
    ]) {
      expect(
        formatter.formatEditUpdate(_value(''), _value(text)).text,
        '04/09/2026',
      );
    }
    expect(
      const DateInputFormatter(
        monthOnly: true,
      ).formatEditUpdate(_value(''), _value('2026-04')).text,
      '04/2026',
    );
  });
  test('active keyboard composition is not rewritten', () {
    const formatter = DateInputFormatter();
    const composing = TextEditingValue(
      text: '०४',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    expect(formatter.formatEditUpdate(_value(''), composing), composing);
    expect(formatter.formatEditUpdate(composing, _value('०४')).text, '04/');
  });
  test('extra digits and unrelated clipboard text do not corrupt the date', () {
    const formatter = DateInputFormatter();
    final old = _value('04/09/2026');
    expect(formatter.formatEditUpdate(old, _value('04/09/20267')), old);
    expect(formatter.formatEditUpdate(old, _value('expiry unknown')), old);
  });
  test('selection direction is preserved when a date is selected', () {
    const incoming = TextEditingValue(
      text: '04092026',
      selection: TextSelection(
        baseOffset: 8,
        extentOffset: 2,
        isDirectional: true,
      ),
    );
    final result = const DateInputFormatter().formatEditUpdate(
      _value(''),
      incoming,
    );
    expect(result.selection.baseOffset, 10);
    expect(result.selection.extentOffset, 3);
    expect(result.selection.isDirectional, true);
  });
}
