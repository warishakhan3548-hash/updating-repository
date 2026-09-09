import 'dart:async';

import 'package:flutter/material.dart';

import '../services/local_ai_service.dart';

/// Embedded in the existing AI connections sheet, never a second AI Hub.
class LocalModelsPanel extends StatefulWidget {
  const LocalModelsPanel({super.key});
  @override
  State<LocalModelsPanel> createState() => _LocalModelsPanelState();
}

class _LocalModelsPanelState extends State<LocalModelsPanel> {
  final local = LocalAiService.instance;
  final query = TextEditingController();
  List<String> repositories = [];
  List<LocalModelFile> files = [];
  String error = '';
  bool searching = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_run(local.initialize));
  }

  @override
  void dispose() {
    ++_generation;
    query.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (mounted) setState(() => error = '');
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> _search([String? repository]) async {
    final generation = ++_generation;
    final text = query.text.trim();
    if (repository == null && text.isEmpty) return;
    setState(() {
      searching = true;
      error = '';
      files = [];
    });
    try {
      if (repository != null || text.contains('/')) {
        final result = await local.files(repository ?? text);
        if (!mounted || generation != _generation) return;
        setState(() {
          files = result;
          if (files.isEmpty)
            error =
                'No supported single-file GGUF weights with checksums found. Split/projector/adapter files are excluded.';
        });
      } else {
        final result = await local.search(text);
        if (!mounted || generation != _generation) return;
        setState(() => repositories = result);
      }
    } catch (e) {
      if (mounted && generation == _generation)
        setState(() => error = e.toString());
    } finally {
      if (mounted && generation == _generation)
        setState(() => searching = false);
    }
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: local,
    builder: (context, _) => Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Local AI models',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'Search/download uses internet. Chat, scans and inventory stay on this device when a local model is selected. No silent external fallback.',
            ),
            const SizedBox(height: 8),
            if (local.hasSelection)
              Text(
                'Selected: ${local.activeLabel}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            Text(local.status, style: Theme.of(context).textTheme.bodySmall),
            if (local.busy || local.transferring) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: local.progress),
              TextButton(
                onPressed: local.transferring
                    ? local.cancelTransfer
                    : local.cancelRequest,
                child: Text(
                  local.transferring
                      ? 'Pause download'
                      : 'Cancel result (native step drains safely)',
                ),
              ),
            ],
            if (local.supported) ...[
              const SizedBox(height: 12),
              TextField(
                controller: query,
                enabled: !searching,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  labelText: 'Search GGUF models or publisher/repository',
                  suffixIcon: IconButton(
                    tooltip: 'Search public models',
                    onPressed: searching ? null : _search,
                    icon: const Icon(Icons.search),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'First 30 search results. Enter an exact repository for new/unlisted models. Android local inference needs arm64 Android 9+. Choose an instruction-tuned single GGUF; not every architecture is compatible.',
                style: TextStyle(fontSize: 11),
              ),
              if (searching) const LinearProgressIndicator(),
              if (repositories.isNotEmpty && files.isEmpty) ...[
                const SizedBox(height: 8),
                SizedBox(
                  height: 180,
                  child: ListView.builder(
                    itemCount: repositories.length,
                    itemBuilder: (context, i) => ListTile(
                      dense: true,
                      title: Text(repositories[i]),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: searching ? null : () => _search(repositories[i]),
                    ),
                  ),
                ),
              ],
              if (files.isNotEmpty)
                SizedBox(
                  height: 240,
                  child: ListView.builder(
                    itemCount: files.length,
                    itemBuilder: (context, i) {
                      final file = files[i];
                      return ListTile(
                        title: Text(
                          file.filename,
                          style: const TextStyle(fontSize: 12),
                        ),
                        subtitle: Text(
                          '${modelSize(file.bytes)} · license: ${file.license}',
                        ),
                        trailing: IconButton(
                          tooltip: 'Download verified weights',
                          onPressed: local.busy || local.transferring
                              ? null
                              : () async {
                                  if (await _confirm(
                                    'Download ${modelSize(file.bytes)}?',
                                    'Review the publisher license (${file.license}). Storage must fit the download. Working RAM is larger than the weight file and depends on context/model architecture. Setup checks are not a pharmacy accuracy benchmark.',
                                  )) {
                                    await _run(() => local.download(file));
                                  }
                                },
                          icon: const Icon(Icons.download_outlined),
                        ),
                      );
                    },
                  ),
                ),
              OutlinedButton.icon(
                onPressed: local.busy || local.transferring
                    ? null
                    : () => _run(local.importModel),
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Import GGUF from device'),
              ),
              const Divider(),
              const Text(
                'Installed models',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              if (local.installed.isEmpty)
                const Text(
                  'No model installed. Model weights are separate from the APK.',
                ),
              for (final model in local.installed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    model.label,
                    style: const TextStyle(fontSize: 12),
                  ),
                  subtitle: Text(
                    '${modelSize(model.bytes)} · ${model.smokeTestPassed ? 'Setup checks passed; review-only' : 'Not tested'}',
                  ),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        tooltip: 'Load, test and activate',
                        onPressed: local.busy || local.transferring
                            ? null
                            : () async {
                                if (await _confirm(
                                  'Activate on this device?',
                                  'This loads ${modelSize(model.bytes)} of weights plus runtime memory. Large models can exhaust RAM. All AI Hub requests and enabled scan reasoning will use this local model. Inventory changes still need review.',
                                )) {
                                  await _run(() => local.activate(model.id));
                                }
                              },
                        icon: Icon(
                          model.id == local.activeId
                              ? Icons.check_circle
                              : Icons.play_circle_outline,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Remove downloaded model',
                        onPressed:
                            local.busy ||
                                local.transferring ||
                                model.id == local.activeId
                            ? null
                            : () async {
                                if (await _confirm(
                                  'Remove model?',
                                  'Only this model file is removed. Pharmacy records stay unchanged. You can download/import it again.',
                                )) {
                                  await _run(() => local.remove(model.id));
                                }
                              },
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Use local AI for scan review'),
                subtitle: const Text(
                  'Once per grouped medicine, not every camera frame. Deterministic OCR remains available.',
                ),
                value: local.scannerEnabled,
                onChanged: local.busy || local.transferring
                    ? null
                    : (v) => _run(() => local.setScannerEnabled(v)),
              ),
              if (local.hasSelection)
                TextButton(
                  onPressed: local.busy || local.transferring
                      ? null
                      : () async {
                          if (await _confirm(
                            'Disable local AI routing?',
                            'Future chat requests will use your existing connected-provider settings, if configured. Disabling does not send any data itself.',
                          )) {
                            await _run(local.deactivate);
                          }
                        },
                  child: const Text('Disable local AI'),
                ),
            ],
            if (error.isNotEmpty)
              SelectableText(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
  );
}
