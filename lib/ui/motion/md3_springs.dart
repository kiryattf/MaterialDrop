import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';

/// Material 3 Expressive motion physics tokens.
class Md3Springs {
  static SpringDescription _fromDampingRatio({
    required double stiffness,
    required double dampingRatio,
  }) {
    return SpringDescription(
      mass: 1.0,
      stiffness: stiffness,
      damping: 2.0 * dampingRatio * math.sqrt(stiffness),
    );
  }

  static final SpringDescription fastSpatial =
      _fromDampingRatio(stiffness: 800, dampingRatio: 0.9);

  static final SpringDescription defaultSpatial =
      _fromDampingRatio(stiffness: 380, dampingRatio: 0.78);

  static final SpringDescription bouncySpatial =
      _fromDampingRatio(stiffness: 320, dampingRatio: 0.65);

  static final SpringDescription slowSpatial =
      _fromDampingRatio(stiffness: 200, dampingRatio: 0.85);

  static final SpringDescription defaultEffects =
      _fromDampingRatio(stiffness: 1600, dampingRatio: 1.0);
}

/// Interactive wrapper providing Material 3 Expressive spring press/hover bounce.
class SpringScaleButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double pressedScale;
  final double hoverScale;

  const SpringScaleButton({
    super.key,
    required this.child,
    this.onTap,
    this.pressedScale = 0.94,
    this.hoverScale = 1.04,
  });

  @override
  State<SpringScaleButton> createState() => _SpringScaleButtonState();
}

class _SpringScaleButtonState extends State<SpringScaleButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _hovered = false;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(vsync: this, value: 1.0);
  }

  void _animateToTarget() {
    final target = _pressed
        ? widget.pressedScale
        : (_hovered ? widget.hoverScale : 1.0);
    final sim = SpringSimulation(
      Md3Springs.bouncySpatial,
      _controller.value,
      target,
      0.0,
    );
    _controller.animateWith(sim);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) {
        _hovered = true;
        _animateToTarget();
      },
      onExit: (_) {
        _hovered = false;
        _pressed = false;
        _animateToTarget();
      },
      child: GestureDetector(
        onTapDown: (_) {
          if (widget.onTap == null) return;
          _pressed = true;
          _animateToTarget();
        },
        onTapUp: (_) {
          _pressed = false;
          _animateToTarget();
        },
        onTapCancel: () {
          _pressed = false;
          _animateToTarget();
        },
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Transform.scale(
              scale: _controller.value.clamp(0.7, 1.3),
              child: child,
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}

/// Smooth Material 3 Expressive stage transition switcher.
class ExpressiveStageSwitcher extends StatelessWidget {
  final Widget child;
  final Duration duration;

  const ExpressiveStageSwitcher({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 360),
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (widget, animation) {
        final slide = Tween<Offset>(
          begin: const Offset(0, 0.05),
          end: Offset.zero,
        ).animate(animation);
        final scale = Tween<double>(begin: 0.96, end: 1.0).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: slide,
            child: ScaleTransition(scale: scale, child: widget),
          ),
        );
      },
      child: child,
    );
  }
}

