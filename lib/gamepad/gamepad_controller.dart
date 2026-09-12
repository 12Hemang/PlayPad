import 'package:flutter/foundation.dart';

/// Base abstract class for any Gamepad controller layout (e.g. NES, SNES, Genesis, Modern Gamepad).
/// Handles HID report descriptor generation, report encoding, and state change dispatching.
abstract class GamepadController {
  /// Display name of the controller (e.g., "NES Gamepad", "SNES Controller").
  String get name;

  /// HID Report ID assigned to this controller.
  int get reportId;

  /// Complete USB HID Report Descriptor for this gamepad layout.
  List<int> get reportDescriptor;

  /// Builds the current binary input report payload to be transmitted over Bluetooth HID.
  List<int> buildReport();

  /// Resets all inputs to their default neutral state.
  void reset();

  /// Callback triggered whenever an input changes and a report is ready to send.
  void Function(int reportId, List<int> reportData)? onReportReady;

  /// Dispatches the current report payload to the active HID transmission listener.
  @protected
  void dispatchReport() {
    final data = buildReport();
    onReportReady?.call(reportId, data);
  }
}
