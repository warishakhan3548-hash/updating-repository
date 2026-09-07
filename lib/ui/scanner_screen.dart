import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../services/scan_service.dart';
import 'design.dart';

class ScanResult {
  const ScanResult({this.barcode = '', this.text = ''});
  final String barcode, text;
}

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen>
    with WidgetsBindingObserver {
  final _vision = MedicineVisionService();
  CameraController? _camera;
  CameraDescription? _description;
  Future<void>? _frameWork;
  Future<void> _lifecycle = Future.value();
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  bool _busy = false, _closed = false, _capturing = false;
  int _generation = 0;
  String _text = '', _barcode = '', _error = '';
  bool _manualOnly = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  Future<void> _start() async {
    final generation = ++_generation;
    if (kIsWeb) {
      setState(
        () => _error =
            'Live camera OCR is available in the Android app. You can paste text into search.',
      );
      return;
    }
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
      await camera.initialize();
      if (_closed || generation != _generation) {
        await camera.dispose();
        return;
      }
      _description = description;
      _camera = camera;
      await camera.startImageStream(_onFrame);
      if (mounted) setState(() => _error = '');
    } catch (e) {
      if (mounted && !_closed)
        setState(
          () => _error =
              'Camera unavailable. Allow camera access in your phone settings, then retry.',
        );
    }
  }

  void _onFrame(CameraImage image) {
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

  Future<void> _recognize(InputImage input) async {
    if (_busy || _closed) return;
    _busy = true;
    final generation = _generation;
    try {
      // A single immutable frame feeds all detectors; only one frame is in flight.
      final result = await _vision.analyze(input);
      if (_closed || !mounted || generation != _generation) return;
      if (result.text.isNotEmpty || result.barcode.isNotEmpty)
        setState(() {
          _text = result.text;
          _barcode = result.barcode;
          _error = '';
        });
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
    try {
      if (camera.value.isStreamingImages) await camera.stopImageStream();
      await _frameWork;
      final photo = await camera.takePicture();
      await _recognize(InputImage.fromFilePath(photo.path));
      if (!_closed && camera == _camera)
        await camera.startImageStream(_onFrame);
    } catch (e) {
      if (mounted) showError(context, 'Capture failed. Please retry.');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _stopCamera() async {
    ++_generation;
    final camera = _camera;
    _camera = null;
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
      title: const Text('Scan medicine'),
      backgroundColor: ink,
      foregroundColor: Colors.white,
      actions: [
        IconButton(
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
                  style: const TextStyle(
                    color: Color(0xFFD1E6DA),
                    fontSize: 12,
                  ),
                ),
              ),
              Container(
                height: (constraints.maxHeight * .48).clamp(210.0, 440.0),
                margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                decoration: depthDecoration(const Color(0xFF0D2C24)),
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
                                border: Border.all(color: lime, width: 2),
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
                            color: const Color(0xC00D2C24),
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
                blurSigma: 14,
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
                              const Text(
                                'Check the result, then tap Use scan.',
                                style: TextStyle(color: muted, fontSize: 12),
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
                              if (_text.isEmpty && _barcode.isEmpty)
                                'Point at packaging or a printed medicine list.',
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
                                : 'Capture text',
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: _text.isEmpty && _barcode.isEmpty
                              ? null
                              : () => Navigator.pop(
                                  context,
                                  ScanResult(barcode: _barcode, text: _text),
                                ),
                          icon: const Icon(Icons.arrow_forward_rounded),
                          label: const Text('Use scan'),
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
