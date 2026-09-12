import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/controller_layout.dart';

enum SelectedCluster {
  none,
  dpad,
  actionButtons,
  menuButtons,
}

class ControllerEditScreen extends StatefulWidget {
  final ControllerLayout initialPortraitLayout;
  final ControllerLayout initialLandscapeLayout;
  final Orientation initialOrientation;

  const ControllerEditScreen({
    super.key,
    required this.initialPortraitLayout,
    required this.initialLandscapeLayout,
    this.initialOrientation = Orientation.landscape, // Initially load as landscape
  });

  @override
  State<ControllerEditScreen> createState() => _ControllerEditScreenState();
}

class _ControllerEditScreenState extends State<ControllerEditScreen> {
  late Orientation _currentOrientation;
  late ControllerLayout _portraitLayout;
  late ControllerLayout _landscapeLayout;
  SelectedCluster _selectedCluster = SelectedCluster.none;

  // Multi-touch gesture baseline values
  Offset _gestureStartFocalPoint = Offset.zero;
  double _gestureStartDx = 0.5;
  double _gestureStartDy = 0.5;
  double _gestureStartScale = 1.0;
  double _gestureStartRotation = 0.0;

  ControllerLayout get _currentLayout =>
      _currentOrientation == Orientation.landscape ? _landscapeLayout : _portraitLayout;

  set _currentLayout(ControllerLayout layout) {
    if (_currentOrientation == Orientation.landscape) {
      _landscapeLayout = layout;
    } else {
      _portraitLayout = layout;
    }
  }

  @override
  void initState() {
    super.initState();
    _currentOrientation = widget.initialOrientation;
    _portraitLayout = widget.initialPortraitLayout;
    _landscapeLayout = widget.initialLandscapeLayout;
  }

  ClusterLayout _getClusterLayout(SelectedCluster cluster) {
    switch (cluster) {
      case SelectedCluster.dpad:
        return _currentLayout.dpad;
      case SelectedCluster.actionButtons:
        return _currentLayout.actionButtons;
      case SelectedCluster.menuButtons:
        return _currentLayout.menuButtons;
      case SelectedCluster.none:
        return const ClusterLayout(dx: 0.5, dy: 0.5);
    }
  }

  void _updateCluster(SelectedCluster cluster, {
    double? dx,
    double? dy,
    double? scale,
    double? rotation,
  }) {
    final current = _getClusterLayout(cluster);
    final updated = current.copyWith(
      dx: dx,
      dy: dy,
      scale: scale,
      rotation: rotation,
    );

    switch (cluster) {
      case SelectedCluster.dpad:
        _currentLayout = _currentLayout.copyWith(dpad: updated);
        break;
      case SelectedCluster.actionButtons:
        _currentLayout = _currentLayout.copyWith(actionButtons: updated);
        break;
      case SelectedCluster.menuButtons:
        _currentLayout = _currentLayout.copyWith(menuButtons: updated);
        break;
      case SelectedCluster.none:
        break;
    }
  }

  void _onScaleStart(SelectedCluster cluster, ScaleStartDetails details) {
    setState(() {
      _selectedCluster = cluster;
      final layout = _getClusterLayout(cluster);
      _gestureStartFocalPoint = details.focalPoint;
      _gestureStartDx = layout.dx;
      _gestureStartDy = layout.dy;
      _gestureStartScale = layout.scale;
      _gestureStartRotation = layout.rotation;
    });
  }

  void _onScaleUpdate(SelectedCluster cluster, ScaleUpdateDetails details, Size canvasSize) {
    if (_selectedCluster != cluster) return;

    final delta = details.focalPoint - _gestureStartFocalPoint;
    final newDx = (_gestureStartDx + delta.dx / canvasSize.width).clamp(0.08, 0.92);
    final newDy = (_gestureStartDy + delta.dy / canvasSize.height).clamp(0.08, 0.92);

    // Multi-touch pinch to resize (details.scale = 1.0 for 1-finger drag)
    final newScale = (_gestureStartScale * details.scale).clamp(0.5, 2.5);

    // Multi-touch twist to rotate (details.rotation = 0.0 for 1-finger drag)
    double newRotation = _gestureStartRotation + details.rotation;

    // Snap to 0° if within ~3 degrees
    if (newRotation.abs() < 0.05) {
      newRotation = 0.0;
    }

    setState(() {
      _updateCluster(
        cluster,
        dx: newDx,
        dy: newDy,
        scale: newScale,
        rotation: newRotation,
      );
    });
  }

  void _resetToDefault() {
    setState(() {
      if (_currentOrientation == Orientation.landscape) {
        _landscapeLayout = ControllerLayout.defaultLandscape();
      } else {
        _portraitLayout = ControllerLayout.defaultPortrait();
      }
      _selectedCluster = SelectedCluster.none;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Reset ${_currentOrientation.name.toUpperCase()} layout to default.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _saveAndExit() async {
    await ControllerLayout.save(Orientation.portrait, _portraitLayout);
    await ControllerLayout.save(Orientation.landscape, _landscapeLayout);
    if (!mounted) return;
    Navigator.of(context).pop({
      'portrait': _portraitLayout,
      'landscape': _landscapeLayout,
    });
  }

  String _getClusterTitle(SelectedCluster cluster) {
    switch (cluster) {
      case SelectedCluster.dpad:
        return _currentLayout.directionType == DirectionControlType.joystick ? 'Joystick' : 'D-Pad';
      case SelectedCluster.actionButtons:
        return 'ABXY Buttons';
      case SelectedCluster.menuButtons:
        return 'Select / Start';
      case SelectedCluster.none:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101014),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16161D),
        elevation: 1,
        title: const Text(
          'Layout Editor',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        actions: [
          // Direction Control Type Selector (D-Pad <-> Joystick)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                setState(() {
                  final nextType = _currentLayout.directionType == DirectionControlType.joystick
                      ? DirectionControlType.dpad
                      : DirectionControlType.joystick;
                  _currentLayout = _currentLayout.copyWith(directionType: nextType);
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF252530),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF00E676).withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _currentLayout.directionType == DirectionControlType.joystick
                          ? Icons.sports_esports
                          : Icons.gamepad,
                      size: 14,
                      color: const Color(0xFF00E676),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _currentLayout.directionType == DirectionControlType.joystick
                          ? 'Joystick'
                          : 'D-Pad',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),

          // Orientation toggle button
          IconButton(
            icon: Icon(
              _currentOrientation == Orientation.landscape
                  ? Icons.stay_current_landscape
                  : Icons.stay_current_portrait,
              color: const Color(0xFF42A5F5),
            ),
            tooltip: 'Switch Orientation Preview',
            onPressed: () {
              setState(() {
                _currentOrientation = _currentOrientation == Orientation.landscape
                    ? Orientation.portrait
                    : Orientation.landscape;
                _selectedCluster = SelectedCluster.none;
              });
            },
          ),
          // Reset to default
          IconButton(
            icon: const Icon(Icons.restore, color: Colors.white70),
            tooltip: 'Reset to Default',
            onPressed: _resetToDefault,
          ),
          // Save and Done
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E676),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Save', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              onPressed: _saveAndExit,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Top instructions banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              color: const Color(0xFF1A1A22),
              child: Row(
                children: [
                  const Icon(Icons.pinch, size: 16, color: Color(0xFF64B5F6)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Drag to move • Pinch to resize • Twist 2 fingers to rotate',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF42A5F5).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _currentOrientation.name.toUpperCase(),
                      style: const TextStyle(
                        color: Color(0xFF42A5F5),
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Canvas Area
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);

                  return GestureDetector(
                    onTap: () => setState(() => _selectedCluster = SelectedCluster.none),
                    child: Stack(
                      children: [
                        // Blueprint grid background
                        CustomPaint(
                          size: canvasSize,
                          painter: GridPainter(),
                        ),

                        // 1. Directional Control Cluster (D-Pad or Joystick)
                        _buildInteractiveCluster(
                          cluster: SelectedCluster.dpad,
                          layout: _currentLayout.dpad,
                          canvasSize: canvasSize,
                          child: _currentLayout.directionType == DirectionControlType.joystick
                              ? _buildJoystickMock(_currentLayout.dpad.scale)
                              : _buildDpadMock(_currentLayout.dpad.scale),
                        ),

                        // 2. Action Buttons Cluster (ABXY)
                        _buildInteractiveCluster(
                          cluster: SelectedCluster.actionButtons,
                          layout: _currentLayout.actionButtons,
                          canvasSize: canvasSize,
                          child: _buildActionButtonsMock(_currentLayout.actionButtons.scale),
                        ),

                        // 3. Menu Buttons Cluster (Select & Start)
                        _buildInteractiveCluster(
                          cluster: SelectedCluster.menuButtons,
                          layout: _currentLayout.menuButtons,
                          canvasSize: canvasSize,
                          child: _buildMenuButtonsMock(_currentLayout.menuButtons.scale),
                        ),

                        // Floating Gesture HUD when a cluster is active
                        if (_selectedCluster != SelectedCluster.none)
                          Positioned(
                            bottom: 12,
                            left: 16,
                            right: 16,
                            child: _buildGestureStatusHud(_getClusterLayout(_selectedCluster)),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInteractiveCluster({
    required SelectedCluster cluster,
    required ClusterLayout layout,
    required Size canvasSize,
    required Widget child,
  }) {
    final bool isSelected = _selectedCluster == cluster;
    final pixelX = layout.dx * canvasSize.width;
    final pixelY = layout.dy * canvasSize.height;

    return Positioned(
      left: pixelX,
      top: pixelY,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5), // Center on (x, y)
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (details) => _onScaleStart(cluster, details),
          onScaleUpdate: (details) => _onScaleUpdate(cluster, details, canvasSize),
          onTap: () {
            setState(() => _selectedCluster = cluster);
          },
          child: Transform.rotate(
            angle: layout.rotation,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: isSelected ? const Color(0xFF00E676) : Colors.transparent,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: const Color(0xFF00E676).withValues(alpha: 0.35),
                          blurRadius: 12,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  // ==========================================
  // FLOATING GESTURE STATUS HUD (NO MANUAL BUTTONS)
  // ==========================================

  Widget _buildGestureStatusHud(ClusterLayout layout) {
    final title = _getClusterTitle(_selectedCluster);
    final scalePercent = (layout.scale * 100).toInt();
    final angleDegrees = (layout.rotation * 180 / math.pi).round();

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E28).withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFF00E676).withValues(alpha: 0.5)),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 4)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Cluster Name
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.white),
            ),
            const SizedBox(width: 12),

            // Size Indicator
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.zoom_out_map, size: 12, color: Color(0xFF00E676)),
                  const SizedBox(width: 4),
                  Text(
                    '$scalePercent%',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Color(0xFF00E676)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),

            // Rotation Indicator
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.rotate_right, size: 12, color: Color(0xFF64B5F6)),
                  const SizedBox(width: 4),
                  Text(
                    '$angleDegrees°',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Color(0xFF64B5F6)),
                  ),
                ],
              ),
            ),

            if (layout.rotation != 0.0) ...[
              const SizedBox(width: 8),
              // Quick Snap to 0° chip
              GestureDetector(
                onTap: () {
                  setState(() {
                    _updateCluster(_selectedCluster, rotation: 0.0);
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD32F2F).withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFD32F2F).withValues(alpha: 0.6)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.restart_alt, size: 12, color: Colors.white70),
                      SizedBox(width: 3),
                      Text('0°', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ==========================================
  // MOCK BUTTON GRAPHICS FOR EDITOR
  // ==========================================

  Widget _buildJoystickMock(double scale) {
    final baseRadius = 65.0 * scale;
    final knobRadius = 28.0 * scale;

    return Container(
      width: baseRadius * 2,
      height: baseRadius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF1E1E26),
        border: Border.all(color: const Color(0xFF3E3E4E), width: 3),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Inner guide ring
          Container(
            width: baseRadius * 1.4,
            height: baseRadius * 1.4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white12, width: 1.5),
            ),
          ),
          // Direction indicators
          const Positioned(top: 4, child: Icon(Icons.arrow_drop_up, size: 14, color: Colors.white24)),
          const Positioned(bottom: 4, child: Icon(Icons.arrow_drop_down, size: 14, color: Colors.white24)),
          const Positioned(left: 4, child: Icon(Icons.arrow_left, size: 14, color: Colors.white24)),
          const Positioned(right: 4, child: Icon(Icons.arrow_right, size: 14, color: Colors.white24)),
          // Center Knob
          Container(
            width: knobRadius * 2,
            height: knobRadius * 2,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                colors: [Color(0xFF555566), Color(0xFF2B2B36)],
              ),
              border: Border.all(color: const Color(0xFF777788), width: 2),
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
                width: knobRadius * 0.7,
                height: knobRadius * 0.7,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF00E676),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDpadMock(double scale) {
    final baseSize = 48.0 * scale;
    return Container(
      width: baseSize * 3,
      height: baseSize * 3,
      decoration: BoxDecoration(
        color: const Color(0xFF22222A).withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Vertical Bar
          Container(
            width: baseSize,
            height: baseSize * 3,
            decoration: BoxDecoration(
              color: const Color(0xFF2E2E36),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          // Horizontal Bar
          Container(
            width: baseSize * 3,
            height: baseSize,
            decoration: BoxDecoration(
              color: const Color(0xFF2E2E36),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          // Cross Center
          Container(
            width: baseSize,
            height: baseSize,
            color: const Color(0xFF1E1E24),
            child: const Icon(Icons.open_with, color: Colors.white54, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtonsMock(double scale) {
    final btnSize = 46.0 * scale;
    final clusterSize = btnSize * 2.8;

    return Container(
      width: clusterSize,
      height: clusterSize,
      decoration: BoxDecoration(
        color: const Color(0xFF22222A).withValues(alpha: 0.6),
        shape: BoxShape.circle,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Top: X
          Positioned(
            top: 2,
            child: _buildRoundBtn('X', btnSize, const Color(0xFF1E88E5)),
          ),
          // Left: Y
          Positioned(
            left: 2,
            child: _buildRoundBtn('Y', btnSize, const Color(0xFF43A047)),
          ),
          // Right: A
          Positioned(
            right: 2,
            child: _buildRoundBtn('A', btnSize, const Color(0xFFE53935)),
          ),
          // Bottom: B
          Positioned(
            bottom: 2,
            child: _buildRoundBtn('B', btnSize, const Color(0xFFFDD835)),
          ),
        ],
      ),
    );
  }

  Widget _buildRoundBtn(String label, double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 4, offset: const Offset(0, 3)),
        ],
      ),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: size * 0.42,
          ),
        ),
      ),
    );
  }

  Widget _buildMenuButtonsMock(double scale) {
    final btnW = 54.0 * scale;
    final btnH = 22.0 * scale;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 8 * scale),
      decoration: BoxDecoration(
        color: const Color(0xFF22222A).withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildPillBtn('SELECT', btnW, btnH),
          SizedBox(width: 14 * scale),
          _buildPillBtn('START', btnW, btnH),
        ],
      ),
    );
  }

  Widget _buildPillBtn(String label, double width, double height) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFF33333A),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white24),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFFD32F2F),
            fontWeight: FontWeight.bold,
            fontSize: 9,
            letterSpacing: 1.0,
          ),
        ),
      ],
    );
  }
}

/// Custom painter for blueprint grid lines in editor
class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 1.0;

    const step = 28.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
