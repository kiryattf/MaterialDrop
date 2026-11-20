import 'dart:convert';

enum TransferProtocol { materialDrop, lan, quickShare, tapProximity }

enum DeviceKind { pc, phone, tablet, usb, unknown }

enum TransferDirection { incoming, outgoing }

enum AppThemeStyle { system, light, dark, oled }

class NearbyDevice {
  final String id;
  final String name;
  final String ip;
  final int port;
  final DeviceKind kind;
  final TransferProtocol protocol;
  final bool isUsb;
  final String? endpointId;
  final String? instanceId;
  final String? channelId;
  final String? tlsFingerprint;
  final bool useHttps;
  final int? rssi;
  final String? proximityZone;
  final DateTime lastSeen;

  const NearbyDevice({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    required this.kind,
    required this.protocol,
    required this.isUsb,
    required this.lastSeen,
    this.endpointId,
    this.instanceId,
    this.channelId,
    this.tlsFingerprint,
    this.useHttps = false,
    this.rssi,
    this.proximityZone,
  });

  NearbyDevice copyWith({
    String? id,
    String? name,
    String? ip,
    int? port,
    DeviceKind? kind,
    TransferProtocol? protocol,
    bool? isUsb,
    String? endpointId,
    String? instanceId,
    String? channelId,
    String? tlsFingerprint,
    bool? useHttps,
    int? rssi,
    String? proximityZone,
    DateTime? lastSeen,
  }) {
    return NearbyDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      kind: kind ?? this.kind,
      protocol: protocol ?? this.protocol,
      isUsb: isUsb ?? this.isUsb,
      endpointId: endpointId ?? this.endpointId,
      instanceId: instanceId ?? this.instanceId,
      channelId: channelId ?? this.channelId,
      tlsFingerprint: tlsFingerprint ?? this.tlsFingerprint,
      useHttps: useHttps ?? this.useHttps,
      rssi: rssi ?? this.rssi,
      proximityZone: proximityZone ?? this.proximityZone,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}

class StagedFile {
  final String name;
  final int size;
  final String mimeType;
  final String? path;
  final String? contentUri;
  final String? relativePath;

  const StagedFile({
    required this.name,
    required this.size,
    required this.mimeType,
    this.path,
    this.contentUri,
    this.relativePath,
  });

  String get displayName =>
      (relativePath != null && relativePath!.isNotEmpty) ? relativePath! : name;

  String get extension {
    final idx = name.lastIndexOf('.');
    if (idx <= 0 || idx == name.length - 1) return '';
    return name.substring(idx + 1).toUpperCase();
  }
}

class ShareLaunchPayload {
  final bool isShareSheet;
  final List<StagedFile> files;
  final String? sharedText;

  const ShareLaunchPayload({
    required this.isShareSheet,
    required this.files,
    this.sharedText,
  });
}

sealed class OutgoingTransferState {
  const OutgoingTransferState();
}

final class OutgoingIdle extends OutgoingTransferState {
  const OutgoingIdle();
}

final class OutgoingConnecting extends OutgoingTransferState {
  final String deviceName;
  final TransferProtocol protocol;
  const OutgoingConnecting({
    required this.deviceName,
    required this.protocol,
  });
}

final class OutgoingPinReady extends OutgoingTransferState {
  final String deviceName;
  final String pin;
  const OutgoingPinReady({
    required this.deviceName,
    required this.pin,
  });
}

final class OutgoingTransferring extends OutgoingTransferState {
  final String deviceName;
  final String fileName;
  final double progress;
  final int bytesSent;
  final int totalBytes;
  final double speedBps;
  final String? pin;
  final TransferProtocol protocol;

  const OutgoingTransferring({
    required this.deviceName,
    required this.fileName,
    required this.progress,
    required this.bytesSent,
    required this.totalBytes,
    required this.speedBps,
    required this.protocol,
    this.pin,
  });
}

final class OutgoingCompleted extends OutgoingTransferState {
  final String deviceName;
  final String displayTitle;
  final int filesCount;
  const OutgoingCompleted({
    required this.deviceName,
    required this.displayTitle,
    required this.filesCount,
  });
}

final class OutgoingError extends OutgoingTransferState {
  final String message;
  const OutgoingError(this.message);
}

final class OutgoingCanceled extends OutgoingTransferState {
  const OutgoingCanceled();
}

class IncomingFileMeta {
  final String name;
  final int size;
  final String mimeType;
  final String? relativePath;

  const IncomingFileMeta({
    required this.name,
    required this.size,
    required this.mimeType,
    this.relativePath,
  });
}

class IncomingTextItem {
  final String title;
  final String body;
  final String typeName;

  const IncomingTextItem({
    required this.title,
    required this.body,
    required this.typeName,
  });
}

class IncomingTransferItem {
  final String name;
  final int size;
  final String mimeType;
  final String savedPathOrUri;

  const IncomingTransferItem({
    required this.name,
    required this.size,
    required this.mimeType,
    required this.savedPathOrUri,
  });
}

class IncomingOffer {
  final String id;
  final String senderName;
  final String senderAddress;
  final TransferProtocol protocol;
  final String? pin;
  final List<IncomingFileMeta> files;
  final List<IncomingTextItem> texts;
  final int totalSize;
  final bool isTrusted;
  final bool isUsb;

  const IncomingOffer({
    required this.id,
    required this.senderName,
    required this.senderAddress,
    required this.protocol,
    required this.files,
    required this.texts,
    required this.totalSize,
    required this.isTrusted,
    required this.isUsb,
    this.pin,
  });
}

sealed class IncomingTransferState {
  const IncomingTransferState();
}

final class IncomingIdle extends IncomingTransferState {
  const IncomingIdle();
}

final class IncomingOfferPending extends IncomingTransferState {
  final IncomingOffer offer;
  const IncomingOfferPending(this.offer);
}

final class IncomingReceiving extends IncomingTransferState {
  final IncomingOffer offer;
  final String currentFileName;
  final double progress;
  final int bytesReceived;
  final int totalBytes;
  final double speedBps;

  const IncomingReceiving({
    required this.offer,
    required this.currentFileName,
    required this.progress,
    required this.bytesReceived,
    required this.totalBytes,
    required this.speedBps,
  });
}

final class IncomingCompleted extends IncomingTransferState {
  final IncomingOffer offer;
  final List<IncomingTransferItem> savedItems;
  final List<IncomingTextItem> receivedTexts;

  const IncomingCompleted({
    required this.offer,
    required this.savedItems,
    required this.receivedTexts,
  });
}

final class IncomingError extends IncomingTransferState {
  final String message;
  const IncomingError(this.message);
}

class HistoryEntry {
  final String id;
  final String fileName;
  final int size;
  final String mimeType;
  final String pathOrUri;
  final String peerName;
  final TransferDirection direction;
  final TransferProtocol protocol;
  final DateTime timestamp;
  final bool isText;
  final String? textBody;

  const HistoryEntry({
    required this.id,
    required this.fileName,
    required this.size,
    required this.mimeType,
    required this.pathOrUri,
    required this.peerName,
    required this.direction,
    required this.protocol,
    required this.timestamp,
    this.isText = false,
    this.textBody,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'size': size,
        'mimeType': mimeType,
        'pathOrUri': pathOrUri,
        'peerName': peerName,
        'direction': direction.name,
        'protocol': protocol.name,
        'timestamp': timestamp.toIso8601String(),
        'isText': isText,
        'textBody': textBody,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    return HistoryEntry(
      id: json['id'] as String? ?? '',
      fileName: json['fileName'] as String? ?? 'file',
      size: (json['size'] as num?)?.toInt() ?? 0,
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      pathOrUri: json['pathOrUri'] as String? ?? '',
      peerName: json['peerName'] as String? ?? 'Device',
      direction: TransferDirection.values.firstWhere(
        (e) => e.name == json['direction'],
        orElse: () => TransferDirection.incoming,
      ),
      protocol: TransferProtocol.values.firstWhere(
        (e) => e.name == json['protocol'],
        orElse: () => TransferProtocol.materialDrop,
      ),
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.now(),
      isText: json['isText'] as bool? ?? false,
      textBody: json['textBody'] as String?,
    );
  }

  static String encodeList(List<HistoryEntry> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());

  static List<HistoryEntry> decodeList(String raw) {
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(HistoryEntry.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }
}

String formatFileSize(int bytes) {
  if (bytes < 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatSpeed(double bytesPerSec) {
  if (bytesPerSec <= 0) return '0 B/s';
  if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
  if (bytesPerSec < 1024 * 1024) {
    return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
  }
  return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
}

