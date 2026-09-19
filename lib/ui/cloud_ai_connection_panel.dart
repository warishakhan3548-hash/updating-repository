import 'package:flutter/material.dart';

import '../domain/ai_discovered_model.dart';
import '../services/ai_model_discovery_service.dart';
import '../services/ai_service.dart';

/// One provider + key, then a live dropdown. No provider model catalog is
/// hardcoded and credentials never move between providers during edits.
class CloudAiConnectionPanel extends StatefulWidget {
  const CloudAiConnectionPanel({
    super.key,
    required this.initial,
    required this.service,
    required this.localBrainEnabled,
    required this.onSaved,
    required this.onSavingChanged,
    this.blocked = false,
  });
  final AiConfiguration initial;
  final AiService service;
  final bool localBrainEnabled;
  final bool blocked;
  final ValueChanged<AiConfiguration> onSaved;
  final ValueChanged<bool> onSavingChanged;

  @override
  State<CloudAiConnectionPanel> createState() => _CloudAiConnectionPanelState();
}

class _CloudAiConnectionPanelState extends State<CloudAiConnectionPanel> {
  final _discovery = AiModelDiscoveryService();
  final _key = TextEditingController();
  final _endpoint = TextEditingController();
  final _modelsEndpoint = TextEditingController();
  final _manualModel = TextEditingController();
  final _drafts = <String, AiConfiguration>{};
  List<AiDiscoveredModel> _models = [];
  late String _provider;
  String _selected = '';
  AiConfiguration? _verified;
  String _message = '';
  String _error = '';
  bool _auto = true;
  bool _obscure = true;
  bool _loading = false;
  bool _restoring = false;
  bool _saving = false;
  bool _manual = false;
  bool _streamingEnabled = true;
  bool? _jsonModeEnabled;
  int _responseTimeoutSeconds = 90;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _restore(widget.initial);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _key.text.trim().isNotEmpty) _connect();
    });
  }

  void _restore(AiConfiguration config) {
    _verified = null;
    _provider = config.definition.id;
    _key.text = config.key;
    _endpoint.text = config.endpoint;
    _modelsEndpoint.text = config.modelsEndpoint;
    _selected = config.model;
    _manualModel.text = config.model;
    _auto = config.autoSelectModel || config.model.isEmpty;
    _streamingEnabled = config.streamingEnabled;
    _jsonModeEnabled = config.jsonModeEnabled;
    _responseTimeoutSeconds = config.responseTimeoutSeconds;
    _models = config.model.isEmpty
        ? []
        : [AiDiscoveredModel(id: config.model, label: config.model)];
    _manual = false;
    _message = config.key.isEmpty
        ? ''
        : 'Saved selection restored. Refresh to see current models.';
  }

  AiConfiguration get _configuration => AiConfiguration(
    provider: _provider,
    key: _key.text.trim(),
    endpoint: _endpoint.text.trim(),
    modelsEndpoint: _modelsEndpoint.text.trim(),
    model: _manual ? _manualModel.text.trim() : _selected,
    autoSelectModel: !_manual && _auto,
    localBrainEnabled: widget.localBrainEnabled,
    streamingEnabled: _streamingEnabled,
    jsonModeEnabled: _jsonModeEnabled,
    responseTimeoutSeconds: _responseTimeoutSeconds,
  );

  bool _wasVerified(AiConfiguration config) {
    final verified = _verified;
    return verified != null &&
        verified.provider == config.provider &&
        verified.model == config.model &&
        verified.key == config.key &&
        verified.endpoint == config.endpoint &&
        verified.modelsEndpoint == config.modelsEndpoint &&
        verified.streamingEnabled == config.streamingEnabled &&
        verified.useJsonMode == config.useJsonMode &&
        verified.responseTimeoutSeconds == config.responseTimeoutSeconds;
  }

  void _invalidate() {
    _verified = null;
    ++_generation;
    _discovery.cancel();
    setState(() {
      _loading = false;
      _models = [];
      _selected = '';
      _manualModel.clear();
      _message = '';
      _error = '';
    });
  }

  Future<void> _changeProvider(String? value) async {
    if (widget.blocked || _saving || value == null || value == _provider)
      return;
    if (!_restoring) _drafts[_provider] = _configuration;
    final generation = ++_generation;
    _discovery.cancel();
    setState(() {
      _restore(AiConfiguration(provider: value));
      _loading = false;
      _restoring = true;
      _error = '';
    });
    try {
      final config =
          _drafts[value] ??
          await widget.service.loadProviderConfiguration(value);
      if (!mounted || generation != _generation) return;
      setState(() {
        if (config != null) _restore(config);
        _restoring = false;
      });
      // Restored keys may fetch the catalog; this performs no inference.
      if (_key.text.trim().isNotEmpty) await _connect();
    } catch (_) {
      if (mounted && generation == _generation)
        setState(() {
          _restoring = false;
          _error =
              'Could not read this saved connection. Re-enter its API key.';
        });
    }
  }

  Future<void> _connect() async {
    if (widget.blocked || _saving || _restoring) return;
    final config = _configuration;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _message = '';
      _error = '';
    });
    try {
      final models = await _discovery.discover(config);
      if (!mounted || generation != _generation) return;
      final kept = models.any((m) => m.id == config.model);
      setState(() {
        _models = models;
        _selected = _auto
            ? (AiDiscoveredModel.choose(models, config.model)?.id ?? '')
            : (kept ? config.model : '');
        _manual = false;
        _message = models.isEmpty
            ? 'No compatible text models were listed for this connection.'
            : '${models.length} text model candidates found. Test checks your key’s access.';
        if (!_auto && config.model.isNotEmpty && !kept) {
          _message += ' Your saved model is no longer listed. Choose another.';
        }
      });
    } catch (error) {
      if (mounted && generation == _generation)
        setState(() => _error = _safeError(error));
    } finally {
      if (mounted && generation == _generation)
        setState(() => _loading = false);
    }
  }

  String _safeError(Object error) => error is AiConnectionFailure
      ? error.message
      : error is FormatException
      ? error.message
      : 'Connection could not be completed. Check the settings and retry.';

  Future<void> _test({required bool save}) async {
    if (widget.blocked || _saving || _loading || _restoring) return;
    final config = _configuration;
    final generation = ++_generation;
    setState(() {
      _saving = true;
      _error = '';
      _message = '';
    });
    widget.onSavingChanged(true);
    try {
      // Save reuses a successful probe only for this exact edited connection.
      // Explicit Test always probes again; any connection edit invalidates it.
      if (!save || !_wasVerified(config)) {
        await _discovery.testModel(config);
        if (!mounted || generation != _generation) return;
        _verified = config;
      }
      if (!mounted || generation != _generation) return;
      if (save) {
        await widget.service.saveConfiguration(config);
        if (!mounted || generation != _generation) return;
        widget.onSavingChanged(false);
        widget.onSaved(config);
      } else {
        setState(
          () => _message =
              'Model replied successfully. Save to use this connection.',
        );
      }
    } catch (error) {
      if (mounted && generation == _generation)
        setState(() => _error = _safeError(error));
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _saving = false);
        widget.onSavingChanged(false);
      }
    }
  }

  Future<void> _remove() async {
    if (widget.blocked || _saving) return;
    ++_generation;
    _discovery.cancel();
    setState(() {
      _saving = true;
      _loading = false;
      _error = '';
    });
    widget.onSavingChanged(true);
    try {
      await widget.service.forgetKey();
      final saved = await widget.service.loadConfiguration();
      if (!mounted) return;
      widget.onSavingChanged(false);
      widget.onSaved(saved);
    } catch (_) {
      if (mounted)
        setState(
          () => _error = 'Could not remove the saved key. Please retry.',
        );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        widget.onSavingChanged(false);
      }
    }
  }

  @override
  void dispose() {
    ++_generation;
    _discovery.cancel();
    _key.dispose();
    _endpoint.dispose();
    _modelsEndpoint.dispose();
    _manualModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final custom = AiProviderDefinition.forId(_provider).isCustom;
    final editable = !widget.blocked && !_saving && !_restoring;
    final canTest =
        editable &&
        !_loading &&
        _configuration.model.isNotEmpty &&
        _key.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: ValueKey('provider-$_provider'),
            initialValue: _provider,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Provider'),
            items: AiProviderDefinition.values
                .map(
                  (p) => DropdownMenuItem(
                    value: p.id,
                    child: Text(p.label, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: widget.blocked || _saving ? null : _changeProvider,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _key,
            enabled: editable,
            obscureText: _obscure,
            enableSuggestions: false,
            autocorrect: false,
            onChanged: (_) => _invalidate(),
            decoration: InputDecoration(
              labelText: 'API key',
              helperText: 'Saved securely on this device for this provider.',
              helperMaxLines: 2,
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Show API key' : 'Hide API key',
                onPressed: editable
                    ? () => setState(() => _obscure = !_obscure)
                    : null,
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              ),
            ),
          ),
          if (custom) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _endpoint,
              enabled: editable,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: (_) => _invalidate(),
              decoration: const InputDecoration(
                labelText: 'HTTPS base URL or chat endpoint',
              ),
            ),
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: editable && !_loading ? _connect : null,
            icon: _loading || _restoring
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            label: Text(
              _restoring
                  ? 'Restoring saved connection…'
                  : _loading
                  ? 'Loading models…'
                  : _models.isEmpty
                  ? 'Connect & load models'
                  : 'Refresh models',
            ),
          ),
          if (_models.isNotEmpty && !_manual) ...[
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              key: ValueKey(
                'model-$_provider-$_auto-$_selected-${_models.length}',
              ),
              initialValue: _auto
                  ? '\u0000auto'
                  : _selected.isEmpty
                  ? null
                  : _selected,
              isExpanded: true,
              menuMaxHeight: 340,
              decoration: const InputDecoration(labelText: 'Choose model'),
              items: [
                const DropdownMenuItem(
                  value: '\u0000auto',
                  child: Text('Auto — choose an available model'),
                ),
                ..._models.map(
                  (m) => DropdownMenuItem(
                    value: m.id,
                    child: Text(
                      m.label == m.id ? m.id : '${m.label} · ${m.id}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              onChanged: editable && !_loading
                  ? (value) => setState(() {
                      _auto = value == '\u0000auto';
                      _selected = _auto
                          ? (AiDiscoveredModel.choose(_models, _selected)?.id ??
                                '')
                          : value ?? '';
                      _error = '';
                      _message = '';
                    })
                  : null,
            ),
            if (_auto && _selected.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Selected: $_selected',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text(
              'Advanced / manual setup',
              style: TextStyle(fontSize: 13),
            ),
            children: [
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Stream replies'),
                value: _streamingEnabled,
                onChanged: editable
                    ? (value) => setState(() => _streamingEnabled = value)
                    : null,
              ),
              if (_configuration.protocol !=
                  AiProviderProtocol.anthropicMessages)
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Provider supports JSON mode'),
                  subtitle: const Text(
                    'For structured scans. Chat replies normally. Turn off if this model rejects JSON mode.',
                  ),
                  value: _configuration.useJsonMode,
                  onChanged: editable
                      ? (value) => setState(() => _jsonModeEnabled = value)
                      : null,
                ),
              if (custom)
                TextField(
                  controller: _modelsEndpoint,
                  enabled: editable,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onChanged: (_) => _invalidate(),
                  decoration: const InputDecoration(
                    labelText: 'Models URL (optional)',
                    helperText: 'For gateways with a custom discovery path.',
                    helperMaxLines: 2,
                  ),
                ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Enter model manually'),
                subtitle: const Text(
                  'Only if your provider does not offer model discovery.',
                ),
                value: _manual,
                onChanged: editable && !_loading
                    ? (value) => setState(() {
                        _manual = value;
                        _manualModel.text = _selected;
                        _message = '';
                        _error = '';
                      })
                    : null,
              ),
              if (_manual)
                TextField(
                  controller: _manualModel,
                  enabled: editable,
                  autocorrect: false,
                  onChanged: (_) => setState(() {
                    _error = '';
                    _message = '';
                  }),
                  decoration: const InputDecoration(labelText: 'Model ID'),
                ),
            ],
          ),
          if (_message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                _message,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                _error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const Text(
            'Testing sends a small sample request and may use API credits.',
            style: TextStyle(fontSize: 11),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: canTest ? () => _test(save: false) : null,
                child: const Text('Test model'),
              ),
              FilledButton.icon(
                onPressed: canTest ? () => _test(save: true) : null,
                icon: const Icon(Icons.lock_outline),
                label: Text(
                  _saving
                      ? 'Saving connection…'
                      : _wasVerified(_configuration)
                      ? 'Save connection'
                      : 'Test & save',
                ),
              ),
            ],
          ),
          if (widget.initial.key.isNotEmpty)
            TextButton(
              onPressed: widget.blocked || _saving ? null : _remove,
              child: Text('Remove saved ${widget.initial.providerLabel} key'),
            ),
        ],
      ),
    );
  }
}
