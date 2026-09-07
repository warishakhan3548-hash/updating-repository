import 'medicine.dart';
import 'search.dart';

/// Identity data that may be safely prefilled from a public medicine catalog.
///
/// Stock-specific facts such as expiry, manufacturing date, quantity, price and
/// pharmacy location deliberately do not exist in this model. They must come
/// from the pharmacist or the physical pack.
class MedicineDraftSeed {
  const MedicineDraftSeed({
    required this.name,
    this.brand = '',
    this.manufacturer = '',
    this.salt = '',
    this.strength = '',
    this.form = '',
    this.barcode = '',
    this.source = '',
    this.sourceId = '',
  });

  final String name;
  final String brand;
  final String manufacturer;
  final String salt;
  final String strength;
  final String form;
  final String barcode;
  final String source;
  final String sourceId;

  MedicineDraftSeed withScanBarcode(String value) => MedicineDraftSeed(
    name: name,
    brand: brand,
    manufacturer: manufacturer,
    salt: salt,
    strength: strength,
    form: form,
    barcode: barcode.isNotEmpty ? barcode : value.trim(),
    source: source,
    sourceId: sourceId,
  );

  String get identityKey => [
    searchText(name),
    searchText(brand),
    searchText(salt),
    searchText(strength),
    normalizeForm(form).toLowerCase(),
  ].join('|');
}

class MedicineCatalogCandidate {
  const MedicineCatalogCandidate({
    required this.seed,
    required this.score,
    required this.provider,
    this.reason = '',
  });

  final MedicineDraftSeed seed;
  final double score;
  final String provider;
  final String reason;

  String get subtitle => [
    if (seed.salt.isNotEmpty) seed.salt,
    if (seed.strength.isNotEmpty) seed.strength,
    if (seed.form.isNotEmpty) seed.form,
  ].join(' · ');

  String get manufacturerLine => seed.manufacturer;

  String get confidence => score >= .92
      ? 'Strong match'
      : score >= .78
      ? 'Likely match'
      : 'Possible match';
}
