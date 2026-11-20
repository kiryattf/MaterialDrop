import 'dart:async';

import '../../models/models.dart';
import '../engine/transport_channel.dart';
import '../engine/transport_models.dart';
import 'lan_constants.dart';
import 'lan_discovery.dart';
import 'lan_receiver.dart';
import 'lan_sender.dart';
import 'tls_identity.dart';

/// Unified [TransportChannel] implementing LAN discovery and HTTP/HTTPS v2
/// streaming transfers with explicit TLS SHA-256 fingerprint validation.
class LanTransport implements TransportChannel {
  final TlsIdentity identity;
  final bool multiInstance;
  final bool useHttps;
  final bool Function(String senderName, String senderIp) isTrustedFn;
  final bool Function() autoAcceptAllFn;
  final bool Function() autoAcceptTrustedFn;

  late final LanReceiver _receiver;
  late final LanDiscovery _discovery;
  final LanSender _sender = LanSender();

  final StreamController<List<NearbyDevice>> _devicesCtrl =
      StreamController<List<NearbyDevice>>.broadcast();
  final StreamController<TransportEvent> _eventsCtrl =
      StreamController<TransportEvent>.broadcast();

  final Map<String, NearbyDevice> _peers = {};
  bool _running = false;

  LanTransport({
    required String deviceName,
    required String downloadDir,
    TlsIdentity? identity,
    this.multiInstance = false,
    this.useHttps = true,
    required this.isTrustedFn,
    required this.autoAcceptAllFn,
    required this.autoAcceptTrustedFn,
  }) : identity = identity ?? TlsIdentity.generate(commonName: deviceName) {
    _receiver = LanReceiver(
      deviceName: deviceName,
      downloadDir: downloadDir,
      identity: this.identity,
      isTrustedFn: isTrustedFn,
      autoAcceptAllFn: autoAcceptAllFn,
      autoAcceptTrustedFn: autoAcceptTrustedFn,
      onPeerRegistered: (info, remoteIp) {
        if (remoteIp.isNotEmpty) {
          _discovery.ingestPeerAnnouncement(info, remoteIp);
        }
      },
      onOffer: (offer) =>
          _eventsCtrl.add(TransportIncomingOffer(id, offer)),
      onProgress: (offer, fileName, received, total, speed) =>
          _eventsCtrl.add(
        TransportIncomingProgress(
          id,
          offer,
          fileName,
          received,
          total,
          speed,
        ),
      ),
      onCompleted: (offer, items) => _eventsCtrl.add(
        TransportIncomingCompleted(id, offer, items, const []),
      ),
      onCanceled: () => _eventsCtrl.add(TransportIncomingCanceled(id)),
      onError: (msg) => _eventsCtrl.add(TransportIncomingError(id, msg)),
      onGestureEvent: (g) => _eventsCtrl.add(TransportPreGesture(id, g)),
    );

    _discovery = LanDiscovery(
      multiInstance: multiInstance,
      deviceNameFn: () => _receiver.deviceName,
      localPortFn: () =>
          _receiver.port > 0 ? _receiver.port : LanConstants.defaultPort,
      fingerprintFn: () => this.identity.fingerprint,
      useHttpsFn: () => _receiver.useHttps,
      onDeviceFound: (dev) {
        _peers[dev.id] = dev;
        _emitDevices();
      },
      onDeviceExpired: (devId) {
        if (_peers.remove(devId) != null) {
          _emitDevices();
        }
      },
    );
  }

  @override
  String get id => 'lan';

  @override
  TransportKind get kind => TransportKind.lan;

  @override
  int get priority => 20;

  @override
  bool get isAvailable => _running;

  @override
  int get boundPort => _receiver.port;

  String get fingerprint => identity.fingerprint;

  @override
  Stream<List<NearbyDevice>> get devicesStream => _devicesCtrl.stream;

  @override
  Stream<TransportEvent> get eventsStream => _eventsCtrl.stream;

  void _emitDevices() {
    if (!_devicesCtrl.isClosed) {
      _devicesCtrl.add(List.unmodifiable(_peers.values));
    }
  }

  @override
  Future<void> start({int? explicitPort, String? bindAddress}) async {
    if (_running) return;
    await _receiver.start(
      explicitPort: explicitPort,
      bindAddress: bindAddress,
      useHttps: useHttps,
    );
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _discovery.stopDiscovery();
    await _receiver.stop();
    _peers.clear();
    _emitDevices();
  }

  @override
  Future<void> startDiscovery() => _discovery.startDiscovery();

  @override
  Future<void> stopDiscovery() async {
    await _discovery.stopDiscovery();
    _peers.clear();
    _emitDevices();
  }

  @override
  Future<void> refreshDiscovery() => _discovery.triggerImmediateRefresh();

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
      TransportOutgoingConnecting(id, device.name, TransferProtocol.lan),
    );

    try {
      await _sender.sendBatch(
        device: device,
        localDeviceName: localDeviceName,
        localPort: boundPort > 0 ? boundPort : LanConstants.defaultPort,
        localFingerprint: identity.fingerprint,
        localUseHttps: _receiver.useHttps,
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
              TransferProtocol.lan,
            ),
          );
        },
      );
      _eventsCtrl.add(
        TransportOutgoingCompleted(
          id,
          device.name,
          displayTitle,
          files.length,
          TransferProtocol.lan,
          files,
        ),
      );
    } on LanSendException catch (e) {
      if (e.message == 'Transfer canceled') {
        _eventsCtrl.add(TransportOutgoingCanceled(id));
        return;
      }
      rethrow;
    }
  }

  @override
  Future<void> acceptOffer(String offerId) async {
    _receiver.setDecision(true);
  }

  @override
  Future<void> declineOffer(String offerId) async {
    _receiver.setDecision(false);
  }

  @override
  Future<void> cancelTransfer({String? offerId}) async {
    _sender.cancel();
    await _receiver.cancelActive();
  }

  @override
  Future<void> updateConfig({String? deviceName, String? downloadDir}) async {
    if (deviceName != null) {
      _receiver.deviceName = deviceName;
    }
    if (downloadDir != null) {
      _receiver.downloadDir = downloadDir;
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _discovery.dispose();
    await _devicesCtrl.close();
    await _eventsCtrl.close();
  }
}
