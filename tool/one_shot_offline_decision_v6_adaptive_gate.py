from pathlib import Path
import runpy

# Build the complete V6 source from the unchanged main-branch baseline.
runpy.run_path(
    'tool/one_shot_offline_decision_v6_frame_fix.py',
    run_name='__main__',
)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one anchor, found {count}')
    return text.replace(old, new, 1)


path = Path('lib/domain/medicine_resolution_v2.dart')
text = path.read_text()

old_lock = """    final requiredScore = _resolverRequiredLockScore(winner, evidenceQuality);
    final requiredMargin = _resolverRequiredLockMargin(winner, evidenceQuality);
    final calibratedLock =
        winner.product.verified &&
        winner.score >= requiredScore &&
        winner.channels >= 2 &&
        winner.decisionMass >= _resolverMinimumDecisionMass &&
        margin >= requiredMargin &&
        winner.hardConflicts == 0;
"""
new_lock = """    final requiredScore = _resolverRequiredLockScore(winner, evidenceQuality);
    final requiredMargin = _resolverRequiredLockMargin(winner, evidenceQuality);
    final requiredDecisionMass = _resolverRequiredDecisionMass(evidenceQuality);
    final calibratedLock =
        winner.product.verified &&
        winner.score >= requiredScore &&
        winner.channels >= 2 &&
        winner.decisionMass >= requiredDecisionMass &&
        margin >= requiredMargin &&
        winner.hardConflicts == 0;
"""
text = replace_once(text, old_lock, new_lock, 'calibrated lock mass gate')

margin_anchor = """double _resolverRequiredLockMargin(
  _ProductHypothesis hypothesis,
  double evidenceQuality,
) {
  final channelRelief = hypothesis.channels >= 3 ? .008 : 0.0;
  return (.145 - evidenceQuality * .05 - channelRelief)
      .clamp(.082, .145)
      .toDouble();
}

"""
mass_function = """double _resolverRequiredLockMargin(
  _ProductHypothesis hypothesis,
  double evidenceQuality,
) {
  final channelRelief = hypothesis.channels >= 3 ? .008 : 0.0;
  return (.145 - evidenceQuality * .05 - channelRelief)
      .clamp(.082, .145)
      .toDouble();
}

/// V6 keeps the historical 0.50 authority target as its center, but avoids a
/// discontinuity where confidence-calibrated evidence can become safer yet miss
/// automation by only a few thousandths. High-quality coherent evidence may
/// lower the gate by at most 0.025; poor evidence raises it by at most 0.015.
/// Identity-only or identity+form hypotheses remain far below this range.
double _resolverRequiredDecisionMass(double evidenceQuality) {
  return (_resolverMinimumDecisionMass + .015 - evidenceQuality * .045)
      .clamp(.475, .515)
      .toDouble();
}

"""
text = replace_once(text, margin_anchor, mass_function, 'adaptive mass function')
path.write_text(text)

doc_path = Path('docs/OFFLINE_DECISION_ENGINE_MAP.md')
doc = doc_path.read_text()
old_doc = """7. the existing `0.50` minimum decision-mass, winner score and runner-up margin
   gates remain in force, so reliability calibration tightens evidence quality
   without replacing the established resolver.
"""
new_doc = """7. decision-mass remains centered on the historical `0.50` target, but V6
   calibrates the final gate within a narrow `0.475..0.515` range from evidence
   quality; winner score and runner-up separation remain independent gates, so a
   weak identity/form-only hypothesis cannot auto-lock merely from this relief.
"""
doc = replace_once(doc, old_doc, new_doc, 'V6 decision-mass documentation')
doc_path.write_text(doc)
