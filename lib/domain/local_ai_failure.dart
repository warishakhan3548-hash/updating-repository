import 'dart:async';

/// Records what the runtime actually observed, without storing prompts, model
/// paths or private reasoning. A timeout alone does not prove a RAM failure.
class LocalAiGenerationTimeout extends TimeoutException {
  LocalAiGenerationTimeout({
    required Duration limit,
    required this.hasTokenProgress,
    required this.hasVisibleText,
  }) : super(
         hasVisibleText
             ? 'Local AI started a reply but did not finish before the time limit. No inventory changes were made.'
             : hasTokenProgress
             ? 'Local AI produced output, but no readable reply arrived before the time limit. No inventory changes were made.'
             : 'The local model loaded, but no output arrived before the time limit. This does not confirm a RAM problem. No inventory changes were made.',
         limit,
       );

  final bool hasTokenProgress;
  final bool hasVisibleText;
}
