import 'dart:async';
import 'dart:io';

import '../../models/models.dart';
import '../../services/platform_bridge.dart';

class MaterialDropSendException implements Exception {
  final String message;
  MaterialDropSendException(this.message);
  @override
  String toString() => message;
}

class MaterialDropSender {
  bool _canceled = false;
  HttpClient? _activeClient;
  HttpClientRequest? _activeRequest;

  void cancel() {
    _canceled = true;
    try {
      _activeRequest?.abort();
    } catch (_) {}
    try {
      _activeClient?.close(force: true);
    } catch (_) {}
  }

  Future<void> sendBatch({
    required NearbyDevice device,
    required String localDeviceName,
    required List<StagedFile> files,
    required void Function(
      String fileName,
      int bytesSent,
      int totalBytes,
      double speedBps,
    ) onProgress,
  }) async {
    if (files.isEmpty) return;
    _canceled = false;

    final totalBytes = files.fold<int>(0, (sum, f) => sum + f.size);
    var totalSentBefore = 0;
    final sw = Stopwatch()..start();

    for (final file in files) {
      if (_canceled) throw MaterialDropSendException('Transfer canceled');
      await _sendSingleFile(
        device: device,
        localDeviceName: localDeviceName,
        file: file,
        onFileProgress: (sentInFile) {
          final cumulative = totalSentBefore + sentInFile;
          final sec = sw.elapsedMilliseconds / 1000.0;
          final speed = sec > 0 ? cumulative / sec : 0.0;
          onProgress(file.name, cumulative, totalBytes, speed);
        },
      );
      totalSentBefore += file.size;
    }
  }

  Future<void> _sendSingleFile({
    required NearbyDevice device,
    required String localDeviceName,
    required StagedFile file,
    required void Function(int bytesSent) onFileProgress,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    _activeClient = client;

    try {
      final encName = Uri.encodeQueryComponent(file.name);
      final encDevice = Uri.encodeQueryComponent(localDeviceName);
      final relQuery = (file.relativePath != null && file.relativePath!.isNotEmpty)
          ? '&rel=${Uri.encodeQueryComponent(file.relativePath!)}'
          : '';
      final uri = Uri.parse(
        'http://${device.ip}:${device.port}/upload?name=$encName&device=$encDevice$relQuery',
      );

      final request = await client.postUrl(uri);
      _activeRequest = request;
      if (file.size >= 0) {
        request.contentLength = file.size;
      } else {
        request.headers.chunkedTransferEncoding = true;
      }
      request.headers.contentType = ContentType.binary;

      var bytesSent = 0;
      var bytesSinceFlush = 0;
      var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

      await for (final chunk in PlatformBridge.instance.openFileReadStream(file)) {
        if (_canceled) {
          request.abort();
          throw MaterialDropSendException('Transfer canceled');
        }
        request.add(chunk);
        bytesSent += chunk.length;
        bytesSinceFlush += chunk.length;

        if (bytesSinceFlush >= 256 * 1024) {
          bytesSinceFlush = 0;
          await request.flush();
        }

        final now = DateTime.now();
        if (now.difference(lastEmit).inMilliseconds >= 50 ||
            (file.size > 0 && bytesSent >= file.size)) {
          lastEmit = now;
          onFileProgress(bytesSent);
        }
      }

      if (_canceled) {
        request.abort();
        throw MaterialDropSendException('Transfer canceled');
      }

      final response = await request.close().timeout(const Duration(seconds: 60));
      await response.drain<void>();

      if (response.statusCode == HttpStatus.ok) {
        onFileProgress(bytesSent);
        return;
      } else if (response.statusCode == HttpStatus.forbidden) {
        throw MaterialDropSendException('Recipient declined transfer');
      } else {
        throw MaterialDropSendException('Server returned HTTP ${response.statusCode}');
      }
    } finally {
      _activeRequest = null;
      _activeClient = null;
      client.close(force: true);
    }
  }
}

