import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_drop/protocol/quickshare/proto_codec.dart';
import 'package:material_drop/protocol/quickshare/qs_crypto.dart';
import 'package:material_drop/protocol/quickshare/qs_mdns.dart';
import 'package:material_drop/protocol/quickshare/qs_secure_channel.dart';
import 'package:material_drop/protocol/quickshare/qs_ukey2.dart';

void main() {
  group('QsCrypto & UKEY2', () {
    test('P-256 coordinate two-s complement signed encoding round-trip', () {
      final highBitSet = Uint8List(32)..[0] = 0x80..[31] = 0x05;
      final encoded = QsCrypto.encodePointSigned(highBitSet);
      expect(encoded.length, 33);
      expect(encoded[0], 0x00);
      expect(QsCrypto.decodePointUnsigned(encoded, 32), highBitSet);

      final leadingZeros = Uint8List(32)..[1] = 0x12..[31] = 0xFE;
      final enc2 = QsCrypto.encodePointSigned(leadingZeros);
      expect(enc2[0], 0x00);
      expect(enc2.length, 32); // 0x00 + 31 minimal bytes
      expect(QsCrypto.decodePointUnsigned(enc2, 32), leadingZeros);
    });

    test('toFourDigitPin matches Python quickshare/crypto.py identically', () {
      final vec1 = Uint8List.fromList(
        List.generate(32, (i) => (i * 17 + 130) & 0xFF),
      );
      expect(QsCrypto.toFourDigitPin(vec1), '6138');

      final vec2 = Uint8List.fromList([0xFF, 0x80, 0x01, 0xFE, 0x7F, 0xAA, 0x55]);
      expect(QsCrypto.toFourDigitPin(vec2), '5663');
    });

    test('Full UKEY2 Client <-> Server handshake produces matching keys and PIN', () async {
      final clientInitC = Completer<Uint8List>();
      final serverInitC = Completer<Uint8List>();
      final clientFinC = Completer<Uint8List>();

      final clientFuture = QsUkey2.runClientHandshake(
        sendClientInit: (ci) async => clientInitC.complete(ci),
        recvServerInit: () => serverInitC.future,
        sendClientFinished: (cf) async => clientFinC.complete(cf),
      );

      final clientInitBytes = await clientInitC.future;
      final serverResult = await QsUkey2.runServerHandshake(
        clientInitBytes: clientInitBytes,
        sendServerInit: (si) async => serverInitC.complete(si),
        recvClientFinished: () => clientFinC.future,
      );

      final clientResult = await clientFuture;

      expect(clientResult.keys.pin, serverResult.keys.pin);
      expect(clientResult.keys.encryptKey, serverResult.keys.decryptKey);
      expect(clientResult.keys.decryptKey, serverResult.keys.encryptKey);
      expect(clientResult.keys.sendHmacKey, serverResult.keys.recvHmacKey);
      expect(clientResult.keys.recvHmacKey, serverResult.keys.sendHmacKey);

      final clientCh = QsSecureChannel.fromKeys(clientResult.keys);
      final serverCh = QsSecureChannel.fromKeys(serverResult.keys);

      final msg = Uint8List.fromList(utf8.encode('Hello Quick Share!'));
      final encrypted = clientCh.encrypt(msg);
      final decrypted = serverCh.decrypt(encrypted);
      expect(decrypted, msg);

      // Tampering with ciphertext must fail HMAC verification
      final tampered = Uint8List.fromList(encrypted);
      tampered[tampered.length - 1] ^= 0xFF;
      expect(
        () => serverCh.decrypt(tampered),
        throwsA(isA<SecureChannelException>()),
      );
    });
  });

  group('QsMdns & Protobuf codecs', () {
    test('mDNS service instance name and endpointInfo match Python quickshare/mdns.py', () {
      expect(QsMdns.serviceType, '_FC9F5ED42C8A._tcp.local');

      // Exact wire match with Python build_service_instance_name(b"ABCD")
      final abcdInst = QsMdns.buildServiceInstanceName(
        Uint8List.fromList(ascii.encode('ABCD')),
      );
      expect(abcdInst, 'I0FCQ0T8n14AAA');

      final eid = QsMdns.stableEndpointId('TEST-PC');
      expect(eid.length, 4);
      final instName = QsMdns.buildServiceInstanceName(eid);
      expect(instName.contains('='), isFalse);
      expect(instName.length, 14);

      final parsedInst = QsMdns.parseServiceInstanceName(instName);
      expect(parsedInst, isNotNull);
      expect(parsedInst!.endpointId, eid);
      expect(parsedInst.serviceIdHash, QsMdns.instanceServiceIdHash);

      final txtVal = QsMdns.buildEndpointInfoTxtValue(
        'Кирилл Galaxy',
        ShareTargetType.phone,
      );
      expect(txtVal.contains('='), isFalse);
      final adv = QsMdns.parseTxtEndpointInfo(txtVal);
      expect(adv, isNotNull);
      expect(adv!.deviceName, 'Кирилл Galaxy');
      expect(adv.deviceType, ShareTargetType.phone);
    });

    test('OfflineFrame 64-bit signed payload_id & IntroductionFrame round-trip', () {
      const negativeId = -7123456789012345678;
      final frame = OfflineFrame(
        version: OfflineFrame.versionV1,
        v1: OfflineV1Frame(
          type: OfflineFrameType.payloadTransfer,
          payloadTransfer: PayloadTransferFrame(
            packetType: PayloadTransferFrame.packetData,
            payloadHeader: PayloadHeader(
              id: negativeId,
              type: PayloadHeader.typeFile,
              totalSize: 0,
              fileName: 'empty.bin',
            ),
            payloadChunk: PayloadChunk(
              flags: PayloadChunk.flagLastChunk,
              offset: 0,
              body: Uint8List(0),
            ),
          ),
        ),
      );

      final parsed = OfflineFrame.parse(frame.toBytes());
      final pt = parsed.v1!.payloadTransfer!;
      expect(pt.payloadHeader!.id, negativeId);
      expect(pt.payloadHeader!.totalSize, 0);
      expect(pt.payloadHeader!.fileName, 'empty.bin');
      expect(pt.payloadChunk!.flags, PayloadChunk.flagLastChunk);
    });
  });
}

