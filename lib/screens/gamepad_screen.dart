import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../gamepad/nes_gamepad_controller.dart';
import '../hid/bluetooth_connection_manager.dart';
import '../hid/hid_register.dart';
import '../models/controller_layout.dart';
import '../models/haptic_settings.dart';
import '../widgets/virtual_joystick.dart';
import 'controller_edit_screen.dart';

class GamepadScreen extends StatefulWidget {
  final NesGamepadController controller;
  final HidRegister hidRegister;
  final BluetoothConnectionManager connectionManager;
  final ValueChanged<bool>? onFullScreenChanged;

  const GamepadScreen({
    super.key,
    required this.controller,
    required this.hidRegister,
    required this.connectionManager,
    this.onFullScreenChanged,
  });

  @override
  State<GamepadScreen> createState() => _GamepadScreenState();
}

class _GamepadScreenState extends State<GamepadScreen> {
  bool _isFullScreen = false;
  ControllerLayout _portraitLayout = ControllerLayout.defaultPortrait();
  ControllerLayout _landscapeLayout = ControllerLayout.defaultLandscape();
  HapticSettings _hapticSettings = const HapticSettings();

  // Multi-touch tracking for action buttons
  final Map<int, Offset> _actionPointers = {};
  int _activeDpadSector = 0;

  StreamSubscription<HidAckEvent>? _ackSub;
  HidAckEvent? _lastAck;
  bool _ackPulsing = false;
  Timer? _ackPulseTimer;

  @override
  void initState() {
    super.initState();
    _loadSavedLayouts();
    _listenToAcks();
  }

  void _listenToAcks() {
    _ackSub = widget.hidRegister.ackStream.listen((event) {
      if (!mounted) return;
      if (event.success) {
        // Confirmation haptic click only if enabled in haptic settings (disabled by default to prevent constant buzzing)
        _hapticSettings.trigger(HapticTriggerType.ack);
      }
      setState(() {
        _lastAck = event;
        _ackPulsing = true;
      });
      _ackPulseTimer?.cancel();
      _ackPulseTimer = Timer(const Duration(milliseconds: 350), () {
        if (mounted) setState(() => _ackPulsing = false);
      });
    });
  }

  @override
  void dispose() {
    _ackSub?.cancel();
    _ackPulseTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSavedLayouts() async {
    final p = await ControllerLayout.load(Orientation.portrait);
    final l = await ControllerLayout.load(Orientation.landscape);
    final h = await HapticSettings.load();
    if (mounted) {
      setState(() {
        _portraitLayout = p;
        _landscapeLayout = l;
        _hapticSettings = h;
      });
    }
  }

  void _toggleFullScreen() {
    if (_isFullScreen) {
      _exitFullScreen();
    } else {
      _enterFullScreen();
    }
  }

  void _enterFullScreen() {
    setState(() => _isFullScreen = true);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    widget.onFullScreenChanged?.call(true);
  }

  void _exitFullScreen() {
    setState(() => _isFullScreen = false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    widget.onFullScreenChanged?.call(false);
  }

  void _openLayoutEditor(Orientation currentOrientation) async {
    final result = await Navigator.of(context).push<Map<String, ControllerLayout>>(
      MaterialPageRoute(
        builder: (_) => ControllerEditScreen(
          initialPortraitLayout: _portraitLayout,
          initialLandscapeLayout: _landscapeLayout,
          initialOrientation: Orientation.landscape,
        ),
      ),
    );

    if (result != null) {
      setState(() {
        _portraitLayout = result['portrait'] ?? _portraitLayout;
        _landscapeLayout = result['landscape'] ?? _landscapeLayout;
      });
    }
  }

  void _triggerHaptic([HapticTriggerType type = HapticTriggerType.buttonPress]) {
    _hapticSettings.trigger(type);
  }

  void _openSettingsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF181822),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Handle
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Header
                    Row(
                      children: [
                        const Icon(Icons.vibration, color: Color(0xFFFFB74D), size: 22),
                        const SizedBox(width: 10),
                        const Text(
                          'Vibration & Accuracy Settings',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white12),

                    // Master Toggle
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Haptic Feedback',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                      subtitle: const Text(
                        'Tactile vibrations for buttons, directions & ACK',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      value: _hapticSettings.enabled,
                      activeThumbColor: const Color(0xFF00E676),
                      onChanged: (val) {
                        final updated = _hapticSettings.copyWith(enabled: val);
                        setState(() => _hapticSettings = updated);
                        setSheetState(() => _hapticSettings = updated);
                        HapticSettings.save(updated);
                      },
                    ),

                    // Strength Selector
                    if (_hapticSettings.enabled) ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Vibration Strength',
                            style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFFFFB74D),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            ),
                            icon: const Icon(Icons.play_arrow, size: 14),
                            label: const Text('Test Feel', style: TextStyle(fontSize: 12)),
                            onPressed: () => _hapticSettings.executeFeedback(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<HapticStrength>(
                          segments: const [
                            ButtonSegment(
                              value: HapticStrength.subtle,
                              label: Text('Subtle', style: TextStyle(fontSize: 11)),
                              icon: Icon(Icons.touch_app, size: 14),
                            ),
                            ButtonSegment(
                              value: HapticStrength.medium,
                              label: Text('Medium', style: TextStyle(fontSize: 11)),
                              icon: Icon(Icons.vibration, size: 14),
                            ),
                            ButtonSegment(
                              value: HapticStrength.strong,
                              label: Text('Strong', style: TextStyle(fontSize: 11)),
                              icon: Icon(Icons.offline_bolt, size: 14),
                            ),
                          ],
                          selected: {_hapticSettings.strength},
                          onSelectionChanged: (selection) {
                            final updated = _hapticSettings.copyWith(strength: selection.first);
                            setState(() => _hapticSettings = updated);
                            setSheetState(() => _hapticSettings = updated);
                            HapticSettings.save(updated);
                            updated.executeFeedback();
                          },
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Specific trigger toggles
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Vibrate on Button Press', style: TextStyle(color: Colors.white, fontSize: 14)),
                        subtitle: const Text('Tactile response when tapping A, B, X, Y, Select, Start', style: TextStyle(color: Colors.white54, fontSize: 11)),
                        value: _hapticSettings.vibrateOnPress,
                        activeThumbColor: const Color(0xFF00E676),
                        onChanged: (val) {
                          final updated = _hapticSettings.copyWith(vibrateOnPress: val);
                          setState(() => _hapticSettings = updated);
                          setSheetState(() => _hapticSettings = updated);
                          HapticSettings.save(updated);
                        },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Vibrate on D-Pad Roll', style: TextStyle(color: Colors.white, fontSize: 14)),
                        subtitle: const Text('Light click when thumb transitions between directions', style: TextStyle(color: Colors.white54, fontSize: 11)),
                        value: _hapticSettings.vibrateOnDirectionChange,
                        activeThumbColor: const Color(0xFF00E676),
                        onChanged: (val) {
                          final updated = _hapticSettings.copyWith(vibrateOnDirectionChange: val);
                          setState(() => _hapticSettings = updated);
                          setSheetState(() => _hapticSettings = updated);
                          HapticSettings.save(updated);
                        },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Vibrate on Host ACK', style: TextStyle(color: Colors.white, fontSize: 14)),
                        subtitle: const Text('Confirms report delivery to host (Keep OFF to avoid constant buzzing)', style: TextStyle(color: Colors.white54, fontSize: 11)),
                        value: _hapticSettings.vibrateOnAck,
                        activeThumbColor: const Color(0xFF00E676),
                        onChanged: (val) {
                          final updated = _hapticSettings.copyWith(vibrateOnAck: val);
                          setState(() => _hapticSettings = updated);
                          setSheetState(() => _hapticSettings = updated);
                          HapticSettings.save(updated);
                        },
                      ),
                    ],

                    const Divider(color: Colors.white12),

                    // Section 2: No-Look Flat Screen Gaming
                    const Row(
                      children: [
                        Icon(Icons.remove_red_eye_outlined, color: Color(0xFF64B5F6), size: 18),
                        SizedBox(width: 8),
                        Text(
                          'No-Look Screen Accuracy (Blind Play)',
                          style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('A + B Dual-Press Bridge', style: TextStyle(color: Colors.white, fontSize: 14)),
                      subtitle: const Text('Rest single thumb between A & B to activate both (for run+jump in platformers)', style: TextStyle(color: Colors.white54, fontSize: 11)),
                      value: _hapticSettings.aPlusBBridge,
                      activeThumbColor: const Color(0xFF00E676),
                      onChanged: (val) {
                        final updated = _hapticSettings.copyWith(aPlusBBridge: val);
                        setState(() => _hapticSettings = updated);
                        setSheetState(() => _hapticSettings = updated);
                        HapticSettings.save(updated);
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Continuous 8-Way Rolling D-Pad', style: TextStyle(color: Colors.white, fontSize: 14)),
                      subtitle: const Text('Slide thumb across D-Pad without lifting; automatically activates diagonals', style: TextStyle(color: Colors.white54, fontSize: 11)),
                      value: _hapticSettings.continuousDpad,
                      activeThumbColor: const Color(0xFF00E676),
                      onChanged: (val) {
                        final updated = _hapticSettings.copyWith(continuousDpad: val);
                        setState(() => _hapticSettings = updated);
                        setSheetState(() => _hapticSettings = updated);
                        HapticSettings.save(updated);
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isFullScreen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isFullScreen) {
          _exitFullScreen();
        }
      },
      child: OrientationBuilder(
        builder: (context, orientation) {
          final layout = orientation == Orientation.landscape
              ? _landscapeLayout
              : _portraitLayout;

          return Scaffold(
            backgroundColor: const Color(0xFF101014),
            body: SafeArea(
              // In fullscreen mode, don't reserve SafeArea padding so it uses full display
              top: !_isFullScreen,
              bottom: !_isFullScreen,
              left: !_isFullScreen,
              right: !_isFullScreen,
              child: Stack(
                children: [
                  // 1. Controller Canvas Layer
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);

                        return Stack(
                          children: [
                            // Directional Control Cluster (D-Pad or Joystick)
                            _buildPositionedCluster(
                              layout: layout.dpad,
                              canvasSize: canvasSize,
                              child: layout.directionType == DirectionControlType.joystick
                                  ? _buildJoystick(layout.dpad.scale)
                                  : _buildDpad(layout.dpad.scale),
                            ),

                            // ABXY Action Buttons Cluster
                            _buildPositionedCluster(
                              layout: layout.actionButtons,
                              canvasSize: canvasSize,
                              child: _buildAbxyCluster(layout.actionButtons.scale),
                            ),

                            // Menu Buttons Cluster (Select & Start)
                            _buildPositionedCluster(
                              layout: layout.menuButtons,
                              canvasSize: canvasSize,
                              child: _buildMenuCluster(layout.menuButtons.scale),
                            ),
                          ],
                        );
                      },
                    ),
                  ),

                  // 2. Floating Top Chrome Bar (Status & Action controls)
                  Positioned(
                    top: 8,
                    left: 12,
                    right: 12,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: _isFullScreen ? 0.35 : 1.0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1B1B22).withValues(alpha: 0.88),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white12),
                          boxShadow: const [
                            BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 2)),
                          ],
                        ),
                        child: Row(
                          children: [
                            // Connection indicator
                            StreamBuilder<ConnectionStatus>(
                              stream: widget.connectionManager.statusStream,
                              initialData: widget.connectionManager.status,
                              builder: (context, snapshot) {
                                final isConnected = snapshot.data == ConnectionStatus.connected;
                                final hostName = widget.connectionManager.connectedDevice?.name ?? 'No Device';

                                return Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: isConnected ? const Color(0xFF00E676) : Colors.orangeAccent,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      isConnected ? hostName : 'Disconnected',
                                      style: TextStyle(
                                        color: isConnected ? Colors.white : Colors.white60,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 12,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                );
                              },
                            ),

                            // ACK Confirmation Badge
                            if (_lastAck != null) ...[
                              const SizedBox(width: 10),
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _lastAck!.success
                                      ? (_ackPulsing
                                          ? const Color(0xFF00E676).withValues(alpha: 0.35)
                                          : const Color(0xFF00E676).withValues(alpha: 0.12))
                                      : Colors.redAccent.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: _lastAck!.success
                                        ? (_ackPulsing ? const Color(0xFF00E676) : const Color(0xFF00E676).withValues(alpha: 0.4))
                                        : Colors.redAccent,
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _lastAck!.success ? Icons.check_circle : Icons.error_outline,
                                      size: 10,
                                      color: _lastAck!.success ? const Color(0xFF00E676) : Colors.redAccent,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      _lastAck!.success ? 'ACK ${_lastAck!.latencyMs}ms' : 'DROP',
                                      style: TextStyle(
                                        color: _lastAck!.success ? const Color(0xFF00E676) : Colors.redAccent,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],

                            const Spacer(),

                            // Direction Mode Toggle (D-Pad <-> Joystick)
                            if (!_isFullScreen)
                              IconButton(
                                icon: Icon(
                                  layout.directionType == DirectionControlType.joystick
                                      ? Icons.sports_esports
                                      : Icons.gamepad,
                                  color: const Color(0xFF00E676),
                                  size: 20,
                                ),
                                tooltip: layout.directionType == DirectionControlType.joystick
                                    ? 'Current: Joystick (Tap for D-Pad)'
                                    : 'Current: D-Pad (Tap for Joystick)',
                                visualDensity: VisualDensity.compact,
                                onPressed: () {
                                  final nextType = layout.directionType == DirectionControlType.joystick
                                      ? DirectionControlType.dpad
                                      : DirectionControlType.joystick;
                                  setState(() {
                                    if (orientation == Orientation.landscape) {
                                      _landscapeLayout = _landscapeLayout.copyWith(directionType: nextType);
                                      ControllerLayout.save(Orientation.landscape, _landscapeLayout);
                                    } else {
                                      _portraitLayout = _portraitLayout.copyWith(directionType: nextType);
                                      ControllerLayout.save(Orientation.portrait, _portraitLayout);
                                    }
                                  });
                                },
                              ),

                            // Haptic & Touch Accuracy Settings
                            if (!_isFullScreen)
                              IconButton(
                                icon: const Icon(Icons.vibration, color: Color(0xFFFFB74D), size: 20),
                                tooltip: 'Vibration & Touch Settings',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _openSettingsSheet(context),
                              ),

                            // Layout Edit Button
                            if (!_isFullScreen)
                              IconButton(
                                icon: const Icon(Icons.tune, color: Color(0xFF64B5F6), size: 20),
                                tooltip: 'Edit Layout & Size',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _openLayoutEditor(orientation),
                              ),

                            // Fullscreen Toggle Button
                            IconButton(
                              icon: Icon(
                                _isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                                color: Colors.white,
                                size: 22,
                              ),
                              tooltip: _isFullScreen ? 'Exit Full Screen' : 'Full Screen Mode',
                              visualDensity: VisualDensity.compact,
                              onPressed: _toggleFullScreen,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Hint indicator when in Fullscreen mode
                  if (_isFullScreen)
                    Positioned(
                      bottom: 8,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'Full Screen: Press Back to exit',
                            style: TextStyle(color: Colors.white38, fontSize: 10),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPositionedCluster({
    required ClusterLayout layout,
    required Size canvasSize,
    required Widget child,
  }) {
    final pixelX = layout.dx * canvasSize.width;
    final pixelY = layout.dy * canvasSize.height;

    return Positioned(
      left: pixelX,
      top: pixelY,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: Transform.rotate(
          angle: layout.rotation,
          child: child,
        ),
      ),
    );
  }

  // ==========================================
  // JOYSTICK CLUSTER
  // ==========================================

  Widget _buildJoystick(double scale) {
    return VirtualJoystick(
      scale: scale,
      onTouchDown: () => _triggerHaptic(HapticTriggerType.buttonPress),
      onDirectionChanged: (x, y) {
        widget.controller.setJoystick(x, y);
      },
      onReleased: () {
        widget.controller.resetJoystick();
      },
    );
  }

  // ==========================================
  // D-PAD CLUSTER (Continuous Rolling Touch Surface)
  // ==========================================

  Widget _buildDpad(double scale) {
    final btnSize = 52.0 * scale;
    final totalSize = btnSize * 3.0;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => _handleDpadPointer(event.localPosition, totalSize, btnSize, isInitialDown: true),
      onPointerMove: (event) => _handleDpadPointer(event.localPosition, totalSize, btnSize),
      onPointerUp: (_) => _releaseDpad(),
      onPointerCancel: (_) => _releaseDpad(),
      child: Container(
        width: totalSize,
        height: totalSize,
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Vertical bar backing
            Container(
              width: btnSize,
              height: totalSize,
              decoration: BoxDecoration(
                color: const Color(0xFF1B1B22),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF33333E), width: 1.5),
                boxShadow: const [
                  BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 3)),
                ],
              ),
            ),
            // Horizontal bar backing
            Container(
              width: totalSize,
              height: btnSize,
              decoration: BoxDecoration(
                color: const Color(0xFF1B1B22),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF33333E), width: 1.5),
                boxShadow: const [
                  BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 3)),
                ],
              ),
            ),

            // UP Arrow Zone
            Positioned(
              top: 0,
              left: btnSize,
              width: btnSize,
              height: btnSize,
              child: _buildDpadArmVisual(
                icon: Icons.arrow_drop_up,
                isPressed: widget.controller.isUpPressed,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
              ),
            ),

            // DOWN Arrow Zone
            Positioned(
              bottom: 0,
              left: btnSize,
              width: btnSize,
              height: btnSize,
              child: _buildDpadArmVisual(
                icon: Icons.arrow_drop_down,
                isPressed: widget.controller.isDownPressed,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
              ),
            ),

            // LEFT Arrow Zone
            Positioned(
              left: 0,
              top: btnSize,
              width: btnSize,
              height: btnSize,
              child: _buildDpadArmVisual(
                icon: Icons.arrow_left,
                isPressed: widget.controller.isLeftPressed,
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
              ),
            ),

            // RIGHT Arrow Zone
            Positioned(
              right: 0,
              top: btnSize,
              width: btnSize,
              height: btnSize,
              child: _buildDpadArmVisual(
                icon: Icons.arrow_right,
                isPressed: widget.controller.isRightPressed,
                borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
              ),
            ),

            // Diagonal corner accents
            Positioned(
              top: btnSize * 0.1,
              right: btnSize * 0.1,
              child: _buildDiagonalAccent(widget.controller.isUpPressed && widget.controller.isRightPressed),
            ),
            Positioned(
              bottom: btnSize * 0.1,
              right: btnSize * 0.1,
              child: _buildDiagonalAccent(widget.controller.isDownPressed && widget.controller.isRightPressed),
            ),
            Positioned(
              bottom: btnSize * 0.1,
              left: btnSize * 0.1,
              child: _buildDiagonalAccent(widget.controller.isDownPressed && widget.controller.isLeftPressed),
            ),
            Positioned(
              top: btnSize * 0.1,
              left: btnSize * 0.1,
              child: _buildDiagonalAccent(widget.controller.isUpPressed && widget.controller.isLeftPressed),
            ),

            // Center Neutral Hub with tactile grip ring
            Container(
              width: btnSize * 0.9,
              height: btnSize * 0.9,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const RadialGradient(
                  colors: [Color(0xFF282832), Color(0xFF18181E)],
                ),
                border: Border.all(color: const Color(0xFF3E3E4C), width: 1.5),
              ),
              child: Center(
                child: Container(
                  width: btnSize * 0.35,
                  height: btnSize * 0.35,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF33333F),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDpadArmVisual({
    required IconData icon,
    required bool isPressed,
    required BorderRadius borderRadius,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 50),
      decoration: BoxDecoration(
        color: isPressed ? const Color(0xFF4A4A58) : Colors.transparent,
        borderRadius: borderRadius,
      ),
      child: Center(
        child: Icon(
          icon,
          size: 34,
          color: isPressed ? const Color(0xFF00E676) : Colors.white70,
        ),
      ),
    );
  }

  Widget _buildDiagonalAccent(bool isActive) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 50),
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isActive ? const Color(0xFF00E676).withValues(alpha: 0.5) : Colors.transparent,
        border: Border.all(
          color: isActive ? const Color(0xFF00E676) : Colors.white10,
          width: 1,
        ),
      ),
    );
  }

  void _handleDpadPointer(Offset localPos, double totalSize, double btnSize, {bool isInitialDown = false}) {
    final center = Offset(totalSize / 2, totalSize / 2);
    final delta = localPos - center;
    final distance = delta.distance;
    final deadzone = btnSize * 0.38;

    if (distance < deadzone) {
      if (_activeDpadSector != 0) {
        _activeDpadSector = 0;
        widget.controller.setDpad(up: false, down: false, left: false, right: false);
        setState(() {});
      }
      return;
    }

    var angleDeg = math.atan2(delta.dy, delta.dx) * 180 / math.pi;
    if (angleDeg < 0) angleDeg += 360;

    // 8 sectors (45 degrees each)
    // 0: Right, 1: Down-Right, 2: Down, 3: Down-Left, 4: Left, 5: Up-Left, 6: Up, 7: Up-Right
    final sector = (((angleDeg + 22.5) % 360) / 45).floor();
    final sectorCode = sector + 1;

    bool up = false;
    bool down = false;
    bool left = false;
    bool right = false;

    switch (sector) {
      case 0:
        right = true;
        break;
      case 1:
        down = true;
        right = true;
        break;
      case 2:
        down = true;
        break;
      case 3:
        down = true;
        left = true;
        break;
      case 4:
        left = true;
        break;
      case 5:
        up = true;
        left = true;
        break;
      case 6:
        up = true;
        break;
      case 7:
        up = true;
        right = true;
        break;
    }

    if (_activeDpadSector != sectorCode) {
      _activeDpadSector = sectorCode;
      _triggerHaptic(isInitialDown ? HapticTriggerType.buttonPress : HapticTriggerType.directionChange);
      widget.controller.setDpad(up: up, down: down, left: left, right: right);
      setState(() {});
    }
  }

  void _releaseDpad() {
    if (_activeDpadSector != 0) {
      _activeDpadSector = 0;
      widget.controller.setDpad(up: false, down: false, left: false, right: false);
      setState(() {});
    }
  }

  // ==========================================
  // ABXY ACTION BUTTONS CLUSTER (DIAMOND + A+B COMBO BRIDGE)
  // ==========================================

  Widget _buildAbxyCluster(double scale) {
    final btnSize = 50.0 * scale;
    final clusterSize = btnSize * 3.1;
    final clusterCenter = clusterSize / 2;
    final btnOffset = btnSize * 0.90;

    final posA = Offset(clusterCenter + btnOffset, clusterCenter);
    final posB = Offset(clusterCenter, clusterCenter + btnOffset);
    final posX = Offset(clusterCenter, clusterCenter - btnOffset);
    final posY = Offset(clusterCenter - btnOffset, clusterCenter);
    final posAB = (posA + posB) / 2;

    final isABComboActive = widget.controller.isAPressed && widget.controller.isBPressed;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        _actionPointers[e.pointer] = e.localPosition;
        _evaluateActionButtons(btnSize, posA, posB, posX, posY, posAB);
      },
      onPointerMove: (e) {
        _actionPointers[e.pointer] = e.localPosition;
        _evaluateActionButtons(btnSize, posA, posB, posX, posY, posAB);
      },
      onPointerUp: (e) {
        _actionPointers.remove(e.pointer);
        _evaluateActionButtons(btnSize, posA, posB, posX, posY, posAB);
      },
      onPointerCancel: (e) {
        _actionPointers.remove(e.pointer);
        _evaluateActionButtons(btnSize, posA, posB, posX, posY, posAB);
      },
      child: Container(
        width: clusterSize,
        height: clusterSize,
        decoration: BoxDecoration(
          color: const Color(0xFF1B1B22).withValues(alpha: 0.65),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white12, width: 1.5),
          boxShadow: const [
            BoxShadow(color: Colors.black45, blurRadius: 8, offset: Offset(0, 4)),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Tactile alignment guides
            Container(
              width: clusterSize * 0.7,
              height: 2,
              color: Colors.white.withValues(alpha: 0.05),
            ),
            Container(
              width: 2,
              height: clusterSize * 0.7,
              color: Colors.white.withValues(alpha: 0.05),
            ),

            // A+B Combo Bridge Pill (Allows resting single thumb across A & B for run+jump)
            if (_hapticSettings.aPlusBBridge)
              Positioned(
                left: posAB.dx - (btnSize * 0.44),
                top: posAB.dy - (btnSize * 0.24),
                child: Transform.rotate(
                  angle: -math.pi / 4,
                  child: Container(
                    width: btnSize * 0.88,
                    height: btnSize * 0.48,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(btnSize * 0.24),
                      color: isABComboActive
                          ? const Color(0xFFFF9100).withValues(alpha: 0.40)
                          : const Color(0xFF2B2B38).withValues(alpha: 0.60),
                      border: Border.all(
                        color: isABComboActive ? const Color(0xFFFF9100) : Colors.white24,
                        width: isABComboActive ? 1.8 : 1.0,
                      ),
                      boxShadow: [
                        if (isABComboActive)
                          BoxShadow(
                            color: const Color(0xFFFF9100).withValues(alpha: 0.4),
                            blurRadius: 8,
                            spreadRadius: 1,
                          ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        'A+B',
                        style: TextStyle(
                          fontSize: 10 * scale,
                          fontWeight: FontWeight.bold,
                          color: isABComboActive ? Colors.white : Colors.white54,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // Button X (Top - Blue)
            Positioned(
              left: posX.dx - btnSize / 2,
              top: posX.dy - btnSize / 2,
              child: _buildButtonFace('X', widget.controller.isXPressed, btnSize, const Color(0xFF1E88E5)),
            ),

            // Button Y (Left - Green)
            Positioned(
              left: posY.dx - btnSize / 2,
              top: posY.dy - btnSize / 2,
              child: _buildButtonFace('Y', widget.controller.isYPressed, btnSize, const Color(0xFF43A047)),
            ),

            // Button A (Right - Red)
            Positioned(
              left: posA.dx - btnSize / 2,
              top: posA.dy - btnSize / 2,
              child: _buildButtonFace('A', widget.controller.isAPressed, btnSize, const Color(0xFFE53935)),
            ),

            // Button B (Bottom - Yellow)
            Positioned(
              left: posB.dx - btnSize / 2,
              top: posB.dy - btnSize / 2,
              child: _buildButtonFace('B', widget.controller.isBPressed, btnSize, const Color(0xFFFBC02D)),
            ),
          ],
        ),
      ),
    );
  }

  void _evaluateActionButtons(
    double btnSize,
    Offset posA,
    Offset posB,
    Offset posX,
    Offset posY,
    Offset posAB,
  ) {
    final activeRadius = btnSize * 0.70;
    final bridgeRadius = btnSize * 0.65;

    bool nextA = false;
    bool nextB = false;
    bool nextX = false;
    bool nextY = false;

    for (final pt in _actionPointers.values) {
      final distA = (pt - posA).distance;
      final distB = (pt - posB).distance;
      final distX = (pt - posX).distance;
      final distY = (pt - posY).distance;
      final distAB = (pt - posAB).distance;

      // Check A+B bridge first
      if (_hapticSettings.aPlusBBridge && distAB <= bridgeRadius) {
        nextA = true;
        nextB = true;
      } else {
        if (distA <= activeRadius) nextA = true;
        if (distB <= activeRadius) nextB = true;
      }

      if (distX <= activeRadius) nextX = true;
      if (distY <= activeRadius) nextY = true;
    }

    _updateActionState(NesButton.a, nextA, widget.controller.isAPressed);
    _updateActionState(NesButton.b, nextB, widget.controller.isBPressed);
    _updateActionState(NesButton.x, nextX, widget.controller.isXPressed);
    _updateActionState(NesButton.y, nextY, widget.controller.isYPressed);
  }

  void _updateActionState(NesButton btn, bool nextState, bool currentState) {
    if (nextState != currentState) {
      if (nextState) {
        _triggerHaptic(HapticTriggerType.buttonPress);
        widget.controller.pressButton(btn);
      } else {
        widget.controller.releaseButton(btn);
      }
      setState(() {});
    }
  }

  Widget _buildButtonFace(String label, bool isPressed, double size, Color color) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 40),
      width: size,
      height: size,
      transform: isPressed ? Matrix4.translationValues(0, 2, 0) : Matrix4.identity(),
      decoration: BoxDecoration(
        color: isPressed ? color.withValues(alpha: 0.75) : color,
        shape: BoxShape.circle,
        border: Border.all(
          color: isPressed ? Colors.white : Colors.white24,
          width: isPressed ? 2.5 : 1.8,
        ),
        boxShadow: [
          if (!isPressed)
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 5,
              offset: const Offset(0, 3),
            ),
          if (isPressed)
            BoxShadow(
              color: color.withValues(alpha: 0.6),
              blurRadius: 8,
              spreadRadius: 1,
            ),
        ],
      ),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: size * 0.44,
            shadows: const [
              Shadow(color: Colors.black54, blurRadius: 2, offset: Offset(0, 1)),
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================
  // MENU BUTTONS CLUSTER (SELECT / START)
  // ==========================================

  Widget _buildMenuCluster(double scale) {
    final btnW = 56.0 * scale;
    final btnH = 22.0 * scale;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 8 * scale),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E24).withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildPillButton('SELECT', NesButton.select, widget.controller.isSelectPressed, btnW, btnH),
          SizedBox(width: 16 * scale),
          _buildPillButton('START', NesButton.start, widget.controller.isStartPressed, btnW, btnH),
        ],
      ),
    );
  }

  Widget _buildPillButton(
    String label,
    NesButton button,
    bool isPressed,
    double width,
    double height,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Listener(
          onPointerDown: (_) {
            _triggerHaptic(HapticTriggerType.buttonPress);
            setState(() => widget.controller.pressButton(button));
          },
          onPointerUp: (_) {
            setState(() => widget.controller.releaseButton(button));
          },
          onPointerCancel: (_) {
            setState(() => widget.controller.releaseButton(button));
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 50),
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: isPressed ? const Color(0xFF555560) : const Color(0xFF2B2B32),
              borderRadius: BorderRadius.circular(height / 2),
              border: Border.all(
                color: isPressed ? const Color(0xFF00E676) : const Color(0xFF44444F),
                width: 1.5,
              ),
              boxShadow: [
                if (!isPressed)
                  const BoxShadow(color: Colors.black45, blurRadius: 3, offset: Offset(0, 2)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            color: isPressed ? const Color(0xFF00E676) : const Color(0xFFE53935),
            fontWeight: FontWeight.bold,
            fontSize: 10,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }
}
