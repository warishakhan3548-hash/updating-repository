import '../lib/domain/date_input.dart';
import '../lib/domain/medicine.dart';

void _equal(Object? actual, Object? expected) {
  if (actual != expected)
    throw StateError('Expected $expected, received $actual');
}

void _invalid(void Function() action) {
  try {
    action();
  } on FormatException {
    return;
  }
  throw StateError('An invalid date was accepted.');
}

Map<String, void Function()> dateInputContract() => {
  'month digits become ISO month': () =>
      _equal(inputDateToIso('042026', monthOnly: true), '2026-04'),
  'full date digits are day first': () =>
      _equal(inputDateToIso('04092026'), '2026-09-04'),
  'slash date is day first': () =>
      _equal(inputDateToIso('04/09/2026'), '2026-09-04'),
  'slash month retains precision': () =>
      _equal(inputDateToIso('04/2026', monthOnly: true), '2026-04'),
  'existing ISO date supported': () =>
      _equal(inputDateToIso('2026-09-04'), '2026-09-04'),
  'existing ISO month supported': () =>
      _equal(inputDateToIso('2026-04', monthOnly: true), '2026-04'),
  'clipboard whitespace supported': () =>
      _equal(inputDateToIso(' 04/09/2026\n'), '2026-09-04'),
  'Hindi digits supported': () =>
      _equal(inputDateToIso('०४०९२०२६'), '2026-09-04'),
  'Arabic digits supported': () =>
      _equal(inputDateToIso('٠٤٢٠٢٦', monthOnly: true), '2026-04'),
  'full-width digits supported': () =>
      _equal(inputDateToIso('０４０９２０２６'), '2026-09-04'),
  'unknown optional date remains unknown': () =>
      _equal(inputDateToIso('   '), null),
  'April month end stays April 30': () => _equal(
    dateText(
      parseDate(inputDateToIso('042026', monthOnly: true), monthEnd: true)!,
    ),
    '2026-04-30',
  ),
  'leap February month end': () => _equal(
    dateText(
      parseDate(inputDateToIso('022028', monthOnly: true), monthEnd: true)!,
    ),
    '2028-02-29',
  ),
  'leap day accepted': () => _equal(inputDateToIso('29022024'), '2024-02-29'),
  'non-leap February 29 rejected': () =>
      _invalid(() => inputDateToIso('29022026')),
  'April 31 rejected': () => _invalid(() => inputDateToIso('31042026')),
  'month 13 rejected': () =>
      _invalid(() => inputDateToIso('132026', monthOnly: true)),
  'day zero rejected': () => _invalid(() => inputDateToIso('00042026')),
  'incomplete date rejected': () => _invalid(() => inputDateToIso('04/09/202')),
  'excess digits rejected': () => _invalid(() => inputDateToIso('040920260')),
  'ambiguous two-digit year rejected': () =>
      _invalid(() => inputDateToIso('04/09/26')),
  'month-only stock round trip': () {
    final medicine = Medicine.fromJson({
      'id': 'month-test',
      'name': 'Example',
      'expiry': inputDateToIso('042026', monthOnly: true),
    });
    _equal(medicine.expiryMonthOnly, true);
    _equal(medicine.toJson()['expiry'], '2026-04');
    _equal(medicine.daysLeft(DateTime.utc(2026, 4, 30)), 0);
    _equal(medicine.daysLeft(DateTime.utc(2026, 5, 1)), -1);
  },
  'manufacturing after expiry still rejected': () => _invalid(
    () => Medicine.fromJson({
      'id': 'invalid-order',
      'name': 'Example',
      'mfg': inputDateToIso('01052026'),
      'expiry': inputDateToIso('042026', monthOnly: true),
    }),
  ),
  'displaying a month does not invent a day': () => _equal(
    inputDateText(DateTime.utc(2026, 4, 30), monthOnly: true),
    '04/2026',
  ),
};
