import 'dart:io';

import '../lib/domain/default_local_model.dart';
import '../lib/domain/local_model.dart';

void main() {
  const revision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const hashA =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const hashB =
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
  const hashC =
      'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

  LocalModelFile file(String name, int bytes, String hash) => LocalModelFile(
    repository: aarisDefaultModelRepository,
    revision: revision,
    filename: name,
    bytes: bytes,
    sha256: hash,
    license: 'apache-2.0',
  );

  final selected = chooseAarisDefaultModel([
    file('Qwen2.5-0.5B-Instruct-Q3_K_M.gguf', 355000000, hashA),
    file('Qwen2.5-0.5B-Instruct-Q4_K_M.gguf', 398000000, hashB),
    file('Qwen2.5-0.5B-Instruct-Q2_K.gguf', 299000000, hashC),
  ]);
  assert(selected != null);
  assert(selected!.filename.contains('Q4_K_M'));

  final outsideBand = chooseAarisDefaultModel([
    file('Qwen2.5-0.5B-Instruct-Q8_0.gguf', 531000000, hashA),
  ]);
  assert(outsideBand == null);

  final wrongRepository = chooseAarisDefaultModel([
    const LocalModelFile(
      repository: 'someone/other-model',
      revision: revision,
      filename: 'Qwen2.5-0.5B-Instruct-Q4_K_M.gguf',
      bytes: 398000000,
      sha256: hashA,
      license: 'apache-2.0',
    ),
  ]);
  assert(wrongRepository == null);

  stdout.writeln('Aaris default local AI policy checks passed.');
}
