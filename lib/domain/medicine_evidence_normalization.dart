import 'dart:math';

import 'medicine_understanding.dart';

/// Canonicalizes detector evidence before acquisition, intake and review gates.
///
/// ML Kit can rarely retain valid per-line geometry while its merged text stream
/// is empty. The downstream deterministic parser intentionally consumes a text
/// stream, so dropping such a frame here would erase real OCR evidence before
/// date, composition and product reasoning get a chance to use it. Reconstruct
/// only missing text from observed layout lines; never overwrite a non-empty raw
/// OCR stream and never manufacture medicine facts.
List<MedicineFrameEvidence> normalizeMedicineReviewEvidence(
  Iterable<MedicineFrameEvidence> source,
) {
  final frames = source.take(maxMedicineEvidenceFrames + 1).toList(growable: false);
  if (frames.length > maxMedicineEvidenceFrames) {
    throw const FormatException('Too many capture frames. Split this import.');
  }
  return List<MedicineFrameEvidence>.unmodifiable(
    frames.map(normalizeMedicineFrameEvidence),
  );
}

MedicineFrameEvidence normalizeMedicineFrameEvidence(
  MedicineFrameEvidence frame,
) {
  if (frame.text.trim().isNotEmpty || frame.layoutLines.isEmpty) return frame;
  final fallback = _layoutOcrText(frame.layoutLines);
  if (fallback.isEmpty) return frame;
  return MedicineFrameEvidence(
    barcode: frame.barcode,
    barcodes: frame.barcodes,
    layoutLines: frame.layoutLines,
    text: fallback,
    source: frame.source,
    sequence: frame.sequence,
    timestampMs: frame.timestampMs,
    quality: frame.quality,
    startsNewItem: frame.startsNewItem,
  );
}

String _layoutOcrText(Iterable<MedicineTextLineEvidence> source) {
  final lines = source
      .where((line) => line.text.trim().isNotEmpty)
      .take(240)
      .toList(growable: false);
  if (lines.isEmpty) return '';

  double coordinate(double value) => value.isFinite ? value : 0;
  final ordered = lines.toList(growable: true)
    ..sort((a, b) {
      final vertical = coordinate(a.top).compareTo(coordinate(b.top));
      if (vertical != 0) return vertical;
      return coordinate(a.left).compareTo(coordinate(b.left));
    });
  final heights = ordered
      .map((line) => line.height)
      .where((height) => height.isFinite && height > 0)
      .toList(growable: false)
    ..sort();
  final medianHeight = heights.isEmpty ? 0.0 : heights[heights.length ~/ 2];
  final rowTolerance = max(2.0, medianHeight * .48);

  final readingOrder = <MedicineTextLineEvidence>[];
  var index = 0;
  while (index < ordered.length) {
    final anchorTop = coordinate(ordered[index].top);
    final row = <MedicineTextLineEvidence>[ordered[index]];
    index++;
    while (index < ordered.length &&
        (coordinate(ordered[index].top) - anchorTop).abs() <= rowTolerance) {
      row.add(ordered[index]);
      index++;
    }
    row.sort((a, b) {
      final horizontal = coordinate(a.left).compareTo(coordinate(b.left));
      if (horizontal != 0) return horizontal;
      return coordinate(a.top).compareTo(coordinate(b.top));
    });
    readingOrder.addAll(row);
  }

  final output = <String>[];
  var characters = 0;
  for (final line in readingOrder) {
    var clean = line.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) continue;
    if (clean.length > 300) clean = clean.substring(0, 300);
    final remaining = 30000 - characters;
    if (remaining <= 0) break;
    if (clean.length > remaining) clean = clean.substring(0, remaining);
    output.add(clean);
    characters += clean.length + 1;
  }
  return output.join('\n');
}
