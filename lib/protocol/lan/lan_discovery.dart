import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/models.dart';
import '../../services/platform_bridge.dart';
import 'lan_constants.dart';
import 'tls_identity.dart';

class LanDiscovery {
  RawDatagramSocket? _udpSocket;
  StreamSubscription<RawSocketEvent>? _udpSub;
  Timer? _announceTimer;
  Timer? _pruneTimer;

  bool _scanning = false;
  bool _disposed = false;

  final bool multiInstance;
  final String Function() deviceNameFn;
  final int Function() localPortFn;
  final String Function() fingerprintFn;
  final bool Function() useHttpsFn;
  final void Function(NearbyDevice device) onDeviceFound;
  final void Function(String deviceId) onDeviceExpired;

  final Map<String, DateTime> _seenAt = {};

  LanDiscovery({
    this.multiInstance = false,
    required this.deviceNameFn,
    required this.localPortFn,
    required this.fingerprintFn,
    required this.useHttpsFn,
    required this.onDeviceFound,
    required this.onDeviceExpired,
  });

  bool get isScanning => _scanning;

  Future<void> startDiscovery() async {
    if (_scanning) return;
    _scanning = true;
    _disposed = false;

    await PlatformBridge.instance.acquireMulticastLock();
    await _ensureMulticastSocket();

    unawaited(announce());
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(announce()),
    );

    _pruneTimer?.cancel();
    _pruneTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _pruneExpired(),
    );
  }

  Future<void> stopDiscovery() async {
    _scanning = false;
    _announceTimer?.cancel();
    _announceTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;

    await _udpSub?.cancel();
    _udpSub = null;
    _udpSocket?.close();
    _udpSocket = null;
    _seenAt.clear();
  }

  Future<void> dispose() async {
    _disposed = true;
    await stopDiscovery();
  }

  Future<void> triggerImmediateRefresh() async {
    await _ensureMulticastSocket();
    await announce();
    if (multiInstance) {
      await _probeLocalInstances();
    }
  }

  Map<String, dynamic> buildAnnouncementPayload({bool announceFlag = true}) {
    return {
      'alias': deviceNameFn(),
      'version': LanConstants.protocolVersion,
      'deviceModel': LanConstants.localDeviceModel,
      'deviceType': LanConstants.localDeviceType,
      'fingerprint': fingerprintFn(),
      'port': localPortFn(),
      'protocol': useHttpsFn() ? 'https' : 'http',
      'download': false,
      if (announceFlag) 'announce': true,
    };
  }

  void ingestPeerAnnouncement(
    Map<String, dynamic> data,
    String remoteIp,
  ) {
    final fp = (data['fingerprint'] as String? ?? '').trim().toUpperCase();
    if (fp.isEmpty || fp == fingerprintFn().toUpperCase()) return;

    final alias = (data['alias'] as String? ?? '').trim();
    if (alias.isEmpty) return;

    final port = (data['port'] as num?)?.toInt() ?? LanConstants.defaultPort;
    final protoStr = (data['protocol'] as String? ?? 'https').toLowerCase();
    final useHttps = protoStr == 'https';
    final devType = (data['deviceType'] as String? ?? 'desktop').toLowerCase();

    final kind = switch (devType) {
      'mobile' => DeviceKind.phone,
      'tablet' => DeviceKind.tablet,
      _ => DeviceKind.pc,
    };

    final deviceId = 'lan:$fp';
    _seenAt[deviceId] = DateTime.now();

    onDeviceFound(
      NearbyDevice(
        id: deviceId,
        name: alias,
        ip: remoteIp,
        port: port,
        kind: kind,
        protocol: TransferProtocol.lan,
        isUsb: false,
        instanceId: fp,
        channelId: 'lan',
        tlsFingerprint: fp,
        useHttps: useHttps,
        lastSeen: DateTime.now(),
      ),
    );
  }

  Future<void> _ensureMulticastSocket() async {
    if (_udpSocket != null) return;
    try {
      final sock = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        LanConstants.defaultPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      sock.broadcastEnabled = true;
      sock.multicastLoopback = multiInstance;

      final group = InternetAddress(LanConstants.multicastGroup);
      var joined = false;
      try {
        final ifaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: multiInstance,
        );
        for (final iface in ifaces) {
          try {
            sock.joinMulticast(group, iface);
            joined = true;
          } catch (_) {}
        }
      } catch (_) {}

      if (!joined) {
        try {
          sock.joinMulticast(group);
        } catch (_) {}
      }

      _udpSocket = sock;
      _udpSub = sock.listen(
        (ev) {
          if (ev == RawSocketEvent.read) {
            _drainUdp(sock);
          }
        },
        onError: (_) {},
      );
    } catch (_) {
      // Fall back cleanly if UDP port is already owned by another local service
      try {
        final fallback = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          0,
          reuseAddress: true,
        );
        fallback.broadcastEnabled = true;
        fallback.multicastLoopback = multiInstance;
        _udpSocket = fallback;
        _udpSub = fallback.listen(
          (ev) {
            if (ev == RawSocketEvent.read) {
              _drainUdp(fallback);
            }
          },
          onError: (_) {},
        );
      } catch (_) {}
    }
  }

  void _drainUdp(RawDatagramSocket sock) {
    while (true) {
      final dg = sock.receive();
      if (dg == null) break;
      try {
        final decoded =
            jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
        final fp =
            (decoded['fingerprint'] as String? ?? '').trim().toUpperCase();
        if (fp.isEmpty || fp == fingerprintFn().toUpperCase()) continue;

        final remoteIp = dg.address.address;
        ingestPeerAnnouncement(decoded, remoteIp);

        if (decoded['announce'] == true) {
          final remotePort =
              (decoded['port'] as num?)?.toInt() ?? LanConstants.defaultPort;
          final useHttps =
              (decoded['protocol'] as String? ?? 'https').toLowerCase() ==
                  'https';
          unawaited(
            _registerWithPeer(
              ip: remoteIp,
              port: remotePort,
              useHttps: useHttps,
              expectedFingerprint: fp,
            ),
          );
        }
      } catch (_) {}
    }
  }

  Future<void> announce() async {
    if (_disposed) return;
    await _ensureMulticastSocket();
    final sock = _udpSocket;
    if (sock == null) return;

    final bytes = utf8.encode(jsonEncode(buildAnnouncementPayload()));
    try {
      sock.send(
        bytes,
        InternetAddress(LanConstants.multicastGroup),
        LanConstants.defaultPort,
      );
    } catch (_) {}

    if (multiInstance) {
      for (final ip in const ['127.0.0.1', '127.0.0.2']) {
        try {
          sock.send(bytes, InternetAddress(ip), LanConstants.defaultPort);
        } catch (_) {}
      }
    }
  }

  Future<void> _registerWithPeer({
    required String ip,
    required int port,
    required bool useHttps,
    required String expectedFingerprint,
  }) async {
    final client = useHttps
        ? TlsIdentity.createPinnedClient(
            expectedFingerprint: expectedFingerprint,
            connectionTimeout: const Duration(seconds: 3),
          )
        : (HttpClient()..connectionTimeout = const Duration(seconds: 3));

    try {
      final scheme = useHttps ? 'https' : 'http';
      final req = await client.postUrl(
        Uri.parse('$scheme://$ip:$port${LanConstants.pathRegister}'),
      );
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(buildAnnouncementPayload(announceFlag: false)));
      final resp = await req.close().timeout(const Duration(seconds: 4));
      final body = await utf8.decodeStream(resp);
      if (resp.statusCode == HttpStatus.ok && body.isNotEmpty) {
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        ingestPeerAnnouncement(decoded, ip);
      }
    } catch (_) {
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _probeLocalInstances() async {
    final ownPort = localPortFn();
    const candidatePorts = [
      LanConstants.defaultPort,
      46873,
      46874,
      46875,
      46876,
    ];
    for (final ip in const ['127.0.0.1', '127.0.0.2']) {
      for (final port in candidatePorts) {
        if (port == ownPort && (ip == '127.0.0.1' || ip == '127.0.0.2')) {
          continue;
        }
        unawaited(probeDirectPeer(ip, port, useHttps: true));
      }
    }
  }

  /// Probes a single host:port for its v2 info document, verifying that any
  /// presented TLS certificate SHA-256 matches the `fingerprint` returned in JSON.
  Future<void> probeDirectPeer(
    String ip,
    int port, {
    bool useHttps = true,
  }) async {
    String? observedFp;
    final client = useHttps
        ? TlsIdentity.createPinnedClient(
            expectedFingerprint: null,
            trustOnFirstProbe: true,
            onObservedCertFingerprint: (fp) => observedFp = fp,
            connectionTimeout: const Duration(seconds: 2),
          )
        : (HttpClient()..connectionTimeout = const Duration(seconds: 2));

    try {
      final scheme = useHttps ? 'https' : 'http';
      final req = await client.getUrl(
        Uri.parse('$scheme://$ip:$port${LanConstants.pathInfo}'),
      );
      final resp = await req.close().timeout(const Duration(seconds: 3));
      if (resp.statusCode == HttpStatus.ok) {
        final data =
            jsonDecode(await utf8.decodeStream(resp)) as Map<String, dynamic>;
        final claimedFp =
            (data['fingerprint'] as String? ?? '').trim().toUpperCase();
        if (useHttps &&
            observedFp != null &&
            claimedFp.isNotEmpty &&
            observedFp != claimedFp) {
          return;
        }
        ingestPeerAnnouncement({
          ...data,
          'port': (data['port'] as num?)?.toInt() ?? port,
          'protocol': useHttps ? 'https' : 'http',
        }, ip);
      }
    } catch (_) {
    } finally {
      client.close(force: true);
    }
  }

  void _pruneExpired() {
    final cutoff = DateTime.now().subtract(LanConstants.peerTtl);
    final expired = _seenAt.entries
        .where((e) => e.value.isBefore(cutoff))
        .map((e) => e.key)
        .toList();
    for (final id in expired) {
      _seenAt.remove(id);
      onDeviceExpired(id);
    }
  }
}
