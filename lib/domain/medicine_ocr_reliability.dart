/// Normalizes detector confidence without inventing medicine certainty.
///
/// Some ML Kit Android configurations report exactly 0 when per-line confidence
/// is unavailable. Treat that sentinel as unknown instead of as proof that a
/// perfectly readable line is bad. Positive detector scores remain bounded.
/// This signal is used only to choose between duplicate OCR layout readings; it
/// never rewrites physical capture quality or authorizes a medicine decision.
double? usableMedicineOcrConfidence(num? raw) {
  if (raw == null || !raw.isFinite) return null;
  final value = raw.toDouble();
  if (value <= 0) return null;
  return value.clamp(0.0, 1.0).toDouble();
}
