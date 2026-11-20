import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

import '../quickshare/qs_crypto.dart';

/// Pure-Dart self-signed X.509 v3 TLS identity (ECDSA P-256) and pinned HttpClient builder.
class TlsIdentity {
  final Uint8List certificateDerBytes;
  final Uint8List certificatePemBytes;
  final Uint8List privateKeyPemBytes;
  final String fingerprint;

  TlsIdentity._({
    required this.certificateDerBytes,
    required this.certificatePemBytes,
    required this.privateKeyPemBytes,
    required this.fingerprint,
  });

  SecurityContext createSecurityContext() {
    final ctx = SecurityContext();
    ctx.useCertificateChainBytes(certificatePemBytes);
    ctx.usePrivateKeyBytes(privateKeyPemBytes);
    return ctx;
  }

  /// Generates a fresh ECDSA P-256 keypair and self-signed X.509 v3 certificate.
  factory TlsIdentity.generate({String commonName = 'MaterialDrop'}) {
    final pair = QsCrypto.generateKeyPair();
    final pub = pair.publicKey;
    final priv = pair.privateKey;

    final privScalar = _bigIntToBytes(priv.d!, 32);
    final pubPoint = pub.Q!.getEncoded(false);

    // OIDs:
    // ecPublicKey: 1.2.840.10045.2.1
    // prime256v1 (secp256r1): 1.2.840.10045.3.1.7
    // ecdsa-with-SHA256: 1.2.840.10045.4.3.2
    // commonName (CN): 2.5.4.3
    final oidEcPublicKey =
        ASN1ObjectIdentifier.fromIdentifierString('1.2.840.10045.2.1');
    final oidPrime256v1 =
        ASN1ObjectIdentifier.fromIdentifierString('1.2.840.10045.3.1.7');
    final oidEcdsaSha256 =
        ASN1ObjectIdentifier.fromIdentifierString('1.2.840.10045.4.3.2');
    final oidCommonName = ASN1ObjectIdentifier.fromIdentifierString('2.5.4.3');

    // RFC 5915 ECPrivateKey wrapped inside RFC 5958 PKCS#8 PrivateKeyInfo
    final ecPrivateKeySeq = ASN1Sequence(elements: [
      ASN1Integer.fromtInt(1),
      ASN1OctetString(octets: privScalar),
      ASN1Sequence(
        tag: 0xA1,
        elements: [ASN1BitString(stringValues: pubPoint)],
      ),
    ]);
    final pkcs8Info = ASN1Sequence(elements: [
      ASN1Integer.fromtInt(0),
      ASN1Sequence(elements: [oidEcPublicKey, oidPrime256v1]),
      ASN1OctetString(octets: ecPrivateKeySeq.encode()),
    ]);
    final pkcs8Der = pkcs8Info.encode();

    // RFC 5280 TBSCertificate (X.509 v3)
    final now = DateTime.now().toUtc();
    final notBefore = now.subtract(const Duration(days: 1));
    final notAfter = now.add(const Duration(days: 3650));

    final cnName = ASN1Sequence(elements: [
      ASN1Set(elements: [
        ASN1Sequence(elements: [
          oidCommonName,
          ASN1UTF8String(utf8StringValue: commonName),
        ]),
      ]),
    ]);

    final sigAlgSeq = ASN1Sequence(elements: [oidEcdsaSha256]);
    final spkiSeq = ASN1Sequence(elements: [
      ASN1Sequence(elements: [oidEcPublicKey, oidPrime256v1]),
      ASN1BitString(stringValues: pubPoint),
    ]);

    // Positive 63-bit serial number
    final serial = BigInt.from(QsCrypto.randomPositive63BitId());

    final tbsCert = ASN1Sequence(elements: [
      ASN1Sequence(tag: 0xA0, elements: [ASN1Integer.fromtInt(2)]), // v3
      ASN1Integer(serial),
      sigAlgSeq,
      cnName,
      ASN1Sequence(elements: [ASN1UtcTime(notBefore), ASN1UtcTime(notAfter)]),
      cnName,
      spkiSeq,
    ]);

    final tbsDer = tbsCert.encode();
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter<ECPrivateKey>(priv));
    final ecSig = signer.generateSignature(tbsDer) as ECSignature;
    final sigDer = ASN1Sequence(elements: [
      ASN1Integer(ecSig.r),
      ASN1Integer(ecSig.s),
    ]).encode();

    final certDer = ASN1Sequence(elements: [
      tbsCert,
      sigAlgSeq,
      ASN1BitString(stringValues: sigDer),
    ]).encode();

    final fp = bytesToUpperHex(sha256.convert(certDer).bytes);
    final certPem = Uint8List.fromList(utf8.encode(_wrapPem('CERTIFICATE', certDer)));
    final keyPem = Uint8List.fromList(utf8.encode(_wrapPem('PRIVATE KEY', pkcs8Der)));

    return TlsIdentity._(
      certificateDerBytes: certDer,
      certificatePemBytes: certPem,
      privateKeyPemBytes: keyPem,
      fingerprint: fp,
    );
  }

  /// Computes uppercase SHA-256 fingerprint of a peer's X.509 certificate DER bytes.
  static String certificateSha256Hex(X509Certificate cert) {
    return bytesToUpperHex(sha256.convert(cert.der).bytes);
  }

  static String bytesToUpperHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString().toUpperCase();
  }

  /// Creates an [HttpClient] whose `badCertificateCallback` validates self-signed
  /// peer certificates by comparing SHA-256 DER fingerprint with [expectedFingerprint].
  static HttpClient createPinnedClient({
    required String? expectedFingerprint,
    bool trustOnFirstProbe = false,
    void Function(String actualFingerprint)? onObservedCertFingerprint,
    Duration connectionTimeout = const Duration(seconds: 6),
  }) {
    final expected = expectedFingerprint?.trim().toUpperCase();
    final client = HttpClient()..connectionTimeout = connectionTimeout;
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) {
      final actual = certificateSha256Hex(cert);
      onObservedCertFingerprint?.call(actual);
      if (expected != null && expected.isNotEmpty) {
        return actual == expected;
      }
      return trustOnFirstProbe;
    };
    return client;
  }

  static Uint8List _bigIntToBytes(BigInt number, int length) {
    final out = Uint8List(length);
    var v = number;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v = v >> 8;
    }
    return out;
  }

  static String _wrapPem(String label, Uint8List der) {
    final b64 = base64Encode(der);
    final sb = StringBuffer('-----BEGIN $label-----\n');
    for (var i = 0; i < b64.length; i += 64) {
      final end = (i + 64 < b64.length) ? i + 64 : b64.length;
      sb.writeln(b64.substring(i, end));
    }
    sb.writeln('-----END $label-----');
    return sb.toString();
  }
}
