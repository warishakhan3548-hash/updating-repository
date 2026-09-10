from __future__ import annotations

import re
from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def regex_once(text: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one regex match, found {count}")
    return updated


def patch_app_brain() -> None:
    path = "lib/domain/app_brain.dart"
    text = read(path)
    text = replace_once(
        text,
        "import 'brain_operations.dart';",
        "import 'brain_analytics.dart';\nimport 'brain_operations.dart';",
        "app_brain analytics import",
    )
    text = replace_once(
        text,
        "  inventorySummary,\n  attentionBrief,",
        "  inventorySummary,\n  analyticsBrief,\n  attentionBrief,",
        "app_brain analytics enum",
    )
    text = replace_once(
        text,
        "    this.quantity,\n    this.briefFocus,",
        "    this.quantity,\n    this.analyticsRequest,\n    this.briefFocus,",
        "app_brain analytics constructor",
    )
    text = replace_once(
        text,
        "  final int? quantity;\n  final MedicineBriefFocus? briefFocus;",
        "  final int? quantity;\n  final BrainAnalyticsRequest? analyticsRequest;\n  final MedicineBriefFocus? briefFocus;",
        "app_brain analytics field",
    )
    text = replace_once(
        text,
        """  if (_containsAny(text, _analyticsReadTerms)) {
    return const AppBrainIntent(
      action: AppBrainAction.navigate,
      section: AppSection.calculator,
      confidence: .98,
    );
  }
""",
        """  final analytics = parseBrainAnalyticsRequest(raw);
  if (analytics != null) {
    return AppBrainIntent(
      action: AppBrainAction.analyticsBrief,
      analyticsRequest: analytics,
      confidence: .99,
    );
  }
""",
        "app_brain analytics parser",
    )
    text = regex_once(
        text,
        r"const _analyticsReadTerms = <String>\[.*?\];\n\n(?=const _nextTaskTerms)",
        "",
        "remove obsolete analytics term table",
    )
    write(path, text)


def patch_brain_screen() -> None:
    path = "lib/ui/brain_screen.dart"
    text = read(path)
    text = replace_once(
        text,
        "import '../domain/attention.dart';",
        "import '../domain/attention.dart';\nimport '../domain/brain_analytics.dart';",
        "brain_screen analytics import",
    )
    text = replace_once(
        text,
        """      case AppBrainAction.inventorySummary:
        _summary();
        return;
      case AppBrainAction.attentionBrief:
""",
        """      case AppBrainAction.inventorySummary:
        _summary();
        return;
      case AppBrainAction.analyticsBrief:
        final request = intent.analyticsRequest;
        if (request == null) {
          _unknown(raw);
          return;
        }
        _analyticsBrief(request);
        return;
      case AppBrainAction.attentionBrief:
""",
        "brain_screen analytics action",
    )

    new_undo = r'''  Future<void> _undo() async {
    if (!widget.controller.canUndo) {
      setState(() => _reply = 'There is no current change available to undo.');
      return;
    }

    // Bind the confirmation copy to the exact newest audited event. The
    // controller still rechecks canUndo/revision when committing, so this is an
    // explainability improvement rather than a second authority over recovery.
    final event = widget.controller.snapshot.events.first;
    final label = event['label'] is String
        ? event['label'] as String
        : 'Latest inventory change';
    final revision = event['revision'] is int
        ? event['revision'] as int
        : widget.controller.snapshot.revision;
    final businessDay = event['businessDay'] is String
        ? event['businessDay'] as String
        : '';
    final rawTime = event['time'] is String ? event['time'] as String : '';
    final parsedTime = DateTime.tryParse(rawTime);
    final localTime = parsedTime?.toLocal();
    final timeLabel = localTime == null
        ? 'Time unavailable'
        : localTime.toString().split('.').first;

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Undo this exact inventory change?'),
            content: Text(
              '$label\n\nRevision $revision${businessDay.isEmpty ? '' : ' · business day $businessDay'}\n$timeLabel\n\nAaris will restore the immediately previous audited inventory state. If anything changes before this confirmation commits, the revision-protected undo will fail closed.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Undo this change'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      setState(() => _reply = 'Undo cancelled. Nothing changed.');
      return;
    }
    await widget.controller.undo();
    if (mounted) {
      setState(() => _reply = 'Last reviewed inventory change was undone.');
    }
  }

'''
    text = regex_once(
        text,
        r"  Future<void> _undo\(\) async \{.*?\n  \}\n\n(?=  void _summary\(\))",
        lambda_match(new_undo),
        "brain_screen undo explainability",
    )

    summary_match = re.search(
        r"  void _summary\(\) \{.*?\n  \}\n\n(?=  PharmacyAttentionReport _currentAttentionReport)",
        text,
        flags=re.S,
    )
    if summary_match is None:
        raise RuntimeError("brain_screen summary anchor not found")
    analytics_method = r'''
  void _analyticsBrief(BrainAnalyticsRequest request) {
    final range = request.resolveRange(widget.controller.today);
    final stats = widget.controller.tracking(range);
    final brief = buildBrainAnalyticsBrief(
      request: request,
      stats: stats,
      today: widget.controller.today,
    );
    setState(() => _reply = brief);
  }

'''
    insert_at = summary_match.end()
    text = text[:insert_at] + analytics_method + text[insert_at:]

    text = replace_once(
        text,
        """                        _QuickCommand('Stock summary', 'stock summary'),
                        _QuickCommand('Add medicine', 'add medicine'),
""",
        """                        _QuickCommand('Stock summary', 'stock summary'),
                        _QuickCommand('Sales today', 'aaj ki bikri kitni'),
                        _QuickCommand('Fast movers', 'fast moving this month'),
                        _QuickCommand('Slow movers', 'slow moving last 30 days'),
                        _QuickCommand('Add medicine', 'add medicine'),
""",
        "brain_screen analytics quick commands",
    )
    write(path, text)


def lambda_match(value: str):
    return lambda _: value


def patch_tracking() -> None:
    path = "lib/domain/tracking.dart"
    text = read(path)
    old = """      final price =
          active
              .where((m) => m.unitPricePaise != null)
              .firstOrNull
              ?.unitPricePaise ??
          records
              .where((m) => m.sold && m.soldUnitPricePaise != null)
              .firstOrNull
              ?.soldUnitPricePaise;
"""
    new = """      // Purchase-order cost is an accounting input, not a value Aaris may
      // guess from whichever batch happens to be first in an Iterable. Auto-fill
      // only when all known active batch prices agree. If active stock has no
      // saved price, one unambiguous historical SOLD price may be used. Conflicting
      // evidence intentionally produces null so the pharmacist enters/reviews cost.
      final activePrices = active
          .map((medicine) => medicine.unitPricePaise)
          .whereType<int>()
          .toSet();
      final historicalPrices = records
          .where((medicine) => medicine.sold)
          .map((medicine) => medicine.soldUnitPricePaise)
          .whereType<int>()
          .toSet();
      final price = activePrices.length == 1
          ? activePrices.single
          : activePrices.isEmpty && historicalPrices.length == 1
          ? historicalPrices.single
          : null;
"""
    text = replace_once(text, old, new, "tracking cost consensus")
    write(path, text)


def patch_order_screen() -> None:
    path = "lib/ui/order_screen.dart"
    text = read(path)
    text = replace_once(
        text,
        """                                suggestion.confidenceLabel,
                                if (suggestion.reviewRequired)
                                  'Manual review required',
""",
        """                                suggestion.confidenceLabel,
                                if (suggestion.unitPricePaise == null)
                                  'Unit cost needs review',
                                if (suggestion.reviewRequired)
                                  'Manual review required',
""",
        "order_screen cost review cue",
    )
    write(path, text)


def main() -> None:
    patch_app_brain()
    patch_brain_screen()
    patch_tracking()
    patch_order_screen()
    print("Aaris surgical upgrade applied")


if __name__ == "__main__":
    main()
