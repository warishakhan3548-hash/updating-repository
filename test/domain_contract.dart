import 'dart:convert';

import '../lib/domain/medicine.dart';
import '../lib/domain/inventory.dart';
import '../lib/domain/search.dart';
import '../lib/domain/ai_protocol.dart';
import '../lib/domain/backup.dart';
import '../lib/domain/sales_overview.dart';
import '../lib/domain/tracking.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void rejects(void Function() action) {
  var rejected = false;
  try {
    action();
  } catch (_) {
    rejected = true;
  }
  check(rejected, 'Invalid input was accepted.');
}

Medicine stock(
  String id, {
  String name = 'Paracetamol',
  String strength = '500mg',
  String expiry = '2026-09-10',
  String barcode = '',
  String batchNumber = '',
  String notes = '',
  String salt = '',
  int? quantity = 10,
  int? price = 200,
  String form = 'Tablet',
  bool sold = false,
}) => Medicine.fromJson({
  'id': id,
  'name': name,
  'strength': strength,
  'expiry': expiry,
  'barcode': barcode,
  'batchNumber': batchNumber,
  'notes': notes,
  'salt': salt,
  'quantity': sold ? 0 : quantity,
  'unitPricePaise': price,
  'form': form,
  'sold': sold,
});

final contractToday = DateTime(2026, 9, 7, 23, 59);
const contractSettings = WarningSettings();

Map<String, void Function()> domainContract() {
  String envelope(
    List<Map<String, dynamic>> actions, {
    int revision = 0,
    String requestId = 'request_12345',
    Map<String, dynamic> extra = const {},
  }) => jsonEncode({
    'schema': pharmacySchema,
    'requestId': requestId,
    'baseRevision': revision,
    'actions': actions,
    ...extra,
  });
  final current = stock('existing');
  AiPlan parse(
    String text, {
    int revision = 0,
    Set<String> receipts = const {},
  }) => parseAiPlan(
    text,
    {'existing': current},
    revision,
    receipts,
    contractToday,
  );
  return {
    'expiry today stays in short warning until tomorrow': () {
      final m = stock('a', expiry: '2026-09-07');
      check(
        statusOf(m, contractSettings, contractToday).status ==
            StockStatus.shortExpiry,
        'Today expired too soon.',
      );
      check(
        m.daysLeft(contractToday) == 0,
        'Time of day changed civil expiry.',
      );
      check(
        statusOf(m, contractSettings, DateTime(2026, 9, 8)).status ==
            StockStatus.expired,
        'Did not expire on following day.',
      );
    },
    'month-only expiry handles leap years': () {
      check(
        dateText(parseDate('2028-02', monthEnd: true)!) == '2028-02-29',
        'Leap month wrong.',
      );
      check(
        dateText(parseDate('2027-02', monthEnd: true)!) == '2027-02-28',
        'Non-leap month wrong.',
      );
    },
    'invalid dates never normalize silently': () {
      for (final date in [
        '2026-02-29',
        '2026-13-01',
        '2026-04-31',
        'garbage',
      ]) {
        rejects(() => parseDate(date, monthEnd: true));
      }
    },
    'MFG after expiry is rejected': () {
      rejects(
        () => Medicine.fromJson({
          'id': 'x',
          'name': 'x',
          'mfg': '2027-01-01',
          'expiry': '2026-01-01',
        }),
      );
    },
    'missing expiry has no warning': () {
      final m = stock('a', expiry: '');
      for (final scope in [
        SearchScope.shortExpiry,
        SearchScope.monthExpiry,
        SearchScope.expired,
      ]) {
        check(
          !inScope(m, scope, contractSettings, contractToday),
          'Unknown expiry classified.',
        );
      }
    },
    'warning categories are disjoint at boundaries': () {
      for (final days in [0, 8, 9, 60, 61]) {
        final m = stock(
          'x',
          expiry: dateText(civilDay(contractToday).add(Duration(days: days))),
        );
        final scopes = [
          SearchScope.shortExpiry,
          SearchScope.monthExpiry,
          SearchScope.expired,
        ].where((s) => inScope(m, s, contractSettings, contractToday));
        check(
          scopes.length == (days <= 60 ? 1 : 0),
          'Wrong category overlap for $days.',
        );
      }
    },
    'red border matches the selected day baseline': () {
      check(
        (statusOf(
                      stock('a', expiry: '2026-09-10'),
                      contractSettings,
                      contractToday,
                    ).redFraction -
                    .625)
                .abs() <
            .00001,
        '3 of 8 days border incorrect.',
      );
      check(
        statusOf(
              stock('b', expiry: '2026-09-15'),
              contractSettings,
              contractToday,
            ).redFraction ==
            0,
        'Full window is not green.',
      );
    },
    'month perimeter uses 60-day baseline': () {
      final m = stock(
        'a',
        expiry: dateText(civilDay(contractToday).add(const Duration(days: 45))),
      );
      check(
        statusOf(m, contractSettings, contractToday).redFraction == .25,
        '45 of60 should be25% red.',
      );
      check(
        statusOf(m, contractSettings, contractToday).label ==
            '1 month 15 days left',
        'Month/day label lost remaining days.',
      );
    },
    'sold overrides expiry but never deletes the entry': () {
      final m = stock('a', sold: true, expiry: '2020-01-01');
      check(
        inScope(m, SearchScope.sold, contractSettings, contractToday),
        'Sold record lost.',
      );
      check(
        !inScope(m, SearchScope.expired, contractSettings, contractToday),
        'Sold leaks into expired.',
      );
      check(
        inScope(m, SearchScope.all, contractSettings, contractToday),
        'Sold not globally searchable.',
      );
    },
    'quantity zero does not automatically mark sold': () {
      check(
        statusOf(
              stock('a', quantity: 0),
              contractSettings,
              contractToday,
            ).status !=
            StockStatus.sold,
        'Sold was inferred.',
      );
    },
    'archived entries disappear from all regular scopes': () {
      final m = stock('a').patch({'archived': true});
      for (final scope in SearchScope.values) {
        check(
          !inScope(m, scope, contractSettings, contractToday),
          'Archive leak.',
        );
      }
    },
    'same product can have distinct expiry entries': () {
      final list = [
        stock('a', expiry: '2026-09-12'),
        stock('b', expiry: '2026-09-08'),
      ]..sort((a, b) => expiryOrder(a, b, contractToday));
      check(list.first.id == 'b', 'Nearest stock is not first.');
    },
    'recently expired stock sorts first': () {
      final list = [
        stock('a', expiry: '2025-01-01'),
        stock('b', expiry: '2026-09-06'),
      ]..sort((a, b) => expiryOrder(a, b, contractToday));
      check(list.first.id == 'b', 'Expired sort wrong.');
    },
    'dispensing eligibility is expiry-day safe': () {
      check(
        isDispensableOn(stock('today', expiry: '2026-09-07'), contractToday),
        'Stock became unavailable before the expiry day ended.',
      );
      check(
        !isDispensableOn(stock('expired', expiry: '2026-09-06'), contractToday),
        'Expired stock was offered for dispensing.',
      );
      check(
        !isDispensableOn(stock('sold', sold: true), contractToday),
        'Sold stock was offered for dispensing.',
      );
      check(
        isDispensableOn(stock('unknown', expiry: ''), contractToday),
        'Unknown expiry was silently converted into expired stock.',
      );
    },
    'FEFO prefers earliest valid stock and defers unknown expiry': () {
      final requested = stock('requested', expiry: '2026-10-10');
      final candidates = dispensingCandidates(
        [
          requested,
          stock('first', expiry: '2026-09-08'),
          stock('unknown', expiry: ''),
          stock('empty', expiry: '2026-09-07', quantity: 0),
          stock('expired', expiry: '2026-09-06'),
          stock('other', strength: '650mg', expiry: '2026-09-07'),
        ],
        requested,
        contractToday,
      );
      check(
        candidates.map((record) => record.id).join(',') ==
            'first,requested,unknown',
        'FEFO returned an unsafe or unstable stock order.',
      );
    },
    'sale date respects manufacturing and inclusive expiry facts': () {
      final dated = Medicine.fromJson({
        ...stock('dated', expiry: '2026-09-07').toJson(),
        'mfg': '2026-09-01',
      });
      validateDispensingDate(dated, DateTime(2026, 9, 1));
      validateDispensingDate(dated, DateTime(2026, 9, 7, 23, 59));
      rejects(() => validateDispensingDate(dated, DateTime(2026, 8, 31)));
      rejects(() => validateDispensingDate(dated, DateTime(2026, 9, 8)));
    },
    'paise arithmetic avoids floating rounding': () {
      check(parseMoney('2.50') == 250, 'Price parsing wrong.');
      check(parseMoney('0.01') == 1, 'Paisa missing.');
      check(parseMoney('') == null, 'Missing price became zero.');
      check(money(123456789) == '₹12,34,567.89', 'Indian grouping wrong.');
      rejects(() => parseMoney('-5'));
      rejects(() => parseMoney('3.456'));
    },
    'unknown quantity and price are excluded with coverage': () {
      final stats = InventoryStats([
        stock('a', quantity: 100, price: 200),
        stock('b', quantity: 20, price: 1500),
        stock('c', quantity: null, price: 50),
        stock('d', quantity: 50, price: null),
      ], contractToday);
      check(stats.onHandValue == 50000, 'Inventory total wrong.');
      check(
        stats.unvaluedEntries == 2 && stats.unknownQuantity == 1,
        'Missing coverage wrong.',
      );
    },
    'form and salt normalization do not double count': () {
      final stats = InventoryStats([
        stock('a', salt: ' Paracetamol ', form: 'TAB'),
        stock('b', salt: 'PARACETAMOL', form: 'Tablets'),
      ], contractToday);
      check(stats.uniqueSalts == 1, 'Salt duplicated.');
      check(
        stats.byForm.length == 1 && stats.byForm['Tablet']!.records == 2,
        'Forms duplicated.',
      );
    },
    'distinct strengths remain distinct medicines': () {
      final stats = InventoryStats([
        stock('a'),
        stock('b', strength: '650mg'),
      ], contractToday);
      check(stats.uniqueMedicines == 2, 'Strengths merged.');
    },
    'invalid quantity or price never coerces': () {
      rejects(
        () => Medicine.fromJson({'id': 'a', 'name': 'A', 'quantity': -1}),
      );
      rejects(
        () => Medicine.fromJson({'id': 'a', 'name': 'A', 'quantity': 1.5}),
      );
      rejects(
        () => Medicine.fromJson({
          'id': 'a',
          'name': 'A',
          'unitPricePaise': '200',
        }),
      );
    },
    'search scope filters exact barcode before retrieval': () {
      final engine = MedicineSearch([
        stock('active', expiry: '2027-01-01', barcode: '12345'),
        stock('expired', expiry: '2026-09-01', barcode: '12345'),
      ]);
      final hits = engine.search(
        '12345',
        SearchScope.expired,
        contractSettings,
        contractToday,
      );
      check(
        hits.length == 1 && hits.first.id == 'expired',
        'Barcode leaked active stock.',
      );
      check(
        engine
                .search(
                  '12345',
                  SearchScope.all,
                  contractSettings,
                  contractToday,
                )
                .length ==
            2,
        'Barcode lost a stock entry.',
      );
    },
    'batch number is searchable without acting like stock quantity': () {
      final engine = MedicineSearch([
        stock('batch-a', batchNumber: 'DL-2407'),
        stock('batch-b', batchNumber: 'AZ-9912'),
      ]);
      final hits = engine.search(
        'DL-2407',
        SearchScope.all,
        contractSettings,
        contractToday,
      );
      check(
        hits.isNotEmpty && hits.first.id == 'batch-a',
        'Batch number was not indexed.',
      );
    },
    'fuzzy DROTAVRIN DOTIN and ROTAEN find Drotaverine': () {
      final engine = MedicineSearch([
        stock('d', name: 'Drotaverine', strength: '80mg'),
        stock('c', name: 'Cefixime', strength: '200mg'),
        stock('p'),
      ]);
      for (final query in ['DROTAVRIN', 'DOTIN', 'ROTAEN']) {
        final hits = engine.search(
          query,
          SearchScope.all,
          contractSettings,
          contractToday,
        );
        check(hits.isNotEmpty && hits.first.id == 'd', 'Failed $query.');
      }
    },
    'ordered missing letters METOZOL find Metronidazole': () {
      final hits = MedicineSearch([
        stock('m', name: 'Metronidazole'),
        stock('p'),
      ]).search('METOZOL', SearchScope.all, contractSettings, contractToday);
      check(
        hits.isNotEmpty && hits.first.id == 'm',
        'Sequence matching failed.',
      );
    },
    'search preserves strength and prefers 650mg': () {
      final hits = MedicineSearch(
        [
          stock('500', name: 'Dolo'),
          stock('650', name: 'Dolo', strength: '650mg'),
        ],
      ).search('Dolo 650 mg', SearchScope.all, contractSettings, contractToday);
      check(
        hits.isNotEmpty && hits.first.id == '650',
        'Wrong strength ranked first.',
      );
      check(
        !hits.any((h) => h.id == '500' && h.score > .85),
        'Wrong strength marked confident.',
      );
    },
    'OCR trailing O is normalized as zero beside dosage units': () {
      final hits = MedicineSearch(
        [
          stock('650', name: 'Dolo', strength: '650mg'),
          stock('500', name: 'Dolo', strength: '500mg'),
        ],
      ).search('D0L0 65O mg', SearchScope.all, contractSettings, contractToday);
      check(
        hits.isNotEmpty &&
            hits.first.id == '650' &&
            hits.first.confidence == 'High',
        'OCR dosage correction ranked the wrong medicine.',
      );
    },
    'numeric product codes survive tokenization': () {
      final hits = MedicineSearch([
        stock('code', name: 'DTO 5111'),
        stock('other', name: 'DTO 8999'),
      ]).search('DT 51', SearchScope.all, contractSettings, contractToday);
      check(
        hits.isNotEmpty && hits.first.id == 'code',
        'Product code destroyed.',
      );
    },
    'medicine name outweighs another medicine note': () {
      final hits = MedicineSearch([
        stock('true', name: 'Dolo'),
        stock('note', name: 'Cefixime', notes: 'Dolo'),
      ]).search('Dolo', SearchScope.all, contractSettings, contractToday);
      check(hits.first.id == 'true', 'Notes outrank name.');
    },
    'search indexes manufacturer form expiry and compact location': () {
      final medicine = Medicine.fromJson({
        ...stock('indexed', name: 'Alerid').toJson(),
        'manufacturer': 'Cipla Limited',
        'form': 'Syrup',
        'expiry': '2027-04-30',
        'block': '1',
        'row': '3',
        'vertical': '4',
      });
      final engine = MedicineSearch([medicine]);
      for (final query in [
        'Cipla',
        'syrup',
        '2027-04',
        'B1',
        'R3',
        'indexed',
      ]) {
        final hits = engine.search(
          query,
          SearchScope.all,
          contractSettings,
          contractToday,
        );
        check(
          hits.isNotEmpty && hits.first.id == 'indexed',
          'Indexed field failed for $query.',
        );
      }
    },
    'search index and hostile tokens stay memory bounded': () {
      final longOcr = List.generate(1200, (index) => 'token$index').join(' ');
      final longNote = List.filled(5000, 'x').join();
      final longQuery = List.filled(30000, 'z').join();
      final document = SearchDocument(
        Medicine.fromJson({
          ...stock('bounded').toJson(),
          'ocrText': longOcr,
          'notes': '$longNote tail note',
        }),
      );
      check(
        document.terms.length <= SearchDocument.maxTerms,
        'One record created an unbounded search index.',
      );
      check(
        document.terms.every(
          (term) => term.length <= SearchDocument.maxTermLength,
        ),
        'An oversized token entered the n-gram index.',
      );
      final hits = MedicineSearch([document.record])
          .search(longQuery, SearchScope.all, contractSettings, contractToday);
      check(hits.isEmpty, 'Hostile long query produced a false match.');
    },
    'identity normalizes punctuation and strength spacing': () {
      final a = stock('a', name: 'Dolo-650', strength: '650 mg');
      final b = stock('b', name: 'DOLO 650', strength: '650mg');
      check(a.identity == b.identity, 'Equivalent medicine identity split.');
    },
    'bulk newline medicine text returns all matches': () {
      final engine = MedicineSearch([
        stock('d', name: 'Dolo', strength: '650mg'),
        stock('a', name: 'Azithromycin'),
        stock('p', name: 'Pantoprazole', strength: '40mg'),
      ]);
      final hits = engine.search(
        'Tab Dolo 650mg\nAzithromycin 500mg\nPantoprazole 40mg',
        SearchScope.all,
        contractSettings,
        contractToday,
      );
      check(
        hits.map((h) => h.id).toSet().containsAll(['d', 'a', 'p']),
        'Bulk medicines lost.',
      );
    },
    'Hindi digits and common medicine speech normalize': () {
      check(
        searchText('डोलो ६५० एमजी') == 'dolo 650mg',
        'Hindi search normalization wrong.',
      );
    },
    'AI export contains pharmacy facts and no provider keys': () {
      final data = PharmacyExport(
        revision: 7,
        records: [current],
        today: contractToday,
      );
      check(
        data.content.contains('existing') &&
            data.content.contains('baseRevision'),
        'Snapshot fields missing.',
      );
      check(!data.content.contains('apiKey'), 'Unexpected key field.');
    },
    'AI fenced JSON imports with readable change': () {
      final plan = parse(
        '```json\n${envelope([
          {
            'op': 'update',
            'id': 'existing',
            'fields': {'location': 'Rack 2'},
          },
        ])}\n```',
      );
      check(
        plan.changes.single.after.location == 'Rack 2',
        'Update not normalized.',
      );
      check(
        plan.changes.single.before!.location == '',
        'Before facts mutated.',
      );
    },
    'AI rejects stale revision and replay': () {
      rejects(() => parse(envelope([], revision: 5)));
      rejects(() => parse(envelope([]), receipts: {'request_12345'}));
    },
    'AI rejects foreign paths and derived status': () {
      rejects(
        () => parse(
          envelope([
            {'op': 'update', 'id': 'existing', 'path': 'diaryDB', 'fields': {}},
          ]),
        ),
      );
      rejects(
        () => parse(
          envelope([
            {
              'op': 'update',
              'id': 'existing',
              'fields': {'status': 'expired'},
            },
          ]),
        ),
      );
      rejects(() => parse(envelope([], extra: {'diaryDB': []})));
    },
    'AI refuses missing or repeated target IDs': () {
      rejects(
        () => parse(
          envelope([
            {'op': 'remove', 'id': 'Paracetamol'},
          ]),
        ),
      );
      rejects(
        () => parse(
          envelope([
            {'op': 'remove', 'id': 'existing'},
            {'op': 'mark_sold', 'id': 'existing'},
          ]),
        ),
      );
    },
    'AI add requires a name and flags likely duplicates': () {
      rejects(
        () => parse(
          envelope([
            {
              'op': 'add',
              'fields': {'salt': 'x'},
            },
          ]),
        ),
      );
      final plan = parse(
        envelope([
          {
            'op': 'add',
            'fields': {
              'name': 'Paracetamol',
              'strength': '500mg',
              'form': 'Tablet',
            },
          },
        ]),
      );
      check(
        plan.changes.single.possibleDuplicates.contains('existing'),
        'Duplicate not flagged.',
      );
    },
    'AI Sold keeps original amount and quantity snapshot': () {
      final m = parse(
        envelope([
          {'op': 'mark_sold', 'id': 'existing'},
        ]),
      ).changes.single.after;
      check(
        m.sold &&
            m.quantity == 0 &&
            m.soldQuantity == 10 &&
            m.soldUnitPricePaise == 200,
        'Sold facts wrong.',
      );
    },
    'AI cannot relabel expired stock as sold': () {
      final expired = stock('expired', expiry: '2026-09-06');
      rejects(
        () => parseAiPlan(
          envelope([
            {'op': 'mark_sold', 'id': 'expired'},
          ]),
          {'expired': expired},
          0,
          const {},
          contractToday,
        ),
      );
    },
    'AI rejects batches over 250 actions': () {
      rejects(
        () => parse(
          envelope(
            List.generate(
              251,
              (i) => {
                'op': 'add',
                'fields': {'name': 'Drug $i'},
              },
            ),
          ),
        ),
      );
    },
    'warning settings reject inverted or malformed windows': () {
      rejects(() => WarningSettings.fromJson({'shortDays': 60, 'months': 1}));
      rejects(() => WarningSettings.fromJson({'shortDays': 1.5, 'months': 2}));
    },
    'tracking filters sales by civil-date period': () {
      final tracking = TrackingStats(
        medicines: [stock('a')],
        sales: [
          SaleEvent(
            id: 'sale_inside',
            stockId: 'a',
            medicineName: 'Paracetamol',
            strength: '500mg',
            form: 'Tablet',
            quantity: 3,
            totalAmountPaise: 900,
            occurredAt: DateTime(2026, 9, 7, 23, 55),
          ),
          SaleEvent(
            id: 'sale_outside',
            stockId: 'a',
            medicineName: 'Paracetamol',
            quantity: 20,
            occurredAt: DateTime(2026, 8, 1),
          ),
        ],
        range: TrackingRange.lastDays(contractToday, 7),
      );
      check(
        tracking.recordedSales == 1 &&
            tracking.unitsSold == 3 &&
            tracking.revenuePaise == 900,
        'Tracking period leaked old sales.',
      );
    },
    'on-hand stock without movement is reported as slow moving': () {
      final tracking = TrackingStats(
        medicines: [stock('quiet', name: 'Quiet medicine', quantity: 40)],
        sales: const [],
        range: TrackingRange.lastDays(contractToday, 30),
      );
      check(
        tracking.slowMoving.length == 1 &&
            tracking.slowMoving.single.currentQuantity == 40,
        'Slow-moving stock was not identified.',
      );
    },
    'sold-out stock creates an urgent reorder suggestion': () {
      final tracking = TrackingStats(
        medicines: [stock('a', sold: true)],
        sales: const [],
        range: TrackingRange.lastDays(contractToday, 30),
      );
      check(
        tracking.reorder.single.priority == ReorderPriority.urgent &&
            tracking.reorder.single.suggestedQuantity > 0,
        'Sold stock was not queued for reorder.',
      );
    },
    'sales velocity raises the low-stock reorder target': () {
      final sales = List.generate(
        7,
        (index) => SaleEvent(
          id: 'sale_$index',
          stockId: 'a',
          medicineName: 'Paracetamol',
          strength: '500mg',
          form: 'Tablet',
          quantity: 4,
          occurredAt: DateTime(2026, 9, 1 + index),
        ),
      );
      final tracking = TrackingStats(
        medicines: [stock('a', quantity: 5)],
        sales: sales,
        range: TrackingRange.lastDays(contractToday, 7),
      );
      check(
        tracking.reorder.single.priority == ReorderPriority.soon &&
            tracking.reorder.single.suggestedQuantity >= 100,
        'Demand velocity did not influence the order quantity.',
      );
    },
    'sale events reject customer-data-shaped invalid core fields': () {
      rejects(
        () => SaleEvent.fromJson({
          'id': 'sale',
          'stockId': 'stock',
          'medicineName': 'Dolo',
          'quantity': 0,
          'occurredAt': '2026-09-07T10:00:00',
        }),
      );
      rejects(
        () => SaleEvent.fromJson({
          'id': 'sale',
          'stockId': 'stock',
          'medicineName': 'Dolo',
          'quantity': 1,
          'occurredAt': 'not-a-date',
        }),
      );
    },
    'undone direct SOLD transition is excluded from sales analytics': () {
      final active = stock('sold-then-undone', quantity: 12);
      final overview = SalesOverview(
        const [],
        medicines: [active],
        events: [
          {
            'undone': true,
            'soldValue': 2400,
            'unknownSold': 0,
            'salesBefore': <String, dynamic>{},
            'before': <String, dynamic>{active.id: active.toJson()},
          },
        ],
      );
      check(
        overview.recordedSales == 0 &&
            overview.totalUnitsSold == 0 &&
            overview.salesValuePaise == 0 &&
            overview.ranked.isEmpty,
        'Undo left a phantom sale in analytics.',
      );
    },
    'full backup round-trips medicines settings and sales': () {
      final sale = SaleEvent(
        id: 'sale_1',
        stockId: 'existing',
        medicineName: 'Paracetamol',
        strength: '500mg',
        form: 'Tablet',
        quantity: 2,
        totalAmountPaise: 500,
        occurredAt: contractToday,
      );
      final encoded = PharmacyBackup(
        createdAt: contractToday,
        sourceRevision: 8,
        settings: const WarningSettings(shortDays: 5, months: 3),
        records: {'existing': current},
        sales: {'sale_1': sale},
        soldValue: 2000,
        unknownSold: 1,
      ).encode();
      final restored = PharmacyBackup.parse(encoded);
      check(
        restored.records['existing']!.name == 'Paracetamol' &&
            restored.sales['sale_1']!.quantity == 2 &&
            restored.settings.shortDays == 5 &&
            restored.soldValue == 2000,
        'Backup lost pharmacy facts.',
      );
    },
    'backup rejects unknown paths and orphan sale events': () {
      rejects(
        () => PharmacyBackup.parse(
          jsonEncode({
            'schema': pharmacyBackupSchema,
            'createdAt': contractToday.toIso8601String(),
            'sourceRevision': 1,
            'settings': const WarningSettings().toJson(),
            'medicines': [current.toJson()],
            'sales': const [],
            'soldValue': 0,
            'unknownSold': 0,
            'diary': const [],
          }),
        ),
      );
      rejects(
        () => PharmacyBackup.parse(
          jsonEncode({
            'schema': pharmacyBackupSchema,
            'createdAt': contractToday.toIso8601String(),
            'sourceRevision': 1,
            'settings': const WarningSettings().toJson(),
            'medicines': [current.toJson()],
            'sales': [
              SaleEvent(
                id: 'orphan',
                stockId: 'missing',
                medicineName: 'Unknown',
                quantity: 1,
                occurredAt: contractToday,
              ).toJson(),
            ],
            'soldValue': 0,
            'unknownSold': 0,
          }),
        ),
      );
      rejects(
        () => PharmacyBackup.parse(
          jsonEncode({
            'schema': pharmacyBackupSchema,
            'createdAt': contractToday.toIso8601String(),
            'sourceRevision': 1,
            'settings': const WarningSettings().toJson(),
            'medicines': [
              {...current.toJson(), 'foreignPath': 'diary'},
            ],
            'sales': const [],
            'soldValue': 0,
            'unknownSold': 0,
          }),
        ),
      );
    },
  };
}
