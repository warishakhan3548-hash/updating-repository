import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Widget tests do not have a native secure-storage host. Keep both supported
  // test seams deterministic: the package platform mock covers normal reads,
  // while the method-channel handler also covers any plugin registration that
  // reinstalls the default MethodChannel implementation after test startup.
  TestWidgetsFlutterBinding.ensureInitialized();
  final storage = <String, String>{};
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  Future<Object?> handleSecureStorage(MethodCall call) async {
    final arguments = call.arguments is Map
        ? Map<Object?, Object?>.from(call.arguments as Map)
        : const <Object?, Object?>{};
    final key = arguments['key']?.toString();
    switch (call.method) {
      case 'read':
        return key == null ? null : storage[key];
      case 'write':
        final value = arguments['value']?.toString();
        if (key != null && value != null) storage[key] = value;
        return null;
      case 'delete':
        if (key != null) storage.remove(key);
        return null;
      case 'deleteAll':
        storage.clear();
        return null;
      case 'containsKey':
        return key != null && storage.containsKey(key);
      case 'readAll':
        return Map<String, String>.from(storage);
      default:
        return null;
    }
  }

  void resetSecureStorage() {
    storage.clear();
    FlutterSecureStorage.setMockInitialValues(storage);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handleSecureStorage);
  }

  resetSecureStorage();
  setUp(resetSecureStorage);
  await testMain();
}
