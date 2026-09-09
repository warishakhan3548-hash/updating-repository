import 'dart:convert';

/// Model tokens are byte pieces, not necessarily complete UTF-8 characters.
/// Keep at most the decoder's unfinished code point between token callbacks.
class TokenTextDecoder {
  TokenTextDecoder() {
    _sink = const Utf8Decoder(
      allowMalformed: false,
    ).startChunkedConversion(StringConversionSink.fromStringSink(_text));
  }
  final _text = StringBuffer();
  late final ByteConversionSink _sink;
  String _take() {
    final value = _text.toString();
    _text.clear();
    return value;
  }

  String add(List<int> bytes) {
    _sink.add(bytes);
    return _take();
  }

  String finish() {
    _sink.close();
    return _take();
  }
}
