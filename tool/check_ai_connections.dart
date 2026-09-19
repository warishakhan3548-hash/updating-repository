// Dependency-free checks for credential persistence and model selection.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/domain/ai_configuration.dart';
import '../lib/domain/ai_discovered_model.dart';
import '../lib/services/ai_connection_store.dart';

var checks = 0;
void check(bool condition, String label) {
  checks++;
  if (!condition) throw StateError(label);
}

Future<void> main() async {
  final disk = <String, String>{};
  var writes = 0;
  var failWrite = false;
  final store = AiConnectionStore(
    read: (key) async => disk[key],
    write: (key, value) async {
      writes++;
      if (failWrite) {
        failWrite = false;
        throw StateError('storage failed');
      }
      await Future<void>.delayed(Duration.zero);
      disk[key] = value;
    },
  );
  const gemini = AiConfiguration(
    model: 'future-gemini',
    key: 'key-a',
    localBrainEnabled: true,
    streamingEnabled: false,
    jsonModeEnabled: false,
    responseTimeoutSeconds: 120,
  );
  const openai = AiConfiguration(
    provider: 'OpenAI',
    model: 'future-chat',
    key: 'key-b',
    autoSelectModel: true,
    localBrainEnabled: true,
  );
  disk[AiConnectionStore.configurationKey] = jsonEncode(gemini.toJson());
  await store.save(openai);
  final restored = await store.forProvider('Gemini');
  check(
    restored?.key == 'key-a' && restored?.model == 'future-gemini',
    'Legacy connection migrated into profile',
  );
  check(
    restored?.streamingEnabled == false &&
        restored?.jsonModeEnabled == false &&
        restored?.responseTimeoutSeconds == 120,
    'Migration and provider restoration preserve advanced capabilities',
  );
  check((await store.load()).provider == 'OpenAI', 'New provider active');
  await store.save(restored!);
  check(
    (await store.forProvider('OpenAI'))?.key == 'key-b',
    'Second key restored independently',
  );
  check(
    (await store.forProvider('OpenAI'))?.autoSelectModel == true,
    'Auto preference retained',
  );
  check(
    await store.forProvider('Groq') == null,
    'Other provider never receives a key',
  );
  check(
    (await store.forProvider('Gemini'))?.localBrainEnabled == true,
    'Local route preserved',
  );
  await store.forgetActiveKey();
  check((await store.load()).key.isEmpty, 'Active key removed');
  check(
    (await store.forProvider('Gemini'))?.key.isEmpty == true,
    'Removed key cannot return from profile',
  );
  check((await store.load()).localBrainEnabled, 'Forget preserves local route');
  final withoutKey = await store.load();
  check(
    !withoutKey.streamingEnabled &&
        !withoutKey.useJsonMode &&
        withoutKey.responseTimeout.inSeconds == 120,
    'Forget preserves streaming, JSON and timeout settings',
  );
  check(
    (await store.forProvider('OpenAI'))?.key == 'key-b',
    'Forget preserves other provider',
  );
  await store.save(openai);
  final save = store.save(gemini);
  final remove = store.forgetActiveKey();
  await Future.wait([save, remove]);
  check(
    (await store.load()).provider == 'Gemini' &&
        (await store.load()).key.isEmpty,
    'Queued removal uses latest active connection',
  );
  await Future.wait([store.save(openai), store.setLocalBrainEnabled(false)]);
  final active = await store.load();
  check(
    active.provider == 'OpenAI' &&
        active.key == 'key-b' &&
        !active.localBrainEnabled,
    'Local toggle cannot overwrite a new provider',
  );
  failWrite = true;
  var rejected = false;
  try {
    await store.save(gemini);
  } catch (_) {
    rejected = true;
  }
  check(rejected, 'Secure write failure reported');
  await store.save(gemini);
  check(
    (await store.load()).key == 'key-a',
    'Failed write does not poison later saves',
  );
  disk[AiConnectionStore.configurationKey] = '{"key":"broken-secret';
  await store.save(openai);
  check(
    (await store.load()).key == 'key-b',
    'New connection repairs corrupt storage',
  );
  try {
    AiConfiguration.fromStored('{"key":"sensitive');
  } catch (error) {
    check(
      !error.toString().contains('sensitive'),
      'Decode errors never echo secret',
    );
  }
  final models = AiDiscoveredModel.parse({
    'data': [
      {'id': 'next-unknown'},
      {
        'id': 'next-mini',
        'capabilities': {'completion_chat': true},
      },
      {'id': 'next-embedding'},
      {'id': 'unavailable', 'active': false},
      {
        'id': 'future-image',
        'architecture': {
          'input_modalities': ['text', 'image'],
          'output_modalities': ['text'],
        },
      },
    ],
  }, openai);
  check(models.length == 3, 'Only compatible candidates retained');
  check(
    AiDiscoveredModel.choose(models, 'next-unknown')?.id == 'next-unknown',
    'Saved selection stable',
  );
  check(
    AiDiscoveredModel.choose(models, 'removed')?.id == 'next-mini',
    'Auto replacement comes from catalog',
  );
  check(models.last.vision == true, 'Declared vision retained');
  check(
    !models.first.textConfirmed && models.first.vision == null,
    'Unknown capabilities not invented',
  );
  check(writes > 0, 'Secure persistence exercised');
  stdout.writeln('PASS: $checks connection persistence and selection checks.');
}
