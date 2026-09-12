from pathlib import Path

path = Path('lib/domain/medicine_semantic_roles.dart')
text = path.read_text()

old_remember = '''  void rememberComponent(_ComponentCandidate candidate) {
    final key = searchText(candidate.ingredient);
    if (key.length < 3) return;
    final old = componentVotes[key];
    if (old == null) {
      componentVotes[key] = _ComponentVote(
        candidate.ingredient,
        candidate.strength,
        candidate.confidence,
        1,
        order++,
      );
      return;
    }
    final sameStrength =
        _strengthKey(old.strength) == _strengthKey(candidate.strength);
    componentVotes[key] = _ComponentVote(
      old.ingredient,
      sameStrength || old.strength.isNotEmpty
          ? old.strength
          : candidate.strength,
      max(old.confidence, candidate.confidence),
      old.support + 1,
      old.order,
      conflicted:
          old.conflicted ||
          (!sameStrength &&
              old.strength.isNotEmpty &&
              candidate.strength.isNotEmpty),
    );
  }
'''
new_remember = '''  void rememberComponent(_ComponentCandidate candidate) {
    final rawKey = searchText(candidate.ingredient);
    if (rawKey.length < 3) return;
    String key = rawKey;
    for (final existing in componentVotes.entries) {
      final sameStrength =
          _strengthKey(existing.value.strength) ==
          _strengthKey(candidate.strength);
      if (!sameStrength &&
          existing.value.strength.isNotEmpty &&
          candidate.strength.isNotEmpty) {
        continue;
      }
      if (_semanticSimilarity(existing.key, rawKey) >= .955) {
        key = existing.key;
        break;
      }
    }
    final old = componentVotes[key];
    if (old == null) {
      componentVotes[key] = _ComponentVote(
        candidate.ingredient,
        candidate.strength,
        candidate.confidence,
        1,
        order++,
      );
      return;
    }
    final sameStrength =
        _strengthKey(old.strength) == _strengthKey(candidate.strength);
    final preferCandidateIngredient =
        candidate.ingredient.length < old.ingredient.length &&
        _semanticSimilarity(
              searchText(old.ingredient),
              searchText(candidate.ingredient),
            ) >=
            .955;
    componentVotes[key] = _ComponentVote(
      preferCandidateIngredient ? candidate.ingredient : old.ingredient,
      sameStrength || old.strength.isNotEmpty
          ? old.strength
          : candidate.strength,
      max(old.confidence, candidate.confidence),
      old.support + 1,
      old.order,
      conflicted:
          old.conflicted ||
          (!sameStrength &&
              old.strength.isNotEmpty &&
              candidate.strength.isNotEmpty),
    );
  }
'''

old_frame = '''    final windows = _compositionWindows(lines);
    final frameComponents = <String, _ComponentCandidate>{};
    for (final window in windows) {
      for (final component in _parseComposition(window, quality)) {
        final key = searchText(component.ingredient);
        if (key.length < 3) continue;
        final old = frameComponents[key];
        if (old == null || component.confidence > old.confidence) {
          frameComponents[key] = component;
        }
      }
    }
'''
new_frame = '''    final windows = _compositionWindows(lines);
    final frameComponents = <String, _ComponentCandidate>{};
    for (final window in windows) {
      for (final component in _parseComposition(window, quality)) {
        final rawKey = searchText(component.ingredient);
        if (rawKey.length < 3) continue;
        String key = rawKey;
        for (final existing in frameComponents.entries) {
          final sameStrength =
              _strengthKey(existing.value.strength) ==
              _strengthKey(component.strength);
          if (!sameStrength) continue;
          if (_semanticSimilarity(existing.key, rawKey) >= .955) {
            key = existing.key;
            break;
          }
        }
        final old = frameComponents[key];
        if (old == null) {
          frameComponents[key] = component;
          continue;
        }
        final semanticallySame =
            _semanticSimilarity(
              searchText(old.ingredient),
              searchText(component.ingredient),
            ) >=
            .955;
        final cleanerIngredient =
            semanticallySame && component.ingredient.length < old.ingredient.length;
        if (cleanerIngredient || component.confidence > old.confidence + .03) {
          frameComponents[key] = component;
        }
      }
    }
'''

for old, new, label in [
    (old_remember, new_remember, 'rememberComponent'),
    (old_frame, new_frame, 'frameComponents'),
]:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one anchor, found {count}')
    text = text.replace(old, new, 1)

path.write_text(text)
print('V11 semantic component dedupe hardening applied')
