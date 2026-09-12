import 'package:flutter/services.dart';
import 'gamepad_controller.dart';
import 'n64_gamepad_controller.dart';
import 'nes_gamepad_controller.dart';

enum ControllerType {
  nes,
  n64,
}

/// Factory to create and manage gamepad controller types.
class ControllerFactory {
  static const MethodChannel _channel = MethodChannel('com.example.ble/gamepad');
  static const String _prefKey = 'selected_controller_type';

  static GamepadController createController(ControllerType type) {
    switch (type) {
      case ControllerType.nes:
        return NesGamepadController();
      case ControllerType.n64:
        return N64GamepadController();
    }
  }

  static List<ControllerType> get availableTypes => [
        ControllerType.nes,
        ControllerType.n64,
      ];

  static String getDisplayName(ControllerType type) {
    switch (type) {
      case ControllerType.nes:
        return 'NES Gamepad (1 Dial Pad)';
      case ControllerType.n64:
        return 'N64 Gamepad (Dual Dialers)';
    }
  }

  static String getShortName(ControllerType type) {
    switch (type) {
      case ControllerType.nes:
        return 'NES';
      case ControllerType.n64:
        return 'N64';
    }
  }

  static Future<void> saveActiveType(ControllerType type) async {
    try {
      await _channel.invokeMethod('savePreference', {
        'key': _prefKey,
        'value': type.name,
      });
    } catch (_) {}
  }

  static Future<ControllerType> loadActiveType() async {
    try {
      final val = await _channel.invokeMethod<String>('getPreference', {'key': _prefKey});
      if (val != null) {
        for (final t in ControllerType.values) {
          if (t.name == val) return t;
        }
      }
    } catch (_) {}
    return ControllerType.nes;
  }
}
