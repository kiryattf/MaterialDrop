import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'proto_codec.dart';
import 'qs_crypto.dart';

class Ukey2Exception implements Exception {
  final String message;
  Ukey2Exception(this.message);
  @override
  String toString() => 'Ukey2Exception: $message';
}

class Ukey2HandshakeResult {
  final D2DKeys keys;
  Ukey2HandshakeResult(this.keys);
}

class QsUkey2 {
  static const String _nextProtocol = 'AES_256_CBC-HMAC_SHA256';

  static ECPublicKey _parseP256PublicKey(GenericPublicKey generic) {
    if (generic.type != GenericPublicKey.typeEcP256 ||
        generic.ecP256PublicKey == null) {
      throw Ukey2Exception('Peer public key is not EC_P256');
    }
    final ecKey = generic.ecP256PublicKey!;
    final x = QsCrypto.decodePointUnsigned(ecKey.x, 32);
    final y = QsCrypto.decodePointUnsigned(ecKey.y, 32);
    return QsCrypto.publicKeyFromXY(x, y);
  }

  static Uint8List _encodeP256PublicKey(ECPublicKey pub) {
    final (x, y) = QsCrypto.publicKeyXY(pub);
    return GenericPublicKey(
      type: GenericPublicKey.typeEcP256,
      ecP256PublicKey: EcP256PublicKey(
        x: QsCrypto.encodePointSigned(x),
        y: QsCrypto.encodePointSigned(y),
      ),
    ).toBytes();
  }

  static Ukey2ClientInit parseClientInit(Uint8List rawMessageBytes) {
    final msg = Ukey2Message.parse(rawMessageBytes);
    if (msg.messageType != Ukey2MessageType.clientInit) {
      throw Ukey2Exception('Expected CLIENT_INIT, got ${msg.messageType}');
    }
    final ci = Ukey2ClientInit.parse(msg.messageData);
    if (ci.version != 1) {
      throw Ukey2Exception('Unsupported ClientInit version ${ci.version}');
    }
    if (ci.random.length != 32) {
      throw Ukey2Exception('ClientInit random must be 32 bytes');
    }
    if (ci.nextProtocol != _nextProtocol) {
      throw Ukey2Exception('Unsupported next_protocol ${ci.nextProtocol}');
    }
    final hasP256 = ci.cipherCommitments.any(
      (c) => c.handshakeCipher == Ukey2HandshakeCipher.p256Sha512,
    );
    if (!hasP256) {
      throw Ukey2Exception('ClientInit missing P256_SHA512 commitment');
    }
    return ci;
  }

  static Uint8List findP256Commitment(Ukey2ClientInit ci) {
    for (final c in ci.cipherCommitments) {
      if (c.handshakeCipher == Ukey2HandshakeCipher.p256Sha512) {
        return c.commitment;
      }
    }
    throw Ukey2Exception('No P256_SHA512 commitment found');
  }

  static Uint8List buildServerInit(ECPublicKey serverPublicKey) {
    final serverInit = Ukey2ServerInit(
      version: 1,
      random: QsCrypto.randomBytes(32),
      handshakeCipher: Ukey2HandshakeCipher.p256Sha512,
      publicKey: _encodeP256PublicKey(serverPublicKey),
    );
    return Ukey2Message(
      messageType: Ukey2MessageType.serverInit,
      messageData: serverInit.toBytes(),
    ).toBytes();
  }

  static ECPublicKey verifyClientFinished(
    Uint8List rawMessageBytes,
    Uint8List expectedCommitment,
  ) {
    final digest = QsCrypto.sha512Bytes(rawMessageBytes);
    if (digest.length != expectedCommitment.length) {
      throw Ukey2Exception('Commitment length mismatch');
    }
    for (var i = 0; i < digest.length; i++) {
      if (digest[i] != expectedCommitment[i]) {
        throw Ukey2Exception(
            'Cipher commitment mismatch: sha512(ClientFinished) != commitment');
      }
    }
    final msg = Ukey2Message.parse(rawMessageBytes);
    if (msg.messageType != Ukey2MessageType.clientFinish) {
      throw Ukey2Exception('Expected CLIENT_FINISH, got ${msg.messageType}');
    }
    final cf = Ukey2ClientFinished.parse(msg.messageData);
    final generic = GenericPublicKey.parse(cf.publicKey);
    return _parseP256PublicKey(generic);
  }

  static Future<Ukey2HandshakeResult> runServerHandshake({
    required Uint8List clientInitBytes,
    required Future<void> Function(Uint8List serverInitBytes) sendServerInit,
    required Future<Uint8List> Function() recvClientFinished,
  }) async {
    final clientInit = parseClientInit(clientInitBytes);
    final commitment = findP256Commitment(clientInit);

    final kp = QsCrypto.generateKeyPair();
    final serverInitBytes = buildServerInit(kp.publicKey);
    await sendServerInit(serverInitBytes);

    final clientFinishedBytes = await recvClientFinished();
    final clientPub = verifyClientFinished(clientFinishedBytes, commitment);

    final shared = QsCrypto.ecdhSharedSecret(kp.privateKey, clientPub);
    final keys = QsCrypto.deriveD2DKeys(
      sharedSecret: shared,
      clientInitBytes: clientInitBytes,
      serverInitBytes: serverInitBytes,
      isServer: true,
    );
    return Ukey2HandshakeResult(keys);
  }

  static Uint8List buildClientFinished(ECPublicKey clientPublicKey) {
    final cf = Ukey2ClientFinished(
      publicKey: _encodeP256PublicKey(clientPublicKey),
    );
    return Ukey2Message(
      messageType: Ukey2MessageType.clientFinish,
      messageData: cf.toBytes(),
    ).toBytes();
  }

  static Uint8List buildClientInit(Uint8List clientFinishedBytes) {
    final commitment = Ukey2CipherCommitment(
      handshakeCipher: Ukey2HandshakeCipher.p256Sha512,
      commitment: QsCrypto.sha512Bytes(clientFinishedBytes),
    );
    final ci = Ukey2ClientInit(
      version: 1,
      random: QsCrypto.randomBytes(32),
      cipherCommitments: [commitment],
      nextProtocol: _nextProtocol,
    );
    return Ukey2Message(
      messageType: Ukey2MessageType.clientInit,
      messageData: ci.toBytes(),
    ).toBytes();
  }

  static ECPublicKey parseServerInit(Uint8List rawMessageBytes) {
    final msg = Ukey2Message.parse(rawMessageBytes);
    if (msg.messageType != Ukey2MessageType.serverInit) {
      throw Ukey2Exception('Expected SERVER_INIT, got ${msg.messageType}');
    }
    final si = Ukey2ServerInit.parse(msg.messageData);
    if (si.version != 1) {
      throw Ukey2Exception('Unsupported ServerInit version ${si.version}');
    }
    if (si.random.length != 32) {
      throw Ukey2Exception('ServerInit random must be 32 bytes');
    }
    if (si.handshakeCipher != Ukey2HandshakeCipher.p256Sha512) {
      throw Ukey2Exception('ServerInit cipher is not P256_SHA512');
    }
    final generic = GenericPublicKey.parse(si.publicKey);
    return _parseP256PublicKey(generic);
  }

  static Future<Ukey2HandshakeResult> runClientHandshake({
    required Future<void> Function(Uint8List clientInitBytes) sendClientInit,
    required Future<Uint8List> Function() recvServerInit,
    required Future<void> Function(Uint8List clientFinishedBytes)
        sendClientFinished,
  }) async {
    final kp = QsCrypto.generateKeyPair();
    final clientFinishedBytes = buildClientFinished(kp.publicKey);
    final clientInitBytes = buildClientInit(clientFinishedBytes);
    await sendClientInit(clientInitBytes);

    final serverInitBytes = await recvServerInit();
    final serverPub = parseServerInit(serverInitBytes);

    await sendClientFinished(clientFinishedBytes);

    final shared = QsCrypto.ecdhSharedSecret(kp.privateKey, serverPub);
    final keys = QsCrypto.deriveD2DKeys(
      sharedSecret: shared,
      clientInitBytes: clientInitBytes,
      serverInitBytes: serverInitBytes,
      isServer: false,
    );
    return Ukey2HandshakeResult(keys);
  }
}

