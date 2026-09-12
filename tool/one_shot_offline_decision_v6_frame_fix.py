from pathlib import Path
import runpy

# Apply the primary V6 surgery first, then tighten one resolver detail found by
# regression testing: strong product-specific frame identity must carry its own
# capture reliability when the structured parser has not populated name/brand.
runpy.run_path('tool/one_shot_offline_decision_v6.py', run_name='__main__')


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one anchor, found {count}')
    return text.replace(old, new, 1)


path = Path('lib/domain/medicine_resolution_v2.dart')
text = path.read_text()

old_consensus = """class _IdentityConsensus {
  const _IdentityConsensus({
    required this.score,
    required this.bestRawScore,
    required this.strongSources,
  });

  final double score;
  final double bestRawScore;
  final int strongSources;
}
"""
new_consensus = """class _IdentityConsensus {
  const _IdentityConsensus({
    required this.score,
    required this.bestRawScore,
    required this.strongSources,
    required this.decisionConfidence,
  });

  final double score;
  final double bestRawScore;
  final int strongSources;

  /// Confidence of evidence that actually produced a strong match against this
  /// product. This is product-specific: unrelated high-quality frames cannot
  /// lend authority to another candidate.
  final double decisionConfidence;
}
"""
text = replace_once(text, old_consensus, new_consensus, 'identity consensus shape')

old_frames = """  final frameScores = <double>[];
  final seenFrameFingerprints = <String>{};
"""
new_frames = """  final frameScores = <double>[];
  var strongestMatchedFrameQuality = 0.0;
  final seenFrameFingerprints = <String>{};
"""
text = replace_once(text, old_frames, new_frames, 'frame reliability accumulator')

old_frame_add = """    final quality = frame.quality.clamp(0, 1).toDouble();
    frameScores.add(raw * (.90 + quality * .10));
"""
new_frame_add = """    final quality = frame.quality.clamp(0, 1).toDouble();
    final frameScore = raw * (.90 + quality * .10);
    frameScores.add(frameScore);
    if (frameScore >= .78) {
      strongestMatchedFrameQuality = max(strongestMatchedFrameQuality, quality);
    }
"""
text = replace_once(text, old_frame_add, new_frame_add, 'matched frame quality')

old_return = """  final structuredStrong = structuredScore >= .78 ? 1 : 0;
  final strongSources = max(structuredStrong, strongFrameScores.length);
  return _IdentityConsensus(
    score: score.clamp(0, .999).toDouble(),
    bestRawScore: bestRaw.clamp(0, 1).toDouble(),
    strongSources: strongSources,
  );
"""
new_return = """  final structuredStrong = structuredScore >= .78 ? 1 : 0;
  final strongSources = max(structuredStrong, strongFrameScores.length);
  final structuredConfidence = structuredStrong > 0
      ? max(
          draft.field('name').confidence,
          draft.field('brand').confidence,
        ).clamp(0, 1).toDouble()
      : 0.0;
  final decisionConfidence = max(
    structuredConfidence,
    strongestMatchedFrameQuality,
  ).clamp(0, 1).toDouble();
  return _IdentityConsensus(
    score: score.clamp(0, .999).toDouble(),
    bestRawScore: bestRaw.clamp(0, 1).toDouble(),
    strongSources: strongSources,
    decisionConfidence: decisionConfidence,
  );
"""
text = replace_once(text, old_return, new_return, 'identity decision confidence')

old_authority = """      final identityConfidence = max(
        draft.field('name').confidence,
        draft.field('brand').confidence,
      );
      final identityAuthority =
          _resolverEvidenceReliability(identityConfidence) *
          _resolverAgreementReliability(bestIdentity, .78);
"""
new_authority = """      final identityAuthority =
          _resolverEvidenceReliability(identity.decisionConfidence) *
          _resolverAgreementReliability(bestIdentity, .78);
"""
text = replace_once(text, old_authority, new_authority, 'identity authority source')

path.write_text(text)
