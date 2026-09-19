import 'ai_configuration.dart';

/// Nullable capabilities mean the provider did not declare them. A catalog
/// listing is never proof of inference access, quota, JSON or vision support.
class AiDiscoveredModel {
  const AiDiscoveredModel({
    required this.id,
    required this.label,
    this.textConfirmed = false,
    this.vision,
    this.created = 0,
  });
  final String id, label;
  final bool textConfirmed;
  final bool? vision;
  final int created;

  static List<AiDiscoveredModel> parse(
    Object? envelope,
    AiConfiguration config,
  ) {
    final rows = envelope is List
        ? envelope
        : envelope is Map
        ? envelope[config.protocol == AiProviderProtocol.gemini
              ? 'models'
              : 'data']
        : null;
    if (rows is! List)
      throw const FormatException(
        'The provider returned an incompatible model list.',
      );
    final found = <String, AiDiscoveredModel>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final raw =
          row[config.protocol == AiProviderProtocol.gemini ? 'name' : 'id'];
      if (raw is! String) continue;
      final id = config.protocol == AiProviderProtocol.gemini
          ? raw.replaceFirst(RegExp(r'^models/'), '')
          : raw;
      if (!AiConfiguration.validModelId(id)) continue;
      if (config.protocol == AiProviderProtocol.gemini &&
          !RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(id))
        continue;
      if (row['active'] == false ||
          row['archived'] == true ||
          row['deprecated'] == true ||
          const ['retired', 'disabled', 'deprecated'].contains(row['status']))
        continue;
      final shutdown = row['shutdown_date'];
      if (shutdown is String) {
        final date = DateTime.tryParse(shutdown);
        if (date != null && !date.isAfter(DateTime.now().toUtc())) continue;
      }
      final capabilities = row['capabilities'];
      final architecture = row['architecture'];
      final outputs =
          row['output_modalities'] ??
          (architecture is Map ? architecture['output_modalities'] : null);
      final inputs =
          row['input_modalities'] ??
          (architecture is Map ? architecture['input_modalities'] : null);
      final methods = row['supportedGenerationMethods'];
      bool confirmed = false;
      bool? vision;
      if (capabilities is Map) {
        if (capabilities['completion_chat'] == false) continue;
        confirmed = capabilities['completion_chat'] == true;
        if (capabilities['vision'] is bool)
          vision = capabilities['vision'] as bool;
      }
      if (outputs is List && outputs.isNotEmpty) {
        if (!outputs.contains('text')) continue;
        confirmed = true;
      }
      if (inputs is List && inputs.isNotEmpty) {
        if (!inputs.contains('text')) continue;
        vision = inputs.contains('image');
      }
      if (methods is List && !methods.contains('generateContent')) continue;
      if (row['type'] == 'chat') confirmed = true;
      if (const [
        'embedding',
        'embeddings',
        'rerank',
        'image',
        'audio',
        'moderation',
        'transcription',
        'text-to-image',
        'text-to-speech',
      ].contains(row['type']))
        continue;
      // Some catalogs (including Gemini's generateContent list) do not declare
      // output modalities. Exclude known non-chat families without pinning any
      // allowed model version. Unknown/future text models remain testable.
      if (outputs is! List &&
          RegExp(
            r'(^|[/_.-])(embed(ding(s)?)?|rerank(er)?|whisper|tts|transcrib(e|er)|transcription|moderation|realtime|native-audio|imagen|veo|dall-e|sora|image)([/_.-]|$)',
            caseSensitive: false,
          ).hasMatch(id))
        continue;
      final name = row['displayName'] ?? row['display_name'] ?? row['name'];
      final label = name is String && name.trim().isNotEmpty
          ? name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim()
          : id;
      found[id] = AiDiscoveredModel(
        id: id,
        label: label.length <= 160 ? label : label.substring(0, 160),
        textConfirmed: confirmed,
        vision: vision,
        created: row['created'] is int ? row['created'] as int : 0,
      );
    }
    return found.values.toList();
  }

  /// A convenience suggestion, not a benchmark/cost claim. Keep the saved
  /// model whenever possible; never select a different company automatically.
  static AiDiscoveredModel? choose(
    List<AiDiscoveredModel> models,
    String saved,
  ) {
    for (final model in models) {
      if (model.id == saved) return model;
    }
    if (models.isEmpty) return null;
    final ranked = [...models]
      ..sort((a, b) {
        int score(AiDiscoveredModel m) {
          final name = m.id.toLowerCase();
          return (m.textConfirmed ? 10 : 0) +
              (RegExp(r'flash|mini|small|haiku|instant').hasMatch(name)
                  ? 20
                  : 0) -
              (RegExp(r'preview|experimental|(^|-)exp(-|$)').hasMatch(name)
                  ? 40
                  : 0);
        }

        final byScore = score(b).compareTo(score(a));
        if (byScore != 0) return byScore;
        final byDate = b.created.compareTo(a.created);
        return byDate != 0 ? byDate : a.id.compareTo(b.id);
      });
    return ranked.first;
  }
}
