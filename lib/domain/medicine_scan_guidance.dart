import 'medicine_understanding.dart';

enum MedicineScanFocus {
  frontIdentity,
  strength,
  composition,
  dataMatrix,
  lotDates,
  dosageForm,
}

class MedicineScanAdvice {
  const MedicineScanAdvice({
    required this.focus,
    required this.priority,
    required this.message,
  });

  final MedicineScanFocus focus;
  final double priority;
  final String message;
}

/// Chooses the single next view with the highest expected information gain.
///
/// This is intentionally deterministic and offline. It never guesses medicine
/// identity and never changes a draft. It only inspects which safety-critical
/// clues are missing, conflicted or weak, then asks for the view most likely to
/// resolve that uncertainty. One short instruction is returned so the scanner
/// stays simple for the pharmacist.
MedicineScanAdvice? nextBestMedicineScanAdvice(MedicineScanDraft draft) {
  final candidates = <MedicineScanAdvice>[];

  bool weak(
    String key, {
    double minimum = .78,
    bool missingCounts = true,
  }) {
    final field = draft.field(key);
    if (field.conflicted) return true;
    if (field.value.trim().isEmpty) return missingCounts;
    return field.confidence < minimum;
  }

  double conflictBoost(String key) => draft.field(key).conflicted ? .12 : 0;

  if (weak('name', minimum: .84)) {
    candidates.add(
      MedicineScanAdvice(
        focus: MedicineScanFocus.frontIdentity,
        priority: (1.00 + conflictBoost('name')).clamp(0, 1).toDouble(),
        message: 'Show the front clearly with the medicine name and brand.',
      ),
    );
  }

  if (weak('strength', minimum: .82)) {
    candidates.add(
      MedicineScanAdvice(
        focus: MedicineScanFocus.strength,
        priority: (.94 + conflictBoost('strength')).clamp(0, 1).toDouble(),
        message: 'Show the strength clearly, for example 500 mg or 5 mg/ml.',
      ),
    );
  }

  // A conflicted salt is high-risk. A merely absent salt is useful but not
  // mandatory on every branded pack, so absence alone gets a lower priority.
  final salt = draft.field('salt');
  if (salt.conflicted ||
      (salt.value.trim().isNotEmpty && salt.confidence < .80)) {
    candidates.add(
      MedicineScanAdvice(
        focus: MedicineScanFocus.composition,
        priority: (.90 + conflictBoost('salt')).clamp(0, 1).toDouble(),
        message: 'Show the composition or salt side clearly.',
      ),
    );
  } else if (salt.value.trim().isEmpty && draft.overallConfidence < .76) {
    candidates.add(
      const MedicineScanAdvice(
        focus: MedicineScanFocus.composition,
        priority: .66,
        message: 'Show the composition or salt side if it is printed.',
      ),
    );
  }

  final expiryWeak = weak('expiry', minimum: .82);
  final batchWeak = weak('batchNumber', minimum: .78);
  final barcodeWeak = weak('barcode', minimum: .82);

  // GS1 DataMatrix can carry product identity plus batch and expiry in one scan.
  // When several of those clues are missing, it has higher expected information
  // gain than asking for each printed field separately.
  if (barcodeWeak && (expiryWeak || batchWeak)) {
    candidates.add(
      MedicineScanAdvice(
        focus: MedicineScanFocus.dataMatrix,
        priority: expiryWeak && batchWeak ? .92 : .86,
        message: 'Show the square DataMatrix/barcode side clearly.',
      ),
    );
  } else if (barcodeWeak &&
      draft.name.trim().isNotEmpty &&
      draft.overallConfidence < .90) {
    candidates.add(
      const MedicineScanAdvice(
        focus: MedicineScanFocus.dataMatrix,
        priority: .72,
        message: 'For a stronger match, show the DataMatrix/barcode side.',
      ),
    );
  }

  if (draft.field('expiry').conflicted ||
      (draft.expiry.trim().isNotEmpty && draft.field('expiry').confidence < .82)) {
    candidates.add(
      MedicineScanAdvice(
        focus: MedicineScanFocus.lotDates,
        priority: (.93 + conflictBoost('expiry')).clamp(0, 1).toDouble(),
        message: 'Show Batch and EXP/MFG together in one clear view.',
      ),
    );
  } else if (expiryWeak && !barcodeWeak) {
    candidates.add(
      const MedicineScanAdvice(
        focus: MedicineScanFocus.lotDates,
        priority: .79,
        message: 'Show Batch and EXP/MFG together in one clear view.',
      ),
    );
  }

  if (weak('form', minimum: .76) && draft.name.trim().isNotEmpty) {
    candidates.add(
      MedicineScanAdvice(
        focus: MedicineScanFocus.dosageForm,
        priority: (.64 + conflictBoost('form')).clamp(0, 1).toDouble(),
        message: 'Show where Tablet, Capsule, Syrup or the dosage form is printed.',
      ),
    );
  }

  if (candidates.isEmpty) return null;
  candidates.sort((a, b) => b.priority.compareTo(a.priority));
  final best = candidates.first;

  // Do not nag on already coherent packs for weak optional clues.
  if (best.priority < .68 &&
      !draft.needsReview &&
      draft.overallConfidence >= .82) {
    return null;
  }
  return best;
}
