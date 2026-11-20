import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/models.dart';
import '../direct/md_sender.dart';
import '../engine/transport_channel.dart';
import '../engine/transport_models.dart';
import '../lan/lan_sender.dart';
import '../quickshare/qs_crypto.dart';
import 'proximity_bridge.dart';

/// Autonomous proximity transport (BLE Advertising + EMA RSSI + NFC HCE + Direct Wi-Fi)
/// enabling peer discovery and transfer when router Wi-Fi is off or guest AP Isolation blocks LAN.
class TapProximityTransport implements TransportChannel {
  final int Function() transferPortFn;
  final String Function() localFingerprintFn;
  final String Function() deviceNameFn;
  final void Function(String ticketOrLink, String fallbackName)?
      onIrohTicketReceived;

  final ProximityBridge _bridge = ProximityBridge.instance;
  final RssiEmaFilter _rssiFilter = RssiEmaFilter(alpha: 0.35);
  final LanSender _lanSender = LanSender();
  final MaterialDropSender _mdSender = MaterialDropSender();

  final StreamController<List<NearbyDevice>> _devicesCtrl =
      StreamController<List<NearbyDevice>>.broadcast();
  final StreamController<TransportEvent> _eventsCtrl =
      StreamController<TransportEvent>.broadcast();

  final Map<String, NearbyDevice> _peers = {};
  final Map<String, ProximityHandshakeEvent> _handshakesByPeer = {};
  final Map<String, DateTime> _seenAt = {};

  StreamSubscription<ProximityPeerEvent>? _bleSub;
  StreamSubscription<ProximityHandshakeEvent>? _handshakeSub;
  Timer? _rotationTimer;
  Timer? _pruneTimer;

  Uint8List _ephemeralId = QsCrypto.randomBytes(16);
  var _ecKeyPair = QsCrypto.generateKeyPair();
  bool _running = false;
  bool _discovering = false;
  bool _radarVisible = false;
  bool _hostingDirectWifi = false;
  String _localIrohTicket = '';
  ProximityStatus _lastStatus = const ProximityStatus();

  TapProximityTransport({
    required this.transferPortFn,
    required this.localFingerprintFn,
    required this.deviceNameFn,
    this.onIrohTicketReceived,
  });

  Future<void> updateIrohTicket(String ticketOrLink) async {
    _localIrohTicket = ticketOrLink;
    if (_running) {
      await _bridge.updateSessionMetadata(
        deviceName: deviceNameFn(),
        port: transferPortFn(),
        fingerprint: localFingerprintFn(),
        irohTicket: _localIrohTicket,
      );
    }
  }

  @override
  String get id => 'tap_proximity';

  @override
  TransportKind get kind => TransportKind.tapProximity;

  @override
  int get priority => 40;

  @override
  bool get isAvailable => _running;

  @override
  int get boundPort => transferPortFn();

  ProximityStatus get lastStatus => _lastStatus;
  String get localEphemeralHex => _ephemeralId
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  @override
  Stream<List<NearbyDevice>> get devicesStream => _devicesCtrl.stream;

  @override
  Stream<TransportEvent> get eventsStream => _eventsCtrl.stream;

  void _emitDevices() {
    if (!_devicesCtrl.isClosed) {
      _devicesCtrl.add(List.unmodifiable(_peers.values));
    }
  }

  Future<ProximityStatus> refreshStatus() async {
    _lastStatus = await _bridge.getStatus();
    return _lastStatus;
  }

  Future<bool> requestPermissions() async {
    final ok = await _bridge.requestPermissions();
    await refreshStatus();
    return ok;
  }

  Future<void> setRadarVisible(bool visible) async {
    _radarVisible = visible;
    if (Platform.isAndroid && _running) {
      await _bridge.setNfcReaderEnabled(visible);
      if (_discovering) {
        await _bridge.startBleDiscovery(
          port: transferPortFn(),
          ephemeralBytes: _ephemeralId,
          lowLatency: visible,
        );
      }
    }
  }

  @override
  Future<void> start({int? explicitPort, String? bindAddress}) async {
    if (_running) return;
    _running = true;
    _bridge.ensureBound();

    await _bridge.updateSessionMetadata(
      deviceName: deviceNameFn(),
      port: transferPortFn(),
      fingerprint: localFingerprintFn(),
      irohTicket: _localIrohTicket.isNotEmpty ? _localIrohTicket : null,
    );

    _bleSub = _bridge.blePeerStream.listen(_onBlePeerFound);
    _handshakeSub = _bridge.handshakeStream.listen(_onHandshakeReceived);

    _rotationTimer?.cancel();
    _rotationTimer = Timer.periodic(const Duration(minutes: 15), (_) async {
      _ephemeralId = QsCrypto.randomBytes(16);
      _ecKeyPair = QsCrypto.generateKeyPair();
      if (_discovering) {
        await _bridge.startBleDiscovery(
          port: transferPortFn(),
          ephemeralBytes: _ephemeralId,
          lowLatency: _radarVisible,
        );
      }
    });

    await refreshStatus();
  }

  @override
  Future<void> stop() async {
    _running = false;
    await stopDiscovery();
    _rotationTimer?.cancel();
    _rotationTimer = null;
    await _bleSub?.cancel();
    _bleSub = null;
    await _handshakeSub?.cancel();
    _handshakeSub = null;
    await _bridge.setNfcReaderEnabled(false);
    if (_hostingDirectWifi) {
      await _bridge.stopDirectWifiHost();
      _hostingDirectWifi = false;
    }
    await _bridge.disconnectDirectWifi();
  }

  @override
  Future<void> startDiscovery() async {
    if (!_running) return;
    _discovering = true;
    await _bridge.updateSessionMetadata(
      deviceName: deviceNameFn(),
      port: transferPortFn(),
      fingerprint: localFingerprintFn(),
      irohTicket: _localIrohTicket.isNotEmpty ? _localIrohTicket : null,
    );
    await _bridge.startBleDiscovery(
      port: transferPortFn(),
      ephemeralBytes: _ephemeralId,
      lowLatency: _radarVisible,
    );
    if (Platform.isAndroid && _radarVisible) {
      await _bridge.setNfcReaderEnabled(true);
    }
    _pruneTimer?.cancel();
    _pruneTimer = Timer.periodic(
      const Duration(seconds: 6),
      (_) => _pruneExpired(),
    );
    await refreshStatus();
  }

  @override
  Future<void> stopDiscovery() async {
    _discovering = false;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _rssiFilter.clear();
    await _bridge.stopBleDiscovery();
    await _bridge.setNfcReaderEnabled(false);
    _peers.clear();
    _seenAt.clear();
    _emitDevices();
  }

  @override
  Future<void> refreshDiscovery() async {
    if (!_running) return;
    await _bridge.startBleDiscovery(
      port: transferPortFn(),
      ephemeralBytes: _ephemeralId,
      lowLatency: true,
    );
    await refreshStatus();
  }

  void _onBlePeerFound(ProximityPeerEvent ev) {
    if (ev.ephemeralId.toUpperCase() == localEphemeralHex) return;

    final peerId = 'tap:${ev.ephemeralId.toUpperCase()}';
    final smoothed = _rssiFilter.update(peerId, ev.rssi);
    final zone = RssiEmaFilter.classifyZone(smoothed);
    final handshake = _handshakesByPeer[peerId];

    _seenAt[peerId] = DateTime.now();
    _peers[peerId] = NearbyDevice(
      id: peerId,
      name: (handshake?.name.isNotEmpty == true) ? handshake!.name : ev.name,
      ip: (handshake?.wifiIp.isNotEmpty == true)
          ? handshake!.wifiIp
          : ev.bleAddress,
      port: (handshake != null && handshake.port > 0)
          ? handshake.port
          : ev.port,
      kind: DeviceKind.phone,
      protocol: TransferProtocol.tapProximity,
      isUsb: false,
      endpointId: ev.bleAddress,
      instanceId: ev.ephemeralId.toUpperCase(),
      channelId: id,
      tlsFingerprint:
          (handshake?.fingerprint.isNotEmpty == true) ? handshake!.fingerprint : null,
      useHttps: handshake?.fingerprint.isNotEmpty == true,
      rssi: smoothed,
      proximityZone: zone,
      irohTicket:
          (handshake?.irohTicket.isNotEmpty == true) ? handshake!.irohTicket : null,
      lastSeen: DateTime.now(),
    );
    _emitDevices();
  }

  Future<void> _onHandshakeReceived(ProximityHandshakeEvent ev) async {
    final keySuffix = ev.ephemeralId.isNotEmpty
        ? ev.ephemeralId.toUpperCase()
        : ev.name.toUpperCase();
    final peerId = 'tap:$keySuffix';

    // Validate peer ECDH public key when provided
    if (ev.ecPubB64.isNotEmpty) {
      try {
        ProximityBridge.deriveEcdhSessionKey(_ecKeyPair.privateKey, ev.ecPubB64);
      } catch (_) {
        return;
      }
    }

    // If a remote peer touched us over NFC/GATT asking to connect via direct Wi-Fi
    // and we don't have a hotspot active yet, automatically bring up LocalOnlyHotspot
    if (Platform.isAndroid &&
        (ev.source == 'nfc_hce' || ev.source == 'ble_gatt') &&
        !ev.hasDirectWifiCredentials &&
        !_hostingDirectWifi) {
      final hostInfo = await _bridge.startDirectWifiHost();
      if (hostInfo != null) {
        _hostingDirectWifi = true;
      }
    }

    if (ev.irohTicket.isNotEmpty) {
      onIrohTicketReceived?.call(
        ev.irohTicket,
        ev.name.isNotEmpty ? ev.name : 'Nearby Device',
      );
    }

    _handshakesByPeer[peerId] = ev;
    _seenAt[peerId] = DateTime.now();
    final existing = _peers[peerId];
    _peers[peerId] = NearbyDevice(
      id: peerId,
      name: ev.name.isNotEmpty ? ev.name : (existing?.name ?? 'Nearby Device'),
      ip: ev.wifiIp.isNotEmpty ? ev.wifiIp : (existing?.ip ?? ''),
      port: ev.port > 0 ? ev.port : (existing?.port ?? 53317),
      kind: DeviceKind.phone,
      protocol: TransferProtocol.tapProximity,
      isUsb: false,
      endpointId: existing?.endpointId,
      instanceId: keySuffix,
      channelId: id,
      tlsFingerprint: ev.fingerprint.isNotEmpty ? ev.fingerprint : null,
      useHttps: ev.fingerprint.isNotEmpty,
      rssi: ev.source.startsWith('nfc') ? -38 : (existing?.rssi ?? -55),
      proximityZone:
          ev.source.startsWith('nfc') ? 'immediate' : (existing?.proximityZone ?? 'near'),
      irohTicket: ev.irohTicket.isNotEmpty ? ev.irohTicket : existing?.irohTicket,
      lastSeen: DateTime.now(),
    );
    _emitDevices();
  }

  @override
  Future<void> sendOffer(
    NearbyDevice device,
    List<StagedFile> files, {
    required String localDeviceName,
  }) async {
    if (files.isEmpty) return;
    final totalSize = files.fold<int>(0, (s, f) => s + f.size);
    final displayTitle = files.length == 1
        ? files.first.name
        : '${files.first.name} (+${files.length - 1})';

    _eventsCtrl.add(
      TransportOutgoingConnecting(
        id,
        device.name,
        TransferProtocol.tapProximity,
      ),
    );

    var handshake = _handshakesByPeer[device.id];
    final bleAddr = device.endpointId ?? '';

    // Step 1: If peer was discovered only via BLE and hasn't exchanged credentials yet,
    // perform BLE GATT handshake (and optionally offer our own LocalOnlyHotspot).
    if ((handshake == null || !handshake.hasDirectWifiCredentials) &&
        Platform.isAndroid &&
        bleAddr.isNotEmpty) {
      final pubPoint = _ecKeyPair.publicKey.Q!.getEncoded(false);
      final resp = await _bridge.exchangeGattHandshake(
        bleAddress: bleAddr,
        outgoingPayload: {
          'n': localDeviceName,
          'e': localEphemeralHex,
          'k': base64Encode(pubPoint),
          'p': transferPortFn(),
          'f': localFingerprintFn(),
        },
      );
      if (resp != null) {
        handshake = resp;
        _handshakesByPeer[device.id] = resp;
      }
    }

    var targetIp = handshake?.wifiIp.isNotEmpty == true
        ? handshake!.wifiIp
        : device.ip;
    var targetPort =
        (handshake != null && handshake.port > 0) ? handshake.port : device.port;
    final targetFp = (handshake?.fingerprint.isNotEmpty == true)
        ? handshake!.fingerprint
        : (device.tlsFingerprint ?? '');

    var connectedDirectWifi = false;
    try {
      // Step 2: Bring up direct router-free Wi-Fi link if credentials were exchanged
      if (Platform.isAndroid &&
          handshake != null &&
          handshake.wifiSsid.isNotEmpty &&
          handshake.wifiPass.isNotEmpty) {
        final gateway = await _bridge.connectDirectWifi(
          ssid: handshake.wifiSsid,
          passphrase: handshake.wifiPass,
        );
        if (gateway != null && gateway.isNotEmpty) {
          connectedDirectWifi = true;
          if (handshake.wifiIp.isEmpty) {
            targetIp = gateway;
          }
        }
      }

      if (targetIp.isEmpty || targetIp.contains(':')) {
        // Never attempt IP socket connection using a raw MAC address
        throw const SocketException(
          'Proximity peer does not yet have an active Wi-Fi direct or LAN address',
        );
      }

      final routeDevice = device.copyWith(
        ip: targetIp,
        port: targetPort,
        tlsFingerprint: targetFp.isNotEmpty ? targetFp : null,
        useHttps: targetFp.isNotEmpty,
      );

      if (targetFp.isNotEmpty) {
        await _lanSender.sendBatch(
          device: routeDevice,
          localDeviceName: localDeviceName,
          localPort: transferPortFn(),
          localFingerprint: localFingerprintFn(),
          localUseHttps: true,
          files: files,
          onProgress: (fileName, sent, total, speed) {
            _eventsCtrl.add(
              TransportOutgoingProgress(
                id,
                device.name,
                fileName,
                sent,
                total > 0 ? total : totalSize,
                speed,
                TransferProtocol.tapProximity,
              ),
            );
          },
        );
      } else {
        await _mdSender.sendBatch(
          device: routeDevice,
          localDeviceName: localDeviceName,
          files: files,
          onProgress: (fileName, sent, total, speed) {
            _eventsCtrl.add(
              TransportOutgoingProgress(
                id,
                device.name,
                fileName,
                sent,
                total > 0 ? total : totalSize,
                speed,
                TransferProtocol.tapProximity,
              ),
            );
          },
        );
      }

      _eventsCtrl.add(
        TransportOutgoingCompleted(
          id,
          device.name,
          displayTitle,
          files.length,
          TransferProtocol.tapProximity,
          files,
        ),
      );
    } finally {
      if (connectedDirectWifi) {
        await _bridge.disconnectDirectWifi();
      }
    }
  }

  @override
  Future<void> acceptOffer(String offerId) async {}

  @override
  Future<void> declineOffer(String offerId) async {}

  @override
  Future<void> cancelTransfer({String? offerId}) async {
    _lanSender.cancel();
    _mdSender.cancel();
    await _bridge.disconnectDirectWifi();
  }

  @override
  Future<void> updateConfig({String? deviceName, String? downloadDir}) async {
    if (!_running) return;
    await _bridge.updateSessionMetadata(
      deviceName: deviceName ?? deviceNameFn(),
      port: transferPortFn(),
      fingerprint: localFingerprintFn(),
    );
  }

  void _pruneExpired() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 25));
    final expired = _seenAt.entries
        .where((e) => e.value.isBefore(cutoff))
        .map((e) => e.key)
        .toList();
    if (expired.isEmpty) return;
    for (final k in expired) {
      _seenAt.remove(k);
      _peers.remove(k);
    }
    _emitDevices();
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _devicesCtrl.close();
    await _eventsCtrl.close();
  }
}
