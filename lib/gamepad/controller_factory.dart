import 'gamepad_controller.dart';
import 'nes_gamepad_controller.dart';

enum ControllerType {
  nes,
  // Future additions:
  // snes,
  // genesis,
  // modern,
}

/// Factory to create and manage gamepad controller types.
class ControllerFactory {
  static GamepadController createController(ControllerType type) {
    switch (type) {
      case ControllerType.nes:
        return NesGamepadController();
    }
  }

  static List<ControllerType> get availableTypes => [
        ControllerType.nes,
      ];

  static String getDisplayName(ControllerType type) {
    switch (type) {
      case ControllerType.nes:
        return 'NES Gamepad';
    }
  }
}
