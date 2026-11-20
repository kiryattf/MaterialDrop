import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/models.dart';
import '../../services/platform_bridge.dart';
import '../engine/transport_channel.dart';
import '../engine/transport_models.dart';
import '../ffi/native_bridge.dart';
import 'iroh_link.dart';

/// [TransportChannel] implementing serverless QUIC Internet P2P transfers via `iroh`.
class InternetP2PTransport implements TransportChannel {
  final String Function() deviceNameFn;
  final String Function() downloadDirFn;
  final bool Function(String senderName, String senderIp) isTrustedFn;
  final bool Function() autoAcceptAllFn;
  final bool Function() autoAcceptTrustedFn;
  final void Function(String deepLink, String nodeId)? onReadyChanged;

  final NativeBridge _native = NativeBridge.instance;
  final StreamController<List<NearbyDevice>> _devicesCtrl =
      StreamController<List<NearbyDevice>>.broadcast();
  final StreamController<TransportEvent> _eventsCtrl =
      StreamController<TransportEvent>.broadcast();

  final Map<String, NearbyDevice> _ticketPeers = {};
  final Map<String, IncomingOffer> _pendingOffers = {};
  StreamSubscription<Map<String, dynamic>>? _nativeSub;
  Completer<void>? _activeOutgoingCompleter;
  String? _activeOutgoingTransferId;
  NearbyDevice? _activeOutgoingDevice;
  List<StagedFile> _activeOutgoingFiles = const [];
  String _activeOutgoingDisplayTitle = '';
  bool _canceledByUser = false;
  bool _enabled = true;
  bool _running = false;
  String _nodeId = '';
  String _ticket = '';
  String _deepLink = '';
  int _txSeq = 0;

  InternetP2PTransport({
    required this.deviceNameFn,
    required this.downloadDirFn,
    required this.isTrustedFn,
    required this.autoAcceptAllFn,
    required this.autoAcceptTrustedFn,
    this.onReadyChanged,
    bool enabled = true,
  }) {
    _enabled = enabled;
  }

  @override
  String get id => 'internet_p2p';

  @override
  TransportKind get kind => TransportKind.internetP2p;

  @override
  int get priority => 50;

  @override
  bool get isAvailable => _enabled && _running && _native.isAvailable;

  @override
  int get boundPort => 0;

  String get nodeId => _nodeId;
  String get ticket => _ticket;
  String get deepLink => _deepLink;
  bool get isEnabled => _enabled;
  bool get isEndpointReady => _ticket.isNotEmpty && _deepLink.isNotEmpty;

  @override
  Stream<List<NearbyDevice>> get devicesStream => _devicesCtrl.stream;

  @override
  Stream<TransportEvent> get eventsStream => _eventsCtrl.stream;

  @override
  Future<void> start({int? explicitPort, String? bindAddress}) async {
    if (_running || !_enabled) return;
    if (!_native.isAvailable) {
      _running = false;
      return;
    }

    final supportDir = await getApplicationSupportDirectory();
    final stateDir = p.join(supportDir.path, 'iroh_state');
    final ok = _native.init(
      stateDir: stateDir,
      deviceName: deviceNameFn(),
      downloadDir: downloadDirFn(),
    );
    if (!ok) {
      _running = false;
      return;
    }

    _nativeSub ??= _native.eventsStream.listen(_handleNativeEvent);
    _running = _native.startIroh();
    if (_running) {
      final cachedTicket = _native.getIrohTicket();
      final cachedNode = _native.getIrohNodeId();
      if (cachedTicket.isNotEmpty) {
        _nodeId = cachedNode;
        _ticket = cachedTicket;
        _deepLink = IrohDeepLink(
          ticket: cachedTicket,
          deviceName: deviceNameFn(),
          nodeId: cachedNode,
        ).toUriString();
        onReadyChanged?.call(_deepLink, _nodeId);
      }
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _nativeSub?.cancel();
    _nativeSub = null;
    _native.stopIroh();
  }

  Future<void> setEnabled(bool enabled) async {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (_enabled) {
      await start();
    } else {
      await stop();
    }
  }

  @override
  Future<void> startDiscovery() async {
    _emitDevices();
  }

  @override
  Future<void> stopDiscovery() async {
    _emitDevices();
  }

  @override
  Future<void> refreshDiscovery() async {
    _emitDevices();
  }

  @override
  Future<void> updateConfig({String? deviceName, String? downloadDir}) async {
    final name = deviceName ?? deviceNameFn();
    final dir = downloadDir ?? downloadDirFn();
    _native.updateConfig(deviceName: name, downloadDir: dir);
    if (deviceName != null && _ticket.isNotEmpty) {
      _deepLink = IrohDeepLink(
        ticket: _ticket,
        deviceName: name,
        nodeId: _nodeId,
      ).toUriString();
      onReadyChanged?.call(_deepLink, _nodeId);
    }
  }

  /// Registers or updates a remote peer from a `materialdrop://iroh/...` deep link,
  /// NFC/BLE handshake ticket, or pasted endpoint ticket.
  NearbyDevice? addPeerFromLinkOrTicket(
    String raw, {
    String? fallbackName,
  }) {
    final parsed = IrohDeepLink.parse(raw);
    if (parsed == null) return null;
    if (_ticket.isNotEmpty && parsed.ticket == _ticket) return null;

    final peerId = parsed.nodeId?.isNotEmpty == true
        ? 'iroh:${parsed.nodeId}'
        : 'iroh:${parsed.ticket.hashCode}';
    final devName =
        parsed.deviceName ?? fallbackName ?? 'Remote P2P (${parsed.shortNodeId})';

    final dev = NearbyDevice(
      id: peerId,
      name: devName,
      ip: 'Iroh QUIC',
      port: 0,
      kind: DeviceKind.unknown,
      protocol: TransferProtocol.internetP2p,
      isUsb: false,
      endpointId: parsed.nodeId ?? peerId,
      channelId: id,
      irohTicket: parsed.ticket,
      lastSeen: DateTime.now(),
    );
    _ticketPeers[peerId] = dev;
    _emitDevices();
    return dev;
  }

  @override
  Future<void> sendOffer(
    NearbyDevice device,
    List<StagedFile> files, {
    required String localDeviceName,
  }) async {
    if (files.isEmpty) return;
    if (!isAvailable) {
      throw StateError('Internet P2P (Iroh) engine is unavailable on this build');
    }
    final ticket = device.irohTicket;
    if (ticket == null || ticket.isEmpty) {
      throw ArgumentError('Missing peer Iroh ticket');
    }

    _canceledByUser = false;
    final displayTitle = files.length == 1
        ? files.first.name
        : '${files.first.name} (+${files.length - 1})';
    final transferId = 'tx_iroh_${++_txSeq}_${DateTime.now().millisecondsSinceEpoch}';

    _activeOutgoingTransferId = transferId;
    _activeOutgoingDevice = device;
    _activeOutgoingFiles = List<StagedFile>.from(files);
    _activeOutgoingDisplayTitle = displayTitle;
    final completer = Completer<void>();
    _activeOutgoingCompleter = completer;

    _eventsCtrl.add(
      TransportOutgoingConnecting(
        id,
        device.name,
        TransferProtocol.internetP2p,
      ),
    );

    final tempFiles = <File>[];
    try {
      final specs = <Map<String, dynamic>>[];
      for (final sf in files) {
        final localPath = await _materializeFilePath(sf, tempFiles);
        specs.add({
          'path': localPath,
          'name': sf.name,
          'size': sf.size,
          'mime_type': sf.mimeType,
          'relative_path': sf.relativePath,
        });
      }

      final queued = _native.sendIrohFiles(
        transferId: transferId,
        ticketOrLink: ticket,
        files: specs,
      );
      if (!queued) {
        throw StateError('Failed to dispatch Iroh QUIC send task');
      }

      await completer.future;
    } finally {
      _activeOutgoingCompleter = null;
      _activeOutgoingTransferId = null;
      _activeOutgoingDevice = null;
      _activeOutgoingFiles = const [];
      _activeOutgoingDisplayTitle = '';
      for (final tmp in tempFiles) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
    }
  }

  Future<String> _materializeFilePath(
    StagedFile sf,
    List<File> tempFiles,
  ) async {
    if (sf.path != null && sf.path!.isNotEmpty) {
      return sf.path!;
    }
    final tmpDir = await getTemporaryDirectory();
    final safeName = sf.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final tmpFile = File(p.join(
      tmpDir.path,
      'md_iroh_${DateTime.now().microsecondsSinceEpoch}_$safeName',
    ));
    final sink = tmpFile.openWrite();
    await for (final chunk in PlatformBridge.instance.openFileReadStream(sf)) {
      sink.add(chunk);
    }
    await sink.close();
    tempFiles.add(tmpFile);
    return tmpFile.path;
  }

  @override
  Future<void> acceptOffer(String offerId) async {
    _native.respondIrohOffer(offerId, true);
  }

  @override
  Future<void> declineOffer(String offerId) async {
    _native.respondIrohOffer(offerId, false);
  }

  @override
  Future<void> cancelTransfer({String? offerId}) async {
    if (offerId != null && offerId.isNotEmpty) {
      _native.cancelIrohTransfer(offerId);
      return;
    }
    _canceledByUser = true;
    final tid = _activeOutgoingTransferId;
    if (tid != null) {
      _native.cancelIrohTransfer(tid);
    }
    _eventsCtrl.add(TransportOutgoingCanceled(id));
    final comp = _activeOutgoingCompleter;
    if (comp != null && !comp.isCompleted) {
      comp.complete();
    }
  }

  void _handleNativeEvent(Map<String, dynamic> ev) {
    final type = ev['type'] as String? ?? '';
    switch (type) {
      case 'iroh_ready':
        _nodeId = ev['node_id'] as String? ?? _nodeId;
        _ticket = ev['ticket'] as String? ?? _ticket;
        _deepLink = ev['deep_link'] as String? ?? _deepLink;
        if (_deepLink.isNotEmpty) {
          onReadyChanged?.call(_deepLink, _nodeId);
        }
        break;

      case 'iroh_incoming_offer':
        final oid = ev['id'] as String? ?? '';
        final sender = ev['sender_name'] as String? ?? 'Iroh Peer';
        final nodeId = ev['sender_node_id'] as String? ?? 'iroh';
        final totalBytes = (ev['total_bytes'] as num?)?.toInt() ?? 0;
        final filesRaw = (ev['files'] as List<dynamic>? ?? const []);
        final items = filesRaw.map((raw) {
          final m = Map<String, dynamic>.from(raw as Map);
          return IncomingFileMeta(
            name: m['name'] as String? ?? 'file',
            size: (m['size'] as num?)?.toInt() ?? 0,
            mimeType: m['mime_type'] as String? ?? 'application/octet-stream',
            relativePath: m['relative_path'] as String?,
          );
        }).toList();

        final trusted = isTrustedFn(sender, nodeId);
        final offer = IncomingOffer(
          id: oid,
          senderName: sender,
          senderAddress:
              nodeId.length >= 12 ? '${nodeId.substring(0, 8)}...' : nodeId,
          protocol: TransferProtocol.internetP2p,
          files: items,
          texts: const [],
          totalSize: totalBytes,
          isTrusted: trusted,
          isUsb: false,
        );
        _pendingOffers[oid] = offer;
        if (autoAcceptAllFn() || (autoAcceptTrustedFn() && trusted)) {
          _eventsCtrl.add(TransportIncomingOffer(id, offer));
          unawaited(acceptOffer(oid));
        } else {
          _eventsCtrl.add(TransportIncomingOffer(id, offer));
        }
        break;

      case 'iroh_incoming_progress':
        final oid = ev['id'] as String? ?? '';
        final offer = _pendingOffers[oid];
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

      case 'iroh_incoming_completed':
        final oid = ev['id'] as String? ?? '';
        final offer = _pendingOffers.remove(oid);
        if (offer != null) {
          final paths = (ev['saved_paths'] as List<dynamic>? ?? const [])
              .map((e) => e.toString())
              .toList();
          final completed = <IncomingTransferItem>[];
          for (var i = 0; i < paths.length; i++) {
            final item = i < offer.files.length ? offer.files[i] : null;
            completed.add(
              IncomingTransferItem(
                name: item?.name ?? p.basename(paths[i]),
                size: item?.size ?? 0,
                mimeType: item?.mimeType ?? 'application/octet-stream',
                savedPathOrUri: paths[i],
              ),
            );
          }
          _eventsCtrl
              .add(TransportIncomingCompleted(id, offer, completed, const []));
        }
        break;

      case 'iroh_incoming_canceled':
        final oid = ev['id'] as String? ?? '';
        _pendingOffers.remove(oid);
        _eventsCtrl.add(TransportIncomingCanceled(id));
        break;

      case 'iroh_outgoing_progress':
        final tid = ev['id'] as String? ?? '';
        final dev = _activeOutgoingDevice;
        if (tid == _activeOutgoingTransferId && dev != null) {
          _eventsCtrl.add(
            TransportOutgoingProgress(
              id,
              dev.name,
              ev['file_name'] as String? ?? '',
              (ev['sent'] as num?)?.toInt() ?? 0,
              (ev['total'] as num?)?.toInt() ?? 0,
              (ev['speed_bps'] as num?)?.toDouble() ?? 0,
              TransferProtocol.internetP2p,
            ),
          );
        }
        break;

      case 'iroh_outgoing_completed':
        final tid = ev['id'] as String? ?? '';
        final dev = _activeOutgoingDevice;
        if (tid == _activeOutgoingTransferId && dev != null) {
          _eventsCtrl.add(
            TransportOutgoingCompleted(
              id,
              dev.name,
              _activeOutgoingDisplayTitle,
              _activeOutgoingFiles.length,
              TransferProtocol.internetP2p,
              _activeOutgoingFiles,
            ),
          );
          final comp = _activeOutgoingCompleter;
          if (comp != null && !comp.isCompleted) {
            comp.complete();
          }
        }
        break;

      case 'iroh_error':
        final eid = ev['id'] as String? ?? '';
        final msg = ev['message'] as String? ?? 'Iroh P2P transfer failed';
        if (eid == _activeOutgoingTransferId) {
          if (_canceledByUser) {
            _eventsCtrl.add(TransportOutgoingCanceled(id));
          } else {
            _eventsCtrl.add(TransportOutgoingError(id, msg));
          }
          final comp = _activeOutgoingCompleter;
          if (comp != null && !comp.isCompleted) {
            comp.completeError(StateError(msg));
          }
        } else if (_pendingOffers.remove(eid) != null) {
          _eventsCtrl.add(TransportIncomingError(id, msg));
        }
        break;
    }
  }

  void _emitDevices() {
    if (!_devicesCtrl.isClosed) {
      _devicesCtrl.add(
        List<NearbyDevice>.unmodifiable(_ticketPeers.values),
      );
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _devicesCtrl.close();
    await _eventsCtrl.close();
  }
}
