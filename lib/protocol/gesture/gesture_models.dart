import 'dart:convert';
import 'dart:typed_data';

/// Incoming or outgoing pre-gesture event transmitted over `/ws/gesture`.
class GesturePreviewEvent {
  final String eventType; // drop_gesture_trigger | drop_gesture_progress | drop_gesture_cancel
  final String senderName;
  final String fileName;
  final int fileCount;
  final int totalBytes;
  final String mimeType;
  final int dominantColor;
  final Uint8List? thumbnailBytes;
  final double dragProgress;

  const GesturePreviewEvent({
    required this.eventType,
    required this.senderName,
    required this.fileName,
    required this.fileCount,
    required this.totalBytes,
    required this.mimeType,
    required this.dominantColor,
    required this.dragProgress,
    this.thumbnailBytes,
  });

  bool get isCancel => eventType == 'drop_gesture_cancel';

  Map<String, dynamic> toJson() => {
        'type': eventType,
        'senderName': senderName,
        'fileName': fileName,
        'fileCount': fileCount,
        'totalBytes': totalBytes,
        'mimeType': mimeType,
        'dominantColor': dominantColor,
        'dragProgress': dragProgress,
        if (thumbnailBytes != null && thumbnailBytes!.isNotEmpty)
          'thumbnailBase64': base64Encode(thumbnailBytes!),
      };

  static GesturePreviewEvent? fromJsonString(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final type = map['type'] as String? ?? '';
      if (type != 'drop_gesture_trigger' &&
          type != 'drop_gesture_progress' &&
          type != 'drop_gesture_cancel') {
        return null;
      }
      final b64 = map['thumbnailBase64'] as String?;
      Uint8List? thumb;
      if (b64 != null && b64.isNotEmpty) {
        try {
          thumb = base64Decode(b64);
        } catch (_) {}
      }
      return GesturePreviewEvent(
        eventType: type,
        senderName: map['senderName'] as String? ?? 'Device',
        fileName: map['fileName'] as String? ?? 'file',
        fileCount: (map['fileCount'] as num?)?.toInt() ?? 1,
        totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
        mimeType: map['mimeType'] as String? ?? 'application/octet-stream',
        dominantColor: (map['dominantColor'] as num?)?.toInt() ?? 0xFF6750A4,
        dragProgress:
            ((map['dragProgress'] as num?)?.toDouble() ?? 0.2).clamp(0.0, 1.0),
        thumbnailBytes: thumb,
      );
    } catch (_) {
      return null;
    }
  }
}
