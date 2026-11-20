import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/models.dart';
import '../../services/platform_bridge.dart';
import 'md_constants.dart';

class MaterialDropDiscovery {
  RawDatagramSocket? _udpSocket;
  StreamSubscription<RawSocketEvent>? _udpSub;
  Timer? _udpPingTimer;
  Timer? _usbProbeTimer;
  Timer? _subnetScanTimer;
  Timer? _pruneTimer;

  bool _scanning = false;
  bool _disposed = false;
  bool _subnetScanningInFlight = false;

  final String instanceId;
  final bool multiInstance;
  final String Function() deviceNameFn;
  final int Function() localPortFn;
  final void Function(NearbyDevice device) onDeviceFound;
  final void Function(String deviceId) onDeviceExpired;

  final Map<String, DateTime> _seenTimestamps = {};

  MaterialDropDiscovery({
    this.instanceId = '',
    this.multiInstance = false,
    required this.deviceNameFn,
    required this.localPortFn,
    required this.onDeviceFound,
    required this.onDeviceExpired,
  });

  bool get isScanning => _scanning;

  Future<void> startDiscovery() async {
    if (_scanning) return;
    _scanning = true;
    _disposed = false;

    await PlatformBridge.instance.acquireMulticastLock();
    await _ensureUdpSocket();

    // Immediate probes on start
    unawaited(_sendUdpPing());
    unawaited(_probeUsbLoopback());
    unawaited(_probeLocalSubnets());

    _udpPingTimer = Timer.periodic(const Duration(milliseconds: 1400), (_) {
      if (_scanning && !_disposed) unawaited(_sendUdpPing());
    });

    _usbProbeTimer = Timer.periodic(const Duration(milliseconds: 1800), (_) {
      if (_scanning && !_disposed) unawaited(_probeUsbLoopback());
    });

    _subnetScanTimer = Timer.periodic(const Duration(milliseconds: 4500), (_) {
      if (_scanning && !_disposed) unawaited(_probeLocalSubnets());
    });

    _pruneTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _pruneExpired();
    });
  }

  Future<void> triggerImmediateRefresh() async {
    if (!_scanning) {
      await startDiscovery();
      return;
    }
    await Future.wait([
      _sendUdpPing(),
      _probeUsbLoopback(),
      _probeLocalSubnets(),
    ]);
  }

  Future<void> stopDiscovery() async {
    _scanning = false;
    _udpPingTimer?.cancel();
    _udpPingTimer = null;
    _usbProbeTimer?.cancel();
    _usbProbeTimer = null;
    _subnetScanTimer?.cancel();
    _subnetScanTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;

    await _udpSub?.cancel();
    _udpSub = null;
    _udpSocket?.close();
    _udpSocket = null;
    _seenTimestamps.clear();
  }

  Future<void> dispose() async {
    _disposed = true;
    await stopDiscovery();
  }

  Future<void> _ensureUdpSocket() async {
    if (_udpSocket != null) return;
    try {
      final sock = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        MdConstants.udpPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      sock.broadcastEnabled = true;
      sock.multicastLoopback = true;
      _udpSocket = sock;
      _udpSub = sock.listen((ev) {
        if (ev == RawSocketEvent.read) {
          Datagram? dg;
          while ((dg = sock.receive()) != null) {
            _handleUdpDatagram(dg!);
          }
        }
      });
    } catch (_) {
      // Fallback ephemeral socket if port 45872 is already bound by another process
      try {
        final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        sock.broadcastEnabled = true;
        _udpSocket = sock;
        _udpSub = sock.listen((ev) {
          if (ev == RawSocketEvent.read) {
            Datagram? dg;
            while ((dg = sock.receive()) != null) {
              _handleUdpDatagram(dg!);
            }
          }
        });
      } catch (_) {}
    }
  }

  Future<void> _sendUdpPing() async {
    final sock = _udpSocket;
    if (sock == null) return;

    final payload = utf8.encode(jsonEncode({
      'magic': MdConstants.magic,
      'type': 'ping',
      'name': deviceNameFn(),
      'port': localPortFn(),
      'platform': Platform.isAndroid ? 'Android' : 'Windows',
      if (instanceId.isNotEmpty) 'instanceId': instanceId,
    }));

    final targets = await _getBroadcastAddresses();
    for (final addr in targets) {
      try {
        sock.send(payload, addr, MdConstants.udpPort);
      } catch (_) {}
    }
  }

  Future<List<InternetAddress>> _getBroadcastAddresses() async {
    final out = <String, InternetAddress>{
      '255.255.255.255': InternetAddress('255.255.255.255'),
      if (multiInstance) '127.0.0.1': InternetAddress('127.0.0.1'),
      if (multiInstance) '127.0.0.2': InternetAddress('127.0.0.2'),
    };
    final ips = await PlatformBridge.instance.getLocalIpv4Addresses();
    for (final ip in ips) {
      final parts = ip.split('.');
      if (parts.length == 4) {
        final bcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
        out[bcast] = InternetAddress(bcast);
      }
    }
    return out.values.toList();
  }

  void _handleUdpDatagram(Datagram dg) async {
    try {
      final text = utf8.decode(dg.data, allowMalformed: true);
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) return;

      final magic = json['magic'] as String? ?? '';
      if (magic != MdConstants.magic && magic != MdConstants.legacyMagic) return;

      final type = json['type'] as String? ?? '';
      final senderIp = dg.address.address;
      final peerPort = (json['port'] as num?)?.toInt() ?? 0;
      final peerName = (json['name'] as String?)?.trim();
      final platform = json['platform'] as String? ?? '';
      final peerInstanceId = json['instanceId'] as String? ?? '';

      if (instanceId.isNotEmpty && peerInstanceId == instanceId) {
        return;
      }

      final allOwnIps = await PlatformBridge.instance.getAllOwnIpv4Addresses();
      final myPort = localPortFn();
      if (!multiInstance && allOwnIps.contains(senderIp)) {
        return;
      }
      if (multiInstance &&
          peerInstanceId.isEmpty &&
          allOwnIps.contains(senderIp) &&
          peerPort == myPort) {
        return;
      }

      if (type == 'ping') {
        // Reply with pong
        final sock = _udpSocket;
        if (sock != null) {
          final pong = utf8.encode(jsonEncode({
            'magic': MdConstants.magic,
            'type': 'pong',
            'name': deviceNameFn(),
            'port': myPort,
            'platform': Platform.isAndroid ? 'Android' : 'Windows',
            if (instanceId.isNotEmpty) 'instanceId': instanceId,
          }));
          try {
            sock.send(pong, dg.address, dg.port);
          } catch (_) {}
        }
      }

      if (type == 'pong' || type == 'ping') {
        final effectivePort = peerPort > 0
            ? peerPort
            : (platform.toLowerCase() == 'android'
                ? MdConstants.androidHttpPort
                : MdConstants.pcHttpPort);
        final isLoopbackUsb =
            !multiInstance && senderIp == '127.0.0.1';
        final kind = _kindFromPlatform(platform, effectivePort, isLoopbackUsb);
        final dev = NearbyDevice(
          id: 'md:$senderIp:$effectivePort',
          name: (peerName != null && peerName.isNotEmpty)
              ? peerName
              : (kind == DeviceKind.phone ? 'Android Phone' : 'Windows PC'),
          ip: senderIp,
          port: effectivePort,
          kind: kind,
          protocol: TransferProtocol.materialDrop,
          isUsb: isLoopbackUsb,
          instanceId: peerInstanceId.isNotEmpty ? peerInstanceId : null,
          lastSeen: DateTime.now(),
        );
        _seenTimestamps[dev.id] = dev.lastSeen;
        onDeviceFound(dev);
      }
    } catch (_) {}
  }

  Future<void> _probeUsbLoopback() async {
    if (Platform.isWindows) {
      final adb = await PlatformBridge.instance.findAdbExecutable();
      if (adb != null) {
        try {
          final res = await Process.run(adb, ['devices']).timeout(
            const Duration(seconds: 2),
          );
          final out = (res.stdout as String).split('\n').skip(1);
          final hasDevice = out.any(
            (l) => l.trim().isNotEmpty && l.contains('\tdevice'),
          );
          if (hasDevice) {
            await Process.run(adb, [
              'forward',
              'tcp:${MdConstants.androidHttpPort}',
              'tcp:${MdConstants.androidHttpPort}',
            ]).timeout(const Duration(seconds: 2));
            await Process.run(adb, [
              'reverse',
              'tcp:${MdConstants.pcHttpPort}',
              'tcp:${MdConstants.pcHttpPort}',
            ]).timeout(const Duration(seconds: 2));
          }
        } catch (_) {}
      }
      await _checkHttpDirect('127.0.0.1', MdConstants.androidHttpPort, 700,
          forceUsb: true);
      if (multiInstance) {
        final myPort = localPortFn();
        final probePorts = {
          MdConstants.pcHttpPort,
          45875,
          53317,
          53318,
          myPort,
        };
        final probes = <Future<void>>[];
        for (final host in const ['127.0.0.1', '127.0.0.2']) {
          for (final pt in probePorts) {
            probes.add(_checkHttpDirect(host, pt, 450, forceUsb: false));
          }
        }
        await Future.wait(probes);
      }
    } else if (Platform.isAndroid) {
      await _checkHttpDirect('127.0.0.1', MdConstants.pcHttpPort, 700,
          forceUsb: true);
    }
  }

  Future<void> _probeLocalSubnets() async {
    if (_subnetScanningInFlight) return;
    _subnetScanningInFlight = true;
    try {
      final ips = await PlatformBridge.instance.getLocalIpv4Addresses();
      final prefixes = <String>{};
      for (final ip in ips) {
        if (ip.startsWith('192.168.') ||
            ip.startsWith('10.') ||
            ip.startsWith('172.')) {
          final lastDot = ip.lastIndexOf('.');
          if (lastDot > 0) {
            prefixes.add(ip.substring(0, lastDot + 1));
          }
        }
      }
      if (prefixes.isEmpty) return;

      final targets = <(String, int)>[];
      for (final prefix in prefixes) {
        for (var host = 1; host <= 254; host++) {
          final targetIp = '$prefix$host';
          if (ips.contains(targetIp)) continue;
          targets.add((targetIp, MdConstants.pcHttpPort));
          targets.add((targetIp, MdConstants.androidHttpPort));
        }
      }

      const batchSize = 36;
      for (var i = 0; i < targets.length; i += batchSize) {
        if (!_scanning || _disposed) break;
        final end = (i + batchSize).clamp(0, targets.length);
        final batch = targets.sublist(i, end);
        await Future.wait(
          batch.map((t) => _checkHttpDirect(t.$1, t.$2, 350)),
        );
      }
    } finally {
      _subnetScanningInFlight = false;
    }
  }

  Future<void> _checkHttpDirect(
    String ip,
    int port,
    int timeoutMs, {
    bool forceUsb = false,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = Duration(milliseconds: timeoutMs);
    try {
      final req = await client
          .getUrl(Uri.parse('http://$ip:$port/ping'))
          .timeout(Duration(milliseconds: timeoutMs));
      final resp = await req.close().timeout(Duration(milliseconds: timeoutMs));
      if (resp.statusCode == 200) {
        final body = await utf8.decodeStream(resp);
        final json = jsonDecode(body);
        if (json is Map<String, dynamic>) {
          final peerInstanceId = json['instanceId'] as String? ?? '';
          if (instanceId.isNotEmpty && peerInstanceId == instanceId) {
            return;
          }
          final name = (json['name'] as String?)?.trim();
          final type = (json['type'] as String? ?? '').toLowerCase();
          final platform = (json['platform'] as String? ?? '').toLowerCase();
          final isUsb = forceUsb || (!multiInstance && ip == '127.0.0.1');
          final kind = isUsb
              ? DeviceKind.usb
              : _kindFromPlatform(
                  platform.isNotEmpty ? platform : type,
                  port,
                  false,
                );
          final dev = NearbyDevice(
            id: 'md:$ip:$port',
            name: (name != null && name.isNotEmpty)
                ? name
                : (kind == DeviceKind.phone ? 'Android Phone' : 'Windows PC'),
            ip: ip,
            port: port,
            kind: kind,
            protocol: TransferProtocol.materialDrop,
            isUsb: isUsb,
            instanceId: peerInstanceId.isNotEmpty ? peerInstanceId : null,
            lastSeen: DateTime.now(),
          );
          _seenTimestamps[dev.id] = dev.lastSeen;
          onDeviceFound(dev);
        }
      } else {
        await resp.drain<void>();
      }
    } catch (_) {
      // Offline devices are expired uniformly via TTL
    } finally {
      client.close(force: true);
    }
  }

  void _pruneExpired() {
    final now = DateTime.now();
    final expiredIds = <String>[];
    _seenTimestamps.forEach((id, lastSeen) {
      if (now.difference(lastSeen) > MdConstants.deviceTtl) {
        expiredIds.add(id);
      }
    });
    for (final id in expiredIds) {
      _seenTimestamps.remove(id);
      onDeviceExpired(id);
    }
  }

  DeviceKind _kindFromPlatform(String platformOrType, int port, bool isUsb) {
    if (isUsb) return DeviceKind.usb;
    final lower = platformOrType.toLowerCase();
    if (lower.contains('android') ||
        lower.contains('phone') ||
        port == MdConstants.androidHttpPort) {
      return DeviceKind.phone;
    }
    if (lower.contains('tablet')) return DeviceKind.tablet;
    if (lower.contains('windows') ||
        lower.contains('pc') ||
        lower.contains('laptop') ||
        port == MdConstants.pcHttpPort) {
      return DeviceKind.pc;
    }
    return DeviceKind.unknown;
  }
}
