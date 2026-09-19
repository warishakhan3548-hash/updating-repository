import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import '../domain/gguf_metadata.dart';

Future<GgufMetadata> inspectGgufFile(String path) => Isolate.run(() async {
  final file = File(path), reader = await File(path).open();
  try {
    final size = await file.length();
    return inspectGgufPrefix(
      await reader.read(min(size, maxGgufMetadataBytes)),
      fileBytes: size,
    );
  } finally {
    await reader.close();
  }
});
