import 'dart:async';
import 'package:flutter/services.dart';
import '../gamepad/gamepad_controller.dart';
import 'ble_logger.dart';

/// Event containing acknowledgement details for a transmitted HID report.
class HidAckEvent {
  final int reportId;
  final bool success;
  final int latencyMs;
  final DateTime timestamp;

  const HidAckEvent({
    required this.reportId,
    required this.success,
    required this.latencyMs,
    required this.timestamp,
  });
}

/// Class responsible for registering the Android device as a Bluetooth HID Gamepad
/// using the controller's HID Report Descriptor, and managing HID report transmissions.
class HidRegister {
  static const MethodChannel _methodChannel = MethodChannel('com.example.ble/gamepad');
  static const EventChannel _eventChannel = EventChannel('com.example.ble/events');

  final BleLogger _logger = BleLogger.instance;
  StreamSubscription? _eventSub;

  bool _isRegistered = false;
  GamepadController? _activeController;

  HidAckEvent? _lastAck;
  HidAckEvent? get lastAck => _lastAck;

  final StreamController<bool> _registrationStateController =
      StreamController<bool>.broadcast();
  final StreamController<HidAckEvent> _ackController =
      StreamController<HidAckEvent>.broadcast();

  bool get isRegistered => _isRegistered;
  GamepadController? get activeController => _activeController;
  Stream<bool> get registrationStateStream => _registrationStateController.stream;
  Stream<HidAckEvent> get ackStream => _ackController.stream;

  HidRegister() {
    _listenToEvents();
  }

  void _listenToEvents() {
    _eventSub?.cancel();
    _eventSub = _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Map) {
          final type = event['event'] as String?;
          if (type == 'app_status') {
            final reg = event['registered'] as bool? ?? false;
            _isRegistered = reg;
            _registrationStateController.add(reg);
            _logger.info(
              'HID_REG',
              'Event listener confirmed HID Gamepad is ${reg ? "ACTIVE & REGISTERED" : "UNREGISTERED"}',
            );
          } else if (type == 'hid_proxy_connected') {
            _logger.info('HID_REG', 'HID Proxy connected notification received.');
          }
        }
      },
      onError: (e) {
        // Ignored or logged by BleLogger
      },
    );
  }

  /// Registers the device as a Bluetooth HID Gamepad peripheral using the provided controller descriptor.
  Future<bool> registerGamepad(GamepadController controller) async {
    _logger.info('HID_REG', 'Registering HID Gamepad for "${controller.name}"...');
    _activeController = controller;

    // Wire controller report pipeline
    controller.onReportReady = (int reportId, List<int> data) {
      sendReport(reportId, data);
    };

    try {
      final success = await _methodChannel.invokeMethod<bool>(
        'registerHidDevice',
        {
          'name': controller.name,
          'descriptor': controller.reportDescriptor,
        },
      );

      if (success == true) {
        _isRegistered = true;
        _registrationStateController.add(true);
        _logger.info('HID_REG', 'HID Gamepad registration request accepted.');
        return true;
      } else {
        _logger.info(
          'HID_REG',
          'Registration dispatched; awaiting onAppStatusChanged callback confirmation from OS...',
        );
        // Note: onAppStatusChanged will fire shortly if accepted asynchronously
        return false;
      }
    } catch (e) {
      _logger.error('HID_REG', 'Exception during HID registration: $e');
      return false;
    }
  }

  /// Unregisters the current Bluetooth HID peripheral application.
  Future<bool> unregisterGamepad() async {
    _logger.info('HID_REG', 'Unregistering HID Gamepad...');
    try {
      final success = await _methodChannel.invokeMethod<bool>('unregisterHidDevice');
      _isRegistered = false;
      _registrationStateController.add(false);
      return success ?? false;
    } catch (e) {
      _logger.error('HID_REG', 'Exception during HID unregister: $e');
      return false;
    }
  }

  /// Transmits an input report to the connected Bluetooth HID host (e.g. Android TV).
  Future<bool> sendReport(int reportId, List<int> reportData) async {
    final sw = Stopwatch()..start();
    try {
      final success = await _methodChannel.invokeMethod<bool>(
        'sendReport',
        {
          'reportId': reportId,
          'data': reportData,
        },
      ) ?? false;
      sw.stop();

      final ack = HidAckEvent(
        reportId: reportId,
        success: success,
        latencyMs: sw.elapsedMilliseconds,
        timestamp: DateTime.now(),
      );
      _lastAck = ack;
      _ackController.add(ack);

      if (success) {
        _logger.debug('HID_ACK', 'Report #$reportId acknowledged in ${sw.elapsedMilliseconds}ms');
      } else {
        _logger.warn('HID_ACK', 'Report #$reportId buffer congested / dropped (${sw.elapsedMilliseconds}ms)');
      }
      return success;
    } catch (e) {
      sw.stop();
      final ack = HidAckEvent(
        reportId: reportId,
        success: false,
        latencyMs: sw.elapsedMilliseconds,
        timestamp: DateTime.now(),
      );
      _lastAck = ack;
      _ackController.add(ack);
      _logger.error('HID_ACK', 'Exception transmitting report #$reportId: $e');
      return false;
    }
  }

  void dispose() {
    _eventSub?.cancel();
    _registrationStateController.close();
    _ackController.close();
  }
}
