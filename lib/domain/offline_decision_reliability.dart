/// Conservative reliability assessment for the deterministic product resolver.
///
/// This score is deliberately NOT presented as an empirical probability. It is
/// a monotonic fusion of independent decision features and exists to implement a
/// selective-classification policy: strong coherent cases may resolve, while
/// uncertain cases abstain and stay in pharmacist review.
class OfflineDecisionReliability {
  const OfflineDecisionReliability({
    required this.score,
    required this.acceptCanonicalLock,
  });

  final double score;
  final bool acceptCanonicalLock;
}

OfflineDecisionReliability assessOfflineDecisionReliability({
  required double winnerScore,
  required double margin,
  required int channels,
  required double decisionMass,
  required double evidenceQuality,
  required bool verified,
  required int hardConflicts,
  bool exactBarcode = false,
}) {
  if (!verified || hardConflicts > 0) {
    return const OfflineDecisionReliability(
      score: 0,
      acceptCanonicalLock: false,
    );
  }
  if (exactBarcode) {
    return const OfflineDecisionReliability(
      score: .995,
      acceptCanonicalLock: true,
    );
  }

  final scoreQuality = ((winnerScore - .72) / .27).clamp(0, 1).toDouble();
  final marginQuality = (margin / .18).clamp(0, 1).toDouble();
  final channelQuality = (channels / 4).clamp(0, 1).toDouble();
  final massQuality = (decisionMass / .65).clamp(0, 1).toDouble();
  final evidence = evidenceQuality.clamp(0, 1).toDouble();

  // V7: compensation-resistant selective classification.
  //
  // A plain weighted average is useful for ranking, but it permits a very
  // strong clue to numerically hide one weak decision dimension. That is the
  // wrong failure mode for medicine identity. The final lock score therefore
  // combines three bounded views of exactly the same evidence:
  //
  //  * arithmeticSupport preserves the historical calibration and monotonicity;
  //  * harmonicConsensus rewards broad agreement and sharply discounts weak
  //    dimensions without adding another model or network dependency;
  //  * criticalFloor represents the weakest safety-critical dimension, so an
  //    excellent name match cannot fully compensate for a tiny winner margin,
  //    weak decision authority, poor capture quality, or a marginal score.
  //
  // Retrieval remains permissive. This stricter fusion is used only at the
  // canonicalization boundary where the engine must choose resolve vs review.
  final arithmeticSupport =
      (scoreQuality * .30 +
              marginQuality * .22 +
              channelQuality * .16 +
              massQuality * .18 +
              evidence * .14)
          .clamp(0, 1)
          .toDouble();

  final harmonicConsensus = _weightedHarmonicConsensus(
    scoreQuality: scoreQuality,
    marginQuality: marginQuality,
    channelQuality: channelQuality,
    massQuality: massQuality,
    evidenceQuality: evidence,
  );

  final criticalFloor = _minimumQuality(
    scoreQuality,
    marginQuality,
    massQuality,
    evidence,
  );

  // The disagreement term measures how much the arithmetic mean is being
  // propped up by strong dimensions while weaker dimensions lag behind. It is
  // bounded and small, so coherent historical cases retain their calibration,
  // while lopsided evidence is pushed toward REVIEW instead of false certainty.
  final compensationGap = (arithmeticSupport - harmonicConsensus)
      .clamp(0, 1)
      .toDouble();

  final reliability =
      (arithmeticSupport * .55 +
              harmonicConsensus * .30 +
              criticalFloor * .15 -
              compensationGap * .08)
          .clamp(0, 1)
          .toDouble();

  // This remains an extra abstention gate, never a replacement for the
  // resolver's independent score/margin/channel/mass/contradiction checks.
  // Keeping the historical acceptance threshold protects existing behavior;
  // the upgraded fusion changes only *how coherent* the evidence must be to
  // reach it.
  final accepted = reliability >= .66 && channels >= 2 && decisionMass >= .46;
  return OfflineDecisionReliability(
    score: reliability,
    acceptCanonicalLock: accepted,
  );
}

/// Weighted harmonic fusion is intentionally bounded and allocation-free.
/// A small floor prevents division by zero while still making a near-zero
/// dimension dominate the consensus score. The weights mirror the historical
/// arithmetic calibration above, so this is a surgical upgrade rather than a
/// second competing policy engine.
double _weightedHarmonicConsensus({
  required double scoreQuality,
  required double marginQuality,
  required double channelQuality,
  required double massQuality,
  required double evidenceQuality,
}) {
  const floor = .08;

  double safe(double value) => value < floor ? floor : value;

  final denominator =
      .30 / safe(scoreQuality) +
      .22 / safe(marginQuality) +
      .16 / safe(channelQuality) +
      .18 / safe(massQuality) +
      .14 / safe(evidenceQuality);

  if (!denominator.isFinite || denominator <= 0) return 0;
  return (1 / denominator).clamp(0, 1).toDouble();
}

double _minimumQuality(double a, double b, double c, double d) {
  var result = a;
  if (b < result) result = b;
  if (c < result) result = c;
  if (d < result) result = d;
  return result.clamp(0, 1).toDouble();
}
