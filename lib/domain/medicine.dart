import 'dart:math';

String newId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String normalize(String value) =>
    value.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

DateTime civilDay(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);
String dateText(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

/// Strict civil dates. A printed YYYY-MM expiry means the last day of that month.
DateTime? parseDate(Object? raw, {bool monthEnd = false}) {
  if (raw == null || raw == '') return null;
  if (raw is! String) throw const FormatException('Date must be text.');
  final match = RegExp(
    r'^(\d{4})-(\d{2})(?:-(\d{2}))?$',
  ).firstMatch(raw.trim());
  if (match == null)
    throw const FormatException(
      'Use YYYY-MM-DD, or YYYY-MM for a printed expiry month.',
    );
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  if (year < 1900 || year > 2200 || month < 1 || month > 12) {
    throw const FormatException('Date is outside the supported range.');
  }
  if (match[3] == null && !monthEnd)
    throw const FormatException('Enter the full manufacturing date.');
  final day = match[3] == null
      ? DateTime.utc(year, month + 1, 0).day
      : int.parse(match[3]!);
  final date = DateTime.utc(year, month, day);
  if (date.month != month || date.year != year || date.day != day)
    throw const FormatException('This date does not exist.');
  return date;
}

int? parseMoney(String raw) {
  final value = raw.trim().replaceAll('₹', '');
  if (value.isEmpty) return null;
  if (!RegExp(r'^\d{1,9}(?:\.\d{1,2})?$').hasMatch(value)) {
    throw const FormatException(
      'Unit price needs a positive amount with at most two decimal places.',
    );
  }
  final parts = value.split('.');
  return int.parse(parts[0]) * 100 +
      (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
}

const maxExactPaise = 9007199254740991;
int checkedMoneySum(int a, int b) {
  final value = BigInt.from(a) + BigInt.from(b);
  if (value.isNegative || value > BigInt.from(maxExactPaise)) {
    throw const FormatException(
      'Amount exceeds the supported exact accounting range.',
    );
  }
  return value.toInt();
}

int stockValue(int quantity, int unitPricePaise) {
  final value = BigInt.from(quantity) * BigInt.from(unitPricePaise);
  if (value.isNegative || value > BigInt.from(maxExactPaise)) {
    throw const FormatException(
      'Quantity multiplied by unit price is too large. Check the units.',
    );
  }
  return value.toInt();
}

String money(int paise) {
  final negative = paise < 0 ? '-' : '';
  final raw = (paise.abs() ~/ 100).toString();
  String grouped = raw;
  if (raw.length > 3) {
    final tail = raw.substring(raw.length - 3);
    String head = raw.substring(0, raw.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    parts.insert(0, head);
    grouped = '${parts.join(',')},$tail';
  }
  return '$negative₹$grouped.${(paise.abs() % 100).toString().padLeft(2, '0')}';
}

const forms = [
  'Tablet',
  'Capsule',
  'Syrup',
  'Injection',
  'Cream',
  'Ointment',
  'Drops',
  'Sachet',
  'Other',
];
String normalizeForm(String raw) {
  final key = normalize(raw);
  const aliases = {
    'tab': 'Tablet',
    'tabs': 'Tablet',
    'tablet': 'Tablet',
    'tablets': 'Tablet',
    'cap': 'Capsule',
    'caps': 'Capsule',
    'capsule': 'Capsule',
    'capsules': 'Capsule',
    'syp': 'Syrup',
    'syr': 'Syrup',
    'syrup': 'Syrup',
    'syrups': 'Syrup',
    'inj': 'Injection',
    'injection': 'Injection',
    'injections': 'Injection',
    'cream': 'Cream',
    'ointment': 'Ointment',
    'drop': 'Drops',
    'drops': 'Drops',
    'sachet': 'Sachet',
    'sachets': 'Sachet',
  };
  return aliases[key] ?? (key.isEmpty ? '' : 'Other');
}

class Medicine {
  Medicine({
    required this.id,
    required this.name,
    this.brand = '',
    this.salt = '',
    this.strength = '',
    this.form = '',
    this.mfg,
    this.expiry,
    this.expiryMonthOnly = false,
    this.quantity,
    this.unitPricePaise,
    this.barcode = '',
    this.block = '',
    this.row = '',
    this.vertical = '',
    this.location = '',
    this.notes = '',
    this.ocrText = '',
    this.sold = false,
    this.archived = false,
    this.soldAt,
    this.soldQuantity,
    this.soldUnitPricePaise,
    this.revision = 1,
  });

  final String id,
      name,
      brand,
      salt,
      strength,
      form,
      barcode,
      block,
      row,
      vertical,
      location,
      notes,
      ocrText;
  final DateTime? mfg, expiry;
  final bool expiryMonthOnly, sold, archived;
  final int? quantity, unitPricePaise, soldQuantity, soldUnitPricePaise;
  final String? soldAt;
  final int revision;

  String get identity => [name, strength, form].map(normalize).join('|');
  String get address => [
    if (block.isNotEmpty) 'Block $block',
    if (row.isNotEmpty) 'Row $row',
    if (vertical.isNotEmpty) 'Vertical $vertical',
    if (location.isNotEmpty) location,
  ].join(' · ');
  String get title => '$name${strength.isEmpty ? '' : ' · $strength'}';
  int? daysLeft(DateTime now) => expiry?.difference(civilDay(now)).inDays;

  static const editable = <String>{
    'name',
    'brand',
    'salt',
    'strength',
    'form',
    'mfg',
    'expiry',
    'quantity',
    'unitPricePaise',
    'barcode',
    'block',
    'row',
    'vertical',
    'location',
    'notes',
    'ocrText',
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'brand': brand,
    'salt': salt,
    'strength': strength,
    'form': form,
    'mfg': mfg == null ? null : dateText(mfg!),
    'expiry': expiry == null
        ? null
        : expiryMonthOnly
        ? dateText(expiry!).substring(0, 7)
        : dateText(expiry!),
    'quantity': quantity,
    'unitPricePaise': unitPricePaise,
    'barcode': barcode,
    'block': block,
    'row': row,
    'vertical': vertical,
    'location': location,
    'notes': notes,
    'ocrText': ocrText,
    'sold': sold,
    'archived': archived,
    'soldAt': soldAt,
    'soldQuantity': soldQuantity,
    'soldUnitPricePaise': soldUnitPricePaise,
    'revision': revision,
  };

  factory Medicine.fromJson(Map<String, dynamic> json) {
    String text(String key, [int max = 300]) {
      final value = json[key];
      if (value == null) return '';
      if (value is! String || value.length > max)
        throw FormatException('Invalid $key.');
      return value.trim();
    }

    int? number(String key, int max) {
      final value = json[key];
      if (value == null) return null;
      if (value is! int || value < 0 || value > max)
        throw FormatException('Invalid $key.');
      return value;
    }

    final name = text('name');
    final id = text('id');
    if (name.isEmpty || id.isEmpty)
      throw const FormatException('Medicine name and record ID are required.');
    final mfg = parseDate(json['mfg']);
    final expiry = parseDate(json['expiry'], monthEnd: true);
    if (mfg != null && expiry != null && mfg.isAfter(expiry))
      throw const FormatException('Manufacturing date cannot be after expiry.');
    for (final key in ['sold', 'archived']) {
      if (json[key] != null && json[key] is! bool)
        throw FormatException('Invalid $key.');
    }
    final sold = json['sold'] == true;
    final quantity = number('quantity', 100000000);
    if (sold && quantity != 0)
      throw const FormatException(
        'A sold entry must have zero available quantity.',
      );
    final price = number('unitPricePaise', 99999999999);
    if (quantity != null && price != null) stockValue(quantity, price);
    return Medicine(
      id: id,
      name: name,
      brand: text('brand'),
      salt: text('salt'),
      strength: text('strength'),
      form: normalizeForm(text('form')),
      mfg: mfg,
      expiry: expiry,
      expiryMonthOnly:
          json['expiry'] is String &&
          (json['expiry'] as String).trim().length == 7,
      quantity: quantity,
      unitPricePaise: price,
      barcode: text('barcode'),
      block: text('block'),
      row: text('row'),
      vertical: text('vertical'),
      location: text('location', 1000),
      notes: text('notes', 10000),
      ocrText: text('ocrText', 30000),
      sold: sold,
      archived: json['archived'] == true,
      soldAt: json['soldAt'] as String?,
      soldQuantity: number('soldQuantity', 100000000),
      soldUnitPricePaise: number('soldUnitPricePaise', 99999999999),
      revision: number('revision', 2147483647) ?? 1,
    );
  }

  Medicine patch(Map<String, dynamic> changes) => Medicine.fromJson({
    ...toJson(),
    ...changes,
    'id': id,
    'revision': revision + 1,
  });
}

class WarningSettings {
  const WarningSettings({this.shortDays = 8, this.months = 2});
  final int shortDays, months;
  int get monthDays => months * 30;
  Map<String, dynamic> toJson() => {'shortDays': shortDays, 'months': months};
  factory WarningSettings.fromJson(Map<String, dynamic> json) {
    final days = json['shortDays'] ?? 8;
    final months = json['months'] ?? 2;
    if (days is! int ||
        months is! int ||
        days < 1 ||
        days > 365 ||
        months < 1 ||
        months > 24 ||
        days >= months * 30) {
      throw const FormatException(
        'Choose 1–365 days and 1–24 months. The month window must be longer than the day window.',
      );
    }
    return WarningSettings(shortDays: days, months: months);
  }
}
