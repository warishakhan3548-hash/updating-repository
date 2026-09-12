import 'package:flutter/material.dart';

import 'design.dart';

/// The action rail owns its space; only the preview and evidence can scroll.
/// Keeping this layout independent of camera plugins also lets phone-size and
/// accessibility regressions exercise the exact production widget.
class ScannerView extends StatelessWidget {
  const ScannerView({
    super.key,
    required this.preview,
    required this.cameraReady,
    required this.starting,
    required this.capturing,
    required this.autoSubmit,
    required this.rapidCapture,
    required this.manualOnly,
    required this.torchOn,
    required this.text,
    required this.barcode,
    required this.error,
    required this.qualityHint,
    required this.onCapture,
    required this.onUseScan,
    required this.onTorch,
  });

  final Widget? preview;
  final bool cameraReady, starting, capturing, autoSubmit, rapidCapture;
  final bool manualOnly, torchOn;
  final String text, barcode, error, qualityHint;
  final VoidCallback? onCapture, onUseScan, onTorch;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: ink,
    appBar: AppBar(
      title: const Text('Scan medicine', style: TextStyle(color: Colors.white)),
      backgroundColor: ink,
      foregroundColor: Colors.white,
      actions: [
        IconButton(
          style: IconButton.styleFrom(foregroundColor: Colors.white),
          tooltip: torchOn ? 'Turn torch off' : 'Turn torch on',
          onPressed: onTorch,
          icon: Icon(
            torchOn
                ? Icons.flashlight_on_rounded
                : Icons.flashlight_off_outlined,
          ),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: GlassPanel(
              tint: canvas,
              blurSigma: 0,
              radius: 22,
              padding: const EdgeInsets.all(12),
              child: Wrap(
                key: const ValueKey('scan-actions'),
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: onCapture,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: Text(
                      capturing
                          ? 'Reading…'
                          : starting
                          ? 'Opening camera…'
                          : !cameraReady
                          ? 'Retry camera'
                          : rapidCapture
                          ? 'Capture photo'
                          : autoSubmit
                          ? 'Capture & automate'
                          : 'Capture text',
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: onUseScan,
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: Text(rapidCapture ? 'Finish captures' : 'Use scan'),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                key: const ValueKey('scan-content'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      child: Text(
                        manualOnly || rapidCapture
                            ? '1. Point at the pack   2. Capture   3. Review'
                            : '1. Point at the pack   2. Hold steady   3. Review',
                        style: const TextStyle(
                          color: inverseMuted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Container(
                      height: (constraints.maxHeight * .52).clamp(180.0, 440.0),
                      margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                      decoration: depthDecoration(ink),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (preview != null)
                              Center(child: preview)
                            else
                              Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(22),
                                  child: Text(
                                    error.isEmpty ? 'Opening camera…' : error,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                              ),
                            IgnorePointer(
                              child: Center(
                                child: FractionallySizedBox(
                                  widthFactor: .88,
                                  heightFactor: .68,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: primarySoft,
                                        width: 2,
                                      ),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    GlassPanel(
                      tint: canvas,
                      radius: 28,
                      blurSigma: 0,
                      elevation: 1.1,
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              DepthIcon(
                                barcode.isNotEmpty || text.isNotEmpty
                                    ? Icons.check_rounded
                                    : Icons.document_scanner_outlined,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      rapidCapture && text.isNotEmpty
                                          ? 'Captures saved'
                                          : barcode.isNotEmpty
                                          ? 'Barcode detected'
                                          : text.isNotEmpty
                                          ? 'Text captured'
                                          : 'Ready to scan',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    Text(
                                      rapidCapture
                                          ? 'Keep capturing. Review your saved photos in AI Hub.'
                                          : autoSubmit
                                          ? 'Capture once to continue to medicine review.'
                                          : 'Check the result, then tap Use scan above.',
                                      style: const TextStyle(
                                        color: muted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            qualityHint.isNotEmpty
                                ? qualityHint
                                : manualOnly || rapidCapture
                                ? 'Tap Capture to read the label.'
                                : 'Barcode and label text are read together.',
                            style: const TextStyle(color: muted, fontSize: 12),
                          ),
                          if (error.isNotEmpty && cameraReady)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                error,
                                style: const TextStyle(
                                  color: red,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          const SizedBox(height: 16),
                          Surface(
                            padding: const EdgeInsets.all(16),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 180),
                              child: SingleChildScrollView(
                                key: const ValueKey('scan-evidence'),
                                child: SelectableText(
                                  [
                                    if (barcode.isNotEmpty) 'Barcode: $barcode',
                                    if (text.isNotEmpty) text,
                                    if (text.isEmpty && barcode.isEmpty)
                                      'Point at packaging or a printed medicine list.',
                                  ].join('\n\n'),
                                  style: const TextStyle(
                                    color: muted,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
