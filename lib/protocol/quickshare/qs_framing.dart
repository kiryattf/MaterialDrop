import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

const int maxQuickShareFrameLength = 5 * 1024 * 1024;

class FrameException implements Exception {
  final String message;
  FrameException(this.message);
  @override
  String toString() => 'FrameException: $message';
}

class ConnectionClosedImmediately extends FrameException {
  ConnectionClosedImmediately()
      : super('Connection closed without sending any data');
}

Uint8List packQuickShareFrame(Uint8List payload) {
  final out = Uint8List(4 + payload.length);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, payload.length, Endian.big);
  out.setRange(4, out.length, payload);
  return out;
}

/// Buffered reader for 4-byte big-endian length-prefixed frames over a TCP [Socket].
class FrameSocketReader {
  final StreamIterator<Uint8List> _iterator;
  final List<int> _buffer = [];
  bool _closed = false;

  FrameSocketReader(Socket socket)
      : _iterator = StreamIterator<Uint8List>(socket);

  Future<Uint8List> _readExact(int n, {bool allowImmediateClose = false}) async {
    while (_buffer.length < n) {
      if (_closed) {
        if (allowImmediateClose && _buffer.isEmpty) {
          throw ConnectionClosedImmediately();
        }
        throw FrameException('Connection closed while reading frame');
      }
      final hasMore = await _iterator.moveNext();
      if (!hasMore) {
        _closed = true;
        if (allowImmediateClose && _buffer.isEmpty) {
          throw ConnectionClosedImmediately();
        }
        throw FrameException('Connection closed while reading frame');
      }
      _buffer.addAll(_iterator.current);
    }

    final result = Uint8List.fromList(_buffer.sublist(0, n));
    _buffer.removeRange(0, n);
    return result;
  }

  Future<Uint8List> readFrame({bool isFirstFrame = false}) async {
    final lenBytes = await _readExact(4, allowImmediateClose: isFirstFrame);
    final length = ByteData.sublistView(lenBytes).getUint32(0, Endian.big);
    if (length > maxQuickShareFrameLength) {
      throw FrameException(
          'Frame length $length exceeds max $maxQuickShareFrameLength');
    }
    return _readExact(length);
  }

  Future<void> dispose() async {
    await _iterator.cancel();
  }
}

