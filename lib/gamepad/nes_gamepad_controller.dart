import 'dart:async';
import 'dart:math' as math;
import '../hid/ble_logger.dart';
import 'gamepad_controller.dart';

enum NesButton {
  up,
  down,
  left,
  right,
  select,
  start,
  b,
  a,
  x,
  y,
}

/// NES / SNES Gamepad Controller implementation for Bluetooth HID.
/// Provides directional D-Pad, Select, Start, and A/B/X/Y buttons.
class NesGamepadController extends GamepadController {
  @override
  String get name => 'NES Gamepad';

  @override
  int get reportId => 1;

  // Button states
  bool _up = false;
  bool _down = false;
  bool _left = false;
  bool _right = false;
  bool _select = false;
  bool _start = false;
  bool _b = false;
  bool _a = false;
  bool _x = false;
  bool _y = false;

  // Analog joystick state
  double _joystickX = 0.0; // -1.0 (left) to +1.0 (right)
  double _joystickY = 0.0; // -1.0 (up) to +1.0 (down)
  bool _isJoystickActive = false;

  double get joystickX => _joystickX;
  double get joystickY => _joystickY;
  bool get isJoystickActive => _isJoystickActive;

  // Pulse hold tracking to guarantee host detects short touchscreen taps
  final Map<NesButton, DateTime> _pressTimes = {};
  final Map<NesButton, Timer> _pendingReleaseTimers = {};
  static const Duration minHoldDuration = Duration(milliseconds: 55);

  bool get isUpPressed => _up;
  bool get isDownPressed => _down;
  bool get isLeftPressed => _left;
  bool get isRightPressed => _right;
  bool get isSelectPressed => _select;
  bool get isStartPressed => _start;
  bool get isBPressed => _b;
  bool get isAPressed => _a;
  bool get isXPressed => _x;
  bool get isYPressed => _y;

  /// Standard USB HID Gamepad Report Descriptor:
  /// - 1 Byte X Axis (0..255, neutral 128)
  /// - 1 Byte Y Axis (0..255, neutral 128)
  /// - 1 Byte Hat Switch (D-Pad, 0=neutral, 1..8 directions) + 4-bit padding (Const, Var, Abs = 0x03)
  /// - 2 Bytes Buttons (16 buttons)
  @override
  List<int> get reportDescriptor => const [
        0x05, 0x01, // USAGE_PAGE (Generic Desktop)
        0x09, 0x05, // USAGE (Game Pad)
        0xA1, 0x01, // COLLECTION (Application)
        0x85, 0x01, //   REPORT_ID (1)

        // X, Y Axes (Left Stick / Direction)
        0x05, 0x01, //   USAGE_PAGE (Generic Desktop)
        0x09, 0x30, //   USAGE (X)
        0x09, 0x31, //   USAGE (Y)
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

        // 16 Buttons (A, B, X, Y, Select, Start, L1, R1, etc.)
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

  /// Updates a button's state and immediately dispatches the HID report.
  void setButton(NesButton button, bool isPressed) {
    bool changed = false;
    switch (button) {
      case NesButton.up:
        if (_up != isPressed) {
          _up = isPressed;
          changed = true;
        }
        break;
      case NesButton.down:
        if (_down != isPressed) {
          _down = isPressed;
          changed = true;
        }
        break;
      case NesButton.left:
        if (_left != isPressed) {
          _left = isPressed;
          changed = true;
        }
        break;
      case NesButton.right:
        if (_right != isPressed) {
          _right = isPressed;
          changed = true;
        }
        break;
      case NesButton.select:
        if (_select != isPressed) {
          _select = isPressed;
          changed = true;
        }
        break;
      case NesButton.start:
        if (_start != isPressed) {
          _start = isPressed;
          changed = true;
        }
        break;
      case NesButton.b:
        if (_b != isPressed) {
          _b = isPressed;
          changed = true;
        }
        break;
      case NesButton.a:
        if (_a != isPressed) {
          _a = isPressed;
          changed = true;
        }
        break;
      case NesButton.x:
        if (_x != isPressed) {
          _x = isPressed;
          changed = true;
        }
        break;
      case NesButton.y:
        if (_y != isPressed) {
          _y = isPressed;
          changed = true;
        }
        break;
    }

    if (changed) {
      final action = isPressed ? 'DOWN' : 'UP';
      final btnLabel = button.name.toUpperCase();
      BleLogger.instance.info('BUTTON', '[$action] $btnLabel');
      dispatchReport();
    }
  }

  bool _isActionButton(NesButton button) {
    return button == NesButton.a ||
        button == NesButton.b ||
        button == NesButton.x ||
        button == NesButton.y ||
        button == NesButton.select ||
        button == NesButton.start;
  }

  /// Press button with automatic minimum hold duration tracking for action buttons.
  void pressButton(NesButton button) {
    _pendingReleaseTimers[button]?.cancel();
    _pendingReleaseTimers.remove(button);
    _pressTimes[button] = DateTime.now();
    setButton(button, true);
  }

  /// Release button, deferring release for action buttons if necessary to satisfy minHoldDuration.
  void releaseButton(NesButton button) {
    // D-Pad directions release immediately for precise movement
    if (!_isActionButton(button)) {
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
      // Defer release until minimum hold time is reached
      final remaining = minHoldDuration - elapsed;
      _pendingReleaseTimers[button]?.cancel();
      _pendingReleaseTimers[button] = Timer(remaining, () {
        _pressTimes.remove(button);
        _pendingReleaseTimers.remove(button);
        setButton(button, false);
      });
    } else {
      _pressTimes.remove(button);
      _pendingReleaseTimers.remove(button);
      setButton(button, false);
    }
  }

  /// Convenient method for D-Pad touch controls to set all 4 directions in one go.
  void setDpad({
    required bool up,
    required bool down,
    required bool left,
    required bool right,
  }) {
    if (_up != up || _down != down || _left != left || _right != right) {
      _up = up;
      _down = down;
      _left = left;
      _right = right;
      final dirs = [
        if (up) 'UP',
        if (down) 'DOWN',
        if (left) 'LEFT',
        if (right) 'RIGHT',
      ];
      final state = dirs.isEmpty ? 'CENTER/RELEASED' : dirs.join('+');
      BleLogger.instance.info('DPAD', '[DIRECTION] $state');
      dispatchReport();
    }
  }

  /// Update analog joystick coordinates. Normalized between -1.0 and 1.0.
  /// (x: -1.0 = left, +1.0 = right; y: -1.0 = up, +1.0 = down).
  void setJoystick(double x, double y) {
    final clampedX = x.clamp(-1.0, 1.0);
    final clampedY = y.clamp(-1.0, 1.0);
    final mag = math.sqrt(clampedX * clampedX + clampedY * clampedY);
    final wasActive = _isJoystickActive;
    _isJoystickActive = mag > 0.08;
    _joystickX = _isJoystickActive ? clampedX : 0.0;
    _joystickY = _isJoystickActive ? clampedY : 0.0;

    if (wasActive != _isJoystickActive || _isJoystickActive) {
      BleLogger.instance.info('JOYSTICK', '[POS] X=${_joystickX.toStringAsFixed(2)}, Y=${_joystickY.toStringAsFixed(2)}');
      dispatchReport();
    }
  }

  /// Reset joystick back to center (0.0, 0.0).
  void resetJoystick() {
    if (_isJoystickActive || _joystickX != 0.0 || _joystickY != 0.0) {
      _joystickX = 0.0;
      _joystickY = 0.0;
      _isJoystickActive = false;
      BleLogger.instance.info('JOYSTICK', '[RESET] Center');
      dispatchReport();
    }
  }

  @override
  void reset() {
    for (final timer in _pendingReleaseTimers.values) {
      timer.cancel();
    }
    _pendingReleaseTimers.clear();
    _pressTimes.clear();

    _up = false;
    _down = false;
    _left = false;
    _right = false;
    _select = false;
    _start = false;
    _b = false;
    _a = false;
    _x = false;
    _y = false;
    _joystickX = 0.0;
    _joystickY = 0.0;
    _isJoystickActive = false;
    BleLogger.instance.info('BUTTON', '[RESET] All buttons released');
    dispatchReport();
  }

  /// Calculates the 4-bit Hat Switch direction:
  /// 0 = centered (neutral / null)
  /// 1 = Up
  /// 2 = Up + Right
  /// 3 = Right
  /// 4 = Down + Right
  /// 5 = Down
  /// 6 = Down + Left
  /// 7 = Left
  /// 8 = Up + Left
  int _calculateHatSwitch() {
    if (_isJoystickActive) {
      final mag = math.sqrt(_joystickX * _joystickX + _joystickY * _joystickY);
      if (mag < 0.25) return 0; // In deadzone
      var angleDeg = math.atan2(_joystickY, _joystickX) * 180 / math.pi;
      if (angleDeg < 0) angleDeg += 360;
      // 0 deg = Right (3), 45 deg = Down-Right (4), 90 deg = Down (5), 135 deg = Down-Left (6),
      // 180 deg = Left (7), 225 deg = Up-Left (8), 270 deg = Up (1), 315 deg = Up-Right (2)
      const hatMap = [3, 4, 5, 6, 7, 8, 1, 2];
      final sector = ((angleDeg + 22.5) / 45).floor() % 8;
      return hatMap[sector];
    }
    if (_up && _right) return 2;
    if (_down && _right) return 4;
    if (_down && _left) return 6;
    if (_up && _left) return 8;
    if (_up) return 1;
    if (_right) return 3;
    if (_down) return 5;
    if (_left) return 7;
    return 0; // Centered / released
  }

  @override
  List<int> buildReport() {
    // 1. X Axis (0..255, neutral = 128)
    int x = 128;
    // 2. Y Axis (0..255, neutral = 128)
    int y = 128;

    if (_isJoystickActive) {
      x = ((_joystickX.clamp(-1.0, 1.0) + 1.0) * 127.5).round().clamp(0, 255);
      y = ((_joystickY.clamp(-1.0, 1.0) + 1.0) * 127.5).round().clamp(0, 255);
    } else {
      if (_left && !_right) x = 0;
      if (_right && !_left) x = 255;
      if (_up && !_down) y = 0;
      if (_down && !_up) y = 255;
    }

    // 3. Hat Switch (lower 4 bits)
    final hat = _calculateHatSwitch() & 0x0F;

    // 4. Buttons 1..8:
    // Button 1 (bit 0): A (South / KEYCODE_BUTTON_A)
    // Button 2 (bit 1): B (East / KEYCODE_BUTTON_B)
    // Button 3 (bit 2): X in 4-button pads
    // Button 4 (bit 3): X in Linux Generic.kl (North / KEYCODE_BUTTON_X)
    // Button 5 (bit 4): Y in Linux Generic.kl (West / KEYCODE_BUTTON_Y)
    // Button 6 (bit 5): Y alternative
    // Button 7 (bit 6): L1
    // Button 8 (bit 7): R1
    int buttonsLow = 0;
    if (_a) buttonsLow |= (1 << 0);
    if (_b) buttonsLow |= (1 << 1);
    if (_x) buttonsLow |= (1 << 2) | (1 << 3); // Sets both Button 3 and Button 4
    if (_y) buttonsLow |= (1 << 4) | (1 << 5); // Sets Button 5 and Button 6

    // 5. Buttons 9..16:
    // Button 9 (bit 0 of high byte): Select (in 10-button pads)
    // Button 10 (bit 1 of high byte): Start (in 10-button pads)
    // Button 11 (bit 2 of high byte): Select (in 16-button Linux: KEYCODE_BUTTON_SELECT)
    // Button 12 (bit 3 of high byte): Start (in 16-button Linux: KEYCODE_BUTTON_START)
    int buttonsHigh = 0;
    if (_select) buttonsHigh |= (1 << 0) | (1 << 2);
    if (_start) buttonsHigh |= (1 << 1) | (1 << 3);

    return [x, y, hat, buttonsLow, buttonsHigh];
  }
}
