import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/models.dart';
import '../../services/platform_bridge.dart';
import 'lan_constants.dart';
import 'tls_identity.dart';

class LanSendException implements Exception {
  final String message;
  final bool userDeclined;

  const LanSendException(this.message, {this.userDeclined = false});

  @override
  String toString() => message;
}

class LanSender {
  bool _canceled = false;
  HttpClient? _activeClient;
  String? _activeSessionId;
  NearbyDevice? _activeDevice;

  void cancel() {
    _canceled = true;
    final sid = _activeSessionId;
    final dev = _activeDevice;
    if (sid != null && dev != null) {
      unawaited(_sendCancelSignal(dev, sid));
    }
    _activeClient?.close(force: true);
    _activeClient = null;
  }

  HttpClient _buildClient(NearbyDevice device) {
    if (device.useHttps) {
      return TlsIdentity.createPinnedClient(
        expectedFingerprint: device.tlsFingerprint,
        connectionTimeout: const Duration(seconds: 8),
      );
    }
    return HttpClient()..connectionTimeout = const Duration(seconds: 8);
  }

  Future<void> _sendCancelSignal(NearbyDevice device, String sessionId) async {
    final client = _buildClient(device);
    try {
      final scheme = device.useHttps ? 'https' : 'http';
      final uri = Uri.parse(
        '$scheme://${device.ip}:${device.port}${LanConstants.pathCancel}?sessionId=${Uri.encodeQueryComponent(sessionId)}',
      );
      final req = await client.postUrl(uri);
      await req.close().timeout(const Duration(seconds: 2));
    } catch (_) {
    } finally {
      client.close(force: true);
    }
  }

  Future<void> sendBatch({
    required NearbyDevice device,
    required String localDeviceName,
    required int localPort,
    required String localFingerprint,
    required bool localUseHttps,
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
    _activeDevice = device;
    _activeSessionId = null;

    final client = _buildClient(device);
    _activeClient = client;

    try {
      final scheme = device.useHttps ? 'https' : 'http';
      final baseUrl = '$scheme://${device.ip}:${device.port}';

      final fileMap = <String, Map<String, dynamic>>{};
      final idToFile = <String, StagedFile>{};
      var totalBatchBytes = 0;

      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        final id = 'f_$i';
        idToFile[id] = f;
        totalBatchBytes += f.size;
        fileMap[id] = {
          'id': id,
          'fileName': f.displayName,
          'size': f.size,
          'fileType': f.mimeType,
        };
      }

      // 1. Prepare upload session
      final prepReq = await client.postUrl(
        Uri.parse('$baseUrl${LanConstants.pathPrepareUpload}'),
      );
      prepReq.headers.contentType = ContentType.json;
      prepReq.write(jsonEncode({
        'info': {
          'alias': localDeviceName,
          'version': LanConstants.protocolVersion,
          'deviceModel': LanConstants.localDeviceModel,
          'deviceType': LanConstants.localDeviceType,
          'fingerprint': localFingerprint,
          'port': localPort,
          'protocol': localUseHttps ? 'https' : 'http',
          'download': false,
        },
        'files': fileMap,
      }));

      final prepResp = await prepReq.close().timeout(const Duration(seconds: 65));
      final prepBody = await utf8.decodeStream(prepResp);

      if (prepResp.statusCode == HttpStatus.forbidden) {
        throw const LanSendException('Transfer declined by receiver', userDeclined: true);
      }
      if (prepResp.statusCode == HttpStatus.noContent) {
        return;
      }
      if (prepResp.statusCode != HttpStatus.ok) {
        throw LanSendException('Receiver returned HTTP ${prepResp.statusCode}');
      }

      final decoded = jsonDecode(prepBody) as Map<String, dynamic>;
      final sessionId = decoded['sessionId'] as String? ?? '';
      final tokens = (decoded['files'] as Map<String, dynamic>?) ?? const {};
      if (sessionId.isEmpty) {
        throw const LanSendException('Missing upload sessionId');
      }
      _activeSessionId = sessionId;

      // 2. Stream each accepted file
      var cumulativeSent = 0;
      final sw = Stopwatch()..start();
      var lastNotifyMs = 0;

      for (final entry in idToFile.entries) {
        if (_canceled) throw const LanSendException('Transfer canceled');
        final fileId = entry.key;
        final file = entry.value;
        final token = tokens[fileId]?.toString();
        if (token == null || token.isEmpty) continue;

        final uploadUri = Uri.parse(
          '$baseUrl${LanConstants.pathUpload}'
          '?sessionId=${Uri.encodeQueryComponent(sessionId)}'
          '&fileId=${Uri.encodeQueryComponent(fileId)}'
          '&token=${Uri.encodeQueryComponent(token)}',
        );

        final req = await client.postUrl(uploadUri);
        req.contentLength = file.size;
        req.headers.contentType = ContentType.binary;

        await for (final chunk in PlatformBridge.instance.openFileReadStream(file)) {
          if (_canceled) {
            req.abort();
            throw const LanSendException('Transfer canceled');
          }
          req.add(chunk);
          cumulativeSent += chunk.length;

          final elapsedMs = sw.elapsedMilliseconds;
          if (elapsedMs - lastNotifyMs >= 80) {
            lastNotifyMs = elapsedMs;
            final bps =
                elapsedMs > 0 ? cumulativeSent / (elapsedMs / 1000.0) : 0.0;
            onProgress(file.name, cumulativeSent, totalBatchBytes, bps);
          }
        }

        final resp = await req.close();
        await resp.drain<void>();
        if (resp.statusCode != HttpStatus.ok) {
          throw LanSendException('Upload HTTP ${resp.statusCode}');
        }
        onProgress(
          file.name,
          cumulativeSent,
          totalBatchBytes,
          sw.elapsedMilliseconds > 0
              ? cumulativeSent / (sw.elapsedMilliseconds / 1000.0)
              : 0.0,
        );
      }
    } finally {
      _activeClient = null;
      _activeSessionId = null;
      _activeDevice = null;
      client.close(force: true);
    }
  }
}
