import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/default_local_model.dart';
import '../services/aaris_default_ai_service.dart';
import '../services/local_ai_service.dart';

bool _askedForDefaultAiThisSession = false;

/// Offers one explicit, metered-download-safe setup before medicine capture.
/// Declining or failing never blocks the scanner: the existing deterministic
/// OCR/barcode/pharmacy field engine remains the fallback.
Future<void> offerAarisDefaultAi(
  BuildContext context, {
  bool force = false,
}) async {
  final defaults = AarisDefaultAiService.instance;
  final local = LocalAiService.instance;
  try {
    await defaults.initialize();
    if (!context.mounted || !defaults.supported) return;

    if (!local.hasSelection && defaults.hasDefault) {
      try {
        await defaults.ensureActiveIfInstalled();
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Aaris Default AI could not load right now. The offline pharmacy scanner will be used. $error',
              ),
            ),
          );
        }
        return;
      }
    }
    if (!context.mounted || local.hasSelection || defaults.hasDefault) return;
    if (_askedForDefaultAiThisSession && !force) return;
    _askedForDefaultAiThisSession = true;

    final accepted =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Download Aaris Default AI?'),
            content: const Text(
              'Recommended one-time download: about 400 MB. It adds a small local LLM for medicine, salt and strength reasoning. EXP/MFG still use Aaris safety rules.\n\nIf you choose Not now, scanning still works with the existing offline pharmacy extractor. No pharmacy data is uploaded to download the model.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Not now'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(dialogContext, true),
                icon: const Icon(Icons.download_rounded),
                label: const Text('Download & activate'),
              ),
            ],
          ),
        ) ??
        false;
    if (!accepted || !context.mounted) return;

    final dialogReady = Completer<BuildContext>();
    final progressRoute = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        if (!dialogReady.isCompleted) dialogReady.complete(dialogContext);
        return AnimatedBuilder(
          animation: Listenable.merge([defaults, local]),
          builder: (context, _) => AlertDialog(
            title: const Text('Setting up Aaris Default AI'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: defaults.progress),
                const SizedBox(height: 14),
                Text(defaults.status),
                const SizedBox(height: 8),
                const Text(
                  'You only need this once. The downloaded model is verified and device-tested before it becomes the default.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: defaults.busy ? defaults.cancel : null,
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
      },
    );

    final progressContext = await dialogReady.future;
    Object? failure;
    try {
      await defaults.installAndActivate();
    } catch (error) {
      failure = error;
    } finally {
      if (progressContext.mounted) Navigator.pop(progressContext);
    }
    await progressRoute;
    if (!context.mounted) return;

    if (failure != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Default AI was not activated. Aaris will continue with the offline pharmacy scanner. $failure',
          ),
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          '$aarisDefaultModelDisplayName is active. A stronger user-selected model can override it later.',
        ),
      ),
    );
  } catch (error) {
    // Default AI is an optional acceleration/intelligence layer. Never turn a
    // setup problem into a scanner outage.
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Local AI setup is unavailable right now. Aaris will use the offline pharmacy scanner. $error',
          ),
        ),
      );
    }
  }
}
