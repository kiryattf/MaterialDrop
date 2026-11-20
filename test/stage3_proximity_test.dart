import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_drop/models/models.dart';
import 'package:material_drop/protocol/engine/transport_models.dart';
import 'package:material_drop/protocol/lan/lan_receiver.dart';
import 'package:material_drop/protocol/lan/tls_identity.dart';
import 'package:material_drop/protocol/proximity/proximity_bridge.dart';
import 'package:material_drop/protocol/proximity/tap_proximity_transport.dart';
import 'package:material_drop/protocol/quickshare/qs_crypto.dart';
import 'package:path/path.dart' as p;

void main() {
  test('RssiEmaFilter smooths noisy readings and orders radar proximity orbits', () {
    final filter = RssiEmaFilter(alpha: 0.35);
    expect(filter.update('peer1', -50), -50);
    final next = filter.update('peer1', -80);
    expect(next, greaterThan(-65));
    expect(next, lessThan(-55));

    expect(RssiEmaFilter.classifyZone(-52), 'immediate');
    expect(RssiEmaFilter.classifyZone(-68), 'near');
    expect(RssiEmaFilter.classifyZone(-84), 'far');

    expect(
      RssiEmaFilter.orbitFactorForZone('immediate'),
      lessThan(RssiEmaFilter.orbitFactorForZone('near')),
    );
    expect(
      RssiEmaFilter.orbitFactorForZone('near'),
      lessThan(RssiEmaFilter.orbitFactorForZone('far')),
    );
  });

  test('Proximity ECDH session key derivation matches across both peers and validates curves', () {
    final alice = QsCrypto.generateKeyPair();
    final bob = QsCrypto.generateKeyPair();

    final alicePubB64 = base64Encode(alice.publicKey.Q!.getEncoded(false));
    final bobPubB64 = base64Encode(bob.publicKey.Q!.getEncoded(false));

    final keyAlice = ProximityBridge.deriveEcdhSessionKey(alice.privateKey, bobPubB64);
    final keyBob = ProximityBridge.deriveEcdhSessionKey(bob.privateKey, alicePubB64);

    expect(keyAlice.length, 32);
    expect(keyAlice, keyBob);

    expect(
      () => ProximityBridge.deriveEcdhSessionKey(alice.privateKey, base64Encode([0, 1, 2, 3])),
      throwsArgumentError,
    );

    final handshake = ProximityHandshakeEvent.fromMap('nfc_reader', {
      'n': 'Pixel-9',
      'e': '00112233445566778899AABBCCDDEEFF',
      'k': bobPubB64,
      'p': 53317,
      'f': 'AA' * 32,
      's': 'DIRECT-MD-1234',
      'w': 'secretpass',
      'i': '192.168.49.1',
    });
    expect(handshake.name, 'Pixel-9');
    expect(handshake.hasDirectWifiCredentials, isTrue);
    expect(handshake.wifiSsid, 'DIRECT-MD-1234');
  });

  test('TapProximityTransport handles NFC/BLE handshake and completes HTTPS transfer cleanly', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final savedOverrides = HttpOverrides.current;
    HttpOverrides.global = null;

    final tempRoot = await Directory.systemTemp.createTemp('md_tap_');
    final recvDir = Directory(p.join(tempRoot.path, 'recv'));
    await recvDir.create();
    final srcFile = File(p.join(tempRoot.path, 'tap_photo.bin'));
    final srcBytes = List<int>.generate(64 * 1024, (i) => (i * 17) & 0xFF);
    await srcFile.writeAsBytes(srcBytes, flush: true);

    final receiverId = TlsIdentity.generate(commonName: 'Receiver-Phone');
    final senderId = TlsIdentity.generate(commonName: 'Sender-Phone');
    final completed = <IncomingTransferItem>[];
    final recvDone = Completer<void>();

    final receiver = LanReceiver(
      deviceName: 'Receiver-Phone',
      downloadDir: recvDir.path,
      identity: receiverId,
      isTrustedFn: (_, _) => false,
      autoAcceptAllFn: () => true,
      autoAcceptTrustedFn: () => true,
      onOffer: (_) {},
      onProgress: (_, _, _, _, _) {},
      onCompleted: (_, items) {
        completed.addAll(items);
        if (!recvDone.isCompleted) recvDone.complete();
      },
      onCanceled: () {},
      onError: (e) {
        if (!recvDone.isCompleted) recvDone.completeError(StateError(e));
      },
    );
    await receiver.start(bindAddress: '127.0.0.1', explicitPort: 0, useHttps: true);

    final peerKp = QsCrypto.generateKeyPair();
    final peerPubB64 = base64Encode(peerKp.publicKey.Q!.getEncoded(false));

    final transport = TapProximityTransport(
      transferPortFn: () => 53317,
      localFingerprintFn: () => senderId.fingerprint,
      deviceNameFn: () => 'Sender-Phone',
    );

    try {
      await transport.start();
      final devicesFuture = transport.devicesStream
          .firstWhere((list) => list.any((d) => d.ip == '127.0.0.1'))
          .timeout(const Duration(seconds: 3));

      const channel = MethodChannel('dev.materialdrop.flutter/proximity');
      const codec = StandardMethodCodec();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(
          const MethodCall('onProximityEvent', {
            'type': 'blePeerFound',
            'bleAddress': '11:22:33:44:55:66',
            'ephemeralId': 'FFEEDDCCBBAA99887766554433221100',
            'name': 'Receiver-Phone',
            'port': 53317,
            'capabilities': 7,
            'rssi': -44,
            'proximityZone': 'immediate',
          }),
        ),
        (_) {},
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(
          MethodCall('onProximityEvent', {
            'type': 'handshake',
            'source': 'nfc_reader',
            'peer': {
              'name': 'Receiver-Phone',
              'ephemeralId': 'FFEEDDCCBBAA99887766554433221100',
              'ecPubB64': peerPubB64,
              'port': receiver.port,
              'fingerprint': receiverId.fingerprint,
              'wifiSsid': 'DIRECT-TEST-AP',
              'wifiPass': 'pass1234',
              'wifiIp': '127.0.0.1',
            },
          }),
        ),
        (_) {},
      );

      final devices = await devicesFuture;
      final target = devices.firstWhere((d) => d.ip == '127.0.0.1');
      expect(target.proximityZone, 'immediate');
      expect(target.protocol, TransferProtocol.tapProximity);

      final outCompleted = Completer<void>();
      final sub = transport.eventsStream.listen((ev) {
        if (ev is TransportOutgoingCompleted && !outCompleted.isCompleted) {
          outCompleted.complete();
        }
      });

      await transport.sendOffer(
        target,
        [
          StagedFile(
            name: 'tap_photo.bin',
            size: srcBytes.length,
            mimeType: 'application/octet-stream',
            path: srcFile.path,
          ),
        ],
        localDeviceName: 'Sender-Phone',
      );

      await Future.wait([
        recvDone.future.timeout(const Duration(seconds: 5)),
        outCompleted.future.timeout(const Duration(seconds: 5)),
      ]);
      await sub.cancel();

      expect(completed.length, 1);
      final saved = File(completed.single.savedPathOrUri);
      expect(
        sha256.convert(await saved.readAsBytes()).toString(),
        sha256.convert(srcBytes).toString(),
      );
    } finally {
      await transport.dispose();
      await receiver.stop();
      await tempRoot.delete(recursive: true);
      HttpOverrides.global = savedOverrides;
    }
  });
}
