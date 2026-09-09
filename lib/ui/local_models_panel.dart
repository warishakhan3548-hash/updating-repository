import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/default_local_model.dart';
import '../services/aaris_default_ai_service.dart';
import '../services/local_ai_service.dart';

/// Embedded in the existing AI connections sheet, never a second AI Hub.
class LocalModelsPanel extends StatefulWidget {
  const LocalModelsPanel({super.key});
  @override
  State<LocalModelsPanel> createState() => _LocalModelsPanelState();
}

class _LocalModelsPanelState extends State<LocalModelsPanel> {
  final local = LocalAiService.instance;
  final defaults = AarisDefaultAiService.instance;
  final query = TextEditingController();
  List<String> repositories = [];
  List<LocalModelFile> files = [];
  String error = '', catalogueNote = '';
  ModelSort sort = ModelSort.popular;
  Uri? nextPage;
  String _lastQuery = '';
  int? maxFileBytes;
  final _seenPages = <String>{};
  bool searching = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(
      _run(() async {
        await local.initialize();
        await defaults.initialize();
      }),
    );
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
    final text = repository ?? query.text.trim();
    setState(() {
      searching = true;
      error = '';
      catalogueNote = '';
      files = [];
      repositories = [];
      nextPage = null;
      _seenPages.clear();
    });
    try {
      final location = ModelRepositoryLocation.parse(text);
      if (location != null) {
        final result = await local.repositoryFiles(text);
        if (!mounted || generation != _generation) return;
        setState(() {
          files = result.files;
          catalogueNote = [
            if (result.cached)
              'Cached public metadata; download stays revision-pinned.',
            if (result.gated)
              'Publisher access restrictions apply. Import an authorized local copy if needed.',
            for (final entry in result.unavailable.entries)
              '${entry.value} × ${entry.key}',
            if (files.isEmpty)
              'No downloadable complete GGUF weights found. Check the publisher files or import from device.',
          ].join('\n');
        });
      } else {
        _lastQuery = text;
        final result = await local.searchPage(text, sort: sort);
        if (!mounted || generation != _generation) return;
        setState(() {
          repositories = result.repositories;
          nextPage = result.next;
          catalogueNote = result.cached ? 'Cached public search results.' : '';
          if (repositories.isEmpty)
            catalogueNote =
                'No matching models. Try a family name or an exact repository link.';
        });
      }
    } catch (e) {
      if (mounted && generation == _generation)
        setState(() => error = e.toString());
    } finally {
      if (mounted && generation == _generation)
        setState(() => searching = false);
    }
  }

  Future<void> _more() async {
    final cursor = nextPage;
    if (cursor == null || searching) return;
    final generation = ++_generation;
    setState(() {
      searching = true;
      error = '';
    });
    try {
      final result = await local.searchPage(
        _lastQuery,
        sort: sort,
        cursor: cursor,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _seenPages.add(cursor.toString());
        repositories = {...repositories, ...result.repositories}.toList();
        // Keep the phone UI bounded; start a more specific search after 500.
        nextPage =
            repositories.length >= 500 ||
                _seenPages.contains(result.next.toString())
            ? null
            : result.next;
        if (repositories.length >= 500)
          catalogueNote =
              '500 results loaded. Narrow the search to explore further.';
      });
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

  Widget _defaultAiCard(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 12, bottom: 14),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primaryContainer.withAlpha(70),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: Theme.of(context).colorScheme.primary.withAlpha(45),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              defaults.active
                  ? Icons.offline_bolt_rounded
                  : Icons.memory_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 9),
            const Expanded(
              child: Text(
                'Aaris Default Local AI',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
              ),
            ),
            if (defaults.active)
              const Chip(
                visualDensity: VisualDensity.compact,
                label: Text('Active'),
              ),
          ],
        ),
        const SizedBox(height: 7),
        Text(
          defaults.hasDefault
              ? defaults.status
              : 'Recommended one-time ~$aarisDefaultModelDownloadHint download. User-selected models can override it; without it Aaris keeps using the offline pharmacy scanner.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: local.busy || local.transferring || defaults.busy
              ? null
              : defaults.active
              ? null
              : () async {
                  final proceed = await _confirm(
                    defaults.hasDefault
                        ? 'Use Aaris Default AI?'
                        : 'Download Aaris Default AI?',
                    defaults.hasDefault
                        ? 'This switches from the current local model back to the remembered Aaris default. Existing inventory is unchanged.'
                        : 'This is an explicit ~$aarisDefaultModelDownloadHint internet download. It is verified and activation-tested on this device. If setup fails, the existing offline scanner remains available.',
                  );
                  if (proceed) await _run(defaults.installAndActivate);
                },
          icon: Icon(
            defaults.hasDefault
                ? Icons.play_circle_outline_rounded
                : Icons.download_rounded,
          ),
          label: Text(
            defaults.active
                ? 'Default AI active'
                : defaults.hasDefault
                ? 'Use default AI'
                : 'Download & activate default',
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([local, defaults]),
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
            _defaultAiCard(context),
            if (local.hasSelection)
              Text(
                'Selected: ${local.activeLabel}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            Text(local.status, style: Theme.of(context).textTheme.bodySmall),
            if (local.executionSummary.isNotEmpty)
              Text(
                local.executionSummary,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (local.busy || local.transferring) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: local.progress),
              TextButton(
                onPressed: local.transferring
                    ? local.cancelTransfer
                    : local.cancelRequest,
                child: Text(
                  local.transferring
                      ? 'Pause download / cancel import'
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
                  labelText: 'Model name, publisher/repository or Hub link',
                  suffixIcon: IconButton(
                    tooltip: 'Search public models',
                    onPressed: searching ? null : _search,
                    icon: const Icon(Icons.search),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Browse current public GGUF models or paste an exact link, including new or untagged repositories. A downloadable file still needs a successful device activation test.',
                style: TextStyle(fontSize: 11),
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final option in ModelSort.values)
                    ChoiceChip(
                      label: Text(option.label),
                      selected: sort == option,
                      onSelected: searching
                          ? null
                          : (_) {
                              setState(() => sort = option);
                              unawaited(_search());
                            },
                    ),
                ],
              ),
              if (catalogueNote.isNotEmpty)
                Text(
                  catalogueNote,
                  style: Theme.of(context).textTheme.bodySmall,
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
              if (nextPage != null)
                TextButton(
                  onPressed: searching ? null : _more,
                  child: const Text('Load more models'),
                ),
              if (files.isNotEmpty) ...[
                Wrap(
                  spacing: 8,
                  children: [
                    for (final limit in <int?>[
                      null,
                      1024 * 1024 * 1024,
                      2 * 1024 * 1024 * 1024,
                      4 * 1024 * 1024 * 1024,
                    ])
                      ChoiceChip(
                        label: Text(
                          limit == null
                              ? 'All sizes'
                              : 'Up to ${modelSize(limit)}',
                        ),
                        selected: maxFileBytes == limit,
                        onSelected: (_) => setState(() => maxFileBytes = limit),
                      ),
                  ],
                ),
                const Text(
                  'Weight-file size filter only; working RAM is checked separately.',
                  style: TextStyle(fontSize: 11),
                ),
                if (!files.any(
                  (f) => maxFileBytes == null || f.bytes <= maxFileBytes!,
                ))
                  const Text(
                    'No files within this size. Choose All sizes or another repository.',
                  ),
                SizedBox(
                  height: 240,
                  child: ListView.builder(
                    itemCount: files
                        .where(
                          (f) =>
                              maxFileBytes == null || f.bytes <= maxFileBytes!,
                        )
                        .length,
                    itemBuilder: (context, i) {
                      final file = files
                          .where(
                            (f) =>
                                maxFileBytes == null ||
                                f.bytes <= maxFileBytes!,
                          )
                          .elementAt(i);
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
              ],
              OutlinedButton.icon(
                onPressed: local.busy || local.transferring
                    ? null
                    : () => _run(local.importModel),
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Import GGUF from device'),
              ),
              const Divider(),
              if (local.pendingDownloads.isNotEmpty) ...[
                const Text(
                  'Paused / unfinished downloads',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                for (final pending in local.pendingDownloads)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      pending.label,
                      style: const TextStyle(fontSize: 12),
                    ),
                    subtitle: Text(
                      '${modelSize(pending.bytes)} · resume from verified revision',
                    ),
                    trailing: Wrap(
                      children: [
                        IconButton(
                          tooltip: 'Resume download',
                          icon: const Icon(Icons.download),
                          onPressed: local.busy || local.transferring
                              ? null
                              : () => _run(() => local.download(pending)),
                        ),
                        IconButton(
                          tooltip: 'Remove partial download',
                          icon: const Icon(Icons.close),
                          onPressed: local.busy || local.transferring
                              ? null
                              : () async {
                                  if (await _confirm(
                                    'Remove partial download?',
                                    'Only unfinished weights are removed.',
                                  )) {
                                    await _run(
                                      () =>
                                          local.discardDownload(pending.sha256),
                                    );
                                  }
                                },
                        ),
                      ],
                    ),
                  ),
              ],
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
                    defaults.defaultId == model.id
                        ? 'Aaris Default AI · ${model.label}'
                        : model.label,
                    style: const TextStyle(fontSize: 12),
                  ),
                  subtitle: Text(
                    '${modelSize(model.bytes)} · ${model.metadata?.architecture ?? 'Inspect on activation'} · ${model.smokeTestPassed ? 'Setup checks passed; review-only' : 'Not tested'}',
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
                          final hasPersistentDefault = defaults.hasDefault;
                          if (await _confirm(
                            hasPersistentDefault
                                ? 'Pause local AI routing?'
                                : 'Disable local AI routing?',
                            hasPersistentDefault
                                ? 'The downloaded Aaris Default AI is a persistent fallback and will be restored on the next AI/capture request. To switch permanently to cloud-only behavior, disable here and then remove the default model before leaving settings.'
                                : 'Future chat requests will use your existing connected-provider settings, if configured. Disabling does not send any data itself.',
                          )) {
                            await _run(local.deactivate);
                          }
                        },
                  child: Text(
                    defaults.hasDefault
                        ? 'Pause local AI'
                        : 'Disable local AI',
                  ),
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
