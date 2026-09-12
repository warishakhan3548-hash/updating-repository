import 'package:flutter/foundation.dart';

class AarisDefaultAiService extends ChangeNotifier {
  static final instance = AarisDefaultAiService();

  bool get supported => false;
  bool get busy => false;
  bool get hasDefault => false;
  bool get active => false;
  double? get progress => null;
  String get status =>
      'Aaris Default Local AI needs the installed Android/desktop app.';
  String? get defaultId => null;

  Future<void> initialize() async {}
  Future<bool> ensureActiveIfInstalled() async => false;
  Future<void> installAndActivate() async => throw UnsupportedError(status);
  void cancel() {}
}
