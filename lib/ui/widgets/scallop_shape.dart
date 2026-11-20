import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Material 3 Expressive 12-lobe Scalloped Flower Shape.
class ScallopBorder extends OutlinedBorder {
  final int lobes;
  final double depth;

  const ScallopBorder({
    this.lobes = 12,
    this.depth = 0.14,
    super.side,
  });

  Path _buildPath(Rect rect) {
    final path = Path();
    final cx = rect.center.dx;
    final cy = rect.center.dy;
    final baseR = math.min(rect.width, rect.height) / 2.0;
    final steps = lobes * 10;

    for (var i = 0; i <= steps; i++) {
      final angle = (i / steps) * 2.0 * math.pi;
      final r = baseR * (1.0 - depth * (0.5 + 0.5 * math.cos(lobes * angle)));
      final x = cx + r * math.cos(angle);
      final y = cy + r * math.sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  @override
  OutlinedBorder copyWith({BorderSide? side}) {
    return ScallopBorder(
      lobes: lobes,
      depth: depth,
      side: side ?? this.side,
    );
  }

  @override
  ShapeBorder scale(double t) {
    return ScallopBorder(
      lobes: lobes,
      depth: depth,
      side: side.scale(t),
    );
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    return _buildPath(rect.deflate(side.strokeInset));
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return _buildPath(rect);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style != BorderStyle.none && side.width > 0) {
      final paint = side.toPaint();
      canvas.drawPath(getInnerPath(rect), paint);
    }
  }
}

