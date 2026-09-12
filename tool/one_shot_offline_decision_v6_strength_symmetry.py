from pathlib import Path
import runpy

runpy.run_path(
    'tool/one_shot_offline_decision_v6_adaptive_gate.py',
    run_name='__main__',
)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one anchor, found {count}')
    return text.replace(old, new, 1)


path = Path('lib/domain/medicine_resolution_v2.dart')
text = path.read_text()
old = """    if (agrees) {
      channels++;
      decisionMass +=
          .18 * _resolverEvidenceReliability(draft.field('strength').confidence);
    } else if (draft.field('strength').confidence >= .65) {
"""
new = """    if (agrees) {
      channels++;
      final strengthConfidence = draft.field('strength').confidence;
      final baseStrengthAuthority = _resolverEvidenceReliability(
        strengthConfidence,
      );
      // The parser already treats confidence >= .65 as trustworthy enough to
      // hard-veto a contradictory strength. Apply the same trust symmetrically
      // when the normalized strength exactly agrees with the product; otherwise
      // a correct 500 mg clue is paradoxically weaker than an incorrect one.
      final strengthAuthority = strengthConfidence >= .65
          ? max(.92, baseStrengthAuthority)
          : baseStrengthAuthority;
      decisionMass += .18 * strengthAuthority;
    } else if (draft.field('strength').confidence >= .65) {
"""
text = replace_once(text, old, new, 'trusted exact strength symmetry')
path.write_text(text)

doc_path = Path('docs/OFFLINE_DECISION_ENGINE_MAP.md')
doc = doc_path.read_text()
old_doc = """6. strength/form/GS1 contradictions retain the existing hard veto behavior;
7. decision-mass remains centered on the historical `0.50` target, but V6
"""
new_doc = """6. strength/form/GS1 contradictions retain the existing hard veto behavior;
   an exactly matching normalized strength at the same `>=0.65` trust level used
   for contradiction veto receives symmetric high authority instead of being
   penalized merely for having only one OCR observation;
7. decision-mass remains centered on the historical `0.50` target, but V6
"""
doc = replace_once(doc, old_doc, new_doc, 'strength symmetry documentation')
doc_path.write_text(doc)
