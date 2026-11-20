import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'qs_crypto.dart';

enum ShareTargetType {
  unknown(0),
  phone(1),
  tablet(2),
  laptop(3),
  car(4),
  foldable(5),
  xr(6);

  final int code;
  const ShareTargetType(this.code);

  static ShareTargetType fromCode(int code) {
    for (final v in ShareTargetType.values) {
      if (v.code == code) return v;
    }
    return ShareTargetType.unknown;
  }
}

class ParsedEndpointInfo {
  final String? deviceName;
  final ShareTargetType deviceType;

  const ParsedEndpointInfo({
    required this.deviceName,
    required this.deviceType,
  });
}

class ParsedServiceInstance {
  final Uint8List endpointId;
  final Uint8List serviceIdHash;

  const ParsedServiceInstance({
    required this.endpointId,
    required this.serviceIdHash,
  });
}

class QsMdns {
  static const String serviceId = 'NearbySharing';
  static final Uint8List _serviceIdDigest =
      Uint8List.fromList(sha256.convert(utf8.encode(serviceId)).bytes);

  static final String serviceType =
      '_${_bytesToHexUpper(_serviceIdDigest.sublist(0, 6))}._tcp.local';
  static const String serviceTypeShort = '_FC9F5ED42C8A._tcp';

  static final Uint8List instanceServiceIdHash = _serviceIdDigest.sublist(0, 3);

  static const String txtKeyEndpointInfo = 'n';
  static const String txtKeyIpv4 = 'IPv4';

  static const String _endpointIdAlphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890';
  static const int endpointIdLength = 4;

  static const int _pcpP2pPointToPoint = 3;
  static const int wifiLanServiceInfoVersion = 1;
  static const int advertisementSaltSize = 2;
  static const int advertisementMetadataKeySize = 14;
  static const int _advertisementVersion = 0;

  static String webSafeBase64Encode(Uint8List data) {
    return base64Url.encode(data).replaceAll('=', '');
  }

  static Uint8List webSafeBase64Decode(String input) {
    final cleaned = input.trim();
    final mod = cleaned.length % 4;
    final padded =
        mod == 0 ? cleaned : cleaned + ('=' * (4 - mod));
    return Uint8List.fromList(base64Url.decode(padded));
  }

  static Uint8List stableEndpointId(String seed) {
    final digest = sha256.convert(utf8.encode(seed)).bytes;
    final out = StringBuffer();
    for (var i = 0; i < endpointIdLength; i++) {
      out.write(_endpointIdAlphabet[digest[i] % _endpointIdAlphabet.length]);
    }
    return Uint8List.fromList(ascii.encode(out.toString()));
  }

  static String buildServiceInstanceName(Uint8List endpointId) {
    if (endpointId.length != endpointIdLength) {
      throw ArgumentError('endpointId must be $endpointIdLength bytes');
    }
    const versionAndPcp =
        ((wifiLanServiceInfoVersion & 0x07) << 5) | (_pcpP2pPointToPoint & 0x1F);
    final payload = Uint8List(10);
    payload[0] = versionAndPcp;
    payload.setRange(1, 5, endpointId);
    payload.setRange(5, 8, instanceServiceIdHash);
    payload[8] = 0x00;
    payload[9] = 0x00;
    return webSafeBase64Encode(payload);
  }

  static ParsedServiceInstance? parseServiceInstanceName(String instanceName) {
    try {
      final raw = webSafeBase64Decode(instanceName);
      if (raw.length < 8) return null;
      final version = (raw[0] >> 5) & 0x07;
      if (version != wifiLanServiceInfoVersion) return null;
      return ParsedServiceInstance(
        endpointId: raw.sublist(1, 5),
        serviceIdHash: raw.sublist(5, 8),
      );
    } catch (_) {
      return null;
    }
  }

  static Uint8List buildEndpointInfo(
    String? deviceName,
    ShareTargetType deviceType, {
    Uint8List? salt,
    Uint8List? metadataKey,
  }) {
    final hasName = deviceName != null && deviceName.isNotEmpty;
    final byte0 = ((_advertisementVersion & 0x07) << 5) |
        ((hasName ? 0 : 1) << 4) |
        ((deviceType.code & 0x07) << 1);

    final builder = BytesBuilder(copy: false);
    builder.addByte(byte0);
    builder.add(salt ?? QsCrypto.randomBytes(advertisementSaltSize));
    builder.add(
      metadataKey ?? QsCrypto.randomBytes(advertisementMetadataKeySize),
    );

    if (hasName) {
      var nameBytes = utf8.encode(deviceName);
      if (nameBytes.length > 255) {
        nameBytes = nameBytes.sublist(0, 255);
      }
      builder.addByte(nameBytes.length);
      builder.add(nameBytes);
    }

    return builder.toBytes();
  }

  static String buildEndpointInfoTxtValue(
    String? deviceName,
    ShareTargetType deviceType,
  ) {
    return webSafeBase64Encode(buildEndpointInfo(deviceName, deviceType));
  }

  static ParsedEndpointInfo? parseEndpointInfo(Uint8List endpointInfo) {
    if (endpointInfo.isEmpty) return null;
    final byte0 = endpointInfo[0];
    final hasNoName = ((byte0 >> 4) & 1) == 1;
    final rawType = (byte0 >> 1) & 0x07;
    final deviceType = ShareTargetType.fromCode(rawType);

    String? name;
    const headerSize =
        1 + advertisementSaltSize + advertisementMetadataKeySize;
    if (!hasNoName && endpointInfo.length > headerSize) {
      final nameLen = endpointInfo[headerSize];
      final end = (headerSize + 1 + nameLen).clamp(0, endpointInfo.length);
      if (end > headerSize + 1) {
        name = utf8.decode(
          endpointInfo.sublist(headerSize + 1, end),
          allowMalformed: true,
        );
      }
    }
    return ParsedEndpointInfo(deviceName: name, deviceType: deviceType);
  }

  static ParsedEndpointInfo? parseTxtEndpointInfo(String txtN) {
    if (txtN.isEmpty) return null;
    try {
      final raw = webSafeBase64Decode(txtN);
      return parseEndpointInfo(raw);
    } catch (_) {
      return null;
    }
  }

  static String _bytesToHexUpper(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return sb.toString();
  }
}

