import 'package:flutter/services.dart';
import 'ble_logger.dart';

class PermissionStatusResult {
  final bool permissionsGranted;
  final bool bluetoothEnabled;
  final bool locationEnabled;
  final List<String> missingPermissions;

  PermissionStatusResult({
    required this.permissionsGranted,
    required this.bluetoothEnabled,
    this.locationEnabled = true,
    required this.missingPermissions,
  });

  // Only requires Bluetooth permissions and Bluetooth turned ON to start using Gamepad!
  bool get isAllReady => permissionsGranted && bluetoothEnabled;

  factory PermissionStatusResult.fromMap(Map<dynamic, dynamic> map) {
    final missing = (map['missingPermissions'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    return PermissionStatusResult(
      permissionsGranted: map['permissionsGranted'] as bool? ?? false,
      bluetoothEnabled: map['bluetoothEnabled'] as bool? ?? false,
      locationEnabled: map['locationEnabled'] as bool? ?? true,
      missingPermissions: missing,
    );
  }
}

class PermissionService {
  static const MethodChannel _methodChannel = MethodChannel('com.example.ble/gamepad');
  final BleLogger _logger = BleLogger.instance;

  /// Checks whether all Bluetooth permissions are granted and if Bluetooth adapter is enabled.
  Future<PermissionStatusResult> checkPermissions() async {
    try {
      final res = await _methodChannel.invokeMethod<Map>('checkPermissions');
      if (res != null) {
        final result = PermissionStatusResult.fromMap(res);
        _logger.info(
          'PERM_SVC',
          'Permission check: granted=${result.permissionsGranted}, btEnabled=${result.bluetoothEnabled}, missing=${result.missingPermissions.length}',
        );
        return result;
      }
    } catch (e) {
      _logger.error('PERM_SVC', 'Error checking permissions: $e');
    }
    return PermissionStatusResult(
      permissionsGranted: false,
      bluetoothEnabled: false,
      missingPermissions: ['Unknown'],
    );
  }

  /// Prompts the Android OS permission dialog for missing Bluetooth permissions.
  Future<bool> requestPermissions() async {
    try {
      _logger.info('PERM_SVC', 'Requesting missing Bluetooth permissions from user...');
      final granted = await _methodChannel.invokeMethod<bool>('requestPermissions');
      _logger.info('PERM_SVC', 'Permission request response: granted=$granted');
      return granted ?? false;
    } catch (e) {
      _logger.error('PERM_SVC', 'Error requesting permissions: $e');
      return false;
    }
  }

  /// Launches the system intent to enable Bluetooth adapter.
  Future<bool> enableBluetooth() async {
    try {
      _logger.info('PERM_SVC', 'Launching system Bluetooth enable prompt...');
      final res = await _methodChannel.invokeMethod<bool>('enableBluetooth');
      return res ?? false;
    } catch (e) {
      _logger.error('PERM_SVC', 'Error enabling Bluetooth: $e');
      return false;
    }
  }

  /// Opens the App Settings page for manual permission granting if permanently denied.
  Future<bool> openAppSettings() async {
    try {
      _logger.info('PERM_SVC', 'Opening application details settings...');
      final res = await _methodChannel.invokeMethod<bool>('openAppSettings');
      return res ?? false;
    } catch (e) {
      _logger.error('PERM_SVC', 'Error opening app settings: $e');
      return false;
    }
  }

  /// Opens the Android Location Source Settings page so the user can turn ON GPS.
  Future<bool> openLocationSettings() async {
    try {
      _logger.info('PERM_SVC', 'Opening system location settings...');
      final res = await _methodChannel.invokeMethod<bool>('openLocationSettings');
      return res ?? false;
    } catch (e) {
      _logger.error('PERM_SVC', 'Error opening location settings: $e');
      return false;
    }
  }

  /// Checks whether Location permission is granted (used only when user initiates scanning).
  Future<bool> isLocationPermissionGranted() async {
    try {
      final res = await _methodChannel.invokeMethod<bool>('checkLocationPermission');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Checks if Location Services (GPS) is turned ON.
  Future<bool> isLocationServicesEnabled() async {
    try {
      final res = await _methodChannel.invokeMethod<bool>('isLocationServicesEnabled');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Requests the Android Location permission dialog specifically for device scanning.
  Future<bool> requestLocationPermission() async {
    try {
      _logger.info('PERM_SVC', 'Requesting Location permission for Bluetooth scanning...');
      final res = await _methodChannel.invokeMethod<bool>('requestLocationPermission');
      return res ?? false;
    } catch (e) {
      _logger.error('PERM_SVC', 'Error requesting Location permission: $e');
      return false;
    }
  }
}
