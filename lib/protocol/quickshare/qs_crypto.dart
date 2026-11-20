import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// Cryptographic primitives for Google Quick Share UKEY2 + SecureMessage (AES-256-CBC + HMAC-SHA256).
class QsCrypto {
  // SHA256("D2D")
  static final Uint8List _d2dSalt = _hexToBytes(
    '82aa55a0d397f88346ca1cee8d3909b95f13fa7deb1d4ab38376b8256da85510',
  );

  // SHA256("SecureMessage")
  static final Uint8List _secureMessageSalt = _hexToBytes(
    'bf9d2a53c63616d75db0a7165b91c1ef73e537f2427405fa23610a4be657642e',
  );

  static final Uint8List _authSalt = Uint8List.fromList(utf8.encode('UKEY2 v1 auth'));
  static final Uint8List _nextSalt = Uint8List.fromList(utf8.encode('UKEY2 v1 next'));

  static final ECDomainParameters _p256 = ECCurve_secp256r1();

  // P-256 curve parameters for explicit point-on-curve validation
  static final BigInt _p256P = BigInt.parse(
    'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
    radix: 16,
  );
  static final BigInt _p256A = BigInt.parse(
    'ffffffff00000001000000000000000000000000fffffffffffffffffffffffc',
    radix: 16,
  );
  static final BigInt _p256B = BigInt.parse(
    '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
    radix: 16,
  );

  static final Random _secureRandom = Random.secure();

  static Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _secureRandom.nextInt(256);
    }
    return out;
  }

  static int randomInt64() {
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value = (value << 8) | _secureRandom.nextInt(256);
    }
    return value;
  }

  static int randomPositive63BitId() {
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value = (value << 8) | _secureRandom.nextInt(256);
    }
    final positive = value >>> 1;
    return positive == 0 ? 1 : positive;
  }

  static FortunaRandom _createFortuna() {
    final fortuna = FortunaRandom();
    fortuna.seed(KeyParameter(randomBytes(32)));
    return fortuna;
  }

  static AsymmetricKeyPair<ECPublicKey, ECPrivateKey> generateKeyPair() {
    final gen = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(_p256), _createFortuna()));
    final pair = gen.generateKeyPair();
    return AsymmetricKeyPair<ECPublicKey, ECPrivateKey>(
      pair.publicKey as ECPublicKey,
      pair.privateKey as ECPrivateKey,
    );
  }

  /// ExportEcP256Key two's complement coordinate encoding:
  /// unsigned minimal big-endian bytes, unconditionally prefixed with a single 0x00 byte.
  static Uint8List encodePointSigned(Uint8List coord32) {
    var start = 0;
    while (start < coord32.length && coord32[start] == 0) {
      start++;
    }
    final minimal = coord32.sublist(start);
    final out = Uint8List(1 + minimal.length);
    out[0] = 0x00;
    out.setRange(1, out.length, minimal);
    return out;
  }

  /// Inverse of [encodePointSigned]: strips leading sign/padding bytes and left-pads to [size].
  static Uint8List decodePointUnsigned(Uint8List encoded, [int size = 32]) {
    var n = BigInt.zero;
    for (final b in encoded) {
      n = (n << 8) | BigInt.from(b);
    }
    return bigIntToFixedBytes(n, size);
  }

  static (Uint8List, Uint8List) publicKeyXY(ECPublicKey pub) {
    final q = pub.Q!;
    final x = bigIntToFixedBytes(q.x!.toBigInteger()!, 32);
    final y = bigIntToFixedBytes(q.y!.toBigInteger()!, 32);
    return (x, y);
  }

  static ECPublicKey publicKeyFromXY(Uint8List xBytes, Uint8List yBytes) {
    final x = bytesToBigInt(xBytes);
    final y = bytesToBigInt(yBytes);
    if (x < BigInt.zero || x >= _p256P || y < BigInt.zero || y >= _p256P) {
      throw ArgumentError('P-256 coordinates out of field range');
    }
    final lhs = (y * y) % _p256P;
    final rhs = (x.modPow(BigInt.from(3), _p256P) + _p256A * x + _p256B) % _p256P;
    if (lhs != rhs) {
      throw ArgumentError('Point is not on NIST P-256 curve');
    }
    final point = _p256.curve.createPoint(x, y);
    if (point.isInfinity) {
      throw ArgumentError('Point is at infinity');
    }
    return ECPublicKey(point, _p256);
  }

  static Uint8List ecdhSharedSecret(ECPrivateKey priv, ECPublicKey peerPub) {
    final agreement = ECDHBasicAgreement()..init(priv);
    final secretInt = agreement.calculateAgreement(peerPub);
    final raw = bigIntToFixedBytes(secretInt, 32);
    return Uint8List.fromList(sha256.convert(raw).bytes);
  }

  static Uint8List hkdfExtractExpand(
    Uint8List salt,
    Uint8List ikm,
    Uint8List info, [
    int length = 32,
  ]) {
    final prk = Hmac(sha256, salt).convert(ikm).bytes;
    final out = BytesBuilder(copy: false);
    var prev = Uint8List(0);
    var counter = 1;
    while (out.length < length) {
      final input = BytesBuilder(copy: false)
        ..add(prev)
        ..add(info)
        ..addByte(counter);
      prev = Uint8List.fromList(Hmac(sha256, prk).convert(input.toBytes()).bytes);
      out.add(prev);
      counter++;
    }
    final all = out.toBytes();
    return Uint8List.sublistView(all, 0, length);
  }

  static String toFourDigitPin(Uint8List authString) {
    const kHashModulo = 9973;
    const kHashBaseMultiplier = 31;
    var h = 0;
    var multiplier = 1;
    for (final b in authString) {
      final signedB = b >= 128 ? b - 256 : b;
      h = (h + signedB * multiplier).remainder(kHashModulo);
      multiplier = (multiplier * kHashBaseMultiplier).remainder(kHashModulo);
    }
    return h.abs().toString().padLeft(4, '0');
  }

  static D2DKeys deriveD2DKeys({
    required Uint8List sharedSecret,
    required Uint8List clientInitBytes,
    required Uint8List serverInitBytes,
    required bool isServer,
  }) {
    final ukeyInfo = Uint8List(clientInitBytes.length + serverInitBytes.length)
      ..setRange(0, clientInitBytes.length, clientInitBytes)
      ..setRange(clientInitBytes.length, clientInitBytes.length + serverInitBytes.length, serverInitBytes);

    final authString = hkdfExtractExpand(_authSalt, sharedSecret, ukeyInfo, 32);
    final nextSecret = hkdfExtractExpand(_nextSalt, sharedSecret, ukeyInfo, 32);

    final d2dClient = hkdfExtractExpand(
      _d2dSalt,
      nextSecret,
      Uint8List.fromList(utf8.encode('client')),
      32,
    );
    final d2dServer = hkdfExtractExpand(
      _d2dSalt,
      nextSecret,
      Uint8List.fromList(utf8.encode('server')),
      32,
    );

    final ownKey = isServer ? d2dServer : d2dClient;
    final peerKey = isServer ? d2dClient : d2dServer;

    final encInfo = Uint8List.fromList(utf8.encode('ENC:2'));
    final sigInfo = Uint8List.fromList(utf8.encode('SIG:1'));

    return D2DKeys(
      encryptKey: hkdfExtractExpand(_secureMessageSalt, ownKey, encInfo, 32),
      sendHmacKey: hkdfExtractExpand(_secureMessageSalt, ownKey, sigInfo, 32),
      decryptKey: hkdfExtractExpand(_secureMessageSalt, peerKey, encInfo, 32),
      recvHmacKey: hkdfExtractExpand(_secureMessageSalt, peerKey, sigInfo, 32),
      authString: authString,
    );
  }

  static Uint8List aesCbcEncrypt(
    Uint8List key,
    Uint8List iv,
    Uint8List plaintext,
  ) {
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
        true,
        PaddedBlockCipherParameters(
          ParametersWithIV(KeyParameter(key), iv),
          null,
        ),
      );
    return cipher.process(plaintext);
  }

  static Uint8List aesCbcDecrypt(
    Uint8List key,
    Uint8List iv,
    Uint8List ciphertext,
  ) {
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
        false,
        PaddedBlockCipherParameters(
          ParametersWithIV(KeyParameter(key), iv),
          null,
        ),
      );
    return cipher.process(ciphertext);
  }

  static Uint8List hmacSha256(Uint8List key, Uint8List data) {
    return Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);
  }

  static bool hmacVerify(Uint8List key, Uint8List data, Uint8List expected) {
    final actual = hmacSha256(key, data);
    if (actual.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual[i] ^ expected[i];
    }
    return diff == 0;
  }

  static Uint8List sha512Bytes(Uint8List data) {
    return Uint8List.fromList(sha512.convert(data).bytes);
  }

  static BigInt bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  static Uint8List bigIntToFixedBytes(BigInt value, int size) {
    final out = Uint8List(size);
    var v = value;
    for (var i = size - 1; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xFF)).toInt();
      v = v >> 8;
    }
    return out;
  }

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

class D2DKeys {
  final Uint8List decryptKey;
  final Uint8List recvHmacKey;
  final Uint8List encryptKey;
  final Uint8List sendHmacKey;
  final Uint8List authString;

  D2DKeys({
    required this.decryptKey,
    required this.recvHmacKey,
    required this.encryptKey,
    required this.sendHmacKey,
    required this.authString,
  });

  String get pin => QsCrypto.toFourDigitPin(authString);
}
