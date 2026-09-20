import 'medicine.dart';

String _supplierKey(String value) => normalize(value)
    .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f]+'), '');

const _reservedSupplierLabels = <String>{
  'supplier',
  'suppliername',
  'name',
  'returnbeforeexpiry',
  'returnwindow',
  'returndays',
  'address',
  'gstin',
  'gst',
  'druglicenceno',
  'druglicensenumber',
  'licenceno',
  'licensenumber',
  'dlno',
  'batch',
  'batchnumber',
  'lot',
  'lotnumber',
  'expiry',
  'exp',
  'medicine',
  'medicinename',
  'quantity',
  'stock',
  'stockid',
};

bool isReservedSupplierCustomFieldLabel(String value) =>
    _reservedSupplierLabels.contains(_supplierKey(value));

const _supplierLeadTimeLabels = <String>{
  'leadtime',
  'leadtimedays',
  'deliverydays',
  'deliveryleadtime',
  'supplydays',
  'restockdays',
};

/// Reads an optional operational lead-time fact from the existing flexible
/// supplier fields. Conflicting aliases deliberately return null so purchasing
/// falls back to the conservative default instead of choosing one silently.
int? supplierPlanningLeadDays(Supplier supplier) {
  final values = <int>{};
  for (final field in supplier.customFields) {
    if (!_supplierLeadTimeLabels.contains(_supplierKey(field.label))) continue;
    final match = RegExp(
      r'^\s*([0-9]{1,3})\s*(?:days?|day|din|दिन)?\s*$',
      caseSensitive: false,
      unicode: true,
    ).firstMatch(field.value);
    if (match == null) return null;
    final value = int.tryParse(match.group(1)!);
    if (value == null || value < 1 || value > 90) return null;
    values.add(value);
  }
  return values.length == 1 ? values.single : null;
}

class SupplierCustomField {
  const SupplierCustomField({
    required this.id,
    required this.label,
    required this.value,
  });

  final String id;
  final String label;
  final String value;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'label': label,
    'value': value,
  };

  factory SupplierCustomField.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final label = json['label'];
    final value = json['value'];
    if (id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{8,120}$').hasMatch(id) ||
        label is! String ||
        value is! String) {
      throw const FormatException('Invalid supplier custom field.');
    }
    final cleanLabel = label.replaceAll(RegExp(r'\s+'), ' ').trim();
    final cleanValue = value.trim();
    if (cleanLabel.isEmpty ||
        cleanLabel.length > 100 ||
        cleanValue.length > 2000) {
      throw const FormatException('Invalid supplier custom field.');
    }
    if (isReservedSupplierCustomFieldLabel(cleanLabel)) {
      throw FormatException(
        '$cleanLabel is already a built-in supplier or stock field.',
      );
    }
    return SupplierCustomField(
      id: id,
      label: cleanLabel,
      value: cleanValue,
    );
  }
}

class Supplier {
  const Supplier({
    required this.id,
    required this.name,
    required this.returnBeforeExpiryDays,
    this.address = '',
    this.gstin = '',
    this.drugLicenceNo = '',
    this.customFields = const <SupplierCustomField>[],
    this.revision = 1,
  });

  final String id;
  final String name;
  final int returnBeforeExpiryDays;
  final String address;
  final String gstin;
  final String drugLicenceNo;
  final List<SupplierCustomField> customFields;
  final int revision;

  static const storedFields = <String>{
    'id',
    'name',
    'returnBeforeExpiryDays',
    'address',
    'gstin',
    'drugLicenceNo',
    'customFields',
    'revision',
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'returnBeforeExpiryDays': returnBeforeExpiryDays,
    'address': address,
    'gstin': gstin,
    'drugLicenceNo': drugLicenceNo,
    'customFields': customFields.map((field) => field.toJson()).toList(),
    'revision': revision,
  };

  factory Supplier.fromJson(Map<String, dynamic> json) {
    if (json.keys.any((key) => !storedFields.contains(key))) {
      throw const FormatException('Supplier contains an unsupported field.');
    }
    final id = json['id'];
    final name = json['name'];
    final returnDays = json['returnBeforeExpiryDays'];
    final address = json['address'] ?? '';
    final gstin = json['gstin'] ?? '';
    final drugLicenceNo = json['drugLicenceNo'] ?? '';
    final revision = json['revision'] ?? 1;
    final rawCustom = json['customFields'] ?? const <dynamic>[];

    if (id is! String ||
        id.trim().isEmpty ||
        id.length > 300 ||
        name is! String ||
        returnDays is! int ||
        returnDays < 0 ||
        returnDays > 3650 ||
        address is! String ||
        gstin is! String ||
        drugLicenceNo is! String ||
        revision is! int ||
        revision < 1 ||
        rawCustom is! List ||
        rawCustom.length > 50) {
      throw const FormatException('Invalid supplier details.');
    }
    final cleanName = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    final cleanAddress = address.trim();
    final cleanGstin = gstin.replaceAll(RegExp(r'\s+'), '').toUpperCase();
    final cleanDrugLicenceNo =
        drugLicenceNo.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleanName.isEmpty ||
        cleanName.length > 300 ||
        cleanAddress.length > 1000 ||
        cleanGstin.length > 40 ||
        cleanDrugLicenceNo.length > 120) {
      throw const FormatException('Invalid supplier details.');
    }

    final fields = <SupplierCustomField>[];
    final ids = <String>{};
    final labels = <String>{};
    for (final raw in rawCustom) {
      if (raw is! Map) {
        throw const FormatException('Invalid supplier custom field.');
      }
      final field = SupplierCustomField.fromJson(
        Map<String, dynamic>.from(raw),
      );
      if (!ids.add(field.id)) {
        throw const FormatException('Supplier custom field ID is repeated.');
      }
      final key = _supplierKey(field.label);
      if (!labels.add(key)) {
        throw FormatException(
          'Supplier field "${field.label}" is repeated.',
        );
      }
      fields.add(field);
    }

    return Supplier(
      id: id.trim(),
      name: cleanName,
      returnBeforeExpiryDays: returnDays,
      address: cleanAddress,
      gstin: cleanGstin,
      drugLicenceNo: cleanDrugLicenceNo,
      customFields: List.unmodifiable(fields),
      revision: revision,
    );
  }

  Supplier patch(Map<String, dynamic> changes) => Supplier.fromJson({
    ...toJson(),
    ...changes,
    'revision': revision + 1,
  });
}

class SupplierReturnCandidate {
  const SupplierReturnCandidate({
    required this.supplier,
    required this.medicine,
    required this.daysLeft,
  });

  final Supplier supplier;
  final Medicine medicine;
  final int daysLeft;
}

List<SupplierReturnCandidate> supplierReturnCandidates({
  required Iterable<Medicine> medicines,
  required Map<String, Supplier> suppliers,
  required DateTime today,
}) {
  final day = civilDay(today);
  final result = <SupplierReturnCandidate>[];
  for (final medicine in medicines) {
    if (medicine.archived ||
        medicine.sold ||
        medicine.quantity == 0 ||
        medicine.supplierId.trim().isEmpty ||
        medicine.expiry == null) {
      continue;
    }
    final supplier = suppliers[medicine.supplierId];
    if (supplier == null) continue;
    final daysLeft = civilDay(medicine.expiry!).difference(day).inDays;
    if (daysLeft < 0 || daysLeft > supplier.returnBeforeExpiryDays) continue;
    result.add(
      SupplierReturnCandidate(
        supplier: supplier,
        medicine: medicine,
        daysLeft: daysLeft,
      ),
    );
  }
  result.sort((a, b) {
    final supplier = a.supplier.name.compareTo(b.supplier.name);
    if (supplier != 0) return supplier;
    final expiry = a.daysLeft.compareTo(b.daysLeft);
    if (expiry != 0) return expiry;
    return a.medicine.title.compareTo(b.medicine.title);
  });
  return List.unmodifiable(result);
}
