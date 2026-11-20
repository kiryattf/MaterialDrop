import 'dart:io';

import 'package:path/path.dart' as p;

class MdConstants {
  static const int udpPort = 45872;
  static const int pcHttpPort = 45873;
  static const int androidHttpPort = 45874;

  static int get localHttpPort =>
      Platform.isAndroid ? androidHttpPort : pcHttpPort;

  static int get remoteDefaultHttpPort =>
      Platform.isAndroid ? pcHttpPort : androidHttpPort;

  static const String magic = 'materialdrop';
  static const String legacyMagic = 'MATDROP_V1';

  static const Duration deviceTtl = Duration(seconds: 18);

  static String sanitizeFileName(String raw) {
    final nulIdx = raw.indexOf('\x00');
    final truncated = nulIdx >= 0 ? raw.substring(0, nulIdx) : raw;
    final normalized = truncated.replaceAll('\\', '/');
    final slashIdx = normalized.lastIndexOf('/');
    var base = slashIdx >= 0 ? normalized.substring(slashIdx + 1) : normalized;
    base = base.replaceFirst(RegExp(r'^\.+'), '');
    // Strip Windows-illegal filename characters while preserving spaces and Unicode
    base = base.replaceAll(RegExp(r'[<>:"|?*]'), '_').trim();
    return base.isEmpty ? 'unnamed_file' : base;
  }

  /// Sanitizes a slash-delimited relative path (preserving subdirectories for
  /// folder drops while blocking traversal, drive prefixes, and illegal chars).
  static String sanitizeRelativePath(String raw) {
    final nulIdx = raw.indexOf('\x00');
    final truncated = nulIdx >= 0 ? raw.substring(0, nulIdx) : raw;
    final parts = truncated
        .replaceAll('\\', '/')
        .split('/')
        .map((seg) => seg.trim())
        .where((seg) =>
            seg.isNotEmpty &&
            seg != '.' &&
            seg != '..' &&
            !RegExp(r'^[a-zA-Z]:$').hasMatch(seg))
        .map((seg) => seg
            .replaceFirst(RegExp(r'^\.+'), '')
            .replaceAll(RegExp(r'[<>:"|?*]'), '_')
            .trim())
        .where((seg) => seg.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'unnamed_file';
    return parts.join('/');
  }

  static String uniqueFilePath(String dir, String fileName) {
    final safe = sanitizeFileName(fileName);
    var candidate = p.join(dir, safe);
    if (!File(candidate).existsSync()) return candidate;
    final stem = p.basenameWithoutExtension(safe);
    final ext = p.extension(safe);
    var i = 1;
    while (File(candidate).existsSync()) {
      candidate = p.join(dir, '$stem ($i)$ext');
      i++;
    }
    return candidate;
  }
}

