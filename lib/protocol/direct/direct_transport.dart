import 'dart:async';

import '../../models/models.dart';
import '../engine/transport_channel.dart';
import '../engine/transport_models.dart';
import 'md_constants.dart';
import 'md_discovery.dart';
import 'md_receiver.dart';
import 'md_sender.dart';

/// [TransportChannel] adapter for the native MaterialDrop Direct protocol.
class DirectTransport implements TransportChannel {
  final String instanceId;
  final bool multiInstance;
  final bool treatLoopbackAsUsb;
  final bool Function(String senderName, String senderIp) isTrustedFn;
  final bool Function() autoAcceptAllFn;
  final bool Function() autoAcceptTrustedFn;

  late final MaterialDropReceiver _receiver;
  late final MaterialDropDiscovery _discovery;
  final MaterialDropSender _sender = MaterialDropSender();

  final StreamController<List<NearbyDevice>> _devicesCtrl =
      StreamController<List<NearbyDevice>>.broadcast();
  final StreamController<TransportEvent> _eventsCtrl =
      StreamController<TransportEvent>.broadcast();

  final Map<String, NearbyDevice> _peers = {};
  int? _configuredPort;
  bool _running = false;

  DirectTransport({
    required String deviceName,
    required String downloadDir,
    required this.instanceId,
    this.multiInstance = false,
    this.treatLoopbackAsUsb = true,
    required this.isTrustedFn,
    required this.autoAcceptAllFn,
    required this.autoAcceptTrustedFn,
  }) {
    _receiver = MaterialDropReceiver(
      instanceId: instanceId,
      deviceName: deviceName,
      downloadDir: downloadDir,
      treatLoopbackAsUsb: treatLoopbackAsUsb,
      isTrustedFn: isTrustedFn,
      autoAcceptAllFn: autoAcceptAllFn,
      autoAcceptTrustedFn: autoAcceptTrustedFn,
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
      onCompleted: (offer, item) => _eventsCtrl.add(
        TransportIncomingCompleted(id, offer, [item], const []),
      ),
      onCanceled: () => _eventsCtrl.add(TransportIncomingCanceled(id)),
      onError: (msg) => _eventsCtrl.add(TransportIncomingError(id, msg)),
    );

    _discovery = MaterialDropDiscovery(
      instanceId: instanceId,
      multiInstance: multiInstance,
      deviceNameFn: () => _receiver.deviceName,
      localPortFn: () => _receiver.port > 0
          ? _receiver.port
          : (_configuredPort ?? MdConstants.localHttpPort),
      onDeviceFound: (dev) {
        final tagged = dev.copyWith(channelId: id);
        _peers[tagged.id] = tagged;
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
  String get id => 'direct';

  @override
  TransportKind get kind => TransportKind.direct;

  @override
  int get priority => 10;

  @override
  bool get isAvailable => _running;

  @override
  int get boundPort => _receiver.port;

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
    _configuredPort = explicitPort;
    await _receiver.start(
      explicitPort: explicitPort,
      bindAddress: bindAddress,
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
      TransportOutgoingConnecting(
        id,
        device.name,
        TransferProtocol.materialDrop,
      ),
    );

    await _sender.sendBatch(
      device: device,
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
            TransferProtocol.materialDrop,
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
        TransferProtocol.materialDrop,
        files,
      ),
    );
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
    _receiver.setDecision(false);
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
