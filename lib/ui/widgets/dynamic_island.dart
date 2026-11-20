import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../protocol/gesture/gesture_models.dart';
import '../../protocol/transfer_coordinator.dart';
import '../../services/settings_controller.dart';

/// Cached GPU FragmentShader program for `shaders/liquid_glass.frag`.
class LiquidGlassShaderCache {
  LiquidGlassShaderCache._();

  static ui.FragmentProgram? _program;
  static bool _loadAttempted = false;

  static ui.FragmentProgram? get program => _program;

  static Future<ui.FragmentProgram?> ensureLoaded() async {
    if (_program != null) return _program;
    if (_loadAttempted) return null;
    _loadAttempted = true;
    try {
      _program = await ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag');
    } catch (_) {
      _program = null;
    }
    return _program;
  }
}

/// Sealed state machine driving both the in-app GPU Liquid Glass Dynamic Island
/// and the borderless OS Desktop Dynamic Island window.
sealed class DynamicIslandState {
  const DynamicIslandState();
}

final class IslandHidden extends DynamicIslandState {
  const IslandHidden();
}

final class IslandPreGesturePeek extends DynamicIslandState {
  final GesturePreviewEvent preview;
  const IslandPreGesturePeek(this.preview);
}

final class IslandOffer extends DynamicIslandState {
  final IncomingOffer offer;
  final int dominantColor;
  final Uint8List? thumbnailBytes;

  const IslandOffer({
    required this.offer,
    required this.dominantColor,
    this.thumbnailBytes,
  });
}

final class IslandProgress extends DynamicIslandState {
  final IncomingOffer offer;
  final String fileName;
  final double progress;
  final int bytesReceived;
  final int totalBytes;
  final double speedBps;
  final int dominantColor;
  final Uint8List? thumbnailBytes;

  const IslandProgress({
    required this.offer,
    required this.fileName,
    required this.progress,
    required this.bytesReceived,
    required this.totalBytes,
    required this.speedBps,
    required this.dominantColor,
    this.thumbnailBytes,
  });
}

final class IslandCompleted extends DynamicIslandState {
  final IncomingCompleted completed;
  final int dominantColor;
  final Uint8List? thumbnailBytes;

  const IslandCompleted({
    required this.completed,
    required this.dominantColor,
    this.thumbnailBytes,
  });
}

/// GPU-accelerated Liquid Glass capsule painter without full-screen [BackdropFilter].
class LiquidGlassPainter extends CustomPainter {
  final ui.FragmentProgram? program;
  final double timeSeconds;
  final double morphProgress;
  final Color accentColor;
  final bool isDark;

  LiquidGlassPainter({
    required this.program,
    required this.timeSeconds,
    required this.morphProgress,
    required this.accentColor,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (program != null) {
      final shader = program!.fragmentShader();
      shader.setFloat(0, size.width);
      shader.setFloat(1, size.height);
      shader.setFloat(2, timeSeconds);
      shader.setFloat(3, morphProgress.clamp(0.0, 1.0));
      shader.setFloat(4, accentColor.r);
      shader.setFloat(5, accentColor.g);
      shader.setFloat(6, accentColor.b);
      shader.setFloat(7, isDark ? 1.0 : 0.0);

      final paint = Paint()..shader = shader;
      canvas.drawRect(rect, paint);
      return;
    }

    // Fallback painter when shader program is not yet warm or unavailable in headless test
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(size.height * 0.5),
    );
    final base = isDark ? const Color(0xE614161D) : const Color(0xE6F4F6FB);
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = Color.lerp(base, accentColor, 0.14)!
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      rrect.deflate(1),
      Paint()
        ..color = accentColor.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  @override
  bool shouldRepaint(covariant LiquidGlassPainter oldDelegate) {
    return oldDelegate.program != program ||
        oldDelegate.morphProgress != morphProgress ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.isDark != isDark ||
        (oldDelegate.timeSeconds - timeSeconds).abs() > 0.015;
  }
}

/// Overlay rendering the Liquid Glass Dynamic Island inside the Flutter viewport
/// at the user-configured [IslandPosition] (`topCenter` or `bottomCenter`),
/// wrapped in [RepaintBoundary] to cache textures when stationary.
class DynamicIslandOverlay extends StatefulWidget {
  final TransferCoordinator coordinator;
  final SettingsController settings;
  final VoidCallback? onOpenReceive;
  final void Function(IncomingCompleted)? onOpenFile;
  final void Function(IncomingCompleted)? onShowFolder;
  final void Function(IncomingCompleted)? onCopy;

  const DynamicIslandOverlay({
    super.key,
    required this.coordinator,
    required this.settings,
    this.onOpenReceive,
    this.onOpenFile,
    this.onShowFolder,
    this.onCopy,
  });

  @override
  State<DynamicIslandOverlay> createState() => _DynamicIslandOverlayState();
}

class _DynamicIslandOverlayState extends State<DynamicIslandOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _springCtrl;
  late final AnimationController _pulseCtrl;
  ui.FragmentProgram? _program;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _springCtrl = AnimationController.unbounded(vsync: this, value: 0.0);
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    );
    unawaited(LiquidGlassShaderCache.ensureLoaded().then((p) {
      if (mounted && p != null) {
        setState(() => _program = p);
      }
    }));
    widget.coordinator.addListener(_syncAnimation);
    _syncAnimation();
  }

  void _syncAnimation() {
    if (!mounted) return;
    final state = widget.coordinator.islandState;
    final shouldShow =
        widget.settings.islandEnabled && state is! IslandHidden;

    if (shouldShow && !_visible) {
      _visible = true;
      _springCtrl.animateWith(
        SpringSimulation(
          const SpringDescription(mass: 1.0, stiffness: 420.0, damping: 24.0),
          _springCtrl.value,
          1.0,
          2.2,
        ),
      );
      if (!_pulseCtrl.isAnimating && state is! IslandOffer) {
        _pulseCtrl.repeat();
      }
    } else if (!shouldShow && _visible) {
      _visible = false;
      _pulseCtrl.stop();
      _springCtrl.animateTo(
        0.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInCubic,
      );
    } else if (shouldShow) {
      // Freeze ambient shader pulse when resting idle on offer consent so RepaintBoundary stays cached
      if (state is IslandOffer) {
        _pulseCtrl.stop();
      } else if (!_pulseCtrl.isAnimating) {
        _pulseCtrl.repeat();
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.coordinator.removeListener(_syncAnimation);
    _springCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.coordinator.islandState;
    if (!widget.settings.islandEnabled) return const SizedBox.shrink();

    final isTop = widget.settings.islandPosition == IslandPosition.topCenter;
    final strings = widget.settings.strings;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: Listenable.merge([_springCtrl, _pulseCtrl]),
      builder: (context, child) {
        final t = _springCtrl.value.clamp(0.0, 1.18);
        if (!_visible && t <= 0.01) {
          return const SizedBox.shrink();
        }
        final dy = (isTop ? -44.0 : 44.0) * (1.0 - t.clamp(0.0, 1.0));
        final opacity = t.clamp(0.0, 1.0);

        return Align(
          alignment: isTop ? Alignment.topCenter : Alignment.bottomCenter,
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                top: isTop ? 12 : 0,
                bottom: isTop ? 0 : 14,
                left: 16,
                right: 16,
              ),
              child: Transform.translate(
                offset: Offset(0, dy),
                child: Transform.scale(
                  scale: 0.82 + 0.18 * t,
                  alignment: isTop ? Alignment.topCenter : Alignment.bottomCenter,
                  child: Opacity(
                    opacity: opacity,
                    child: RepaintBoundary(
                      child: Material(
                        color: Colors.transparent,
                        child: _buildIslandBody(
                          context,
                          strings,
                          state,
                          isDark,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildIslandBody(
    BuildContext context,
    AppStrings strings,
    DynamicIslandState state,
    bool isDark,
  ) {
    final (accent, morph, thumbBytes) = switch (state) {
      IslandPreGesturePeek(:final preview) => (
          Color(preview.dominantColor),
          preview.dragProgress.clamp(0.2, 1.0),
          preview.thumbnailBytes,
        ),
      IslandOffer(:final dominantColor, :final thumbnailBytes) => (
          Color(dominantColor),
          0.72,
          thumbnailBytes,
        ),
      IslandProgress(
        :final dominantColor,
        :final progress,
        :final thumbnailBytes,
      ) =>
        (Color(dominantColor), progress.clamp(0.3, 1.0), thumbnailBytes),
      IslandCompleted(:final dominantColor, :final thumbnailBytes) => (
          Color(dominantColor),
          1.0,
          thumbnailBytes,
        ),
      IslandHidden() => (Theme.of(context).colorScheme.primary, 0.0, null),
    };

    final fgColor = isDark ? Colors.white : const Color(0xFF161822);
    final subColor = isDark ? Colors.white70 : const Color(0xFF4A4E61);

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 460),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: CustomPaint(
          painter: LiquidGlassPainter(
            program: _program,
            timeSeconds: _pulseCtrl.value * 6.0,
            morphProgress: morph,
            accentColor: accent,
            isDark: isDark,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: _buildContentRow(
              context,
              strings,
              state,
              accent,
              thumbBytes,
              fgColor,
              subColor,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContentRow(
    BuildContext context,
    AppStrings strings,
    DynamicIslandState state,
    Color accent,
    Uint8List? thumbBytes,
    Color fgColor,
    Color subColor,
  ) {
    final avatar = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 34,
        height: 34,
        child: thumbBytes != null && thumbBytes.isNotEmpty
            ? Image.memory(
                thumbBytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.24),
                ),
                child: Icon(
                  state is IslandCompleted
                      ? Icons.check_circle_rounded
                      : Icons.downloading_rounded,
                  color: accent,
                  size: 20,
                ),
              ),
      ),
    );

    switch (state) {
      case IslandHidden():
        return const SizedBox.shrink();

      case IslandPreGesturePeek(:final preview):
        final title = preview.fileCount > 1
            ? '${preview.fileName} (+${preview.fileCount - 1})'
            : preview.fileName;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            avatar,
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fgColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    '${preview.senderName} • ${formatFileSize(preview.totalBytes)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: subColor, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                value: preview.dragProgress.clamp(0.2, 1.0),
                strokeWidth: 2.4,
                color: accent,
              ),
            ),
          ],
        );

      case IslandOffer(:final offer):
        final count = offer.files.length + offer.texts.length;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            avatar,
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    offer.pin != null
                        ? '${offer.senderName} • PIN ${offer.pin}'
                        : offer.senderName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fgColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    '$count • ${formatFileSize(offer.totalSize)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: subColor, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              visualDensity: VisualDensity.compact,
              tooltip: strings.tr('decline'),
              onPressed: widget.coordinator.declineIncoming,
              icon: const Icon(Icons.close_rounded, size: 17),
            ),
            const SizedBox(width: 4),
            FilledButton(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                backgroundColor: accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onPressed: () => widget.coordinator.acceptIncoming(),
              child: Text(strings.tr('accept')),
            ),
          ],
        );

      case IslandProgress(
          :final fileName,
          :final progress,
          :final speedBps,
        ):
        final pct = (progress * 100).round().clamp(0, 100);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            avatar,
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: fgColor,
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      Text(
                        '$pct% • ${formatSpeed(speedBps)}',
                        style: TextStyle(color: subColor, fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress > 0 ? progress : null,
                      minHeight: 4,
                      color: accent,
                      backgroundColor: accent.withValues(alpha: 0.2),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: strings.tr('cancel'),
              onPressed: widget.coordinator.cancelIncoming,
              icon: Icon(Icons.close_rounded, color: subColor, size: 17),
            ),
          ],
        );

      case IslandCompleted(:final completed):
        final firstFile = completed.savedItems.isNotEmpty
            ? completed.savedItems.first.name
            : (completed.receivedTexts.isNotEmpty
                ? completed.receivedTexts.first.body
                : completed.offer.senderName);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            avatar,
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    strings.tr('transfer_complete'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fgColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    firstFile,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: subColor, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: strings.tr('ctx_copy_path'),
              onPressed: () => widget.onCopy?.call(completed),
              icon: Icon(Icons.copy_rounded, color: fgColor, size: 17),
            ),
            if (completed.savedItems.isNotEmpty) ...[
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: strings.tr('open_file'),
                onPressed: () => widget.onOpenFile?.call(completed),
                icon: Icon(Icons.open_in_new_rounded, color: fgColor, size: 17),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: strings.tr('show_in_folder'),
                onPressed: () => widget.onShowFolder?.call(completed),
                icon: Icon(Icons.folder_open_rounded, color: fgColor, size: 17),
              ),
            ],
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: widget.coordinator.dismissIsland,
              icon: Icon(Icons.close_rounded, color: subColor, size: 16),
            ),
          ],
        );
    }
  }
}
