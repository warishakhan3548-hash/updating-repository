import 'package:flutter/material.dart';

import '../state/autopilot_supervisor.dart';

/// A compact global signal for urgent pharmacist work.
///
/// The beacon is intentionally read-only. Tapping it opens Aaris Brain, where
/// the existing deterministic router, exact-target resolution and review gates
/// remain authoritative for every action.
class AarisAutopilotBeacon extends StatelessWidget {
  const AarisAutopilotBeacon({
    super.key,
    required this.supervisor,
    required this.onOpenBrain,
  });

  final AarisAutopilotSupervisor supervisor;
  final VoidCallback onOpenBrain;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: supervisor,
    builder: (context, _) {
      final digest = supervisor.digest;
      if (!digest.isReady || !digest.hasUrgentWork) {
        return const SizedBox.shrink();
      }

      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      final critical = digest.criticalCount > 0;
      final background = critical
          ? scheme.errorContainer
          : scheme.primaryContainer;
      final foreground = critical
          ? scheme.onErrorContainer
          : scheme.onPrimaryContainer;
      final priorityText = critical
          ? '${digest.criticalCount} critical${digest.highCount > 0 ? ' · ${digest.highCount} high' : ''}'
          : '${digest.highCount} high priority';
      final next = digest.hasNextTask
          ? digest.nextTaskTitle
          : 'Open the current pharmacist work queue';

      return Semantics(
        button: true,
        label: digest.accessibilitySummary,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Material(
            color: background,
            elevation: 4,
            shadowColor: scheme.shadow.withValues(alpha: .18),
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onOpenBrain,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      critical
                          ? Icons.health_and_safety_rounded
                          : Icons.psychology_alt_rounded,
                      color: foreground,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Aaris Autopilot · $priorityText',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: foreground,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Next: $next',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: foreground,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.arrow_forward_rounded, color: foreground),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
