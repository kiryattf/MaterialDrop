import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/models.dart';
import '../../services/platform_bridge.dart';
import 'qs_mdns.dart';

/// Cross-platform Quick Share mDNS advertiser & browser (`_FC9F5ED42C8A._tcp.local`).
///
/// Uses native [NsdManager] via [PlatformBridge] on Android and pure-Dart RFC 6762
/// multicast DNS over UDP 5353 on Windows (plus UDP multicast browsing fallback).
class QsMdnsService {
  static final InternetAddress _mdnsMulticast = InternetAddress('224.0.0.251');
  static const int _mdnsPort = 5353;

  static const int _typeA = 1;
  static const int _typePtr = 12;
  static const int _typeTxt = 16;
  static const int _typeSrv = 33;
  static const int _classIn = 1;
  static const int _cacheFlush = 0x8000;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSub;
  StreamSubscription<NsdDiscoveryEvent>? _nsdSub;
  Timer? _announceTimer;
  Timer? _browseTimer;

  bool _isAdvertising = false;
  bool _isBrowsing = false;
  bool _disposed = false;

  int _listenPort = 0;
  String _advertisedIp = '';
  String _instanceName = '';
  String _hostTarget = '';
  String _txtN = '';
  Uint8List _endpointId = Uint8List(4);

  final void Function(NearbyDevice device)? onDeviceFound;
  final void Function(String instanceName)? onDeviceLost;

  QsMdnsService({
    this.onDeviceFound,
    this.onDeviceLost,
  });

  Uint8List get endpointId => _endpointId;
  String get instanceName => _instanceName;

  Future<void> startAdvertising({
    required String deviceName,
    required int port,
    required String ipAddress,
  }) async {
    _listenPort = port;
    _advertisedIp = ipAddress;

    final hostSeed = Platform.localHostname.isNotEmpty
        ? Platform.localHostname
        : deviceName;
    _endpointId = QsMdns.stableEndpointId(hostSeed);
    _instanceName = QsMdns.buildServiceInstanceName(_endpointId);
    final sanitizedHost = hostSeed
        .replaceAll(RegExp(r'[^a-zA-Z0-9\-]'), '-')
        .replaceAll(RegExp(r'-+'), '-');
    _hostTarget = '${sanitizedHost.isEmpty ? "materialdrop" : sanitizedHost}.local';

    final targetType = Platform.isAndroid
        ? ShareTargetType.phone
        : ShareTargetType.laptop;
    _txtN = QsMdns.buildEndpointInfoTxtValue(deviceName, targetType);
    _isAdvertising = true;

    if (Platform.isAndroid) {
      await PlatformBridge.instance.registerNsdService(
        instanceName: _instanceName,
        port: _listenPort,
        txtN: _txtN,
        txtIpv4: _advertisedIp,
      );
      return;
    }

    await _ensureSocket();
    _sendAnnouncement(ttl: 120);

    // Startup burst (5x every 2s) + steady 6s re-announce (matches server.py)
    var burstCount = 0;
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(const Duration(seconds: 2), (t) {
      if (!_isAdvertising || _disposed) {
        t.cancel();
        return;
      }
      burstCount++;
      _sendAnnouncement(ttl: 120);
      if (burstCount >= 5) {
        t.cancel();
        _announceTimer = Timer.periodic(const Duration(seconds: 6), (_) {
          if (_isAdvertising && !_disposed) {
            _sendAnnouncement(ttl: 120);
          }
        });
      }
    });
  }

  Future<void> stopAdvertising() async {
    _isAdvertising = false;
    _announceTimer?.cancel();
    _announceTimer = null;

    if (Platform.isAndroid) {
      await PlatformBridge.instance.unregisterNsdService();
    } else if (_socket != null && _instanceName.isNotEmpty) {
      _sendAnnouncement(ttl: 0); // goodbye packet
    }
    if (!_isBrowsing) {
      await _closeSocket();
    }
  }

  Future<void> startBrowsing() async {
    if (_isBrowsing) return;
    _isBrowsing = true;

    if (Platform.isAndroid) {
      await PlatformBridge.instance.acquireMulticastLock();
      _nsdSub?.cancel();
      _nsdSub = PlatformBridge.instance.nsdEvents.listen(_handleNsdEvent);
      await PlatformBridge.instance.startNsdDiscovery();
      return;
    }

    await _ensureSocket();
    _sendBrowseQuery();
    _browseTimer?.cancel();
    _browseTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_isBrowsing && !_disposed) {
        _sendBrowseQuery();
      }
    });
  }

  Future<void> stopBrowsing() async {
    _isBrowsing = false;
    _browseTimer?.cancel();
    _browseTimer = null;

    if (Platform.isAndroid) {
      await _nsdSub?.cancel();
      _nsdSub = null;
      await PlatformBridge.instance.stopNsdDiscovery();
    }
    if (!_isAdvertising) {
      await _closeSocket();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await stopAdvertising();
    await stopBrowsing();
    await _closeSocket();
  }

  void _handleNsdEvent(NsdDiscoveryEvent ev) {
    if (ev.type == 'lost') {
      onDeviceLost?.call(ev.instanceName);
      return;
    }
    if (ev.instanceName == _instanceName) return;
    final parsedInstance = QsMdns.parseServiceInstanceName(ev.instanceName);
    if (parsedInstance == null) return;

    final info = QsMdns.parseTxtEndpointInfo(ev.txtN);
    final ip = ev.host.isNotEmpty ? ev.host : ev.txtIpv4;
    if (ip.isEmpty || ev.port <= 0) return;

    final endpointIdStr = ascii.decode(parsedInstance.endpointId, allowInvalid: true);
    final name = (info?.deviceName?.isNotEmpty == true)
        ? info!.deviceName!
        : 'Quick Share ($endpointIdStr)';

    onDeviceFound?.call(
      NearbyDevice(
        id: 'qs:$endpointIdStr',
        name: name,
        ip: ip,
        port: ev.port,
        kind: _mapShareType(info?.deviceType ?? ShareTargetType.unknown),
        protocol: TransferProtocol.quickShare,
        isUsb: false,
        endpointId: endpointIdStr,
        lastSeen: DateTime.now(),
      ),
    );
  }

  DeviceKind _mapShareType(ShareTargetType type) {
    return switch (type) {
      ShareTargetType.phone || ShareTargetType.foldable => DeviceKind.phone,
      ShareTargetType.tablet => DeviceKind.tablet,
      ShareTargetType.laptop => DeviceKind.pc,
      _ => DeviceKind.unknown,
    };
  }

  Future<void> _ensureSocket() async {
    if (_socket != null) return;
    try {
      final sock = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _mdnsPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
        ttl: 255,
      );
      sock.multicastHops = 255;
      sock.multicastLoopback = true;
      try {
        sock.joinMulticast(_mdnsMulticast);
      } catch (_) {}
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        for (final intf in interfaces) {
          try {
            sock.joinMulticast(_mdnsMulticast, intf);
          } catch (_) {}
        }
      } catch (_) {}

      _socket = sock;
      _socketSub = sock.listen((event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg;
          while ((dg = sock.receive()) != null) {
            _onDatagram(dg!);
          }
        }
      });
    } catch (_) {
      // Fallback ephemeral socket if port 5353 is exclusively held
      try {
        final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        sock.multicastHops = 255;
        _socket = sock;
        _socketSub = sock.listen((event) {
          if (event == RawSocketEvent.read) {
            Datagram? dg;
            while ((dg = sock.receive()) != null) {
              _onDatagram(dg!);
            }
          }
        });
      } catch (_) {}
    }
  }

  Future<void> _closeSocket() async {
    await _socketSub?.cancel();
    _socketSub = null;
    _socket?.close();
    _socket = null;
  }

  void _sendBrowseQuery() {
    final sock = _socket;
    if (sock == null) return;
    final pkt = _buildPtrQuery('${QsMdns.serviceType}.');
    try {
      sock.send(pkt, _mdnsMulticast, _mdnsPort);
    } catch (_) {}
  }

  void _sendAnnouncement({required int ttl, InternetAddress? unicastDest, int? unicastPort}) {
    final sock = _socket;
    if (sock == null || _instanceName.isEmpty || _listenPort <= 0) return;

    final fqServiceType = '${QsMdns.serviceType}.';
    final fqInstance = '$_instanceName.$fqServiceType';
    final fqHost = _hostTarget.endsWith('.') ? _hostTarget : '$_hostTarget.';

    final txtItems = <String>[
      '${QsMdns.txtKeyEndpointInfo}=$_txtN',
      if (_advertisedIp.isNotEmpty) '${QsMdns.txtKeyIpv4}=$_advertisedIp',
    ];

    final ipv4Bytes = _parseIpv4(_advertisedIp);
    final pkt = _buildResponsePacket(
      fqServiceType: fqServiceType,
      fqInstance: fqInstance,
      fqHost: fqHost,
      port: _listenPort,
      txtItems: txtItems,
      ipv4Bytes: ipv4Bytes,
      ttl: ttl,
    );

    try {
      if (unicastDest != null && unicastPort != null) {
        sock.send(pkt, unicastDest, unicastPort);
      } else {
        sock.send(pkt, _mdnsMulticast, _mdnsPort);
      }
    } catch (_) {}
  }

  void _onDatagram(Datagram dg) {
    try {
      final packet = _parseDnsPacket(dg.data);
      if (packet == null) return;

      // Respond to queries for our service if advertising
      if (!packet.isResponse && _isAdvertising) {
        final fqServiceType = '${QsMdns.serviceType.toLowerCase()}.';
        final fqInstance = '$_instanceName.$fqServiceType'.toLowerCase();
        final fqHost = '${_hostTarget.toLowerCase()}.';

        var shouldReply = false;
        var wantsUnicast = false;
        for (final q in packet.questions) {
          final qn = q.name.toLowerCase();
          if (qn == fqServiceType || qn == fqInstance || qn == fqHost) {
            shouldReply = true;
            if (q.unicastResponse) wantsUnicast = true;
          }
        }
        if (shouldReply) {
          _sendAnnouncement(ttl: 120);
          if (wantsUnicast) {
            _sendAnnouncement(
              ttl: 120,
              unicastDest: dg.address,
              unicastPort: dg.port,
            );
          }
        }
      }

      if (!_isBrowsing) return;
      final records = [...packet.answers, ...packet.additionals];
      if (records.isEmpty) return;

      final fqTypeSuffix = '.${QsMdns.serviceType.toLowerCase()}.';
      final srvs = <String, _DnsSrv>{};
      final txts = <String, Map<String, String>>{};
      final addrs = <String, String>{};

      for (final rr in records) {
        final nameLower = rr.name.toLowerCase();
        if (rr.type == _typeA && rr.rdata.length == 4) {
          final ip = '${rr.rdata[0]}.${rr.rdata[1]}.${rr.rdata[2]}.${rr.rdata[3]}';
          addrs[nameLower] = ip;
        } else if (rr.type == _typeSrv && rr.srv != null) {
          srvs[nameLower] = rr.srv!;
        } else if (rr.type == _typeTxt && rr.txtMap != null) {
          txts[nameLower] = rr.txtMap!;
        }
      }

      for (final entry in srvs.entries) {
        final fqInstanceLower = entry.key;
        if (!fqInstanceLower.endsWith(fqTypeSuffix)) continue;
        final rawInstance = fqInstanceLower.substring(
          0,
          fqInstanceLower.length - fqTypeSuffix.length,
        );
        // Preserve original case if found in records
        final originalRr = records.firstWhere(
          (r) => r.name.toLowerCase() == fqInstanceLower,
        );
        final instanceName = originalRr.name.substring(
          0,
          originalRr.name.length - fqTypeSuffix.length,
        );
        if (instanceName == _instanceName) continue;

        final parsedInst = QsMdns.parseServiceInstanceName(instanceName);
        if (parsedInst == null) continue;

        final txtMap = txts[fqInstanceLower] ?? const {};
        final txtN = txtMap[QsMdns.txtKeyEndpointInfo] ?? '';
        final info = QsMdns.parseTxtEndpointInfo(txtN);
        final srv = entry.value;

        var ip = addrs[srv.target.toLowerCase()] ??
            txtMap[QsMdns.txtKeyIpv4] ??
            dg.address.address;
        if (ip.isEmpty || srv.port <= 0) continue;

        // Skip loopback or self
        if (ip == _advertisedIp && srv.port == _listenPort) continue;

        final endpointIdStr =
            ascii.decode(parsedInst.endpointId, allowInvalid: true);
        final devName = (info?.deviceName?.isNotEmpty == true)
            ? info!.deviceName!
            : 'Quick Share ($endpointIdStr)';

        onDeviceFound?.call(
          NearbyDevice(
            id: 'qs:$endpointIdStr',
            name: devName,
            ip: ip,
            port: srv.port,
            kind: _mapShareType(info?.deviceType ?? ShareTargetType.unknown),
            protocol: TransferProtocol.quickShare,
            isUsb: false,
            endpointId: endpointIdStr,
            lastSeen: DateTime.now(),
          ),
        );
        // keep analyzer clean for rawInstance
        if (rawInstance.isEmpty) continue;
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Pure-Dart RFC 6762 DNS wire encoder / decoder
  // ---------------------------------------------------------------------------

  Uint8List _buildPtrQuery(String fqName) {
    final b = BytesBuilder(copy: false);
    // Header: ID=0, Flags=0 (standard query), QDCOUNT=1, AN=0, NS=0, AR=0
    b.add([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    _writeDnsName(b, fqName);
    _writeUint16(b, _typePtr);
    _writeUint16(b, _classIn); // QM query
    return b.toBytes();
  }

  Uint8List _buildResponsePacket({
    required String fqServiceType,
    required String fqInstance,
    required String fqHost,
    required int port,
    required List<String> txtItems,
    required Uint8List? ipv4Bytes,
    required int ttl,
  }) {
    final b = BytesBuilder(copy: false);
    final answerCount = 3 + (ipv4Bytes != null ? 1 : 0);
    // Header: ID=0, Flags=0x8400 (Response + Authoritative), QD=0, AN=answerCount
    b.add([0, 0, 0x84, 0x00, 0, 0]);
    _writeUint16(b, answerCount);
    b.add([0, 0, 0, 0]);

    // 1. PTR: _FC9F5ED42C8A._tcp.local. -> <instance>._FC9F5ED42C8A._tcp.local.
    final ptrData = BytesBuilder(copy: false);
    _writeDnsName(ptrData, fqInstance);
    _writeResourceRecord(
      b,
      name: fqServiceType,
      type: _typePtr,
      rrClass: _classIn, // PTR records do NOT set cache-flush
      ttl: ttl,
      rdata: ptrData.toBytes(),
    );

    // 2. SRV: <instance> -> <host>.local.:port
    final srvData = BytesBuilder(copy: false);
    _writeUint16(srvData, 0); // priority
    _writeUint16(srvData, 0); // weight
    _writeUint16(srvData, port);
    _writeDnsName(srvData, fqHost);
    _writeResourceRecord(
      b,
      name: fqInstance,
      type: _typeSrv,
      rrClass: _classIn | _cacheFlush,
      ttl: ttl,
      rdata: srvData.toBytes(),
    );

    // 3. TXT: <instance> -> n=... IPv4=...
    final txtData = BytesBuilder(copy: false);
    for (final item in txtItems) {
      final bytes = utf8.encode(item);
      if (bytes.length <= 255) {
        txtData.addByte(bytes.length);
        txtData.add(bytes);
      }
    }
    _writeResourceRecord(
      b,
      name: fqInstance,
      type: _typeTxt,
      rrClass: _classIn | _cacheFlush,
      ttl: ttl,
      rdata: txtData.toBytes(),
    );

    // 4. A: <host>.local. -> ipv4
    if (ipv4Bytes != null) {
      _writeResourceRecord(
        b,
        name: fqHost,
        type: _typeA,
        rrClass: _classIn | _cacheFlush,
        ttl: ttl,
        rdata: ipv4Bytes,
      );
    }

    return b.toBytes();
  }

  void _writeResourceRecord(
    BytesBuilder b, {
    required String name,
    required int type,
    required int rrClass,
    required int ttl,
    required Uint8List rdata,
  }) {
    _writeDnsName(b, name);
    _writeUint16(b, type);
    _writeUint16(b, rrClass);
    _writeUint32(b, ttl);
    _writeUint16(b, rdata.length);
    b.add(rdata);
  }

  void _writeDnsName(BytesBuilder b, String name) {
    final labels = name.split('.').where((l) => l.isNotEmpty);
    for (final label in labels) {
      final bytes = utf8.encode(label);
      b.addByte(bytes.length);
      b.add(bytes);
    }
    b.addByte(0);
  }

  void _writeUint16(BytesBuilder b, int val) {
    b.addByte((val >> 8) & 0xFF);
    b.addByte(val & 0xFF);
  }

  void _writeUint32(BytesBuilder b, int val) {
    b.addByte((val >> 24) & 0xFF);
    b.addByte((val >> 16) & 0xFF);
    b.addByte((val >> 8) & 0xFF);
    b.addByte(val & 0xFF);
  }

  Uint8List? _parseIpv4(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    final out = Uint8List(4);
    for (var i = 0; i < 4; i++) {
      final n = int.tryParse(parts[i]);
      if (n == null || n < 0 || n > 255) return null;
      out[i] = n;
    }
    return out;
  }

  _DnsPacket? _parseDnsPacket(Uint8List data) {
    if (data.length < 12) return null;
    final bd = ByteData.sublistView(data);
    final flags = bd.getUint16(2);
    final isResponse = (flags & 0x8000) != 0;
    final qdCount = bd.getUint16(4);
    final anCount = bd.getUint16(6);
    final nsCount = bd.getUint16(8);
    final arCount = bd.getUint16(10);

    var offset = 12;
    final questions = <_DnsQuestion>[];
    for (var i = 0; i < qdCount; i++) {
      final (name, nextOff) = _readDnsName(data, offset);
      offset = nextOff;
      if (offset + 4 > data.length) return null;
      final qType = bd.getUint16(offset);
      final qClass = bd.getUint16(offset + 2);
      offset += 4;
      questions.add(_DnsQuestion(
        name: name,
        type: qType,
        unicastResponse: (qClass & 0x8000) != 0,
      ));
    }

    final answers = <_DnsRecord>[];
    final additionals = <_DnsRecord>[];

    for (var i = 0; i < anCount; i++) {
      final (rr, nextOff) = _readDnsRecord(data, offset);
      if (rr == null) return null;
      offset = nextOff;
      answers.add(rr);
    }

    for (var i = 0; i < nsCount; i++) {
      final (rr, nextOff) = _readDnsRecord(data, offset);
      if (rr == null) return null;
      offset = nextOff;
    }

    for (var i = 0; i < arCount; i++) {
      final (rr, nextOff) = _readDnsRecord(data, offset);
      if (rr == null) return null;
      offset = nextOff;
      additionals.add(rr);
    }

    return _DnsPacket(
      isResponse: isResponse,
      questions: questions,
      answers: answers,
      additionals: additionals,
    );
  }

  (String, int) _readDnsName(Uint8List data, int startOffset) {
    final labels = <String>[];
    var offset = startOffset;
    var jumped = false;
    var returnOffset = startOffset;
    var guard = 0;

    while (offset < data.length && guard++ < 64) {
      final len = data[offset];
      if (len == 0) {
        if (!jumped) returnOffset = offset + 1;
        break;
      }
      if ((len & 0xC0) == 0xC0) {
        if (offset + 1 >= data.length) break;
        final ptr = ((len & 0x3F) << 8) | data[offset + 1];
        if (!jumped) {
          returnOffset = offset + 2;
          jumped = true;
        }
        offset = ptr;
        continue;
      }
      offset++;
      if (offset + len > data.length) break;
      labels.add(utf8.decode(data.sublist(offset, offset + len), allowMalformed: true));
      offset += len;
      if (!jumped) returnOffset = offset;
    }

    return ('${labels.join('.')}.', returnOffset);
  }

  (_DnsRecord?, int) _readDnsRecord(Uint8List data, int startOffset) {
    if (startOffset >= data.length) return (null, startOffset);
    final (name, off) = _readDnsName(data, startOffset);
    if (off + 10 > data.length) return (null, off);
    final bd = ByteData.sublistView(data);
    final type = bd.getUint16(off);
    final rdLen = bd.getUint16(off + 8);
    final rdataStart = off + 10;
    final rdataEnd = rdataStart + rdLen;
    if (rdataEnd > data.length) return (null, data.length);
    final rdata = data.sublist(rdataStart, rdataEnd);

    _DnsSrv? srv;
    Map<String, String>? txtMap;

    if (type == _typeSrv && rdLen >= 6) {
      final port = bd.getUint16(rdataStart + 4);
      final (target, _) = _readDnsName(data, rdataStart + 6);
      srv = _DnsSrv(port: port, target: target);
    } else if (type == _typeTxt) {
      txtMap = <String, String>{};
      var i = 0;
      while (i < rdata.length) {
        final itemLen = rdata[i++];
        if (i + itemLen > rdata.length) break;
        final str = utf8.decode(rdata.sublist(i, i + itemLen), allowMalformed: true);
        i += itemLen;
        final eq = str.indexOf('=');
        if (eq > 0) {
          txtMap[str.substring(0, eq)] = str.substring(eq + 1);
        }
      }
    }

    return (
      _DnsRecord(
        name: name,
        type: type,
        rdata: rdata,
        srv: srv,
        txtMap: txtMap,
      ),
      rdataEnd,
    );
  }
}

class _DnsPacket {
  final bool isResponse;
  final List<_DnsQuestion> questions;
  final List<_DnsRecord> answers;
  final List<_DnsRecord> additionals;

  _DnsPacket({
    required this.isResponse,
    required this.questions,
    required this.answers,
    required this.additionals,
  });
}

class _DnsQuestion {
  final String name;
  final int type;
  final bool unicastResponse;

  _DnsQuestion({
    required this.name,
    required this.type,
    required this.unicastResponse,
  });
}

class _DnsSrv {
  final int port;
  final String target;
  _DnsSrv({required this.port, required this.target});
}

class _DnsRecord {
  final String name;
  final int type;
  final Uint8List rdata;
  final _DnsSrv? srv;
  final Map<String, String>? txtMap;

  _DnsRecord({
    required this.name,
    required this.type,
    required this.rdata,
    this.srv,
    this.txtMap,
  });
}
