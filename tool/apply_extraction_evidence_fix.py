#!/usr/bin/env python3
"""Reapply the reviewed extraction repair to the pinned source, idempotently.

Usage:
  python3 tool/apply_extraction_evidence_fix.py --check
  python3 tool/apply_extraction_evidence_fix.py [--root /path/to/repository]

Every source hash and exact anchor is checked before any file is replaced.
Divergent source is rejected. No dependency install, test, build, network call,
commit or push is performed by this script.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile

PATCHES = json.loads(r'''[
  {
    "path": "lib/domain/medicine_date_parser.dart",
    "before_sha": "bd79863736b090fbae15b294bf0f1eecb6bfadf6",
    "after_sha": "314a05506ea0eafce8d5965b4fba8cccb0a895b5",
    "replacements": [
      [
        "  // Year-first named dates are unambiguous when a four-digit year and literal",
        "  // A named month also makes MONTH DAY YEAR unambiguous when the final\n  // year has four digits. Reserve the whole surface before validating it:\n  // \"APR 31, 2028\" must not degrade into the month-only date \"APR 31\".\n  add(\n    RegExp(\n      '(?<![$namedMonthBoundary])($monthNames)$sep(\\\\d{1,2})$sep(20\\\\d{2})(?![$namedMonthBoundary])',\n      caseSensitive: false,\n    ),\n    (m) => _date(int.parse(m[3]!), _month(m[1]!), int.parse(m[2]!)),\n  );\n  // Year-first named dates are unambiguous when a four-digit year and literal"
      ]
    ]
  },
  {
    "path": "lib/domain/medicine_date_intelligence_core.dart",
    "before_sha": "e2ccf39631884ab38e950a51f95e6d570ca331fe",
    "after_sha": "48f383d1921caf2176af7f861af3221563ad44f0",
    "replacements": [
      [
        "    for (final orderedLines in _dateLineStreams(frame)) {\n      final acceptedBareCompact = _bareCompactDatePairIndexes(\n        orderedLines,\n        today,\n      );",
        "    for (final orderedLines in _dateLineStreams(frame)) {\n      // Tokenize each bounded line once. Pair discovery and adjacency checks\n      // reuse the same offsets and calendar decisions as role assignment.\n      final matchesByLine = orderedLines\n          .map((line) => extractMedicineDateMatches(line, allowCompact: true))\n          .toList(growable: false);\n      final acceptedBareCompact = _bareCompactDatePairIndexes(\n        orderedLines,\n        matchesByLine,\n        today,\n      );"
      ],
      [
        "        final matches = extractMedicineDateMatches(line, allowCompact: true);",
        "        final matches = matchesByLine[index];"
      ],
      [
        "                  _isStandaloneDateLine(orderedLines[index + 2]);",
        "                  matchesByLine[index + 2].length == 1 &&\n                  _isStandaloneDateMatch(\n                    orderedLines[index + 2],\n                    matchesByLine[index + 2].single,\n                  );"
      ]
    ]
  },
  {
    "path": "lib/domain/medicine_date_intelligence_helpers.dart",
    "before_sha": "4b04fc355dae660259f3c9e19e0bd9cd02be7b83",
    "after_sha": "1a33cd68423826ef3256e9b242cc580049b75a68",
    "replacements": [
      [
        "Set<int> _bareCompactDatePairIndexes(List<String> lines, DateTime today) {",
        "Set<int> _bareCompactDatePairIndexes(\n  List<String> lines,\n  List<List<MedicineDateMatch>> matchesByLine,\n  DateTime today,\n) {"
      ],
      [
        "    final matches = extractMedicineDateMatches(lines[index], allowCompact: true);",
        "    final matches = matchesByLine[index];"
      ],
      [
        "bool _isStandaloneDateLine(String line) {\n  final matches = extractMedicineDateMatches(line, allowCompact: true);\n  return matches.length == 1 && _isStandaloneDateMatch(line, matches.single);\n}\n\n",
        ""
      ]
    ]
  },
  {
    "path": "lib/domain/medicine_semantic_roles.dart",
    "before_sha": "af07b18d45a04398a1a9f6b7e6eeda8b8c35e5e1",
    "after_sha": "c6c26a666ba4da5cd246765cc23467ca6bc259ee",
    "replacements": [
      [
        "    this.conflicted = false,\n  });\n\n  final String brand;",
        "    this.conflicted = false,\n    this.compositionConflicted = false,\n  });\n\n  final String brand;"
      ],
      [
        "  final bool conflicted;\n\n  String get salt",
        "  final bool conflicted;\n\n  /// Contradictory ingredient/dose evidence is independent of trade identity.\n  /// Keep it visible even when semantic composition abstains from a value.\n  final bool compositionConflicted;\n\n  String get salt"
      ],
      [
        "  bool get isEmpty =>\n      brand.trim().isEmpty && genericName.trim().isEmpty && components.isEmpty;",
        "  bool get isEmpty =>\n      brand.trim().isEmpty &&\n      genericName.trim().isEmpty &&\n      components.isEmpty &&\n      !conflicted &&\n      !compositionConflicted;"
      ],
      [
        "    Map<String, _TextVote> target,\n    String value,",
        "    Map<String, _TextVote> target,\n    Set<String> observedInFrame,\n    String value,"
      ],
      [
        "    final old = target[key];\n    target[key] = old == null",
        "    final independent = observedInFrame.add(key);\n    final old = target[key];\n    target[key] = old == null"
      ],
      [
        "            old.support + 1,\n          );",
        "            old.support + (independent ? 1 : 0),\n          );"
      ],
      [
        "    final frameComponents = <String, _ComponentCandidate>{};",
        "    final frameComponents = <String, _ComponentCandidate>{};\n    final frameBrands = <String>{};\n    final frameGenerics = <String>{};"
      ],
      [
        "      String key = rawKey;\n      for (final existing in frameComponents.entries) {",
        "      // Equal doses on different ingredients and contradictory doses on one\n      // ingredient are distinct facts. Only the same ingredient/dose pair may\n      // collapse across semantic rules inside a single physical frame.\n      String key = '$rawKey|${_strengthKey(component.strength)}';\n      for (final existing in frameComponents.entries) {"
      ],
      [
        "        if (_semanticSimilarity(existing.key, rawKey) >= .955) {\n          key = existing.key;\n          break;\n        }\n      }\n      final old = frameComponents[key];",
        "        if (_semanticSimilarity(\n              searchText(existing.value.ingredient),\n              rawKey,\n            ) >=\n            .955) {\n          key = existing.key;\n          break;\n        }\n      }\n      final old = frameComponents[key];"
      ],
      [
        "        rememberText(brandVotes, _stripTradePresentation(explicitBrand), .97);",
        "        rememberText(\n          brandVotes,\n          frameBrands,\n          _stripTradePresentation(explicitBrand),\n          .97,\n        );"
      ],
      [
        "          genericVotes,\n          _stripGenericPresentation(explicitGeneric),",
        "          genericVotes,\n          frameGenerics,\n          _stripGenericPresentation(explicitGeneric),"
      ],
      [
        "        rememberText(genericVotes, candidate, .82 + quality * .05);",
        "        rememberText(\n          genericVotes,\n          frameGenerics,\n          candidate,\n          .82 + quality * .05,\n        );"
      ],
      [
        "        rememberText(brandVotes, candidate, score.clamp(0, .94));",
        "        rememberText(brandVotes, frameBrands, candidate, score.clamp(0, .94));"
      ],
      [
        "  var componentConflict = false;\n  for (final item in components.take(6)) {\n    componentConflict = componentConflict || item.conflicted;",
        "  final componentConflict = components.any((item) => item.conflicted);\n  for (final item in components.take(6)) {"
      ],
      [
        "  // composition entirely and let the baseline/resolver keep that field in\n  // review, while brand inference remains usable.",
        "  // composition entirely and explicitly pass its conflict to the resolver;\n  // otherwise an already confident baseline dose could escape review."
      ],
      [
        "    conflicted: conflicted,\n  );\n}\n\nclass _SemanticLine",
        "    conflicted: conflicted,\n    compositionConflicted: componentConflict,\n  );\n}\n\nclass _SemanticLine"
      ],
      [
        "List<_SemanticLine> _orderedFrameLines(MedicineFrameEvidence frame) {\n  final result = <_SemanticLine>[];\n  final seen = <String>{};\n  // ML Kit recognizers are merged from more than one script. Their insertion\n  // order is therefore not guaranteed to be physical reading order. Sort a\n  // bounded copy by row/column geometry before any adjacency-sensitive semantic\n  // parsing so a COMPOSITION heading still owns the ingredient printed beneath\n  // it even when the recognizer streams arrived in the opposite order.\n  final layout = frame.layoutLines.take(160).toList(growable: false)\n    ..sort(_compareLayoutReadingOrder);\n  final heights =\n      layout\n          .where((line) => line.height > 0)\n          .map((line) => line.height)\n          .toList(growable: false)\n        ..sort();\n  final median = heights.isEmpty ? 0.0 : heights[heights.length ~/ 2];\n\n  for (final line in layout) {\n    final clean = line.text.replaceAll(RegExp(r'\\s+'), ' ').trim();\n    final key = searchText(clean);\n    if (key.length < 2 || !seen.add(key)) continue;\n    final relative = median <= 0 ? 0.0 : line.height / median;\n    final prominence = ((relative - 1) * .10).clamp(0, .12).toDouble();\n    result.add(_SemanticLine(clean, prominence));\n  }\n  for (final raw in frame.text.split(RegExp(r'[\\r\\n]+')).take(180)) {\n    final clean = raw.replaceAll(RegExp(r'\\s+'), ' ').trim();\n    final key = searchText(clean);\n    if (key.length < 2 || !seen.add(key)) continue;\n    result.add(_SemanticLine(clean, 0));\n  }\n  return result;\n}\n\nint _compareLayoutReadingOrder(\n  MedicineTextLineEvidence left,\n  MedicineTextLineEvidence right,\n) {\n  final leftCenterY = left.top + left.height / 2;\n  final rightCenterY = right.top + right.height / 2;\n  final rowTolerance = max(3.0, min(left.height, right.height) * .65);\n  if ((leftCenterY - rightCenterY).abs() > rowTolerance) {\n    final vertical = left.top.compareTo(right.top);\n    if (vertical != 0) return vertical;\n  }\n  final horizontal = left.left.compareTo(right.left);\n  if (horizontal != 0) return horizontal;\n  final vertical = left.top.compareTo(right.top);\n  if (vertical != 0) return vertical;\n  return left.text.compareTo(right.text);\n}\n\n",
        "List<_SemanticLine> _orderedFrameLines(MedicineFrameEvidence frame) {\n  final result = <_SemanticLine>[];\n  // Geometry is sorted by a total order, then assigned to anchored rows.\n  // Pairwise \"close enough to share a row\" is not transitive and must never\n  // be used as a sort comparator.\n  final spatial = frame.layoutLines\n      .where((line) =>\n          line.left.isFinite &&\n          line.top.isFinite &&\n          line.width.isFinite &&\n          line.height.isFinite &&\n          line.height > 0)\n      .take(160)\n      .toList(growable: false)\n    ..sort(_compareLayoutReadingOrder);\n  final layout = <MedicineTextLineEvidence>[];\n  var index = 0;\n  while (index < spatial.length) {\n    final anchor = spatial[index++];\n    final row = <MedicineTextLineEvidence>[anchor];\n    final anchorCenter = anchor.top + anchor.height / 2;\n    while (index < spatial.length) {\n      final line = spatial[index];\n      final center = line.top + line.height / 2;\n      final tolerance = max(3.0, min(anchor.height, line.height) * .65);\n      if ((center - anchorCenter).abs() > tolerance) break;\n      row.add(line);\n      index++;\n    }\n    row.sort((left, right) {\n      final horizontal = left.left.compareTo(right.left);\n      return horizontal != 0\n          ? horizontal\n          : _compareLayoutReadingOrder(left, right);\n    });\n    layout.addAll(row);\n  }\n\n  final heights = layout.map((line) => line.height).toList(growable: false)\n    ..sort();\n  final median = heights.isEmpty ? 0.0 : heights[heights.length ~/ 2];\n  final positions = <String>{};\n  final layoutOccurrences = <String, int>{};\n  for (final line in layout) {\n    final clean = line.text.replaceAll(RegExp(r'\\s+'), ' ').trim();\n    final key = searchText(clean);\n    if (key.length < 2) continue;\n    final position =\n        '$key|${line.left}|${line.top}|${line.width}|${line.height}';\n    if (!positions.add(position)) continue;\n    // Equal text in different physical regions remains separate evidence.\n    // In particular, two ingredients can each have a printed \"5 mg\" row.\n    layoutOccurrences.update(key, (count) => count + 1, ifAbsent: () => 1);\n    final relative = median <= 0 ? 0.0 : line.height / median;\n    final prominence = ((relative - 1) * .10).clamp(0, .12).toDouble();\n    result.add(_SemanticLine(clean, prominence));\n  }\n  for (final raw in frame.text.split(RegExp(r'[\\r\\n]+')).take(180)) {\n    final clean = raw.replaceAll(RegExp(r'\\s+'), ' ').trim();\n    final key = searchText(clean);\n    if (key.length < 2) continue;\n    final represented = layoutOccurrences[key] ?? 0;\n    if (represented > 0) {\n      layoutOccurrences[key] = represented - 1;\n      continue;\n    }\n    // Preserve multiplicity within raw OCR too. Cross-rule/frame voting owns\n    // deduplication; deleting repeated words here destroys label/dose adjacency.\n    result.add(_SemanticLine(clean, 0));\n  }\n  return result;\n}\n\nint _compareLayoutReadingOrder(\n  MedicineTextLineEvidence left,\n  MedicineTextLineEvidence right,\n) {\n  final vertical = left.top.compareTo(right.top);\n  if (vertical != 0) return vertical;\n  final horizontal = left.left.compareTo(right.left);\n  if (horizontal != 0) return horizontal;\n  final text = left.text.compareTo(right.text);\n  if (text != 0) return text;\n  final height = left.height.compareTo(right.height);\n  if (height != 0) return height;\n  return left.width.compareTo(right.width);\n}\n\n"
      ]
    ]
  },
  {
    "path": "lib/domain/medicine_resolution_v2.dart",
    "before_sha": "6ad0ba027d35768b0e032d91dc0011faa167075c",
    "after_sha": "fed16f7ba2004b9c8312d612b98e1363d8265aaa",
    "replacements": [
      [
        "    void addLine(String raw) {",
        "    void addLine(String raw, {bool fromLayout = false}) {"
      ],
      [
        "      if (key.isEmpty || !seen.add(key)) return;",
        "      if (key.isEmpty || (fromLayout && seen.contains(key))) return;\n      // Repeated text within one OCR stream can belong to different fields\n      // (\"5 mg\" below two ingredients, or repeated GENERIC NAME labels). Keep\n      // its position; suppress only layout text already present in that stream.\n      seen.add(key);"
      ],
      [
        "      addLine(line.text);",
        "      addLine(line.text, fromLayout: true);"
      ],
      [
        "  if (semantic.conflicted) {\n    for (final key in const <String>['name', 'brand', 'salt', 'strength']) {",
        "  if (semantic.compositionConflicted) {\n    for (final key in const <String>['salt', 'strength']) {\n      final field = fields[key];\n      // An empty conflicting field must also block later catalogue inheritance.\n      fields[key] = ExtractedMedicineField(\n        value: field?.value ?? '',\n        confidence: min(field?.confidence ?? 0, .77),\n        support: field?.support ?? 0,\n        conflicted: true,\n      );\n    }\n  }\n\n  if (semantic.conflicted) {\n    for (final key in const <String>['name', 'brand', 'salt', 'strength']) {"
      ],
      [
        "    overallConfidence: semantic.conflicted\n        ? min(draft.overallConfidence, .77)",
        "    overallConfidence: semantic.conflicted || semantic.compositionConflicted\n        ? min(draft.overallConfidence, .77)"
      ]
    ]
  }
]''')


def blob_sha(content):
    return hashlib.sha1(
        b"blob " + str(len(content)).encode("ascii") + b"\0" + content
    ).hexdigest()


def stage_bytes(target, content, mode):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", prefix="." + target.name + ".aaris-",
            dir=target.parent, delete=False,
        ) as output:
            temporary = Path(output.name)
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        return temporary
    except BaseException:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--check", action="store_true",
                        help="validate and report without changing files")
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    plan = []
    unchanged = 0

    for patch in PATCHES:
        target = root / patch["path"]
        if target.is_symlink():
            raise RuntimeError("Refusing a symbolic link: " + patch["path"])
        target.resolve(strict=True).relative_to(root)
        before = target.read_bytes()
        current_sha = blob_sha(before)
        if current_sha == patch["after_sha"]:
            unchanged += 1
            continue
        if current_sha != patch["before_sha"]:
            raise RuntimeError("Source differs from the reviewed version: " + patch["path"])
        text = before.decode("utf-8")
        for old, new in patch["replacements"]:
            if not old or text.count(old) != 1:
                raise RuntimeError("Patch anchor is missing or ambiguous: " + patch["path"])
            text = text.replace(old, new, 1)
        after = text.encode("utf-8")
        if blob_sha(after) != patch["after_sha"]:
            raise RuntimeError("Patched content hash mismatch: " + patch["path"])
        mode = stat.S_IMODE(target.stat().st_mode)
        plan.append((target, before, after, mode))

    if args.check:
        print(f"Validated: {len(plan)} files need repair; {unchanged} already repaired.")
        return

    staged = []
    applied = []
    try:
        for target, before, after, mode in plan:
            temporary = stage_bytes(target, after, mode)
            staged.append((target, before, after, mode, temporary))
        for target, before, after, mode, temporary in staged:
            if target.read_bytes() != before:
                raise RuntimeError("Source changed during repair: " + str(target))
            os.replace(temporary, target)
            applied.append((target, before, after, mode))
    except BaseException as failure:
        rollback_errors = []
        for target, before, after, mode in reversed(applied):
            rollback = None
            try:
                if target.read_bytes() != after:
                    raise RuntimeError("Preserved a concurrent edit: " + str(target))
                rollback = stage_bytes(target, before, mode)
                os.replace(rollback, target)
            except BaseException as error:
                rollback_errors.append(str(error))
            finally:
                if rollback is not None:
                    rollback.unlink(missing_ok=True)
        if rollback_errors:
            raise RuntimeError(
                "Repair failed; rollback needs attention: " + "; ".join(rollback_errors)
            ) from failure
        raise
    finally:
        for _, _, _, _, temporary in staged:
            temporary.unlink(missing_ok=True)

    print(f"Repaired {len(plan)} files; {unchanged} already repaired.")


if __name__ == "__main__":
    main()
