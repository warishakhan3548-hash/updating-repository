import 'dart:math';

import 'medicine.dart';
import 'medicine_strength.dart';
import 'medicine_understanding.dart';
import 'offline_evidence_graph.dart';
import 'search.dart';

/// Deterministic pharmaceutical-role reasoning layered above raw OCR.
///
/// This is intentionally not a language model. It converts packaging evidence
/// into a compact semantic hypothesis: trade name versus generic composition,
/// ingredient components and their aligned strengths. Downstream product-level
/// resolution and safety firewalls remain authoritative.
class MedicineIngredientComponent {
  const MedicineIngredientComponent({
    required this.ingredient,
    required this.strength,
    required this.confidence,
    required this.support,
  });

  final String ingredient;
  final String strength;
  final double confidence;
  final int support;
}

class MedicineSemanticResolution {
  const MedicineSemanticResolution({
    this.brand = '',
    this.brandConfidence = 0,
    this.genericName = '',
    this.genericConfidence = 0,
    this.components = const <MedicineIngredientComponent>[],
    this.conflicted = false,
    this.compositionConflicted = false,
  });

  final String brand;
  final double brandConfidence;
  final String genericName;
  final double genericConfidence;
  final List<MedicineIngredientComponent> components;
  final bool conflicted;

  /// Contradictory ingredient/dose evidence is independent of trade identity.
  /// Keep it visible even when semantic composition abstains from a value.
  final bool compositionConflicted;

  String get salt => components.map((value) => value.ingredient).join(' + ');

  String get strength => components
      .map((value) => value.strength)
      .where((value) => value.isNotEmpty)
      .join(' + ');

  double get compositionConfidence => components.isEmpty
      ? 0
      : components
            .map((value) => value.confidence)
            .reduce(min)
            .clamp(0, 1)
            .toDouble();

  bool get genericOnly {
    final saltKey = searchText(salt);
    final genericKey = searchText(genericName);
    return brand.trim().isEmpty &&
        saltKey.isNotEmpty &&
        genericKey.isNotEmpty &&
        _semanticSimilarity(saltKey, genericKey) >= .90;
  }

  bool get isEmpty =>
      brand.trim().isEmpty &&
      genericName.trim().isEmpty &&
      components.isEmpty &&
      !conflicted &&
      !compositionConflicted;
}

MedicineSemanticResolution inferMedicineSemanticRoles(
  Iterable<MedicineFrameEvidence> source,
) {
  final graph = buildOfflineEvidenceGraph(source, maxFrames: 12);
  final frames = graph.groups.isEmpty
      ? source.take(12).toList(growable: false)
      : graph.groups
            .map((group) => group.representative)
            .toList(growable: false);
  if (frames.isEmpty) return const MedicineSemanticResolution();

  final componentVotes = <String, _ComponentVote>{};
  final brandVotes = <String, _TextVote>{};
  final genericVotes = <String, _TextVote>{};
  var order = 0;

  void rememberComponent(_ComponentCandidate candidate) {
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
        _strengthKey(old.strength) ==
        _strengthKey(candidate.strength);
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

  void rememberText(
    Map<String, _TextVote> target,
    Set<String> observedInFrame,
    String value,
    double confidence,
  ) {
    final clean = _cleanSemanticText(value);
    final key = searchText(clean);
    if (key.length < 3 || _semanticNoiseOnly(key)) return;
    final independent = observedInFrame.add(key);
    final old = target[key];
    target[key] = old == null
        ? _TextVote(clean, confidence, 1)
        : _TextVote(
            old.value,
            max(old.confidence, confidence),
            old.support + (independent ? 1 : 0),
          );
  }

  for (final frame in frames) {
    final quality = frame.quality.clamp(0, 1).toDouble();
    final lines = _orderedFrameLines(frame);
    if (lines.isEmpty) continue;

    final frameComponents = <String, _ComponentCandidate>{};
    final frameBrands = <String>{};
    final frameGenerics = <String>{};

    // All semantic lanes converge through one per-frame gate. A single camera
    // frame therefore contributes at most one vote for the same ingredient and
    // dose even if more than one deterministic rule recognizes it.
    void rememberFrameComponent(_ComponentCandidate component) {
      final rawKey = searchText(component.ingredient);
      if (rawKey.length < 3) return;
      // Equal doses on different ingredients and contradictory doses on one
      // ingredient are distinct facts. Only the same ingredient/dose pair may
      // collapse across semantic rules inside a single physical frame.
      String key = '$rawKey|${_strengthKey(component.strength)}';
      for (final existing in frameComponents.entries) {
        final sameStrength =
            _strengthKey(existing.value.strength) ==
            _strengthKey(component.strength);
        if (!sameStrength) continue;
        if (_semanticSimilarity(
              searchText(existing.value.ingredient),
              rawKey,
            ) >=
            .955) {
          key = existing.key;
          break;
        }
      }
      final old = frameComponents[key];
      if (old == null) {
        frameComponents[key] = component;
        return;
      }
      final semanticallySame =
          _semanticSimilarity(
            searchText(old.ingredient),
            searchText(component.ingredient),
          ) >=
          .955;
      final cleanerIngredient =
          semanticallySame &&
          component.ingredient.length < old.ingredient.length;
      if (cleanerIngredient || component.confidence > old.confidence + .03) {
        frameComponents[key] = component;
      }
    }

    for (final window in _compositionWindows(lines)) {
      for (final component in _parseComposition(window, quality)) {
        rememberFrameComponent(component);
      }
    }

    // Generic/Salt labels are high-authority packaging evidence. OCR often
    // emits label, value and dose as separate rows, so preserve bounded
    // adjacency rather than requiring all three to survive on one OCR line.
    for (final component in _labelledCompositionCandidates(lines, quality)) {
      rememberFrameComponent(component);
    }

    // Packaging OCR frequently loses the COMPOSITION/CONTAINS heading while
    // still reading a clinically useful ingredient + dose line perfectly.
    for (final component in _unlabelledCompositionCandidates(lines, quality)) {
      rememberFrameComponent(component);
    }

    // Also recover the common "PARACETAMOL I.P." / "650 mg" shape. A
    // pharmaceutical morphology gate plus a dose-only adjacent line prevents a
    // trade heading such as "CROCIN" / "650 mg" becoming an invented salt.
    for (final component in _splitUnlabelledCompositionCandidates(
      lines,
      quality,
    )) {
      rememberFrameComponent(component);
    }

    for (final component in frameComponents.values) {
      rememberComponent(component);
    }

    for (var index = 0; index < lines.length; index++) {
      final raw = lines[index].text;
      final normalized = searchText(raw);
      if (normalized.isEmpty) continue;

      final explicitBrand = _semanticLabelValue(lines, index, _brandLabel);
      if (explicitBrand.isNotEmpty) {
        rememberText(
          brandVotes,
          frameBrands,
          _stripTradePresentation(explicitBrand),
          .97,
        );
      }
      final explicitGeneric = _semanticLabelValue(lines, index, _genericLabel);
      if (explicitGeneric.isNotEmpty) {
        rememberText(
          genericVotes,
          frameGenerics,
          _stripGenericPresentation(explicitGeneric),
          .965,
        );
      }

      // Legal-company rows are high-salience uppercase text on many medicine
      // packs. They are useful manufacturer evidence elsewhere, but they must
      // never compete with an unlabelled trade name merely because they are
      // early, large, or uppercase. Explicit BRAND/PRODUCT NAME labels above
      // remain authoritative and are intentionally evaluated before this gate.
      if (_compositionCue.hasMatch(normalized) ||
          _brandLabel.hasMatch(normalized) ||
          _genericLabel.hasMatch(normalized) ||
          _semanticLegalNoise.hasMatch(normalized) ||
          _semanticDateNoise.hasMatch(normalized) ||
          _manufacturerNoise.hasMatch(normalized) ||
          _companyIdentityNoise.hasMatch(normalized)) {
        continue;
      }
      if (raw.length < 3 || raw.length > 72) continue;

      var candidate = _stripPresentation(raw);
      if (candidate.length < 3 || _semanticNoiseOnly(searchText(candidate))) {
        continue;
      }
      if (_strengthPattern.hasMatch(candidate) &&
          candidate.replaceAll(_strengthPattern, '').trim().length < 3) {
        continue;
      }
      candidate = candidate
          .replaceAll(_strengthPattern, ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (candidate.length < 3) continue;

      final candidateKey = searchText(candidate);
      final containedComponents = componentVotes.values
          .where((component) {
            final ingredientKey = searchText(component.ingredient);
            return ingredientKey.length >= 4 &&
                candidateKey.contains(ingredientKey);
          })
          .take(2)
          .length;
      final componentLike =
          componentVotes.values.any(
            (component) =>
                _semanticSimilarity(
                  candidateKey,
                  searchText(component.ingredient),
                ) >=
                .90,
          ) ||
          containedComponents >= 2;
      if (componentLike) {
        rememberText(
          genericVotes,
          frameGenerics,
          candidate,
          .82 + quality * .05,
        );
        continue;
      }

      var score = .60 + quality * .08;
      if (index < 3) score += .08;
      if (RegExp(r'[®™]').hasMatch(raw)) score += .08;
      final uppercase = _uppercaseRatio(raw);
      score += min(.07, uppercase * .08);
      score += lines[index].prominence.clamp(0, .12);
      if (score >= .72) {
        rememberText(brandVotes, frameBrands, candidate, score.clamp(0, .94));
      }
    }
  }

  final components = componentVotes.values.toList(growable: false)
    ..sort((a, b) => a.order.compareTo(b.order));
  final resolvedComponents = <MedicineIngredientComponent>[];
  final componentConflict = components.any((item) => item.conflicted);
  for (final item in components.take(6)) {
    final confidence =
        (item.confidence + min(.07, max(0, item.support - 1) * .025))
            .clamp(0, .99)
            .toDouble();
    if (confidence < .76) continue;
    resolvedComponents.add(
      MedicineIngredientComponent(
        ingredient: item.ingredient,
        strength: item.strength,
        confidence: confidence,
        support: item.support,
      ),
    );
  }
  // Composition disagreement is field-local. Do not let a conflicting dose or
  // salt erase independently clean trade-name evidence. Abstain from semantic
  // composition entirely and explicitly pass its conflict to the resolver;
  // otherwise an already confident baseline dose could escape review.
  if (componentConflict) resolvedComponents.clear();

  double textScore(_TextVote vote) =>
      (vote.confidence + min(.08, max(0, vote.support - 1) * .03))
          .clamp(0, .99)
          .toDouble();

  _TextVote? chooseText(Map<String, _TextVote> votes, {required bool brand}) {
    final ranked = votes.values.toList(growable: false)
      ..sort((a, b) {
        final score = textScore(b).compareTo(textScore(a));
        if (score != 0) return score;
        final confidence = b.confidence.compareTo(a.confidence);
        if (confidence != 0) return confidence;
        return a.value.compareTo(b.value);
      });
    if (ranked.isEmpty) return null;
    if (!brand || resolvedComponents.isEmpty) return ranked.first;
    for (final candidate in ranked) {
      final isIngredient = resolvedComponents.any(
        (component) =>
            _semanticSimilarity(
              searchText(candidate.value),
              searchText(component.ingredient),
            ) >=
            .90,
      );
      if (!isIngredient) return candidate;
    }
    return null;
  }

  final brand = chooseText(brandVotes, brand: true);
  final generic = chooseText(genericVotes, brand: false);
  // Only an emitted semantic lane may poison that lane. Composition conflict
  // above abstains instead of globally suppressing brand identity.
  var conflicted = false;

  if (brand != null) {
    // Conflict evaluation must use the same support-aware ordering that selected
    // the winner. Comparing raw detector confidence here previously allowed a
    // single competing frame to veto a consistently repeated trade name.
    final ranked = brandVotes.values.toList(growable: false)
      ..sort((a, b) {
        final score = textScore(b).compareTo(textScore(a));
        if (score != 0) return score;
        return a.value.compareTo(b.value);
      });
    if (ranked.length > 1) {
      final first = ranked[0];
      final second = ranked[1];
      final firstScore = textScore(first);
      final secondScore = textScore(second);
      final distinct =
          _semanticSimilarity(
            searchText(first.value),
            searchText(second.value),
          ) <
          .80;
      if (distinct &&
          firstScore >= .80 &&
          secondScore >= .78 &&
          firstScore - secondScore < .06) {
        conflicted = true;
      }
    }
  }

  double effectiveTextConfidence(_TextVote? vote) =>
      vote == null ? 0 : textScore(vote);

  return MedicineSemanticResolution(
    brand: conflicted ? '' : brand?.value ?? '',
    brandConfidence: conflicted ? 0 : effectiveTextConfidence(brand),
    genericName: generic?.value ?? '',
    genericConfidence: effectiveTextConfidence(generic),
    components: List<MedicineIngredientComponent>.unmodifiable(
      resolvedComponents,
    ),
    conflicted: conflicted,
    compositionConflicted: componentConflict,
  );
}

class _SemanticLine {
  const _SemanticLine(this.text, this.prominence);
  final String text;
  final double prominence;
}

class _TextVote {
  const _TextVote(this.value, this.confidence, this.support);
  final String value;
  final double confidence;
  final int support;
}

class _ComponentCandidate {
  const _ComponentCandidate(this.ingredient, this.strength, this.confidence);
  final String ingredient;
  final String strength;
  final double confidence;
}

class _ComponentVote {
  const _ComponentVote(
    this.ingredient,
    this.strength,
    this.confidence,
    this.support,
    this.order, {
    this.conflicted = false,
  });
  final String ingredient;
  final String strength;
  final double confidence;
  final int support;
  final int order;
  final bool conflicted;
}

List<_SemanticLine> _orderedFrameLines(MedicineFrameEvidence frame) {
  final result = <_SemanticLine>[];
  // Geometry is sorted by a total order, then assigned to anchored rows.
  // Pairwise "close enough to share a row" is not transitive and must never
  // be used as a sort comparator.
  final spatial = frame.layoutLines
      .where((line) =>
          line.left.isFinite &&
          line.top.isFinite &&
          line.width.isFinite &&
          line.height.isFinite &&
          line.height > 0)
      .take(160)
      .toList(growable: false)
    ..sort(_compareLayoutReadingOrder);
  final layout = <MedicineTextLineEvidence>[];
  var index = 0;
  while (index < spatial.length) {
    final anchor = spatial[index++];
    final row = <MedicineTextLineEvidence>[anchor];
    final anchorCenter = anchor.top + anchor.height / 2;
    while (index < spatial.length) {
      final line = spatial[index];
      final center = line.top + line.height / 2;
      final tolerance = max(3.0, min(anchor.height, line.height) * .65);
      if ((center - anchorCenter).abs() > tolerance) break;
      row.add(line);
      index++;
    }
    row.sort((left, right) {
      final horizontal = left.left.compareTo(right.left);
      return horizontal != 0
          ? horizontal
          : _compareLayoutReadingOrder(left, right);
    });
    layout.addAll(row);
  }

  final heights = layout.map((line) => line.height).toList(growable: false)
    ..sort();
  final median = heights.isEmpty ? 0.0 : heights[heights.length ~/ 2];
  final positions = <String>{};
  final layoutOccurrences = <String, int>{};
  for (final line in layout) {
    final clean = line.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final key = searchText(clean);
    if (key.length < 2) continue;
    final position =
        '$key|${line.left}|${line.top}|${line.width}|${line.height}';
    if (!positions.add(position)) continue;
    // Equal text in different physical regions remains separate evidence.
    // In particular, two ingredients can each have a printed "5 mg" row.
    layoutOccurrences.update(key, (count) => count + 1, ifAbsent: () => 1);
    final relative = median <= 0 ? 0.0 : line.height / median;
    final prominence = ((relative - 1) * .10).clamp(0, .12).toDouble();
    result.add(_SemanticLine(clean, prominence));
  }
  for (final raw in frame.text.split(RegExp(r'[\r\n]+')).take(180)) {
    final clean = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final key = searchText(clean);
    if (key.length < 2) continue;
    final represented = layoutOccurrences[key] ?? 0;
    if (represented > 0) {
      layoutOccurrences[key] = represented - 1;
      continue;
    }
    // Preserve multiplicity within raw OCR too. Cross-rule/frame voting owns
    // deduplication; deleting repeated words here destroys label/dose adjacency.
    result.add(_SemanticLine(clean, 0));
  }
  return result;
}

int _compareLayoutReadingOrder(
  MedicineTextLineEvidence left,
  MedicineTextLineEvidence right,
) {
  final vertical = left.top.compareTo(right.top);
  if (vertical != 0) return vertical;
  final horizontal = left.left.compareTo(right.left);
  if (horizontal != 0) return horizontal;
  final text = left.text.compareTo(right.text);
  if (text != 0) return text;
  final height = left.height.compareTo(right.height);
  if (height != 0) return height;
  return left.width.compareTo(right.width);
}

List<String> _compositionWindows(List<_SemanticLine> lines) {
  final result = <String>[];
  for (var index = 0; index < lines.length; index++) {
    final normalized = searchText(lines[index].text);
    if (!_compositionCue.hasMatch(normalized)) continue;
    final parts = <String>[lines[index].text];
    var consumedThrough = index;
    var characters = parts.first.length;
    for (
      var next = index + 1;
      next < lines.length && next <= index + 7;
      next++
    ) {
      final value = searchText(lines[next].text);
      if (_compositionStop.hasMatch(value)) break;
      final nextText = lines[next].text;
      if (characters + 1 + nextText.length > 420) break;
      parts.add(nextText);
      characters += 1 + nextText.length;
      consumedThrough = next;
    }
    final window = parts.join('\n');
    if (_strengthPattern.hasMatch(window)) result.add(window);
    index = consumedThrough;
  }
  return result;
}

List<_ComponentCandidate> _labelledCompositionCandidates(
  List<_SemanticLine> lines,
  double quality,
) {
  final result = <_ComponentCandidate>[];
  for (var index = 0; index < lines.length; index++) {
    if (!_genericLabel.hasMatch(lines[index].text)) continue;
    final located = _semanticLabelValueWithIndex(lines, index, _genericLabel);
    if (located == null) continue;
    final valueRaw = located.$1;
    final inlineStrengths = _strengthPattern
        .allMatches(valueRaw)
        .take(3)
        .toList(growable: false);
    if (inlineStrengths.length > 1) {
      for (final component in _parseComposition(valueRaw, quality)) {
        result.add(
          _ComponentCandidate(
            component.ingredient,
            component.strength,
            max(component.confidence, .93),
          ),
        );
      }
      continue;
    }

    final strengthMatch = inlineStrengths.firstOrNull;
    String strengthRaw = strengthMatch?.group(0) ?? '';
    final ingredientRaw = strengthMatch == null
        ? valueRaw
        : '${valueRaw.substring(0, strengthMatch.start)} ${valueRaw.substring(strengthMatch.end)}';

    if (strengthRaw.isEmpty && located.$2 + 1 < lines.length) {
      final adjacent = lines[located.$2 + 1].text.trim();
      if (_isDoseOnlyLine(adjacent)) {
        strengthRaw = _strengthPattern.firstMatch(adjacent)?.group(0) ?? '';
      }
    }
    if (strengthRaw.isEmpty) continue;

    final ingredient = _cleanIngredient(ingredientRaw);
    final strength = _normalizeStrength(strengthRaw);
    if (ingredient.length < 3 || strength.isEmpty) continue;
    final confidence = (.925 + quality * .05).clamp(.925, .98).toDouble();
    result.add(_ComponentCandidate(ingredient, strength, confidence));
  }
  return result;
}

List<_ComponentCandidate> _unlabelledCompositionCandidates(
  List<_SemanticLine> lines,
  double quality,
) {
  final result = <_ComponentCandidate>[];
  for (var index = 0; index < lines.length; index++) {
    final raw = lines[index].text.trim();
    if (raw.length < 5 || raw.length > 120) continue;
    final normalized = searchText(raw);
    if (normalized.isEmpty ||
        _compositionCue.hasMatch(normalized) ||
        _brandLabel.hasMatch(normalized) ||
        _genericLabel.hasMatch(normalized) ||
        _semanticLegalNoise.hasMatch(normalized) ||
        _semanticDateNoise.hasMatch(normalized) ||
        _manufacturerNoise.hasMatch(normalized) ||
        _companyIdentityNoise.hasMatch(normalized) ||
        _equivalentToHint.hasMatch(normalized) ||
        _unlabelledCompositionNoise.hasMatch(normalized) ||
        _compositionInstructionStop.hasMatch(normalized)) {
      continue;
    }

    final strengths = _strengthPattern
        .allMatches(raw)
        .take(5)
        .toList(growable: false);

    // Combination packs often lose the COMPOSITION heading while OCR still
    // preserves an exact "ingredient dose + ingredient dose" row. Recover only
    // this explicit shape: 2-4 aligned strengths, literal '+' separators, and a
    // pharmaceutical signal for every segment. This deliberately abstains on
    // prose, dosage directions and weak multi-number lines rather than inventing
    // a clinically unsafe salt/strength pairing.
    if (strengths.length > 1) {
      if (strengths.length > 4 || !raw.contains('+')) continue;
      final segments = raw.split('+').map((value) => value.trim()).toList();
      if (segments.length != strengths.length || segments.length > 4) continue;

      final parsed = _parseComposition(raw, quality);
      if (parsed.length != strengths.length) continue;

      final seenIngredients = <String>{};
      var safeCombination = true;
      for (var componentIndex = 0;
          componentIndex < parsed.length;
          componentIndex++) {
        final component = parsed[componentIndex];
        final segment = segments[componentIndex];
        final segmentStrengths = _strengthPattern
            .allMatches(segment)
            .take(2)
            .length;
        final ingredientKey = searchText(component.ingredient);
        final pharmaceuticalSignal =
            _pharmacopoeiaHint.hasMatch(segment) ||
            _genericChemistryHint.hasMatch(ingredientKey) ||
            _genericDrugMorphology.hasMatch(ingredientKey);
        if (segmentStrengths != 1 ||
            ingredientKey.length < 4 ||
            !pharmaceuticalSignal ||
            !seenIngredients.add(ingredientKey)) {
          safeCombination = false;
          break;
        }
      }
      if (!safeCombination) continue;

      for (final component in parsed) {
        final confidence = max(
          component.confidence,
          (.83 + quality * .06).clamp(.83, .92).toDouble(),
        );
        result.add(
          _ComponentCandidate(
            component.ingredient,
            component.strength,
            confidence,
          ),
        );
      }
      continue;
    }

    if (strengths.length != 1) continue;
    final match = strengths.single;
    if (match.start <= 0) continue;
    final prefix = raw.substring(0, match.start).trim();
    if (!RegExp(r'[A-Za-z]').hasMatch(prefix)) continue;
    final ingredient = _cleanIngredient(prefix);
    if (ingredient.length < 4 || ingredient.length > 88) continue;

    final ingredientKey = searchText(ingredient);
    if (ingredientKey.isEmpty) continue;
    final pharmacopoeial = _pharmacopoeiaHint.hasMatch(prefix);
    final chemical = _genericChemistryHint.hasMatch(ingredientKey);
    final genericMorphology = _genericDrugMorphology.hasMatch(ingredientKey);
    if (!pharmacopoeial && !chemical && !genericMorphology) continue;

    final strength = _normalizeStrength(match.group(0) ?? '');
    if (strength.isEmpty) continue;
    var confidence = .77 + quality * .08;
    if (pharmacopoeial) confidence += .065;
    if (chemical) confidence += .035;
    if (genericMorphology) confidence += .025;
    result.add(
      _ComponentCandidate(
        ingredient,
        strength,
        confidence.clamp(.78, .93).toDouble(),
      ),
    );
  }
  return result;
}

List<_ComponentCandidate> _splitUnlabelledCompositionCandidates(
  List<_SemanticLine> lines,
  double quality,
) {
  final result = <_ComponentCandidate>[];
  for (var index = 0; index + 1 < lines.length; index++) {
    final raw = lines[index].text.trim();
    final doseRaw = lines[index + 1].text.trim();
    if (raw.length < 4 || raw.length > 100 || !_isDoseOnlyLine(doseRaw)) {
      continue;
    }
    final normalized = searchText(raw);
    if (normalized.isEmpty ||
        _compositionCue.hasMatch(normalized) ||
        _brandLabel.hasMatch(normalized) ||
        _genericLabel.hasMatch(normalized) ||
        _semanticLegalNoise.hasMatch(normalized) ||
        _semanticDateNoise.hasMatch(normalized) ||
        _manufacturerNoise.hasMatch(normalized) ||
        _companyIdentityNoise.hasMatch(normalized) ||
        _equivalentToHint.hasMatch(normalized) ||
        _unlabelledCompositionNoise.hasMatch(normalized) ||
        _strengthPattern.hasMatch(raw)) {
      continue;
    }

    final ingredient = _cleanIngredient(raw);
    if (ingredient.length < 4 || ingredient.length > 88) continue;
    final ingredientKey = searchText(ingredient);
    final pharmacopoeial = _pharmacopoeiaHint.hasMatch(raw);
    final chemical = _genericChemistryHint.hasMatch(ingredientKey);
    final genericMorphology = _genericDrugMorphology.hasMatch(ingredientKey);
    if (!pharmacopoeial && !chemical && !genericMorphology) continue;

    final strength = _normalizeStrength(
      _strengthPattern.firstMatch(doseRaw)?.group(0) ?? '',
    );
    if (strength.isEmpty) continue;
    var confidence = .79 + quality * .075;
    if (pharmacopoeial) confidence += .055;
    if (chemical) confidence += .03;
    if (genericMorphology) confidence += .02;
    result.add(
      _ComponentCandidate(
        ingredient,
        strength,
        confidence.clamp(.80, .93).toDouble(),
      ),
    );
  }
  return result;
}

List<_ComponentCandidate> _parseComposition(String raw, double quality) {
  var source = raw.replaceAll('\r', '\n');
  final instructionStop = _compositionInstructionStop.firstMatch(source);
  if (instructionStop != null) {
    source = source.substring(0, instructionStop.start);
  }
  final matches = _strengthPattern
      .allMatches(source)
      .take(8)
      .toList(growable: false);
  if (matches.isEmpty) return const <_ComponentCandidate>[];
  final result = <_ComponentCandidate>[];
  var previousEnd = 0;
  for (final match in matches) {
    var segment = source.substring(previousEnd, match.start);
    previousEnd = match.end;
    segment = segment.split(RegExp(r'[+;,]')).last;
    if (_equivalentToHint.hasMatch(segment)) {
      segment = segment.split(_equivalentToHint).last;
    }
    final ingredient = _cleanIngredient(segment);
    if (ingredient.isEmpty) continue;
    final strength = _normalizeStrength(match.group(0) ?? '');
    if (strength.isEmpty) continue;
    final confidence = (.88 + quality * .07).clamp(0, .975).toDouble();
    result.add(_ComponentCandidate(ingredient, strength, confidence));
  }
  return result;
}

String _cleanIngredient(String raw) {
  var value = raw.replaceAll(RegExp(r'[\r\n]+'), ' ');
  value = value.replaceAll(
    RegExp(
      r'\b(?:composition|active\s+ingredients?|generic\s+name|each|film\s*coated|uncoated|tablet|tablets|capsule|capsules|contains?|content|of)\b\s*[:.-]*',
      caseSensitive: false,
    ),
    ' ',
  );
  value = value.replaceAll(_pharmacopoeiaHint, ' ');
  value = value.replaceAll(
    RegExp(r'^\s*(?:and|plus|with|as)\s+', caseSensitive: false),
    ' ',
  );
  value = value.replaceAll(RegExp(r'[^A-Za-z0-9()\-/ ]+'), ' ');
  value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (value.length < 3 || !RegExp(r'[A-Za-z]').hasMatch(value)) return '';
  final tokens = value.split(' ').where((token) => token.isNotEmpty).toList();
  while (tokens.isNotEmpty &&
      _ingredientNoise.contains(tokens.first.toLowerCase())) {
    tokens.removeAt(0);
  }
  if (tokens.isEmpty) return '';
  final bounded = tokens.length > 8
      ? tokens.sublist(tokens.length - 8)
      : tokens;
  final result = bounded.join(' ').trim();
  if (result.length < 3 || _semanticNoiseOnly(searchText(result))) return '';
  return result;
}

String _afterSemanticLabel(String raw, RegExp pattern) {
  final match = pattern.firstMatch(raw);
  if (match == null) return '';
  return raw
      .substring(match.end)
      .replaceFirst(RegExp(r'^\s*[:#.-]+\s*'), '')
      .trim();
}

(String, int)? _semanticLabelValueWithIndex(
  List<_SemanticLine> lines,
  int index,
  RegExp pattern,
) {
  final raw = lines[index].text;
  final inline = _afterSemanticLabel(raw, pattern);
  if (inline.isNotEmpty && _isSemanticValueCandidate(inline)) {
    return (inline, index);
  }
  if (!_isStandaloneSemanticLabel(raw, pattern)) return null;

  // OCR/layout streams sometimes place a pure presentation row (TABLETS,
  // CAPSULES, etc.) between a printed field label and its real value. Look
  // ahead at most two rows, skipping only presentation/dose-only noise. Stop at
  // another semantic/legal/date boundary so ownership can never jump fields.
  for (var next = index + 1; next < lines.length && next <= index + 2; next++) {
    final adjacent = lines[next].text.trim();
    if (adjacent.isEmpty) continue;
    final normalized = searchText(adjacent);
    if (_brandLabel.hasMatch(normalized) ||
        _genericLabel.hasMatch(normalized) ||
        _semanticLegalNoise.hasMatch(normalized) ||
        _semanticDateNoise.hasMatch(normalized) ||
        _manufacturerNoise.hasMatch(normalized) ||
        _compositionCue.hasMatch(normalized)) {
      return null;
    }
    if (_isSemanticValueCandidate(adjacent)) return (adjacent, next);
    final presentationOnly =
        _semanticNoiseOnly(searchText(_stripPresentation(adjacent))) ||
        _isDoseOnlyLine(adjacent);
    if (!presentationOnly) return null;
  }
  return null;
}

String _semanticLabelValue(
  List<_SemanticLine> lines,
  int index,
  RegExp pattern,
) =>
    _semanticLabelValueWithIndex(lines, index, pattern)?.$1 ?? '';

bool _isStandaloneSemanticLabel(String raw, RegExp pattern) {
  final match = pattern.firstMatch(raw);
  if (match == null) return false;
  bool emptyPresentation(String value) => value
      .replaceAll(RegExp(r'[\s:#._\-/]+'), '')
      .trim()
      .isEmpty;
  return emptyPresentation(raw.substring(0, match.start)) &&
      emptyPresentation(raw.substring(match.end));
}

bool _isSemanticValueCandidate(String raw) {
  final value = raw.trim();
  if (value.length < 3 || value.length > 120 || _isDoseOnlyLine(value)) {
    return false;
  }
  if (!RegExp(r'[A-Za-z].*[A-Za-z]|[A-Za-z]{2,}').hasMatch(value)) {
    return false;
  }
  final normalized = searchText(value);
  return normalized.isNotEmpty &&
      !_semanticNoiseOnly(normalized) &&
      !_compositionCue.hasMatch(normalized) &&
      !_brandLabel.hasMatch(normalized) &&
      !_genericLabel.hasMatch(normalized) &&
      !_semanticLegalNoise.hasMatch(normalized) &&
      !_semanticDateNoise.hasMatch(normalized) &&
      !_manufacturerNoise.hasMatch(normalized);
}

bool _isDoseOnlyLine(String raw) {
  final matches = _strengthPattern.allMatches(raw).take(2).toList();
  if (matches.length != 1) return false;
  var remainder = raw.replaceRange(matches.single.start, matches.single.end, ' ');
  remainder = remainder.replaceAll(
    RegExp(
      r'\b(?:per|each|tablet|tablets|capsule|capsules|dose|5\s*ml|ml)\b',
      caseSensitive: false,
    ),
    ' ',
  );
  remainder = remainder.replaceAll(RegExp(r'[\s:;,.()\-/]+'), ' ').trim();
  return remainder.isEmpty;
}

String _stripPresentation(String raw) {
  var value = raw.replaceAll(RegExp(r'[®™]'), ' ');
  value = value.replaceAll(_pharmacopoeiaHint, ' ');
  value = value.replaceAll(medicineFormPresentationPattern, ' ');
  value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return value;
}

// A printed trade name often carries a dose unit ("CROCIN 650 mg TABLETS").
// Keep the dose number because it can be part of the commercial variant, but do
// not let the unit/form contaminate the brand field or create a false conflict
// against canonical product identity.
String _stripTradePresentation(String raw) {
  var value = _stripPresentation(raw);
  value = value.replaceAllMapped(_strengthPattern, (match) {
    final dose = RegExp(r'\d+(?:[.,]\d+)?').firstMatch(match.group(0) ?? '');
    return dose == null ? ' ' : ' ${dose.group(0)} ';
  });
  return value.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _stripGenericPresentation(String raw) => _stripPresentation(raw)
    .replaceAll(_strengthPattern, ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _cleanSemanticText(String raw) => raw
    .replaceAll(RegExp(r'^[\s:#.-]+|[\s:#.-]+$'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _normalizeStrength(String raw) => raw
    .replaceAll(',', '.')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll('µ', 'u')
    .trim()
    .toLowerCase();

String _strengthKey(String raw) => medicineStrengthKey(raw);

bool _semanticNoiseOnly(String value) {
  if (value.isEmpty) return true;
  final tokens = value.split(' ').where((token) => token.isNotEmpty).toList();
  return tokens.isEmpty || tokens.every(_presentationNoise.contains);
}

double _uppercaseRatio(String raw) {
  var letters = 0;
  var uppercase = 0;
  for (final rune in raw.runes) {
    if (rune >= 65 && rune <= 90) {
      letters++;
      uppercase++;
    } else if (rune >= 97 && rune <= 122) {
      letters++;
    }
  }
  return letters == 0 ? 0 : uppercase / letters;
}

double _semanticSimilarity(String left, String right) {
  if (left == right) return 1;
  if (left.isEmpty || right.isEmpty) return 0;
  final leftTokens = left.split(' ').where((value) => value.isNotEmpty).toSet();
  final rightTokens = right
      .split(' ')
      .where((value) => value.isNotEmpty)
      .toSet();
  final union = leftTokens.union(rightTokens).length;
  final token = union == 0
      ? 0.0
      : leftTokens.intersection(rightTokens).length / union;
  return max(token, orderedSimilarity(left, right));
}

final _compositionCue = RegExp(
  r'\b(?:composition|active\s+ingredients?|each\s+(?:film\s*coated\s+)?(?:tablet|capsule|5\s*ml)[^\n]{0,32}\bcontains?)\b',
  caseSensitive: false,
);
final _compositionStop = RegExp(
  r'\b(?:manufactured|manufacturer|mfg|mfd|dom|exp|expn|xpry|expiry|doe|e\s*[./-]\s*d|batch|lot|mrp|storage|schedule|marketed|distributed|pkd|pkg|packed|packing|use\s*(?:before|by|till|until)|best\s*before|valid\s*(?:till|until))\b',
  caseSensitive: false,
);
final _compositionInstructionStop = RegExp(
  r'\b(?:dosage|directions?|take|administer(?:ed|ing)?|administration|warning|caution|excipients?|preservatives?|colour|color|flavou?r)\b|\bdose\s*[:.-]?\s*(?=\d)',
  caseSensitive: false,
);
final _brandLabel = RegExp(
  r'\b(?:brand(?:\s+name)?|trade\s+(?:name|mark)|product\s*name|proprietary\s+name)\b',
  caseSensitive: false,
);
final _genericLabel = RegExp(
  r'\b(?:generic(?:\s+name)?|active\s+ingredients?|salt)\b',
  caseSensitive: false,
);
final _semanticLegalNoise = RegExp(
  r'\b(?:schedule|prescription|warning|storage|keep\s+out|licen[cs]e|marketed|distributed|address|customer\s+care)\b',
  caseSensitive: false,
);
final _semanticDateNoise = RegExp(
  r'\b(?:mfg|mfd|dom|manufactured|exp|expn|xpry|expiry|doe|e\s*[./-]\s*d|batch|lot|mrp|pkd|pkg|packed|packing|use\s*(?:before|by|till|until)|best\s*before|valid\s*(?:till|until))\b',
  caseSensitive: false,
);
final _manufacturerNoise = RegExp(
  r'\b(?:manufactured\s+by|mfg\.?\s+by|manufacturer|made\s+by)\b',
  caseSensitive: false,
);

// Corporate identity is a different semantic role from a medicine trade name.
// Keep this separate from general legal noise so an explicit BRAND NAME value
// is still accepted when the packaging itself declares it, while unlabelled
// company rows cannot win the visual-prominence brand heuristic.
final _companyIdentityNoise = medicineCompanyIdentityMarker;

final _unlabelledCompositionNoise = RegExp(
  r'(?:₹|\brs\.?\b|\bm\s*\.?\s*r\s*\.?\s*p\.?\b|\bprice\b|\bpack\b|\bstrip\b|\bblister\b|\bnet\s+(?:qty|quantity|content)\b|\bbatch\b|\blot\b|\bmfg\b|\bmfd\b|\bdom\b|\b(?:exp(?:iry)?|expn|xpry)\b|\be\s*[./-]\s*d\b|\bdoe\b|\bpkd\b|\bpkg\b|\bpacked\b|\bpacking\b|\buse\s*(?:before|by|till|until)\b|\bbest\s*before\b|\bvalid\s*(?:till|until)\b|\blicen[cs]e\b|\bstorage\b|\bmarketed\b|\bmanufactured\b|\bdistributed\b|\baddress\b|\bmade\s+in\b|\bfor\s+(?:oral|external)\s+use\b|\bexcipients?\b|\bcolour\b|\bflavou?r\b)',
  caseSensitive: false,
);
final _pharmacopoeiaHint = RegExp(
  r'\b(?:I\.?\s*P\.?|B\.?\s*P\.?|U\.?\s*S\.?\s*P\.?|Ph\.?\s*Eur\.?)\b',
  caseSensitive: false,
);
final _genericChemistryHint = RegExp(
  r'\b(?:hydrochloride|hcl|dihydrate|trihydrate|monohydrate|sodium|potassium|calcium|magnesium|maleate|besylate|mesylate|succinate|tartrate|citrate|phosphate|sulphate|sulfate|nitrate|acetate|clavulanate|clavulanic\s+acid)\b',
  caseSensitive: false,
);
final _genericDrugMorphology = RegExp(
  r'(?:cillin|cycline|floxacin|mycin|micin|azole|prazole|pril|sartan|olol|statin|caine|dipine|terol|tadine|oxetine|zepam|vir|mab|nib|gliptin|gliflozin|formin|profen|coxib|semide|thiazide)\b',
  caseSensitive: false,
);
final _equivalentToHint = RegExp(
  r'\bequivalent\s+to\b',
  caseSensitive: false,
);
final _strengthPattern = medicineStrengthPattern;

const _ingredientNoise = <String>{
  'equivalent',
  'to',
  'active',
  'ingredient',
  'ingredients',
  'generic',
  'name',
  'salt',
};

const _presentationNoise = <String>{
  'tablet',
  'tablets',
  'capsule',
  'capsules',
  'syrup',
  'suspension',
  'solution',
  'injection',
  'cream',
  'ointment',
  'gel',
  'lotion',
  'drops',
  'drop',
  'spray',
  'inhaler',
  'powder',
  'sachet',
  'sachets',
  'ip',
  'bp',
  'usp',
};
