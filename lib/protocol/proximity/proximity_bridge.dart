import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:pointycastle/export.dart';

import '../quickshare/qs_crypto.dart';

/// Exponential moving average filter for BLE RSSI measurements and proximity classification.
class RssiEmaFilter {
  final double alpha;
  final Map<String, double> _values = {};

  RssiEmaFilter({this.alpha = 0.35});

  int update(String key, int rawRssi) {
    final prev = _values[key];
    final next =
        prev == null ? rawRssi.toDouble() : alpha * rawRssi + (1.0 - alpha) * prev;
    _values[key] = next;
    return next.round();
  }

  void clear() => _values.clear();

  static String classifyZone(int rssi) {
    if (rssi >= -55) return 'immediate';
    if (rssi >= -75) return 'near';
    return 'far';
  }

  static double orbitFactorForZone(String? zone) {
    return switch (zone) {
      'immediate' => 0.40,
      'near' => 0.64,
      _ => 0.86,
    };
  }
}

class BleAdapterStatus {
  final bool supported;
  final bool adapterAvailable;
  final bool adapterEnabled;
  final bool permissionsGranted;
  final bool scanning;
  final bool advertising;
  final String reason;

  const BleAdapterStatus({
    this.supported = false,
    this.adapterAvailable = false,
    this.adapterEnabled = false,
    this.permissionsGranted = false,
    this.scanning = false,
    this.advertising = false,
    this.reason = 'unsupported',
  });

  factory BleAdapterStatus.fromMap(Map<dynamic, dynamic>? raw) {
    if (raw == null) return const BleAdapterStatus();
    return BleAdapterStatus(
      supported: raw['supported'] == true,
      adapterAvailable: raw['adapterAvailable'] == true,
      adapterEnabled: raw['adapterEnabled'] == true,
      permissionsGranted: raw['permissionsGranted'] == true,
      scanning: raw['scanning'] == true,
      advertising: raw['advertising'] == true,
      reason: raw['reason'] as String? ?? 'unsupported',
    );
  }
}

class ProximityStatus {
  final bool supported;
  final BleAdapterStatus ble;
  final bool nfcSupported;
  final bool nfcEnabled;
  final bool nfcReaderActive;
  final bool wifiDirectSupported;
  final bool wifiDirectPermissionsGranted;
  final String ephemeralId;

  const ProximityStatus({
    this.supported = false,
    this.ble = const BleAdapterStatus(),
    this.nfcSupported = false,
    this.nfcEnabled = false,
    this.nfcReaderActive = false,
    this.wifiDirectSupported = false,
    this.wifiDirectPermissionsGranted = false,
    this.ephemeralId = '',
  });

  factory ProximityStatus.fromMap(Map<dynamic, dynamic>? raw) {
    if (raw == null) return const ProximityStatus();
    return ProximityStatus(
      supported: raw['supported'] == true,
      ble: BleAdapterStatus.fromMap(raw['ble'] as Map<dynamic, dynamic>?),
      nfcSupported: raw['nfcSupported'] == true,
      nfcEnabled: raw['nfcEnabled'] == true,
      nfcReaderActive: raw['nfcReaderActive'] == true,
      wifiDirectSupported: raw['wifiDirectSupported'] == true,
      wifiDirectPermissionsGranted: raw['wifiDirectPermissionsGranted'] == true,
      ephemeralId: raw['ephemeralId'] as String? ?? '',
    );
  }
}

class ProximityPeerEvent {
  final String bleAddress;
  final String ephemeralId;
  final String name;
  final int port;
  final int capabilities;
  final int rssi;
  final String proximityZone;

  const ProximityPeerEvent({
    required this.bleAddress,
    required this.ephemeralId,
    required this.name,
    required this.port,
    required this.capabilities,
    required this.rssi,
    required this.proximityZone,
  });

  factory ProximityPeerEvent.fromMap(Map<dynamic, dynamic> map) {
    final rssi = (map['rssi'] as num?)?.toInt() ?? -70;
    return ProximityPeerEvent(
      bleAddress: map['bleAddress'] as String? ?? '',
      ephemeralId: map['ephemeralId'] as String? ?? '',
      name: map['name'] as String? ?? 'Nearby Device',
      port: (map['port'] as num?)?.toInt() ?? 53317,
      capabilities: (map['capabilities'] as num?)?.toInt() ?? 0,
      rssi: rssi,
      proximityZone:
          map['proximityZone'] as String? ?? RssiEmaFilter.classifyZone(rssi),
    );
  }
}

class ProximityHandshakeEvent {
  final String source;
  final String name;
  final String ephemeralId;
  final String ecPubB64;
  final int port;
  final String fingerprint;
  final String wifiSsid;
  final String wifiPass;
  final String wifiIp;
  final String irohTicket;

  const ProximityHandshakeEvent({
    required this.source,
    required this.name,
    required this.ephemeralId,
    required this.ecPubB64,
    required this.port,
    required this.fingerprint,
    required this.wifiSsid,
    required this.wifiPass,
    required this.wifiIp,
    required this.irohTicket,
  });

  bool get hasDirectWifiCredentials =>
      wifiSsid.isNotEmpty && wifiPass.isNotEmpty && wifiIp.isNotEmpty;

  factory ProximityHandshakeEvent.fromMap(
    String source,
    Map<dynamic, dynamic> map,
  ) {
    return ProximityHandshakeEvent(
      source: source,
      name: map['name'] as String? ?? map['n'] as String? ?? 'Nearby Device',
      ephemeralId: map['ephemeralId'] as String? ?? map['e'] as String? ?? '',
      ecPubB64: map['ecPubB64'] as String? ?? map['k'] as String? ?? '',
      port: (map['port'] as num?)?.toInt() ??
          (map['p'] as num?)?.toInt() ??
          53317,
      fingerprint:
          map['fingerprint'] as String? ?? map['f'] as String? ?? '',
      wifiSsid: map['wifiSsid'] as String? ?? map['s'] as String? ?? '',
      wifiPass: map['wifiPass'] as String? ?? map['w'] as String? ?? '',
      wifiIp: map['wifiIp'] as String? ?? map['i'] as String? ?? '',
      irohTicket: map['irohTicket'] as String? ?? map['t'] as String? ?? '',
    );
  }
}

class DirectWifiHostInfo {
  final String mode;
  final String ssid;
  final String passphrase;
  final String hostIp;

  const DirectWifiHostInfo({
    required this.mode,
    required this.ssid,
    required this.passphrase,
    required this.hostIp,
  });
}

class ProximityBridge {
  static const _method = MethodChannel('dev.materialdrop.flutter/proximity');
  static const _events = EventChannel('dev.materialdrop.flutter/proximity_events');

  static final ProximityBridge instance = ProximityBridge._();
  ProximityBridge._();

  final StreamController<ProximityPeerEvent> _blePeersCtrl =
      StreamController<ProximityPeerEvent>.broadcast();
  final StreamController<ProximityHandshakeEvent> _handshakesCtrl =
      StreamController<ProximityHandshakeEvent>.broadcast();

  bool _bound = false;
  StreamSubscription<dynamic>? _eventSub;

  Stream<ProximityPeerEvent> get blePeerStream => _blePeersCtrl.stream;
  Stream<ProximityHandshakeEvent> get handshakeStream => _handshakesCtrl.stream;

  bool get isPlatformSupported =>
      Platform.isAndroid || Platform.isWindows || Platform.isLinux;

  void ensureBound() {
    if (_bound || !isPlatformSupported) return;
    _bound = true;

    _method.setMethodCallHandler((call) async {
      if (call.method == 'onProximityEvent' && call.arguments is Map) {
        _dispatchEvent(call.arguments as Map<dynamic, dynamic>);
      }
    });

    if (Platform.isAndroid) {
      _eventSub = _events.receiveBroadcastStream().listen(
        (ev) {
          if (ev is Map) _dispatchEvent(ev);
        },
        onError: (_) {},
      );
    }
  }

  void _dispatchEvent(Map<dynamic, dynamic> map) {
    final type = map['type'] as String? ?? '';
    if (type == 'blePeerFound') {
      _blePeersCtrl.add(ProximityPeerEvent.fromMap(map));
    } else if (type == 'handshake') {
      final src = map['source'] as String? ?? 'unknown';
      final peer = map['peer'] as Map<dynamic, dynamic>?;
      if (peer != null) {
        _handshakesCtrl.add(ProximityHandshakeEvent.fromMap(src, peer));
      }
    }
  }

  Future<ProximityStatus> getStatus() async {
    if (!isPlatformSupported) return const ProximityStatus();
    ensureBound();
    try {
      final raw = await _method.invokeMapMethod<dynamic, dynamic>(
        'getProximityStatus',
      );
      return ProximityStatus.fromMap(raw);
    } catch (_) {
      return const ProximityStatus();
    }
  }

  Future<bool> requestPermissions() async {
    if (!isPlatformSupported) return false;
    ensureBound();
    try {
      return await _method.invokeMethod<bool>('requestProximityPermissions') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> updateSessionMetadata({
    required String deviceName,
    required int port,
    required String fingerprint,
    String? irohTicket,
  }) async {
    if (!isPlatformSupported) return;
    ensureBound();
    try {
      await _method.invokeMethod('updateSessionMetadata', {
        'deviceName': deviceName,
        'port': port,
        'fingerprint': fingerprint,
        'irohTicket': ?irohTicket,
      });
    } catch (_) {}
  }

  Future<({bool advertising, bool scanning})> startBleDiscovery({
    required int port,
    required Uint8List ephemeralBytes,
    bool lowLatency = true,
  }) async {
    if (!isPlatformSupported) return (advertising: false, scanning: false);
    ensureBound();
    try {
      final raw = await _method.invokeMapMethod<dynamic, dynamic>(
        'startBleDiscovery',
        {
          'port': port,
          'ephemeralBytes': ephemeralBytes,
          'lowLatency': lowLatency,
        },
      );
      return (
        advertising: raw?['advertising'] == true,
        scanning: raw?['scanning'] == true,
      );
    } catch (_) {
      return (advertising: false, scanning: false);
    }
  }

  Future<void> stopBleDiscovery() async {
    if (!isPlatformSupported) return;
    try {
      await _method.invokeMethod('stopBleDiscovery');
    } catch (_) {}
  }

  Future<ProximityHandshakeEvent?> exchangeGattHandshake({
    required String bleAddress,
    required Map<String, dynamic> outgoingPayload,
  }) async {
    if (!Platform.isAndroid) return null;
    ensureBound();
    try {
      final rawJson = await _method.invokeMethod<String>(
        'exchangeGattHandshake',
        {
          'bleAddress': bleAddress,
          'outgoingJson': jsonEncode(outgoingPayload),
        },
      );
      if (rawJson == null || rawJson.isEmpty) return null;
      final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
      return ProximityHandshakeEvent.fromMap('ble_gatt', decoded);
    } catch (_) {
      return null;
    }
  }

  Future<bool> setNfcReaderEnabled(bool enabled) async {
    if (!Platform.isAndroid) return false;
    ensureBound();
    try {
      return await _method.invokeMethod<bool>(
            'setNfcReaderEnabled',
            {'enabled': enabled},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<DirectWifiHostInfo?> startDirectWifiHost() async {
    if (!Platform.isAndroid) return null;
    ensureBound();
    try {
      final raw = await _method.invokeMapMethod<dynamic, dynamic>(
        'startDirectWifiHost',
      );
      if (raw == null) return null;
      final ssid = raw['ssid'] as String? ?? '';
      final pass = raw['passphrase'] as String? ?? '';
      final ip = raw['hostIp'] as String? ?? '';
      if (ssid.isEmpty || pass.isEmpty || ip.isEmpty) return null;
      return DirectWifiHostInfo(
        mode: raw['mode'] as String? ?? 'hotspot',
        ssid: ssid,
        passphrase: pass,
        hostIp: ip,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> stopDirectWifiHost() async {
    if (!Platform.isAndroid) return;
    try {
      await _method.invokeMethod('stopDirectWifiHost');
    } catch (_) {}
  }

  Future<String?> connectDirectWifi({
    required String ssid,
    required String passphrase,
  }) async {
    if (!Platform.isAndroid) return null;
    ensureBound();
    try {
      final raw = await _method.invokeMapMethod<dynamic, dynamic>(
        'connectDirectWifi',
        {
          'ssid': ssid,
          'passphrase': passphrase,
        },
      );
      if (raw?['connected'] == true) {
        return raw?['gatewayIp'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> disconnectDirectWifi() async {
    if (!Platform.isAndroid) return;
    try {
      await _method.invokeMethod('disconnectDirectWifi');
    } catch (_) {}
  }

  /// Derives a 32-byte session token from local & remote uncompressed P-256 keys via ECDH + HKDF.
  static Uint8List deriveEcdhSessionKey(
    ECPrivateKey localPriv,
    String remotePubB64,
  ) {
    final raw = base64Decode(remotePubB64);
    final curve = ECCurve_secp256r1();
    final point = curve.curve.decodePoint(raw);
    if (point == null || point.isInfinity) {
      throw ArgumentError('Invalid P-256 proximity public key');
    }
    final peerPub = ECPublicKey(point, curve);
    final secret = QsCrypto.ecdhSharedSecret(localPriv, peerPub);
    final digest = sha256.convert([
      ...utf8.encode('materialdrop-tap-v1'),
      ...secret,
    ]).bytes;
    return Uint8List.fromList(digest);
  }

  Future<void> dispose() async {
    await _eventSub?.cancel();
    _eventSub = null;
    await _blePeersCtrl.close();
    await _handshakesCtrl.close();
  }
}
