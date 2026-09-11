import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../domain/medicine_understanding.dart';
import '../services/media_import_service.dart';
import '../services/scan_service.dart';
import 'default_ai_prompt.dart';
import 'design.dart';

class ScanResult {
  const ScanResult({
    this.barcode = '',
    this.text = '',
    this.evidence = const <ScanEvidence>[],
  });
  final String barcode, text;
  final List<ScanEvidence> evidence;
}

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({
    super.key,
    this.autoSubmit = false,
    this.onCaptureQueued,
  });
  final bool autoSubmit;

  /// Acknowledge only after the capture is durably copied; OCR happens in queue.
  final Future<void> Function(String path)? onCaptureQueued;
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen>
    with WidgetsBindingObserver {
  final _vision = MedicineVisionService();
  final _media = MediaImportService();
  CameraController? _camera;
  CameraDescription? _description;
  Future<void>? _frameWork;
  Future<void> _lifecycle = Future.value();
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  bool _busy = false, _closed = false, _capturing = false;
  int _generation = 0;
  int _scanSequence = 0;
  String _text = '', _barcode = '', _error = '';
  final List<ScanEvidence> _evidence = <ScanEvidence>[];
  bool _manualOnly = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed) unawaited(_bootstrap());
    });
  }

  Future<void> _bootstrap() async {
    // Ask once for the small default brain before opening the camera. If the
    // owner declines or setup fails, offerAarisDefaultAi returns normally and
    // the existing deterministic scanner starts unchanged.
    await offerAarisDefaultAi(context);
    if (!_closed && mounted) await _start();
  }

  Future<void> _start() async {
    final generation = ++_generation;
    if (kIsWeb) {
      setState(
        () => _error = 'Live camera OCR is available in the Android app. You can paste text into search.',
      );
      return;
    }
    CameraController? openingCamera;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('No camera is available.');
      final description = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final camera = CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: defaultTargetPlatform == TargetPlatform.android
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );
      openingCamera = camera;
      await camera.initialize();
      if (_closed || generation != _generation) {
        await camera.dispose();
        openingCamera = null;
        return;
      }
      _description = description;
      _camera = camera;
      if (widget.onCaptureQueued == null)
        await camera.startImageStream(_onFrame);
      openingCamera = null;
      if (mounted) setState(() => _error = '');
    } catch (e) {
      if (identical(_camera, openingCamera)) {
        _camera = null;
        _description = null;
      }
      try {
        await openingCamera?.dispose();
      } catch (_) {}
      if (mounted && !_closed)
        setState(
          () => _error = 'Camera unavailable. Allow camera access in your phone settings, then retry.',
        );
    }
  }

  void _onFrame(CameraImage image) {
    if (widget.onCaptureQueued != null) return;
    if (_closed ||
        _busy ||
        _capturing ||
        DateTime.now().difference(_lastFrame).inMilliseconds < 450)
      return;
    final input = _inputImage(image);
    if (input == null) {
      if (!_manualOnly && mounted) setState(() => _manualOnly = true);
      return;
    }
    _lastFrame = DateTime.now();
    _frameWork = _recognize(input);
  }

  InputImage? _inputImage(CameraImage image) {
    final description = _description;
    final camera = _camera;
    if (description == null || camera == null || image.planes.length != 1)
      return null;
    var rotation = description.sensorOrientation;
    if (defaultTargetPlatform == TargetPlatform.android) {
      const orientation = {
        DeviceOrientation.portraitUp: 0,
        DeviceOrientation.landscapeLeft: 90,
        DeviceOrientation.portraitDown: 180,
        DeviceOrientation.landscapeRight: 270,
      };
      final compensation = orientation[camera.value.deviceOrientation] ?? 0;
      rotation = description.lensDirection == CameraLensDirection.front
          ? (rotation + compensation) % 360
          : (rotation - compensation + 360) % 360;
    }
    final converted = InputImageRotationValue.fromRawValue(rotation);
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (converted == null || format == null) return null;
    if (defaultTargetPlatform == TargetPlatform.android &&
        format != InputImageFormat.nv21)
      return null;
    return InputImage.fromBytes(
      bytes: image.planes.first.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: converted,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  Future<void> _recognize(InputImage input, {String? source}) async {
    if (_busy || _closed) return;
    _busy = true;
    final generation = _generation;
    try {
      // A single immutable frame feeds all detectors; only one frame is in flight.
      final sequence = _scanSequence++;
      final result = await _vision.analyze(
        input,
        source: source ?? 'Live camera frame ${sequence + 1}',
        sequence: sequence,
      );
      if (_closed || !mounted || generation != _generation) return;
      if (result.text.isNotEmpty || result.barcode.isNotEmpty) {
        final evidence = <ScanEvidence>[..._evidence, result];
        if (evidence.length > 18) {
          evidence.removeRange(0, evidence.length - 18);
        }
        final payload = await compute(
          understandMedicineEvidenceMessage,
          <String, Object?>{
            'evidence': evidence
                .map((item) => item.toMessage())
                .toList(growable: false),
          },
        );
        if (_closed || !mounted || generation != _generation) return;
        final understood = MedicineUnderstandingResult.fromMessage(payload);
        setState(() {
          _evidence
            ..clear()
            ..addAll(evidence);
          final current = understood.drafts.isEmpty
              ? null
              : understood.drafts.last;
          _text = current?.rawText ?? result.text;
          _barcode = current?.barcode ?? result.barcode;
          _error = '';
        });
      }
    } catch (e) {
      if (mounted && !_closed && _capturing)
        setState(
          () => _error =
              'Text could not be read. Move closer, add light and try again.',
        );
    } finally {
      _busy = false;
    }
  }

  Future<void> _capture() async {
    final camera = _camera;
    if (camera == null || _capturing || _closed) return;
    setState(() => _capturing = true);
    String? capturePath;
    try {
      if (camera.value.isStreamingImages) await camera.stopImageStream();
      await _frameWork;
      final photo = await camera.takePicture();
      capturePath = photo.path;
      if (widget.onCaptureQueued != null) {
        await widget.onCaptureQueued!(photo.path);
        if (mounted)
          setState(
            () => _text =
                '${++_scanSequence} photos queued. Capture the next pack. Review in AI Hub.',
          );
      } else {
        // The live stream is useful evidence, not disposable preview state. It
        // often sees a barcode/front label while the high-resolution still sees
        // the composition/expiry panel (or vice versa). Keep the existing
        // bounded evidence window and add the captured still as the final frame
        // so deterministic understanding and Local AI receive the fused pack,
        // instead of throwing away everything observed immediately before tap.
        await _recognize(
          InputImage.fromFilePath(photo.path),
          source: 'Captured still photo',
        );
        if (widget.autoSubmit &&
            mounted &&
            (_text.isNotEmpty || _barcode.isNotEmpty)) {
          Navigator.pop(
            context,
            ScanResult(
              barcode: _barcode,
              text: _text,
              evidence: List.of(_evidence),
            ),
          );
          return;
        }
      }
      if (!_closed && camera == _camera && widget.onCaptureQueued == null)
        await camera.startImageStream(_onFrame);
    } catch (e) {
      if (mounted)
        showError(context, 'Capture was not queued/read. Please retry. $e');
    } finally {
      if (capturePath != null) {
        try {
          await _media.cleanupCameraCapture(capturePath);
        } catch (_) {
          // Cache cleanup must not hide a successfully recognized scan.
        }
      }
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _stopCamera() async {
    ++_generation;
    final camera = _camera;
    _camera = null;
    _description = null;
    if (camera != null) {
      try {
        await camera.dispose();
      } catch (_) {}
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        state != AppLifecycleState.inactive &&
        state != AppLifecycleState.paused)
      return;
    _lifecycle = _lifecycle
        .then((_) async {
          if (_closed) return;
          await _stopCamera();
          if (state == AppLifecycleState.resumed && !_closed) await _start();
        })
        .catchError((Object _) {});
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(
      _stopCamera().then((_) async {
        await _frameWork;
        await _vision.close();
      }),
    );
    super.dispose();
  }

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
          tooltip: _camera?.value.flashMode == FlashMode.torch
              ? 'Turn torch off'
              : 'Turn torch on',
          onPressed: _camera?.value.isInitialized != true
              ? null
              : () async {
                  final camera = _camera;
                  if (camera == null) return;
                  try {
                    await camera.setFlashMode(
                      camera.value.flashMode == FlashMode.torch
                          ? FlashMode.off
                          : FlashMode.torch,
                    );
                    if (mounted) setState(() {});
                  } catch (e) {
                    if (context.mounted)
                      showError(context, 'Torch is unavailable.');
                  }
                },
          icon: Icon(
            _camera?.value.flashMode == FlashMode.torch
                ? Icons.flashlight_on_rounded
                : Icons.flashlight_off_outlined,
          ),
        ),
      ],
    ),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                child: Text(
                  _manualOnly
                      ? '1. Point at the pack   2. Capture   3. Review'
                      : '1. Point at the pack   2. Hold steady   3. Review',
                  style: const TextStyle(color: inverseMuted, fontSize: 12),
                ),
              ),
              Container(
                height: (constraints.maxHeight * .48).clamp(210.0, 440.0),
                margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                decoration: depthDecoration(ink),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_camera?.value.isInitialized == true)
                        Center(child: CameraPreview(_camera!))
                      else
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.all(22),
                            child: Text(
                              _error.isEmpty ? 'Opening camera…' : _error,
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
                      Positioned(
                        left: 14,
                        right: 14,
                        bottom: 14,
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xE6182A44),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _manualOnly
                                ? 'Tap Capture text to read the label.'
                                : 'Barcode and label text are read together.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
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
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        DepthIcon(
                          _barcode.isNotEmpty || _text.isNotEmpty
                              ? Icons.check_rounded
                              : Icons.document_scanner_outlined,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _barcode.isNotEmpty
                                    ? 'Barcode detected'
                                    : _text.isNotEmpty
                                    ? 'Text captured'
                                    : 'Ready to scan',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                widget.onCaptureQueued != null
                                    ? 'Keep capturing. Processing continues in the saved inbox.'
                                    : widget.autoSubmit
                                    ? 'Capture once. OCR will hand off automatically to Aaris Brain.'
                                    : 'Check the result, then tap Use scan.',
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
                    const SizedBox(height: 16),
                    Surface(
                      padding: const EdgeInsets.all(16),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 180),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            [
                              if (_barcode.isNotEmpty) 'Barcode: $_barcode',
                              if (_text.isNotEmpty) _text,
                              if (_text.isEmpty && _barcode.isEmpty) 'Point at packaging or a printed medicine list.',
                            ].join('\n\n'),
                            style: const TextStyle(color: muted, fontSize: 13),
                          ),
                        ),
                      ),
                    ),
                    if (_error.isNotEmpty && _camera != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _error,
                          style: const TextStyle(color: red, fontSize: 12),
                        ),
                      ),
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _camera == null
                              ? () => unawaited(_start())
                              : _capturing
                              ? null
                              : _capture,
                          icon: const Icon(Icons.camera_alt_outlined),
                          label: Text(
                            _camera == null
                                ? 'Retry camera'
                                : _capturing
                                ? 'Reading…'
                                : widget.autoSubmit
                                ? 'Capture & automate'
                                : 'Capture text',
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: _capturing
                              ? null
                              : widget.onCaptureQueued != null
                              ? () => Navigator.pop(context)
                              : _text.isEmpty && _barcode.isEmpty
                              ? null
                              : () => Navigator.pop(
                                  context,
                                  ScanResult(
                                    barcode: _barcode,
                                    text: _text,
                                    evidence: List<ScanEvidence>.unmodifiable(
                                      _evidence,
                                    ),
                                  ),
                                ),
                          icon: const Icon(Icons.arrow_forward_rounded),
                          label: Text(
                            widget.onCaptureQueued != null
                                ? 'Finish captures'
                                : 'Use scan',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
