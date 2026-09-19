import 'dart:convert';

import '../domain/ai_configuration.dart';

/// A single queue owns active-connection and provider-profile writes. Callers
/// supply platform secure storage; credentials never enter inventory storage.
class AiConnectionStore {
  AiConnectionStore({
    required Future<String?> Function(String) read,
    required Future<void> Function(String, String) write,
  }) : _read = read,
       _write = write;
  final Future<String?> Function(String) _read;
  final Future<void> Function(String, String) _write;
  static const configurationKey = 'pharmacy.ai.configuration';
  Future<void> _tail = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<AiConfiguration> _active() async =>
      AiConfiguration.fromStored(await _read(configurationKey));
  Future<AiConfiguration> load() => _serialized(_active);

  Future<AiConfiguration?> forProvider(String provider) =>
      _serialized(() async {
        final id = AiProviderDefinition.forId(provider).id;
        AiConfiguration active;
        try {
          active = await _active();
        } on FormatException {
          active = const AiConfiguration();
        }
        if (active.definition.id == id && active.key.isNotEmpty) return active;
        final raw = await _read('pharmacy.ai.profile.$id');
        if (raw == null) return active.definition.id == id ? active : null;
        final saved = AiConfiguration.fromStored(raw);
        if (saved.definition.id != id) return null;
        return saved.copyWith(localBrainEnabled: active.localBrainEnabled);
      });

  Future<void> _persist(AiConfiguration config) async {
    AiConfiguration old;
    try {
      old = await _active();
    } on FormatException {
      old = const AiConfiguration();
    }
    // Migrate the previous single-connection format before switching providers.
    if (old.definition.id != config.definition.id && old.key.isNotEmpty) {
      await _write(
        'pharmacy.ai.profile.${old.definition.id}',
        jsonEncode(old.toJson()),
      );
    }
    await _write(
      'pharmacy.ai.profile.${config.definition.id}',
      jsonEncode(config.toJson()),
    );
    // Scanner and local-route policy retain their existing active-envelope key.
    await _write(configurationKey, jsonEncode(config.toJson()));
  }

  Future<void> save(AiConfiguration config) =>
      _serialized(() => _persist(config));

  Future<void> setLocalBrainEnabled(bool enabled) => _serialized(() async {
    final active = await _active();
    await _persist(active.copyWith(localBrainEnabled: enabled));
  });

  Future<void> forgetActiveKey() => _serialized(() async {
    final active = await _active();
    await _persist(active.copyWith(key: ''));
  });
}
