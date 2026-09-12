import 'dart:async';
import 'package:flutter/services.dart';
import '../models/log_entry.dart';
import 'ble_logger.dart';

enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  disconnecting,
}

/// Class responsible for managing Bluetooth device connections, pairing/bonded status,
/// active nearby device scanning, capabilities discovery, reconnecting, and logging.
class BluetoothConnectionManager {
  static const MethodChannel _methodChannel = MethodChannel('com.example.ble/gamepad');
  static const EventChannel _eventChannel = EventChannel('com.example.ble/events');

  final BleLogger _logger = BleLogger.instance;
  StreamSubscription? _eventSubscription;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  BluetoothDeviceInfo? _connectedDevice;
  BluetoothDeviceInfo? _lastConnectedDevice;
  List<BluetoothDeviceInfo> _bondedDevices = [];
  final Map<String, BluetoothDeviceInfo> _availableDevicesMap = {};
  bool _isBluetoothEnabled = false;
  bool _isDiscovering = false;

  final StreamController<ConnectionStatus> _statusController =
      StreamController<ConnectionStatus>.broadcast();
  final StreamController<BluetoothDeviceInfo?> _deviceController =
      StreamController<BluetoothDeviceInfo?>.broadcast();
  final StreamController<List<BluetoothDeviceInfo>> _bondedDevicesController =
      StreamController<List<BluetoothDeviceInfo>>.broadcast();
  final StreamController<List<BluetoothDeviceInfo>> _availableDevicesController =
      StreamController<List<BluetoothDeviceInfo>>.broadcast();
  final StreamController<bool> _isDiscoveringController =
      StreamController<bool>.broadcast();

  ConnectionStatus get status => _status;
  BluetoothDeviceInfo? get connectedDevice => _connectedDevice;
  BluetoothDeviceInfo? get lastConnectedDevice => _lastConnectedDevice;
  List<BluetoothDeviceInfo> get bondedDevices => List.unmodifiable(_bondedDevices);
  List<BluetoothDeviceInfo> get availableDevices =>
      List.unmodifiable(_availableDevicesMap.values.toList());
  bool get isBluetoothEnabled => _isBluetoothEnabled;
  bool get isDiscovering => _isDiscovering;

  Stream<ConnectionStatus> get statusStream => _statusController.stream;
  Stream<BluetoothDeviceInfo?> get deviceStream => _deviceController.stream;
  Stream<List<BluetoothDeviceInfo>> get bondedDevicesStream => _bondedDevicesController.stream;
  Stream<List<BluetoothDeviceInfo>> get availableDevicesStream =>
      _availableDevicesController.stream;
  Stream<bool> get isDiscoveringStream => _isDiscoveringController.stream;

  /// Initializes listeners for native Bluetooth and HID events.
  Future<void> init() async {
    _logger.info('CONN_MGR', 'Initializing BluetoothConnectionManager...');
    _startEventListening();

    try {
      final enabled = await _methodChannel.invokeMethod<bool>('isBluetoothEnabled');
      _isBluetoothEnabled = enabled ?? false;
      _logger.info(
        'CONN_MGR',
        'Bluetooth is ${_isBluetoothEnabled ? "ENABLED" : "DISABLED"} on host device',
      );
    } catch (e) {
      _logger.error('CONN_MGR', 'Failed to check Bluetooth enabled status: $e');
    }

    await refreshBondedDevices();
    await fetchLastConnectedDevice();
  }

  void _startEventListening() {
    _eventSubscription?.cancel();
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Map) {
          _handlePlatformEvent(event);
        }
      },
      onError: (dynamic error) {
        _logger.error('CONN_MGR', 'Error on platform event stream: $error');
      },
    );
  }

  void _handlePlatformEvent(Map<dynamic, dynamic> event) {
    final eventType = event['event'] as String?;
    switch (eventType) {
      case 'log':
        final level = event['level'] as String? ?? 'INFO';
        final tag = event['tag'] as String? ?? 'NATIVE';
        final msg = event['message'] as String? ?? '';
        final timeStr = event['formattedTime'] as String?;
        final ts = event['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;
        _logger.addEntry(LogEntry(
          timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
          formattedTime: timeStr ?? LogEntry.fromMap(event).formattedTime,
          level: level,
          tag: tag,
          message: msg,
        ));
        break;

      case 'discovery_started':
        _isDiscovering = true;
        _isDiscoveringController.add(true);
        _logger.info('SCAN', 'Nearby device discovery active.');
        break;

      case 'discovery_finished':
        _isDiscovering = false;
        _isDiscoveringController.add(false);
        _logger.info('SCAN', 'Nearby device discovery completed. Found ${_availableDevicesMap.length} devices.');
        break;

      case 'device_found':
        final devMap = event['device'] as Map?;
        if (devMap != null) {
          final dev = BluetoothDeviceInfo.fromMap(devMap);
          // Only add if not already in bonded devices
          final isAlreadyBonded = _bondedDevices.any((b) => b.address == dev.address);
          if (!isAlreadyBonded) {
            _availableDevicesMap[dev.address] = dev;
            _availableDevicesController.add(availableDevices);
          }
        }
        break;

      case 'connection_state':
        final stateStr = event['state'] as String? ?? 'disconnected';
        final name = event['deviceName'] as String? ?? 'Unknown';
        final address = event['deviceAddress'] as String? ?? '';

        final dev = address.isNotEmpty
            ? BluetoothDeviceInfo(name: name, address: address, bondState: 'bonded')
            : null;

        _updateConnectionStatus(stateStr, dev);
        break;

      case 'bond_state':
        final bondState = event['bondState'] as String? ?? 'none';
        final name = event['deviceName'] as String? ?? 'Unknown';
        final address = event['deviceAddress'] as String? ?? '';
        _logger.info(
          'CONN_MGR',
          '[Pairing Event] Device "$name" ($address) state changed to $bondState',
        );

        if (bondState == 'bonded') {
          _logger.info('CONN_MGR', 'Device "$name" is now paired. Ready for HID connection.');
          _lastConnectedDevice = BluetoothDeviceInfo(name: name, address: address, bondState: bondState);
          _availableDevicesMap.remove(address);
          _availableDevicesController.add(availableDevices);
        } else if (bondState == 'none') {
          if (_connectedDevice?.address == address) {
            _updateConnectionStatus('disconnected', null);
          }
        }
        refreshBondedDevices();
        break;

      case 'bt_state':
        final enabled = event['enabled'] as bool? ?? false;
        _isBluetoothEnabled = enabled;
        _logger.info('CONN_MGR', 'Bluetooth state updated: ${enabled ? "ON" : "OFF"}');
        if (!enabled) {
          _isDiscovering = false;
          _isDiscoveringController.add(false);
          _updateConnectionStatus('disconnected', null);
        }
        break;
    }
  }

  void _updateConnectionStatus(String stateStr, BluetoothDeviceInfo? device) {
    ConnectionStatus newStatus;
    switch (stateStr.toLowerCase()) {
      case 'connected':
        newStatus = ConnectionStatus.connected;
        _connectedDevice = device;
        if (device != null) {
          _lastConnectedDevice = device;
        }
        _logger.info(
          'CONN_MGR',
          '[Connection] CONNECTED to "${device?.name ?? "Host"}" (${device?.address ?? "N/A"})',
        );
        break;
      case 'connecting':
        newStatus = ConnectionStatus.connecting;
        _connectedDevice = device;
        _logger.info(
          'CONN_MGR',
          '[Connection] CONNECTING to "${device?.name ?? "Host"}" (${device?.address ?? "N/A"})...',
        );
        break;
      case 'disconnecting':
        newStatus = ConnectionStatus.disconnecting;
        _logger.info(
          'CONN_MGR',
          '[Connection] DISCONNECTING from "${device?.name ?? "Host"}"...',
        );
        break;
      case 'disconnected':
      default:
        newStatus = ConnectionStatus.disconnected;
        _logger.info(
          'CONN_MGR',
          '[Connection] DISCONNECTED from "${device?.name ?? _connectedDevice?.name ?? "Host"}"',
        );
        _connectedDevice = null;
        break;
    }

    _status = newStatus;
    _statusController.add(_status);
    _deviceController.add(_connectedDevice);
  }

  /// Starts Bluetooth scan discovery for nearby unpaired devices.
  Future<bool> startDiscovery() async {
    _logger.info('SCAN', 'Starting active Bluetooth scan for nearby devices...');
    _availableDevicesMap.clear();
    _availableDevicesController.add([]);
    try {
      final success = await _methodChannel.invokeMethod<bool>('startDiscovery');
      _isDiscovering = success ?? false;
      _isDiscoveringController.add(_isDiscovering);
      return _isDiscovering;
    } catch (e) {
      _logger.error('SCAN', 'Exception starting discovery: $e');
      return false;
    }
  }

  /// Cancels active Bluetooth scan discovery.
  Future<bool> stopDiscovery() async {
    try {
      final success = await _methodChannel.invokeMethod<bool>('stopDiscovery');
      _isDiscovering = false;
      _isDiscoveringController.add(false);
      return success ?? false;
    } catch (e) {
      _logger.error('SCAN', 'Exception stopping discovery: $e');
      return false;
    }
  }

  /// Pairs (bonds) with an unpaired nearby device.
  Future<bool> pair(String address, {String? deviceName}) async {
    final devLabel = deviceName != null ? '"$deviceName" ($address)' : address;
    _logger.info('CONN_MGR', '[Pair] Initiating pairing with $devLabel...');
    try {
      final success = await _methodChannel.invokeMethod<bool>('pairDevice', {'address': address});
      return success ?? false;
    } catch (e) {
      _logger.error('CONN_MGR', '[Pair] Exception pairing with $address: $e');
      return false;
    }
  }

  /// Unpairs (removes bond) for a specific device so the user can re-pair freshly.
  Future<bool> unpair(String address, {String? deviceName}) async {
    final devLabel = deviceName != null ? '"$deviceName" ($address)' : address;
    _logger.info('CONN_MGR', '[Unpair] Removing Bluetooth bond for $devLabel...');
    try {
      final success = await _methodChannel.invokeMethod<bool>('unpairDevice', {'address': address});
      if (success == true) {
        _logger.info('CONN_MGR', '[Unpair] Device $devLabel successfully unpaired.');
        await refreshBondedDevices();
        return true;
      } else {
        _logger.warn('CONN_MGR', '[Unpair] Failed to unpair $devLabel.');
        return false;
      }
    } catch (e) {
      _logger.error('CONN_MGR', '[Unpair] Exception during unpair: $e');
      return false;
    }
  }

  /// Retrieves list of bonded (paired) Bluetooth devices with rich capabilities.
  Future<List<BluetoothDeviceInfo>> refreshBondedDevices() async {
    try {
      final res = await _methodChannel.invokeListMethod<Map>('getBondedDevices');
      if (res != null) {
        _bondedDevices = res.map((m) => BluetoothDeviceInfo.fromMap(m)).toList();
        _bondedDevicesController.add(_bondedDevices);
        _logger.info('CONN_MGR', 'Queried ${_bondedDevices.length} paired devices.');
      }
    } catch (e) {
      _logger.error('CONN_MGR', 'Failed to retrieve paired devices: $e');
    }
    return _bondedDevices;
  }

  /// Initiates a Bluetooth HID connection to a specific device address.
  Future<bool> connect(String address, {String? deviceName}) async {
    final devLabel = deviceName != null ? '"$deviceName" ($address)' : address;
    _logger.info('CONN_MGR', '[Connect] Dispatching connection request to $devLabel...');
    _updateConnectionStatus(
      'connecting',
      BluetoothDeviceInfo(
        name: deviceName ?? 'Target Device',
        address: address,
        bondState: 'bonded',
      ),
    );

    try {
      final success = await _methodChannel.invokeMethod<bool>('connect', {'address': address});
      if (success == true) {
        _logger.info('CONN_MGR', '[Connect] Connection signal dispatched to OS. Awaiting host handshake...');
        return true;
      } else {
        _logger.warn(
          'CONN_MGR',
          '[Connect] Connection call returned false. Check logs for details. If TV shows connection error, tap "Unpair" and re-pair freshly.',
        );
        return false;
      }
    } catch (e) {
      _logger.error('CONN_MGR', '[Connect] Exception connecting to $address: $e');
      _updateConnectionStatus('disconnected', null);
      return false;
    }
  }

  /// Requests the device to become discoverable so Android TV can find and pair with it as a Gamepad.
  Future<bool> makeDiscoverable({int duration = 300}) async {
    _logger.info('CONN_MGR', '[Discoverable] Making phone discoverable for $duration seconds...');
    try {
      final success = await _methodChannel.invokeMethod<bool>('makeDiscoverable', {'duration': duration});
      return success ?? false;
    } catch (e) {
      _logger.error('CONN_MGR', '[Discoverable] Exception requesting discoverable: $e');
      return false;
    }
  }

  /// Turns Bluetooth ON.
  Future<bool> enableBluetooth() async {
    _logger.info('CONN_MGR', 'Turning Bluetooth ON...');
    try {
      final ok = await _methodChannel.invokeMethod<bool>('enableBluetooth');
      return ok ?? false;
    } catch (e) {
      _logger.error('CONN_MGR', 'Failed to enable Bluetooth: $e');
      return false;
    }
  }

  /// Turns Bluetooth OFF.
  Future<bool> disableBluetooth() async {
    _logger.info('CONN_MGR', 'Turning Bluetooth OFF...');
    try {
      final ok = await _methodChannel.invokeMethod<bool>('disableBluetooth');
      return ok ?? false;
    } catch (e) {
      _logger.error('CONN_MGR', 'Failed to disable Bluetooth: $e');
      return false;
    }
  }

  /// Queries adapter info: local name, MAC, isEnabled, isDiscovering, isHidRegistered.
  Future<Map<String, dynamic>?> getAdapterInfo() async {
    try {
      final map = await _methodChannel.invokeMapMethod<String, dynamic>('getAdapterInfo');
      return map;
    } catch (e) {
      return null;
    }
  }

  /// Disconnects from the current active device.
  Future<bool> disconnect() async {
    final dev = _connectedDevice;
    if (dev == null) {
      _logger.warn('CONN_MGR', '[Disconnect] Cannot disconnect: No active device connected.');
      return false;
    }

    _logger.info('CONN_MGR', '[Disconnect] Disconnecting from "${dev.name}" (${dev.address})...');
    _updateConnectionStatus('disconnecting', dev);

    try {
      final success = await _methodChannel.invokeMethod<bool>('disconnect');
      if (success == true) {
        _logger.info('CONN_MGR', '[Disconnect] Disconnect request sent successfully.');
        return true;
      } else {
        _logger.warn('CONN_MGR', '[Disconnect] Disconnect call returned false.');
        return false;
      }
    } catch (e) {
      _logger.error('CONN_MGR', '[Disconnect] Exception during disconnect: $e');
      return false;
    }
  }

  /// Reconnects to the last successfully connected or paired host (e.g. Android TV).
  Future<bool> reconnect() async {
    _logger.info('CONN_MGR', '[Reconnect] Attempting to reconnect to previous host...');
    if (_lastConnectedDevice == null) {
      await fetchLastConnectedDevice();
    }

    if (_lastConnectedDevice == null) {
      _logger.warn('CONN_MGR', '[Reconnect] No previously connected device found in history.');
      return false;
    }

    _logger.info(
      'CONN_MGR',
      '[Reconnect] Reconnecting to "${_lastConnectedDevice!.name}" (${_lastConnectedDevice!.address})',
    );

    try {
      final success = await _methodChannel.invokeMethod<bool>('reconnect');
      return success ?? false;
    } catch (e) {
      _logger.error('CONN_MGR', '[Reconnect] Exception during reconnect: $e');
      return false;
    }
  }

  /// Queries the last stored device from platform storage.
  Future<BluetoothDeviceInfo?> fetchLastConnectedDevice() async {
    try {
      final map = await _methodChannel.invokeMapMethod<String, dynamic>('getLastConnectedDevice');
      if (map != null && map.containsKey('address')) {
        _lastConnectedDevice = BluetoothDeviceInfo.fromMap(map);
        _logger.info(
          'CONN_MGR',
          'Cached last connected host: "${_lastConnectedDevice!.name}" (${_lastConnectedDevice!.address})',
        );
      }
    } catch (e) {
      _logger.error('CONN_MGR', 'Error fetching last connected device: $e');
    }
    return _lastConnectedDevice;
  }

  void dispose() {
    _eventSubscription?.cancel();
    _statusController.close();
    _deviceController.close();
    _bondedDevicesController.close();
    _availableDevicesController.close();
    _isDiscoveringController.close();
  }
}
