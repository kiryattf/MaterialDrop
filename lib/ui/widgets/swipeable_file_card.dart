import 'dart:async';

import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../protocol/gesture/preview_extractor.dart';
import '../../services/sound_service.dart';
import '../../theme/app_theme.dart';
import '../motion/md3_springs.dart';

/// Expressive playing-card style file preview with spring-physics Swipe-to-Throw.
class SwipeableFileCard extends StatefulWidget {
  static const double throwThresholdPx = 115.0;

  final List<StagedFile> files;
  final NearbyDevice targetDevice;
  final AppStrings strings;
  final VoidCallback onThrowSuccess;
  final VoidCallback? onPreGestureTrigger;
  final void Function(double dragProgress)? onDragProgress;
  final VoidCallback? onPreGestureCancel;

  const SwipeableFileCard({
    super.key,
    required this.files,
    required this.targetDevice,
    required this.strings,
    required this.onThrowSuccess,
    this.onPreGestureTrigger,
    this.onDragProgress,
    this.onPreGestureCancel,
  });

  @override
  State<SwipeableFileCard> createState() => _SwipeableFileCardState();
}

class _SwipeableFileCardState extends State<SwipeableFileCard>
    with TickerProviderStateMixin {
  late final AnimationController _xCtrl;
  late final AnimationController _yCtrl;
  bool _thrown = false;
  bool _preTriggered = false;

  @override
  void initState() {
    super.initState();
    _xCtrl = AnimationController.unbounded(vsync: this, value: 0.0);
    _yCtrl = AnimationController.unbounded(vsync: this, value: 0.0);
    unawaited(PreviewExtractor.extractForStaged(widget.files));
  }

  @override
  void didUpdateWidget(covariant SwipeableFileCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.files != widget.files ||
        oldWidget.targetDevice.id != widget.targetDevice.id) {
      _resetCard();
      unawaited(PreviewExtractor.extractForStaged(widget.files));
    }
  }

  void _resetCard() {
    _thrown = false;
    _preTriggered = false;
    _xCtrl.value = 0.0;
    _yCtrl.value = 0.0;
  }

  @override
  void dispose() {
    _xCtrl.dispose();
    _yCtrl.dispose();
    super.dispose();
  }

  Future<void> _launchThrow({double initialVelocityY = -1800}) async {
    if (_thrown) return;
    _thrown = true;
    await SoundService.instance.haptic(HapticKind.heavy);

    _xCtrl.animateTo(
      0,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
    await _yCtrl.animateTo(
      -900,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
    if (mounted) {
      widget.onThrowSuccess();
    }
  }

  void _snapBack(Velocity velocity) {
    if (_preTriggered) {
      _preTriggered = false;
      widget.onPreGestureCancel?.call();
    }
    final simX = SpringSimulation(
      Md3Springs.bouncySpatial,
      _xCtrl.value,
      0.0,
      velocity.pixelsPerSecond.dx * 0.35,
    );
    final simY = SpringSimulation(
      Md3Springs.bouncySpatial,
      _yCtrl.value,
      0.0,
      velocity.pixelsPerSecond.dy * 0.35,
    );
    _xCtrl.animateWith(simX);
    _yCtrl.animateWith(simY);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final totalBytes = widget.files.fold<int>(0, (s, f) => s + f.size);
    final first = widget.files.isNotEmpty ? widget.files.first : null;
    final ext = first?.extension ?? '';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Launch hint header
        Text(
          widget.strings.tr('swipe_hint'),
          style: textTheme.labelLarge?.copyWith(
            color: scheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          widget.strings.tr('swipe_target', {'device': widget.targetDevice.name}),
          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),

        // Interactive draggable playing card
        GestureDetector(
          onPanStart: (_) {
            if (_thrown) return;
            _xCtrl.stop();
            _yCtrl.stop();
          },
          onPanUpdate: (details) {
            if (_thrown) return;
            _xCtrl.value += details.delta.dx * 0.78;
            _yCtrl.value += details.delta.dy * 0.88;
            final dragProgress =
                (-_yCtrl.value / SwipeableFileCard.throwThresholdPx)
                    .clamp(0.0, 1.0);
            if (!_preTriggered && dragProgress >= 0.20) {
              _preTriggered = true;
              unawaited(HapticFeedback.heavyImpact());
              widget.onPreGestureTrigger?.call();
            } else if (_preTriggered) {
              widget.onDragProgress?.call(dragProgress);
            }
          },
          onPanCancel: () {
            if (!_thrown) _snapBack(Velocity.zero);
          },
          onPanEnd: (details) {
            if (_thrown) return;
            final vy = details.velocity.pixelsPerSecond.dy;
            if (vy < -600 || _yCtrl.value < -SwipeableFileCard.throwThresholdPx) {
              _launchThrow(initialVelocityY: vy);
            } else {
              _snapBack(details.velocity);
            }
          },
          child: AnimatedBuilder(
            animation: Listenable.merge([_xCtrl, _yCtrl]),
            builder: (context, child) {
              final x = _xCtrl.value;
              final y = _yCtrl.value;
              final rotationZ = (x * 0.0011).clamp(-0.32, 0.32);

              final dragProg = (y / 400.0).clamp(-0.6, 0.4);
              final jellyY = y > 0 ? 1.0 + dragProg * 0.22 : 1.0 - dragProg * 0.16;
              final jellyX = y > 0 ? 1.0 - dragProg * 0.11 : 1.0 + dragProg * 0.10;
              final flyScale = y < 0 ? (1.0 + y / 1800.0).clamp(0.55, 1.0) : 1.0;
              final alpha = y < -200
                  ? (1.0 - ((-y - 200) / 360.0)).clamp(0.0, 1.0)
                  : 1.0;

              return Opacity(
                opacity: alpha,
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..translateByDouble(x, y, 0.0, 1.0)
                    ..rotateZ(rotationZ)
                    ..scaleByDouble(
                      jellyX * flyScale,
                      jellyY * flyScale,
                      1.0,
                      1.0,
                    ),
                  child: child,
                ),
              );
            },
            child: Container(
              width: 256,
              height: 356,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(32),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.7),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.22),
                    blurRadius: 28,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Top header: status pill + file size
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            widget.files.length > 1
                                ? widget.strings.tr(
                                    'package_badge',
                                    {'count': '${widget.files.length}'},
                                  )
                                : widget.strings.tr('ready_to_send'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatFileSize(totalBytes),
                        style: textTheme.labelSmall?.tabular.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),

                  // Center artwork container
                  Container(
                    width: 136,
                    height: 136,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          scheme.surfaceContainerHighest,
                          scheme.primaryContainer.withValues(alpha: 0.45),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          widget.files.length > 1
                              ? Icons.inventory_2_rounded
                              : _iconForExt(ext),
                          size: 52,
                          color: scheme.primary,
                        ),
                        if (ext.isNotEmpty && widget.files.length == 1) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primary.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              ext,
                              style: textTheme.labelSmall?.copyWith(
                                color: scheme.primary,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // File name & MIME
                  Column(
                    children: [
                      Text(
                        widget.files.length > 1
                            ? widget.strings.tr(
                                'files_count',
                                {'count': '${widget.files.length}'},
                              )
                            : (first?.name ?? ''),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.files.length > 1
                            ? '${first?.name ?? ""} (+${widget.files.length - 1})'
                            : (first?.mimeType ?? ''),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),

                  // Bottom swipe cue pill
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.keyboard_arrow_up_rounded,
                          size: 18,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            widget.strings.tr('swipe_subhint'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 16),
        FilledButton.tonalIcon(
          onPressed: () => _launchThrow(),
          icon: const Icon(Icons.send_rounded, size: 18),
          label: Text(widget.strings.tr('send_now')),
        ),
      ],
    );
  }

  IconData _iconForExt(String ext) {
    return switch (ext.toLowerCase()) {
      'jpg' || 'jpeg' || 'png' || 'webp' || 'gif' || 'bmp' =>
        Icons.image_rounded,
      'mp4' || 'mkv' || 'mov' || 'webm' => Icons.movie_rounded,
      'mp3' || 'wav' || 'flac' || 'ogg' => Icons.music_note_rounded,
      'pdf' => Icons.picture_as_pdf_rounded,
      'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.folder_zip_rounded,
      'apk' => Icons.android_rounded,
      _ => Icons.insert_drive_file_rounded,
    };
  }
}

