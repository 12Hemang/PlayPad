import 'package:flutter/material.dart';

/// Touchscreen analog joystick widget with auto-centering and normalized coordinates (-1.0 to +1.0).
class VirtualJoystick extends StatefulWidget {
  final double scale;
  final void Function(double x, double y) onDirectionChanged;
  final VoidCallback onReleased;
  final VoidCallback? onTouchDown;

  const VirtualJoystick({
    super.key,
    this.scale = 1.0,
    required this.onDirectionChanged,
    required this.onReleased,
    this.onTouchDown,
  });

  @override
  State<VirtualJoystick> createState() => _VirtualJoystickState();
}

class _VirtualJoystickState extends State<VirtualJoystick> {
  Offset _dragOffset = Offset.zero;
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    final baseRadius = 65.0 * widget.scale;
    final knobRadius = 28.0 * widget.scale;
    final maxDistance = baseRadius * 0.72;

    return Listener(
      onPointerDown: (event) {
        widget.onTouchDown?.call();
        _updatePosition(event.localPosition, baseRadius, maxDistance);
      },
      onPointerMove: (event) {
        _updatePosition(event.localPosition, baseRadius, maxDistance);
      },
      onPointerUp: (_) => _resetKnob(),
      onPointerCancel: (_) => _resetKnob(),
      child: Container(
        width: baseRadius * 2,
        height: baseRadius * 2,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const RadialGradient(
            colors: [Color(0xFF23232C), Color(0xFF141419)],
          ),
          border: Border.all(
            color: _isDragging
                ? const Color(0xFF00E676).withValues(alpha: 0.6)
                : const Color(0xFF3B3B48),
            width: 3,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Directional cross hair marks
            Positioned(
              top: 6,
              child: Container(width: 2, height: 8, color: Colors.white24),
            ),
            Positioned(
              bottom: 6,
              child: Container(width: 2, height: 8, color: Colors.white24),
            ),
            Positioned(
              left: 6,
              child: Container(width: 8, height: 2, color: Colors.white24),
            ),
            Positioned(
              right: 6,
              child: Container(width: 8, height: 2, color: Colors.white24),
            ),

            // Inner boundary ring
            Container(
              width: maxDistance * 2,
              height: maxDistance * 2,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: _isDragging
                      ? const Color(0xFF00E676).withValues(alpha: 0.25)
                      : Colors.white10,
                  width: 1.5,
                ),
              ),
            ),

            // Draggable Thumb Knob
            Transform.translate(
              offset: _dragOffset,
              child: Container(
                width: knobRadius * 2,
                height: knobRadius * 2,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: _isDragging
                        ? [const Color(0xFF5A5A72), const Color(0xFF2C2C38)]
                        : [const Color(0xFF424250), const Color(0xFF22222A)],
                  ),
                  border: Border.all(
                    color: _isDragging ? const Color(0xFF00E676) : const Color(0xFF6E6E82),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.6),
                      blurRadius: 6,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Center(
                  child: Container(
                    width: knobRadius * 0.65,
                    height: knobRadius * 0.65,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isDragging
                          ? const Color(0xFF00E676)
                          : Colors.white30,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _updatePosition(Offset localPos, double baseRadius, double maxDistance) {
    final center = Offset(baseRadius, baseRadius);
    final delta = localPos - center;
    final distance = delta.distance;

    Offset clampedOffset;
    if (distance <= maxDistance) {
      clampedOffset = delta;
    } else {
      clampedOffset = Offset(
        (delta.dx / distance) * maxDistance,
        (delta.dy / distance) * maxDistance,
      );
    }

    setState(() {
      _isDragging = true;
      _dragOffset = clampedOffset;
    });

    final normX = (clampedOffset.dx / maxDistance).clamp(-1.0, 1.0);
    final normY = (clampedOffset.dy / maxDistance).clamp(-1.0, 1.0);
    widget.onDirectionChanged(normX, normY);
  }

  void _resetKnob() {
    setState(() {
      _isDragging = false;
      _dragOffset = Offset.zero;
    });
    widget.onReleased();
  }
}
