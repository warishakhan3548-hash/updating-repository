import 'package:flutter_test/flutter_test.dart';
import 'package:aaris_pharmacy/domain/gguf_metadata.dart';
import 'package:aaris_pharmacy/domain/local_model.dart';
import 'package:aaris_pharmacy/domain/local_model_checks.dart';
import 'package:aaris_pharmacy/domain/model_catalogue.dart';

void main() {
  test('auxiliary imatrix GGUF is never offered as a standalone model', () {
    expect(isSingleGguf('imatrix-qwen3.8-27b.gguf'), isFalse);
    expect(
      modelArtifactLimitation('imatrix-qwen3.8-27b.gguf'),
      contains('not a standalone'),
    );
  });

  test('runtime readiness is a technical non-empty ping only', () {
    expect(passesLocalRuntimeProbe('READY'), isTrue);
    expect(passesLocalRuntimeProbe(' hello '), isTrue);
    expect(passesLocalRuntimeProbe('   '), isFalse);
  });

  test(
    '4 GB phone can attempt 2 GB weights with a low-context smart guard',
    () {
      const gib = 1024 * 1024 * 1024;
      const mib = 1024 * 1024;
      const metadata = GgufMetadata(architecture: 'qwen2', tensorCount: 1);
      final plan = planLocalExecution(
        weightBytes: 2 * gib,
        metadata: metadata,
        totalMemory: 4 * gib,
        availableMemory: 1400 * mib,
        lowMemory: true,
        phone: true,
      );
      expect(plan.contextTokens, inInclusiveRange(512, 2048));
      expect(plan.outputTokens, greaterThan(0));
      expect(plan.memoryWarning, isTrue);
    },
  );

  test('planner can step all the way down to 512 tokens', () {
    const metadata = GgufMetadata(
      architecture: 'llama',
      tensorCount: 1,
      contextLength: 512,
    );
    final plan = planLocalExecution(
      weightBytes: 700 * 1024 * 1024,
      metadata: metadata,
      phone: true,
    );
    expect(plan.contextTokens, 512);
  });
}
