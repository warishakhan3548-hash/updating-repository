import 'dart:math';

/// One detector-reported OCR confidence sample.
///
/// This is evidence quality, never a probability that the medicine identity is
/// correct. The medicine resolver still owns semantic conflicts and abstention.
class MedicineOcrConfidenceSample {
  const MedicineOcrConfidenceSample({
    required this.text,
    required this.confidence,
  });

  final String text;
  final double? confidence;
}

/// Produces a bounded, conservative frame-level OCR certainty signal.
///
/// ML Kit may omit confidence on a platform/model. Missing confidence therefore
/// returns null so the historical capture-quality path remains unchanged. Exact
/// duplicate text from multiple script recognizers contributes only its strongest
/// detector confidence, avoiding double votes.
double? robustMedicineOcrConfidence(
  Iterable<MedicineOcrConfidenceSample> samples,
) {
  final byText = <String, double>{};
  for (final sample in samples.take(500)) {
    final raw = sample.confidence;
    if (raw == null || !raw.isFinite) continue;
    final text = sample.text.trim();
    if (text.length < 2) continue;
    final key = text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final confidence = raw.clamp(0.0, 1.0).toDouble();
    final previous = byText[key];
    if (previous == null || confidence > previous) {
      byText[key] = confidence;
    }
  }
  if (byText.isEmpty) return null;

  final values = byText.entries.toList(growable: false);
  var weightedTotal = 0.0;
  var weightTotal = 0.0;
  for (final entry in values) {
    // Long legal paragraphs must not drown a short but important strength/date
    // line. Text length helps only inside a deliberately tight bounded range.
    final weight = .55 + min(entry.key.length, 48) / 48 * .45;
    weightedTotal += entry.value * weight;
    weightTotal += weight;
  }
  final weightedMean = weightedTotal / max(weightTotal, .0001);

  final ordered = values.map((entry) => entry.value).toList(growable: false)
    ..sort();
  // Blend toward the lower quartile so several uncertain lines cannot be hidden
  // by one perfect heading. This is intentionally conservative for pharmacy OCR.
  final lowerQuartile = ordered[((ordered.length - 1) * .25).round()];
  return (weightedMean * .76 + lowerQuartile * .24)
      .clamp(0.0, 1.0)
      .toDouble();
}

/// Adds detector certainty to the existing physical capture-quality signal.
///
/// The capture metric remains the majority vote. OCR confidence can down/up-weight
/// otherwise equal frames, but it can never erase text or override barcode/GS1
/// evidence. If detector confidence is unavailable, behavior is exactly legacy.
double confidenceAwareMedicineEvidenceQuality({
  required double captureQuality,
  required double? ocrConfidence,
}) {
  final capture = captureQuality.isFinite
      ? captureQuality.clamp(0.0, 1.0).toDouble()
      : .65;
  final ocr = ocrConfidence;
  if (ocr == null || !ocr.isFinite) return capture;
  return (capture * .70 + ocr.clamp(0.0, 1.0) * .30)
      .clamp(0.0, 1.0)
      .toDouble();
}
