from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    target = Path(path)
    text = target.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected exactly one guarded match, found {count}')
    target.write_text(text.replace(old, new, 1))


replace_once(
    'lib/data/inventory_database.dart',
    """  final eventTimeRaw = event['time'];
  if (eventTimeRaw is! String) {
    throw const FormatException('Inventory event time is missing.');
  }
  final operationTime = DateTime.tryParse(eventTimeRaw);
  if (operationTime == null ||
      operationTime.year < 2000 ||
      operationTime.year > 2200) {
    throw const FormatException('Inventory event time is invalid.');
  }
  final operationDay = civilDay(operationTime);
""",
    """  final eventTimeRaw = event['time'];
  if (eventTimeRaw is! String) {
    throw const FormatException('Inventory event time is missing.');
  }
  final operationTime = DateTime.tryParse(eventTimeRaw);
  if (operationTime == null ||
      operationTime.year < 2000 ||
      operationTime.year > 2200) {
    throw const FormatException('Inventory event time is invalid.');
  }
  // The audit instant is normalized to UTC for durable ordering, but the
  // pharmacist's business day must retain the controller/device local civil
  // date. Re-deriving the day from the UTC instant would shift transactions
  // around local midnight in positive/negative UTC offsets.
  final operationDayRaw = event['businessDay'];
  final parsedOperationDay = operationDayRaw is String
      ? DateTime.tryParse(operationDayRaw)
      : null;
  if (parsedOperationDay == null ||
      parsedOperationDay.year < 2000 ||
      parsedOperationDay.year > 2200 ||
      dateText(parsedOperationDay) != operationDayRaw) {
    throw const FormatException('Inventory business day is invalid.');
  }
  final operationDay = civilDay(parsedOperationDay);
""",
)

replace_once(
    'test/authoritative_business_clock_test.dart',
    """import 'package:aaris_pharmacy/data/inventory_database.dart';
""",
    """import 'dart:io';

import 'package:aaris_pharmacy/data/inventory_database.dart';
""",
)

replace_once(
    'test/authoritative_business_clock_test.dart',
    """    test('operation time validation fails closed before persistence', () async {
""",
    """    test('local business day survives UTC audit normalization', () async {
      final storage = MemoryInventoryStorage();
      final operationTime = DateTime(2027, 1, 1, 0, 30);
      final result = await storage.commit(
        InventoryMutation(
          expectedRevision: 0,
          label: 'Local-midnight stock intake',
          upserts: [_futureDatedStock('local-midnight')],
          operationTime: operationTime,
        ),
      );

      expect(result.events.first['businessDay'], '2027-01-01');
      expect(result.records['local-midnight']?.mfg, DateTime.utc(2027, 1, 1));
      expect(
        result.events.first['time'],
        operationTime.toUtc().toIso8601String(),
      );

      if (Platform.environment['AARIS_REQUIRE_NON_UTC_CLOCK_TEST'] == '1') {
        expect(
          operationTime.timeZoneOffset,
          const Duration(hours: 5, minutes: 30),
        );
        expect(
          DateTime.parse(result.events.first['time'] as String).day,
          31,
          reason:
              'The UTC audit instant must be allowed to fall on the previous UTC day while businessDay stays Jan 1.',
        );
      }
    });

    test('operation time validation fails closed before persistence', () async {
""",
)
