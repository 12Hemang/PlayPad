import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../gamepad/controller_factory.dart';
import '../gamepad/gamepad_controller.dart';
import '../gamepad/n64_gamepad_controller.dart';
import '../gamepad/nes_gamepad_controller.dart';
import '../hid/bluetooth_connection_manager.dart';
import '../hid/hid_register.dart';
import '../models/controller_layout.dart';
import '../models/haptic_settings.dart';
import '../widgets/virtual_joystick.dart';
import 'add_roms_dialog.dart';
import 'controller_edit_screen.dart';

class GamepadScreen extends StatefulWidget {
  final GamepadController? controller;
  final HidRegister hidRegister;
  final BluetoothConnectionManager connectionManager;
  final ValueChanged<bool>? onFullScreenChanged;
  final ValueChanged<ControllerType>? onControllerTypeChanged;

  const GamepadScreen({
    super.key,
    this.controller,
    required this.hidRegister,
    required this.connectionManager,
    this.onFullScreenChanged,
    this.onControllerTypeChanged,
  });

  @override
  State<GamepadScreen> createState() => _GamepadScreenState();
}

class _GamepadScreenState extends State<GamepadScreen> {
  bool _isFullScreen = false;
  ControllerLayout _portraitLayout = ControllerLayout.defaultPortrait();
  ControllerLayout _landscapeLayout = ControllerLayout.defaultLandscape();
  HapticSettings _hapticSettings = const HapticSettings();

  late GamepadController _activeController;
  ControllerType _controllerType = ControllerType.nes;

  NesGamepadController get _nes =>
      _activeController is NesGamepadController
          ? _activeController as NesGamepadController
          : NesGamepadController();

  N64GamepadController get _n64 =>
      _activeController is N64GamepadController
          ? _activeController as N64GamepadController
          : N64GamepadController();

  // Multi-touch tracking for action buttons
  final Map<int, Offset> _actionPointers = {};
  int _activeDpadSector = 0;

  // Real-time transmission latency feedback
  StreamSubscription<HidAckEvent>? _ackSub;
  HidAckEvent? _lastAck;
  bool _ackPulsing = false;

  @override
  void initState() {
    super.initState();
    _activeController = widget.controller ?? NesGamepadController();
    _enterLandscapeFullscreen();
    _loadSettings();
    _listenToAcks();
  }

  Future<void> _loadSettings() async {
    final savedType = await ControllerFactory.loadActiveType();
    final p = await ControllerLayout.load(Orientation.portrait, controllerType: savedType);
    final l = await ControllerLayout.load(Orientation.landscape, controllerType: savedType);
    final h = await HapticSettings.load();

    if (mounted) {
      setState(() {
        _portraitLayout = p;
        _landscapeLayout = l;
        _hapticSettings = h;
      });
      if (savedType != _controllerType) {
        await _switchControllerType(savedType, notify: false, reloadLayouts: false);
      }
    }
  }

  Future<void> _switchControllerType(
    ControllerType type, {
    bool notify = true,
    bool reloadLayouts = true,
  }) async {
    if (_controllerType == type &&
        _activeController.runtimeType ==
            (type == ControllerType.nes ? NesGamepadController : N64GamepadController)) {
      return;
    }

    _activeController.reset();
    final newController = ControllerFactory.createController(type);
    _activeController = newController;
    _controllerType = type;

    if (_activeController is NesGamepadController) {
      (_activeController as NesGamepadController).swapAB = _hapticSettings.swapAB;
      (_activeController as NesGamepadController).swapXY = _hapticSettings.swapXY;
    }

    if (reloadLayouts) {
      final p = await ControllerLayout.load(Orientation.portrait, controllerType: type);
      final l = await ControllerLayout.load(Orientation.landscape, controllerType: type);
      if (mounted) {
        setState(() {
          _portraitLayout = p;
          _landscapeLayout = l;
        });
      }
    }

    await widget.hidRegister.registerGamepad(newController);
    await ControllerFactory.saveActiveType(type);

    if (notify) {
      widget.onControllerTypeChanged?.call(type);
    }

    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Switched to ${ControllerFactory.getDisplayName(type)}'),
          backgroundColor: const Color(0xFF00E676),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  void _listenToAcks() {
    _ackSub = widget.hidRegister.ackStream.listen((ack) {
      if (!mounted) return;
      setState(() {
        _lastAck = ack;
        _ackPulsing = true;
      });

      if (_hapticSettings.vibrateOnAck && ack.success) {
        _hapticSettings.trigger(HapticTriggerType.ack);
      }

      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) setState(() => _ackPulsing = false);
      });
    });
  }

  void _enterLandscapeFullscreen() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _restoreOrientations() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.top, SystemUiOverlay.bottom],
    );
  }

  @override
  void dispose() {
    _ackSub?.cancel();
    _restoreOrientations();
    super.dispose();
  }

  void _triggerHaptic(HapticTriggerType type) {
    _hapticSettings.trigger(type);
  }

  void _toggleFullScreen() {
    setState(() => _isFullScreen = !_isFullScreen);
    widget.onFullScreenChanged?.call(_isFullScreen);
  }

  Future<void> _openLayoutEditor(Orientation orientation) async {
    _activeController.reset();
    final result = await Navigator.of(context).push<ControllerEditResult>(
      MaterialPageRoute(
        builder: (_) => ControllerEditScreen(
          initialControllerType: _controllerType,
          initialPortraitLayout: _portraitLayout,
          initialLandscapeLayout: _landscapeLayout,
          initialOrientation: Orientation.landscape,
        ),
      ),
    );

    if (result != null && mounted) {
      if (result.selectedType != _controllerType) {
        await _switchControllerType(result.selectedType, reloadLayouts: false);
      }
      setState(() {
        _portraitLayout = result.portraitLayout;
        _landscapeLayout = result.landscapeLayout;
      });
    }

    _enterLandscapeFullscreen();
  }

  void _openSettingsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF30363D), width: 1.5),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Row(
                      children: [
                        const Icon(Icons.vibration, color: Color(0xFFFFB74D), size: 22),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Gamepad & Touch Settings',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white12),

                    // Section 0: Controller Type Selection
                    const Row(
                      children: [
                        Icon(Icons.tune, color: Color(0xFF00E676), size: 18),
                        SizedBox(width: 8),
                        Text(
                          'Active Controller Layout',
                          style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF21262D),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF30363D)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<ControllerType>(
                          value: _controllerType,
                          isExpanded: true,
                          dropdownColor: const Color(0xFF161B22),
                          icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF00E676)),
                          items: ControllerType.values.map((t) {
                            return DropdownMenuItem(
                              value: t,
                              child: Row(
                                children: [
                                  Icon(
                                    t == ControllerType.n64 ? Icons.videogame_asset : Icons.sports_esports,
                                    size: 18,
                                    color: t == _controllerType ? const Color(0xFF00E676) : Colors.white70,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    ControllerFactory.getDisplayName(t),
                                    style: TextStyle(
                                      color: t == _controllerType ? const Color(0xFF00E676) : Colors.white,
                                      fontWeight: t == _controllerType ? FontWeight.bold : FontWeight.normal,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                          onChanged: (newType) {
                            if (newType != null) {
                              setSheetState(() => _controllerType = newType);
                              _switchControllerType(newType);
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Section 1: Vibration Intensity
                    const Row(
                      children: [
                        Icon(Icons.touch_app, color: Color(0xFF00E676), size: 18),
                        SizedBox(width: 8),
                        Text(
                          'Haptic Feedback Settings',
                          style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Enable Haptics', style: TextStyle(color: Colors.white, fontSize: 14)),
                      subtitle: const Text('Tactile response on button touch', style: TextStyle(color: Colors.white54, fontSize: 11)),
                      value: _hapticSettings.enabled,
                      activeThumbColor: const Color(0xFF00E676),
                      onChanged: (val) {
                        final updated = _hapticSettings.copyWith(enabled: val);
                        setState(() => _hapticSettings = updated);
                        setSheetState(() => _hapticSettings = updated);
                        HapticSettings.save(updated);
                      },
                    ),

                    if (_hapticSettings.enabled) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Text('Strength: ', style: TextStyle(color: Colors.white70, fontSize: 13)),
                          const SizedBox(width: 8),
                          ...HapticStrength.values.map((s) {
                            final isSel = _hapticSettings.strength == s;
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(s.name.toUpperCase()),
                                selected: isSel,
                                selectedColor: const Color(0xFF00E676),
                                labelStyle: TextStyle(
                                  color: isSel ? Colors.black : Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                                onSelected: (sel) {
                                  if (sel) {
                                    final updated = _hapticSettings.copyWith(strength: s);
                                    setState(() => _hapticSettings = updated);
                                    setSheetState(() => _hapticSettings = updated);
                                    HapticSettings.save(updated);
                                    updated.executeFeedback();
                                  }
                                },
                              ),
                            );
                          }),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Vibrate on Button Press', style: TextStyle(color: Colors.white, fontSize: 14)),
                        subtitle: const Text('Click feel when pressing A, B, X, Y, C buttons', style: TextStyle(color: Colors.white54, fontSize: 11)),
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
                        title: const Text('Vibrate on D-Pad Rolling', style: TextStyle(color: Colors.white, fontSize: 14)),
                        subtitle: const Text('Subtle tick when thumb slides across sectors', style: TextStyle(color: Colors.white54, fontSize: 11)),
                        value: _hapticSettings.vibrateOnDirectionChange,
                        activeThumbColor: const Color(0xFF00E676),
                        onChanged: (val) {
                          final updated = _hapticSettings.copyWith(vibrateOnDirectionChange: val);
                          setState(() => _hapticSettings = updated);
                          setSheetState(() => _hapticSettings = updated);
                          HapticSettings.save(updated);
                        },
                      ),
                    ],

                    const Divider(color: Colors.white12),

                    // Section 2: Ergonomics
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
                      subtitle: const Text('Rest single thumb between A & B for run+jump', style: TextStyle(color: Colors.white54, fontSize: 11)),
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
                      subtitle: const Text('Slide thumb without lifting; auto-activates diagonals', style: TextStyle(color: Colors.white54, fontSize: 11)),
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
      canPop: true,
      child: OrientationBuilder(
        builder: (context, orientation) {
          // Always use landscape layout for the fullscreen gamepad
          final layout = _landscapeLayout;

          return Scaffold(
            backgroundColor: const Color(0xFF0D0D12),
            body: SafeArea(
              child: Stack(
                children: [
                  // Full background touchable area
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);

                        if (_controllerType == ControllerType.nes) {
                          // ==========================================
                          // NES GAMEPAD LAYOUT (1 DIAL PAD)
                          // ==========================================
                          return Stack(
                            children: [
                              // 1. D-Pad / Left Movement Stick (Dialer 1)
                              _buildPositionedCluster(
                                layout: layout.dpad,
                                canvasSize: canvasSize,
                                child: layout.directionType == DirectionControlType.joystick
                                    ? _buildNesJoystick(layout.dpad.scale)
                                    : _buildNesDpad(layout.dpad.scale),
                              ),

                              // 2. Select / Start Cluster
                              _buildPositionedCluster(
                                layout: layout.menuButtons,
                                canvasSize: canvasSize,
                                child: _buildNesMenuCluster(layout.menuButtons.scale),
                              ),

                              // 3. ABXY Action Buttons Cluster (B and A with A+B bridge)
                              _buildPositionedCluster(
                                layout: layout.actionButtons,
                                canvasSize: canvasSize,
                                child: _buildNesAbxyCluster(layout.actionButtons.scale),
                              ),
                            ],
                          );
                        } else {
                          // ==========================================
                          // N64 GAMEPAD LAYOUT (DUAL DIALERS)
                          // ==========================================
                          return Stack(
                            children: [
                              // 1. Left Movement Dial (Dialer 1: 360° Analog Joystick / D-Pad)
                              _buildPositionedCluster(
                                layout: layout.dpad,
                                canvasSize: canvasSize,
                                child: layout.directionType == DirectionControlType.joystick
                                    ? _buildN64Joystick(layout.dpad.scale)
                                    : _buildN64Dpad(layout.dpad.scale),
                              ),

                              // 2. Center Start Button
                              _buildPositionedCluster(
                                layout: layout.menuButtons,
                                canvasSize: canvasSize,
                                child: _buildN64StartButton(layout.menuButtons.scale),
                              ),

                              // 3. Right Cluster (Dialer 2: Yellow C-Buttons Dial Pad + A & B Action Buttons)
                              _buildPositionedCluster(
                                layout: layout.actionButtons,
                                canvasSize: canvasSize,
                                child: _buildN64RightCluster(layout.actionButtons.scale),
                              ),

                              // 4. Top Shoulder & Triggers Bar (L Bumper, Z-Trigger, R Bumper)
                              _buildN64ShoulderTriggers(canvasSize, orientation),
                            ],
                          );
                        }
                      },
                    ),
                  ),

                  // Top Chrome Bar (ALWAYS contains D-Pad switch & Vibration settings on zoom!)
                  Positioned(
                    top: 10,
                    left: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B1B22).withValues(alpha: _isFullScreen ? 0.80 : 0.92),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white12),
                        boxShadow: const [
                          BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 2)),
                        ],
                      ),
                      child: Row(
                        children: [
                          // Left Cluster: Controller Type Dropdown + Connection Indicator + ACK Badge
                          PopupMenuButton<ControllerType>(
                            tooltip: 'Select Controller Type (NES / N64)',
                            initialValue: _controllerType,
                            onSelected: (type) => _switchControllerType(type),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF21262D),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFF30363D)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _controllerType == ControllerType.n64 ? Icons.videogame_asset : Icons.sports_esports,
                                    size: 13,
                                    color: const Color(0xFF00E676),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    ControllerFactory.getShortName(_controllerType),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 10,
                                    ),
                                  ),
                                  const Icon(Icons.arrow_drop_down, color: Colors.white70, size: 14),
                                ],
                              ),
                            ),
                            itemBuilder: (_) => ControllerType.values
                                .map(
                                  (type) => PopupMenuItem(
                                    value: type,
                                    child: Row(
                                      children: [
                                        Icon(
                                          type == ControllerType.n64 ? Icons.videogame_asset : Icons.sports_esports,
                                          color: type == _controllerType ? const Color(0xFF00E676) : Colors.white70,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          ControllerFactory.getDisplayName(type),
                                          style: TextStyle(
                                            color: type == _controllerType ? const Color(0xFF00E676) : Colors.white,
                                            fontWeight: type == _controllerType ? FontWeight.bold : FontWeight.normal,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                          ),

                          const SizedBox(width: 4),

                          // Connection indicator
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: orientation == Orientation.landscape ? 240 : 65,
                            ),
                            child: StreamBuilder<ConnectionStatus>(
                              stream: widget.connectionManager.statusStream,
                              initialData: widget.connectionManager.status,
                              builder: (context, snapshot) {
                                final isConnected = snapshot.data == ConnectionStatus.connected;
                                final hostName = widget.connectionManager.connectedDevice?.name ?? 'No Device';

                                return Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: isConnected ? const Color(0xFF00E676) : Colors.orangeAccent,
                                      ),
                                    ),
                                    const SizedBox(width: 3),
                                    Flexible(
                                      child: Text(
                                        isConnected ? hostName : 'Offline',
                                        style: TextStyle(
                                          color: isConnected ? Colors.white : Colors.white60,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 10,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),

                          // ACK Confirmation Badge
                          if (_lastAck != null) ...[
                            const SizedBox(width: 4),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: _lastAck!.success
                                    ? (_ackPulsing
                                        ? const Color(0xFF00E676).withValues(alpha: 0.35)
                                        : const Color(0xFF00E676).withValues(alpha: 0.12))
                                    : Colors.redAccent.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: _lastAck!.success
                                      ? (_ackPulsing ? const Color(0xFF00E676) : const Color(0xFF00E676).withValues(alpha: 0.4))
                                      : Colors.redAccent,
                                  width: 1,
                                ),
                              ),
                              child: Text(
                                _lastAck!.success ? '${_lastAck!.latencyMs}ms' : 'DROP',
                                style: TextStyle(
                                  color: _lastAck!.success ? const Color(0xFF00E676) : Colors.redAccent,
                                  fontSize: 8,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],

                          // Spacer pushes all action icons to the right top
                          const Spacer(),

                          // Right Cluster: Action Icons (D-Pad switch, Vibration settings, ROMs, Edit, Fullscreen)
                          // 1. Direction Mode Toggle (D-Pad <-> Joystick)
                          _buildCompactActionIcon(
                            icon: layout.directionType == DirectionControlType.joystick
                                ? Icons.sports_esports
                                : Icons.gamepad,
                            color: const Color(0xFF00E676),
                            tooltip: layout.directionType == DirectionControlType.joystick
                                ? 'Current: Joystick (Tap for D-Pad)'
                                : 'Current: D-Pad (Tap for Joystick)',
                            onPressed: () {
                              final nextType = layout.directionType == DirectionControlType.joystick
                                  ? DirectionControlType.dpad
                                  : DirectionControlType.joystick;
                              setState(() {
                                if (orientation == Orientation.landscape) {
                                  _landscapeLayout = _landscapeLayout.copyWith(directionType: nextType);
                                  ControllerLayout.save(Orientation.landscape, _landscapeLayout, controllerType: _controllerType);
                                } else {
                                  _portraitLayout = _portraitLayout.copyWith(directionType: nextType);
                                  ControllerLayout.save(Orientation.portrait, _portraitLayout, controllerType: _controllerType);
                                }
                              });
                            },
                          ),

                          // 2. Vibration & Touch Accuracy Settings
                          _buildCompactActionIcon(
                            icon: Icons.vibration,
                            color: const Color(0xFFFFB74D),
                            tooltip: 'Vibration Settings',
                            onPressed: () => _openSettingsSheet(context),
                          ),

                          // Add ROMs (Push to TV / Local Server)
                          if (!_isFullScreen)
                            _buildCompactActionIcon(
                              icon: Icons.send_to_mobile_rounded,
                              color: const Color(0xFF00E676),
                              tooltip: 'Add ROMs / Push to TV',
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (_) => AddRomsDialog(
                                    targetDevice: widget.connectionManager.connectedDevice,
                                  ),
                                );
                              },
                            ),

                          // Layout Edit Button
                          if (!_isFullScreen)
                            _buildCompactActionIcon(
                              icon: Icons.tune,
                              color: const Color(0xFF64B5F6),
                              tooltip: 'Edit Layout & Size',
                              onPressed: () => _openLayoutEditor(orientation),
                            ),

                          // Fullscreen / Zoom Toggle
                          _buildCompactActionIcon(
                            icon: _isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                            color: Colors.white,
                            tooltip: _isFullScreen ? 'Exit Zoom' : 'Zoom (Hide Tools)',
                            onPressed: _toggleFullScreen,
                          ),

                          // Exit Gamepad Button
                          _buildCompactActionIcon(
                            icon: Icons.close_rounded,
                            color: const Color(0xFFEF5350),
                            tooltip: 'Exit Gamepad',
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Hint Banner at bottom
                  if (!_isFullScreen)
                    Positioned(
                      bottom: 4,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            _controllerType == ControllerType.n64
                                ? 'N64 Mode: Dual Dialers (Left Stick + Yellow C-Dial) • Blue A=Jump, Green B=Attack'
                                : 'NES Mode: 1 Dialer Pad • Red A=Jump, Yellow B=Run • A+B Bridge Active',
                            style: const TextStyle(color: Colors.white38, fontSize: 10),
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
  // NES CONTROLLER CLUSTERS (1 DIAL PAD)
  // ==========================================

  Widget _buildNesJoystick(double scale) {
    return VirtualJoystick(
      scale: scale,
      onTouchDown: () => _triggerHaptic(HapticTriggerType.buttonPress),
      onDirectionChanged: (x, y) {
        _nes.setJoystick(x, y);
      },
      onReleased: () {
        _nes.resetJoystick();
      },
    );
  }

  Widget _buildNesDpad(double scale) {
    final btnSize = 52.0 * scale;
    final totalSize = btnSize * 3.0;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => _handleNesDpadPointer(event.localPosition, totalSize, btnSize, isInitialDown: true),
      onPointerMove: (event) => _handleNesDpadPointer(event.localPosition, totalSize, btnSize),
      onPointerUp: (_) => _releaseNesDpad(),
      onPointerCancel: (_) => _releaseNesDpad(),
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
            // Vertical bar
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
            // Horizontal bar
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
            // Directional indicators
            Positioned(
              top: 0,
              left: btnSize,
              width: btnSize,
              height: btnSize,
              child: _buildDpadDirectionFace(Icons.arrow_drop_up, isPressed: _nes.isUpPressed),
            ),
            Positioned(
              bottom: 0,
              left: btnSize,
              width: btnSize,
              height: btnSize,
              child: _buildDpadDirectionFace(Icons.arrow_drop_down, isPressed: _nes.isDownPressed),
            ),
            Positioned(
              left: 0,
              top: btnSize,
              width: btnSize,
              height: btnSize,
              child: _buildDpadDirectionFace(Icons.arrow_left, isPressed: _nes.isLeftPressed),
            ),
            Positioned(
              right: 0,
              top: btnSize,
              width: btnSize,
              height: btnSize,
              child: _buildDpadDirectionFace(Icons.arrow_right, isPressed: _nes.isRightPressed),
            ),
            // 4 Corner Diagonal Combo Dots
            Positioned(
              top: btnSize * 0.1,
              right: btnSize * 0.1,
              child: _buildDiagonalAccent(_nes.isUpPressed && _nes.isRightPressed),
            ),
            Positioned(
              bottom: btnSize * 0.1,
              right: btnSize * 0.1,
              child: _buildDiagonalAccent(_nes.isDownPressed && _nes.isRightPressed),
            ),
            Positioned(
              bottom: btnSize * 0.1,
              left: btnSize * 0.1,
              child: _buildDiagonalAccent(_nes.isDownPressed && _nes.isLeftPressed),
            ),
            Positioned(
              top: btnSize * 0.1,
              left: btnSize * 0.1,
              child: _buildDiagonalAccent(_nes.isUpPressed && _nes.isLeftPressed),
            ),
            // Central neutral hub with tactile grip ring
            Container(
              width: btnSize * 0.85,
              height: btnSize * 0.85,
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

  void _handleNesDpadPointer(Offset localPos, double totalSize, double btnSize, {bool isInitialDown = false}) {
    final center = Offset(totalSize / 2, totalSize / 2);
    final delta = localPos - center;
    final distance = delta.distance;
    final deadzone = btnSize * 0.38;

    if (distance < deadzone) {
      if (_activeDpadSector != 0) {
        _activeDpadSector = 0;
        _nes.setDpad(up: false, down: false, left: false, right: false);
        setState(() {});
      }
      return;
    }

    var angleDeg = math.atan2(delta.dy, delta.dx) * 180 / math.pi;
    if (angleDeg < 0) angleDeg += 360;

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
      _nes.setDpad(up: up, down: down, left: left, right: right);
      setState(() {});
    }
  }

  void _releaseNesDpad() {
    if (_activeDpadSector != 0) {
      _activeDpadSector = 0;
      _nes.setDpad(up: false, down: false, left: false, right: false);
      setState(() {});
    }
  }

  Widget _buildDpadDirectionFace(IconData icon, {required bool isPressed}) {
    return Center(
      child: Icon(
        icon,
        size: 32,
        color: isPressed ? const Color(0xFF00E676) : Colors.white60,
      ),
    );
  }

  Widget _buildCompactActionIcon({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        icon: Icon(icon, color: color, size: 16),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildDiagonalAccent(bool isActive) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 50),
      width: 13,
      height: 13,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isActive ? const Color(0xFF00E676).withValues(alpha: 0.7) : const Color(0xFF252530),
        border: Border.all(
          color: isActive ? const Color(0xFF00E676) : Colors.white24,
          width: 1.2,
        ),
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: const Color(0xFF00E676).withValues(alpha: 0.6),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
    );
  }

  Widget _buildNesAbxyCluster(double scale) {
    final btnSize = 50.0 * scale;
    final clusterSize = btnSize * 3.1;
    final clusterCenter = clusterSize / 2;
    final btnOffset = btnSize * 0.90;

    final posA = Offset(clusterCenter + btnOffset, clusterCenter);
    final posB = Offset(clusterCenter, clusterCenter + btnOffset);
    final posX = Offset(clusterCenter, clusterCenter - btnOffset);
    final posY = Offset(clusterCenter - btnOffset, clusterCenter);
    final posAB = (posA + posB) / 2;

    final isABComboActive = _nes.isAPressed && _nes.isBPressed;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        _actionPointers[e.pointer] = e.localPosition;
        _evaluateNesActionButtons(btnSize, posA, posB, posX, posY, posAB);
      },
      onPointerMove: (e) {
        _actionPointers[e.pointer] = e.localPosition;
        _evaluateNesActionButtons(btnSize, posA, posB, posX, posY, posAB);
      },
      onPointerUp: (e) {
        _actionPointers.remove(e.pointer);
        _evaluateNesActionButtons(btnSize, posA, posB, posX, posY, posAB);
      },
      onPointerCancel: (e) {
        _actionPointers.remove(e.pointer);
        _evaluateNesActionButtons(btnSize, posA, posB, posX, posY, posAB);
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
            // A+B Combo Bridge Pill
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

            // Button X (Top)
            Positioned(
              left: posX.dx - btnSize / 2,
              top: posX.dy - btnSize / 2,
              child: _buildButtonFace('X', _nes.isXPressed, btnSize, const Color(0xFF1E88E5)),
            ),

            // Button Y (Left)
            Positioned(
              left: posY.dx - btnSize / 2,
              top: posY.dy - btnSize / 2,
              child: _buildButtonFace('Y', _nes.isYPressed, btnSize, const Color(0xFF43A047)),
            ),

            // Button A (Right - Red / Jump)
            Positioned(
              left: posA.dx - btnSize / 2,
              top: posA.dy - btnSize / 2,
              child: _buildButtonFace('A', _nes.isAPressed, btnSize, const Color(0xFFE53935)),
            ),

            // Button B (Bottom - Yellow / Run)
            Positioned(
              left: posB.dx - btnSize / 2,
              top: posB.dy - btnSize / 2,
              child: _buildButtonFace('B', _nes.isBPressed, btnSize, const Color(0xFFFBC02D)),
            ),
          ],
        ),
      ),
    );
  }

  void _evaluateNesActionButtons(
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

    _updateNesActionState(NesButton.a, nextA, _nes.isAPressed);
    _updateNesActionState(NesButton.b, nextB, _nes.isBPressed);
    _updateNesActionState(NesButton.x, nextX, _nes.isXPressed);
    _updateNesActionState(NesButton.y, nextY, _nes.isYPressed);
  }

  void _updateNesActionState(NesButton btn, bool nextState, bool currentState) {
    if (nextState != currentState) {
      if (nextState) {
        _triggerHaptic(HapticTriggerType.buttonPress);
        _nes.pressButton(btn);
      } else {
        _nes.releaseButton(btn);
      }
      setState(() {});
    }
  }

  Widget _buildNesMenuCluster(double scale) {
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
          _buildNesPillButton('SELECT', NesButton.select, _nes.isSelectPressed, btnW, btnH),
          SizedBox(width: 16 * scale),
          _buildNesPillButton('START', NesButton.start, _nes.isStartPressed, btnW, btnH),
        ],
      ),
    );
  }

  Widget _buildNesPillButton(
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
            setState(() => _nes.pressButton(button));
          },
          onPointerUp: (_) {
            setState(() => _nes.releaseButton(button));
          },
          onPointerCancel: (_) {
            setState(() => _nes.releaseButton(button));
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

  // ==========================================
  // N64 CONTROLLER CLUSTERS (DUAL DIALERS!)
  // ==========================================

  Widget _buildN64Joystick(double scale) {
    return VirtualJoystick(
      scale: scale,
      onTouchDown: () => _triggerHaptic(HapticTriggerType.buttonPress),
      onDirectionChanged: (x, y) {
        _n64.setStick(x, y);
      },
      onReleased: () {
        _n64.resetStick();
      },
    );
  }

  Widget _buildN64Dpad(double scale) {
    final btnSize = 52.0 * scale;
    final totalSize = btnSize * 3.0;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => _handleN64DpadPointer(event.localPosition, totalSize, btnSize, isInitialDown: true),
      onPointerMove: (event) => _handleN64DpadPointer(event.localPosition, totalSize, btnSize),
      onPointerUp: (_) => _releaseN64Dpad(),
      onPointerCancel: (_) => _releaseN64Dpad(),
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
            Container(
              width: btnSize,
              height: totalSize,
              decoration: BoxDecoration(
                color: const Color(0xFF1B1B22),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF33333E), width: 1.5),
              ),
            ),
            Container(
              width: totalSize,
              height: btnSize,
              decoration: BoxDecoration(
                color: const Color(0xFF1B1B22),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF33333E), width: 1.5),
              ),
            ),
            Positioned(
              top: 0,
              left: btnSize,
              width: btnSize,
              height: btnSize,
              child: _buildDpadDirectionFace(Icons.arrow_drop_up, isPressed: _n64.isDpadUpPressed),
            ),
            Positioned(
              bottom: 0,
              left: btnSize,
              width: btnSize,
              height: btnSize,
              child: _buildDpadDirectionFace(Icons.arrow_drop_down, isPressed: _n64.isDpadDownPressed),
            ),
            Positioned(
              left: 0,
              top: btnSize,
              width: btnSize,
              height: btnSize,
              child: _buildDpadDirectionFace(Icons.arrow_left, isPressed: _n64.isDpadLeftPressed),
            ),
            Positioned(
              right: 0,
              top: btnSize,
              width: btnSize,
              height: btnSize,
              child: _buildDpadDirectionFace(Icons.arrow_right, isPressed: _n64.isDpadRightPressed),
            ),
            // 4 Corner Diagonal Combo Dots
            Positioned(
              top: btnSize * 0.1,
              right: btnSize * 0.1,
              child: _buildDiagonalAccent(_n64.isDpadUpPressed && _n64.isDpadRightPressed),
            ),
            Positioned(
              bottom: btnSize * 0.1,
              right: btnSize * 0.1,
              child: _buildDiagonalAccent(_n64.isDpadDownPressed && _n64.isDpadRightPressed),
            ),
            Positioned(
              bottom: btnSize * 0.1,
              left: btnSize * 0.1,
              child: _buildDiagonalAccent(_n64.isDpadDownPressed && _n64.isDpadLeftPressed),
            ),
            Positioned(
              top: btnSize * 0.1,
              left: btnSize * 0.1,
              child: _buildDiagonalAccent(_n64.isDpadUpPressed && _n64.isDpadLeftPressed),
            ),
            // Central neutral hub with tactile grip ring
            Container(
              width: btnSize * 0.85,
              height: btnSize * 0.85,
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

  void _handleN64DpadPointer(Offset localPos, double totalSize, double btnSize, {bool isInitialDown = false}) {
    final center = Offset(totalSize / 2, totalSize / 2);
    final delta = localPos - center;
    final distance = delta.distance;
    final deadzone = btnSize * 0.38;

    if (distance < deadzone) {
      if (_activeDpadSector != 0) {
        _activeDpadSector = 0;
        _n64.setDpad(up: false, down: false, left: false, right: false);
        setState(() {});
      }
      return;
    }

    var angleDeg = math.atan2(delta.dy, delta.dx) * 180 / math.pi;
    if (angleDeg < 0) angleDeg += 360;

    final sector = (((angleDeg + 22.5) % 360) / 45).floor();
    final sectorCode = sector + 1;

    bool up = false;
    bool down = false;
    bool left = false;
    bool right = false;

    switch (sector) {
      case 0: right = true; break;
      case 1: down = true; right = true; break;
      case 2: down = true; break;
      case 3: down = true; left = true; break;
      case 4: left = true; break;
      case 5: up = true; left = true; break;
      case 6: up = true; break;
      case 7: up = true; right = true; break;
    }

    if (_activeDpadSector != sectorCode) {
      _activeDpadSector = sectorCode;
      _triggerHaptic(isInitialDown ? HapticTriggerType.buttonPress : HapticTriggerType.directionChange);
      _n64.setDpad(up: up, down: down, left: left, right: right);
      setState(() {});
    }
  }

  void _releaseN64Dpad() {
    if (_activeDpadSector != 0) {
      _activeDpadSector = 0;
      _n64.setDpad(up: false, down: false, left: false, right: false);
      setState(() {});
    }
  }

  // Right Cluster for N64: Yellow C-Buttons Dial Pad + Action Buttons A & B
  Widget _buildN64RightCluster(double scale) {
    final cDialSize = 135.0 * scale;
    final abBtnSize = 46.0 * scale;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Action Buttons A (Blue - Jump) & B (Green - Attack)
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // B Button (Green)
            GestureDetector(
              onTapDown: (_) {
                _triggerHaptic(HapticTriggerType.buttonPress);
                setState(() => _n64.pressButton(N64Button.b));
              },
              onTapUp: (_) => setState(() => _n64.releaseButton(N64Button.b)),
              onTapCancel: () => setState(() => _n64.releaseButton(N64Button.b)),
              child: _buildButtonFace('B', _n64.isBPressed, abBtnSize, const Color(0xFF2E7D32)),
            ),
            const SizedBox(height: 14),
            // A Button (Blue - Jump)
            GestureDetector(
              onTapDown: (_) {
                _triggerHaptic(HapticTriggerType.buttonPress);
                setState(() => _n64.pressButton(N64Button.a));
              },
              onTapUp: (_) => setState(() => _n64.releaseButton(N64Button.a)),
              onTapCancel: () => setState(() => _n64.releaseButton(N64Button.a)),
              child: _buildButtonFace('A', _n64.isAPressed, abBtnSize * 1.12, const Color(0xFF1565C0)),
            ),
          ],
        ),

        const SizedBox(width: 14),

        // Dialer Pad 2: Yellow C-Buttons Diamond Dial Pad
        _buildN64CButtonsDial(cDialSize, scale),
      ],
    );
  }

  Widget _buildN64CButtonsDial(double totalSize, double scale) {
    final btnSize = 36.0 * scale;
    final center = totalSize / 2;
    final offset = btnSize * 0.95;

    final posCUp = Offset(center, center - offset);
    final posCDown = Offset(center, center + offset);
    final posCLeft = Offset(center - offset, center);
    final posCRight = Offset(center + offset, center);

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => _handleCStickPointer(e.localPosition, center, offset),
      onPointerMove: (e) => _handleCStickPointer(e.localPosition, center, offset),
      onPointerUp: (_) => _releaseCStick(),
      onPointerCancel: (_) => _releaseCStick(),
      child: Container(
        width: totalSize,
        height: totalSize,
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E26).withValues(alpha: 0.85),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFFFD600).withValues(alpha: 0.35), width: 1.8),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 4)),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Center yellow N64 "C" badge
            Container(
              width: btnSize * 0.78,
              height: btnSize * 0.78,
              decoration: BoxDecoration(
                color: const Color(0xFFFFD600).withValues(alpha: 0.18),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFFFD600).withValues(alpha: 0.5)),
              ),
              child: const Center(
                child: Text(
                  'C',
                  style: TextStyle(
                    color: Color(0xFFFFD600),
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            // C-Up (▲)
            Positioned(
              left: posCUp.dx - btnSize / 2,
              top: posCUp.dy - btnSize / 2,
              child: _buildCButtonFace('▲', _n64.isCUpPressed, btnSize),
            ),
            // C-Down (▼)
            Positioned(
              left: posCDown.dx - btnSize / 2,
              top: posCDown.dy - btnSize / 2,
              child: _buildCButtonFace('▼', _n64.isCDownPressed, btnSize),
            ),
            // C-Left (◀)
            Positioned(
              left: posCLeft.dx - btnSize / 2,
              top: posCLeft.dy - btnSize / 2,
              child: _buildCButtonFace('◀', _n64.isCLeftPressed, btnSize),
            ),
            // C-Right (▶)
            Positioned(
              left: posCRight.dx - btnSize / 2,
              top: posCRight.dy - btnSize / 2,
              child: _buildCButtonFace('▶', _n64.isCRightPressed, btnSize),
            ),
          ],
        ),
      ),
    );
  }

  void _handleCStickPointer(Offset localPos, double center, double offset) {
    final dx = (localPos.dx - center) / offset;
    final dy = (localPos.dy - center) / offset;

    bool up = dy < -0.35;
    bool down = dy > 0.35;
    bool left = dx < -0.35;
    bool right = dx > 0.35;

    _n64.setCButtons(up: up, down: down, left: left, right: right);
    setState(() {});
  }

  void _releaseCStick() {
    _n64.setCButtons(up: false, down: false, left: false, right: false);
    setState(() {});
  }

  Widget _buildCButtonFace(String symbol, bool isPressed, double size) {
    const yellow = Color(0xFFFFD600);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 40),
      width: size,
      height: size,
      transform: isPressed ? Matrix4.translationValues(0, 2, 0) : Matrix4.identity(),
      decoration: BoxDecoration(
        color: isPressed ? yellow.withValues(alpha: 0.85) : const Color(0xFF2A2A1A),
        shape: BoxShape.circle,
        border: Border.all(
          color: isPressed ? Colors.white : yellow,
          width: 1.8,
        ),
        boxShadow: [
          if (isPressed)
            BoxShadow(color: yellow.withValues(alpha: 0.6), blurRadius: 6, spreadRadius: 1),
        ],
      ),
      child: Center(
        child: Text(
          symbol,
          style: TextStyle(
            color: isPressed ? Colors.black : yellow,
            fontSize: size * 0.42,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  // N64 Top Shoulder & Triggers Bar (L, Z-Trigger, R)
  Widget _buildN64ShoulderTriggers(Size canvasSize, Orientation orientation) {
    return Positioned(
      top: 54,
      left: 14,
      right: 14,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Left Shoulder Group: L Bumper & Z-Trigger
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // L Bumper
              _buildShoulderButton('L', N64Button.lBumper, _n64.isLPressed, width: 64, height: 32),
              const SizedBox(width: 8),
              // Z-Trigger (Prominent Tactical Trigger!)
              _buildZTriggerButton(),
            ],
          ),

          // Right Shoulder Group: R Bumper
          _buildShoulderButton('R', N64Button.rBumper, _n64.isRPressed, width: 64, height: 32),
        ],
      ),
    );
  }

  Widget _buildZTriggerButton() {
    final isPressed = _n64.isZPressed;
    return Listener(
      onPointerDown: (_) {
        _triggerHaptic(HapticTriggerType.buttonPress);
        setState(() => _n64.pressButton(N64Button.zTrigger));
      },
      onPointerUp: (_) => setState(() => _n64.releaseButton(N64Button.zTrigger)),
      onPointerCancel: (_) => setState(() => _n64.releaseButton(N64Button.zTrigger)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 40),
        width: 82,
        height: 34,
        decoration: BoxDecoration(
          color: isPressed ? const Color(0xFFD32F2F) : const Color(0xFF263238),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isPressed ? Colors.white : const Color(0xFFFF5252).withValues(alpha: 0.6),
            width: 1.8,
          ),
          boxShadow: [
            if (isPressed)
              BoxShadow(
                color: Colors.redAccent.withValues(alpha: 0.6),
                blurRadius: 8,
                spreadRadius: 1,
              ),
          ],
        ),
        child: const Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bolt, color: Colors.white, size: 14),
              SizedBox(width: 2),
              Text(
                'Z-TRIG',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShoulderButton(
    String label,
    N64Button button,
    bool isPressed, {
    required double width,
    required double height,
  }) {
    return Listener(
      onPointerDown: (_) {
        _triggerHaptic(HapticTriggerType.buttonPress);
        setState(() => _n64.pressButton(button));
      },
      onPointerUp: (_) => setState(() => _n64.releaseButton(button)),
      onPointerCancel: (_) => setState(() => _n64.releaseButton(button)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 40),
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: isPressed ? const Color(0xFF00E676) : const Color(0xFF2B2B36),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isPressed ? Colors.white : Colors.white24,
            width: 1.5,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: isPressed ? Colors.black : Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildN64StartButton(double scale) {
    final size = 44.0 * scale;
    final isPressed = _n64.isStartPressed;

    return Listener(
      onPointerDown: (_) {
        _triggerHaptic(HapticTriggerType.buttonPress);
        setState(() => _n64.pressButton(N64Button.start));
      },
      onPointerUp: (_) => setState(() => _n64.releaseButton(N64Button.start)),
      onPointerCancel: (_) => setState(() => _n64.releaseButton(N64Button.start)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 40),
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: isPressed ? const Color(0xFFFF5252) : const Color(0xFFB71C1C),
              shape: BoxShape.circle,
              border: Border.all(color: isPressed ? Colors.white : Colors.white24, width: 2),
              boxShadow: [
                BoxShadow(
                  color: isPressed ? Colors.redAccent.withValues(alpha: 0.6) : Colors.black45,
                  blurRadius: isPressed ? 8 : 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Center(
              child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 20),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'START',
            style: TextStyle(
              color: Color(0xFFE53935),
              fontWeight: FontWeight.bold,
              fontSize: 10,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
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
}
