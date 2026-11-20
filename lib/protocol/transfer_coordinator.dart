import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/platform_bridge.dart';
import '../services/settings_controller.dart';
import '../services/sound_service.dart';
import 'direct/md_constants.dart';
import 'direct/md_discovery.dart';
import 'direct/md_receiver.dart';
import 'direct/md_sender.dart';
import 'quickshare/proto_codec.dart';
import 'quickshare/qs_mdns_service.dart';
import 'quickshare/qs_receiver.dart';
import 'quickshare/qs_sender.dart';

class TransferCoordinator extends ChangeNotifier {
  final SettingsController settings;

  late final MaterialDropDiscovery _mdDiscovery;
  late final QsMdnsService _qsMdns;
  late final MaterialDropReceiver _mdReceiver;
  late final QsReceiver _qsReceiver;
  final MaterialDropSender _mdSender = MaterialDropSender();
  final QsSender _qsSender = QsSender();

  final Map<String, NearbyDevice> _devicesById = {};
  List<String> _localIps = [];
  Set<String> _allOwnIps = {'127.0.0.1', '0.0.0.0'};
  late final String _instanceId =
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}_${math.Random.secure().nextInt(0x7fffffff).toRadixString(16)}';
  bool _servicesStarted = false;
  bool _isRadarVisible = false;

  OutgoingTransferState _outgoingState = const OutgoingIdle();
  IncomingTransferState _incomingState = const IncomingIdle();
  TransferProtocol? _activeIncomingProtocol;
  TransferProtocol? _activeOutgoingProtocol;

  Timer? _autoResetOutgoingTimer;

  TransferCoordinator({required this.settings}) {
    final launch = settings.launchConfig;
    _mdDiscovery = MaterialDropDiscovery(
      instanceId: _instanceId,
      multiInstance: launch.isMultiInstance,
      deviceNameFn: () => settings.deviceName,
      localPortFn: () => _mdReceiver.port > 0
          ? _mdReceiver.port
          : (launch.port ?? MdConstants.localHttpPort),
      onDeviceFound: _onDeviceDiscovered,
      onDeviceExpired: _onDeviceRemoved,
    );

    _qsMdns = QsMdnsService(
      onDeviceFound: _onDeviceDiscovered,
      onDeviceLost: (instanceName) {
        // Expire matching QS device if found
        final toRemove = _devicesById.values
            .where((d) =>
                d.protocol == TransferProtocol.quickShare &&
                d.id.endsWith(instanceName))
            .map((d) => d.id)
            .toList();
        for (final id in toRemove) {
          _onDeviceRemoved(id);
        }
      },
    );

    _mdReceiver = MaterialDropReceiver(
      instanceId: _instanceId,
      deviceName: settings.deviceName,
      downloadDir: settings.downloadDir,
      treatLoopbackAsUsb: !launch.isMultiInstance,
      isTrustedFn: (name, ip) => settings.isTrusted(name, ip),
      autoAcceptAllFn: () => settings.autoAcceptAll,
      autoAcceptTrustedFn: () => settings.autoAcceptTrusted,
      onOffer: (offer) => _handleIncomingOffer(offer, TransferProtocol.materialDrop),
      onProgress: _handleIncomingProgress,
      onCompleted: (offer, item) =>
          _handleIncomingCompleted(offer, [item], const []),
      onCanceled: _handleIncomingCanceled,
      onError: _handleIncomingError,
    );

    _qsReceiver = QsReceiver(
      deviceName: settings.deviceName,
      downloadDir: settings.downloadDir,
      isTrustedFn: (name, ip) => settings.isTrusted(name, ip),
      autoAcceptAllFn: () => settings.autoAcceptAll,
      autoAcceptTrustedFn: () => settings.autoAcceptTrusted,
      onOffer: (offer) => _handleIncomingOffer(offer, TransferProtocol.quickShare),
      onProgress: _handleIncomingProgress,
      onCompleted: _handleIncomingCompleted,
      onCanceled: _handleIncomingCanceled,
      onError: _handleIncomingError,
    );
  }

  List<NearbyDevice> get devices {
    final list = _devicesById.values.toList();
    list.sort((a, b) {
      final aTrust = settings.isDeviceTrusted(a) ? 0 : 1;
      final bTrust = settings.isDeviceTrusted(b) ? 0 : 1;
      if (aTrust != bTrust) return aTrust.compareTo(bTrust);

      final aUsb = a.isUsb ? 0 : 1;
      final bUsb = b.isUsb ? 0 : 1;
      if (aUsb != bUsb) return aUsb.compareTo(bUsb);

      if (a.protocol != b.protocol) {
        return a.protocol == TransferProtocol.materialDrop ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  List<String> get localIps => List.unmodifiable(_localIps);
  int get directPort => _mdReceiver.port > 0
      ? _mdReceiver.port
      : (settings.launchConfig.port ?? MdConstants.localHttpPort);
  int get quickSharePort => _qsReceiver.port;
  bool get isDiscovering => _mdDiscovery.isScanning;
  OutgoingTransferState get outgoingState => _outgoingState;
  IncomingTransferState get incomingState => _incomingState;

  void setRadarVisible(bool visible) {
    _isRadarVisible = visible;
  }

  Future<void> startServices() async {
    if (_servicesStarted) return;
    _servicesStarted = true;

    SoundService.instance.enabled = settings.soundsEnabled;
    _localIps = await PlatformBridge.instance.getLocalIpv4Addresses();
    _allOwnIps = await PlatformBridge.instance.getAllOwnIpv4Addresses();

    await _mdReceiver.start(
      explicitPort: settings.launchConfig.port,
      bindAddress: settings.launchConfig.bindAddress,
    );
    if (settings.quickShareEnabled) {
      await _qsReceiver.start(advertiseMdns: true);
    }
    await startDiscovery();
    notifyListeners();
  }

  Future<void> onSettingsUpdated() async {
    SoundService.instance.enabled = settings.soundsEnabled;
    _mdReceiver.deviceName = settings.deviceName;
    _mdReceiver.downloadDir = settings.downloadDir;
    _qsReceiver.deviceName = settings.deviceName;
    _qsReceiver.downloadDir = settings.downloadDir;

    if (settings.quickShareEnabled && !_qsReceiver.isRunning) {
      await _qsReceiver.start(advertiseMdns: true);
      if (_mdDiscovery.isScanning) {
        await _qsMdns.startBrowsing();
      }
    } else if (settings.quickShareEnabled && _qsReceiver.isRunning) {
      await _qsReceiver.updateAdvertisement();
    } else if (!settings.quickShareEnabled && _qsReceiver.isRunning) {
      await _qsReceiver.stop();
      await _qsMdns.stopBrowsing();
      _devicesById.removeWhere(
        (_, d) => d.protocol == TransferProtocol.quickShare,
      );
    }
    notifyListeners();
  }

  Future<void> startDiscovery() async {
    _localIps = await PlatformBridge.instance.getLocalIpv4Addresses();
    _allOwnIps = await PlatformBridge.instance.getAllOwnIpv4Addresses();
    _devicesById.removeWhere((_, d) => _isSelfDevice(d));
    await _mdDiscovery.startDiscovery();
    if (settings.quickShareEnabled) {
      await _qsMdns.startBrowsing();
    }
    notifyListeners();
  }

  Future<void> stopDiscovery() async {
    await _mdDiscovery.stopDiscovery();
    await _qsMdns.stopBrowsing();
    _devicesById.clear();
    notifyListeners();
  }

  Future<void> refreshDiscovery() async {
    _localIps = await PlatformBridge.instance.getLocalIpv4Addresses();
    _allOwnIps = await PlatformBridge.instance.getAllOwnIpv4Addresses();
    _devicesById.removeWhere((_, d) => _isSelfDevice(d));
    await _mdDiscovery.triggerImmediateRefresh();
    if (settings.quickShareEnabled) {
      await _qsMdns.stopBrowsing();
      await _qsMdns.startBrowsing();
    }
    notifyListeners();
  }

  bool _isSelfDevice(NearbyDevice device) {
    if (device.instanceId != null && device.instanceId == _instanceId) {
      return true;
    }
    final multi = settings.launchConfig.isMultiInstance;
    if (!device.isUsb) {
      final isOwnIp =
          _localIps.contains(device.ip) || _allOwnIps.contains(device.ip);
      if (!multi) {
        return isOwnIp;
      }
      // In multi-instance mode on the same host, only drop if it matches our own port
      if (isOwnIp &&
          device.protocol == TransferProtocol.materialDrop &&
          device.port == directPort) {
        return true;
      }
      if (isOwnIp &&
          device.protocol == TransferProtocol.quickShare &&
          quickSharePort > 0 &&
          device.port == quickSharePort) {
        return true;
      }
      return false;
    }
    if (device.protocol == TransferProtocol.materialDrop &&
        device.port == directPort) {
      return true;
    }
    if (device.protocol == TransferProtocol.quickShare &&
        quickSharePort > 0 &&
        device.port == quickSharePort) {
      return true;
    }
    return false;
  }

  void _onDeviceDiscovered(NearbyDevice device) {
    if (_isSelfDevice(device)) return;
    final isNew = !_devicesById.containsKey(device.id);
    _devicesById[device.id] = device;
    if (isNew && _isRadarVisible) {
      unawaited(SoundService.instance.play(AppSound.searching));
      unawaited(SoundService.instance.haptic(HapticKind.light));
    }
    notifyListeners();
  }

  void _onDeviceRemoved(String id) {
    if (_devicesById.remove(id) != null) {
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Outgoing transfers
  // ---------------------------------------------------------------------------

  Future<void> sendFiles(NearbyDevice device, List<StagedFile> files) async {
    if (files.isEmpty) return;
    _autoResetOutgoingTimer?.cancel();
    _activeOutgoingProtocol = device.protocol;

    final totalSize = files.fold<int>(0, (s, f) => s + f.size);
    final displayTitle = files.length == 1
        ? files.first.name
        : '${files.first.name} (+${files.length - 1})';

    _outgoingState = OutgoingConnecting(
      deviceName: device.name,
      protocol: device.protocol,
    );
    notifyListeners();

    unawaited(SoundService.instance.play(AppSound.sending));
    unawaited(
      PlatformBridge.instance.startForegroundTransfer(
        'MaterialDrop',
        'Sending $displayTitle to ${device.name}',
      ),
    );

    try {
      if (device.protocol == TransferProtocol.materialDrop) {
        await _mdSender.sendBatch(
          device: device,
          localDeviceName: settings.deviceName,
          files: files,
          onProgress: (fileName, sent, total, speed) {
            final denom = total > 0 ? total : totalSize;
            final prog = denom > 0 ? (sent / denom).clamp(0.0, 1.0) : 0.0;
            _outgoingState = OutgoingTransferring(
              deviceName: device.name,
              fileName: fileName,
              progress: prog,
              bytesSent: sent,
              totalBytes: denom,
              speedBps: speed,
              protocol: TransferProtocol.materialDrop,
            );
            notifyListeners();
          },
        );
      } else {
        String? activePin;
        final result = await _qsSender.sendFiles(
          device: device,
          localDeviceName: settings.deviceName,
          files: files,
          onPin: (pin) {
            activePin = pin;
            _outgoingState = OutgoingPinReady(
              deviceName: device.name,
              pin: pin,
            );
            notifyListeners();
          },
          onProgress: (fileName, sent, total, speed) {
            final denom = total > 0 ? total : totalSize;
            final prog = denom > 0 ? (sent / denom).clamp(0.0, 1.0) : 0.0;
            _outgoingState = OutgoingTransferring(
              deviceName: device.name,
              fileName: fileName,
              progress: prog,
              bytesSent: sent,
              totalBytes: denom,
              speedBps: speed,
              protocol: TransferProtocol.quickShare,
              pin: activePin,
            );
            notifyListeners();
          },
        );

        if (result.userCanceled) {
          _outgoingState = const OutgoingCanceled();
          notifyListeners();
          return;
        }
        if (result.receiverCanceled ||
            result.status == SharingConnectionResponseFrame.statusReject) {
          _outgoingState =
              OutgoingError(settings.strings.tr('transfer_declined'));
          unawaited(SoundService.instance.play(AppSound.failed));
          notifyListeners();
          return;
        }
        if (!result.isAccepted) {
          _outgoingState = OutgoingError('Quick Share status ${result.status}');
          unawaited(SoundService.instance.play(AppSound.failed));
          notifyListeners();
          return;
        }
      }

      _outgoingState = OutgoingCompleted(
        deviceName: device.name,
        displayTitle: displayTitle,
        filesCount: files.length,
      );
      unawaited(SoundService.instance.play(AppSound.successful));
      unawaited(SoundService.instance.haptic(HapticKind.medium));

      for (final f in files) {
        unawaited(settings.addHistoryEntry(
          HistoryEntry(
            id: '${DateTime.now().microsecondsSinceEpoch}_${f.name}',
            fileName: f.name,
            size: f.size,
            mimeType: f.mimeType,
            pathOrUri: f.path ?? f.contentUri ?? '',
            peerName: device.name,
            direction: TransferDirection.outgoing,
            protocol: device.protocol,
            timestamp: DateTime.now(),
          ),
        ));
      }
      notifyListeners();
    } catch (e) {
      if (_outgoingState is OutgoingCanceled) return;
      _outgoingState = OutgoingError(e.toString());
      unawaited(SoundService.instance.play(AppSound.failed));
      notifyListeners();
    } finally {
      _activeOutgoingProtocol = null;
      unawaited(PlatformBridge.instance.stopForegroundTransfer());
    }
  }

  void cancelOutgoing() {
    if (_activeOutgoingProtocol == TransferProtocol.quickShare) {
      _qsSender.cancel();
    } else {
      _mdSender.cancel();
    }
    _outgoingState = const OutgoingCanceled();
    unawaited(PlatformBridge.instance.stopForegroundTransfer());
    notifyListeners();
  }

  void resetOutgoing() {
    _outgoingState = const OutgoingIdle();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Incoming transfers
  // ---------------------------------------------------------------------------

  void _handleIncomingOffer(IncomingOffer offer, TransferProtocol protocol) {
    _activeIncomingProtocol = protocol;
    final autoAccepted = settings.autoAcceptAll ||
        offer.isUsb ||
        (offer.isTrusted && settings.autoAcceptTrusted);

    if (autoAccepted) {
      _incomingState = IncomingReceiving(
        offer: offer,
        currentFileName:
            offer.files.isNotEmpty ? offer.files.first.name : '...',
        progress: 0,
        bytesReceived: 0,
        totalBytes: offer.totalSize,
        speedBps: 0,
      );
    } else {
      _incomingState = IncomingOfferPending(offer);
      unawaited(SoundService.instance.play(AppSound.receiving));
      unawaited(SoundService.instance.haptic(HapticKind.heavy));
    }
    unawaited(
      PlatformBridge.instance.startForegroundTransfer(
        'MaterialDrop',
        'Receiving from ${offer.senderName}',
      ),
    );
    notifyListeners();
  }

  void _handleIncomingProgress(
    IncomingOffer offer,
    String fileName,
    int bytesReceived,
    int totalBytes,
    double speedBps,
  ) {
    final prog = totalBytes > 0 ? (bytesReceived / totalBytes).clamp(0.0, 1.0) : 0.0;
    _incomingState = IncomingReceiving(
      offer: offer,
      currentFileName: fileName,
      progress: prog,
      bytesReceived: bytesReceived,
      totalBytes: totalBytes,
      speedBps: speedBps,
    );
    notifyListeners();
  }

  void _handleIncomingCompleted(
    IncomingOffer offer,
    List<IncomingTransferItem> items,
    List<IncomingTextItem> texts,
  ) {
    _incomingState = IncomingCompleted(
      offer: offer,
      savedItems: items,
      receivedTexts: texts,
    );
    _activeIncomingProtocol = null;
    unawaited(PlatformBridge.instance.stopForegroundTransfer());
    unawaited(SoundService.instance.play(AppSound.successful));
    unawaited(SoundService.instance.haptic(HapticKind.medium));

    if (settings.clipboardSync) {
      if (texts.isNotEmpty) {
        unawaited(
          PlatformBridge.instance.copyTextToClipboard(texts.first.body),
        );
      } else if (items.isNotEmpty) {
        unawaited(
          PlatformBridge.instance.copyFileOrImageToClipboard(
            items.first.savedPathOrUri,
          ),
        );
      }
    }

    for (final item in items) {
      unawaited(settings.addHistoryEntry(
        HistoryEntry(
          id: '${DateTime.now().microsecondsSinceEpoch}_${item.name}',
          fileName: item.name,
          size: item.size,
          mimeType: item.mimeType,
          pathOrUri: item.savedPathOrUri,
          peerName: offer.senderName,
          direction: TransferDirection.incoming,
          protocol: offer.protocol,
          timestamp: DateTime.now(),
        ),
      ));
    }
    for (final t in texts) {
      unawaited(settings.addHistoryEntry(
        HistoryEntry(
          id: '${DateTime.now().microsecondsSinceEpoch}_text',
          fileName: t.title.isNotEmpty ? t.title : t.typeName,
          size: t.body.length,
          mimeType: 'text/plain',
          pathOrUri: '',
          peerName: offer.senderName,
          direction: TransferDirection.incoming,
          protocol: offer.protocol,
          timestamp: DateTime.now(),
          isText: true,
          textBody: t.body,
        ),
      ));
    }
    notifyListeners();
  }

  void _handleIncomingCanceled() {
    _incomingState = const IncomingIdle();
    _activeIncomingProtocol = null;
    unawaited(PlatformBridge.instance.stopForegroundTransfer());
    notifyListeners();
  }

  void _handleIncomingError(String message) {
    _incomingState = IncomingError(message);
    _activeIncomingProtocol = null;
    unawaited(PlatformBridge.instance.stopForegroundTransfer());
    unawaited(SoundService.instance.play(AppSound.failed));
    notifyListeners();
  }

  Future<void> acceptIncoming({bool trustSender = false}) async {
    final current = _incomingState;
    if (current is IncomingOfferPending) {
      if (trustSender) {
        await settings.setTrusted(
          current.offer.senderName,
          true,
          extraId: current.offer.senderAddress,
        );
      }
      _incomingState = IncomingReceiving(
        offer: current.offer,
        currentFileName: current.offer.files.isNotEmpty
            ? current.offer.files.first.name
            : '...',
        progress: 0,
        bytesReceived: 0,
        totalBytes: current.offer.totalSize,
        speedBps: 0,
      );
      notifyListeners();
    }

    if (_activeIncomingProtocol == TransferProtocol.quickShare) {
      _qsReceiver.setDecision(true);
    } else {
      _mdReceiver.setDecision(true);
    }
  }

  void declineIncoming() {
    if (_activeIncomingProtocol == TransferProtocol.quickShare) {
      _qsReceiver.setDecision(false);
    } else {
      _mdReceiver.setDecision(false);
    }
    _incomingState = const IncomingIdle();
    _activeIncomingProtocol = null;
    unawaited(PlatformBridge.instance.stopForegroundTransfer());
    unawaited(SoundService.instance.play(AppSound.failed));
    notifyListeners();
  }

  Future<void> cancelIncoming() async {
    if (_activeIncomingProtocol == TransferProtocol.quickShare) {
      await _qsReceiver.cancelActiveTransfer();
    }
    _incomingState = const IncomingIdle();
    _activeIncomingProtocol = null;
    unawaited(PlatformBridge.instance.stopForegroundTransfer());
    notifyListeners();
  }

  void dismissIncoming() {
    _incomingState = const IncomingIdle();
    notifyListeners();
  }

  @override
  void dispose() {
    _autoResetOutgoingTimer?.cancel();
    unawaited(_mdDiscovery.dispose());
    unawaited(_qsMdns.dispose());
    unawaited(_mdReceiver.stop());
    unawaited(_qsReceiver.stop());
    super.dispose();
  }
}

