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

  final reliability =
      (scoreQuality * .30 +
              marginQuality * .22 +
              channelQuality * .16 +
              massQuality * .18 +
              evidence * .14)
          .clamp(0, 1)
          .toDouble();

  // This is an extra abstention gate, never a replacement for the resolver's
  // existing minimum score/margin/channel/mass requirements.
  final accepted = reliability >= .66 && channels >= 2 && decisionMass >= .46;
  return OfflineDecisionReliability(
    score: reliability,
    acceptCanonicalLock: accepted,
  );
}
