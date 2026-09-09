import 'package:flutter/foundation.dart';
import '../domain/local_ai_protocol.dart';
import '../domain/local_model.dart';
import '../domain/model_catalogue.dart';
import '../domain/medicine_understanding.dart';

class LocalAiService extends ChangeNotifier {
  static final instance = LocalAiService();
  bool get supported => false;
  bool get hasSelection => false;
  bool get busy => false;
  bool get transferring => false;
  bool get scannerEnabled => false;
  double? get progress => null;
  String get status =>
      'Local native models need the installed Android/desktop app.';
  String get activeLabel => '';
  String? get activeId => null;
  List<InstalledLocalModel> get installed => const [];
  Future<void> initialize() async {}
  Future<ModelSearchPage> searchPage(
    String query, {
    ModelSort sort = ModelSort.popular,
    Uri? cursor,
  }) async => ModelSearchPage(const []);
  Future<ModelRepositoryFiles> repositoryFiles(String input) async =>
      throw UnsupportedError(status);
  Future<List<String>> search(String query) async => [];
  Future<List<LocalModelFile>> files(String repository) async => [];
  Future<void> download(LocalModelFile file) async =>
      throw UnsupportedError(status);
  Future<void> importModel() async => throw UnsupportedError(status);
  Future<void> activate(String id) async => throw UnsupportedError(status);
  Future<void> deactivate() async {}
  Future<void> remove(String id) async {}
  Future<void> setScannerEnabled(bool value) async {}
  void cancelTransfer() {}
  void cancelRequest() {}
  Future<String> ask(
    LocalInventoryContext context,
    String instruction, {
    String conversation = '',
  }) async => throw UnsupportedError(status);
  Future<MedicineScanDraft> understand(MedicineScanDraft draft) async => draft;
}
