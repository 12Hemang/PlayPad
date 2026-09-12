import 'package:flutter_test/flutter_test.dart';
import 'package:ble/gamepad/nes_gamepad_controller.dart';
import 'package:ble/hid/ble_logger.dart';
import 'package:ble/hid/permission_service.dart';
import 'package:ble/models/controller_layout.dart';
import 'package:ble/models/haptic_settings.dart';

void main() {
  group('NES Gamepad Controller Tests', () {
    test('Initial state is neutral', () {
      final controller = NesGamepadController();
      final report = controller.buildReport();

      // [X, Y, Hat, ButtonsLow, ButtonsHigh]
      expect(report.length, 5);
      expect(report[0], 128); // X neutral
      expect(report[1], 128); // Y neutral
      expect(report[2], 0);   // Hat centered
      expect(report[3], 0);   // Buttons released
      expect(report[4], 0);
    });

    test('D-Pad directions calculate correct X/Y and Hat switch', () {
      final controller = NesGamepadController();

      // Test UP
      controller.pressButton(NesButton.up);
      var report = controller.buildReport();
      expect(report[1], 0);   // Y up
      expect(report[2], 1);   // Hat up

      controller.releaseButton(NesButton.up);
      report = controller.buildReport();
      expect(report[1], 128);
      expect(report[2], 0);

      // Test RIGHT
      controller.pressButton(NesButton.right);
      report = controller.buildReport();
      expect(report[0], 255); // X right
      expect(report[2], 3);   // Hat right

      controller.reset();
      report = controller.buildReport();
      expect(report[0], 128);
      expect(report[2], 0);
    });

    test('Buttons A, B, X, Y, Select, Start set correct bitmask', () {
      final controller = NesGamepadController();

      // Button A (bit 0 of buttonsLow)
      controller.pressButton(NesButton.a);
      var report = controller.buildReport();
      expect(report[3] & (1 << 0), isNot(0));

      // Button B (bit 1 of buttonsLow)
      controller.pressButton(NesButton.b);
      report = controller.buildReport();
      expect(report[3] & (1 << 1), isNot(0));

      // Button X (bit 3 of buttonsLow: KEYCODE_BUTTON_X)
      controller.pressButton(NesButton.x);
      report = controller.buildReport();
      expect(report[3] & (1 << 3), isNot(0));

      // Button Y (bit 4 of buttonsLow: KEYCODE_BUTTON_Y)
      controller.pressButton(NesButton.y);
      report = controller.buildReport();
      expect(report[3] & (1 << 4), isNot(0));

      // Select (bit 2 of buttonsHigh: KEYCODE_BUTTON_SELECT)
      controller.pressButton(NesButton.select);
      report = controller.buildReport();
      expect(report[4] & (1 << 2), isNot(0));

      // Start (bit 3 of buttonsHigh: KEYCODE_BUTTON_START)
      controller.pressButton(NesButton.start);
      report = controller.buildReport();
      expect(report[4] & (1 << 3), isNot(0));

      // Reset
      controller.reset();
      report = controller.buildReport();
      expect(report[3], 0);
      expect(report[4], 0);
    });
  });

  group('ControllerLayout Tests', () {
    test('Default portrait layout has valid coordinates and scale', () {
      final p = ControllerLayout.defaultPortrait();
      expect(p.dpad.dx, inInclusiveRange(0.0, 1.0));
      expect(p.dpad.dy, inInclusiveRange(0.0, 1.0));
      expect(p.actionButtons.dx, inInclusiveRange(0.0, 1.0));
      expect(p.menuButtons.dx, inInclusiveRange(0.0, 1.0));
      expect(p.dpad.scale, inInclusiveRange(0.6, 2.0));
    });

    test('Default landscape layout has valid coordinates and scale', () {
      final l = ControllerLayout.defaultLandscape();
      expect(l.dpad.dx, inInclusiveRange(0.0, 1.0));
      expect(l.actionButtons.dx, inInclusiveRange(0.0, 1.0));
      expect(l.menuButtons.dx, inInclusiveRange(0.0, 1.0));
    });

    test('Json serialization round-trip with scale and rotation', () {
      final original = ControllerLayout(
        dpad: const ClusterLayout(dx: 0.25, dy: 0.65, scale: 1.2, rotation: 0.45),
        actionButtons: const ClusterLayout(dx: 0.75, dy: 0.65, scale: 1.4, rotation: -0.3),
        menuButtons: const ClusterLayout(dx: 0.50, dy: 0.85, scale: 0.9, rotation: 0.0),
      );
      final json = original.toJson();
      final restored = ControllerLayout.fromJson(json);

      expect(restored.dpad.dx, closeTo(0.25, 0.001));
      expect(restored.dpad.dy, closeTo(0.65, 0.001));
      expect(restored.dpad.scale, closeTo(1.2, 0.001));
      expect(restored.dpad.rotation, closeTo(0.45, 0.001));
      expect(restored.actionButtons.rotation, closeTo(-0.3, 0.001));
      expect(restored.menuButtons.rotation, closeTo(0.0, 0.001));
    });
  });

  group('BleLogger Tests', () {
    test('Logs are added and formatted correctly', () {
      final logger = BleLogger.instance;
      logger.clear();

      logger.info('TEST', 'Test message');
      expect(logger.history.isNotEmpty, true);
      final last = logger.history.last;
      expect(last.level, 'INFO');
      expect(last.tag, 'TEST');
      expect(last.message, 'Test message');
    });
  });

  group('PermissionStatusResult Tests', () {
    test('Correctly determines isAllReady flag', () {
      final notReady = PermissionStatusResult(
        permissionsGranted: false,
        bluetoothEnabled: true,
        missingPermissions: ['android.permission.BLUETOOTH_CONNECT'],
      );
      expect(notReady.isAllReady, false);

      final btDisabled = PermissionStatusResult(
        permissionsGranted: true,
        bluetoothEnabled: false,
        missingPermissions: [],
      );
      expect(btDisabled.isAllReady, false);

      final locDisabled = PermissionStatusResult(
        permissionsGranted: true,
        bluetoothEnabled: true,
        locationEnabled: false,
        missingPermissions: [],
      );
      expect(locDisabled.isAllReady, false);

      final allReady = PermissionStatusResult(
        permissionsGranted: true,
        bluetoothEnabled: true,
        locationEnabled: true,
        missingPermissions: [],
      );
      expect(allReady.isAllReady, true);
    });
  });

  group('Joystick Controller and Layout Tests', () {
    test('Analog joystick calculations for X, Y and Hat switch', () {
      final controller = NesGamepadController();

      // Right
      controller.setJoystick(1.0, 0.0);
      var report = controller.buildReport();
      expect(report[0], 255); // X right
      expect(report[1], 128); // Y neutral
      expect(report[2], 3);   // Hat right

      // Up
      controller.setJoystick(0.0, -1.0);
      report = controller.buildReport();
      expect(report[0], 128); // X neutral
      expect(report[1], 0);   // Y up
      expect(report[2], 1);   // Hat up

      // Left
      controller.setJoystick(-1.0, 0.0);
      report = controller.buildReport();
      expect(report[0], 0);   // X left
      expect(report[1], 128); // Y neutral
      expect(report[2], 7);   // Hat left

      // Down
      controller.setJoystick(0.0, 1.0);
      report = controller.buildReport();
      expect(report[0], 128); // X neutral
      expect(report[1], 255); // Y down
      expect(report[2], 5);   // Hat down

      // Diagonal Down-Right
      controller.setJoystick(0.707, 0.707);
      report = controller.buildReport();
      expect(report[2], 4);   // Hat down-right

      // Deadzone (< 0.25)
      controller.setJoystick(0.1, 0.1);
      report = controller.buildReport();
      expect(report[2], 0);   // Hat centered

      // Reset joystick
      controller.resetJoystick();
      report = controller.buildReport();
      expect(report[0], 128);
      expect(report[1], 128);
      expect(report[2], 0);
    });

    test('ControllerLayout preserves directionType across JSON serialization', () {
      final layout = ControllerLayout.defaultLandscape().copyWith(
        directionType: DirectionControlType.joystick,
      );
      expect(layout.directionType, DirectionControlType.joystick);

      final json = layout.toJson();
      final restored = ControllerLayout.fromJson(json);
      expect(restored.directionType, DirectionControlType.joystick);
    });
  });

  group('Haptic Settings & Ergonomic Touch Tests', () {
    test('HapticSettings defaults have vibrateOnAck disabled to prevent constant buzzing', () {
      const settings = HapticSettings();
      expect(settings.enabled, true);
      expect(settings.vibrateOnPress, true);
      expect(settings.vibrateOnDirectionChange, true);
      expect(settings.vibrateOnAck, false); // Crucial fix for constant buzzing!
      expect(settings.aPlusBBridge, true);
      expect(settings.continuousDpad, true);
      expect(settings.strength, HapticStrength.subtle);
    });

    test('HapticSettings JSON serialization round-trip', () {
      const original = HapticSettings(
        enabled: false,
        strength: HapticStrength.strong,
        vibrateOnPress: false,
        vibrateOnDirectionChange: true,
        vibrateOnAck: true,
        aPlusBBridge: false,
        continuousDpad: false,
      );

      final jsonStr = original.toJson();
      final restored = HapticSettings.fromJson(jsonStr);

      expect(restored.enabled, false);
      expect(restored.strength, HapticStrength.strong);
      expect(restored.vibrateOnPress, false);
      expect(restored.vibrateOnDirectionChange, true);
      expect(restored.vibrateOnAck, true);
      expect(restored.aPlusBBridge, false);
      expect(restored.continuousDpad, false);
    });

    test('Simultaneous A and B button press sets both bits in report', () {
      final controller = NesGamepadController();

      controller.pressButton(NesButton.a);
      controller.pressButton(NesButton.b);
      final report = controller.buildReport();

      // Bit 0 = A, Bit 1 = B
      expect(report[3] & (1 << 0), isNot(0), reason: 'Button A must be pressed');
      expect(report[3] & (1 << 1), isNot(0), reason: 'Button B must be pressed');
    });

    test('D-Pad diagonals activate both directions simultaneously', () {
      final controller = NesGamepadController();

      // Up + Right diagonal
      controller.setDpad(up: true, down: false, left: false, right: true);
      final report = controller.buildReport();

      expect(report[0], 255); // X right
      expect(report[1], 0);   // Y up
      expect(report[2], 2);   // Hat switch: Up-Right (2)
    });
  });
}
