// No native model is loaded. Checks activation-probe policy, not AI accuracy.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/domain/local_model_checks.dart';
import '../lib/services/local_scan_probe.dart';

Future<void> main() async {
  var passed = 0;
  void check(bool value, String message) {
    if (!value) throw StateError(message);
    passed++;
  }

  Future<Object?> failure(Future<Object?> work) =>
      work.then<Object?>((_) => null, onError: (Object error) => error);

  for (final error in [
    TimeoutException('optional extraction timed out'),
    StateError('native inference failed after model load'),
    const FormatException('Local prompt exceeds context'),
  ]) {
    var calls = 0;
    final verified = await probeLocalScanExtraction(
      generate: (_, __, ___) async {
        calls++;
        throw error;
      },
      checkCurrent: () {},
    );
    check(
      !verified && calls == 1,
      'Optional inference failure becomes one advisory failure, not activation failure',
    );
  }

  var index = 0;
  check(
    await probeLocalScanExtraction(
      generate: (system, source, budget) async {
        final probe = localSetupChecks[index++];
        check(
          system == localSetupPrompt && budget == 180,
          'Existing extraction instructions and limits remain',
        );
        check(
          jsonDecode(source)['SOURCE'] == probe.source,
          'Existing setup evidence remains',
        );
        return jsonEncode({
          'brand': probe.brand,
          'salt': probe.salt,
          'strength': probe.strength,
          'form': probe.form,
          'expiry': probe.expiry,
        });
      },
      checkCurrent: () {},
    ),
    'All existing extraction probes still verify a successful model',
  );
  check(
    index == localSetupChecks.length,
    'No skipped quality probe on success',
  );

  for (final raw in ['', 'hello', '{"brand":"invented"}']) {
    check(
      !await probeLocalScanExtraction(
        generate: (_, __, ___) async => raw,
        checkCurrent: () {},
      ),
      'Empty/malformed/incorrect extraction remains unverified',
    );
  }

  for (final throwDuringGeneration in [false, true]) {
    var cancelled = false;
    final cancellation = StateError('owner cancelled activation');
    final error = await failure(
      probeLocalScanExtraction(
        generate: (_, __, ___) async {
          cancelled = true;
          if (throwDuringGeneration) throw StateError('native cancelled');
          return '{}';
        },
        checkCurrent: () {
          if (cancelled) throw cancellation;
        },
      ),
    );
    check(
      identical(error, cancellation),
      'Stop cannot turn into load readiness',
    );
  }

  var generated = false;
  final cancelled = StateError('already cancelled');
  final error = await failure(
    probeLocalScanExtraction(
      generate: (_, __, ___) async {
        generated = true;
        return '{}';
      },
      checkCurrent: () => throw cancelled,
    ),
  );
  check(
    identical(error, cancelled) && !generated,
    'Cancelled activation never starts another generation',
  );
  stdout.writeln('Local scan setup policy: $passed focused checks passed.');
}
