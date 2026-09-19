import 'brain_analytics.dart';
import 'brain_operations.dart';
import 'inventory.dart';
import 'medicine_brief.dart';

enum AppSection { home, stock, ai, calculator, profile }

enum AppBrainAction {
  unknown,
  safetyBlocked,
  navigate,
  search,
  addMedicine,
  scanMedicine,
  editMedicine,
  setQuantity,
  receiveStock,
  relocateMedicine,
  removeMedicine,
  restoreMedicine,
  removedStockReview,
  markSold,
  recordSale,
  reorderReview,
  undoLast,
  inventorySummary,
  analyticsBrief,
  attentionBrief,
  nextAttentionTask,
  bulkRemoveBlocked,
}

enum AppBrainSafetyReason {
  negatedMutation,
  deferredMutation,
  compoundMutation,
}

extension AppBrainSafetyReasonMessage on AppBrainSafetyReason {
  String get message => switch (this) {
    AppBrainSafetyReason.negatedMutation => 'Nothing changed. Aaris understood a negative instruction (“don’t / mat / nahi”), so no inventory action or navigation was started. Say the positive action only when you actually want a reviewed change.',
    AppBrainSafetyReason.deferredMutation => 'Nothing changed. That inventory instruction is conditional or scheduled for later. Aaris never executes “if / when / kal / later” as if it means now; open the action again when it is actually due.',
    AppBrainSafetyReason.compoundMutation => 'Nothing changed. That sentence contains more than one inventory-changing operation. Aaris will not execute only the first half of a compound command. Run one reviewed operation at a time so each exact stock target and before/after state is confirmed.',
  };
}

class AppBrainIntent {
  const AppBrainIntent({
    required this.action,
    this.section,
    this.scope = SearchScope.all,
    this.query = '',
    this.quantity,
    this.analyticsRequest,
    this.briefFocus,
    this.locationPatch,
    this.removalReason,
    this.safetyReason,
    this.openExact = false,
    this.confidence = 0,
  });

  final AppBrainAction action;
  final AppSection? section;
  final SearchScope scope;
  final String query;
  final int? quantity;
  final BrainAnalyticsRequest? analyticsRequest;
  final MedicineBriefFocus? briefFocus;
  final StockLocationPatch? locationPatch;
  final RemovalReasonHint? removalReason;
  final AppBrainSafetyReason? safetyReason;
  final bool openExact;
  final double confidence;

  bool get needsMedicineTarget =>
      briefFocus != null ||
      switch (action) {
        AppBrainAction.editMedicine ||
        AppBrainAction.setQuantity ||
        AppBrainAction.receiveStock ||
        AppBrainAction.relocateMedicine ||
        AppBrainAction.removeMedicine ||
        AppBrainAction.restoreMedicine ||
        AppBrainAction.markSold ||
        AppBrainAction.recordSale => true,
        _ => false,
      };

  bool get destructive => switch (action) {
    AppBrainAction.setQuantity ||
    AppBrainAction.removeMedicine ||
    AppBrainAction.markSold ||
    AppBrainAction.recordSale ||
    AppBrainAction.bulkRemoveBlocked => true,
    _ => false,
  };

  bool get mutatesInventory => switch (action) {
    AppBrainAction.setQuantity ||
    AppBrainAction.receiveStock ||
    AppBrainAction.relocateMedicine ||
    AppBrainAction.removeMedicine ||
    AppBrainAction.restoreMedicine ||
    AppBrainAction.markSold ||
    AppBrainAction.recordSale ||
    AppBrainAction.undoLast => true,
    _ => false,
  };

  /// Whether a command with no medicine words may reuse the session's exact
  /// active-stock context. This never authorizes fuzzy or guessed targeting.
  /// The executor still requires an exact live ID/fingerprint and all existing
  /// review/confirmation gates remain mandatory for mutations.
  bool get canUseImplicitExactContext =>
      briefFocus != null ||
      switch (action) {
        AppBrainAction.editMedicine ||
        AppBrainAction.setQuantity ||
        AppBrainAction.receiveStock ||
        AppBrainAction.relocateMedicine ||
        AppBrainAction.removeMedicine ||
        AppBrainAction.markSold ||
        AppBrainAction.recordSale => true,
        _ => false,
      };
}

AppBrainIntent parseAppBrainIntent(String raw) {
  final text = _normalized(raw);
  if (text.isEmpty) {
    return const AppBrainIntent(action: AppBrainAction.unknown);
  }

  // Natural-language writes pass through an intent firewall before routing.
  // Negated, conditional/future and multi-write commands must never be
  // reinterpreted as an immediate mutation merely because they contain a
  // familiar verb. This guard is deterministic and runs before target search.
  final safetyReason = _brainSafetyBlock(raw, text);
  if (safetyReason != null) {
    return AppBrainIntent(
      action: AppBrainAction.safetyBlocked,
      safetyReason: safetyReason,
      confidence: 1,
    );
  }

  if (_containsAny(text, const [
    'undo',
    'undo last',
    'last change undo',
    'wapas karo',
    'wapas kar do',
    'pichla change wapas',
    'पिछला बदलाव वापस',
    'वापस करो',
  ])) {
    return const AppBrainIntent(
      action: AppBrainAction.undoLast,
      confidence: .99,
    );
  }

  // Natural-language control must never become an unreviewed bulk destructive
  // path. Single-stock removal is supported; Delete All remains behind the
  // dedicated protected owner flow.
  if (_isBulkRemoval(text)) {
    return const AppBrainIntent(
      action: AppBrainAction.bulkRemoveBlocked,
      confidence: 1,
    );
  }

  // Read-only analytics questions are recognized before the write-side sale
  // vocabulary. This prevents phrases such as "aaj ki bikri kitni" from ever
  // being interpreted as a stock mutation. TrackingStats remains the
  // deterministic source of truth; Brain now renders that projection directly.
  final analytics = parseBrainAnalyticsRequest(raw);
  if (analytics != null) {
    return AppBrainIntent(
      action: AppBrainAction.analyticsBrief,
      analyticsRequest: analytics,
      confidence: .99,
    );
  }

  // "Restore" is overloaded in a pharmacy app: it can mean a full data backup
  // or one removed stock row. Backup wording is routed to the protected profile
  // surface first, so a command can never reinterpret disaster recovery as a
  // medicine mutation.
  if (_containsAny(text, _backupRestoreTerms)) {
    return const AppBrainIntent(
      action: AppBrainAction.navigate,
      section: AppSection.profile,
      confidence: .99,
    );
  }

  final removedStock = _removedStockIntent(raw, text);
  if (removedStock != null) return removedStock;

  // Explicit stock correction / receiving commands are parsed before generic
  // "add stock" and "edit" vocabulary. The parser accepts an exact quantity
  // only when one command-shaped quantity can be isolated; medicine strengths
  // therefore remain search evidence instead of becoming stock counts.
  final stockAdjustment = _stockAdjustmentIntent(raw);
  if (stockAdjustment != null) return stockAdjustment;

  // Physical stock relocation is a narrow deterministic write command. It is
  // recognized before generic remove/edit language so "location hata do"
  // clears only location facts and can never become a medicine deletion.
  final locationUpdate = parseStockLocationCommand(raw);
  if (locationUpdate != null) {
    return AppBrainIntent(
      action: AppBrainAction.relocateMedicine,
      query: locationUpdate.query,
      locationPatch: locationUpdate.patch,
      confidence: .99,
    );
  }

  // Explicit write intent wins over category words such as "expired". A
  // bounded reason hint improves target resolution but never skips the final
  // destructive confirmation in the UI. A direct "delete X" command uses the
  // neutral Correction audit reason so it can land on the one protected final
  // preview instead of forcing a second reason-picker interaction.
  if (_containsAny(text, _removeTerms)) {
    final reason = detectRemovalReason(raw);
    final directDelete = _startsWithAnyPhrase(text, const ['delete', 'डिलीट']);
    return AppBrainIntent(
      action: AppBrainAction.removeMedicine,
      query: _extractMedicineQuery(raw, [
        ..._removeTerms,
        if (reason != null) ...reason.commandTerms,
      ]),
      removalReason:
          reason ?? (directDelete ? RemovalReasonHint.correction : null),
      confidence: .98,
    );
  }

  if (_containsAny(text, _soldTerms)) {
    final query = _extractMedicineQuery(raw, _soldTerms);
    // Ambiguous status wording such as "stock khatam" remains informational
    // when it has no target. Only an explicit whole-stock mutation phrase may
    // reuse exact session context; the UI still requires confirmation.
    if (query.isEmpty) {
      final explicitContextMutation = _containsAny(text, const [
        'mark sold',
        'sold mark',
        'poora stock bik gaya',
        'pura stock bik gaya',
        'पूरा स्टॉक बिक गया',
      ]);
      if (explicitContextMutation) {
        return const AppBrainIntent(
          action: AppBrainAction.markSold,
          confidence: .96,
        );
      }
      return const AppBrainIntent(
        action: AppBrainAction.search,
        scope: SearchScope.sold,
        confidence: .94,
      );
    }
    return AppBrainIntent(
      action: AppBrainAction.markSold,
      query: query,
      confidence: .98,
    );
  }

  // Common pharmacist imperatives such as "Dolo 5 units sell" or
  // "Crocin dispense" feed the existing reviewed sale/FEFO UI. Read-side FEFO
  // questions are explicitly excluded so "which batch should I dispense first"
  // can never become a sale mutation.
  final imperativeSale = _imperativeSaleIntent(raw, text);
  if (imperativeSale != null) return imperativeSale;

  if (_containsAny(text, _saleTerms)) {
    final saleInput = _extractExplicitSaleQuantity(raw);
    return AppBrainIntent(
      action: AppBrainAction.recordSale,
      query: _extractMedicineQuery(saleInput.remainingText, _saleTerms),
      quantity: saleInput.quantity,
      confidence: .96,
    );
  }

  final fieldEdit = _fieldEditIntent(raw, text);
  if (fieldEdit != null) return fieldEdit;

  if (_containsAny(text, _editTerms)) {
    return AppBrainIntent(
      action: AppBrainAction.editMedicine,
      query: _extractMedicineQuery(raw, _editTerms),
      confidence: .95,
    );
  }

  if (_containsAny(text, _nextTaskTerms)) {
    return const AppBrainIntent(
      action: AppBrainAction.nextAttentionTask,
      confidence: .99,
    );
  }

  if (_containsAny(text, _attentionTerms)) {
    return const AppBrainIntent(
      action: AppBrainAction.attentionBrief,
      confidence: .98,
    );
  }

  if (_containsAny(text, _scanTerms)) {
    // The Brain launches the existing scanner/import review path. This action
    // only navigates into that authoritative flow; it never writes inventory.
    return const AppBrainIntent(
      action: AppBrainAction.scanMedicine,
      confidence: .97,
    );
  }

  // Category lists (short-expiry / month-expiry / expired / sold) win before
  // targeted read questions so "short expiry" never becomes a medicine named
  // "short". This preserves the dashboard projections as authoritative filters.
  final listIntent = _listIntent(text);
  if (listIntent != null) return listIntent;

  final operational = _operationalReadIntent(raw, text);
  if (operational != null) return operational;

  if (_containsAny(text, const [
    'stock summary',
    'inventory summary',
    'stock kitna',
    'kitna stock',
    'total medicines',
    'total medicine',
    'inventory batao',
    'stock batao',
    'कितना स्टॉक',
    'कुल मेडिसिन',
    'स्टॉक बताओ',
  ])) {
    return const AppBrainIntent(
      action: AppBrainAction.inventorySummary,
      confidence: .98,
    );
  }

  // Preserve the complete typed medicine payload for the Editor bridge. This
  // turns "Add Cefixime 200mg" into a prefilled draft instead of throwing away
  // Cefixime/200mg and opening a blank editor.
  if (_containsAny(text, _addTerms)) {
    return AppBrainIntent(
      action: AppBrainAction.addMedicine,
      query: _extractMedicineQuery(raw, _addTerms),
      confidence: .98,
    );
  }

  if (_containsAny(text, const [
    'order now',
    'reorder list',
    'reorder review',
    'what to order',
    'what should i order',
    'low stock review',
    'low stock order',
    'purchase order',
    'kya order karna hai',
    'order kya karna hai',
    'reorder dikhao',
    'ऑर्डर क्या करना है',
    'रीऑर्डर',
    'परचेज ऑर्डर',
  ])) {
    return const AppBrainIntent(
      action: AppBrainAction.reorderReview,
      confidence: .98,
    );
  }

  final section = _sectionIntent(text);
  if (section != null) {
    return AppBrainIntent(
      action: AppBrainAction.navigate,
      section: section,
      confidence: .97,
    );
  }

  // "Open Cefixime" is an explicit local deep-link request, not an AI chat
  // prompt. Section/category opens were consumed above, so anything left here
  // is a medicine target and may safely use the exact-match fast path.
  if (_containsAny(text, _openMedicineTerms)) {
    final query = _extractMedicineQuery(raw, _openMedicineTerms);
    if (query.isNotEmpty) {
      return AppBrainIntent(
        action: AppBrainAction.search,
        query: query,
        openExact: true,
        confidence: .99,
      );
    }
  }

  if (_containsAny(text, _searchTerms)) {
    return AppBrainIntent(
      action: AppBrainAction.search,
      query: _extractMedicineQuery(raw, _searchTerms),
      confidence: .94,
    );
  }

  // Batch/barcode/location identifiers are common enough that a pharmacist
  // should not need to say the word "search" first. Location questions were
  // already consumed by the operational intent above.
  if (_containsAny(text, _identifierTerms)) {
    final query = _extractMedicineQuery(raw, _identifierTerms);
    return AppBrainIntent(
      action: AppBrainAction.search,
      query: query,
      confidence: query.isEmpty ? .74 : .96,
    );
  }

  // A short non-question such as "Dolo 650" is treated as an intentional stock
  // lookup. Questions/advice/reasoning remain routed to the reviewed AI layer.
  if (_looksLikeDirectLookup(raw, text)) {
    return AppBrainIntent(
      action: AppBrainAction.search,
      query: raw.trim(),
      confidence: .78,
    );
  }

  return const AppBrainIntent(action: AppBrainAction.unknown);
}

AppBrainIntent? _removedStockIntent(String raw, String text) {
  if (_containsAny(text, _restoreTerms)) {
    final query = _extractMedicineQuery(raw, [
      ..._restoreTerms,
      ..._removedListTerms,
    ]);
    if (query.isEmpty) {
      return const AppBrainIntent(
        action: AppBrainAction.removedStockReview,
        confidence: .99,
      );
    }
    return AppBrainIntent(
      action: AppBrainAction.restoreMedicine,
      query: query,
      confidence: .99,
    );
  }
  if (_containsAny(text, _removedListTerms)) {
    return const AppBrainIntent(
      action: AppBrainAction.removedStockReview,
      confidence: .98,
    );
  }
  return null;
}

AppBrainIntent? _stockAdjustmentIntent(String raw) {
  final exact = _extractStockAdjustment(
    raw,
    _setQuantityPatterns,
    allowZero: true,
  );
  if (exact != null) {
    return AppBrainIntent(
      action: AppBrainAction.setQuantity,
      query: _extractMedicineQuery(exact.remainingText, const <String>[]),
      quantity: exact.quantity,
      confidence: .99,
    );
  }

  final received = _extractStockAdjustment(
    raw,
    _receiveStockPatterns,
    allowZero: false,
  );
  if (received != null) {
    return AppBrainIntent(
      action: AppBrainAction.receiveStock,
      query: _extractMedicineQuery(received.remainingText, const <String>[]),
      quantity: received.quantity,
      confidence: .99,
    );
  }
  return null;
}

AppBrainIntent? _imperativeSaleIntent(String raw, String text) {
  if (!_containsAny(text, _imperativeSaleTerms) ||
      raw.contains('?') ||
      _containsAny(text, _saleReadGuardTerms)) {
    return null;
  }
  final saleInput = _extractExplicitSaleQuantity(raw);
  final query = _extractMedicineQuery(
    saleInput.remainingText,
    _imperativeSaleTerms,
  );
  // A quantity-qualified imperative such as "5 units sell" is
  // sufficiently explicit to continue on exact session context. A bare
  // targetless "sell" remains unknown instead of becoming a mutation.
  if (query.isEmpty && saleInput.quantity == null) return null;
  return AppBrainIntent(
    action: AppBrainAction.recordSale,
    query: query,
    quantity: saleInput.quantity,
    confidence: saleInput.quantity == null ? .93 : .98,
  );
}

AppBrainIntent? _fieldEditIntent(String raw, String text) {
  if (!_looksLikeFieldEdit(text)) return null;
  final query = _extractMedicineQuery(raw, [
    ..._editorFieldEditVerbs,
    ..._editorFieldTerms,
  ]);
  return AppBrainIntent(
    action: AppBrainAction.editMedicine,
    query: query,
    confidence: query.isEmpty ? .90 : .99,
  );
}

bool _looksLikeFieldEdit(String text) =>
    _containsAny(text, _editorFieldEditVerbs) &&
    _containsAny(text, _editorFieldTerms);

AppBrainIntent? _operationalReadIntent(String raw, String text) {
  final matches = <MedicineBriefFocus, List<String>>{
    if (_containsAny(text, _stockLookupTerms))
      MedicineBriefFocus.stock: _stockLookupTerms,
    if (_containsAny(text, _expiryLookupTerms))
      MedicineBriefFocus.expiry: _expiryLookupTerms,
    if (_containsAny(text, _locationTerms))
      MedicineBriefFocus.location: _locationTerms,
    if (_containsAny(text, _fefoTerms)) MedicineBriefFocus.fefo: _fefoTerms,
  };
  if (matches.isEmpty) return null;

  // Multiple operational questions about the same medicine are answered from
  // one coherent read-only snapshot instead of independently parsing each
  // clause. All matched vocabulary is stripped before fuzzy target resolution.
  final terms = <String>[for (final values in matches.values) ...values];
  final query = _extractMedicineQuery(raw, terms);
  if (matches.length == 1 &&
      matches.containsKey(MedicineBriefFocus.stock) &&
      query.isEmpty) {
    return const AppBrainIntent(
      action: AppBrainAction.inventorySummary,
      confidence: .98,
    );
  }

  return AppBrainIntent(
    action: AppBrainAction.search,
    query: query,
    briefFocus: matches.length == 1
        ? matches.keys.single
        : MedicineBriefFocus.summary,
    confidence: query.isEmpty ? .76 : .99,
  );
}

AppBrainIntent? _listIntent(String text) {
  final wantsList = _containsAny(text, const [
    'show',
    'list',
    'open',
    'dikhao',
    'dikhana',
    'batao',
    'दिखाओ',
    'लिस्ट',
    'खोलो',
  ]);

  if (_containsAny(text, const [
    'expired',
    'expiry ho gayi',
    'expire ho gayi',
    'एक्सपायर्ड',
  ])) {
    return AppBrainIntent(
      action: AppBrainAction.search,
      scope: SearchScope.expired,
      confidence: wantsList ? .99 : .96,
    );
  }
  if (_containsAny(text, const [
    'sold medicines',
    'sold medicine',
    'sold list',
    'biki medicine',
    'बिकी मेडिसिन',
  ])) {
    return const AppBrainIntent(
      action: AppBrainAction.search,
      scope: SearchScope.sold,
      confidence: .99,
    );
  }
  if (_containsAny(text, const [
    'short expiry',
    'short-expiry',
    'days left',
    'jaldi expire',
    'जल्दी एक्सपायर',
  ])) {
    return const AppBrainIntent(
      action: AppBrainAction.search,
      scope: SearchScope.shortExpiry,
      confidence: .96,
    );
  }
  if (_containsAny(text, const [
    'month expiry',
    'months left',
    'month left',
    'महीने में एक्सपायर',
  ])) {
    return const AppBrainIntent(
      action: AppBrainAction.search,
      scope: SearchScope.monthExpiry,
      confidence: .96,
    );
  }
  return null;
}

AppSection? _sectionIntent(String text) {
  if (_containsAny(text, const [
    'go home',
    'open home',
    'home kholo',
    'home chalo',
    'होम खोलो',
  ])) {
    return AppSection.home;
  }
  if (_containsAny(text, const [
    'open stock',
    'medicine database',
    'open database',
    'stock kholo',
    'database kholo',
    'मेडिसिन डेटाबेस',
    'स्टॉक खोलो',
  ])) {
    return AppSection.stock;
  }
  if (_containsAny(text, const [
    'open ai',
    'ai kholo',
    'brain kholo',
    'aaris brain',
    'एआई खोलो',
  ])) {
    return AppSection.ai;
  }
  if (_containsAny(text, const [
    'open calculator',
    'calculator kholo',
    'stats kholo',
    'statistics',
    'कैलकुलेटर खोलो',
  ])) {
    return AppSection.calculator;
  }
  if (_containsAny(text, const [
    'open profile',
    'profile kholo',
    'settings kholo',
    'प्रोफाइल खोलो',
  ])) {
    return AppSection.profile;
  }
  return null;
}

bool isAppBrainContextReference(String raw) {
  final text = _normalized(raw);
  if (text.isEmpty) return false;
  if (_contextReferencePhrases.contains(text) ||
      _contextReferenceCores.contains(text)) {
    return true;
  }

  // Human commands often retain harmless grammar after the action words
  // are removed: “us medicine me”, “woh wali”, “that stock entry”. Strip
  // only a closed list of grammatical wrapper tokens, then require the
  // remainder to be a known deictic reference. A medicine name such as
  // “Usman” can therefore never become implicit context by prefix match.
  final reduced = text
      .split(' ')
      .where(
        (token) => token.isNotEmpty && !_contextReferenceGlue.contains(token),
      )
      .join(' ');
  return _contextReferenceCores.contains(reduced) ||
      _contextReferencePhrases.contains(reduced);
}

AppBrainSafetyReason? _brainSafetyBlock(String raw, String text) {
  final families = <String>{};
  final locationMutation = _looksLikeLocationMutation(text);

  // “location hata do” is a location clear, not a medicine removal.
  // Explicit delete/remove/archive wording still counts as a separate
  // family, so “delete Dolo and set location…” is rejected as compound.
  if (_containsAny(text, _removeTerms) &&
      (!locationMutation ||
          _containsAny(text, _unambiguousRemoveSafetyTerms))) {
    families.add('remove');
  }
  if (_containsAny(text, _soldTerms)) families.add('sold');
  if (_containsAny(text, _imperativeSaleTerms) ||
      _containsAny(text, _saleTerms)) {
    families.add('sale');
  }
  if (_containsAny(text, _editTerms) || _looksLikeFieldEdit(text)) {
    families.add('edit');
  }
  if (_containsAny(text, _restoreTerms)) families.add('restore');
  if (_containsAny(text, _undoSafetyTerms)) families.add('undo');
  if (_setQuantityPatterns.any((pattern) => pattern.hasMatch(raw))) {
    families.add('set-quantity');
  }
  if (_receiveStockPatterns.any((pattern) => pattern.hasMatch(raw))) {
    families.add('receive-stock');
  }
  if (locationMutation) families.add('relocate');

  if (families.isEmpty) return null;

  if (_containsAny(text, _negativeWriteSafetyTerms)) {
    return AppBrainSafetyReason.negatedMutation;
  }
  if (_containsAny(text, _deferredWriteSafetyTerms) ||
      _looksLikeScheduledMutation(raw)) {
    return AppBrainSafetyReason.deferredMutation;
  }

  // A single mutation family can still contain multiple targets/actions:
  // “delete Dolo and Crocin”, “sell A and sell B”, or two commands separated
  // by a semicolon/newline. Never let query cleanup collapse such a sentence
  // into one fuzzy medicine target. Editor-only field/location wording is not
  // included here because those paths open a human review surface rather than
  // committing a stock-state transition.
  if (_hasMultiTargetOrChainedStockMutation(raw, text, families)) {
    return AppBrainSafetyReason.compoundMutation;
  }

  final sequencedOrChoice = _containsAny(text, _sequenceOrChoiceSafetyTerms);

  // “undo last remove” describes the previous operation, not two new
  // writes. Only collapse this shape when Undo leads the sentence and
  // there is no explicit sequence/choice connector.
  if (families.contains('undo') &&
      families.length > 1 &&
      !sequencedOrChoice &&
      _startsWithAnyPhrase(text, _undoSafetyTerms)) {
    families
      ..clear()
      ..add('undo');
  }

  // Existing “remove … sold out / stock finished” language intentionally
  // routes to whole-stock SOLD. Preserve that single lifecycle intent,
  // but never collapse an explicit “delete OR mark sold” choice.
  if (families.contains('remove') &&
      families.contains('sold') &&
      !sequencedOrChoice &&
      detectRemovalReason(raw) == RemovalReasonHint.soldOut) {
    families.remove('remove');
  }

  if (families.length > 1) {
    return AppBrainSafetyReason.compoundMutation;
  }
  return null;
}

const _multiTargetSensitiveMutationFamilies = <String>{
  'remove',
  'sold',
  'sale',
  'restore',
  'undo',
  'set-quantity',
  'receive-stock',
};

bool _hasMultiTargetOrChainedStockMutation(
  String raw,
  String text,
  Set<String> families,
) {
  if (!families.any(_multiTargetSensitiveMutationFamilies.contains)) {
    return false;
  }

  // “backup and restore” belongs to the dedicated data-recovery surface and
  // does not mean restore an archived medicine row. Preserve that navigation.
  if (_containsAny(text, _backupRestoreTerms)) return false;

  // Explicit hard separators are always treated as multiple instructions for a
  // stock-changing sentence. Commas are intentionally excluded because they can
  // legitimately occur inside medicine/composition names.
  if (RegExp(r'[;\r\n]').hasMatch(raw)) return true;

  if (_containsAny(text, _sequenceOrChoiceSafetyTerms)) return true;

  // Plain conjunctions were historically harmless when different write families
  // were present because the family-count guard caught them. They are dangerous
  // for repeated/same-family writes, where target cleanup could otherwise turn
  // “A and B” into one fuzzy lookup.
  return _containsAny(text, const <String>['and', 'aur', 'और']);
}

bool _looksLikeLocationMutation(String text) =>
    _containsAny(text, _locationSafetyNouns) &&
    _containsAny(text, _locationSafetyVerbs);

bool _looksLikeScheduledMutation(String raw) =>
    RegExp(
      r'\b(?:at\s+)?(?:[01]?\d|2[0-3]):[0-5]\d(?:\s*(?:a\.?m\.?|p\.?m\.?))?\b',
      caseSensitive: false,
    ).hasMatch(raw) ||
    RegExp(
      r'\b(?:[1-9]|1[0-2])\s*(?:a\.?m\.?|p\.?m\.?)\b',
      caseSensitive: false,
    ).hasMatch(raw) ||
    RegExp(
      r'\b(?:on\s+)?(?:\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?|\d{4}-\d{2}-\d{2})\b',
      caseSensitive: false,
    ).hasMatch(raw) ||
    RegExp(
      r'\b(?:in\s+)?\d+\s*(?:minutes?|hours?|days?|weeks?|months?)\b',
      caseSensitive: false,
    ).hasMatch(raw) ||
    RegExp(
      r'(?:[0-9०-९]+\s*बजे|[0-9०-९]+\s*(?:ghante|din|hafte|mahine)\s*baad)',
      caseSensitive: false,
      unicode: true,
    ).hasMatch(raw);

bool _startsWithAnyPhrase(String text, List<String> phrases) =>
    phrases.any((phrase) {
      final needle = _normalized(phrase);
      return text == needle || text.startsWith('$needle ');
    });

const _contextReferenceCores = <String>{
  'this',
  'it',
  'that',
  'same',
  'selected',
  'last',
  'previous',
  'isko',
  'ise',
  'iska',
  'iski',
  'issi',
  'us',
  'usko',
  'usse',
  'uska',
  'uski',
  'usi',
  'ye',
  'yeh',
  'yahi',
  'woh',
  'wo',
  'vo',
  'voh',
  'wahi',
  'wohi',
  'इसको',
  'इसे',
  'इसका',
  'इसकी',
  'इसी',
  'उस',
  'उसको',
  'उससे',
  'उसका',
  'उसकी',
  'उसी',
  'ये',
  'यह',
  'यही',
  'वो',
  'वह',
  'वही',
};

const _contextReferencePhrases = <String>{
  'this one',
  'this medicine',
  'that one',
  'that medicine',
  'same one',
  'same medicine',
  'the same',
  'the same one',
  'selected one',
  'selected medicine',
  'last one',
  'last medicine',
  'previous one',
  'previous medicine',
  'jo select kiya',
  'jo select kiya tha',
  'जिसे सिलेक्ट किया',
  'जिसे सेलेक्ट किया',
};

const _contextReferenceGlue = <String>{
  'the',
  'one',
  'medicine',
  'medicines',
  'stock',
  'entry',
  'batch',
  'dawa',
  'dawai',
  'ko',
  'me',
  'mein',
  'par',
  'pe',
  'wali',
  'waali',
  'wala',
  'waala',
  'hi',
  'karna',
  'karni',
  'karne',
  'karo',
  'kar',
  'do',
  'hai',
  'hain',
  'tha',
  'thi',
  'दवा',
  'मेडिसिन',
  'स्टॉक',
  'एंट्री',
  'बैच',
  'को',
  'में',
  'पर',
  'पे',
  'वाली',
  'वाला',
  'ही',
  'करना',
  'करनी',
  'करने',
  'करो',
  'कर',
  'दो',
  'है',
  'हैं',
  'था',
  'थी',
};

const _negativeWriteSafetyTerms = <String>[
  'do not',
  'don t',
  'dont',
  'never',
  'avoid',
  'refrain',
  'refrain from',
  'leave unchanged',
  'leave it unchanged',
  'not',
  'mat',
  'mat karo',
  'mat karna',
  'nahi',
  'nahin',
  'na karo',
  'na karna',
  'मत',
  'मत करो',
  'मत करना',
  'नहीं',
  'ना करो',
  'ना करना',
];

const _deferredWriteSafetyTerms = <String>[
  'what if',
  'if',
  'only if',
  'when',
  'whenever',
  'later',
  'tomorrow',
  'next week',
  'next month',
  'next year',
  'after some time',
  'after lunch',
  'after dinner',
  'after closing',
  'before closing',
  'this evening',
  'tonight',
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
  'shaam',
  'raat',
  'dopahar',
  'subah',
  'शाम',
  'रात',
  'दोपहर',
  'सुबह',
  'schedule for',
  'scheduled for',
  'agar',
  'jab',
  'kal',
  'baad me',
  'baad mein',
  'अगर',
  'जब',
  'कल',
  'बाद में',
  'बाद मे',
];

const _sequenceOrChoiceSafetyTerms = <String>[
  'or',
  'either',
  'versus',
  'vs',
  'ya',
  'या',
  'then',
  'and then',
  'phir',
  'fir',
  'uske baad',
  'फिर',
  'और फिर',
  'उसके बाद',
];

const _undoSafetyTerms = <String>[
  'undo',
  'undo last',
  'last change undo',
  'wapas karo',
  'wapas kar do',
  'pichla change wapas',
  'पिछला बदलाव वापस',
  'वापस करो',
];

const _unambiguousRemoveSafetyTerms = <String>[
  'delete',
  'remove',
  'archive',
  'डिलीट',
  'रिमूव',
];

const _locationSafetyNouns = <String>[
  'location',
  'shelf',
  'rack',
  'लोकेशन',
  'शेल्फ',
  'रैक',
  'जगह',
];

const _locationSafetyVerbs = <String>[
  'set',
  'move',
  'shift',
  'rakh do',
  'rakho',
  'clear',
  'hatao',
  'hata do',
  'सेट',
  'मूव',
  'शिफ्ट',
  'रख दो',
  'रखो',
  'खाली',
  'हटाओ',
  'हटा दो',
];

String _normalized(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f]+', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _containsAny(String text, List<String> phrases) => phrases.any((phrase) {
  final needle = _normalized(phrase);
  if (needle.isEmpty) return false;
  return text == needle ||
      text.startsWith('$needle ') ||
      text.endsWith(' $needle') ||
      text.contains(' $needle ');
});

bool _isBulkRemoval(String text) {
  if (!_containsAny(text, _removeTerms)) return false;
  return _containsAny(text, const [
    'delete all',
    'remove all',
    'all medicine',
    'all medicines',
    'all stock',
    'whole inventory',
    'entire inventory',
    'sab medicine',
    'sab medicines',
    'saari medicine',
    'sari medicine',
    'sara stock',
    'poora stock delete',
    'pura stock delete',
    'सब मेडिसिन',
    'सारी मेडिसिन',
    'पूरा स्टॉक',
    'सारा स्टॉक',
    'सब डिलीट',
  ]);
}

bool _looksLikeDirectLookup(String raw, String text) {
  if (raw.contains('?') || text.isEmpty || raw.trim().length > 80) return false;
  final tokens = text.split(' ');
  if (tokens.length > 7) return false;
  if (_containsAny(text, const [
    'what',
    'which',
    'why',
    'how',
    'should',
    'can i',
    'recommend',
    'compare',
    'explain',
    'analyse',
    'analyze',
    'advice',
    'plan',
    'pattern',
    'before food',
    'after food',
    'dose',
    'dosage',
    'use for',
    'kya',
    'kyun',
    'kaise',
    'batao kya',
    'क्या',
    'क्यों',
    'कैसे',
    'खुराक',
  ])) {
    return false;
  }
  if (const {
    'medicine',
    'medicines',
    'stock',
    'database',
    'dawai',
    'दवा',
    'मेडिसिन',
  }.contains(text)) {
    return false;
  }
  return RegExp(r'[a-z0-9\u0900-\u097f]', unicode: true).hasMatch(text);
}

class _ExplicitSaleQuantity {
  const _ExplicitSaleQuantity(this.remainingText, this.quantity);

  final String remainingText;
  final int? quantity;
}

class _ExplicitStockAdjustment {
  const _ExplicitStockAdjustment(this.remainingText, this.quantity);

  final String remainingText;
  final int quantity;
}

class _StockAdjustmentMatch {
  const _StockAdjustmentMatch(this.start, this.end, this.quantityText);

  final int start, end;
  final String quantityText;
}

_ExplicitSaleQuantity _extractExplicitSaleQuantity(String raw) {
  final expression = RegExp(
    r'(?:(?:qty|quantity)\s*[:=]?\s*([0-9०-९]{1,9})|([0-9०-९]{1,9})\s*(?:units?|pcs?|pieces?|यूनिट(?:्स)?))',
    caseSensitive: false,
    unicode: true,
  );
  final matches = expression.allMatches(raw).toList();
  // Multiple quantity statements are ambiguous. Preserve the original command
  // and fall back to the reviewed editor instead of guessing which number wins.
  if (matches.length != 1) return _ExplicitSaleQuantity(raw, null);
  final match = matches.single;
  final digits = _asciiDigits(match.group(1) ?? match.group(2) ?? '');
  final quantity = int.tryParse(digits);
  if (quantity == null || quantity < 1 || quantity > _maxCommandQuantity) {
    return _ExplicitSaleQuantity(raw, null);
  }
  final remaining = raw.replaceRange(match.start, match.end, ' ');
  return _ExplicitSaleQuantity(remaining, quantity);
}

_ExplicitStockAdjustment? _extractStockAdjustment(
  String raw,
  List<RegExp> patterns, {
  required bool allowZero,
}) {
  final found = <_StockAdjustmentMatch>[];
  final seen = <String>{};
  for (final pattern in patterns) {
    for (final match in pattern.allMatches(raw)) {
      final quantityText = match.group(1) ?? '';
      final key = '${match.start}:${match.end}:$quantityText';
      if (seen.add(key)) {
        found.add(_StockAdjustmentMatch(match.start, match.end, quantityText));
      }
    }
  }
  if (found.length != 1) return null;
  final match = found.single;
  final quantity = int.tryParse(_asciiDigits(match.quantityText));
  final minimum = allowZero ? 0 : 1;
  if (quantity == null ||
      quantity < minimum ||
      quantity > _maxCommandQuantity) {
    return null;
  }
  final remaining = raw.replaceRange(match.start, match.end, ' ');
  return _ExplicitStockAdjustment(remaining, quantity);
}

String _asciiDigits(String value) {
  const devanagari = '०१२३४५६७८९';
  final output = StringBuffer();
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final index = devanagari.indexOf(char);
    output.write(index < 0 ? char : index.toString());
  }
  return output.toString();
}

String _extractMedicineQuery(String raw, List<String> terms) {
  var value = raw;
  final ordered = [...terms]..sort((a, b) => b.length.compareTo(a.length));
  for (final term in ordered) {
    value = _stripWholePhrase(value, term);
  }
  for (final filler in _fillers) {
    value = _stripWholePhrase(value, filler);
  }
  return value
      .replaceAll(RegExp(r'[^A-Za-z0-9\u0900-\u097f+./-]+', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _stripWholePhrase(String source, String phrase) {
  final words = phrase
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .map(RegExp.escape)
      .join(r'\s+');
  if (words.isEmpty) return source;
  final expression = RegExp(
    '(^|[^A-Za-z0-9\\u0900-\\u097f])($words)(?=\$|[^A-Za-z0-9\\u0900-\\u097f])',
    caseSensitive: false,
    unicode: true,
  );
  return source.replaceAllMapped(
    expression,
    (match) => '${match.group(1) ?? ''} ',
  );
}

const _maxCommandQuantity = 100000000;

final _setQuantityPatterns = <RegExp>[
  RegExp(
    r'(?:set|correct)\s+(?:stock\s+)?(?:qty|quantity)\s*(?:to\s*)?[:=]?\s*([0-9०-९]{1,9})(?:\s*units?)?',
    caseSensitive: false,
    unicode: true,
  ),
  RegExp(
    r'(?:stock\s+)?(?:qty|quantity)\s*(?:to\s*)?[:=]?\s*([0-9०-९]{1,9})\s*(?:set|correct|karo|kar do)',
    caseSensitive: false,
    unicode: true,
  ),
  RegExp(
    r'stock\s+(?:set|correct)\s*(?:to\s*)?[:=]?\s*([0-9०-९]{1,9})(?:\s*units?)?',
    caseSensitive: false,
    unicode: true,
  ),
  RegExp(
    r'(?:स्टॉक\s+)?(?:क्वांटिटी|मात्रा)\s*([0-9०-९]{1,9})\s*(?:सेट|करो|कर दो)',
    caseSensitive: false,
    unicode: true,
  ),
];

final _receiveStockPatterns = <RegExp>[
  RegExp(
    r'(?:restock|stock\s+add|add\s+stock|receive\s+stock|stock\s+receive)\s*(?:by\s*)?[:=]?\s*([0-9०-९]{1,9})(?:\s*(?:units?|pcs?|pieces?))?',
    caseSensitive: false,
    unicode: true,
  ),
  RegExp(
    r'([0-9०-९]{1,9})\s*(?:units?|pcs?|pieces?)\s*(?:restock|stock\s+add|add\s+stock|receive\s+stock)',
    caseSensitive: false,
    unicode: true,
  ),
  RegExp(
    r'(?:stock\s+badhao|stock\s+badha do|stock\s+badhado)\s*([0-9०-९]{1,9})(?:\s*units?)?',
    caseSensitive: false,
    unicode: true,
  ),
  RegExp(
    r'(?:स्टॉक\s+जोड़ो|स्टॉक\s+बढ़ाओ|स्टॉक\s+बढ़ा दो)\s*([0-9०-९]{1,9})(?:\s*(?:यूनिट|यूनिट्स))?',
    caseSensitive: false,
    unicode: true,
  ),
];

const _fillers = <String>[
  'please',
  'can you',
  'could you',
  'would you',
  'will you',
  'i want to',
  'i need to',
  'want to',
  'need to',
  'aap',
  'zara',
  'kripya',
  'आप',
  'ज़रा',
  'जरा',
  'कृपया',
  'plz',
  'medicine',
  'medicines',
  'dawai',
  'dawa',
  'stock entry',
  'entry',
  'ko',
  'karo',
  'kar do',
  'karna',
  'mujhe',
  'mera',
  'meri',
  'the',
  'hai',
  'hain',
  'stock',
  'and',
  'aur',
  'और',
  'मेडिसिन',
  'दवा',
  'को',
  'करो',
  'कर दो',
  'मुझे',
  'मेरी',
  'है',
  'हैं',
];

const _backupRestoreTerms = <String>[
  'restore backup',
  'backup restore',
  'backup and restore',
  'open backup',
  'backup kholo',
  'बैकअप रिस्टोर',
  'बैकअप खोलो',
];

const _restoreTerms = <String>[
  'restore stock',
  'restore medicine',
  'restore',
  'bring back',
  'recover stock',
  'recover medicine',
  'wapas lao',
  'wapas le aao',
  'dobara lao',
  'वापस लाओ',
  'बहाल करो',
  'रिस्टोर',
];

const _removedListTerms = <String>[
  'removed stock',
  'removed medicines',
  'removed medicine',
  'removed history',
  'deleted medicines',
  'deleted medicine',
  'archived medicines',
  'archived stock',
  'hatai hui medicine',
  'हटाई हुई मेडिसिन',
  'रिमूव्ड स्टॉक',
  'डिलीट मेडिसिन',
];

const _removeTerms = <String>[
  'delete',
  'deleting',
  'remove',
  'removing',
  'archive',
  'discard',
  'discarding',
  'nikal do',
  'nikaal do',
  'निकाल दो',
  'hatao',
  'hata do',
  'hata dena',
  'हटाओ',
  'हटा दो',
  'डिलीट',
  'रिमूव',
];

const _soldTerms = <String>[
  'mark sold',
  'sold mark',
  'stock finished',
  'stock khatam',
  'poora stock bik gaya',
  'pura stock bik gaya',
  'पूरा स्टॉक बिक गया',
  'स्टॉक खत्म',
];

const _imperativeSaleTerms = <String>[
  'sell medicine',
  'dispense medicine',
  'sell',
  'dispense',
  'bech do',
  'becho',
  'bechna',
  'बेच दो',
  'बेचो',
  'डिस्पेंस',
];

const _saleReadGuardTerms = <String>[
  'which',
  'what',
  'should',
  'first',
  'how much',
  'pehle',
  'kaunsi',
  'konsi',
  'kitna',
  'कौनसी',
  'पहले',
  'कितना',
];

const _saleTerms = <String>[
  'record sale',
  'sale record',
  'sale add',
  'becha',
  'bikri',
  'बिक्री',
  'सेल रिकॉर्ड',
];

const _editorFieldEditVerbs = <String>[
  'change',
  'update',
  'edit',
  'correct',
  'fix',
  'set',
  'badlo',
  'badal do',
  'sahi karo',
  'theek karo',
  'बदलो',
  'बदल दो',
  'अपडेट',
  'एडिट',
  'सही करो',
  'ठीक करो',
  'सेट',
];

const _editorFieldTerms = <String>[
  'expiry date',
  'expiry',
  'exp date',
  'mfg date',
  'manufacturing date',
  'manufacturing',
  'mfg',
  'batch number',
  'batch no',
  'batch',
  'barcode',
  'bar code',
  'unit price',
  'price',
  'amount',
  'salt',
  'strength',
  'brand',
  'manufacturer',
  'medicine name',
  'name',
  'form',
  'notes',
  'note',
  'एक्सपायरी डेट',
  'एक्सपायरी',
  'एमएफजी डेट',
  'मैन्युफैक्चरिंग डेट',
  'बैच नंबर',
  'बैच',
  'बारकोड',
  'कीमत',
  'अमाउंट',
  'सॉल्ट',
  'स्ट्रेंथ',
  'ब्रांड',
  'मैन्युफैक्चरर',
  'मेडिसिन नाम',
  'नाम',
  'फॉर्म',
  'नोट्स',
  'नोट',
];

const _editTerms = <String>[
  'edit',
  'update medicine',
  'medicine update',
  'badlo',
  'change medicine',
  'एडिट',
  'अपडेट',
  'बदलो',
];

const _nextTaskTerms = <String>[
  'next task',
  'next safe task',
  'next work',
  'next issue',
  'next problem',
  'do next task',
  'start next task',
  'start work',
  'open next task',
  'handle next task',
  'fix next issue',
  'what next',
  'ab kya karu',
  'ab kya karna hai',
  'agla kaam',
  'agla kaam kholo',
  'agla task',
  'agli problem',
  'अगला काम',
  'अगला काम खोलो',
  'अगला टास्क',
  'अगली समस्या',
  'अब क्या करूं',
  'अब क्या करना है',
];

const _attentionTerms = <String>[
  'what needs attention',
  'needs attention',
  'attention brief',
  'attention summary',
  'risk summary',
  'problem stock',
  'data quality',
  'data quality check',
  'inventory problems',
  'stock problems',
  'duplicate stock',
  'duplicate entries',
  'barcode conflict',
  'scan conflict',
  'missing expiry',
  'missing quantity',
  'future mfg',
  'future manufacturing date',
  'aaj kya dekhna hai',
  'aaj kya karna hai',
  'kya dikkat hai',
  'क्या देखना है',
  'आज क्या करना है',
  'क्या दिक्कत है',
  'डाटा क्वालिटी',
];

const _scanTerms = <String>[
  'scan medicine',
  'scan pack',
  'start scan',
  'open scanner',
  'scanner kholo',
  'scan karo',
  'barcode scan',
  'स्कैन करो',
  'स्कैनर खोलो',
  'मेडिसिन स्कैन',
];

const _locationTerms = <String>[
  'where is',
  'where are',
  'location of',
  'location batao',
  'location dikhao',
  'kahan hai',
  'kidhar hai',
  'rack kaha',
  'rack kahan',
  'shelf kaha',
  'shelf kahan',
  'कहाँ है',
  'किधर है',
  'लोकेशन बताओ',
  'रैक कहाँ',
  'शेल्फ कहाँ',
];

const _stockLookupTerms = <String>[
  'how much stock',
  'stock of',
  'stock kitna hai',
  'stock kitna',
  'kitna stock hai',
  'kitna stock',
  'quantity of',
  'quantity kitni hai',
  'quantity kitni',
  'kitni quantity hai',
  'kitni quantity',
  'units left',
  'kitne bache',
  'kitni bachi',
  'कितना स्टॉक है',
  'कितना स्टॉक',
  'कितनी क्वांटिटी',
  'कितने बचे',
];

const _expiryLookupTerms = <String>[
  'expiry date of',
  'expiry of',
  'expiry kab hai',
  'expiry kab',
  'expiry batao',
  'exp date',
  'exp kab',
  'kab expire hogi',
  'kab expire hoga',
  'kab expire',
  'एक्सपायरी कब है',
  'एक्सपायरी कब',
  'एक्सपायरी बताओ',
  'कब एक्सपायर',
];

const _fefoTerms = <String>[
  'which batch first',
  'which stock first',
  'sell which batch first',
  'dispense which batch first',
  'first expiry first out',
  'fefo',
  'pehle kaunsi batch',
  'pehle konsi batch',
  'pehle konsa batch',
  'kaunsi batch pehle',
  'konsi batch pehle',
  'pehle kya nikalu',
  'पहले कौनसी बैच',
  'कौनसी बैच पहले',
  'पहले क्या निकालूं',
];

const _addTerms = <String>[
  'add medicine',
  'medicine add',
  'new medicine',
  'create medicine',
  'add stock',
  'add',
  'nayi medicine',
  'nayi dawai',
  'नई मेडिसिन',
  'नई दवा',
  'मेडिसिन जोड़',
  'जोड़ो',
];

const _openMedicineTerms = <String>[
  'open medicine',
  'open',
  'view medicine',
  'view',
  'medicine kholo',
  'kholo',
  'मेडिसिन खोलो',
  'खोलो',
];

const _searchTerms = <String>[
  'search',
  'find',
  'dhoondo',
  'dhundo',
  'dikhao',
  'show medicine',
  'खोजो',
  'ढूंढो',
  'दिखाओ',
];

const _identifierTerms = <String>[
  'batch number',
  'batch no',
  'batch',
  'barcode',
  'bar code',
  'location',
  'rack',
  'shelf',
  'block',
  'row',
  'बैच नंबर',
  'बैच',
  'बारकोड',
  'लोकेशन',
  'रैक',
];
