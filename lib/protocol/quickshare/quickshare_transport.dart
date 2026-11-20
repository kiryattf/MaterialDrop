import 'dart:async';

import '../../models/models.dart';
import '../engine/transport_channel.dart';
import '../engine/transport_models.dart';
import 'proto_codec.dart';
import 'qs_mdns_service.dart';
import 'qs_receiver.dart';
import 'qs_sender.dart';

/// [TransportChannel] adapter for Google Quick Share (mDNS + UKEY2 + SecureMessage).
class QuickShareTransport implements TransportChannel {
  final bool Function(String senderName, String senderIp) isTrustedFn;
  final bool Function() autoAcceptAllFn;
  final bool Function() autoAcceptTrustedFn;
  final String Function() declinedMessageFn;

  late final QsMdnsService _mdns;
  late final QsReceiver _receiver;
  final QsSender _sender = QsSender();

  final StreamController<List<NearbyDevice>> _devicesCtrl =
      StreamController<List<NearbyDevice>>.broadcast();
  final StreamController<TransportEvent> _eventsCtrl =
      StreamController<TransportEvent>.broadcast();

  final Map<String, NearbyDevice> _peers = {};
  bool _running = false;
  bool _enabled = true;

  QuickShareTransport({
    required String deviceName,
    required String downloadDir,
    bool enabled = true,
    required this.isTrustedFn,
    required this.autoAcceptAllFn,
    required this.autoAcceptTrustedFn,
    required this.declinedMessageFn,
  }) {
    _enabled = enabled;
    _mdns = QsMdnsService(
      onDeviceFound: (dev) {
        final tagged = dev.copyWith(channelId: id);
        _peers[tagged.id] = tagged;
        _emitDevices();
      },
      onDeviceLost: (instanceName) {
        final toRemove = _peers.keys
            .where((k) => k.endsWith(instanceName))
            .toList();
        var changed = false;
        for (final k in toRemove) {
          if (_peers.remove(k) != null) changed = true;
        }
        if (changed) _emitDevices();
      },
    );

    _receiver = QsReceiver(
      deviceName: deviceName,
      downloadDir: downloadDir,
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
      onCompleted: (offer, items, texts) => _eventsCtrl.add(
        TransportIncomingCompleted(id, offer, items, texts),
      ),
      onCanceled: () => _eventsCtrl.add(TransportIncomingCanceled(id)),
      onError: (msg) => _eventsCtrl.add(TransportIncomingError(id, msg)),
    );
  }

  @override
  String get id => 'quickshare';

  @override
  TransportKind get kind => TransportKind.quickShare;

  @override
  int get priority => 30;

  @override
  bool get isAvailable => _enabled && _running;

  @override
  int get boundPort => _receiver.port;

  bool get isEnabled => _enabled;

  @override
  Stream<List<NearbyDevice>> get devicesStream => _devicesCtrl.stream;

  @override
  Stream<TransportEvent> get eventsStream => _eventsCtrl.stream;

  void _emitDevices() {
    if (!_devicesCtrl.isClosed) {
      _devicesCtrl.add(List.unmodifiable(_peers.values));
    }
  }

  Future<void> setEnabled(bool enabled, {bool discoverIfActive = false}) async {
    _enabled = enabled;
    if (enabled && !_receiver.isRunning) {
      await _receiver.start(advertiseMdns: true);
      _running = true;
      if (discoverIfActive) {
        await _mdns.startBrowsing();
      }
    } else if (enabled && _receiver.isRunning) {
      await _receiver.updateAdvertisement();
    } else if (!enabled && _receiver.isRunning) {
      _running = false;
      await _receiver.stop();
      await _mdns.stopBrowsing();
      _peers.clear();
      _emitDevices();
    }
  }

  @override
  Future<void> start({int? explicitPort, String? bindAddress}) async {
    if (!_enabled || _running) return;
    await _receiver.start(advertiseMdns: true);
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _mdns.stopBrowsing();
    await _receiver.stop();
    _peers.clear();
    _emitDevices();
  }

  @override
  Future<void> startDiscovery() async {
    if (!_enabled) return;
    await _mdns.startBrowsing();
  }

  @override
  Future<void> stopDiscovery() async {
    await _mdns.stopBrowsing();
    _peers.clear();
    _emitDevices();
  }

  @override
  Future<void> refreshDiscovery() async {
    if (!_enabled) return;
    await _mdns.stopBrowsing();
    await _mdns.startBrowsing();
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
        TransferProtocol.quickShare,
      ),
    );

    String? activePin;
    final result = await _sender.sendFiles(
      device: device,
      localDeviceName: localDeviceName,
      files: files,
      onPin: (pin) {
        activePin = pin;
        _eventsCtrl.add(TransportOutgoingPinReady(id, device.name, pin));
      },
      onProgress: (fileName, sent, total, speed) {
        _eventsCtrl.add(
          TransportOutgoingProgress(
            id,
            device.name,
            fileName,
            sent,
            total > 0 ? total : totalSize,
            speed,
            TransferProtocol.quickShare,
            pin: activePin,
          ),
        );
      },
    );

    if (result.userCanceled) {
      _eventsCtrl.add(TransportOutgoingCanceled(id));
      return;
    }
    if (result.receiverCanceled ||
        result.status == SharingConnectionResponseFrame.statusReject) {
      _eventsCtrl.add(TransportOutgoingError(id, declinedMessageFn()));
      return;
    }
    if (!result.isAccepted) {
      _eventsCtrl.add(
        TransportOutgoingError(id, 'Quick Share status ${result.status}'),
      );
      return;
    }

    _eventsCtrl.add(
      TransportOutgoingCompleted(
        id,
        device.name,
        displayTitle,
        files.length,
        TransferProtocol.quickShare,
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
    await _receiver.cancelActiveTransfer();
  }

  @override
  Future<void> updateConfig({String? deviceName, String? downloadDir}) async {
    if (deviceName != null) _receiver.deviceName = deviceName;
    if (downloadDir != null) _receiver.downloadDir = downloadDir;
    if (_enabled && _receiver.isRunning) {
      await _receiver.updateAdvertisement();
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _mdns.dispose();
    await _devicesCtrl.close();
    await _eventsCtrl.close();
  }
}
