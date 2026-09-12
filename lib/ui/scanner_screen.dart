import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../domain/medicine_resolution_v2.dart';
import '../domain/capture_quality.dart';
import '../domain/medicine_understanding.dart';
import '../services/media_import_service.dart';
import '../services/scan_service.dart';
import 'default_ai_prompt.dart';
import 'design.dart';
import 'scanner_view.dart';

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
  Future<bool>? _frameWork;
  Future<void>? _captureWork;
  Future<void> _lifecycle = Future.value();
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  bool _busy = false, _closed = false, _capturing = false;
  bool _starting = false, _bootstrapped = false, _leaving = false;
  bool _foreground = true;
  int _generation = 0;
  int _scanSequence = 0;
  String _text = '', _barcode = '', _error = '';
  String _qualityHint = '';
  final List<ScanEvidence> _evidence = <ScanEvidence>[];
  bool _manualOnly = false;
  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
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
    if (_closed || !mounted) return;
    _bootstrapped = true;
    if (_foreground) await _restartCamera();
  }

  bool _current(int generation) =>
      mounted &&
      !_closed &&
      !_leaving &&
      _foreground &&
      generation == _generation;

  Future<void> _restartCamera() {
    if (_closed || _leaving || !_foreground || !_bootstrapped || _starting) {
      return Future.value();
    }
    final generation = ++_generation;
    setState(() => _starting = true);
    // Bootstrap, retry and resume share the same camera owner. Invalidation is
    // synchronous; native teardown/opening is serialized after existing work.
    return _lifecycle = _lifecycle
        .then((_) async {
          await _stopCamera();
          if (_current(generation)) await _start(generation);
        })
        .whenComplete(() {
          if (_current(generation)) setState(() => _starting = false);
        });
  }

  Future<void> _start(int generation) async {
    if (!_current(generation)) return;
    if (kIsWeb) {
      setState(
        () => _error =
            'Live camera OCR is available in the Android app. You can paste text into search.',
      );
      return;
    }
    CameraController? openingCamera;
    try {
      final cameras = await availableCameras();
      if (!_current(generation)) return;
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
      if (!_current(generation)) {
        await camera.dispose();
        openingCamera = null;
        return;
      }
      _description = description;
      _camera = camera;
      _manualOnly = false;
      if (widget.onCaptureQueued == null)
        await camera.startImageStream((image) => _onFrame(image, generation));
      openingCamera = null;
      if (_current(generation)) setState(() => _error = '');
    } catch (e) {
      if (identical(_camera, openingCamera)) {
        _camera = null;
        _description = null;
      }
      try {
        await openingCamera?.dispose();
      } catch (_) {}
      if (_current(generation))
        setState(
          () => _error =
              'Camera unavailable. Allow camera access in your phone settings, then retry.',
        );
    }
  }

  void _onFrame(CameraImage image, int generation) {
    if (!_current(generation)) return;
    if (widget.onCaptureQueued != null) return;
    if (_closed ||
        _leaving ||
        !_foreground ||
        _camera == null ||
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
    final bgra = defaultTargetPlatform != TargetPlatform.android;
    final quality = CaptureQuality.fromPlane(
      bytes: image.planes.first.bytes,
      width: image.width,
      height: image.height,
      bytesPerRow: image.planes.first.bytesPerRow,
      pixelStride: bgra ? 4 : 1,
      bgra: bgra,
    );
    _frameWork = _recognize(input, quality: quality);
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

  Future<bool> _recognize(
    InputImage input, {
    String? source,
    CaptureQuality? quality,
    String? qualityPath,
  }) async {
    if (_busy || _closed || _leaving || !_foreground) return false;
    _busy = true;
    final generation = _generation;
    try {
      // A single immutable frame feeds all detectors; only one frame is in flight.
      final sequence = _scanSequence++;
      final result = await _vision.analyze(
        input,
        source: source ?? 'Live camera frame ${sequence + 1}',
        sequence: sequence,
        quality: quality?.score,
        qualityPath: qualityPath,
      );
      if (!_current(generation)) return false;
      final hint =
          quality?.guidance ??
          (result.quality < .28
              ? 'Try a closer, steadier photo with even light.'
              : '');
      if (result.text.isNotEmpty || result.barcode.isNotEmpty) {
        final evidence = <ScanEvidence>[..._evidence, result];
        if (evidence.length > 18) {
          evidence.removeRange(0, evidence.length - 18);
        }
        final payload = await compute(
          // Keep live preview on the same evidence-safety pipeline as photo,
          // video, import-inbox and explicit cloud review. No catalogue or
          // private stock memory is supplied here: the scanner only applies
          // V2's spatial, regulatory, date and cross-field contradiction gates
          // to facts observed in this bounded capture window.
          understandMedicineEvidenceV2Message,
          <String, Object?>{
            'evidence': evidence
                .map((item) => item.toMessage())
                .toList(growable: false),
            'knowledge': const <Object?>[],
            'catalog': const <Object?>[],
          },
        );
        if (!_current(generation)) return false;
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
          _qualityHint = hint;
        });
        return true;
      } else if (_qualityHint != hint) {
        setState(() => _qualityHint = hint);
      }
      if (_capturing) {
        setState(
          () => _error =
              'No text or barcode was read in this photo. Hold steady and capture again.',
        );
      }
      return false;
    } catch (e) {
      if (_current(generation) && _capturing)
        setState(
          () => _error =
              'Text could not be read. Move closer, add light and try again.',
        );
      return false;
    } finally {
      _busy = false;
    }
  }

  Future<void> _capture() {
    final camera = _camera;
    final generation = _generation;
    if (camera == null ||
        !camera.value.isInitialized ||
        _starting ||
        _capturing ||
        !_current(generation))
      return Future.value();
    setState(() => _capturing = true);
    return _captureWork = _captureStill(camera, generation);
  }

  Future<void> _captureStill(CameraController camera, int generation) async {
    bool current() => _current(generation) && identical(camera, _camera);
    String? capturePath;
    try {
      if (camera.value.isStreamingImages) await camera.stopImageStream();
      await _frameWork;
      if (!current()) return;
      final photo = await camera.takePicture();
      capturePath = photo.path;
      if (!current()) return;
      if (widget.onCaptureQueued != null) {
        await widget.onCaptureQueued!(photo.path);
        // A durable queue acknowledgement remains valid across app pause; only
        // the camera session was retired, not the already-saved photo.
        if (mounted && !_closed && !_leaving) {
          setState(() {
            _text =
                '${++_scanSequence} photos queued. Capture the next pack. Review in AI Hub.';
            _error = '';
          });
        }
      } else {
        // Keep complementary live evidence, but require this still to succeed
        // before automatic handoff. A failed/empty still must not submit an
        // older preview simply because _text or _barcode was already populated.
        final recognized = await (_frameWork = _recognize(
          InputImage.fromFilePath(photo.path),
          source: 'Captured still photo',
          qualityPath: photo.path,
        ));
        if (current() &&
            widget.autoSubmit &&
            recognized &&
            (_text.isNotEmpty || _barcode.isNotEmpty)) {
          _finishScan();
        }
      }
    } catch (_) {
      if (current()) {
        setState(() => _error = 'Capture was not queued/read. Please retry.');
      }
    } finally {
      if (capturePath != null) {
        try {
          await _media.cleanupCameraCapture(capturePath);
        } catch (_) {
          // Housekeeping cannot turn a saved/read capture into a false failure.
        }
      }
      // Restore live scanning after BOTH success and failure. The session check
      // stops a cancelled capture from restarting a retired camera or route.
      if (current() &&
          widget.onCaptureQueued == null &&
          !camera.value.isStreamingImages) {
        try {
          await camera.startImageStream((image) => _onFrame(image, generation));
        } catch (_) {
          if (current()) setState(() => _manualOnly = true);
        }
      }
      if (mounted && !_closed) setState(() => _capturing = false);
    }
  }

  void _finishScan() {
    if (_closed || _leaving || !mounted) return;
    final result = widget.onCaptureQueued != null
        ? null
        : ScanResult(
            barcode: _barcode,
            text: _text,
            evidence: List<ScanEvidence>.unmodifiable(_evidence),
          );
    _leaving = true;
    ++_generation;
    Navigator.pop(context, result);
  }

  Future<void> _toggleTorch() async {
    final camera = _camera;
    final generation = _generation;
    if (camera == null || !_current(generation)) return;
    try {
      await camera.setFlashMode(
        camera.value.flashMode == FlashMode.torch
            ? FlashMode.off
            : FlashMode.torch,
      );
      if (_current(generation)) setState(() {});
    } catch (_) {
      if (_current(generation)) showError(context, 'Torch is unavailable.');
    }
  }

  Future<void> _stopCamera() async {
    final camera = _camera;
    _camera = null;
    _description = null;
    if (mounted && !_closed) setState(() {});
    // takePicture and still OCR are part of the same lease as stream OCR.
    // Detach first to reject new frames, then drain before native disposal.
    await _captureWork;
    await _frameWork;
    if (camera != null) {
      try {
        await camera.dispose();
      } catch (_) {}
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closed || _leaving) return;
    _foreground = state == AppLifecycleState.resumed;
    ++_generation;
    setState(() => _starting = false);
    _lifecycle = _lifecycle.then((_) => _stopCamera());
    if (_foreground && _bootstrapped) unawaited(_restartCamera());
  }

  @override
  void dispose() {
    _closed = true;
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(
      _lifecycle
          .then((_) => _stopCamera())
          .then((_) => _vision.close())
          .catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cameraReady = _camera?.value.isInitialized == true;
    final canCapture =
        !_capturing && !_starting && _foreground && _bootstrapped && !_leaving;
    return ScannerView(
      preview: cameraReady ? CameraPreview(_camera!) : null,
      cameraReady: cameraReady,
      starting: _starting || !_bootstrapped,
      capturing: _capturing,
      autoSubmit: widget.autoSubmit,
      rapidCapture: widget.onCaptureQueued != null,
      manualOnly: _manualOnly,
      torchOn: _camera?.value.flashMode == FlashMode.torch,
      text: _text,
      barcode: _barcode,
      error: _error,
      qualityHint: _qualityHint,
      onCapture: !canCapture
          ? null
          : cameraReady
          ? _capture
          : _restartCamera,
      onUseScan:
          _capturing ||
              _leaving ||
              (widget.onCaptureQueued == null &&
                  _text.isEmpty &&
                  _barcode.isEmpty)
          ? null
          : _finishScan,
      onTorch: cameraReady && canCapture ? _toggleTorch : null,
    );
  }
}
