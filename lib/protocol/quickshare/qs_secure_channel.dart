import 'dart:typed_data';

import 'proto_codec.dart';
import 'qs_crypto.dart';

class SecureChannelException implements Exception {
  final String message;
  SecureChannelException(this.message);
  @override
  String toString() => 'SecureChannelException: $message';
}

class QsSecureChannel {
  final Uint8List encryptKey;
  final Uint8List decryptKey;
  final Uint8List sendHmacKey;
  final Uint8List recvHmacKey;
  int _sendSeq = 0;

  QsSecureChannel({
    required this.encryptKey,
    required this.decryptKey,
    required this.sendHmacKey,
    required this.recvHmacKey,
  });

  factory QsSecureChannel.fromKeys(D2DKeys keys) {
    return QsSecureChannel(
      encryptKey: keys.encryptKey,
      decryptKey: keys.decryptKey,
      sendHmacKey: keys.sendHmacKey,
      recvHmacKey: keys.recvHmacKey,
    );
  }

  Uint8List encrypt(Uint8List frameBytes) {
    _sendSeq += 1;
    final d2dMsg = DeviceToDeviceMessage(
      message: frameBytes,
      sequenceNumber: _sendSeq,
    ).toBytes();

    final iv = QsCrypto.randomBytes(16);
    final ciphertext = QsCrypto.aesCbcEncrypt(encryptKey, iv, d2dMsg);

    final header = SecureHeader(
      signatureScheme: SecureHeader.sigHmacSha256,
      encryptionScheme: SecureHeader.encAes256Cbc,
      iv: iv,
      publicMetadata: GcmMetadata(
        type: GcmMetadata.typeDeviceToDeviceMessage,
        version: 1,
      ).toBytes(),
    );

    final headerAndBodyBytes = HeaderAndBody(
      header: header,
      body: ciphertext,
    ).toBytes();

    final signature = QsCrypto.hmacSha256(sendHmacKey, headerAndBodyBytes);
    return SecureMessage(
      headerAndBody: headerAndBodyBytes,
      signature: signature,
    ).toBytes();
  }

  Uint8List decrypt(Uint8List secureMessageBytes) {
    final sm = SecureMessage.parse(secureMessageBytes);
    if (!QsCrypto.hmacVerify(recvHmacKey, sm.headerAndBody, sm.signature)) {
      throw SecureChannelException('HMAC verification failed');
    }
    final hb = HeaderAndBody.parse(sm.headerAndBody);
    final iv = hb.header.iv;
    if (iv == null || iv.length != 16) {
      throw SecureChannelException('Missing or invalid AES-CBC IV');
    }
    final plaintext = QsCrypto.aesCbcDecrypt(decryptKey, iv, hb.body);
    final d2d = DeviceToDeviceMessage.parse(plaintext);
    return d2d.message;
  }
}

