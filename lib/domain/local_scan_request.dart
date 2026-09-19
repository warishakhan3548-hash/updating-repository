import 'dart:async';

/// One optional scan review, including queueing, setup and all retry attempts.
/// Cancellation is attached only while this request owns the native lease.
/// A finished scan can therefore never cancel a later chat or another scan.
class LocalScanRequest {
  LocalScanRequest({
    this.limit = const Duration(seconds: 30),
    void Function()? onTimeout,
  }) : _onTimeout = onTimeout {
    if (limit <= Duration.zero) {
      throw ArgumentError.value(limit, 'limit', 'Must be positive.');
    }
    _watch.start();
    _timer = Timer(limit, _expire);
  }

  final Duration limit;
  final void Function()? _onTimeout;
  final _watch = Stopwatch();
  final _stopped = Completer<void>();
  Timer? _timer;
  Object? _lease;
  void Function()? _cancelNative;
  bool _cancelled = false, _timedOut = false;

  bool get cancelled => _cancelled;
  bool get timedOut => _timedOut;
  Future<void> get whenStopped => _stopped.future;
  Duration get remaining {
    final value = limit - _watch.elapsed;
    return value > Duration.zero ? value : Duration.zero;
  }

  void checkCurrent() {
    if (!_cancelled && remaining == Duration.zero) _expire();
    if (_timedOut) {
      throw TimeoutException('Local scan review timed out.', limit);
    }
    if (_cancelled) throw StateError('Local scan review cancelled.');
  }

  /// Used for read-only route/settings waits, never to release an active native
  /// lease early. Late read completion is observed but cannot restore consent.
  Future<T> wait<T>(Future<T> Function() work) async {
    checkCurrent();
    final value = await Future.any<T>([
      work(),
      whenStopped.then<T>((_) {
        checkCurrent();
        throw StateError('Local scan review stopped.');
      }),
    ]);
    checkCurrent();
    return value;
  }

  void bind(Object lease, void Function() cancelNative) {
    checkCurrent();
    if (_lease != null) throw StateError('Scan already owns a local AI lease.');
    _lease = lease;
    _cancelNative = cancelNative;
  }

  void release(Object lease) {
    if (!identical(_lease, lease)) return;
    _lease = null;
    _cancelNative = null;
  }

  void _expire() {
    if (_cancelled) return;
    _timedOut = true;
    cancel();
    _onTimeout?.call();
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
    final cancelNative = _cancelNative;
    _cancelNative = null;
    _lease = null;
    _stopped.complete();
    cancelNative?.call();
  }

  void close() => cancel();
}
