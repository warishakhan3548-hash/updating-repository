import 'local_model.dart';

/// The built-in *policy* for Aaris' recommended downloadable fallback brain.
///
/// We intentionally do not embed model weights in the APK and we do not pin a
/// mutable download URL here. At install time the public catalogue resolves the
/// repository to an immutable revision + SHA-256, then LocalAiService performs
/// its existing GGUF inspection, resource checks and activation probes.
const String aarisDefaultModelRepository =
    'tensorblock/Qwen2.5-0.5B-Instruct-GGUF';

/// Keep the default in the owner's requested light-phone band. These are wire
/// bytes, not working-memory estimates; runtime admission remains authoritative.
const int aarisDefaultModelMinBytes = 300 * 1000 * 1000;
const int aarisDefaultModelMaxBytes = 420 * 1000 * 1000;
const int aarisDefaultModelTargetBytes = 398 * 1000 * 1000;

const String aarisDefaultModelDisplayName = 'Aaris Default Local AI';
const String aarisDefaultModelDownloadHint = '400 MB';

/// Prefer a balanced 4-bit quant, then progressively smaller compatible files.
/// The runtime still has the final say: catalogue presence never equals support.
const List<String> _preferredQuantizations = <String>[
  'q4_k_m',
  'q4_k_s',
  'q3_k_m',
  'q3_k_l',
  'q4_0',
  'q3_k_s',
];

LocalModelFile? chooseAarisDefaultModel(Iterable<LocalModelFile> input) {
  final candidates = input
      .where(
        (file) =>
            file.repository == aarisDefaultModelRepository &&
            file.bytes >= aarisDefaultModelMinBytes &&
            file.bytes <= aarisDefaultModelMaxBytes &&
            isSingleGguf(file.filename),
      )
      .toList(growable: false);
  if (candidates.isEmpty) return null;

  int quantizationRank(LocalModelFile file) {
    final name = file.filename.toLowerCase();
    for (var index = 0; index < _preferredQuantizations.length; index++) {
      if (name.contains(_preferredQuantizations[index])) return index;
    }
    return _preferredQuantizations.length + 1;
  }

  final sorted = List<LocalModelFile>.of(candidates)
    ..sort((a, b) {
      final quality = quantizationRank(a).compareTo(quantizationRank(b));
      if (quality != 0) return quality;
      final aDistance = (a.bytes - aarisDefaultModelTargetBytes).abs();
      final bDistance = (b.bytes - aarisDefaultModelTargetBytes).abs();
      final distance = aDistance.compareTo(bDistance);
      if (distance != 0) return distance;
      final size = a.bytes.compareTo(b.bytes);
      return size != 0 ? size : a.filename.compareTo(b.filename);
    });
  return sorted.first;
}
