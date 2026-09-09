import 'package:flutter_test/flutter_test.dart';

import '../lib/data/inventory_database.dart';
import '../lib/domain/medicine.dart';
import '../lib/domain/pharmacy_brain.dart';
import '../lib/state/pharmacy_brain_controller.dart';
import '../lib/state/pharmacy_controller.dart';

Medicine _stock(
  String id,
  String name, {
  String strength = '',
  String batch = '',
  String location = '',
}) => Medicine(
  id: id,
  name: name,
  strength: strength,
  form: 'Tablet',
  batchNumber: batch,
  location: location,
  quantity: 10,
  expiry: DateTime.utc(2027, 6, 30),
);

Future<PharmacyController> _controller(Iterable<Medicine> records) async {
  final controller = PharmacyController(
    MemoryInventoryStorage(
      InventorySnapshot(records: {for (final record in records) record.id: record}),
    ),
    clock: () => DateTime.utc(2026, 9, 9),
    backgroundSearch: false,
  );
  await controller.initialize();
  return controller;
}

void main() {
  test('parser understands English, Hinglish and Hindi removal commands', () {
    final english = PharmacyBrainParser.parse('Delete Dolo 650 medicine');
    final hinglish = PharmacyBrainParser.parse('Dolo 650 delete kar do');
    final hindi = PharmacyBrainParser.parse('डोलो 650 हटा दो');

    expect(english.intent, PharmacyBrainIntent.removeMedicine);
    expect(english.target, 'dolo 650');
    expect(hinglish.intent, PharmacyBrainIntent.removeMedicine);
    expect(hinglish.target, 'dolo 650');
    expect(hindi.intent, PharmacyBrainIntent.removeMedicine);
    expect(hindi.target, 'डोलो 650');
  });

  test('broad delete language is blocked instead of becoming a mutation', () {
    for (final command in [
      'delete all medicines',
      'sab medicines delete kar do',
      'सभी दवा डिलीट करो',
      'expired medicines delete',
    ]) {
      expect(
        PharmacyBrainParser.parse(command).intent,
        PharmacyBrainIntent.blockedBulkRemove,
        reason: command,
      );
    }
  });

  test('fast navigation commands stay deterministic', () {
    expect(
      PharmacyBrainParser.parse('scan medicine').intent,
      PharmacyBrainIntent.scanMedicine,
    );
    expect(
      PharmacyBrainParser.parse('expired medicines').intent,
      PharmacyBrainIntent.openExpired,
    );
    expect(
      PharmacyBrainParser.parse('आज क्या जरूरी है').intent,
      PharmacyBrainIntent.inventoryHealth,
    );
    expect(
      PharmacyBrainParser.parse('database kholo').intent,
      PharmacyBrainIntent.searchMedicine,
      reason: 'Unknown transliteration remains a safe search instead of an invented action.',
    );
    expect(
      PharmacyBrainParser.parse('डेटाबेस खोलो').intent,
      PharmacyBrainIntent.openDatabase,
    );
  });

  test('one strong medicine match resolves without changing inventory', () async {
    final controller = await _controller([
      _stock('drot', 'Drotaverine', strength: '80mg', batch: 'D-1'),
      _stock('cefix', 'Cefixime', strength: '200mg', batch: 'C-1'),
    ]);
    addTearDown(controller.dispose);
    final brain = PharmacyBrainController(controller);
    final beforeRevision = controller.snapshot.revision;

    final outcome = await brain.interpret('Drotaverine 80mg delete kar do');

    expect(outcome.command.intent, PharmacyBrainIntent.removeMedicine);
    expect(outcome.match, PharmacyBrainMatch.exact);
    expect(outcome.exact?.record.id, 'drot');
    expect(controller.snapshot.revision, beforeRevision);
    expect(controller.snapshot.records['drot']!.archived, isFalse);
  });

  test('same medicine in multiple batches is never guessed', () async {
    final controller = await _controller([
      _stock(
        'dolo-a',
        'Dolo',
        strength: '650mg',
        batch: 'A1',
        location: 'Shelf A',
      ),
      _stock(
        'dolo-b',
        'Dolo',
        strength: '650mg',
        batch: 'B2',
        location: 'Shelf B',
      ),
    ]);
    addTearDown(controller.dispose);
    final brain = PharmacyBrainController(controller);

    final outcome = await brain.interpret('remove Dolo 650mg');

    expect(outcome.match, PharmacyBrainMatch.ambiguous);
    expect(outcome.exact, isNull);
    expect(outcome.candidates.map((candidate) => candidate.record.id).toSet(), {
      'dolo-a',
      'dolo-b',
    });
    expect(controller.records.every((medicine) => !medicine.archived), isTrue);
  });

  test('pharmacy pulse is deterministic from inventory facts', () async {
    final expired = _stock('expired', 'Expired One');
    final unknown = Medicine(
      id: 'unknown',
      name: 'Unknown Expiry',
      form: 'Tablet',
      quantity: 0,
    );
    final controller = await _controller([
      Medicine.fromJson({
        ...expired.toJson(),
        'expiry': '2026-09-01',
      }),
      unknown,
    ]);
    addTearDown(controller.dispose);
    final pulse = PharmacyBrainController(controller).pulse();

    expect(pulse.expired, 1);
    expect(pulse.zeroQuantity, 1);
    expect(pulse.unknownExpiry, 1);
    expect(pulse.recommendation, contains('expired'));
  });
}
