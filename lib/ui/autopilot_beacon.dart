import 'package:flutter/material.dart';

import '../domain/stock_guidance.dart';
import '../state/autopilot_supervisor.dart';

/// A compact global signal for urgent pharmacist work.
///
/// The beacon is intentionally read-only. Tapping it opens the existing
/// dependency-aware Needs Attention workflow, where exact-row editing, ordering,
/// confirmation, CAS and Undo boundaries remain authoritative.
class AarisAutopilotBeacon extends StatelessWidget {
  const AarisAutopilotBeacon({
    super.key,
    required this.supervisor,
    required this.onOpenWorkQueue,
  });

  final AarisAutopilotSupervisor supervisor;
  final VoidCallback onOpenWorkQueue;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: supervisor,
    builder: (context, _) {
      final digest = supervisor.digest;
      if (!digest.isReady || !digest.needsProminentSignal) {
        return const SizedBox.shrink();
      }

      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      final degraded = digest.health == AarisAutopilotHealth.degraded;
      final critical = digest.criticalCount > 0;
      final useErrorTone = degraded || critical;
      final accent = useErrorTone ? scheme.error : scheme.primary;
      final priorityText = degraded
          ? 'दोबारा जाँचें'
          : critical
          ? '${digest.criticalCount} बहुत ज़रूरी'
          : '${digest.highCount} ज़रूरी';
      final next = !degraded && digest.nextAction.trim().isNotEmpty
          ? digest.nextAction
          : 'काम देखने के लिए टैप करें';

      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Semantics(
          button: true,
          label: 'आज के काम · $priorityText · $next',
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Material(
              color: Color.alphaBlend(
                accent.withAlpha(12),
                scheme.surface,
              ),
              elevation: 0,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onOpenWorkQueue,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: accent.withAlpha(42)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        degraded
                            ? Icons.sync_problem_rounded
                            : critical
                            ? Icons.error_outline_rounded
                            : Icons.psychology_alt_rounded,
                        color: accent,
                        size: 20,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'आज के काम · $priorityText',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              next,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.arrow_forward_rounded,
                        color: accent,
                        size: 19,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

