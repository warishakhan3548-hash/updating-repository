import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/pharmacy_brain.dart';
import '../domain/search.dart';
import 'pharmacy_controller.dart';

enum PharmacyBrainMatch { none, exact, ambiguous }

class PharmacyBrainCandidate {
  const PharmacyBrainCandidate({required this.record, required this.hit});

  final Medicine record;
  final SearchHit hit;
}

class PharmacyBrainPulse {
  const PharmacyBrainPulse({
    required this.expired,
    required this.shortExpiry,
    required this.monthExpiry,
    required this.sold,
    required this.zeroQuantity,
    required this.unknownExpiry,
  });

  final int expired;
  final int shortExpiry;
  final int monthExpiry;
  final int sold;
  final int zeroQuantity;
  final int unknownExpiry;

  int get urgent => expired + shortExpiry;

  String get recommendation {
    if (expired > 0) {
      return '$expired expired stock ${expired == 1 ? 'entry needs' : 'entries need'} attention first.';
    }
    if (shortExpiry > 0) {
      return '$shortExpiry short-expiry ${shortExpiry == 1 ? 'entry is' : 'entries are'} the next priority.';
    }
    if (zeroQuantity > 0 || sold > 0) {
      return '${zeroQuantity + sold} stock ${zeroQuantity + sold == 1 ? 'entry may need' : 'entries may need'} reorder review.';
    }
    if (unknownExpiry > 0) {
      return '$unknownExpiry active ${unknownExpiry == 1 ? 'entry has' : 'entries have'} no recorded expiry. Verify the physical pack when practical.';
    }
    return 'No urgent expiry or stock-out signal is recorded right now.';
  }
}

class PharmacyBrainOutcome {
  const PharmacyBrainOutcome({
    required this.command,
    required this.baseRevision,
    this.match = PharmacyBrainMatch.none,
    this.candidates = const [],
    this.message = '',
    this.pulse,
  });

  final PharmacyBrainCommand command;
  final int baseRevision;
  final PharmacyBrainMatch match;
  final List<PharmacyBrainCandidate> candidates;
  final String message;
  final PharmacyBrainPulse? pulse;

  PharmacyBrainCandidate? get exact =>
      match == PharmacyBrainMatch.exact && candidates.isNotEmpty
      ? candidates.first
      : null;
}

/// Coordinates fast command understanding with the existing fuzzy inventory
/// search. It has no write capability: all mutations stay behind the existing
/// PharmacyController transaction/review paths.
class PharmacyBrainController {
  PharmacyBrainController(this.controller);

  final PharmacyController controller;

  PharmacyBrainPulse pulse() {
    var expired = 0;
    var shortExpiry = 0;
    var monthExpiry = 0;
    var sold = 0;
    var zeroQuantity = 0;
    var unknownExpiry = 0;
    for (final medicine in controller.records) {
      if (medicine.archived) continue;
      if (medicine.sold) {
        sold++;
        continue;
      }
      if (medicine.quantity == 0) zeroQuantity++;
      if (medicine.expiry == null) unknownExpiry++;
      final status = statusOf(
        medicine,
        controller.settings,
        controller.today,
      ).status;
      if (status == StockStatus.expired) {
        expired++;
      } else if (status == StockStatus.shortExpiry) {
        shortExpiry++;
      } else if (status == StockStatus.monthExpiry) {
        monthExpiry++;
      }
    }
    return PharmacyBrainPulse(
      expired: expired,
      shortExpiry: shortExpiry,
      monthExpiry: monthExpiry,
      sold: sold,
      zeroQuantity: zeroQuantity,
      unknownExpiry: unknownExpiry,
    );
  }

  Future<PharmacyBrainOutcome> interpret(String raw) async {
    final command = PharmacyBrainParser.parse(raw);
    if (command.intent == PharmacyBrainIntent.inventoryHealth) {
      final health = pulse();
      return PharmacyBrainOutcome(
        command: command,
        baseRevision: controller.snapshot.revision,
        pulse: health,
        message: health.recommendation,
      );
    }
    if (!command.needsMedicine) {
      return PharmacyBrainOutcome(
        command: command,
        baseRevision: controller.snapshot.revision,
        message: _routeMessage(command.intent),
      );
    }
    if (command.target.trim().isEmpty) {
      return PharmacyBrainOutcome(
        command: command,
        baseRevision: controller.snapshot.revision,
        message: 'Tell me the medicine name, strength, barcode, batch or location.',
      );
    }

    // Bind a resolution to one inventory revision. If inventory changes while
    // the background search is running, retry once instead of returning a stale
    // medicine ID to a later action.
    for (var attempt = 0; attempt < 2; attempt++) {
      final revision = controller.snapshot.revision;
      final hits = await controller.search(command.target, SearchScope.all);
      if (revision != controller.snapshot.revision) continue;
      return _rank(command, revision, hits);
    }
    return PharmacyBrainOutcome(
      command: command,
      baseRevision: controller.snapshot.revision,
      message: 'Inventory changed while I was matching that medicine. Try the command once more.',
    );
  }

  PharmacyBrainOutcome _rank(
    PharmacyBrainCommand command,
    int revision,
    List<SearchHit> hits,
  ) {
    final candidates = <PharmacyBrainCandidate>[];
    for (final hit in hits.take(6)) {
      final record = controller.snapshot.records[hit.id];
      if (record == null || record.archived) continue;
      candidates.add(PharmacyBrainCandidate(record: record, hit: hit));
    }
    if (candidates.isEmpty) {
      return PharmacyBrainOutcome(
        command: command,
        baseRevision: revision,
        message: 'No inventory medicine matched “${command.target}”. I did not guess a stock entry.',
      );
    }

    final top = candidates.first;
    if (top.hit.score < .72) {
      return PharmacyBrainOutcome(
        command: command,
        baseRevision: revision,
        match: PharmacyBrainMatch.ambiguous,
        candidates: candidates.take(4).toList(growable: false),
        message: 'I found only low-confidence possibilities. Choose the exact medicine before any action.',
      );
    }

    final close = candidates
        .where(
          (candidate) =>
              candidate.hit.score >= .82 &&
              top.hit.score - candidate.hit.score <= .055,
        )
        .toList();
    final sameIdentity = candidates
        .where((candidate) => candidate.record.identity == top.record.identity)
        .toList();
    final uniqueStrong =
        top.hit.score >= .90 && close.length == 1 && sameIdentity.length == 1;
    if (uniqueStrong) {
      return PharmacyBrainOutcome(
        command: command,
        baseRevision: revision,
        match: PharmacyBrainMatch.exact,
        candidates: [top],
        message: 'Matched ${top.record.title} with ${top.hit.confidence.toLowerCase()} confidence.',
      );
    }

    return PharmacyBrainOutcome(
      command: command,
      baseRevision: revision,
      match: PharmacyBrainMatch.ambiguous,
      candidates: candidates.take(5).toList(growable: false),
      message: sameIdentity.length > 1
          ? 'More than one stock entry matches this medicine. Choose the exact batch/location.'
          : 'More than one medicine is plausible. Choose the exact one; I will not guess.',
    );
  }

  String _routeMessage(PharmacyBrainIntent intent) => switch (intent) {
    PharmacyBrainIntent.addMedicine => 'Opening a new medicine entry.',
    PharmacyBrainIntent.scanMedicine => 'Opening the medicine scanner.',
    PharmacyBrainIntent.openDatabase => 'Opening Add & Remove.',
    PharmacyBrainIntent.openExpired => 'Opening expired medicines.',
    PharmacyBrainIntent.openShortExpiry => 'Opening short-expiry medicines.',
    PharmacyBrainIntent.openMonthExpiry => 'Opening month-expiry medicines.',
    PharmacyBrainIntent.openSold => 'Opening sold medicines.',
    PharmacyBrainIntent.openActivity => 'Opening pharmacy activity.',
    PharmacyBrainIntent.openProfile => 'Opening profile.',
    PharmacyBrainIntent.openHome => 'Opening Home.',
    PharmacyBrainIntent.openAi => 'Opening the full reviewed AI assistant.',
    PharmacyBrainIntent.blockedBulkRemove =>
      'A broad delete request is never executed from one voice/text command. Choose medicines explicitly so stock cannot be erased by a misunderstanding.',
    PharmacyBrainIntent.unknown =>
      'This request needs the full AI assistant. I will not guess an app action.',
    PharmacyBrainIntent.searchMedicine ||
    PharmacyBrainIntent.editMedicine ||
    PharmacyBrainIntent.removeMedicine ||
    PharmacyBrainIntent.inventoryHealth => '',
  };
}
