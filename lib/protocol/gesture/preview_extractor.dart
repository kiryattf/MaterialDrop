import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../models/models.dart';
import '../../services/platform_bridge.dart';

class ExtractedPreview {
  final int dominantColor;
  final Uint8List? thumbnailBytes;

  const ExtractedPreview({
    required this.dominantColor,
    this.thumbnailBytes,
  });
}

/// Fast hardware-accelerated 32x32 thumbnail + 8x8/32x32 dominant color extractor.
class PreviewExtractor {
  PreviewExtractor._();

  static final Map<String, ExtractedPreview> _cache = {};

  static String _cacheKey(List<StagedFile> files) {
    if (files.isEmpty) return '';
    final f = files.first;
    return '${f.name}:${f.size}:${files.length}:${f.path ?? f.contentUri ?? ''}';
  }

  static Future<ExtractedPreview> extractForStaged(
    List<StagedFile> files,
  ) async {
    if (files.isEmpty) {
      return const ExtractedPreview(dominantColor: 0xFF6750A4);
    }
    final key = _cacheKey(files);
    final cached = _cache[key];
    if (cached != null) return cached;

    final primary = files.first;
    final lowerMime = primary.mimeType.toLowerCase();
    final isImage = lowerMime.startsWith('image/') && !lowerMime.contains('svg');

    ExtractedPreview result;
    if (isImage) {
      result = await _extractImagePreview(primary) ??
          ExtractedPreview(dominantColor: fallbackColorForMime(lowerMime));
    } else {
      result = ExtractedPreview(dominantColor: fallbackColorForMime(lowerMime));
    }

    if (_cache.length > 24) {
      _cache.clear();
    }
    _cache[key] = result;
    return result;
  }

  static int fallbackColorForMime(String mime) {
    final lower = mime.toLowerCase();
    if (lower.startsWith('image/')) return 0xFF7C4DFF;
    if (lower.startsWith('video/')) return 0xFFE91E63;
    if (lower.startsWith('audio/')) return 0xFF00BFA5;
    if (lower.contains('pdf')) return 0xFFE53935;
    if (lower.contains('zip') || lower.contains('archive')) return 0xFFFF9100;
    if (lower.startsWith('text/')) return 0xFF2979FF;
    return 0xFF6750A4;
  }

  static Future<ExtractedPreview?> _extractImagePreview(StagedFile file) async {
    try {
      Uint8List? rawBytes;
      if (file.path != null && file.path!.isNotEmpty) {
        final f = File(file.path!);
        if (await f.exists() && await f.length() <= 32 * 1024 * 1024) {
          rawBytes = await f.readAsBytes();
        }
      } else if (file.contentUri != null && file.contentUri!.isNotEmpty) {
        if (file.size <= 16 * 1024 * 1024) {
          final builder = BytesBuilder(copy: false);
          await for (final chunk
              in PlatformBridge.instance.openFileReadStream(file)) {
            builder.add(chunk);
            if (builder.length > 16 * 1024 * 1024) return null;
          }
          rawBytes = builder.toBytes();
        }
      }
      if (rawBytes == null || rawBytes.isEmpty) return null;

      final codec = await ui.instantiateImageCodec(
        rawBytes,
        targetWidth: 32,
        targetHeight: 32,
      );
      final frame = await codec.getNextFrame();
      final img = frame.image;
      try {
        final rgbaData =
            await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        final pngData = await img.toByteData(format: ui.ImageByteFormat.png);

        final color = rgbaData != null
            ? computeDominantColorFromRgba(rgbaData.buffer.asUint8List())
            : 0xFF7C4DFF;
        return ExtractedPreview(
          dominantColor: color,
          thumbnailBytes: pngData?.buffer.asUint8List(),
        );
      } finally {
        img.dispose();
        codec.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  /// Quantized vivid-weighted RGB dominant color extraction from RGBA pixels.
  static int computeDominantColorFromRgba(Uint8List rgba) {
    if (rgba.length < 4) return 0xFF6750A4;
    final buckets = <int, double>{};
    final rSum = <int, double>{};
    final gSum = <int, double>{};
    final bSum = <int, double>{};

    for (var i = 0; i + 3 < rgba.length; i += 4) {
      final r = rgba[i];
      final g = rgba[i + 1];
      final b = rgba[i + 2];
      final a = rgba[i + 3];
      if (a < 96) continue;

      final maxC = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final minC = r < g ? (r < b ? r : b) : (g < b ? g : b);
      final sat = maxC > 0 ? (maxC - minC) / maxC : 0.0;
      final weight = 1.0 + sat * 3.5;

      // 4-bit per channel quantized bucket (4096 bins)
      final key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
      buckets[key] = (buckets[key] ?? 0) + weight;
      rSum[key] = (rSum[key] ?? 0) + r * weight;
      gSum[key] = (gSum[key] ?? 0) + g * weight;
      bSum[key] = (bSum[key] ?? 0) + b * weight;
    }

    if (buckets.isEmpty) return 0xFF6750A4;
    var bestKey = buckets.keys.first;
    var bestScore = -1.0;
    for (final e in buckets.entries) {
      if (e.value > bestScore) {
        bestScore = e.value;
        bestKey = e.key;
      }
    }

    final totalW = buckets[bestKey]!;
    final r = (rSum[bestKey]! / totalW).round().clamp(0, 255);
    final g = (gSum[bestKey]! / totalW).round().clamp(0, 255);
    final b = (bSum[bestKey]! / totalW).round().clamp(0, 255);
    return (0xFF << 24) | (r << 16) | (g << 8) | b;
  }
}
