from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> None:
    file = Path(path)
    text = file.read_text(encoding='utf-8')
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'{label}: expected one match, found {count}')
    file.write_text(text.replace(old, new, 1), encoding='utf-8')


replace_once(
    'test/app_brain_test.dart',
    """          final intent = parseAppBrainIntent(command);
          expect(intent.action, AppBrainAction.navigate, reason: command);
          expect(intent.section, AppSection.calculator, reason: command);
          expect(intent.destructive, isFalse, reason: command);
""",
    """          final intent = parseAppBrainIntent(command);
          expect(intent.action, AppBrainAction.analyticsBrief, reason: command);
          expect(intent.analyticsRequest, isNotNull, reason: command);
          expect(intent.destructive, isFalse, reason: command);
          expect(intent.mutatesInventory, isFalse, reason: command);
""",
    'existing analytics routing regression',
)

replace_once(
    'lib/domain/app_brain.dart',
    """  // being interpreted as a stock mutation. The Calculator/Tracking surface is
  // the existing deterministic source of truth for these metrics.
""",
    """  // being interpreted as a stock mutation. TrackingStats remains the
  // deterministic source of truth; Brain now renders that projection directly.
""",
    'analytics architecture comment',
)

replace_once(
    'lib/ui/brain_screen.dart',
    """  }\n\n\n  void _analyticsBrief(BrainAnalyticsRequest request) {\n""",
    """  }\n\n  void _analyticsBrief(BrainAnalyticsRequest request) {\n""",
    'analytics method spacing',
)
