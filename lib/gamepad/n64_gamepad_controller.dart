import 'dart:async';
import 'dart:math' as math;
import '../hid/ble_logger.dart';
import 'gamepad_controller.dart';

enum N64Button {
  a,
  b,
  zTrigger,
  lBumper,
  rBumper,
  start,
  cUp,
  cDown,
  cLeft,
  cRight,
  dpadUp,
  dpadDown,
  dpadLeft,
  dpadRight,
}

/// N64 Gamepad Controller implementation for Bluetooth HID.
/// Features dual dialers:
/// 1. Main Left Analog Movement Stick (X, Y axes) + D-Pad
/// 2. Right Yellow C-Buttons Dialer Pad (C-Up, C-Down, C-Left, C-Right) + Right Stick (Z, Rz)
/// Action buttons: A (Blue - Jump), B (Green - Attack/Punch), Z-Trigger, L/R Bumpers, Start.
class N64GamepadController extends GamepadController {
  @override
  String get name => 'N64 Gamepad';

  @override
  int get reportId => 1;

  // Main Movement Analog Stick (-1.0 to 1.0)
  double _stickX = 0.0;
  double _stickY = 0.0;
  bool _isStickActive = false;

  // C-Dialer / C-Stick (-1.0 to 1.0)
  double _cStickX = 0.0;
  double _cStickY = 0.0;
  bool _isCStickActive = false;

  // Individual C-Buttons
  bool _cUp = false;
  bool _cDown = false;
  bool _cLeft = false;
  bool _cRight = false;

  // Action & Trigger buttons
  bool _a = false;
  bool _b = false;
  bool _zTrigger = false;
  bool _lBumper = false;
  bool _rBumper = false;
  bool _start = false;

  // D-Pad
  bool _dpadUp = false;
  bool _dpadDown = false;
  bool _dpadLeft = false;
  bool _dpadRight = false;

  // Tap hold tracking to prevent missed taps
  final Map<N64Button, DateTime> _pressTimes = {};
  final Map<N64Button, Timer> _pendingReleaseTimers = {};
  static const Duration minHoldDuration = Duration(milliseconds: 55);

  double get stickX => _stickX;
  double get stickY => _stickY;
  bool get isStickActive => _isStickActive;

  double get cStickX => _cStickX;
  double get cStickY => _cStickY;
  bool get isCStickActive => _isCStickActive;

  bool get isAPressed => _a;
  bool get isBPressed => _b;
  bool get isZPressed => _zTrigger;
  bool get isLPressed => _lBumper;
  bool get isRPressed => _rBumper;
  bool get isStartPressed => _start;
  bool get isCUpPressed => _cUp;
  bool get isCDownPressed => _cDown;
  bool get isCLeftPressed => _cLeft;
  bool get isCRightPressed => _cRight;
  bool get isDpadUpPressed => _dpadUp;
  bool get isDpadDownPressed => _dpadDown;
  bool get isDpadLeftPressed => _dpadLeft;
  bool get isDpadRightPressed => _dpadRight;

  /// Complete USB HID Report Descriptor for N64 Dual-Dial Gamepad:
  /// - 1 Byte Left Stick X (0..255, neutral 128)
  /// - 1 Byte Left Stick Y (0..255, neutral 128)
  /// - 1 Byte Right Stick / C-Stick Z (0..255, neutral 128)
  /// - 1 Byte Right Stick / C-Stick Rz (0..255, neutral 128)
  /// - 1 Byte Hat Switch (D-Pad, 4 bits + 4-bit padding Const, Var, Abs = 0x03)
  /// - 2 Bytes Buttons (16 buttons)
  @override
  List<int> get reportDescriptor => const [
        0x05, 0x01, // USAGE_PAGE (Generic Desktop)
        0x09, 0x05, // USAGE (Game Pad)
        0xA1, 0x01, // COLLECTION (Application)
        0x85, 0x01, //   REPORT_ID (1)

        // Left Analog Stick (X, Y)
        0x05, 0x01, //   USAGE_PAGE (Generic Desktop)
        0x09, 0x30, //   USAGE (X)
        0x09, 0x31, //   USAGE (Y)
        0x15, 0x00, //   LOGICAL_MINIMUM (0)
        0x26, 0xFF, 0x00, // LOGICAL_MAXIMUM (255)
        0x75, 0x08, //   REPORT_SIZE (8)
        0x95, 0x02, //   REPORT_COUNT (2)
        0x81, 0x02, //   INPUT (Data, Var, Abs)

        // Right C-Stick / C-Dialer (Z, Rz)
        0x05, 0x01, //   USAGE_PAGE (Generic Desktop)
        0x09, 0x32, //   USAGE (Z)
        0x09, 0x35, //   USAGE (Rz)
        0x15, 0x00, //   LOGICAL_MINIMUM (0)
        0x26, 0xFF, 0x00, // LOGICAL_MAXIMUM (255)
        0x75, 0x08, //   REPORT_SIZE (8)
        0x95, 0x02, //   REPORT_COUNT (2)
        0x81, 0x02, //   INPUT (Data, Var, Abs)

        // Hat Switch (D-Pad)
        0x05, 0x01, //   USAGE_PAGE (Generic Desktop)
        0x09, 0x39, //   USAGE (Hat switch)
        0x15, 0x01, //   LOGICAL_MINIMUM (1)
        0x25, 0x08, //   LOGICAL_MAXIMUM (8)
        0x35, 0x00, //   PHYSICAL_MINIMUM (0)
        0x46, 0x3B, 0x01, // PHYSICAL_MAXIMUM (315)
        0x65, 0x14, //   UNIT (Eng Rot: Angular Pos)
        0x75, 0x04, //   REPORT_SIZE (4)
        0x95, 0x01, //   REPORT_COUNT (1)
        0x81, 0x42, //   INPUT (Data, Var, Abs, Null)
        // 4-bit padding for hat switch: MUST BE Const, Var, Abs (0x03)
        0x75, 0x04, //   REPORT_SIZE (4)
        0x95, 0x01, //   REPORT_COUNT (1)
        0x81, 0x03, //   INPUT (Const, Var, Abs)

        // 16 Buttons (A, B, Z, C-Up, C-Down, C-Left, C-Right, L, R, Start)
        0x05, 0x09, //   USAGE_PAGE (Button)
        0x19, 0x01, //   USAGE_MINIMUM (Button 1)
        0x29, 0x10, //   USAGE_MAXIMUM (Button 16)
        0x15, 0x00, //   LOGICAL_MINIMUM (0)
        0x25, 0x01, //   LOGICAL_MAXIMUM (1)
        0x75, 0x01, //   REPORT_SIZE (1)
        0x95, 0x10, //   REPORT_COUNT (16)
        0x81, 0x02, //   INPUT (Data, Var, Abs)

        0xC0, // END_COLLECTION
      ];

  /// Updates left analog movement stick coordinates (-1.0 to 1.0).
  void setStick(double x, double y) {
    final clampedX = x.clamp(-1.0, 1.0);
    final clampedY = y.clamp(-1.0, 1.0);
    final mag = math.sqrt(clampedX * clampedX + clampedY * clampedY);
    final wasActive = _isStickActive;
    _isStickActive = mag > 0.08;
    _stickX = _isStickActive ? clampedX : 0.0;
    _stickY = _isStickActive ? clampedY : 0.0;

    if (wasActive != _isStickActive || _isStickActive) {
      BleLogger.instance.info('N64_STICK', '[STICK] X=${_stickX.toStringAsFixed(2)}, Y=${_stickY.toStringAsFixed(2)}');
      dispatchReport();
    }
  }

  void resetStick() {
    if (_isStickActive || _stickX != 0.0 || _stickY != 0.0) {
      _stickX = 0.0;
      _stickY = 0.0;
      _isStickActive = false;
      BleLogger.instance.info('N64_STICK', '[RESET] Stick Center');
      dispatchReport();
    }
  }

  /// Updates C-Stick / C-Dialer coordinates (-1.0 to 1.0).
  void setCStick(double x, double y) {
    final clampedX = x.clamp(-1.0, 1.0);
    final clampedY = y.clamp(-1.0, 1.0);
    final mag = math.sqrt(clampedX * clampedX + clampedY * clampedY);
    final wasActive = _isCStickActive;
    _isCStickActive = mag > 0.12;
    _cStickX = _isCStickActive ? clampedX : 0.0;
    _cStickY = _isCStickActive ? clampedY : 0.0;

    // Also update virtual C-Buttons from C-Stick angle
    if (_isCStickActive) {
      _cLeft = _cStickX < -0.35;
      _cRight = _cStickX > 0.35;
      _cUp = _cStickY < -0.35;
      _cDown = _cStickY > 0.35;
    } else {
      _cLeft = false;
      _cRight = false;
      _cUp = false;
      _cDown = false;
    }

    if (wasActive != _isCStickActive || _isCStickActive) {
      BleLogger.instance.info('N64_C_STICK', '[C_STICK] X=${_cStickX.toStringAsFixed(2)}, Y=${_cStickY.toStringAsFixed(2)}');
      dispatchReport();
    }
  }

  void resetCStick() {
    if (_isCStickActive || _cStickX != 0.0 || _cStickY != 0.0) {
      _cStickX = 0.0;
      _cStickY = 0.0;
      _isCStickActive = false;
      _cUp = false;
      _cDown = false;
      _cLeft = false;
      _cRight = false;
      BleLogger.instance.info('N64_C_STICK', '[RESET] C-Stick Center');
      dispatchReport();
    }
  }

  /// Sets individual C-Buttons directly (C-Up, C-Down, C-Left, C-Right).
  void setCButtons({
    required bool up,
    required bool down,
    required bool left,
    required bool right,
  }) {
    if (_cUp != up || _cDown != down || _cLeft != left || _cRight != right) {
      _cUp = up;
      _cDown = down;
      _cLeft = left;
      _cRight = right;

      // Update virtual C-Stick analog representation as well
      _cStickX = right ? 1.0 : (left ? -1.0 : 0.0);
      _cStickY = down ? 1.0 : (up ? -1.0 : 0.0);
      _isCStickActive = up || down || left || right;

      final pressed = [
        if (up) 'C-UP',
        if (down) 'C-DOWN',
        if (left) 'C-LEFT',
        if (right) 'C-RIGHT',
      ];
      BleLogger.instance.info('N64_C_PAD', '[C_BUTTONS] ${pressed.isEmpty ? "RELEASED" : pressed.join("+")}');
      dispatchReport();
    }
  }

  /// Sets D-Pad directions.
  void setDpad({
    required bool up,
    required bool down,
    required bool left,
    required bool right,
  }) {
    if (_dpadUp != up || _dpadDown != down || _dpadLeft != left || _dpadRight != right) {
      _dpadUp = up;
      _dpadDown = down;
      _dpadLeft = left;
      _dpadRight = right;

      final dirs = [
        if (up) 'UP',
        if (down) 'DOWN',
        if (left) 'LEFT',
        if (right) 'RIGHT',
      ];
      BleLogger.instance.info('N64_DPAD', '[DIRECTION] ${dirs.isEmpty ? "CENTER" : dirs.join("+")}');
      dispatchReport();
    }
  }

  /// Updates button state and dispatches immediately.
  void setButton(N64Button button, bool isPressed) {
    bool changed = false;
    switch (button) {
      case N64Button.a:
        if (_a != isPressed) {
          _a = isPressed;
          changed = true;
        }
        break;
      case N64Button.b:
        if (_b != isPressed) {
          _b = isPressed;
          changed = true;
        }
        break;
      case N64Button.zTrigger:
        if (_zTrigger != isPressed) {
          _zTrigger = isPressed;
          changed = true;
        }
        break;
      case N64Button.lBumper:
        if (_lBumper != isPressed) {
          _lBumper = isPressed;
          changed = true;
        }
        break;
      case N64Button.rBumper:
        if (_rBumper != isPressed) {
          _rBumper = isPressed;
          changed = true;
        }
        break;
      case N64Button.start:
        if (_start != isPressed) {
          _start = isPressed;
          changed = true;
        }
        break;
      case N64Button.cUp:
        if (_cUp != isPressed) {
          _cUp = isPressed;
          _cStickY = isPressed ? -1.0 : 0.0;
          _isCStickActive = _cUp || _cDown || _cLeft || _cRight;
          changed = true;
        }
        break;
      case N64Button.cDown:
        if (_cDown != isPressed) {
          _cDown = isPressed;
          _cStickY = isPressed ? 1.0 : 0.0;
          _isCStickActive = _cUp || _cDown || _cLeft || _cRight;
          changed = true;
        }
        break;
      case N64Button.cLeft:
        if (_cLeft != isPressed) {
          _cLeft = isPressed;
          _cStickX = isPressed ? -1.0 : 0.0;
          _isCStickActive = _cUp || _cDown || _cLeft || _cRight;
          changed = true;
        }
        break;
      case N64Button.cRight:
        if (_cRight != isPressed) {
          _cRight = isPressed;
          _cStickX = isPressed ? 1.0 : 0.0;
          _isCStickActive = _cUp || _cDown || _cLeft || _cRight;
          changed = true;
        }
        break;
      case N64Button.dpadUp:
        if (_dpadUp != isPressed) {
          _dpadUp = isPressed;
          changed = true;
        }
        break;
      case N64Button.dpadDown:
        if (_dpadDown != isPressed) {
          _dpadDown = isPressed;
          changed = true;
        }
        break;
      case N64Button.dpadLeft:
        if (_dpadLeft != isPressed) {
          _dpadLeft = isPressed;
          changed = true;
        }
        break;
      case N64Button.dpadRight:
        if (_dpadRight != isPressed) {
          _dpadRight = isPressed;
          changed = true;
        }
        break;
    }

    if (changed) {
      final action = isPressed ? 'DOWN' : 'UP';
      BleLogger.instance.info('N64_BUTTON', '[$action] ${button.name.toUpperCase()}');
      dispatchReport();
    }
  }

  void pressButton(N64Button button) {
    _pendingReleaseTimers[button]?.cancel();
    _pendingReleaseTimers.remove(button);
    _pressTimes[button] = DateTime.now();
    setButton(button, true);
  }

  void releaseButton(N64Button button) {
    // D-Pad and C-Buttons release immediately for reactive gameplay
    if (button == N64Button.dpadUp ||
        button == N64Button.dpadDown ||
        button == N64Button.dpadLeft ||
        button == N64Button.dpadRight ||
        button == N64Button.cUp ||
        button == N64Button.cDown ||
        button == N64Button.cLeft ||
        button == N64Button.cRight) {
      _pressTimes.remove(button);
      _pendingReleaseTimers[button]?.cancel();
      _pendingReleaseTimers.remove(button);
      setButton(button, false);
      return;
    }

    final pressTime = _pressTimes[button];
    if (pressTime == null) {
      setButton(button, false);
      return;
    }

    final elapsed = DateTime.now().difference(pressTime);
    if (elapsed < minHoldDuration) {
      final remaining = minHoldDuration - elapsed;
      _pendingReleaseTimers[button]?.cancel();
      _pendingReleaseTimers[button] = Timer(remaining, () {
        _pressTimes.remove(button);
        _pendingReleaseTimers.remove(button);
        setButton(button, false);
      });
    } else {
      _pressTimes.remove(button);
      setButton(button, false);
    }
  }

  @override
  void reset() {
    for (final timer in _pendingReleaseTimers.values) {
      timer.cancel();
    }
    _pendingReleaseTimers.clear();
    _pressTimes.clear();

    _stickX = 0.0;
    _stickY = 0.0;
    _isStickActive = false;

    _cStickX = 0.0;
    _cStickY = 0.0;
    _isCStickActive = false;

    _cUp = false;
    _cDown = false;
    _cLeft = false;
    _cRight = false;

    _a = false;
    _b = false;
    _zTrigger = false;
    _lBumper = false;
    _rBumper = false;
    _start = false;

    _dpadUp = false;
    _dpadDown = false;
    _dpadLeft = false;
    _dpadRight = false;

    BleLogger.instance.info('N64', '[RESET] All N64 inputs released');
    dispatchReport();
  }

  int _calculateHatSwitch() {
    // 0 = centered/null, 1=Up, 2=UpRight, 3=Right, 4=DownRight, 5=Down, 6=DownLeft, 7=Left, 8=UpLeft
    if (_dpadUp && _dpadRight) return 2;
    if (_dpadDown && _dpadRight) return 4;
    if (_dpadDown && _dpadLeft) return 6;
    if (_dpadUp && _dpadLeft) return 8;
    if (_dpadUp) return 1;
    if (_dpadRight) return 3;
    if (_dpadDown) return 5;
    if (_dpadLeft) return 7;
    return 0;
  }

  @override
  List<int> buildReport() {
    // 1. Left Stick X & Y (0..255, neutral 128)
    int lx = ((_stickX.clamp(-1.0, 1.0) + 1.0) * 127.5).round().clamp(0, 255);
    int ly = ((_stickY.clamp(-1.0, 1.0) + 1.0) * 127.5).round().clamp(0, 255);

    // If analog stick is centered but D-Pad is pressed, mirror to left stick for full compatibility
    if (!_isStickActive) {
      if (_dpadLeft && !_dpadRight) lx = 0;
      if (_dpadRight && !_dpadLeft) lx = 255;
      if (_dpadUp && !_dpadDown) ly = 0;
      if (_dpadDown && !_dpadUp) ly = 255;
    }

    // 2. Right Stick / C-Stick Z & Rz (0..255, neutral 128)
    int rx = ((_cStickX.clamp(-1.0, 1.0) + 1.0) * 127.5).round().clamp(0, 255);
    int ry = ((_cStickY.clamp(-1.0, 1.0) + 1.0) * 127.5).round().clamp(0, 255);

    // 3. D-Pad Hat Switch (4 bits)
    final hat = _calculateHatSwitch() & 0x0F;

    // 4. Buttons 1..8:
    // In Android / N64 emulators (RetroArch / Mupen64Plus):
    // Button 1 (bit 0): B / Attack in RetroPad, or A
    // Button 2 (bit 1): A / Jump in RetroPad
    // We send Bit 1 for A (Jump) and Bit 0 for B (Attack/Punch) which correctly aligns with N64!
    // Button 3 (bit 2): Z Trigger (KEYCODE_BUTTON_C / Trigger)
    // Button 4 (bit 3): C-Up
    // Button 5 (bit 4): C-Down
    // Button 6 (bit 5): C-Left
    // Button 7 (bit 6): L Bumper (KEYCODE_BUTTON_L1)
    // Button 8 (bit 7): R Bumper (KEYCODE_BUTTON_R1)
    int buttonsLow = 0;
    if (_b) buttonsLow |= (1 << 0); // N64 B (Punch/Attack)
    if (_a) buttonsLow |= (1 << 1); // N64 A (Jump)
    if (_zTrigger) buttonsLow |= (1 << 2); // N64 Z Trigger
    if (_cUp) buttonsLow |= (1 << 3); // C-Up
    if (_cDown) buttonsLow |= (1 << 4); // C-Down
    if (_cLeft) buttonsLow |= (1 << 5); // C-Left
    if (_lBumper) buttonsLow |= (1 << 6); // L Bumper
    if (_rBumper) buttonsLow |= (1 << 7); // R Bumper

    // 5. Buttons 9..16:
    // Button 9 (bit 0 of high byte): Z Trigger alternate (L2)
    // Button 10 (bit 1 of high byte): C-Right (bit 12)
    // Button 12 (bit 3 of high byte): Start (KEYCODE_BUTTON_START)
    int buttonsHigh = 0;
    if (_zTrigger) buttonsHigh |= (1 << 0); // L2 mirror for Z-Trigger
    if (_cRight) buttonsHigh |= (1 << 1) | (1 << 4); // C-Right
    if (_start) buttonsHigh |= (1 << 3); // Start

    return [lx, ly, rx, ry, hat, buttonsLow, buttonsHigh];
  }
}
