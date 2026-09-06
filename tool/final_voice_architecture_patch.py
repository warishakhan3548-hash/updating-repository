#!/usr/bin/env python3
from pathlib import Path


def replace_once(path: str, old: str, new: str, marker: str) -> None:
    file = Path(path)
    text = file.read_text(encoding="utf-8")
    if old in text:
        if text.count(old) != 1:
            raise SystemExit(f"{path}: expected exactly one match for {marker}")
        file.write_text(text.replace(old, new, 1), encoding="utf-8")
        print(f"patched {path}: {marker}")
        return
    if marker not in text:
        raise SystemExit(f"{path}: neither old text nor marker found for {marker}")
    print(f"already patched {path}: {marker}")


# 1) Remove the mutable process-global engine compatibility bridge. The screen
# already injects its exact LudoEngine instance into VoiceDiceController.
replace_once(
    "lib/game/ludo_engine.dart",
    """  LudoEngine({required int playerCount}) {\n    _voiceRuntimeEngine = this;\n    reset(playerCount);\n  }\n\n  static LudoEngine? _voiceRuntimeEngine;\n\n  /// Compatibility bridge for the existing GameScreen construction order.\n  /// VoiceDiceController captures this engine once at construction; it does not\n  /// keep resolving a mutable global reference during gameplay.\n  static LudoEngine? get voiceRuntimeEngine => _voiceRuntimeEngine;\n""",
    """  LudoEngine({required int playerCount}) {\n    reset(playerCount);\n  }\n""",
    "LudoEngine({required int playerCount}) {\n    reset(playerCount);",
)
replace_once(
    "lib/game/ludo_engine.dart",
    "    _voiceRuntimeEngine = this;\n",
    "",
    "_matchGeneration += 1;",
)
replace_once(
    "lib/services/voice_dice_controller.dart",
    "        _engine = engine ?? LudoEngine.voiceRuntimeEngine,\n",
    "        _engine = engine,\n",
    "_engine = engine,",
)

# 2) Rank all N-best ASR hypotheses instead of accepting the first parseable
# alternative. Ambiguous partials wait for a final result; clear measured
# confidence can still select a lower-ranked but much stronger hypothesis.
replace_once(
    "lib/services/voice_dice_controller.dart",
    """@immutable\nclass DiceVoiceParseResult {\n  const DiceVoiceParseResult({\n    required this.value,\n    required this.confidence,\n    required this.strongContext,\n  });\n\n  final int value;\n  final double confidence;\n  final bool strongContext;\n}\n""",
    """@immutable\nclass DiceVoiceParseResult {\n  const DiceVoiceParseResult({\n    required this.value,\n    required this.confidence,\n    required this.strongContext,\n  });\n\n  final int value;\n  final double confidence;\n  final bool strongContext;\n}\n\n@immutable\nclass _RankedDiceVoiceCandidate {\n  const _RankedDiceVoiceCandidate({\n    required this.result,\n    required this.rank,\n    required this.measuredConfidence,\n  });\n\n  final DiceVoiceParseResult result;\n  final int rank;\n  final double? measuredConfidence;\n\n  // Provider order is useful evidence, but measured acoustic confidence must be\n  // able to overtake it when the provider's first hypothesis is weak.\n  double get score => result.confidence - rank * .012;\n}\n""",
    "class _RankedDiceVoiceCandidate",
)
replace_once(
    "lib/services/voice_dice_controller.dart",
    """  static bool _isHighPrecisionDiceOnlyPhrase(List<String> tokens) =>\n      tokens.isNotEmpty && tokens.every(_highPrecisionAliases.contains);\n\n  static DiceVoiceParseResult? parse(\n""",
    """  static bool _isHighPrecisionDiceOnlyPhrase(List<String> tokens) =>\n      tokens.isNotEmpty && tokens.every(_highPrecisionAliases.contains);\n\n  static DiceVoiceParseResult? selectBestHypothesis(\n    List<String> hypotheses, {\n    List<double?>? recognitionConfidences,\n    required bool isFinal,\n  }) {\n    final ranked = <_RankedDiceVoiceCandidate>[];\n\n    for (var i = 0; i < hypotheses.length; i++) {\n      final heard = hypotheses[i].trim();\n      if (heard.isEmpty) continue;\n      final measured = recognitionConfidences != null &&\n              i < recognitionConfidences.length\n          ? recognitionConfidences[i]\n          : null;\n      final candidate = parse(\n        heard,\n        recognitionConfidence: measured,\n      );\n      if (candidate == null) continue;\n      if (!isFinal &&\n          !candidate.strongContext &&\n          !isFastPartialCommand(heard)) {\n        continue;\n      }\n      ranked.add(\n        _RankedDiceVoiceCandidate(\n          result: candidate,\n          rank: i,\n          measuredConfidence: measured,\n        ),\n      );\n    }\n\n    if (ranked.isEmpty) return null;\n    ranked.sort((a, b) {\n      final scoreOrder = b.score.compareTo(a.score);\n      return scoreOrder != 0 ? scoreOrder : a.rank.compareTo(b.rank);\n    });\n\n    final best = ranked.first;\n    _RankedDiceVoiceCandidate? strongestConflict;\n    for (final candidate in ranked.skip(1)) {\n      if (candidate.result.value != best.result.value) {\n        strongestConflict = candidate;\n        break;\n      }\n    }\n\n    if (strongestConflict != null) {\n      final gap = best.score - strongestConflict.score;\n      final bothMeasured = best.measuredConfidence != null &&\n          strongestConflict.measuredConfidence != null;\n\n      // Partial callbacks frequently have no confidence array. If their N-best\n      // list disagrees on the dice value, waiting for the final callback is much\n      // safer than committing a potentially wrong roll.\n      if (!isFinal && (!bothMeasured || gap < .08)) return null;\n\n      // Final callbacks may rely on provider ordering when confidence is absent,\n      // but two acoustically measured values that are effectively tied are still\n      // too ambiguous for a deterministic game input.\n      if (isFinal && bothMeasured && gap < .035) return null;\n    }\n\n    return best.result;\n  }\n\n  static DiceVoiceParseResult? parse(\n""",
    "selectBestHypothesis(",
)
replace_once(
    "lib/services/voice_dice_controller.dart",
    """    final finalResult = event['final'] == true;\n    final confidenceValues = event['confidences'];\n    DiceVoiceParseResult? parsed;\n    for (var i = 0; i < rawTexts.length; i++) {\n      final item = rawTexts[i];\n      if (item is! String) continue;\n      final heard = item.trim();\n      if (heard.isEmpty) continue;\n      final candidate = DiceVoiceIntentParser.parse(\n        heard,\n        recognitionConfidence: _confidenceAt(confidenceValues, i),\n      );\n      if (candidate == null) continue;\n      if (!finalResult && !candidate.strongContext && !DiceVoiceIntentParser.isFastPartialCommand(heard)) continue;\n      parsed = candidate;\n      break;\n    }\n    if (parsed == null) return;\n""",
    """    final finalResult = event['final'] == true;\n    final confidenceValues = event['confidences'];\n    final hypotheses = <String>[];\n    final confidences = <double?>[];\n    for (var i = 0; i < rawTexts.length; i++) {\n      final item = rawTexts[i];\n      if (item is! String) continue;\n      final heard = item.trim();\n      if (heard.isEmpty) continue;\n      hypotheses.add(heard);\n      confidences.add(_confidenceAt(confidenceValues, i));\n    }\n    final parsed = DiceVoiceIntentParser.selectBestHypothesis(\n      hypotheses,\n      recognitionConfidences: confidences,\n      isFinal: finalResult,\n    );\n    if (parsed == null) return;\n""",
    "DiceVoiceIntentParser.selectBestHypothesis(",
)

# 3) Android 13 and older cannot use Android 14's automatic language switch.
# Adapt only after actual speech produced repeated NO_MATCH events; silent
# timeouts never rotate locale. This preserves Hindi-first behavior while giving
# English/Hinglish a deterministic recovery path without a second recognizer.
replace_once(
    "android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt",
    "    private var preferOnDeviceAfterProviderFailure = false\n",
    "    private var preferOnDeviceAfterProviderFailure = false\n    private var legacySystemLocaleIndex = 0\n",
    "legacySystemLocaleIndex",
)
replace_once(
    "android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt",
    """    ): RecognitionListener =\n        object : RecognitionListener {\n            override fun onReadyForSpeech(params: Bundle?) {\n""",
    """    ): RecognitionListener =\n        object : RecognitionListener {\n            private var heardSpeech = false\n\n            override fun onReadyForSpeech(params: Bundle?) {\n""",
    "private var heardSpeech = false",
)
replace_once(
    "android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt",
    """            override fun onBeginningOfSpeech() {\n                if (!isCurrentSession(objectEpoch, sessionEpoch, binding)) return\n                cancelReadyWatchdog()\n""",
    """            override fun onBeginningOfSpeech() {\n                if (!isCurrentSession(objectEpoch, sessionEpoch, binding)) return\n                heardSpeech = true\n                cancelReadyWatchdog()\n""",
    "heardSpeech = true\n                cancelReadyWatchdog()",
)
replace_once(
    "android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt",
    """                if (error == SpeechRecognizer.ERROR_NO_MATCH ||\n                    error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT\n                ) {\n                    consecutiveNoMatch += 1\n                    if (usingOnDeviceRecognizer &&\n""",
    """                if (error == SpeechRecognizer.ERROR_NO_MATCH ||\n                    error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT\n                ) {\n                    consecutiveNoMatch += 1\n\n                    if (!usingOnDeviceRecognizer &&\n                        error == SpeechRecognizer.ERROR_NO_MATCH &&\n                        heardSpeech &&\n                        Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&\n                        consecutiveNoMatch >= LEGACY_LOCALE_ROTATION_THRESHOLD\n                    ) {\n                        legacySystemLocaleIndex =\n                            (legacySystemLocaleIndex + 1) % LEGACY_SYSTEM_LOCALES.size\n                        consecutiveNoMatch = 0\n                        emit(\n                            mapOf(\n                                \"type\" to \"error\",\n                                \"recoverable\" to true,\n                                \"message\" to \"Voice language model adapted automatically.\",\n                            ),\n                        )\n                        scheduleRestart(LEGACY_LOCALE_RETRY_MS)\n                        return\n                    }\n\n                    if (usingOnDeviceRecognizer &&\n""",
    "LEGACY_LOCALE_ROTATION_THRESHOLD",
)
replace_once(
    "android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt",
    """            override fun onPartialResults(partialResults: Bundle?) {\n                if (!isCurrentSession(objectEpoch, sessionEpoch, binding)) return\n\n                consecutiveNoMatch = 0\n""",
    """            override fun onPartialResults(partialResults: Bundle?) {\n                if (!isCurrentSession(objectEpoch, sessionEpoch, binding)) return\n\n                heardSpeech = true\n                consecutiveNoMatch = 0\n""",
    "heardSpeech = true\n                consecutiveNoMatch = 0",
)
replace_once(
    "android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt",
    """    private fun buildRecognizerIntent(): Intent =\n        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {\n""",
    """    private fun activeRecognitionLocale(): String =\n        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||\n            usingOnDeviceRecognizer\n        ) {\n            HINDI_LOCALE\n        } else {\n            LEGACY_SYSTEM_LOCALES[legacySystemLocaleIndex % LEGACY_SYSTEM_LOCALES.size]\n        }\n\n    private fun buildRecognizerIntent(): Intent =\n        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {\n""",
    "activeRecognitionLocale()",
)
replace_once(
    "android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt",
    "            putExtra(RecognizerIntent.EXTRA_LANGUAGE, HINDI_LOCALE)\n",
    "            putExtra(RecognizerIntent.EXTRA_LANGUAGE, activeRecognitionLocale())\n",
    "EXTRA_LANGUAGE, activeRecognitionLocale()",
)
replace_once(
    "android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt",
    """        private const val ON_DEVICE_NO_MATCH_FALLBACK_THRESHOLD = 2\n\n        private const val LANGUAGE_SWITCH_ACTIVE_MS = 2_500\n""",
    """        private const val ON_DEVICE_NO_MATCH_FALLBACK_THRESHOLD = 2\n        private const val LEGACY_LOCALE_ROTATION_THRESHOLD = 2\n\n        private const val LANGUAGE_SWITCH_ACTIVE_MS = 2_500\n""",
    "LEGACY_LOCALE_ROTATION_THRESHOLD = 2",
)
replace_once(
    "android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt",
    "        private val VOICE_LOCALES = listOf(\"hi-IN\", \"en-IN\", \"en-US\")\n",
    "        private val VOICE_LOCALES = listOf(\"hi-IN\", \"en-IN\", \"en-US\")\n        private val LEGACY_SYSTEM_LOCALES = listOf(\"hi-IN\", \"en-IN\")\n",
    "LEGACY_SYSTEM_LOCALES = listOf",
)
replace_once(
    "android/app/src/main/kotlin/com/aaris/voiceludomasti/MainActivity.kt",
    """        private const val ON_DEVICE_FAILOVER_RESTART_MS = 55L\n        private const val STUCK_RESTART_MS = 70L\n""",
    """        private const val ON_DEVICE_FAILOVER_RESTART_MS = 55L\n        private const val LEGACY_LOCALE_RETRY_MS = 55L\n        private const val STUCK_RESTART_MS = 70L\n""",
    "LEGACY_LOCALE_RETRY_MS = 55L",
)

# 4) Version the architecture upgrade.
replace_once(
    "pubspec.yaml",
    "version: 1.4.3+15\n",
    "version: 1.5.0+16\n",
    "version: 1.5.0+16",
)

# 5) Add behavioral tests for N-best arbitration and source-level global-state
# invariant. These run in the normal Flutter suite.
test_path = Path("test/voice_candidate_fusion_test.dart")
test_content = r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_ludo_masti/services/voice_dice_controller.dart';

void main() {
  group('N-best dice hypothesis arbitration', () {
    test('same-value partial alternatives commit immediately', () {
      final parsed = DiceVoiceIntentParser.selectBestHypothesis(
        const ['छक्का', 'छका', 'six'],
        recognitionConfidences: const [null, null, null],
        isFinal: false,
      );
      expect(parsed?.value, 6);
    });

    test('conflicting unmeasured partial waits for final result', () {
      final parsed = DiceVoiceIntentParser.selectBestHypothesis(
        const ['six', 'five'],
        recognitionConfidences: const [null, null],
        isFinal: false,
      );
      expect(parsed, isNull);
    });

    test('clear acoustic confidence can overtake provider rank', () {
      final parsed = DiceVoiceIntentParser.selectBestHypothesis(
        const ['five', 'six'],
        recognitionConfidences: const [.31, .96],
        isFinal: true,
      );
      expect(parsed?.value, 6);
    });

    test('near-tied measured final values fail closed', () {
      final parsed = DiceVoiceIntentParser.selectBestHypothesis(
        const ['six', 'five'],
        recognitionConfidences: const [.81, .80],
        isFinal: true,
      );
      expect(parsed, isNull);
    });
  });

  test('Ludo engine no longer exposes a mutable global voice engine bridge', () {
    final source = File('lib/game/ludo_engine.dart').readAsStringSync();
    expect(source, isNot(contains('_voiceRuntimeEngine')));
    expect(source, isNot(contains('voiceRuntimeEngine')));
  });
}
'''
if not test_path.exists() or test_path.read_text(encoding="utf-8") != test_content:
    test_path.write_text(test_content, encoding="utf-8")
    print(f"wrote {test_path}")
else:
    print(f"already current {test_path}")

print("final voice architecture patch complete")
