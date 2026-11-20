import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/platform_bridge.dart';
import '../services/settings_controller.dart';
import '../services/sound_service.dart';
import 'direct/direct_transport.dart';
import 'direct/md_constants.dart';
import 'engine/transport_models.dart';
import 'engine/transport_router.dart';
import 'iroh/internet_p2p_transport.dart';
import 'lan/lan_constants.dart';
import 'lan/lan_transport.dart';
import 'proximity/proximity_bridge.dart';
import 'proximity/tap_proximity_transport.dart';
import 'quickshare/quickshare_transport.dart';

class TransferCoordinator extends ChangeNotifier {
  final SettingsController settings;

  late final DirectTransport _directTransport;
  late final LanTransport _lanTransport;
  late final QuickShareTransport _quickShareTransport;
  late final TapProximityTransport _tapProximityTransport;
  late final InternetP2PTransport _internetP2PTransport;
  late final TransportRouter _router;

  StreamSubscription<List<DiscoveredPeer>>? _peersSub;
  StreamSubscription<TransportEvent>? _eventsSub;

  Set<String> _knownPeerKeys = {};
  List<String> _localIps = [];
  Set<String> _allOwnIps = {'127.0.0.1', '0.0.0.0'};
  late final String _instanceId =
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}_${math.Random.secure().nextInt(0x7fffffff).toRadixString(16)}';

  bool _servicesStarted = false;
  bool _discovering = false;
  bool _isRadarVisible = false;

  OutgoingTransferState _outgoingState = const OutgoingIdle();
  IncomingTransferState _incomingState = const IncomingIdle();
  String? _activeIncomingChannelId;
  String? _activeIncomingOfferId;
  Timer? _autoResetOutgoingTimer;

  TransferCoordinator({required this.settings}) {
    final launch = settings.launchConfig;

    _directTransport = DirectTransport(
      instanceId: _instanceId,
      multiInstance: launch.isMultiInstance,
      deviceName: settings.deviceName,
      downloadDir: settings.downloadDir,
      treatLoopbackAsUsb: !launch.isMultiInstance,
      isTrustedFn: (name, ip) => settings.isTrusted(name, ip),
      autoAcceptAllFn: () => settings.autoAcceptAll,
      autoAcceptTrustedFn: () => settings.autoAcceptTrusted,
    );

    _lanTransport = LanTransport(
      deviceName: settings.deviceName,
      downloadDir: settings.downloadDir,
      multiInstance: launch.isMultiInstance,
      isTrustedFn: (name, ip) => settings.isTrusted(name, ip),
      autoAcceptAllFn: () => settings.autoAcceptAll,
      autoAcceptTrustedFn: () => settings.autoAcceptTrusted,
    );

    _quickShareTransport = QuickShareTransport(
      deviceName: settings.deviceName,
      downloadDir: settings.downloadDir,
      enabled: settings.quickShareEnabled,
      isTrustedFn: (name, ip) => settings.isTrusted(name, ip),
      autoAcceptAllFn: () => settings.autoAcceptAll,
      autoAcceptTrustedFn: () => settings.autoAcceptTrusted,
      declinedMessageFn: () => settings.strings.tr('transfer_declined'),
    );

    _tapProximityTransport = TapProximityTransport(
      transferPortFn: () => lanPort,
      localFingerprintFn: () => _lanTransport.fingerprint,
      deviceNameFn: () => settings.deviceName,
      onIrohTicketReceived: (ticket, name) {
        _internetP2PTransport.addPeerFromLinkOrTicket(
          ticket,
          fallbackName: name,
        );
      },
    );

    _internetP2PTransport = InternetP2PTransport(
      deviceNameFn: () => settings.deviceName,
      downloadDirFn: () => settings.downloadDir,
      enabled: settings.internetP2pEnabled,
      isTrustedFn: (name, ip) => settings.isTrusted(name, ip),
      autoAcceptAllFn: () => settings.autoAcceptAll,
      autoAcceptTrustedFn: () => settings.autoAcceptTrusted,
      onReadyChanged: (deepLink, nodeId) {
        unawaited(_tapProximityTransport.updateIrohTicket(deepLink));
        notifyListeners();
      },
    );

    _router = TransportRouter(
      channels: [
        _directTransport,
        _lanTransport,
        _quickShareTransport,
        _tapProximityTransport,
        _internetP2PTransport,
      ],
      isSelfFn: _isSelfDevice,
      isTrustedFn: settings.isDeviceTrusted,
    );

    _peersSub = _router.peersStream.listen(_onPeersUpdated);
    _eventsSub = _router.eventsStream.listen(_onTransportEvent);
  }

  List<NearbyDevice> get devices => _router.sortedNearbyDevices();
  List<DiscoveredPeer> get peers => _router.currentPeers;
  List<String> get localIps => List.unmodifiable(_localIps);

  int get directPort => _directTransport.boundPort > 0
      ? _directTransport.boundPort
      : (settings.launchConfig.port ?? MdConstants.localHttpPort);

  int get lanPort => _lanTransport.boundPort > 0
      ? _lanTransport.boundPort
      : LanConstants.defaultPort;

  int get quickSharePort => _quickShareTransport.boundPort;
  ProximityStatus get proximityStatus => _tapProximityTransport.lastStatus;
  String get localIrohDeepLink => _internetP2PTransport.deepLink;
  String get localIrohNodeId => _internetP2PTransport.nodeId;
  bool get isIrohReady => _internetP2PTransport.isEndpointReady;
  bool get isUsingNativeQuickShare => _quickShareTransport.isUsingNativeCore;

  NearbyDevice? connectIrohLink(String rawLink, {String? fallbackName}) {
    final dev = _internetP2PTransport.addPeerFromLinkOrTicket(
      rawLink,
      fallbackName: fallbackName,
    );
    if (dev != null) {
      notifyListeners();
    }
    return dev;
  }
  bool get isDiscovering => _discovering;
  OutgoingTransferState get outgoingState => _outgoingState;
  IncomingTransferState get incomingState => _incomingState;

  void setRadarVisible(bool visible) {
    _isRadarVisible = visible;
    unawaited(_tapProximityTransport.setRadarVisible(visible));
  }

  Future<void> refreshProximityStatus() async {
    await _tapProximityTransport.refreshStatus();
    notifyListeners();
  }

  Future<bool> requestProximityPermissions() async {
    final granted = await _tapProximityTransport.requestPermissions();
    if (granted && _discovering) {
      await _tapProximityTransport.refreshDiscovery();
    }
    notifyListeners();
    return granted;
  }

  Future<void> startServices() async {
    if (_servicesStarted) return;
    _servicesStarted = true;

    SoundService.instance.enabled = settings.soundsEnabled;
    _localIps = await PlatformBridge.instance.getLocalIpv4Addresses();
    _allOwnIps = await PlatformBridge.instance.getAllOwnIpv4Addresses();

    final launch = settings.launchConfig;
    await _directTransport.start(
      explicitPort: launch.port,
      bindAddress: launch.bindAddress,
    );
    await _lanTransport.start(
      explicitPort: launch.port != null ? launch.port! + 1000 : null,
      bindAddress: launch.bindAddress,
    );
    if (settings.quickShareEnabled) {
      await _quickShareTransport.start();
    }
    await _tapProximityTransport.start();
    if (settings.internetP2pEnabled) {
      await _internetP2PTransport.start();
    }
    if (launch.initialDeepLink != null && launch.initialDeepLink!.isNotEmpty) {
      connectIrohLink(launch.initialDeepLink!);
    }

    await startDiscovery();
    notifyListeners();
  }

  Future<void> onSettingsUpdated() async {
    SoundService.instance.enabled = settings.soundsEnabled;
    await _router.updateConfig(
      deviceName: settings.deviceName,
      downloadDir: settings.downloadDir,
    );
    await _quickShareTransport.setEnabled(
      settings.quickShareEnabled,
      discoverIfActive: _discovering,
    );
    await _internetP2PTransport.setEnabled(settings.internetP2pEnabled);
    _router.pruneSelfDevices();
    notifyListeners();
  }

  Future<void> startDiscovery() async {
    _discovering = true;
    _localIps = await PlatformBridge.instance.getLocalIpv4Addresses();
    _allOwnIps = await PlatformBridge.instance.getAllOwnIpv4Addresses();
    _router.pruneSelfDevices();
    await _router.startDiscovery();
    notifyListeners();
  }

  Future<void> stopDiscovery() async {
    _discovering = false;
    await _router.stopDiscovery();
    _knownPeerKeys.clear();
    notifyListeners();
  }

  Future<void> refreshDiscovery() async {
    _localIps = await PlatformBridge.instance.getLocalIpv4Addresses();
    _allOwnIps = await PlatformBridge.instance.getAllOwnIpv4Addresses();
    _router.pruneSelfDevices();
    await _router.refreshDiscovery();
    notifyListeners();
  }

  bool _isSelfDevice(NearbyDevice device) {
    if (device.instanceId != null && device.instanceId == _instanceId) {
      return true;
    }
    if (device.channelId == 'tap_proximity' ||
        device.protocol == TransferProtocol.tapProximity) {
      return device.instanceId != null &&
          device.instanceId!.toUpperCase() ==
              _tapProximityTransport.localEphemeralHex;
    }
    if (device.channelId == 'internet_p2p' ||
        device.protocol == TransferProtocol.internetP2p) {
      return _internetP2PTransport.nodeId.isNotEmpty &&
          device.endpointId == _internetP2PTransport.nodeId;
    }
    if (device.channelId == 'lan' &&
        device.tlsFingerprint != null &&
        device.tlsFingerprint!.toUpperCase() ==
            _lanTransport.fingerprint.toUpperCase()) {
      return true;
    }

    final multi = settings.launchConfig.isMultiInstance;
    if (!device.isUsb) {
      final isOwnIp =
          _localIps.contains(device.ip) || _allOwnIps.contains(device.ip);
      if (!multi) {
        return isOwnIp;
      }
      if (isOwnIp &&
          device.protocol == TransferProtocol.materialDrop &&
          device.port == directPort) {
        return true;
      }
      if (isOwnIp &&
          device.protocol == TransferProtocol.lan &&
          device.port == lanPort) {
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
    if (device.protocol == TransferProtocol.lan && device.port == lanPort) {
      return true;
    }
    if (device.protocol == TransferProtocol.quickShare &&
        quickSharePort > 0 &&
        device.port == quickSharePort) {
      return true;
    }
    return false;
  }

  void _onPeersUpdated(List<DiscoveredPeer> peers) {
    final nextKeys = peers.map((p) => p.peerKey).toSet();
    final hasNew = nextKeys.any((k) => !_knownPeerKeys.contains(k));
    _knownPeerKeys = nextKeys;
    if (hasNew && _isRadarVisible) {
      unawaited(SoundService.instance.play(AppSound.searching));
      unawaited(SoundService.instance.haptic(HapticKind.light));
    }
    notifyListeners();
  }

  void _onTransportEvent(TransportEvent ev) {
    switch (ev) {
      case TransportIncomingOffer(:final channelId, :final offer):
        _handleIncomingOffer(channelId, offer);
      case TransportIncomingProgress(
          :final offer,
          :final fileName,
          :final bytesReceived,
          :final totalBytes,
          :final speedBps,
        ):
        _handleIncomingProgress(
          offer,
          fileName,
          bytesReceived,
          totalBytes,
          speedBps,
        );
      case TransportIncomingCompleted(
          :final offer,
          :final savedItems,
          :final receivedTexts,
        ):
        _handleIncomingCompleted(offer, savedItems, receivedTexts);
      case TransportIncomingCanceled():
        _handleIncomingCanceled();
      case TransportIncomingError(:final message):
        _handleIncomingError(message);
      case TransportOutgoingConnecting(:final deviceName, :final protocol):
        _outgoingState = OutgoingConnecting(
          deviceName: deviceName,
          protocol: protocol,
        );
        notifyListeners();
      case TransportOutgoingPinReady(:final deviceName, :final pin):
        _outgoingState = OutgoingPinReady(deviceName: deviceName, pin: pin);
        notifyListeners();
      case TransportOutgoingProgress(
          :final deviceName,
          :final fileName,
          :final bytesSent,
          :final totalBytes,
          :final speedBps,
          :final protocol,
          :final pin,
        ):
        final prog =
            totalBytes > 0 ? (bytesSent / totalBytes).clamp(0.0, 1.0) : 0.0;
        _outgoingState = OutgoingTransferring(
          deviceName: deviceName,
          fileName: fileName,
          progress: prog,
          bytesSent: bytesSent,
          totalBytes: totalBytes,
          speedBps: speedBps,
          protocol: protocol,
          pin: pin,
        );
        notifyListeners();
      case TransportOutgoingCompleted(
          :final deviceName,
          :final displayTitle,
          :final filesCount,
          :final protocol,
          :final files,
        ):
        _outgoingState = OutgoingCompleted(
          deviceName: deviceName,
          displayTitle: displayTitle,
          filesCount: filesCount,
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
              peerName: deviceName,
              direction: TransferDirection.outgoing,
              protocol: protocol,
              timestamp: DateTime.now(),
            ),
          ));
        }
        notifyListeners();
      case TransportOutgoingCanceled():
        _outgoingState = const OutgoingCanceled();
        notifyListeners();
      case TransportOutgoingError(:final message):
        _outgoingState = OutgoingError(message);
        unawaited(SoundService.instance.play(AppSound.failed));
        notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Outgoing transfers
  // ---------------------------------------------------------------------------

  Future<void> sendFiles(NearbyDevice device, List<StagedFile> files) async {
    if (files.isEmpty) return;
    _autoResetOutgoingTimer?.cancel();

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
      await _router.sendFiles(
        device,
        files,
        localDeviceName: settings.deviceName,
      );
    } catch (e) {
      if (_outgoingState is OutgoingCanceled) return;
      _outgoingState = OutgoingError(e.toString());
      unawaited(SoundService.instance.play(AppSound.failed));
      notifyListeners();
    } finally {
      unawaited(PlatformBridge.instance.stopForegroundTransfer());
    }
  }

  void cancelOutgoing() {
    unawaited(_router.cancelOutgoing());
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

  void _handleIncomingOffer(String channelId, IncomingOffer offer) {
    _activeIncomingChannelId = channelId;
    _activeIncomingOfferId = offer.id;
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
    final prog =
        totalBytes > 0 ? (bytesReceived / totalBytes).clamp(0.0, 1.0) : 0.0;
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
    _activeIncomingChannelId = null;
    _activeIncomingOfferId = null;
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
    _activeIncomingChannelId = null;
    _activeIncomingOfferId = null;
    unawaited(PlatformBridge.instance.stopForegroundTransfer());
    notifyListeners();
  }

  void _handleIncomingError(String message) {
    _incomingState = IncomingError(message);
    _activeIncomingChannelId = null;
    _activeIncomingOfferId = null;
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

    final channelId = _activeIncomingChannelId ?? 'direct';
    final offerId = _activeIncomingOfferId ?? '';
    await _router.acceptIncoming(channelId, offerId);
  }

  void declineIncoming() {
    final channelId = _activeIncomingChannelId ?? 'direct';
    final offerId = _activeIncomingOfferId ?? '';
    unawaited(_router.declineIncoming(channelId, offerId));
    _incomingState = const IncomingIdle();
    _activeIncomingChannelId = null;
    _activeIncomingOfferId = null;
    unawaited(PlatformBridge.instance.stopForegroundTransfer());
    unawaited(SoundService.instance.play(AppSound.failed));
    notifyListeners();
  }

  Future<void> cancelIncoming() async {
    final channelId = _activeIncomingChannelId;
    final offerId = _activeIncomingOfferId;
    if (channelId != null) {
      await _router.cancelIncoming(channelId, offerId: offerId);
    }
    _incomingState = const IncomingIdle();
    _activeIncomingChannelId = null;
    _activeIncomingOfferId = null;
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
    unawaited(_peersSub?.cancel());
    unawaited(_eventsSub?.cancel());
    unawaited(_router.dispose());
    super.dispose();
  }
}
