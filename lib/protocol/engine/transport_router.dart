import 'dart:async';

import '../../models/models.dart';
import 'transport_channel.dart';
import 'transport_models.dart';

/// Aggregates multiple [TransportChannel] implementations into unified [DiscoveredPeer]
/// instances and handles priority routing & automatic channel fallback.
class TransportRouter {
  final List<TransportChannel> _channels;
  final bool Function(NearbyDevice device) isSelfFn;
  final bool Function(NearbyDevice device) isTrustedFn;

  final Map<String, List<NearbyDevice>> _devicesByChannel = {};
  final Map<String, DiscoveredPeer> _peersByKey = {};
  final List<StreamSubscription<dynamic>> _subs = [];

  final StreamController<List<DiscoveredPeer>> _peersCtrl =
      StreamController<List<DiscoveredPeer>>.broadcast();
  final StreamController<TransportEvent> _eventsCtrl =
      StreamController<TransportEvent>.broadcast();

  String? _activeOutgoingChannelId;
  bool _outgoingCanceledByUser = false;

  TransportRouter({
    required List<TransportChannel> channels,
    required this.isSelfFn,
    required this.isTrustedFn,
  }) : _channels = List<TransportChannel>.from(channels)
          ..sort((a, b) => a.priority.compareTo(b.priority)) {
    for (final ch in _channels) {
      _subs.add(
        ch.devicesStream.listen((list) {
          _devicesByChannel[ch.id] = list;
          _rebuildPeers();
        }),
      );
      _subs.add(
        ch.eventsStream.listen((ev) {
          if (!_eventsCtrl.isClosed) {
            _eventsCtrl.add(ev);
          }
        }),
      );
    }
  }

  List<TransportChannel> get channels => List.unmodifiable(_channels);
  List<DiscoveredPeer> get currentPeers => List.unmodifiable(_peersByKey.values);
  Stream<List<DiscoveredPeer>> get peersStream => _peersCtrl.stream;
  Stream<TransportEvent> get eventsStream => _eventsCtrl.stream;

  TransportChannel? channelById(String id) {
    for (final ch in _channels) {
      if (ch.id == id) return ch;
    }
    return null;
  }

  void pruneSelfDevices() => _rebuildPeers();

  void clearPeers() {
    _devicesByChannel.clear();
    _peersByKey.clear();
    if (!_peersCtrl.isClosed) _peersCtrl.add(const []);
  }

  String _peerKeyFor(NearbyDevice d) {
    if (d.isUsb) {
      return 'usb:${d.protocol.name}:${d.port}';
    }
    if (d.protocol == TransferProtocol.quickShare) {
      return 'qs:${d.id}';
    }
    if (d.protocol == TransferProtocol.tapProximity) {
      return 'tap:${d.instanceId ?? d.id}';
    }
    if (d.protocol == TransferProtocol.internetP2p) {
      return 'iroh:${d.endpointId ?? d.id}';
    }
    return 'peer:${d.ip}:${d.name.trim().toLowerCase()}';
  }

  void _rebuildPeers() {
    final merged = <String, Map<String, TransportEndpoint>>{};
    final meta = <String, NearbyDevice>{};

    for (final ch in _channels) {
      final list = _devicesByChannel[ch.id] ?? const [];
      for (final d in list) {
        if (isSelfFn(d)) continue;
        final key = _peerKeyFor(d);
        final endpoints = merged.putIfAbsent(key, () => {});
        endpoints[ch.id] = TransportEndpoint(
          channelId: ch.id,
          kind: ch.kind,
          priority: ch.priority,
          protocol: d.protocol,
          ip: d.ip,
          port: d.port,
          isUsb: d.isUsb,
          useHttps: d.useHttps,
          tlsFingerprint: d.tlsFingerprint,
          endpointId: d.endpointId,
          instanceId: d.instanceId,
          rssi: d.rssi,
          proximityZone: d.proximityZone,
          irohTicket: d.irohTicket,
        );
        final existing = meta[key];
        if (existing == null || d.lastSeen.isAfter(existing.lastSeen)) {
          meta[key] = d;
        }
      }
    }

    final rebuilt = <String, DiscoveredPeer>{};
    for (final entry in merged.entries) {
      final m = meta[entry.key]!;
      rebuilt[entry.key] = DiscoveredPeer(
        peerKey: entry.key,
        name: m.name,
        deviceKind: m.kind,
        endpoints: entry.value,
        lastSeen: m.lastSeen,
      );
    }

    _peersByKey
      ..clear()
      ..addAll(rebuilt);

    if (!_peersCtrl.isClosed) {
      _peersCtrl.add(currentPeers);
    }
  }

  List<NearbyDevice> sortedNearbyDevices() {
    final list = _peersByKey.values.map((p) => p.toNearbyDevice()).toList();
    list.sort((a, b) {
      final aTrust = isTrustedFn(a) ? 0 : 1;
      final bTrust = isTrustedFn(b) ? 0 : 1;
      if (aTrust != bTrust) return aTrust.compareTo(bTrust);

      final aUsb = a.isUsb ? 0 : 1;
      final bUsb = b.isUsb ? 0 : 1;
      if (aUsb != bUsb) return aUsb.compareTo(bUsb);

      if (a.protocol != b.protocol) {
        if (a.protocol == TransferProtocol.quickShare) return 1;
        if (b.protocol == TransferProtocol.quickShare) return -1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  /// Sends [files] to [device], automatically falling back across ordered
  /// endpoints on the matching [DiscoveredPeer] if the primary channel fails
  /// with a connection error (unless explicitly declined or canceled).
  Future<void> sendFiles(
    NearbyDevice device,
    List<StagedFile> files, {
    required String localDeviceName,
  }) async {
    _outgoingCanceledByUser = false;
    final peer = _peersByKey[device.id];
    final routes = <({TransportChannel ch, NearbyDevice target})>[];

    if (peer != null) {
      for (final ep in peer.orderedEndpoints) {
        final ch = channelById(ep.channelId);
        if (ch != null && ch.isAvailable) {
          routes.add((
            ch: ch,
            target: ep.toNearbyDevice(
              peerKey: peer.peerKey,
              name: peer.name,
              deviceKind: peer.deviceKind,
              lastSeen: peer.lastSeen,
            ),
          ));
        }
      }
      // Also attach any matching-name proximity/internet fallback peer when LAN routes fail
      final lowerName = peer.name.trim().toLowerCase();
      for (final other in _peersByKey.values) {
        if (other.peerKey == peer.peerKey) continue;
        if (other.name.trim().toLowerCase() != lowerName) continue;
        for (final ep in other.orderedEndpoints) {
          if (routes.any((r) => r.ch.id == ep.channelId)) continue;
          final ch = channelById(ep.channelId);
          if (ch != null && ch.isAvailable) {
            routes.add((
              ch: ch,
              target: ep.toNearbyDevice(
                peerKey: other.peerKey,
                name: other.name,
                deviceKind: other.deviceKind,
                lastSeen: other.lastSeen,
              ),
            ));
          }
        }
      }
    }

    if (routes.isEmpty) {
      final preferredId = device.channelId ??
          switch (device.protocol) {
            TransferProtocol.quickShare => 'quickshare',
            TransferProtocol.lan => 'lan',
            TransferProtocol.tapProximity => 'tap_proximity',
            TransferProtocol.internetP2p => 'internet_p2p',
            TransferProtocol.materialDrop => 'direct',
          };
      final ch = channelById(preferredId);
      if (ch == null) {
        throw StateError('No transport channel available for $preferredId');
      }
      routes.add((ch: ch, target: device));
    }

    Object? lastError;
    for (final route in routes) {
      if (_outgoingCanceledByUser) return;
      _activeOutgoingChannelId = route.ch.id;
      try {
        await route.ch.sendOffer(
          route.target,
          files,
          localDeviceName: localDeviceName,
        );
        _activeOutgoingChannelId = null;
        return;
      } catch (e) {
        lastError = e;
        if (_outgoingCanceledByUser) return;
        // Stop retrying if the receiver explicitly rejected/declined
        final msg = e.toString().toLowerCase();
        if (msg.contains('declined') || msg.contains('403')) {
          rethrow;
        }
      }
    }

    _activeOutgoingChannelId = null;
    if (lastError != null) {
      throw lastError;
    }
  }

  Future<void> cancelOutgoing() async {
    _outgoingCanceledByUser = true;
    final activeId = _activeOutgoingChannelId;
    if (activeId != null) {
      await channelById(activeId)?.cancelTransfer();
      _activeOutgoingChannelId = null;
    }
  }

  Future<void> acceptIncoming(String channelId, String offerId) async {
    await channelById(channelId)?.acceptOffer(offerId);
  }

  Future<void> declineIncoming(String channelId, String offerId) async {
    await channelById(channelId)?.declineOffer(offerId);
  }

  Future<void> cancelIncoming(String channelId, {String? offerId}) async {
    await channelById(channelId)?.cancelTransfer(offerId: offerId);
  }

  Future<void> startDiscovery() async {
    for (final ch in _channels) {
      if (ch.isAvailable) {
        await ch.startDiscovery();
      }
    }
  }

  Future<void> stopDiscovery() async {
    for (final ch in _channels) {
      await ch.stopDiscovery();
    }
    clearPeers();
  }

  Future<void> refreshDiscovery() async {
    for (final ch in _channels) {
      if (ch.isAvailable) {
        await ch.refreshDiscovery();
      }
    }
  }

  Future<void> updateConfig({String? deviceName, String? downloadDir}) async {
    for (final ch in _channels) {
      await ch.updateConfig(deviceName: deviceName, downloadDir: downloadDir);
    }
  }

  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    for (final ch in _channels) {
      await ch.dispose();
    }
    await _peersCtrl.close();
    await _eventsCtrl.close();
  }
}
