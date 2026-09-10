from pathlib import Path
import re


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 exact match, found {count}")
    return text.replace(old, new, 1)


brain_path = Path("lib/ui/brain_screen.dart")
brain = brain_path.read_text()
brain = replace_once(
    brain,
    "import 'voice_sheet.dart';\n",
    "",
    "remove duplicate Brain voice import",
)
brain = replace_once(
    brain,
    "  final _command = TextEditingController();\n  bool _busy = false, _voiceOpening = false;\n",
    "  bool _busy = false;\n",
    "remove duplicate Brain input state",
)

brain_runner = r'''
  Future<String?> _handleUnifiedCommand(String raw) async {
    if (_busy) return 'Aaris is finishing the previous local command.';
    final text = raw.trim();
    if (text.isEmpty) return null;

    // With no pending exact-row clarification, only deterministic App Brain
    // intents are intercepted here. Unknown text falls straight through to the
    // existing AI/JSON composer, so one field safely serves both engines.
    final preParsed = _pendingChoice == null ? parseAppBrainIntent(text) : null;
    if (preParsed?.action == AppBrainAction.unknown) return null;

    if (mounted) {
      setState(() {
        _busy = true;
        _reply = 'Understanding local command…';
      });
    }
    try {
      if (await _continuePendingChoice(text)) return _reply;
      final intent = preParsed ?? parseAppBrainIntent(text);
      if (intent.action == AppBrainAction.unknown) return null;
      await _execute(intent, text);
      return _reply;
    } catch (error) {
      final message = error.toString().replaceFirst(
        RegExp(r'^(FormatException|Bad state|StateError):\s*'),
        '',
      );
      if (mounted) setState(() => _reply = message);
      return message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _continuePendingChoice'''
brain, count = re.subn(
    r"\n  @override\n  void dispose\(\) \{\n    _command\.dispose\(\);\n    super\.dispose\(\);\n  \}\n\n  Future<void> _run\(\[String\? supplied\]\) async \{.*?\n  \}\n\n  Future<bool> _continuePendingChoice",
    "\n" + brain_runner,
    brain,
    count=1,
    flags=re.S,
)
if count != 1:
    raise SystemExit(
        f"replace Brain duplicate composer runner: expected 1 match, found {count}"
    )

quick_methods = r'''
  Future<String?> _handleQuickAction(AiHubQuickAction action) async {
    return switch (action) {
      AiHubQuickAction.sold => _handleUnifiedCommand('sold medicines dikhao'),
      AiHubQuickAction.removed => _handleUnifiedCommand('removed stock dikhao'),
      AiHubQuickAction.stockSummary => _handleUnifiedCommand('stock summary'),
      AiHubQuickAction.add => _handleUnifiedCommand('add medicine'),
      AiHubQuickAction.delete =>
        _openQuickTargetPicker(AppBrainAction.removeMedicine),
      AiHubQuickAction.modify =>
        _openQuickTargetPicker(AppBrainAction.editMedicine),
    };
  }

  Future<String?> _openQuickTargetPicker(AppBrainAction action) async {
    if (_busy) return 'Aaris is finishing the previous local command.';
    if (action != AppBrainAction.removeMedicine &&
        action != AppBrainAction.editMedicine) {
      return null;
    }
    if (mounted) {
      setState(() {
        _busy = true;
        _reply = action == AppBrainAction.removeMedicine
            ? 'Choose the exact medicine to delete. The protected Remove review remains mandatory.'
            : 'Choose the exact medicine to modify.';
      });
    }
    try {
      final hits = await widget.controller.search('', SearchScope.all);
      if (!mounted) return null;
      if (hits.isEmpty) {
        setState(() => _reply = 'No active medicine is available for this action.');
        return _reply;
      }
      await _showMatches(
        hits,
        title: action == AppBrainAction.removeMedicine
            ? 'Choose medicine to delete'
            : 'Choose medicine to modify',
        emptyReply: 'No active medicine is available for this action.',
        action: action,
      );
      return _reply;
    } catch (error) {
      final message = error.toString().replaceFirst(
        RegExp(r'^(FormatException|Bad state|StateError):\s*'),
        '',
      );
      if (mounted) setState(() => _reply = message);
      return message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

'''
brain = replace_once(
    brain,
    "  String _editorInstruction(\n",
    quick_methods + "  String _editorInstruction(\n",
    "inject unified quick actions",
)

brain_tail = r'''
  @override
  Widget build(BuildContext context) => AiScreen(
    controller: widget.controller,
    onLocalCommand: _handleUnifiedCommand,
    onQuickAction: _handleQuickAction,
  );
}
'''
brain, count = re.subn(
    r"\n  Future<void> _voice\(\) async \{.*?\nclass _QuickCommand \{\n  const _QuickCommand\(this\.label, this\.command\);\n  final String label, command;\n\}\n?\Z",
    "\n" + brain_tail,
    brain,
    count=1,
    flags=re.S,
)
if count != 1:
    raise SystemExit(f"remove duplicate top Brain UI: expected 1 match, found {count}")
brain_path.write_text(brain)


ai_path = Path("lib/ui/ai_screen.dart")
ai = ai_path.read_text()
ai = replace_once(
    ai,
    "class AiScreen extends StatefulWidget {\n  const AiScreen({super.key, required this.controller});\n\n  final PharmacyController controller;\n",
    "enum AiHubQuickAction { sold, removed, stockSummary, add, delete, modify }\n\n"
    "class AiScreen extends StatefulWidget {\n"
    "  const AiScreen({\n"
    "    super.key,\n"
    "    required this.controller,\n"
    "    this.onLocalCommand,\n"
    "    this.onQuickAction,\n"
    "  });\n\n"
    "  final PharmacyController controller;\n"
    "  final Future<String?> Function(String command)? onLocalCommand;\n"
    "  final Future<String?> Function(AiHubQuickAction action)? onQuickAction;\n",
    "extend AI hub with unified callbacks",
)
ai, count = re.subn(
    r"  final List<_AiChatMessage> _messages = const \[.*?\n  \]\.toList\(\);",
    "  final List<_AiChatMessage> _messages = [];",
    ai,
    count=1,
    flags=re.S,
)
if count != 1:
    raise SystemExit(f"remove long AI intro paragraph: expected 1 match, found {count}")
ai = replace_once(
    ai,
    "  bool _requesting = false;\n  bool _preparingRequest = false;\n",
    "  bool _requesting = false;\n  bool _preparingRequest = false;\n  bool _localCommanding = false;\n",
    "add local command busy state",
)

send_composer = r'''  Future<void> _sendComposer() async {
    if (_localCommanding ||
        _requesting ||
        _reviewing ||
        widget.controller.aiPreparing) {
      return;
    }
    final text = _request.text.trim();
    if (text.isEmpty) return;

    // JSON keeps the existing review/import path. Ordinary text is offered to
    // the deterministic local App Brain first; only unrecognized text reaches
    // the configured AI provider. No second composer or command state machine.
    if (_looksLikeAiResponse(text)) {
      setState(() {
        _input.text = text;
        _request.clear();
        _externalReady = false;
        _messages.add(
          const _AiChatMessage('External AI response pasted for review.', true),
        );
        _error = '';
      });
      _scrollToEnd();
      await _review();
      return;
    }

    final localHandler = widget.onLocalCommand;
    if (localHandler != null) {
      String? localReply;
      setState(() {
        _localCommanding = true;
        _error = '';
      });
      try {
        localReply = await localHandler(text);
      } catch (error) {
        if (mounted) {
          setState(
            () => _error = error.toString().replaceFirst('Exception: ', ''),
          );
        }
        return;
      } finally {
        if (mounted) setState(() => _localCommanding = false);
      }
      if (!mounted) return;
      if (localReply != null) {
        final reply = localReply.trim();
        setState(() {
          _request.clear();
          _messages.add(_AiChatMessage(text, true));
          if (reply.isNotEmpty) _messages.add(_AiChatMessage(reply, false));
        });
        _scrollToEnd();
        return;
      }
    }

    await _ask();
  }

  Future<void> _runQuickAction(AiHubQuickAction action) async {
    final handler = widget.onQuickAction;
    if (handler == null ||
        _localCommanding ||
        _preparingRequest ||
        _requesting ||
        _reviewing ||
        widget.controller.aiPreparing) {
      return;
    }
    setState(() {
      _localCommanding = true;
      _error = '';
    });
    try {
      final reply = await handler(action);
      if (!mounted || reply == null || reply.trim().isEmpty) return;
      _appendMessage(reply.trim(), false);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _localCommanding = false);
    }
  }

  Future<void> _pasteExternalResponse'''
ai, count = re.subn(
    r"  Future<void> _sendComposer\(\) async \{.*?\n  \}\n\n  Future<void> _pasteExternalResponse",
    send_composer,
    ai,
    count=1,
    flags=re.S,
)
if count != 1:
    raise SystemExit(f"unify AI composer dispatch: expected 1 match, found {count}")

build_start = ai.index("  @override\n  Widget build(BuildContext context) => AnimatedBuilder(")
header_start = ai.index("\nclass _AiHubHeader", build_start)
new_build = r'''  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.controller, _local]),
    builder: (context, _) {
      final busy =
          _localCommanding ||
          _preparingRequest ||
          _requesting ||
          _reviewing ||
          widget.controller.aiPreparing;
      return Column(
        children: [
          _AiHubHeader(
            configured: _local.hasSelection || _configuration.key.isNotEmpty,
            onSettings: _openConnections,
          ),
          _AiComposer(
            controller: _request,
            busy: busy,
            onSend: _sendComposer,
            onCamera: () async {
              await openMedicineCapture(context, widget.controller);
              if (mounted) _scrollToEnd();
            },
            onMic: () async {
              final words = await voiceSearch(
                context,
                offlineOnly: true,
                title: 'Speak to Aaris',
                actionLabel: 'Use message',
              );
              if (mounted && words != null) {
                setState(() => _request.text = words);
              }
            },
          ),
          _AiQuickActions(
            busy: busy || widget.onQuickAction == null,
            onTap: _runQuickAction,
          ),
          if (_local.hasSelection)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'On-device · ${_local.activeLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: muted),
                ),
              ),
            ),
          if (_externalReady)
            _ExternalAiReadyCard(
              onPaste: _pasteExternalResponse,
              onDismiss: () => setState(() => _externalReady = false),
            ),
          if (_requesting)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _cancelRequest,
                  icon: const Icon(Icons.close_rounded, size: 17),
                  label: const Text('Cancel AI request'),
                ),
              ),
            ),
          Expanded(
            child: ListView(
              controller: _scroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              children: [
                for (final message in _messages)
                  _AiMessageBubble(message: message),
                if (_error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
                    child: Surface(
                      color: errorSoft,
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: red,
                            size: 20,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: SelectableText(
                              _error,
                              style: const TextStyle(color: red, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_plan != null) _reviewPanel(context),
                MedicineIntakePanel(
                  controller: widget.controller,
                  onAsk: (evidence) {
                    _request.text =
                        'Explain only the captured identity, salt and expiry and check existing stock; do not add stock or give treatment advice. OCR DATA: '
                        '${evidence.length > 2200 ? evidence.substring(0, 2200) : evidence}';
                    unawaited(_ask());
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      );
    },
  );
}
'''
ai = ai[:build_start] + new_build + ai[header_start:]

ai = replace_once(
    ai,
    "  Widget build(BuildContext context) => SafeArea(\n    top: false,\n    minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),\n    child: Container(\n",
    "  Widget build(BuildContext context) => Padding(\n    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),\n    child: Container(\n",
    "move composer below AI header",
)

quick_widgets = r'''

class _AiQuickActions extends StatelessWidget {
  const _AiQuickActions({required this.busy, required this.onTap});

  final bool busy;
  final ValueChanged<AiHubQuickAction> onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
    child: GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 1.55,
      children: [
        _AiQuickActionTile(
          label: 'Sold',
          icon: Icons.shopping_cart_checkout_rounded,
          color: amber,
          onTap: busy ? null : () => onTap(AiHubQuickAction.sold),
        ),
        _AiQuickActionTile(
          label: 'Removed',
          icon: Icons.inventory_2_outlined,
          color: red,
          onTap: busy ? null : () => onTap(AiHubQuickAction.removed),
        ),
        _AiQuickActionTile(
          label: 'Stock summary',
          icon: Icons.bar_chart_rounded,
          color: primary,
          onTap: busy ? null : () => onTap(AiHubQuickAction.stockSummary),
        ),
        _AiQuickActionTile(
          label: 'Add',
          icon: Icons.add_circle_rounded,
          color: green,
          onTap: busy ? null : () => onTap(AiHubQuickAction.add),
        ),
        _AiQuickActionTile(
          label: 'Delete',
          icon: Icons.delete_outline_rounded,
          color: red,
          onTap: busy ? null : () => onTap(AiHubQuickAction.delete),
        ),
        _AiQuickActionTile(
          label: 'Modify',
          icon: Icons.edit_rounded,
          color: _aiPurple,
          onTap: busy ? null : () => onTap(AiHubQuickAction.modify),
        ),
      ],
    ),
  );
}

class _AiQuickActionTile extends StatelessWidget {
  const _AiQuickActionTile({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 140),
          opacity: onTap == null ? .48 : 1,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  color.withAlpha(dark ? 38 : 20),
                  dark
                      ? const Color(0xFF1B2130).withAlpha(230)
                      : Colors.white.withAlpha(238),
                ],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: color.withAlpha(dark ? 80 : 58)),
              boxShadow: [
                BoxShadow(
                  color: color.withAlpha(dark ? 20 : 18),
                  blurRadius: 14,
                  spreadRadius: -7,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: color, size: 21),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: ink,
                      fontSize: 12,
                      height: 1.08,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
'''
ai = replace_once(
    ai,
    "\nclass _AiConnectionsSheet extends StatefulWidget {",
    quick_widgets + "\nclass _AiConnectionsSheet extends StatefulWidget {",
    "add six premium quick actions",
)

settings_replacements = {
    "Use another AI without an API key, or connect your own provider inside Aaris Pharmacy.":
        "Models, external AI, or your own API.",
    "Send now, or save the TXT and attach it manually later":
        "Share pharmacy TXT · review returned JSON",
    "Use AI inside the app": "API connection",
    "Your API key stays in secure device storage and is never included in pharmacy exports.":
        "Key stays in secure device storage.",
    "Enter a model available with your provider": "Provider model name",
    "Full HTTPS chat/completions endpoint": "HTTPS endpoint",
}
for old, new in settings_replacements.items():
    if old not in ai:
        raise SystemExit(f"settings copy not found: {old}")
    ai = ai.replace(old, new)
ai_path.write_text(ai)


local_path = Path("lib/ui/local_models_panel.dart")
local = local_path.read_text()
local_replacements = {
    "'Search/download uses internet. Chat, scans and inventory stay on this device when a local model is selected. No silent external fallback.'":
        "'Download uses internet. Local AI and inventory stay on-device.'",
    "'Browse current public GGUF models or paste an exact link, including new or untagged repositories. A downloadable file still needs a successful device activation test.'":
        "'Public GGUF models only. Activation is tested before use.'",
    "'Model name, publisher/repository or Hub link'":
        "'Model, repository or Hub link'",
    "'Pause download / cancel import'": "'Pause download'",
    "'Cancel result (native step drains safely)'": "'Cancel response'",
    "'Recommended one-time ~$aarisDefaultModelDownloadHint download. User-selected models can override it; without it Aaris keeps using the offline pharmacy scanner.'":
        "'Recommended ~$aarisDefaultModelDownloadHint download. User-selected local models can override it.'",
}
for old, new in local_replacements.items():
    if old not in local:
        raise SystemExit(f"local settings copy not found: {old}")
    local = local.replace(old, new)
local_path.write_text(local)


test_path = Path("test/unified_ai_hub_ui_test.dart")
test_path.write_text(r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Aaris Brain uses one unified AI composer with six real quick actions', () {
    final brain = File('lib/ui/brain_screen.dart').readAsStringSync();
    final ai = File('lib/ui/ai_screen.dart').readAsStringSync();

    expect(brain, isNot(contains('Aaris App Brain · offline commands')));
    expect(brain, isNot(contains('_brainBar(')));
    expect(ai, contains("hintText: 'Ask AI or paste pharmacy JSON…'"));
    expect(
      RegExp("hintText: 'Ask AI or paste pharmacy JSON…'").allMatches(ai).length,
      1,
    );
    expect(brain, contains('onLocalCommand: _handleUnifiedCommand'));
    expect(brain, contains('onQuickAction: _handleQuickAction'));

    for (final label in <String>[
      "label: 'Sold'",
      "label: 'Removed'",
      "label: 'Stock summary'",
      "label: 'Add'",
      "label: 'Delete'",
      "label: 'Modify'",
    ]) {
      expect(ai, contains(label), reason: label);
    }

    expect(
      brain,
      contains('AiHubQuickAction.delete =>'),
    );
    expect(
      brain,
      contains('_openQuickTargetPicker(AppBrainAction.removeMedicine)'),
    );
    expect(
      brain,
      contains('_openQuickTargetPicker(AppBrainAction.editMedicine)'),
    );
  });
}
''')
