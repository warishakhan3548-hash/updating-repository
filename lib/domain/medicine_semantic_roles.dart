import 'dart:math';

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
  });

  final String brand;
  final double brandConfidence;
  final String genericName;
  final double genericConfidence;
  final List<MedicineIngredientComponent> components;
  final bool conflicted;

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
      brand.trim().isEmpty && genericName.trim().isEmpty && components.isEmpty;
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

  void rememberText(
    Map<String, _TextVote> target,
    String value,
    double confidence,
  ) {
    final clean = _cleanSemanticText(value);
    final key = searchText(clean);
    if (key.length < 3 || _semanticNoiseOnly(key)) return;
    final old = target[key];
    target[key] = old == null
        ? _TextVote(clean, confidence, 1)
        : _TextVote(
            old.value,
            max(old.confidence, confidence),
            old.support + 1,
          );
  }

  for (final frame in frames) {
    final quality = frame.quality.clamp(0, 1).toDouble();
    final lines = _orderedFrameLines(frame);
    if (lines.isEmpty) continue;

    final windows = _compositionWindows(lines);
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
    for (final component in frameComponents.values) {
      rememberComponent(component);
    }

    for (var index = 0; index < lines.length; index++) {
      final raw = lines[index].text;
      final normalized = searchText(raw);
      if (normalized.isEmpty) continue;

      final explicitBrand = _afterSemanticLabel(raw, _brandLabel);
      if (explicitBrand.isNotEmpty) {
        rememberText(brandVotes, _stripPresentation(explicitBrand), .97);
      }
      final explicitGeneric = _afterSemanticLabel(raw, _genericLabel);
      if (explicitGeneric.isNotEmpty) {
        rememberText(genericVotes, _stripPresentation(explicitGeneric), .965);
      }

      if (_compositionCue.hasMatch(normalized) ||
          _brandLabel.hasMatch(normalized) ||
          _genericLabel.hasMatch(normalized) ||
          _semanticLegalNoise.hasMatch(normalized) ||
          _semanticDateNoise.hasMatch(normalized) ||
          _manufacturerNoise.hasMatch(normalized)) {
        continue;
      }
      if (raw.length < 3 || raw.length > 72) continue;

      var candidate = _stripPresentation(raw);
      if (candidate.length < 3 || _semanticNoiseOnly(searchText(candidate)))
        continue;
      if (_strengthPattern.hasMatch(candidate) &&
          candidate.replaceAll(_strengthPattern, '').trim().length < 3) {
        continue;
      }
      candidate = candidate
          .replaceAll(_strengthPattern, ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (candidate.length < 3) continue;

      final componentLike = componentVotes.values.any(
        (component) =>
            _semanticSimilarity(
              searchText(candidate),
              searchText(component.ingredient),
            ) >=
            .90,
      );
      if (componentLike) {
        rememberText(genericVotes, candidate, .82 + quality * .05);
        continue;
      }

      var score = .60 + quality * .08;
      if (index < 3) score += .08;
      if (RegExp(r'[®™]').hasMatch(raw)) score += .08;
      final uppercase = _uppercaseRatio(raw);
      score += min(.07, uppercase * .08);
      score += lines[index].prominence.clamp(0, .12);
      if (score >= .72)
        rememberText(brandVotes, candidate, score.clamp(0, .94));
    }
  }

  final components = componentVotes.values.toList(growable: false)
    ..sort((a, b) => a.order.compareTo(b.order));
  final resolvedComponents = <MedicineIngredientComponent>[];
  var componentConflict = false;
  for (final item in components.take(6)) {
    componentConflict = componentConflict || item.conflicted;
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

  _TextVote? chooseText(Map<String, _TextVote> votes, {required bool brand}) {
    final ranked = votes.values.toList(growable: false)
      ..sort((a, b) {
        final left = a.confidence + min(.08, max(0, a.support - 1) * .03);
        final right = b.confidence + min(.08, max(0, b.support - 1) * .03);
        return right.compareTo(left);
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
  var conflicted = componentConflict;

  if (brand != null) {
    final ranked = brandVotes.values.toList(growable: false)
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    if (ranked.length > 1) {
      final first = ranked[0];
      final second = ranked[1];
      final distinct =
          _semanticSimilarity(
            searchText(first.value),
            searchText(second.value),
          ) <
          .80;
      if (distinct &&
          first.confidence >= .80 &&
          second.confidence >= .78 &&
          first.confidence - second.confidence < .06) {
        conflicted = true;
      }
    }
  }

  double effectiveTextConfidence(_TextVote? vote) => vote == null
      ? 0
      : (vote.confidence + min(.08, max(0, vote.support - 1) * .03))
            .clamp(0, .99)
            .toDouble();

  return MedicineSemanticResolution(
    brand: conflicted ? '' : brand?.value ?? '',
    brandConfidence: conflicted ? 0 : effectiveTextConfidence(brand),
    genericName: generic?.value ?? '',
    genericConfidence: effectiveTextConfidence(generic),
    components: List<MedicineIngredientComponent>.unmodifiable(
      resolvedComponents,
    ),
    conflicted: conflicted,
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
  final seen = <String>{};
  final heights =
      frame.layoutLines
          .where((line) => line.height > 0)
          .map((line) => line.height)
          .toList(growable: false)
        ..sort();
  final median = heights.isEmpty ? 0.0 : heights[heights.length ~/ 2];

  for (final line in frame.layoutLines.take(160)) {
    final clean = line.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final key = searchText(clean);
    if (key.length < 2 || !seen.add(key)) continue;
    final relative = median <= 0 ? 0.0 : line.height / median;
    final prominence = ((relative - 1) * .10).clamp(0, .12).toDouble();
    result.add(_SemanticLine(clean, prominence));
  }
  for (final raw in frame.text.split(RegExp(r'[\r\n]+')).take(180)) {
    final clean = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final key = searchText(clean);
    if (key.length < 2 || !seen.add(key)) continue;
    result.add(_SemanticLine(clean, 0));
  }
  return result;
}

List<String> _compositionWindows(List<_SemanticLine> lines) {
  final result = <String>[];
  for (var index = 0; index < lines.length; index++) {
    final normalized = searchText(lines[index].text);
    if (!_compositionCue.hasMatch(normalized)) continue;
    final parts = <String>[lines[index].text];
    var consumedThrough = index;
    for (
      var next = index + 1;
      next < lines.length && next <= index + 7;
      next++
    ) {
      final value = searchText(lines[next].text);
      if (_compositionStop.hasMatch(value)) break;
      parts.add(lines[next].text);
      consumedThrough = next;
      if (parts.fold<int>(0, (sum, value) => sum + value.length) > 420) break;
    }
    final window = parts.join('\n');
    if (_strengthPattern.hasMatch(window)) result.add(window);
    index = consumedThrough;
  }
  return result;
}

List<_ComponentCandidate> _parseComposition(String raw, double quality) {
  final source = raw.replaceAll('\r', '\n');
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
    final equivalent = RegExp(r'\bequivalent\s+to\b', caseSensitive: false);
    if (equivalent.hasMatch(segment)) segment = segment.split(equivalent).last;
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
  value = value.replaceAll(
    RegExp(
      r'\b(?:I\.?P\.?|B\.?P\.?|U\.?S\.?P\.?|Ph\.?\s*Eur\.?)\b',
      caseSensitive: false,
    ),
    ' ',
  );
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

String _stripPresentation(String raw) {
  var value = raw.replaceAll(RegExp(r'[®™]'), ' ');
  value = value.replaceAll(
    RegExp(
      r'\b(?:tablets?|capsules?|syrup|suspension|solution|injection|cream|ointment|gel|drops?|spray|inhaler|powder|sachets?)\b',
      caseSensitive: false,
    ),
    ' ',
  );
  value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return value;
}

String _cleanSemanticText(String raw) => raw
    .replaceAll(RegExp(r'^[\s:#.-]+|[\s:#.-]+$'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _normalizeStrength(String raw) => raw
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll('µ', 'u')
    .trim()
    .toLowerCase();

String _strengthKey(String raw) => searchText(raw).replaceAll(' ', '');

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
  r'\b(?:manufactured|manufacturer|mfg|mfd|exp|expiry|batch|lot|mrp|storage|schedule|marketed|distributed)\b',
  caseSensitive: false,
);
final _brandLabel = RegExp(
  r'\b(?:brand|trade|product)\s*name\b',
  caseSensitive: false,
);
final _genericLabel = RegExp(
  r'\b(?:generic\s+name|active\s+ingredient|salt)\b',
  caseSensitive: false,
);
final _semanticLegalNoise = RegExp(
  r'\b(?:schedule|prescription|warning|storage|keep\s+out|licen[cs]e|marketed|distributed|address|customer\s+care)\b',
  caseSensitive: false,
);
final _semanticDateNoise = RegExp(
  r'\b(?:mfg|mfd|manufactured|exp|expiry|batch|lot|mrp)\b',
  caseSensitive: false,
);
final _manufacturerNoise = RegExp(
  r'\b(?:manufactured\s+by|manufacturer|made\s+by)\b',
  caseSensitive: false,
);
final _strengthPattern = RegExp(
  r'(?<![\d.])\d+(?:\.\d+)?\s*(?:mcg|ug|µg|mg|gm|g|ml|iu|units?|%)(?:\s*/\s*(?:\d+(?:\.\d+)?\s*)?(?:ml|g))?',
  caseSensitive: false,
);

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
