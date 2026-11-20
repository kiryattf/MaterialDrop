import 'dart:io';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/models.dart';
import '../../protocol/proximity/proximity_bridge.dart';
import '../motion/md3_springs.dart';
import 'scallop_shape.dart';

class SonarRadar extends StatefulWidget {
  final List<NearbyDevice> devices;
  final bool Function(NearbyDevice device) isTrusted;
  final void Function(NearbyDevice device) onDeviceSelected;
  final String thisDeviceLabel;

  const SonarRadar({
    super.key,
    required this.devices,
    required this.isTrusted,
    required this.onDeviceSelected,
    required this.thisDeviceLabel,
  });

  @override
  State<SonarRadar> createState() => _SonarRadarState();
}

class _SonarRadarState extends State<SonarRadar> with TickerProviderStateMixin {
  late final AnimationController _sweepCtrl;
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _sweepCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    )..repeat();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _sweepCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = widget.devices.take(12).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math.min(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 340.0,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 340.0,
        ).clamp(240.0, 420.0);
        final orbitBase = size * 0.31;

        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              // Animated radar rings & sweep
              AnimatedBuilder(
                animation: Listenable.merge([_sweepCtrl, _pulseCtrl]),
                builder: (context, _) {
                  return CustomPaint(
                    size: Size.square(size),
                    painter: _RadarPainter(
                      primary: scheme.primary,
                      sweepProgress: _sweepCtrl.value,
                      pulseProgress: _pulseCtrl.value,
                    ),
                  );
                },
              ),

              // Center node (This device) — calm, stationary anchor
              Material(
                shape: CircleBorder(
                  side: BorderSide(
                    color: scheme.primary.withValues(alpha: 0.55),
                    width: 1.75,
                  ),
                ),
                color: scheme.primaryContainer,
                elevation: 4,
                shadowColor: scheme.primary.withValues(alpha: 0.25),
                child: SizedBox(
                  width: 58,
                  height: 58,
                  child: Center(
                    child: Icon(
                      Platform.isAndroid
                          ? Icons.smartphone_rounded
                          : Icons.laptop_windows_rounded,
                      color: scheme.onPrimaryContainer,
                      size: 26,
                    ),
                  ),
                ),
              ),

              // Orbiting discovered devices
              for (var i = 0; i < visible.length; i++)
                _buildDeviceNode(
                  context,
                  visible[i],
                  i,
                  visible.length,
                  orbitBase,
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDeviceNode(
    BuildContext context,
    NearbyDevice device,
    int index,
    int total,
    double orbitBase,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final trusted = widget.isTrusted(device);
    final angle = (index / total) * 2.0 * math.pi - (math.pi / 2.0);
    final radius = device.protocol == TransferProtocol.tapProximity
        ? orbitBase * 1.32 * RssiEmaFilter.orbitFactorForZone(device.proximityZone)
        : (total <= 4
            ? orbitBase * 1.04
            : (index.isOdd ? orbitBase * 1.20 : orbitBase * 0.88));
    final dx = radius * math.cos(angle);
    final dy = radius * math.sin(angle);

    return Transform.translate(
      offset: Offset(dx, dy),
      child: TweenAnimationBuilder<double>(
        key: ValueKey(device.id),
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 420),
        curve: Curves.elasticOut,
        builder: (context, scale, child) {
          return Transform.scale(scale: scale, child: child);
        },
        child: SpringScaleButton(
          onTap: () => widget.onDeviceSelected(device),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Material(
                    shape: trusted
                        ? ScallopBorder(
                            lobes: 12,
                            depth: 0.14,
                            side: BorderSide(color: scheme.primary, width: 2),
                          )
                        : CircleBorder(
                            side: BorderSide(
                              color: scheme.outlineVariant,
                              width: 1.2,
                            ),
                          ),
                    color: trusted
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHigh,
                    elevation: trusted ? 6 : 2,
                    child: SizedBox(
                      width: 56,
                      height: 56,
                      child: Center(
                        child: Icon(
                          _iconForDevice(device),
                          color: trusted
                              ? scheme.onPrimaryContainer
                              : scheme.onSurface,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                  if (device.isUsb ||
                      device.protocol == TransferProtocol.quickShare ||
                      device.protocol == TransferProtocol.tapProximity ||
                      device.protocol == TransferProtocol.internetP2p)
                    Positioned(
                      right: -4,
                      top: -4,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: device.isUsb
                              ? scheme.tertiaryContainer
                              : scheme.secondaryContainer,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: scheme.surface,
                            width: 1.5,
                          ),
                        ),
                        child: Icon(
                          device.isUsb
                              ? Icons.usb_rounded
                              : switch (device.protocol) {
                                  TransferProtocol.quickShare =>
                                    Icons.bolt_rounded,
                                  TransferProtocol.tapProximity =>
                                    Icons.sensors_rounded,
                                  TransferProtocol.internetP2p =>
                                    Icons.public_rounded,
                                  _ => Icons.wifi_rounded,
                                },
                          size: 12,
                          color: device.isUsb
                              ? scheme.onTertiaryContainer
                              : scheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  if (trusted)
                    Positioned(
                      left: -4,
                      top: -4,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.surface, width: 1.5),
                        ),
                        child: Icon(
                          Icons.star_rounded,
                          size: 11,
                          color: scheme.onPrimary,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxWidth: 168),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: trusted
                        ? scheme.primary.withValues(alpha: 0.5)
                        : scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: trusted ? scheme.primary : scheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconForDevice(NearbyDevice dev) {
    if (dev.isUsb) return Icons.usb_rounded;
    return switch (dev.kind) {
      DeviceKind.pc => Icons.laptop_windows_rounded,
      DeviceKind.tablet => Icons.tablet_android_rounded,
      DeviceKind.phone => Icons.smartphone_rounded,
      DeviceKind.usb => Icons.usb_rounded,
      DeviceKind.unknown => Icons.devices_rounded,
    };
  }
}

class _RadarPainter extends CustomPainter {
  final Color primary;
  final double sweepProgress;
  final double pulseProgress;

  _RadarPainter({
    required this.primary,
    required this.sweepProgress,
    required this.pulseProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = (math.min(size.width, size.height) / 2) - 8;

    // Static tonal rings
    for (final factor in [0.33, 0.66, 1.0]) {
      final paint = Paint()
        ..color = primary.withValues(alpha: 0.14)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.25;
      canvas.drawCircle(center, maxR * factor, paint);
    }

    // Crosshairs
    final axisPaint = Paint()
      ..color = primary.withValues(alpha: 0.06)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(center.dx - maxR, center.dy),
      Offset(center.dx + maxR, center.dy),
      axisPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - maxR),
      Offset(center.dx, center.dy + maxR),
      axisPaint,
    );

    // Expanding pulse wave
    final pulseR = maxR * (0.2 + 0.8 * pulseProgress);
    final pulseAlpha = (1.0 - pulseProgress) * 0.30;
    final pulsePaint = Paint()
      ..color = primary.withValues(alpha: pulseAlpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, pulseR, pulsePaint);

    // Conical sweep beam
    final rect = Rect.fromCircle(center: center, radius: maxR);
    final startAngle = sweepProgress * 2.0 * math.pi;
    final sweepShader = SweepGradient(
      colors: [
        Colors.transparent,
        primary.withValues(alpha: 0.03),
        primary.withValues(alpha: 0.22),
        Colors.transparent,
      ],
      stops: const [0.0, 0.65, 0.98, 1.0],
      transform: GradientRotation(startAngle),
    ).createShader(rect);

    canvas.drawCircle(center, maxR, Paint()..shader = sweepShader);
  }

  @override
  bool shouldRepaint(_RadarPainter oldDelegate) {
    return oldDelegate.sweepProgress != sweepProgress ||
        oldDelegate.pulseProgress != pulseProgress ||
        oldDelegate.primary != primary;
  }
}

