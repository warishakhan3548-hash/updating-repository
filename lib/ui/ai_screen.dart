import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../domain/ai_protocol.dart';
import '../domain/medicine.dart';
import '../services/ai_service.dart';
import '../state/pharmacy_controller.dart';
import 'design.dart';

class AiScreen extends StatefulWidget {
  const AiScreen({super.key, required this.controller});
  final PharmacyController controller;
  @override
  State<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends State<AiScreen> {
  final _service = AiService();
  final _input = TextEditingController(), _request = TextEditingController();
  AiConfiguration _configuration = const AiConfiguration();
  AiPlan? _plan;
  Set<int> _selected = {};
  String _error = '', _notice = '';
  bool _requesting = false, _sharing = false, _reviewing = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final config = await _service.loadConfiguration();
      if (mounted) setState(() => _configuration = config);
    } catch (_) {}
  }

  @override
  void dispose() {
    ++_generation;
    _service.cancel();
    if (widget.controller.aiPreparing) widget.controller.cancelAi();
    _input.dispose();
    _request.dispose();
    super.dispose();
  }

  Future<void> _configure() async {
    final config = await Navigator.push<AiConfiguration>(
      context,
      MaterialPageRoute(
        builder: (_) => _ApiSetup(initial: _configuration, service: _service),
      ),
    );
    if (config != null && mounted) setState(() => _configuration = config);
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final data = widget.controller.export();
      await sharePharmacy(data);
      if (mounted)
        setState(
          () => _notice =
              'Prompt copied. Share the TXT with your AI, then bring its JSON back here.',
        );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _review() async {
    if (_reviewing) return;
    setState(() => _reviewing = true);
    try {
      await Future<void>.delayed(Duration.zero);
      final plan = widget.controller.review(_input.text);
      if (mounted)
        setState(() {
          _plan = plan;
          _selected = {
            for (var i = 0; i < plan.changes.length; i++)
              if (plan.changes[i].possibleDuplicates.isEmpty &&
                  plan.changes[i].operation != 'remove')
                i,
          };
          _error = '';
        });
    } catch (e) {
      if (mounted)
        setState(() {
          _plan = null;
          _error = e.toString().replaceFirst('FormatException: ', '');
        });
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
  }

  Future<void> _ask() async {
    if (_requesting) return;
    if (_configuration.key.isEmpty) {
      await _configure();
      return;
    }
    final generation = ++_generation;
    setState(() {
      _requesting = true;
      _error = '';
      _plan = null;
    });
    try {
      final result = await _service.ask(
        _configuration,
        widget.controller.export(),
        _request.text,
      );
      if (!mounted || generation != _generation) return;
      _input.text = result;
      await _review();
    } catch (e) {
      if (mounted && generation == _generation)
        setState(
          () => _error = e is TimeoutException
              ? 'The AI took too long. No inventory changes were made.'
              : e.toString().replaceFirst('Bad state: ', ''),
        );
    } finally {
      if (mounted && generation == _generation)
        setState(() => _requesting = false);
    }
  }

  Future<void> _apply() async {
    final plan = _plan;
    if (plan == null || _selected.isEmpty) return;
    try {
      await widget.controller.applyAi(plan, _selected);
      if (mounted)
        setState(() {
          _notice =
              '${_selected.length} reviewed changes saved. All inventory views are updated.';
          _plan = null;
          _input.clear();
          _selected = {};
        });
    } catch (e) {
      if (mounted)
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.fromLTRB(22, 26, 22, 30),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'AI Controller',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: lime,
                borderRadius: BorderRadius.circular(15),
              ),
              child: const Icon(Icons.auto_awesome, color: ink),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'A second pair of eyes.\nYou stay in control of every change.',
          style: TextStyle(color: muted, fontSize: 15),
        ),
        const SizedBox(height: 24),
        Surface(
          color: ink,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.open_in_new_rounded, color: lime, size: 28),
              const SizedBox(height: 16),
              const Text(
                'Bring your favourite AI',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Share only your pharmacy inventory as a TXT file. A ready-to-use prompt is copied with it.',
                style: TextStyle(fontSize: 13, color: Color(0xFFC5D8CC)),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: lime,
                  foregroundColor: ink,
                ),
                onPressed: _sharing ? null : _share,
                icon: const Icon(Icons.ios_share_rounded),
                label: Text(_sharing ? 'Preparing…' : 'Connect with Other AI'),
              ),
            ],
          ),
        ),
        const SectionHeading('Or connect your own API'),
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.key_rounded, color: green),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _configuration.key.isEmpty
                          ? 'Your provider, your key'
                          : '${_configuration.provider} · ${_configuration.model}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Configure AI provider',
                    onPressed: _requesting ? null : _configure,
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Gemini or an OpenAI-compatible HTTPS endpoint. Keys are stored securely on this device.',
                style: TextStyle(fontSize: 12, color: muted),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _request,
                minLines: 2,
                maxLines: 5,
                maxLength: 6000,
                decoration: const InputDecoration(
                  hintText:
                      'What would you like to manage?\n“Find stock to reorder” or “organize these new medicines…”',
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Sending shares pharmacy fields and notes with your chosen provider. Provider charges may apply.',
                style: TextStyle(fontSize: 11, color: muted),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _requesting ? null : _ask,
                    icon: const Icon(Icons.arrow_upward_rounded),
                    label: Text(
                      _requesting
                          ? 'Waiting for AI…'
                          : _configuration.key.isEmpty
                          ? 'Set up API'
                          : 'Send pharmacy request',
                    ),
                  ),
                  if (_requesting)
                    TextButton(
                      onPressed: () {
                        ++_generation;
                        _service.cancel();
                        setState(() => _requesting = false);
                      },
                      child: const Text('Cancel'),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SectionHeading('Bring back the result'),
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Paste AI JSON',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const SizedBox(height: 8),
              const Text(
                'Nothing changes until you review and apply it.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _input,
                minLines: 4,
                maxLines: 9,
                maxLength: 1000000,
                decoration: const InputDecoration(
                  hintText: 'Paste the complete pharmacy response here',
                  counterText: '',
                ),
                onChanged: (_) => setState(() => _plan = null),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final data = await Clipboard.getData(
                        Clipboard.kTextPlain,
                      );
                      if (mounted) {
                        _input.text = data?.text ?? '';
                        setState(() => _plan = null);
                      }
                    },
                    icon: const Icon(Icons.content_paste_rounded),
                    label: const Text('Paste'),
                  ),
                  FilledButton.icon(
                    onPressed: _reviewing ? null : _review,
                    icon: const Icon(Icons.fact_check_outlined),
                    label: Text(_reviewing ? 'Checking…' : 'Review result'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Surface(
              color: const Color(0xFFFFEDEA),
              child: SelectableText(_error, style: const TextStyle(color: red)),
            ),
          ),
        if (_notice.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Surface(
              color: const Color(0xFFEAF3DE),
              child: Text(_notice),
            ),
          ),
        if (_plan != null) ...[
          SectionHeading('${_plan!.changes.length} proposed changes'),
          if (_plan!.reply.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(_plan!.reply),
            ),
          if (_plan!.changes.isEmpty)
            const StatusPill('Answer only · no inventory changes'),
          for (var i = 0; i < _plan!.changes.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Surface(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CheckboxListTile(
                      value: _selected.contains(i),
                      onChanged: widget.controller.aiPreparing
                          ? null
                          : (value) => setState(
                              () => value == true
                                  ? _selected.add(i)
                                  : _selected.remove(i),
                            ),
                      title: Text(_plan!.changes[i].title),
                      subtitle: Text(
                        _operationLabel(_plan!.changes[i].operation),
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                    ),
                    if (_plan!.changes[i].possibleDuplicates.isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 14),
                        child: Text(
                          'Possible existing medicine. Check its expiry and location before adding separate stock.',
                          style: TextStyle(color: amber, fontSize: 12),
                        ),
                      ),
                    ExpansionTile(
                      title: const Text(
                        'See changes',
                        style: TextStyle(fontSize: 13),
                      ),
                      children: [
                        for (final entry
                            in _plan!.changes[i].differences.entries)
                          if (entry.key != 'id')
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  '${_fieldLabel(entry.key)}\n${_value(entry.key, entry.value['before'])} → ${_value(entry.key, entry.value['after'])}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: muted,
                                  ),
                                ),
                              ),
                            ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (widget.controller.aiPreparing) ...[
            LinearProgressIndicator(
              value:
                  widget.controller.preparedActions /
                  (_plan!.changes.isEmpty ? 1 : _plan!.changes.length),
            ),
            const SizedBox(height: 12),
            Text(
              'Prepared ${widget.controller.preparedActions} of ${_plan!.changes.length}. Saving is atomic.',
            ),
            TextButton(
              onPressed: widget.controller.cancelAi,
              child: const Text('Cancel before saving'),
            ),
          ],
          if (_plan!.changes.isNotEmpty)
            FilledButton.icon(
              onPressed: widget.controller.aiPreparing || _selected.isEmpty
                  ? null
                  : _apply,
              icon: const Icon(Icons.check_circle_outline_rounded),
              label: Text('Apply ${_selected.length} selected changes'),
            ),
          if (_plan!.changes.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                'Unselected changes will not be applied. A new request is needed for later changes.',
                style: TextStyle(fontSize: 11, color: muted),
              ),
            ),
        ],
      ],
    ),
  );
}

String _operationLabel(String operation) =>
    {
      'add': 'Add new stock',
      'update': 'Edit existing stock',
      'remove': 'Remove from inventory',
      'mark_sold': 'Mark out of stock · reorder',
      'restock': 'Restock medicine',
    }[operation] ??
    operation;
String _fieldLabel(String key) =>
    {
      'unitPricePaise': 'Unit price',
      'soldUnitPricePaise': 'Price when marked sold',
      'soldQuantity': 'Quantity when marked sold',
      'ocrText': 'Scanned text',
      'mfg': 'Manufacturing date',
      'soldAt': 'Marked sold at',
    }[key] ??
    key;
String _value(String key, dynamic value) => value == null || value == ''
    ? 'Not provided'
    : key.toLowerCase().contains('price') && value is int
    ? money(value)
    : '$value';

class _ApiSetup extends StatefulWidget {
  const _ApiSetup({required this.initial, required this.service});
  final AiConfiguration initial;
  final AiService service;
  @override
  State<_ApiSetup> createState() => _ApiSetupState();
}

class _ApiSetupState extends State<_ApiSetup> {
  late String provider = widget.initial.provider;
  late final model = TextEditingController(text: widget.initial.model),
      endpoint = TextEditingController(text: widget.initial.endpoint),
      key = TextEditingController(text: widget.initial.key);
  String error = '';
  bool busy = false;
  @override
  void dispose() {
    model.dispose();
    endpoint.dispose();
    key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Connect your AI API')),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        const Text(
          'Your API key stays in secure device storage and is never included in inventory exports.',
          style: TextStyle(color: muted),
        ),
        const SizedBox(height: 22),
        DropdownButtonFormField<String>(
          initialValue: provider,
          decoration: const InputDecoration(labelText: 'API format'),
          items: const [
            DropdownMenuItem(value: 'Gemini', child: Text('Google Gemini')),
            DropdownMenuItem(
              value: 'Compatible',
              child: Text('OpenAI-compatible'),
            ),
          ],
          onChanged: (v) => setState(() => provider = v!),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: model,
          decoration: const InputDecoration(
            labelText: 'Model name',
            hintText: 'Enter a model available with your provider',
          ),
        ),
        const SizedBox(height: 16),
        if (provider == 'Compatible') ...[
          TextField(
            controller: endpoint,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Full HTTPS chat/completions endpoint',
              hintText: 'https://your-provider.example/v1/chat/completions',
            ),
          ),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: key,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'API key'),
        ),
        const SizedBox(height: 22),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(error, style: const TextStyle(color: red)),
          ),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() => busy = true);
                  try {
                    final config = AiConfiguration(
                      provider: provider,
                      model: model.text.trim(),
                      endpoint: endpoint.text.trim(),
                      key: key.text.trim(),
                    );
                    await widget.service.saveConfiguration(config);
                    if (context.mounted) Navigator.pop(context, config);
                  } catch (e) {
                    if (mounted) setState(() => error = e.toString());
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: const Text('Save connection'),
        ),
        TextButton(
          onPressed: busy
              ? null
              : () async {
                  try {
                    await widget.service.forgetKey();
                    if (context.mounted)
                      Navigator.pop(context, const AiConfiguration());
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
          child: const Text('Remove saved key'),
        ),
      ],
    ),
  );
}
