import 'dart:convert';
import 'dart:typed_data';

/// Minimal, zero-code-gen Protobuf v2 binary writer supporting 64-bit signed/unsigned varints.
class ProtoWriter {
  final BytesBuilder _buf = BytesBuilder(copy: false);

  void writeVarint(int value) {
    var v = value;
    while (true) {
      if ((v & ~0x7F) == 0) {
        _buf.addByte(v);
        break;
      }
      _buf.addByte((v & 0x7F) | 0x80);
      v = v >>> 7;
    }
  }

  void writeTag(int fieldNumber, int wireType) {
    writeVarint((fieldNumber << 3) | (wireType & 0x07));
  }

  void writeInt32Field(int fieldNumber, int? value) {
    if (value == null) return;
    writeTag(fieldNumber, 0);
    writeVarint(value);
  }

  void writeInt64Field(int fieldNumber, int? value) {
    if (value == null) return;
    writeTag(fieldNumber, 0);
    writeVarint(value);
  }

  void writeBoolField(int fieldNumber, bool? value) {
    if (value == null) return;
    writeTag(fieldNumber, 0);
    writeVarint(value ? 1 : 0);
  }

  void writeBytesField(int fieldNumber, Uint8List? value) {
    if (value == null) return;
    writeTag(fieldNumber, 2);
    writeVarint(value.length);
    _buf.add(value);
  }

  void writeStringField(int fieldNumber, String? value) {
    if (value == null) return;
    final bytes = Uint8List.fromList(utf8.encode(value));
    writeBytesField(fieldNumber, bytes);
  }

  Uint8List toBytes() => _buf.toBytes();
}

/// Minimal Protobuf v2 binary reader.
class ProtoReader {
  final Uint8List _bytes;
  int _offset = 0;

  ProtoReader(this._bytes);

  bool get hasMore => _offset < _bytes.length;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_offset >= _bytes.length) {
        throw const FormatException('Truncated protobuf varint');
      }
      final b = _bytes[_offset++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) {
        return result;
      }
      shift += 7;
      if (shift >= 70) {
        throw const FormatException('Malformed protobuf varint');
      }
    }
  }

  Uint8List readBytes() {
    final len = readVarint();
    if (len < 0 || _offset + len > _bytes.length) {
      throw const FormatException('Truncated protobuf length-delimited field');
    }
    final slice = Uint8List.sublistView(_bytes, _offset, _offset + len);
    _offset += len;
    return Uint8List.fromList(slice);
  }

  String readString() => utf8.decode(readBytes(), allowMalformed: true);

  void skipField(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
      case 1:
        if (_offset + 8 > _bytes.length) {
          throw const FormatException('Truncated fixed64');
        }
        _offset += 8;
      case 2:
        final len = readVarint();
        if (len < 0 || _offset + len > _bytes.length) {
          throw const FormatException('Truncated length-delimited skip');
        }
        _offset += len;
      case 5:
        if (_offset + 4 > _bytes.length) {
          throw const FormatException('Truncated fixed32');
        }
        _offset += 4;
      default:
        throw FormatException('Unsupported protobuf wire type: $wireType');
    }
  }

  /// Iterates through `(fieldNumber, wireType)` tags until EOF.
  void forEachField(void Function(int fieldNumber, int wireType) onField) {
    while (hasMore) {
      final tag = readVarint();
      final fieldNumber = tag >>> 3;
      final wireType = tag & 0x07;
      onField(fieldNumber, wireType);
    }
  }
}

// ---------------------------------------------------------------------------
// ukey.proto
// ---------------------------------------------------------------------------

class Ukey2MessageType {
  static const int unknown = 0;
  static const int alert = 1;
  static const int clientInit = 2;
  static const int serverInit = 3;
  static const int clientFinish = 4;
}

class Ukey2HandshakeCipher {
  static const int reserved = 0;
  static const int p256Sha512 = 100;
  static const int curve25519Sha512 = 200;
}

class Ukey2Message {
  final int messageType;
  final Uint8List messageData;

  Ukey2Message({required this.messageType, required this.messageData});

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, messageType);
    w.writeBytesField(2, messageData);
    return w.toBytes();
  }

  static Ukey2Message parse(Uint8List bytes) {
    var type = 0;
    var data = Uint8List(0);
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        type = r.readVarint();
      } else if (field == 2 && wire == 2) {
        data = r.readBytes();
      } else {
        r.skipField(wire);
      }
    });
    return Ukey2Message(messageType: type, messageData: data);
  }
}

class Ukey2CipherCommitment {
  final int handshakeCipher;
  final Uint8List commitment;

  Ukey2CipherCommitment({
    required this.handshakeCipher,
    required this.commitment,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, handshakeCipher);
    w.writeBytesField(2, commitment);
    return w.toBytes();
  }

  static Ukey2CipherCommitment parse(Uint8List bytes) {
    var cipher = 0;
    var comm = Uint8List(0);
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        cipher = r.readVarint();
      } else if (field == 2 && wire == 2) {
        comm = r.readBytes();
      } else {
        r.skipField(wire);
      }
    });
    return Ukey2CipherCommitment(handshakeCipher: cipher, commitment: comm);
  }
}

class Ukey2ClientInit {
  final int version;
  final Uint8List random;
  final List<Ukey2CipherCommitment> cipherCommitments;
  final String nextProtocol;

  Ukey2ClientInit({
    required this.version,
    required this.random,
    required this.cipherCommitments,
    required this.nextProtocol,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, version);
    w.writeBytesField(2, random);
    for (final c in cipherCommitments) {
      w.writeBytesField(3, c.toBytes());
    }
    w.writeStringField(4, nextProtocol);
    return w.toBytes();
  }

  static Ukey2ClientInit parse(Uint8List bytes) {
    var version = 0;
    var random = Uint8List(0);
    final commitments = <Ukey2CipherCommitment>[];
    var nextProtocol = '';
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        version = r.readVarint();
      } else if (field == 2 && wire == 2) {
        random = r.readBytes();
      } else if (field == 3 && wire == 2) {
        commitments.add(Ukey2CipherCommitment.parse(r.readBytes()));
      } else if (field == 4 && wire == 2) {
        nextProtocol = r.readString();
      } else {
        r.skipField(wire);
      }
    });
    return Ukey2ClientInit(
      version: version,
      random: random,
      cipherCommitments: commitments,
      nextProtocol: nextProtocol,
    );
  }
}

class Ukey2ServerInit {
  final int version;
  final Uint8List random;
  final int handshakeCipher;
  final Uint8List publicKey;

  Ukey2ServerInit({
    required this.version,
    required this.random,
    required this.handshakeCipher,
    required this.publicKey,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, version);
    w.writeBytesField(2, random);
    w.writeInt32Field(3, handshakeCipher);
    w.writeBytesField(4, publicKey);
    return w.toBytes();
  }

  static Ukey2ServerInit parse(Uint8List bytes) {
    var version = 0;
    var random = Uint8List(0);
    var cipher = 0;
    var pubKey = Uint8List(0);
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        version = r.readVarint();
      } else if (field == 2 && wire == 2) {
        random = r.readBytes();
      } else if (field == 3 && wire == 0) {
        cipher = r.readVarint();
      } else if (field == 4 && wire == 2) {
        pubKey = r.readBytes();
      } else {
        r.skipField(wire);
      }
    });
    return Ukey2ServerInit(
      version: version,
      random: random,
      handshakeCipher: cipher,
      publicKey: pubKey,
    );
  }
}

class Ukey2ClientFinished {
  final Uint8List publicKey;

  Ukey2ClientFinished({required this.publicKey});

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeBytesField(1, publicKey);
    return w.toBytes();
  }

  static Ukey2ClientFinished parse(Uint8List bytes) {
    var pubKey = Uint8List(0);
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 2) {
        pubKey = r.readBytes();
      } else {
        r.skipField(wire);
      }
    });
    return Ukey2ClientFinished(publicKey: pubKey);
  }
}

// ---------------------------------------------------------------------------
// securemessage.proto + securegcm.proto + device_to_device_messages.proto
// ---------------------------------------------------------------------------

class EcP256PublicKey {
  final Uint8List x;
  final Uint8List y;

  EcP256PublicKey({required this.x, required this.y});

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeBytesField(1, x);
    w.writeBytesField(2, y);
    return w.toBytes();
  }

  static EcP256PublicKey parse(Uint8List bytes) {
    var x = Uint8List(0);
    var y = Uint8List(0);
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 2) {
        x = r.readBytes();
      } else if (field == 2 && wire == 2) {
        y = r.readBytes();
      } else {
        r.skipField(wire);
      }
    });
    return EcP256PublicKey(x: x, y: y);
  }
}

class GenericPublicKey {
  static const int typeEcP256 = 1;

  final int type;
  final EcP256PublicKey? ecP256PublicKey;

  GenericPublicKey({required this.type, this.ecP256PublicKey});

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, type);
    if (ecP256PublicKey != null) {
      w.writeBytesField(2, ecP256PublicKey!.toBytes());
    }
    return w.toBytes();
  }

  static GenericPublicKey parse(Uint8List bytes) {
    var type = 0;
    EcP256PublicKey? ec;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        type = r.readVarint();
      } else if (field == 2 && wire == 2) {
        ec = EcP256PublicKey.parse(r.readBytes());
      } else {
        r.skipField(wire);
      }
    });
    return GenericPublicKey(type: type, ecP256PublicKey: ec);
  }
}

class SecureHeader {
  static const int sigHmacSha256 = 1;
  static const int encAes256Cbc = 2;

  final int signatureScheme;
  final int encryptionScheme;
  final Uint8List? iv;
  final Uint8List? publicMetadata;

  SecureHeader({
    required this.signatureScheme,
    required this.encryptionScheme,
    this.iv,
    this.publicMetadata,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, signatureScheme);
    w.writeInt32Field(2, encryptionScheme);
    w.writeBytesField(5, iv);
    w.writeBytesField(6, publicMetadata);
    return w.toBytes();
  }

  static SecureHeader parse(Uint8List bytes) {
    var sig = 0;
    var enc = 0;
    Uint8List? iv;
    Uint8List? meta;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        sig = r.readVarint();
      } else if (field == 2 && wire == 0) {
        enc = r.readVarint();
      } else if (field == 5 && wire == 2) {
        iv = r.readBytes();
      } else if (field == 6 && wire == 2) {
        meta = r.readBytes();
      } else {
        r.skipField(wire);
      }
    });
    return SecureHeader(
      signatureScheme: sig,
      encryptionScheme: enc,
      iv: iv,
      publicMetadata: meta,
    );
  }
}

class HeaderAndBody {
  final SecureHeader header;
  final Uint8List body;

  HeaderAndBody({required this.header, required this.body});

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeBytesField(1, header.toBytes());
    w.writeBytesField(2, body);
    return w.toBytes();
  }

  static HeaderAndBody parse(Uint8List bytes) {
    SecureHeader? header;
    var body = Uint8List(0);
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 2) {
        header = SecureHeader.parse(r.readBytes());
      } else if (field == 2 && wire == 2) {
        body = r.readBytes();
      } else {
        r.skipField(wire);
      }
    });
    return HeaderAndBody(
      header: header ?? SecureHeader(signatureScheme: 0, encryptionScheme: 0),
      body: body,
    );
  }
}

class SecureMessage {
  final Uint8List headerAndBody;
  final Uint8List signature;

  SecureMessage({required this.headerAndBody, required this.signature});

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeBytesField(1, headerAndBody);
    w.writeBytesField(2, signature);
    return w.toBytes();
  }

  static SecureMessage parse(Uint8List bytes) {
    var hb = Uint8List(0);
    var sig = Uint8List(0);
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 2) {
        hb = r.readBytes();
      } else if (field == 2 && wire == 2) {
        sig = r.readBytes();
      } else {
        r.skipField(wire);
      }
    });
    return SecureMessage(headerAndBody: hb, signature: sig);
  }
}

class GcmMetadata {
  static const int typeDeviceToDeviceMessage = 13;

  final int type;
  final int version;

  GcmMetadata({required this.type, this.version = 1});

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, type);
    w.writeInt32Field(2, version);
    return w.toBytes();
  }
}

class DeviceToDeviceMessage {
  final Uint8List message;
  final int sequenceNumber;

  DeviceToDeviceMessage({required this.message, required this.sequenceNumber});

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeBytesField(1, message);
    w.writeInt32Field(2, sequenceNumber);
    return w.toBytes();
  }

  static DeviceToDeviceMessage parse(Uint8List bytes) {
    var msg = Uint8List(0);
    var seq = 0;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 2) {
        msg = r.readBytes();
      } else if (field == 2 && wire == 0) {
        seq = r.readVarint();
      } else {
        r.skipField(wire);
      }
    });
    return DeviceToDeviceMessage(message: msg, sequenceNumber: seq);
  }
}

// ---------------------------------------------------------------------------
// offline_wire_formats.proto
// ---------------------------------------------------------------------------

class OfflineFrameType {
  static const int unknown = 0;
  static const int connectionRequest = 1;
  static const int connectionResponse = 2;
  static const int payloadTransfer = 3;
  static const int bandwidthUpgradeNegotiation = 4;
  static const int keepAlive = 5;
  static const int disconnection = 6;
}

class OfflineFrame {
  static const int versionV1 = 1;

  final int version;
  final OfflineV1Frame? v1;

  OfflineFrame({this.version = versionV1, this.v1});

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, version);
    if (v1 != null) {
      w.writeBytesField(2, v1!.toBytes());
    }
    return w.toBytes();
  }

  static OfflineFrame parse(Uint8List bytes) {
    var ver = 0;
    OfflineV1Frame? v1;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        ver = r.readVarint();
      } else if (field == 2 && wire == 2) {
        v1 = OfflineV1Frame.parse(r.readBytes());
      } else {
        r.skipField(wire);
      }
    });
    return OfflineFrame(version: ver, v1: v1);
  }
}

class OfflineV1Frame {
  final int type;
  final ConnectionRequestFrame? connectionRequest;
  final OfflineConnectionResponseFrame? connectionResponse;
  final PayloadTransferFrame? payloadTransfer;

  OfflineV1Frame({
    required this.type,
    this.connectionRequest,
    this.connectionResponse,
    this.payloadTransfer,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, type);
    if (connectionRequest != null) {
      w.writeBytesField(2, connectionRequest!.toBytes());
    }
    if (connectionResponse != null) {
      w.writeBytesField(3, connectionResponse!.toBytes());
    }
    if (payloadTransfer != null) {
      w.writeBytesField(4, payloadTransfer!.toBytes());
    }
    return w.toBytes();
  }

  static OfflineV1Frame parse(Uint8List bytes) {
    var type = 0;
    ConnectionRequestFrame? req;
    OfflineConnectionResponseFrame? resp;
    PayloadTransferFrame? pt;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        type = r.readVarint();
      } else if (field == 2 && wire == 2) {
        req = ConnectionRequestFrame.parse(r.readBytes());
      } else if (field == 3 && wire == 2) {
        resp = OfflineConnectionResponseFrame.parse(r.readBytes());
      } else if (field == 4 && wire == 2) {
        pt = PayloadTransferFrame.parse(r.readBytes());
      } else {
        r.skipField(wire);
      }
    });
    return OfflineV1Frame(
      type: type,
      connectionRequest: req,
      connectionResponse: resp,
      payloadTransfer: pt,
    );
  }
}

class ConnectionRequestFrame {
  static const int mediumWifiLan = 5;

  final String? endpointId;
  final String? endpointName;
  final List<int> mediums;
  final Uint8List? endpointInfo;

  ConnectionRequestFrame({
    this.endpointId,
    this.endpointName,
    this.mediums = const [],
    this.endpointInfo,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeStringField(1, endpointId);
    w.writeStringField(2, endpointName);
    for (final m in mediums) {
      w.writeInt32Field(5, m);
    }
    w.writeBytesField(6, endpointInfo);
    return w.toBytes();
  }

  static ConnectionRequestFrame parse(Uint8List bytes) {
    String? eid;
    String? ename;
    final meds = <int>[];
    Uint8List? einfo;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 2) {
        eid = r.readString();
      } else if (field == 2 && wire == 2) {
        ename = r.readString();
      } else if (field == 5 && wire == 0) {
        meds.add(r.readVarint());
      } else if (field == 5 && wire == 2) {
        final packed = ProtoReader(r.readBytes());
        while (packed.hasMore) {
          meds.add(packed.readVarint());
        }
      } else if (field == 6 && wire == 2) {
        einfo = r.readBytes();
      } else {
        r.skipField(wire);
      }
    });
    return ConnectionRequestFrame(
      endpointId: eid,
      endpointName: ename,
      mediums: meds,
      endpointInfo: einfo,
    );
  }
}

class OsInfo {
  static const int osAndroid = 1;
  static const int osWindows = 3;
  static const int osLinux = 100;

  final int type;

  OsInfo({required this.type});

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, type);
    return w.toBytes();
  }

  static OsInfo parse(Uint8List bytes) {
    var t = 0;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        t = r.readVarint();
      } else {
        r.skipField(wire);
      }
    });
    return OsInfo(type: t);
  }
}

class OfflineConnectionResponseFrame {
  static const int statusAccept = 1;
  static const int statusReject = 2;

  final int response;
  final OsInfo? osInfo;
  final int? safeToDisconnectVersion;

  OfflineConnectionResponseFrame({
    required this.response,
    this.osInfo,
    this.safeToDisconnectVersion,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(3, response);
    if (osInfo != null) {
      w.writeBytesField(4, osInfo!.toBytes());
    }
    w.writeInt32Field(7, safeToDisconnectVersion);
    return w.toBytes();
  }

  static OfflineConnectionResponseFrame parse(Uint8List bytes) {
    var resp = 0;
    OsInfo? os;
    int? stdv;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 3 && wire == 0) {
        resp = r.readVarint();
      } else if (field == 4 && wire == 2) {
        os = OsInfo.parse(r.readBytes());
      } else if (field == 7 && wire == 0) {
        stdv = r.readVarint();
      } else {
        r.skipField(wire);
      }
    });
    return OfflineConnectionResponseFrame(
      response: resp,
      osInfo: os,
      safeToDisconnectVersion: stdv,
    );
  }
}

class PayloadHeader {
  static const int typeBytes = 1;
  static const int typeFile = 2;
  static const int typeStream = 3;

  final int id;
  final int type;
  final int? totalSize;
  final String? fileName;

  PayloadHeader({
    required this.id,
    this.type = 0,
    this.totalSize,
    this.fileName,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt64Field(1, id);
    if (type != 0) w.writeInt32Field(2, type);
    if (totalSize != null) w.writeInt64Field(3, totalSize);
    w.writeStringField(5, fileName);
    return w.toBytes();
  }

  static PayloadHeader parse(Uint8List bytes) {
    var id = 0;
    var type = 0;
    int? total;
    String? fname;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        id = r.readVarint();
      } else if (field == 2 && wire == 0) {
        type = r.readVarint();
      } else if (field == 3 && wire == 0) {
        total = r.readVarint();
      } else if (field == 5 && wire == 2) {
        fname = r.readString();
      } else {
        r.skipField(wire);
      }
    });
    return PayloadHeader(
      id: id,
      type: type,
      totalSize: total,
      fileName: fname,
    );
  }
}

class PayloadChunk {
  static const int flagLastChunk = 0x1;

  final int flags;
  final int offset;
  final Uint8List body;

  PayloadChunk({
    required this.flags,
    required this.offset,
    required this.body,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, flags);
    w.writeInt64Field(2, offset);
    w.writeBytesField(3, body);
    return w.toBytes();
  }

  static PayloadChunk parse(Uint8List bytes) {
    var flags = 0;
    var offset = 0;
    var body = Uint8List(0);
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        flags = r.readVarint();
      } else if (field == 2 && wire == 0) {
        offset = r.readVarint();
      } else if (field == 3 && wire == 2) {
        body = r.readBytes();
      } else {
        r.skipField(wire);
      }
    });
    return PayloadChunk(flags: flags, offset: offset, body: body);
  }
}

class ControlMessage {
  static const int eventPayloadError = 1;
  static const int eventPayloadCanceled = 2;
  static const int eventPayloadReceivedAck = 3;

  final int event;
  final int? offset;

  ControlMessage({required this.event, this.offset});

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, event);
    w.writeInt64Field(2, offset);
    return w.toBytes();
  }

  static ControlMessage parse(Uint8List bytes) {
    var ev = 0;
    int? offset;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        ev = r.readVarint();
      } else if (field == 2 && wire == 0) {
        offset = r.readVarint();
      } else {
        r.skipField(wire);
      }
    });
    return ControlMessage(event: ev, offset: offset);
  }
}

class PayloadTransferFrame {
  static const int packetData = 1;
  static const int packetControl = 2;
  static const int packetAck = 3;

  final int packetType;
  final PayloadHeader? payloadHeader;
  final PayloadChunk? payloadChunk;
  final ControlMessage? controlMessage;

  PayloadTransferFrame({
    required this.packetType,
    this.payloadHeader,
    this.payloadChunk,
    this.controlMessage,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, packetType);
    if (payloadHeader != null) {
      w.writeBytesField(2, payloadHeader!.toBytes());
    }
    if (payloadChunk != null) {
      w.writeBytesField(3, payloadChunk!.toBytes());
    }
    if (controlMessage != null) {
      w.writeBytesField(4, controlMessage!.toBytes());
    }
    return w.toBytes();
  }

  static PayloadTransferFrame parse(Uint8List bytes) {
    var pt = 0;
    PayloadHeader? hdr;
    PayloadChunk? chunk;
    ControlMessage? ctrl;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        pt = r.readVarint();
      } else if (field == 2 && wire == 2) {
        hdr = PayloadHeader.parse(r.readBytes());
      } else if (field == 3 && wire == 2) {
        chunk = PayloadChunk.parse(r.readBytes());
      } else if (field == 4 && wire == 2) {
        ctrl = ControlMessage.parse(r.readBytes());
      } else {
        r.skipField(wire);
      }
    });
    return PayloadTransferFrame(
      packetType: pt,
      payloadHeader: hdr,
      payloadChunk: chunk,
      controlMessage: ctrl,
    );
  }
}

// ---------------------------------------------------------------------------
// wire_format.proto (nearby.sharing.service.proto)
// ---------------------------------------------------------------------------

class SharingFrameType {
  static const int unknown = 0;
  static const int introduction = 1;
  static const int response = 2;
  static const int pairedKeyEncryption = 3;
  static const int pairedKeyResult = 4;
  static const int cancel = 6;
}

class SharingFileType {
  static const int unknown = 0;
  static const int image = 1;
  static const int video = 2;
  static const int androidApp = 3;
  static const int audio = 4;
  static const int document = 5;
  static const int contactCard = 6;
}

class SharingFileMetadata {
  final String name;
  final int type;
  final int payloadId;
  final int size;
  final String mimeType;
  final int id;

  SharingFileMetadata({
    required this.name,
    this.type = SharingFileType.unknown,
    required this.payloadId,
    required this.size,
    this.mimeType = 'application/octet-stream',
    this.id = 0,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeStringField(1, name);
    w.writeInt32Field(2, type);
    w.writeInt64Field(3, payloadId);
    w.writeInt64Field(4, size);
    w.writeStringField(5, mimeType);
    w.writeInt64Field(6, id);
    return w.toBytes();
  }

  static SharingFileMetadata parse(Uint8List bytes) {
    var name = '';
    var type = 0;
    var payloadId = 0;
    var size = 0;
    var mime = 'application/octet-stream';
    var id = 0;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 2) {
        name = r.readString();
      } else if (field == 2 && wire == 0) {
        type = r.readVarint();
      } else if (field == 3 && wire == 0) {
        payloadId = r.readVarint();
      } else if (field == 4 && wire == 0) {
        size = r.readVarint();
      } else if (field == 5 && wire == 2) {
        mime = r.readString();
      } else if (field == 6 && wire == 0) {
        id = r.readVarint();
      } else {
        r.skipField(wire);
      }
    });
    return SharingFileMetadata(
      name: name,
      type: type,
      payloadId: payloadId,
      size: size,
      mimeType: mime,
      id: id,
    );
  }
}

class SharingTextMetadata {
  static const int typeUnknown = 0;
  static const int typeText = 1;
  static const int typeUrl = 2;
  static const int typeAddress = 3;
  static const int typePhoneNumber = 4;

  final String textTitle;
  final int type;
  final int payloadId;
  final int size;
  final int id;

  SharingTextMetadata({
    required this.textTitle,
    required this.type,
    required this.payloadId,
    required this.size,
    this.id = 0,
  });

  String get typeName => switch (type) {
        typeText => 'TEXT',
        typeUrl => 'URL',
        typeAddress => 'ADDRESS',
        typePhoneNumber => 'PHONE_NUMBER',
        _ => 'UNKNOWN',
      };

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeStringField(2, textTitle);
    w.writeInt32Field(3, type);
    w.writeInt64Field(4, payloadId);
    w.writeInt64Field(5, size);
    w.writeInt64Field(6, id);
    return w.toBytes();
  }

  static SharingTextMetadata parse(Uint8List bytes) {
    var title = '';
    var type = 0;
    var payloadId = 0;
    var size = 0;
    var id = 0;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 2 && wire == 2) {
        title = r.readString();
      } else if (field == 3 && wire == 0) {
        type = r.readVarint();
      } else if (field == 4 && wire == 0) {
        payloadId = r.readVarint();
      } else if (field == 5 && wire == 0) {
        size = r.readVarint();
      } else if (field == 6 && wire == 0) {
        id = r.readVarint();
      } else {
        r.skipField(wire);
      }
    });
    return SharingTextMetadata(
      textTitle: title,
      type: type,
      payloadId: payloadId,
      size: size,
      id: id,
    );
  }
}

class IntroductionFrame {
  final List<SharingFileMetadata> fileMetadata;
  final List<SharingTextMetadata> textMetadata;
  final bool startTransfer;

  IntroductionFrame({
    this.fileMetadata = const [],
    this.textMetadata = const [],
    this.startTransfer = true,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    for (final fm in fileMetadata) {
      w.writeBytesField(1, fm.toBytes());
    }
    for (final tm in textMetadata) {
      w.writeBytesField(2, tm.toBytes());
    }
    w.writeBoolField(6, startTransfer);
    return w.toBytes();
  }

  static IntroductionFrame parse(Uint8List bytes) {
    final files = <SharingFileMetadata>[];
    final texts = <SharingTextMetadata>[];
    var start = false;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 2) {
        files.add(SharingFileMetadata.parse(r.readBytes()));
      } else if (field == 2 && wire == 2) {
        texts.add(SharingTextMetadata.parse(r.readBytes()));
      } else if (field == 6 && wire == 0) {
        start = r.readVarint() != 0;
      } else {
        r.skipField(wire);
      }
    });
    return IntroductionFrame(
      fileMetadata: files,
      textMetadata: texts,
      startTransfer: start,
    );
  }
}

class SharingConnectionResponseFrame {
  static const int statusUnknown = 0;
  static const int statusAccept = 1;
  static const int statusReject = 2;
  static const int statusNotEnoughSpace = 3;
  static const int statusUnsupportedAttachmentType = 4;
  static const int statusTimedOut = 5;

  final int status;

  SharingConnectionResponseFrame({required this.status});

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, status);
    return w.toBytes();
  }

  static SharingConnectionResponseFrame parse(Uint8List bytes) {
    var status = 0;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        status = r.readVarint();
      } else {
        r.skipField(wire);
      }
    });
    return SharingConnectionResponseFrame(status: status);
  }
}

class PairedKeyEncryptionFrame {
  final Uint8List signedData;
  final Uint8List secretIdHash;

  PairedKeyEncryptionFrame({
    required this.signedData,
    required this.secretIdHash,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeBytesField(1, signedData);
    w.writeBytesField(2, secretIdHash);
    return w.toBytes();
  }

  static PairedKeyEncryptionFrame parse(Uint8List bytes) {
    var sd = Uint8List(0);
    var hash = Uint8List(0);
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 2) {
        sd = r.readBytes();
      } else if (field == 2 && wire == 2) {
        hash = r.readBytes();
      } else {
        r.skipField(wire);
      }
    });
    return PairedKeyEncryptionFrame(signedData: sd, secretIdHash: hash);
  }
}

class PairedKeyResultFrame {
  static const int statusUnknown = 0;
  static const int statusSuccess = 1;
  static const int statusFail = 2;
  static const int statusUnable = 3;

  final int status;
  final int? osType;

  PairedKeyResultFrame({required this.status, this.osType});

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, status);
    w.writeInt32Field(2, osType);
    return w.toBytes();
  }

  static PairedKeyResultFrame parse(Uint8List bytes) {
    var st = 0;
    int? os;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        st = r.readVarint();
      } else if (field == 2 && wire == 0) {
        os = r.readVarint();
      } else {
        r.skipField(wire);
      }
    });
    return PairedKeyResultFrame(status: st, osType: os);
  }
}

class SharingV1Frame {
  final int type;
  final IntroductionFrame? introduction;
  final SharingConnectionResponseFrame? connectionResponse;
  final PairedKeyEncryptionFrame? pairedKeyEncryption;
  final PairedKeyResultFrame? pairedKeyResult;

  SharingV1Frame({
    required this.type,
    this.introduction,
    this.connectionResponse,
    this.pairedKeyEncryption,
    this.pairedKeyResult,
  });

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, type);
    if (introduction != null) {
      w.writeBytesField(2, introduction!.toBytes());
    }
    if (connectionResponse != null) {
      w.writeBytesField(3, connectionResponse!.toBytes());
    }
    if (pairedKeyEncryption != null) {
      w.writeBytesField(4, pairedKeyEncryption!.toBytes());
    }
    if (pairedKeyResult != null) {
      w.writeBytesField(5, pairedKeyResult!.toBytes());
    }
    return w.toBytes();
  }

  static SharingV1Frame parse(Uint8List bytes) {
    var type = 0;
    IntroductionFrame? intro;
    SharingConnectionResponseFrame? resp;
    PairedKeyEncryptionFrame? pke;
    PairedKeyResultFrame? pkr;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        type = r.readVarint();
      } else if (field == 2 && wire == 2) {
        intro = IntroductionFrame.parse(r.readBytes());
      } else if (field == 3 && wire == 2) {
        resp = SharingConnectionResponseFrame.parse(r.readBytes());
      } else if (field == 4 && wire == 2) {
        pke = PairedKeyEncryptionFrame.parse(r.readBytes());
      } else if (field == 5 && wire == 2) {
        pkr = PairedKeyResultFrame.parse(r.readBytes());
      } else {
        r.skipField(wire);
      }
    });
    return SharingV1Frame(
      type: type,
      introduction: intro,
      connectionResponse: resp,
      pairedKeyEncryption: pke,
      pairedKeyResult: pkr,
    );
  }
}

class SharingFrame {
  static const int versionV1 = 1;

  final int version;
  final SharingV1Frame? v1;

  SharingFrame({this.version = versionV1, this.v1});

  Uint8List toBytes() {
    final w = ProtoWriter();
    w.writeInt32Field(1, version);
    if (v1 != null) {
      w.writeBytesField(2, v1!.toBytes());
    }
    return w.toBytes();
  }

  static SharingFrame parse(Uint8List bytes) {
    var ver = 0;
    SharingV1Frame? v1;
    final r = ProtoReader(bytes);
    r.forEachField((field, wire) {
      if (field == 1 && wire == 0) {
        ver = r.readVarint();
      } else if (field == 2 && wire == 2) {
        v1 = SharingV1Frame.parse(r.readBytes());
      } else {
        r.skipField(wire);
      }
    });
    return SharingFrame(version: ver, v1: v1);
  }
}
