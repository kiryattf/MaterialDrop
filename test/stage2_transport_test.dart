import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_drop/l10n/app_strings.dart';
import 'package:material_drop/models/models.dart';
import 'package:material_drop/protocol/engine/transport_channel.dart';
import 'package:material_drop/protocol/engine/transport_models.dart';
import 'package:material_drop/protocol/engine/transport_router.dart';
import 'package:material_drop/protocol/lan/lan_constants.dart';
import 'package:material_drop/protocol/lan/lan_receiver.dart';
import 'package:material_drop/protocol/lan/lan_sender.dart';
import 'package:material_drop/protocol/lan/tls_identity.dart';
import 'package:path/path.dart' as p;

class _FakeTransportChannel implements TransportChannel {
  @override
  final String id;
  @override
  final TransportKind kind;
  @override
  final int priority;
  @override
  bool get isAvailable => true;
  @override
  int boundPort = 0;

  final bool failConnection;
  int sendAttempts = 0;

  final StreamController<List<NearbyDevice>> _devicesCtrl =
      StreamController<List<NearbyDevice>>.broadcast();
  final StreamController<TransportEvent> _eventsCtrl =
      StreamController<TransportEvent>.broadcast();

  _FakeTransportChannel({
    required this.id,
    required this.kind,
    required this.priority,
    this.failConnection = false,
  });

  void emitDevices(List<NearbyDevice> devices) => _devicesCtrl.add(devices);

  @override
  Stream<List<NearbyDevice>> get devicesStream => _devicesCtrl.stream;

  @override
  Stream<TransportEvent> get eventsStream => _eventsCtrl.stream;

  @override
  Future<void> start({int? explicitPort, String? bindAddress}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> startDiscovery() async {}

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<void> refreshDiscovery() async {}

  @override
  Future<void> sendOffer(
    NearbyDevice device,
    List<StagedFile> files, {
    required String localDeviceName,
  }) async {
    sendAttempts++;
    if (failConnection) {
      throw const SocketException('Simulated primary channel unreachable');
    }
    _eventsCtrl.add(
      TransportOutgoingCompleted(
        id,
        device.name,
        files.first.name,
        files.length,
        device.protocol,
        files,
      ),
    );
  }

  @override
  Future<void> acceptOffer(String offerId) async {}

  @override
  Future<void> declineOffer(String offerId) async {}

  @override
  Future<void> cancelTransfer({String? offerId}) async {}

  @override
  Future<void> updateConfig({String? deviceName, String? downloadDir}) async {}

  @override
  Future<void> dispose() async {
    await _devicesCtrl.close();
    await _eventsCtrl.close();
  }
}

void main() {
  test('TlsIdentity generates valid X.509 cert and badCertificateCallback validates fingerprint', () async {
    final identity = TlsIdentity.generate(commonName: 'MaterialDrop-TLS-Test');
    expect(identity.fingerprint.length, 64);
    expect(
      identity.fingerprint,
      TlsIdentity.bytesToUpperHex(sha256.convert(identity.certificateDerBytes).bytes),
    );

    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      identity.createSecurityContext(),
    );
    server.listen((req) async {
      req.response.statusCode = HttpStatus.ok;
      req.response.write('tls_ok');
      await req.response.close();
    });

    try {
      // Matching fingerprint succeeds
      final validClient = TlsIdentity.createPinnedClient(
        expectedFingerprint: identity.fingerprint.toLowerCase(),
      );
      try {
        final req = await validClient.getUrl(
          Uri.parse('https://127.0.0.1:${server.port}/check'),
        );
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.ok);
        expect(await utf8.decodeStream(resp), 'tls_ok');
      } finally {
        validClient.close(force: true);
      }

      // Mismatched fingerprint is rejected by badCertificateCallback
      final badClient = TlsIdentity.createPinnedClient(
        expectedFingerprint: '0' * 64,
      );
      try {
        await expectLater(
          () async {
            final req = await badClient.getUrl(
              Uri.parse('https://127.0.0.1:${server.port}/check'),
            );
            await req.close();
          }(),
          throwsA(isA<HandshakeException>()),
        );
      } finally {
        badClient.close(force: true);
      }

      // Missing fingerprint with trustOnFirstProbe=false is rejected
      final unpinnedClient = TlsIdentity.createPinnedClient(
        expectedFingerprint: null,
        trustOnFirstProbe: false,
      );
      try {
        await expectLater(
          () async {
            final req = await unpinnedClient.getUrl(
              Uri.parse('https://127.0.0.1:${server.port}/check'),
            );
            await req.close();
          }(),
          throwsA(isA<HandshakeException>()),
        );
      } finally {
        unpinnedClient.close(force: true);
      }
    } finally {
      await server.close(force: true);
    }
  });

  test('LanReceiver <-> LanSender full HTTPS batch transfer with fingerprint pinning & relativePath', () async {
    final tempRoot = await Directory.systemTemp.createTemp('md_lan_https_');
    final recvDir = Directory(p.join(tempRoot.path, 'recv'));
    await recvDir.create();

    final fBin = File(p.join(tempRoot.path, 'payload.bin'));
    final fNested = File(p.join(tempRoot.path, 'note.txt'));
    final binBytes = List<int>.generate(220 * 1024, (i) => (i * 31) & 0xFF);
    final noteBytes = utf8.encode('HTTPS TLS fingerprint verified nested folder file');
    await fBin.writeAsBytes(binBytes, flush: true);
    await fNested.writeAsBytes(noteBytes, flush: true);

    final receiverIdentity = TlsIdentity.generate(commonName: 'Receiver-LAN');
    final senderIdentity = TlsIdentity.generate(commonName: 'Sender-LAN');

    var acceptIncoming = false;
    final completedItems = <IncomingTransferItem>[];
    Completer<void>? doneCompleter;

    late LanReceiver receiver;
    receiver = LanReceiver(
      deviceName: 'Receiver-LAN',
      downloadDir: recvDir.path,
      identity: receiverIdentity,
      isTrustedFn: (_, _) => false,
      autoAcceptAllFn: () => false,
      autoAcceptTrustedFn: () => false,
      onOffer: (_) {
        Future<void>.delayed(const Duration(milliseconds: 15), () {
          receiver.setDecision(acceptIncoming);
        });
      },
      onProgress: (_, _, _, _, _) {},
      onCompleted: (_, items) {
        completedItems.addAll(items);
        final c = doneCompleter;
        if (c != null && !c.isCompleted) {
          c.complete();
        }
      },
      onCanceled: () {},
      onError: (err) {
        final c = doneCompleter;
        if (c != null && !c.isCompleted) {
          c.completeError(StateError(err));
        }
      },
    );

    await receiver.start(bindAddress: '127.0.0.1', explicitPort: 0, useHttps: true);

    try {
      // 1. Verify /info exposes expected fingerprint over HTTPS
      final infoClient = TlsIdentity.createPinnedClient(
        expectedFingerprint: receiverIdentity.fingerprint,
      );
      try {
        final req = await infoClient.getUrl(
          Uri.parse('https://127.0.0.1:${receiver.port}${LanConstants.pathInfo}'),
        );
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.ok);
        final info = jsonDecode(await utf8.decodeStream(resp)) as Map<String, dynamic>;
        expect(info['alias'], 'Receiver-LAN');
        expect(info['fingerprint'], receiverIdentity.fingerprint);
        expect(info['protocol'], 'https');
      } finally {
        infoClient.close(force: true);
      }

      // 2. Verify decline returns 403 / LanSendException(userDeclined: true)
      final sender = LanSender();
      final target = NearbyDevice(
        id: 'lan:${receiverIdentity.fingerprint}',
        name: 'Receiver-LAN',
        ip: '127.0.0.1',
        port: receiver.port,
        kind: DeviceKind.pc,
        protocol: TransferProtocol.lan,
        isUsb: false,
        channelId: 'lan',
        tlsFingerprint: receiverIdentity.fingerprint,
        useHttps: true,
        lastSeen: DateTime.now(),
      );

      acceptIncoming = false;
      await expectLater(
        sender.sendBatch(
          device: target,
          localDeviceName: 'Sender-LAN',
          localPort: 53317,
          localFingerprint: senderIdentity.fingerprint,
          localUseHttps: true,
          files: [
            StagedFile(
              name: 'note.txt',
              size: noteBytes.length,
              mimeType: 'text/plain',
              path: fNested.path,
            ),
          ],
          onProgress: (_, _, _, _) {},
        ),
        throwsA(isA<LanSendException>().having((e) => e.userDeclined, 'userDeclined', isTrue)),
      );

      // 3. Verify accepted batch upload over HTTPS preserves SHA-256 and nested path
      acceptIncoming = true;
      doneCompleter = Completer<void>();
      var progressCalls = 0;

      await sender.sendBatch(
        device: target,
        localDeviceName: 'Sender-LAN',
        localPort: 53317,
        localFingerprint: senderIdentity.fingerprint,
        localUseHttps: true,
        files: [
          StagedFile(
            name: 'payload.bin',
            size: binBytes.length,
            mimeType: 'application/octet-stream',
            path: fBin.path,
          ),
          StagedFile(
            name: 'note.txt',
            size: noteBytes.length,
            mimeType: 'text/plain',
            path: fNested.path,
            relativePath: 'Docs/Sub/note.txt',
          ),
        ],
        onProgress: (_, _, _, _) => progressCalls++,
      );

      await doneCompleter.future.timeout(const Duration(seconds: 5));
      expect(progressCalls, greaterThan(0));
      expect(completedItems.length, 2);

      final savedBin = File(completedItems[0].savedPathOrUri);
      expect(
        sha256.convert(await savedBin.readAsBytes()).toString(),
        sha256.convert(binBytes).toString(),
      );

      final expectedNested = File(p.join(recvDir.path, 'Docs', 'Sub', 'note.txt'));
      expect(expectedNested.existsSync(), isTrue);
      expect(await expectedNested.readAsBytes(), noteBytes);
    } finally {
      await receiver.stop();
      await tempRoot.delete(recursive: true);
    }
  });

  test('TransportRouter unifies endpoints into DiscoveredPeer and falls back across channels', () async {
    final primary = _FakeTransportChannel(
      id: 'direct',
      kind: TransportKind.direct,
      priority: 10,
      failConnection: true,
    );
    final secondary = _FakeTransportChannel(
      id: 'lan',
      kind: TransportKind.lan,
      priority: 20,
      failConnection: false,
    );

    final router = TransportRouter(
      channels: [secondary, primary], // intentionally out of order
      isSelfFn: (_) => false,
      isTrustedFn: (_) => false,
    );

    try {
      final now = DateTime.now();
      primary.emitDevices([
        NearbyDevice(
          id: 'md:192.168.1.44:45874',
          name: 'Pixel-Test',
          ip: '192.168.1.44',
          port: 45874,
          kind: DeviceKind.phone,
          protocol: TransferProtocol.materialDrop,
          isUsb: false,
          channelId: 'direct',
          lastSeen: now,
        ),
      ]);
      secondary.emitDevices([
        NearbyDevice(
          id: 'lan:AABBCC',
          name: 'Pixel-Test',
          ip: '192.168.1.44',
          port: 53317,
          kind: DeviceKind.phone,
          protocol: TransferProtocol.lan,
          isUsb: false,
          channelId: 'lan',
          tlsFingerprint: 'AABBCC',
          useHttps: true,
          lastSeen: now,
        ),
      ]);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(router.currentPeers.length, 1);
      final peer = router.currentPeers.single;
      expect(peer.endpoints.length, 2);
      expect(peer.primaryEndpoint.channelId, 'direct');

      final completedEvents = <TransportOutgoingCompleted>[];
      final sub = router.eventsStream.listen((e) {
        if (e is TransportOutgoingCompleted) completedEvents.add(e);
      });

      final targetDevice = peer.toNearbyDevice();
      await router.sendFiles(
        targetDevice,
        const [
          StagedFile(
            name: 'photo.jpg',
            size: 123,
            mimeType: 'image/jpeg',
          ),
        ],
        localDeviceName: 'Host-PC',
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();

      expect(primary.sendAttempts, 1);
      expect(secondary.sendAttempts, 1);
      expect(completedEvents.length, 1);
      expect(completedEvents.single.channelId, 'lan');
    } finally {
      await router.dispose();
    }
  });

  test('UI localization strings do not expose third-party protocol branding', () {
    for (final lang in AppStrings.supportedLanguages.keys) {
      final s = AppStrings(lang);
      expect(s.tr('protocol_direct').toLowerCase().contains('localsend'), isFalse);
      expect(s.tr('send_subtitle').toLowerCase().contains('localsend'), isFalse);
      expect(s.tr('settings_about_desc').toLowerCase().contains('localsend'), isFalse);
    }
  });
}
