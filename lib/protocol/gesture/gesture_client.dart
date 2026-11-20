import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/models.dart';
import '../lan/tls_identity.dart';
import 'gesture_models.dart';

/// Persistent per-target WebSocket client for `/ws/gesture` pre-gesture triggers.
class GestureClient {
  WebSocket? _socket;
  String? _targetKey;
  bool _connecting = false;
  DateTime _lastProgressSentAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool _supportsWs(NearbyDevice device) {
    if (device.protocol == TransferProtocol.materialDrop ||
        device.protocol == TransferProtocol.lan) {
      return device.ip.isNotEmpty && device.port > 0;
    }
    if (device.protocol == TransferProtocol.tapProximity &&
        device.ip.isNotEmpty &&
        !device.ip.contains(':') &&
        device.port > 0) {
      return true;
    }
    return false;
  }

  Future<WebSocket?> _ensureConnected(NearbyDevice device) async {
    if (!_supportsWs(device)) return null;
    final scheme = device.useHttps ? 'wss' : 'ws';
    final url = '$scheme://${device.ip}:${device.port}/ws/gesture';
    if (_socket != null &&
        _targetKey == url &&
        _socket!.readyState == WebSocket.open) {
      return _socket;
    }
    if (_connecting) return null;

    _connecting = true;
    try {
      await close();
      final HttpClient? customClient = device.useHttps
          ? TlsIdentity.createPinnedClient(
              expectedFingerprint: device.tlsFingerprint,
              connectionTimeout: const Duration(seconds: 3),
            )
          : null;
      final ws = await WebSocket.connect(url, customClient: customClient)
          .timeout(const Duration(seconds: 3));
      _socket = ws;
      _targetKey = url;
      ws.listen(
        (_) {},
        onDone: () {
          if (_socket == ws) {
            _socket = null;
            _targetKey = null;
          }
        },
        onError: (_) {
          if (_socket == ws) {
            _socket = null;
            _targetKey = null;
          }
        },
      );
      return ws;
    } catch (_) {
      return null;
    } finally {
      _connecting = false;
    }
  }

  Future<void> sendTrigger(
    NearbyDevice device,
    GesturePreviewEvent payload,
  ) async {
    final ws = await _ensureConnected(device);
    if (ws == null) return;
    try {
      ws.add(jsonEncode(payload.toJson()));
    } catch (_) {
      await close();
    }
  }

  Future<void> sendProgress(
    NearbyDevice device,
    GesturePreviewEvent payload,
  ) async {
    final now = DateTime.now();
    if (now.difference(_lastProgressSentAt).inMilliseconds < 40) return;
    _lastProgressSentAt = now;
    final ws = await _ensureConnected(device);
    if (ws == null) return;
    try {
      ws.add(jsonEncode(payload.toJson()));
    } catch (_) {
      await close();
    }
  }

  Future<void> sendCancel(
    NearbyDevice device, {
    required String senderName,
  }) async {
    final ws = await _ensureConnected(device);
    if (ws == null) return;
    try {
      ws.add(jsonEncode({
        'type': 'drop_gesture_cancel',
        'senderName': senderName,
      }));
    } catch (_) {
      await close();
    }
  }

  Future<void> close() async {
    final s = _socket;
    _socket = null;
    _targetKey = null;
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
    }
  }
}
