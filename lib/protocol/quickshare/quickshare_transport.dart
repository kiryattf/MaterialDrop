import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/models.dart';
import '../engine/transport_channel.dart';
import '../engine/transport_models.dart';
import '../ffi/native_bridge.dart';
import 'proto_codec.dart';
import 'qs_mdns_service.dart';
import 'qs_receiver.dart';
import 'qs_sender.dart';

/// [TransportChannel] for Google Quick Share (mDNS + UKEY2 + SecureMessage).
///
/// Uses the native Rust `rquickshare_core` engine via FFI on Windows and Linux
/// when the compiled shared library is available, and seamlessly falls back
/// to the pure-Dart engine on Android or headless unit tests.
class QuickShareTransport implements TransportChannel {
  final bool Function(String senderName, String senderIp) isTrustedFn;
  final bool Function() autoAcceptAllFn;
  final bool Function() autoAcceptTrustedFn;
  final String Function() declinedMessageFn;

  String _deviceName;
  String _downloadDir;

  late final QsMdnsService _mdns;
  late final QsReceiver _receiver;
  final QsSender _sender = QsSender();

  final StreamController<List<NearbyDevice>> _devicesCtrl =
      StreamController<List<NearbyDevice>>.broadcast();
  final StreamController<TransportEvent> _eventsCtrl =
      StreamController<TransportEvent>.broadcast();

  final Map<String, NearbyDevice> _peers = {};
  final Map<String, String> _fullnameToPeerId = {};
  final Map<String, IncomingOffer> _nativeOffers = {};
  StreamSubscription<Map<String, dynamic>>? _nativeSub;
  Completer<void>? _nativeOutgoingCompleter;
  String? _nativeOutgoingId;
  NearbyDevice? _nativeOutgoingDevice;
  List<StagedFile> _nativeOutgoingFiles = const [];
  String _nativeOutgoingTitle = '';
  String? _nativeActivePin;
  bool _nativeCanceledByUser = false;

  bool _running = false;
  bool _enabled = true;
  bool _usingNative = false;
  int _nativePort = 0;
  int _txSeq = 0;

  QuickShareTransport({
    required String deviceName,
    required String downloadDir,
    bool enabled = true,
    required this.isTrustedFn,
    required this.autoAcceptAllFn,
    required this.autoAcceptTrustedFn,
    required this.declinedMessageFn,
  })  : _deviceName = deviceName,
        _downloadDir = downloadDir {
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
  int get boundPort => _usingNative ? _nativePort : _receiver.port;

  bool get isEnabled => _enabled;
  bool get isUsingNativeCore => _usingNative;

  @override
  Stream<List<NearbyDevice>> get devicesStream => _devicesCtrl.stream;

  @override
  Stream<TransportEvent> get eventsStream => _eventsCtrl.stream;

  void _emitDevices() {
    if (!_devicesCtrl.isClosed) {
      _devicesCtrl.add(List.unmodifiable(_peers.values));
    }
  }

  Future<bool> _tryStartNative(bool visible) async {
    final bridge = NativeBridge.instance;
    if (!bridge.isDesktopQuickShareAvailable) return false;
    try {
      final supportDir = await getApplicationSupportDirectory();
      final stateDir = p.join(supportDir.path, 'iroh_state');
      final ok = bridge.init(
        stateDir: stateDir,
        deviceName: _deviceName,
        downloadDir: _downloadDir,
      );
      if (!ok) return false;
      _nativeSub ??= bridge.eventsStream.listen(_handleNativeEvent);
      final port = bridge.startDesktopQuickShare(visible: visible);
      if (port <= 0) return false;
      _usingNative = true;
      _nativePort = port;
      _running = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> setEnabled(bool enabled, {bool discoverIfActive = false}) async {
    _enabled = enabled;
    if (enabled && !_running) {
      await start();
      if (discoverIfActive && !_usingNative) {
        await _mdns.startBrowsing();
      }
    } else if (enabled && _running) {
      if (!_usingNative) {
        await _receiver.updateAdvertisement();
      }
    } else if (!enabled && _running) {
      await stop();
    }
  }

  @override
  Future<void> start({int? explicitPort, String? bindAddress}) async {
    if (!_enabled || _running) return;
    if (await _tryStartNative(true)) {
      return;
    }
    _usingNative = false;
    await _receiver.start(advertiseMdns: true);
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
    if (_usingNative) {
      NativeBridge.instance.stopDesktopQuickShare();
      await _nativeSub?.cancel();
      _nativeSub = null;
      _nativePort = 0;
      _usingNative = false;
    } else {
      await _mdns.stopBrowsing();
      await _receiver.stop();
    }
    _peers.clear();
    _fullnameToPeerId.clear();
    _emitDevices();
  }

  @override
  Future<void> startDiscovery() async {
    if (!_enabled || _usingNative) return;
    await _mdns.startBrowsing();
  }

  @override
  Future<void> stopDiscovery() async {
    if (!_usingNative) {
      await _mdns.stopBrowsing();
      _peers.clear();
      _emitDevices();
    }
  }

  @override
  Future<void> refreshDiscovery() async {
    if (!_enabled) return;
    if (_usingNative) {
      await stop();
      await start();
      return;
    }
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
    if (_usingNative) {
      await _sendOfferNative(device, files);
      return;
    }

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

  Future<void> _sendOfferNative(
    NearbyDevice device,
    List<StagedFile> files,
  ) async {
    final displayTitle = files.length == 1
        ? files.first.name
        : '${files.first.name} (+${files.length - 1})';
    final transferId = 'tx_rqs_${++_txSeq}_${DateTime.now().millisecondsSinceEpoch}';
    _nativeCanceledByUser = false;
    _nativeActivePin = null;
    _nativeOutgoingId = transferId;
    _nativeOutgoingDevice = device;
    _nativeOutgoingFiles = List<StagedFile>.from(files);
    _nativeOutgoingTitle = displayTitle;
    final completer = Completer<void>();
    _nativeOutgoingCompleter = completer;

    _eventsCtrl.add(
      TransportOutgoingConnecting(
        id,
        device.name,
        TransferProtocol.quickShare,
      ),
    );

    try {
      final specs = <Map<String, dynamic>>[];
      for (final f in files) {
        if (f.path == null || f.path!.isEmpty) continue;
        specs.add({
          'path': f.path!,
          'name': f.name,
          'mime_type': f.mimeType,
        });
      }
      if (specs.isEmpty) {
        throw StateError('No local file paths available for desktop Quick Share');
      }
      final ok = NativeBridge.instance.sendDesktopQuickShareFiles(
        transferId: transferId,
        ip: device.ip,
        port: device.port,
        files: specs,
      );
      if (!ok) {
        throw StateError('Failed to start rquickshare_core transfer');
      }
      await completer.future;
    } finally {
      _nativeOutgoingCompleter = null;
      _nativeOutgoingId = null;
      _nativeOutgoingDevice = null;
      _nativeOutgoingFiles = const [];
      _nativeOutgoingTitle = '';
      _nativeActivePin = null;
    }
  }

  @override
  Future<void> acceptOffer(String offerId) async {
    if (_usingNative) {
      NativeBridge.instance.respondDesktopQuickShareOffer(offerId, true);
      return;
    }
    _receiver.setDecision(true);
  }

  @override
  Future<void> declineOffer(String offerId) async {
    if (_usingNative) {
      NativeBridge.instance.respondDesktopQuickShareOffer(offerId, false);
      return;
    }
    _receiver.setDecision(false);
  }

  @override
  Future<void> cancelTransfer({String? offerId}) async {
    if (_usingNative) {
      if (offerId != null && offerId.isNotEmpty) {
        NativeBridge.instance.cancelDesktopQuickShareTransfer(offerId);
        return;
      }
      _nativeCanceledByUser = true;
      final tid = _nativeOutgoingId;
      if (tid != null) {
        NativeBridge.instance.cancelDesktopQuickShareTransfer(tid);
      }
      _eventsCtrl.add(TransportOutgoingCanceled(id));
      final comp = _nativeOutgoingCompleter;
      if (comp != null && !comp.isCompleted) {
        comp.complete();
      }
      return;
    }
    _sender.cancel();
    await _receiver.cancelActiveTransfer();
  }

  @override
  Future<void> updateConfig({String? deviceName, String? downloadDir}) async {
    if (deviceName != null) {
      _deviceName = deviceName;
      _receiver.deviceName = deviceName;
    }
    if (downloadDir != null) {
      _downloadDir = downloadDir;
      _receiver.downloadDir = downloadDir;
    }
    if (_usingNative) {
      NativeBridge.instance.updateConfig(
        deviceName: _deviceName,
        downloadDir: _downloadDir,
      );
      return;
    }
    if (_enabled && _receiver.isRunning) {
      await _receiver.updateAdvertisement();
    }
  }

  void _handleNativeEvent(Map<String, dynamic> ev) {
    final type = ev['type'] as String? ?? '';
    switch (type) {
      case 'rqs_ready':
        _nativePort = (ev['port'] as num?)?.toInt() ?? _nativePort;
        break;

      case 'rqs_peer_found':
        final m = Map<String, dynamic>.from(ev['peer'] as Map? ?? const {});
        final fullname = m['fullname'] as String? ?? '';
        final peerId = 'rqs:${m['id'] ?? fullname}';
        final rawType = (m['device_type'] as num?)?.toInt() ?? 0;
        final kind = switch (rawType) {
          1 => DeviceKind.phone,
          2 => DeviceKind.tablet,
          3 => DeviceKind.pc,
          _ => DeviceKind.unknown,
        };
        final dev = NearbyDevice(
          id: peerId,
          name: m['name'] as String? ?? 'Nearby Device',
          ip: m['ip'] as String? ?? '',
          port: (m['port'] as num?)?.toInt() ?? 0,
          kind: kind,
          protocol: TransferProtocol.quickShare,
          isUsb: false,
          endpointId: m['id'] as String?,
          channelId: id,
          lastSeen: DateTime.now(),
        );
        _peers[peerId] = dev;
        if (fullname.isNotEmpty) {
          _fullnameToPeerId[fullname] = peerId;
        }
        _emitDevices();
        break;

      case 'rqs_peer_lost':
        final fullname = ev['fullname'] as String? ?? '';
        final pid = _fullnameToPeerId.remove(fullname);
        if (pid != null && _peers.remove(pid) != null) {
          _emitDevices();
        }
        break;

      case 'rqs_incoming_offer':
        final oid = ev['id'] as String? ?? '';
        final sender = ev['sender_name'] as String? ?? 'Nearby Device';
        final ip = ev['sender_ip'] as String? ?? '';
        final pin = ev['pin_code'] as String? ?? '';
        final totalBytes = (ev['total_bytes'] as num?)?.toInt() ?? 0;
        final names = (ev['file_names'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList();
        final trusted = isTrustedFn(sender, ip);
        final offer = IncomingOffer(
          id: oid,
          senderName: sender,
          senderAddress: ip,
          protocol: TransferProtocol.quickShare,
          pin: pin.isNotEmpty ? pin : null,
          files: names
              .map(
                (n) => IncomingFileMeta(
                  name: n,
                  size: names.length == 1 ? totalBytes : 0,
                  mimeType: 'application/octet-stream',
                ),
              )
              .toList(),
          texts: const [],
          totalSize: totalBytes,
          isTrusted: trusted,
          isUsb: false,
        );
        _nativeOffers[oid] = offer;
        if (autoAcceptAllFn() || (autoAcceptTrustedFn() && trusted)) {
          _eventsCtrl.add(TransportIncomingOffer(id, offer));
          unawaited(acceptOffer(oid));
        } else {
          _eventsCtrl.add(TransportIncomingOffer(id, offer));
        }
        break;

      case 'rqs_incoming_progress':
        final oid = ev['id'] as String? ?? '';
        final offer = _nativeOffers[oid];
        if (offer != null) {
          _eventsCtrl.add(
            TransportIncomingProgress(
              id,
              offer,
              ev['file_name'] as String? ?? '',
              (ev['received'] as num?)?.toInt() ?? 0,
              (ev['total'] as num?)?.toInt() ?? offer.totalSize,
              (ev['speed_bps'] as num?)?.toDouble() ?? 0,
            ),
          );
        }
        break;

      case 'rqs_incoming_completed':
        final oid = ev['id'] as String? ?? '';
        final offer = _nativeOffers.remove(oid);
        if (offer != null) {
          final paths = (ev['saved_paths'] as List<dynamic>? ?? const [])
              .map((e) => e.toString())
              .toList();
          final items = <IncomingTransferItem>[];
          for (var i = 0; i < paths.length; i++) {
            final meta = i < offer.files.length ? offer.files[i] : null;
            final actualSize = Platform.isWindows || Platform.isLinux
                ? (File(paths[i]).existsSync() ? File(paths[i]).lengthSync() : 0)
                : 0;
            items.add(
              IncomingTransferItem(
                name: meta?.name ?? p.basename(paths[i]),
                size: actualSize > 0 ? actualSize : (meta?.size ?? 0),
                mimeType: meta?.mimeType ?? 'application/octet-stream',
                savedPathOrUri: paths[i],
              ),
            );
          }
          _eventsCtrl
              .add(TransportIncomingCompleted(id, offer, items, const []));
        }
        break;

      case 'rqs_incoming_canceled':
        final oid = ev['id'] as String? ?? '';
        _nativeOffers.remove(oid);
        _eventsCtrl.add(TransportIncomingCanceled(id));
        break;

      case 'rqs_outgoing_pin':
        final tid = ev['id'] as String? ?? '';
        final dev = _nativeOutgoingDevice;
        final pin = ev['pin_code'] as String? ?? '';
        if (tid == _nativeOutgoingId && dev != null && pin.isNotEmpty) {
          _nativeActivePin = pin;
          _eventsCtrl.add(TransportOutgoingPinReady(id, dev.name, pin));
        }
        break;

      case 'rqs_outgoing_progress':
        final tid = ev['id'] as String? ?? '';
        final dev = _nativeOutgoingDevice;
        if (tid == _nativeOutgoingId && dev != null) {
          _eventsCtrl.add(
            TransportOutgoingProgress(
              id,
              dev.name,
              ev['file_name'] as String? ?? '',
              (ev['sent'] as num?)?.toInt() ?? 0,
              (ev['total'] as num?)?.toInt() ?? 0,
              (ev['speed_bps'] as num?)?.toDouble() ?? 0,
              TransferProtocol.quickShare,
              pin: _nativeActivePin,
            ),
          );
        }
        break;

      case 'rqs_outgoing_completed':
        final tid = ev['id'] as String? ?? '';
        final dev = _nativeOutgoingDevice;
        if (tid == _nativeOutgoingId && dev != null) {
          _eventsCtrl.add(
            TransportOutgoingCompleted(
              id,
              dev.name,
              _nativeOutgoingTitle,
              _nativeOutgoingFiles.length,
              TransferProtocol.quickShare,
              _nativeOutgoingFiles,
            ),
          );
          final comp = _nativeOutgoingCompleter;
          if (comp != null && !comp.isCompleted) {
            comp.complete();
          }
        }
        break;

      case 'rqs_error':
        final eid = ev['id'] as String? ?? '';
        final msg = ev['message'] as String? ?? 'Quick Share failed';
        if (eid == _nativeOutgoingId) {
          if (_nativeCanceledByUser) {
            _eventsCtrl.add(TransportOutgoingCanceled(id));
          } else {
            final cleanMsg =
                msg.toLowerCase().contains('declined') ? declinedMessageFn() : msg;
            _eventsCtrl.add(TransportOutgoingError(id, cleanMsg));
          }
          final comp = _nativeOutgoingCompleter;
          if (comp != null && !comp.isCompleted) {
            comp.completeError(StateError(msg));
          }
        } else if (_nativeOffers.remove(eid) != null) {
          _eventsCtrl.add(TransportIncomingError(id, msg));
        }
        break;
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
