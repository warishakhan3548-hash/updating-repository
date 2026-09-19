import 'dart:math';

import 'medicine_date_parser.dart';
import 'medicine_understanding.dart';
import 'offline_evidence_graph.dart';
import 'spatial_traceability.dart';

export 'medicine_date_parser.dart'
    show ParsedMedicineDate, parseMedicineDateText;

part 'medicine_date_intelligence_core.dart';
part 'medicine_date_intelligence_helpers.dart';

enum MedicineDateRole { manufacturing, expiry, unknown }

class MedicineDateEvidence {
  const MedicineDateEvidence({
    required this.date,
    required this.role,
    required this.confidence,
    required this.support,
    this.explicitLabel = false,
  });

  final ParsedMedicineDate date;
  final MedicineDateRole role;
  final double confidence;
  final int support;
  final bool explicitLabel;
}

class MedicineDateResolution {
  const MedicineDateResolution({
    this.manufacturing,
    this.expiry,
    this.conflicted = false,
    this.expired = false,
  });

  final MedicineDateEvidence? manufacturing;
  final MedicineDateEvidence? expiry;
  final bool conflicted;
  final bool expired;

  bool get isEmpty => manufacturing == null && expiry == null;
}
