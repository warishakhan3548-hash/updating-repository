import 'dart:convert';

import '../domain/local_ai_protocol.dart';
import '../domain/local_model_checks.dart';

/// Advisory extraction quality after a successful native model load. Generation
/// can fail even when the selected model is usable for an ordinary short chat.
/// Cancellation remains authoritative and is never converted into readiness.
Future<bool> probeLocalScanExtraction({
  required Future<String> Function(String system, String source, int budget)
  generate,
  required void Function() checkCurrent,
  void Function()? onProbe,
}) async {
  for (final probe in localSetupChecks) {
    checkCurrent();
    onProbe?.call();
    String raw;
    try {
      raw = await generate(
        localSetupPrompt,
        jsonEncode({'SOURCE': probe.source}),
        180,
      );
    } catch (_) {
      // The model already passed native load. A long/unsupported extraction
      // task is advisory; a short chat must still be allowed to try that model.
      // Stop/model changes must propagate, including cancellation that caused
      // generate() itself to fail rather than returning a response.
      checkCurrent();
      return false;
    }
    checkCurrent();
    try {
      if (!passesLocalSetup(localJsonObject(raw), probe)) return false;
    } on FormatException {
      return false;
    }
  }
  return true;
}
