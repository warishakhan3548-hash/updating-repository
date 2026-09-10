from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected one patch anchor, found {count}')
    p.write_text(text.replace(old, new, 1))


warning_policy = r'''import 'medicine.dart';

/// A narrow, deterministic update to the pharmacist's expiry-warning policy.
///
/// This is app configuration, never a medicine fact. Values are intentionally
/// unit-qualified so a strength such as "650 mg" cannot become a warning value.
class WarningPolicyPatch {
  const WarningPolicyPatch({this.shortDays, this.months})
    : assert(shortDays != null || months != null);

  final int? shortDays;
  final int? months;

  WarningSettings apply(WarningSettings current) => WarningSettings.fromJson({
    'shortDays': shortDays ?? current.shortDays,
    'months': months ?? current.months,
  });

  String describe() {
    final parts = <String>[
      if (shortDays != null) 'short-expiry: $shortDays days',
      if (months != null) 'month-expiry: $months months',
    ];
    return parts.join(' · ');
  }
}

WarningPolicyPatch? parseWarningPolicyCommand(String raw) {
  if (raw.trim().isEmpty || raw.length > 500) return null;
  final ascii = _asciiDigits(raw);
  final text = _normalizePolicy(ascii);
  if (!_looksLikePolicyContext(text) || !_hasPolicyMutationVerb(text)) {
    return null;
  }

  final dayValues = _unitValues(
    ascii,
    RegExp(
      r'(?:^|[^0-9])([0-9]{1,3})\s*(?:day|days|din|दिन)(?=$|[^A-Za-z0-9\u0900-\u097f])',
      caseSensitive: false,
      unicode: true,
    ),
  );
  final monthValues = _unitValues(
    ascii,
    RegExp(
      r'(?:^|[^0-9])([0-9]{1,2})\s*(?:month|months|mahina|mahine|mahinae|महीना|महीने)(?=$|[^A-Za-z0-9\u0900-\u097f])',
      caseSensitive: false,
      unicode: true,
    ),
  );

  if (dayValues.length > 1) {
    throw const FormatException(
      'Use one day value for the short-expiry warning in a single command.',
    );
  }
  if (monthValues.length > 1) {
    throw const FormatException(
      'Use one month value for the month-expiry warning in a single command.',
    );
  }
  if (dayValues.isEmpty && monthValues.isEmpty) {
    throw const FormatException(
      'Say the expiry-warning value with an explicit unit, for example “10 days” or “3 months”.',
    );
  }

  final days = dayValues.isEmpty ? null : dayValues.single;
  final months = monthValues.isEmpty ? null : monthValues.single;
  if (days != null && (days < 1 || days > 365)) {
    throw const FormatException('Short-expiry warning must be 1–365 days.');
  }
  if (months != null && (months < 1 || months > 24)) {
    throw const FormatException('Month-expiry warning must be 1–24 months.');
  }
  return WarningPolicyPatch(shortDays: days, months: months);
}

/// Fast safety-family detector used before the command parser routes writes.
bool looksLikeWarningPolicyMutation(String raw) {
  if (raw.trim().isEmpty || raw.length > 500) return false;
  final text = _normalizePolicy(_asciiDigits(raw));
  return _looksLikePolicyContext(text) && _hasPolicyMutationVerb(text);
}

List<int> _unitValues(String raw, RegExp pattern) => pattern
    .allMatches(raw)
    .map((match) => int.parse(match.group(1)!))
    .toList(growable: false);

bool _looksLikePolicyContext(String text) => _containsPolicyPhrase(
  text,
  const [
    'warning',
    'warning window',
    'expiry warning',
    'expiry alert',
    'alert window',
    'short expiry',
    'short expiry warning',
    'month expiry',
    'month expiry warning',
    'expiry window',
    'चेतावनी',
    'एक्सपायरी चेतावनी',
    'एक्सपायरी अलर्ट',
    'शॉर्ट एक्सपायरी',
    'मंथ एक्सपायरी',
  ],
);

bool _hasPolicyMutationVerb(String text) => _containsPolicyPhrase(
  text,
  const [
    'set',
    'set karo',
    'set kar do',
    'change',
    'change karo',
    'update',
    'update karo',
    'configure',
    'rakho',
    'rakh do',
    'badlo',
    'badal do',
    'सेट',
    'सेट करो',
    'सेट कर दो',
    'अपडेट',
    'अपडेट करो',
    'बदलो',
    'बदल दो',
    'रखो',
    'रख दो',
  ],
);

bool _containsPolicyPhrase(String text, List<String> phrases) => phrases.any((p) {
  final phrase = _normalizePolicy(p);
  return text == phrase ||
      text.startsWith('$phrase ') ||
      text.endsWith(' $phrase') ||
      text.contains(' $phrase ');
});

String _normalizePolicy(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f]+', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _asciiDigits(String value) {
  const devanagari = '०१२३४५६७८९';
  final out = StringBuffer();
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final index = devanagari.indexOf(char);
    out.write(index < 0 ? char : index);
  }
  return out.toString();
}
'''
Path('lib/domain/warning_policy.dart').write_text(warning_policy)

replace_once(
    'lib/domain/app_brain.dart',
    "import 'medicine_brief.dart';\n",
    "import 'medicine_brief.dart';\nimport 'warning_policy.dart';\n",
)
replace_once(
    'lib/domain/app_brain.dart',
    "  nextAttentionTask,\n  bulkRemoveBlocked,\n",
    "  nextAttentionTask,\n  activityBrief,\n  setWarningPolicy,\n  bulkRemoveBlocked,\n",
)
replace_once(
    'lib/domain/app_brain.dart',
    "    this.removalReason,\n    this.safetyReason,\n",
    "    this.removalReason,\n    this.warningPolicy,\n    this.safetyReason,\n",
)
replace_once(
    'lib/domain/app_brain.dart',
    "  final RemovalReasonHint? removalReason;\n  final AppBrainSafetyReason? safetyReason;\n",
    "  final RemovalReasonHint? removalReason;\n  final WarningPolicyPatch? warningPolicy;\n  final AppBrainSafetyReason? safetyReason;\n",
)
replace_once(
    'lib/domain/app_brain.dart',
    "    AppBrainAction.undoLast => true,\n",
    "    AppBrainAction.undoLast ||\n    AppBrainAction.setWarningPolicy => true,\n",
)
replace_once(
    'lib/domain/app_brain.dart',
    "  if (_containsAny(text, const [\n    'undo',\n    'undo last',\n",
    "  final warningPolicy = parseWarningPolicyCommand(raw);\n  if (warningPolicy != null) {\n    return AppBrainIntent(\n      action: AppBrainAction.setWarningPolicy,\n      warningPolicy: warningPolicy,\n      confidence: .99,\n    );\n  }\n\n  if (_containsAny(text, const [\n    'undo',\n    'undo last',\n",
)
replace_once(
    'lib/domain/app_brain.dart',
    "  // Natural-language control must never become an unreviewed bulk destructive\n",
    "  if (_containsAny(text, const [\n    'what changed today',\n    'what changed',\n    'recent activity',\n    'activity history',\n    'last activity',\n    'show activity',\n    'aaj kya change hua',\n    'aaj kya badla',\n    'recent changes',\n    'आज क्या बदला',\n    'आज क्या बदलाव हुआ',\n    'हाल के बदलाव',\n  ])) {\n    return const AppBrainIntent(\n      action: AppBrainAction.activityBrief,\n      confidence: .99,\n    );\n  }\n\n  // Natural-language control must never become an unreviewed bulk destructive\n",
)
replace_once(
    'lib/domain/app_brain.dart',
    "  if (locationMutation) families.add('relocate');\n\n  if (families.isEmpty) return null;\n",
    "  if (locationMutation) families.add('relocate');\n  if (looksLikeWarningPolicyMutation(raw)) families.add('warning-policy');\n\n  if (families.isEmpty) return null;\n",
)

replace_once(
    'lib/state/pharmacy_controller.dart',
    "/// Immutable single-stock sale review.\n",
    """class ReviewedWarningSettings {
  const ReviewedWarningSettings({
    required this.baseRevision,
    required this.before,
    required this.after,
  });

  final int baseRevision;
  final WarningSettings before;
  final WarningSettings after;

  bool get changesSettings =>
      before.shortDays != after.shortDays || before.months != after.months;
}

/// Immutable single-stock sale review.
""",
)
replace_once(
    'lib/state/pharmacy_controller.dart',
    """  Future<void> setWarnings(WarningSettings value) => _commit(
    InventoryMutation(
      expectedRevision: snapshot.revision,
      label: 'Updated expiry warning windows',
      upserts: [],
      settings: value,
    ),
  );
""",
    """  ReviewedWarningSettings reviewWarningSettings(WarningSettings value) {
    final before = WarningSettings.fromJson(settings.toJson());
    final after = WarningSettings.fromJson(value.toJson());
    return ReviewedWarningSettings(
      baseRevision: snapshot.revision,
      before: before,
      after: after,
    );
  }

  Future<void> applyWarningSettings(ReviewedWarningSettings review) async {
    final live = settings;
    if (review.baseRevision != snapshot.revision ||
        live.shortDays != review.before.shortDays ||
        live.months != review.before.months) {
      throw StateError(
        'Expiry-warning settings changed after this review was prepared. Review the live policy again before saving.',
      );
    }
    if (!review.changesSettings) return;
    await _commit(
      InventoryMutation(
        expectedRevision: snapshot.revision,
        label:
            'Updated expiry warnings · ${review.after.shortDays} days · ${review.after.months} months',
        upserts: const [],
        settings: review.after,
      ),
    );
  }

  Future<void> setWarnings(WarningSettings value) =>
      applyWarningSettings(reviewWarningSettings(value));
""",
)

replace_once(
    'lib/ui/brain_screen.dart',
    "import '../domain/tracking.dart';\n",
    "import '../domain/tracking.dart';\nimport '../domain/warning_policy.dart';\n",
)
replace_once(
    'lib/ui/brain_screen.dart',
    """      case AppBrainAction.nextAttentionTask:
        await _attentionBrief(focusNext: true);
        return;
      case AppBrainAction.bulkRemoveBlocked:
""",
    """      case AppBrainAction.nextAttentionTask:
        await _attentionBrief(focusNext: true);
        return;
      case AppBrainAction.activityBrief:
        _activityBrief();
        return;
      case AppBrainAction.setWarningPolicy:
        await _warningPolicy(intent);
        return;
      case AppBrainAction.bulkRemoveBlocked:
""",
)

brain_methods = r'''  void _activityBrief() {
    if (!mounted) return;
    final events = widget.controller.snapshot.events;
    if (events.isEmpty) {
      setState(
        () => _reply =
            'No inventory activity has been recorded yet. Aaris did not invent any history.',
      );
      return;
    }

    final todayKey = dateText(widget.controller.today);
    final todayEvents = events
        .where((event) => event['businessDay'] == todayKey)
        .toList(growable: false);
    final source = todayEvents.isEmpty ? events : todayEvents;
    final lines = source.take(5).map((event) {
      final rawLabel = event['label'];
      final label = rawLabel is String && rawLabel.trim().isNotEmpty
          ? rawLabel.trim()
          : 'Inventory change';
      return event['undone'] == true ? '$label (undone)' : label;
    }).toList(growable: false);

    final intro = todayEvents.isEmpty
        ? 'No inventory activity is recorded for today. Latest saved activity:'
        : '${todayEvents.length} ${todayEvents.length == 1 ? 'change' : 'changes'} recorded today:';
    setState(() => _reply = '$intro ${lines.join(' · ')}');
  }

  Future<void> _warningPolicy(AppBrainIntent intent) async {
    if (!mounted) return;
    final patch = intent.warningPolicy;
    if (patch == null) {
      throw StateError('The expiry-warning command is incomplete. Nothing changed.');
    }

    final next = patch.apply(widget.controller.settings);
    final review = widget.controller.reviewWarningSettings(next);
    if (!review.changesSettings) {
      setState(
        () => _reply =
            'Expiry warnings already use ${review.before.shortDays} days and ${review.before.months} months. No setting changed.',
      );
      return;
    }

    final confirmed =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('Update expiry warning policy?'),
            content: Text(
              'Current: ${review.before.shortDays} days · ${review.before.months} months\n'
              'New: ${review.after.shortDays} days · ${review.after.months} months\n\n'
              'This changes only the deterministic dashboard/attention windows. It does not edit any medicine, expiry date, stock quantity, sale or medical fact. The month window must remain longer than the short-expiry window.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Update policy'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      setState(() => _reply = 'Expiry-warning update cancelled. Nothing changed.');
      return;
    }

    await widget.controller.applyWarningSettings(review);
    if (!mounted) return;
    setState(
      () => _reply =
          'Expiry warnings updated to ${review.after.shortDays} days and ${review.after.months} months. Home cards, scoped search and Aaris Autopilot will recalculate from the same Medicine Database.',
    );
  }

'''
replace_once(
    'lib/ui/brain_screen.dart',
    "  Future<void> _removedStock(AppBrainIntent intent) async {\n",
    brain_methods + "  Future<void> _removedStock(AppBrainIntent intent) async {\n",
)

tests = r'''import 'package:aaris_pharmacy/data/inventory_database.dart';
import 'package:aaris_pharmacy/domain/app_brain.dart';
import 'package:aaris_pharmacy/domain/medicine.dart';
import 'package:aaris_pharmacy/domain/warning_policy.dart';
import 'package:aaris_pharmacy/state/pharmacy_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Future<PharmacyController> makeController() async {
  final controller = PharmacyController(
    MemoryInventoryStorage(),
    clock: () => DateTime(2026, 9, 10, 12),
    backgroundSearch: false,
  );
  await controller.initialize();
  return controller;
}

void main() {
  group('Aaris Brain expiry-policy control plane', () {
    test('parses explicit unit-bound warning policy in English and Hindi digits', () {
      final combined = parseAppBrainIntent(
        'short expiry warning 10 days and month expiry 3 months set karo',
      );
      expect(combined.action, AppBrainAction.setWarningPolicy);
      expect(combined.warningPolicy?.shortDays, 10);
      expect(combined.warningPolicy?.months, 3);
      expect(combined.mutatesInventory, isTrue);
      expect(combined.destructive, isFalse);

      final hindi = parseAppBrainIntent('शॉर्ट एक्सपायरी १२ दिन सेट करो');
      expect(hindi.action, AppBrainAction.setWarningPolicy);
      expect(hindi.warningPolicy?.shortDays, 12);
    });

    test('ordinary expiry lookup/list language cannot mutate policy', () {
      expect(parseAppBrainIntent('short expiry').action, AppBrainAction.search);
      final medicineQuestion = parseAppBrainIntent('Dolo expiry 10 days set karo');
      expect(medicineQuestion.action, isNot(AppBrainAction.setWarningPolicy));
    });

    test('policy changes obey the deterministic write firewall', () {
      for (final command in [
        'short expiry warning 10 days set mat karo',
        'tomorrow short expiry warning 10 days set karo',
        'Dolo delete karo and short expiry warning 10 days set karo',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.safetyBlocked, reason: command);
      }
    });

    test('ambiguous or unitless warning mutations fail closed', () {
      expect(
        () => parseWarningPolicyCommand('short expiry warning 8 10 days set karo'),
        throwsFormatException,
      );
      expect(
        () => parseWarningPolicyCommand('short expiry warning 10 set karo'),
        throwsFormatException,
      );
    });

    test('activity questions route to deterministic local audit history', () {
      for (final command in [
        'what changed today',
        'recent activity',
        'aaj kya change hua',
        'आज क्या बदला',
      ]) {
        final intent = parseAppBrainIntent(command);
        expect(intent.action, AppBrainAction.activityBrief, reason: command);
        expect(intent.mutatesInventory, isFalse, reason: command);
        expect(intent.destructive, isFalse, reason: command);
      }
    });
  });

  group('reviewed warning policy transaction', () {
    test('policy update is validated, audited and undoable', () async {
      final controller = await makeController();
      addTearDown(controller.dispose);

      final review = controller.reviewWarningSettings(
        const WarningSettings(shortDays: 10, months: 3),
      );
      expect(review.baseRevision, 0);
      expect(review.changesSettings, isTrue);
      await controller.applyWarningSettings(review);

      expect(controller.settings.shortDays, 10);
      expect(controller.settings.months, 3);
      expect(controller.snapshot.events.first['label'], contains('10 days'));
      expect(controller.snapshot.events.first['label'], contains('3 months'));

      await controller.undo();
      expect(controller.settings.shortDays, 8);
      expect(controller.settings.months, 2);
    });

    test('a stale policy review cannot overwrite newer inventory state', () async {
      final controller = await makeController();
      addTearDown(controller.dispose);
      final review = controller.reviewWarningSettings(
        const WarningSettings(shortDays: 10, months: 3),
      );

      await controller.save(
        Medicine.fromJson({
          'id': 'stock-a',
          'name': 'Dolo',
          'strength': '650 mg',
          'form': 'Tablet',
          'quantity': 10,
          'expiry': '2027-12',
          'revision': 1,
        }),
        expectedRevision: 0,
      );

      await expectLater(controller.applyWarningSettings(review), throwsStateError);
      expect(controller.settings.shortDays, 8);
      expect(controller.settings.months, 2);
    });

    test('invalid cross-window policy is rejected before review', () async {
      final controller = await makeController();
      addTearDown(controller.dispose);
      const patch = WarningPolicyPatch(shortDays: 60, months: 1);
      expect(() => patch.apply(controller.settings), throwsFormatException);
    });
  });
}
'''
Path('test/brain_control_plane_upgrade_test.dart').write_text(tests)

doc = r'''# Aaris Brain Control Plane Upgrade — 2026-09-10

This pass extends the existing Aaris Pharmacy architecture instead of creating a
second automation engine. SQLite and `PharmacyController` remain authoritative.

## Reviewed expiry-policy control

Aaris Brain can now understand explicit policy commands such as `short expiry
warning 10 days set karo` and a combined `10 days / 3 months` request. Values
must carry an explicit day/month unit; medicine strengths and ordinary expiry
questions cannot become settings. Hindi/Devanagari digits are normalized locally.

The same deterministic intent firewall runs before routing, so negated, deferred
or compound inventory + policy instructions fail closed. A proposed policy is
validated by `WarningSettings`, shown as current → new values, and requires an
explicit confirmation. The review is bound to the exact inventory revision;
stale confirmation cannot overwrite newer state. The accepted mutation is
atomic, audited and Undo-compatible. No medicine facts are edited.

## Deterministic activity brief

`what changed today`, `recent activity`, Hinglish and Hindi variants read the
existing bounded local audit ledger directly. Aaris reports saved event labels
and marks undone operations; it does not send history to a model or invent an
event when none exists.

## Why this matters

The Brain now controls an important app-level policy and can answer operational
history questions through the same local control center that already handles
search, scan, FEFO sale review, receiving, correction, relocation, removal,
restore, SOLD, reorder and attention routing. This improves pharmacist automation
without granting AI a hidden write path.
'''
Path('docs/AARIS_BRAIN_CONTROL_PLANE_2026_09_10.md').write_text(doc)

replace_once(
    'docs/PROGRESS.md',
    "- Voice-search lifecycle repair: device locales, permission retry, serialized\n  commands, final-word preservation, stale callback rejection and exit cleanup.\n",
    "- Voice-search lifecycle repair: device locales, permission retry, serialized\n  commands, final-word preservation, stale callback rejection and exit cleanup.\n- Aaris Brain control-plane upgrade: explicit unit-bound expiry-warning policy\n  commands now use deterministic parsing, firewall checks, revision-bound review,\n  confirmation, audit and Undo; local activity questions read the audit ledger\n  without invoking AI or inventing history.\n",
)
replace_once(
    'docs/ARCHITECTURE.md',
    """Aaris Brain also applies a deterministic intent firewall before any natural-language
write is routed. Negated commands, future/conditional writes and sentences containing
multiple write families fail closed before target search, so the app cannot execute a
command the pharmacist explicitly rejected, execute a scheduled instruction early, or
silently run only the first half of a compound request. Conversational references are
normalized through a closed deictic grammar and still resolve only to the session's
exact ID/fingerprint; they never become fuzzy implicit mutation targets. The Brain's
“next task” route uses the same dependency-aware local operations plan shown in Needs
Attention, so its recommendation cannot jump ahead of known verification blockers.
""",
    """Aaris Brain also applies a deterministic intent firewall before any natural-language
write is routed. Negated commands, future/conditional writes and sentences containing
multiple write families fail closed before target search, so the app cannot execute a
command the pharmacist explicitly rejected, execute a scheduled instruction early, or
silently run only the first half of a compound request. Conversational references are
normalized through a closed deictic grammar and still resolve only to the session's
exact ID/fingerprint; they never become fuzzy implicit mutation targets. The Brain's
“next task” route uses the same dependency-aware local operations plan shown in Needs
Attention, so its recommendation cannot jump ahead of known verification blockers.
Explicit expiry-warning policy commands are unit-bound and pass through the same
firewall. They create a revision-bound before/after review and explicit confirmation;
ordinary expiry questions or medicine strengths cannot mutate app policy. Brain
activity questions read only the existing local audit ledger and never model-infer
missing history.
""",
)
