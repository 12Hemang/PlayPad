import 'dart:async';
import 'package:flutter/material.dart';
import '../gamepad/gamepad_controller.dart';
import '../gamepad/nes_gamepad_controller.dart';
import '../hid/bluetooth_connection_manager.dart';
import '../hid/hid_register.dart';
import '../hid/permission_service.dart';
import '../models/log_entry.dart';
import 'add_roms_dialog.dart';

class BluetoothScreen extends StatefulWidget {
  final BluetoothConnectionManager connManager;
  final HidRegister hidRegister;
  final GamepadController? controller;
  final VoidCallback onOpenGamepad;
  final VoidCallback onOpenPermissions;

  const BluetoothScreen({
    super.key,
    required this.connManager,
    required this.hidRegister,
    this.controller,
    required this.onOpenGamepad,
    required this.onOpenPermissions,
  });

  @override
  State<BluetoothScreen> createState() => _BluetoothScreenState();
}

class _BluetoothScreenState extends State<BluetoothScreen>
    with SingleTickerProviderStateMixin {
  final PermissionService _permService = PermissionService();
  late TabController _tabController;

  StreamSubscription? _statusSub;
  StreamSubscription? _bondedSub;
  StreamSubscription? _availSub;
  StreamSubscription? _scanSub;
  StreamSubscription? _hidSub;
  StreamSubscription? _btStateSub;

  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  List<BluetoothDeviceInfo> _bondedDevices = [];
  List<BluetoothDeviceInfo> _availableDevices = [];
  bool _isDiscovering = false;
  bool _isBtEnabled = true;
  bool _isHidRegistered = false;
  Map<String, dynamic>? _adapterInfo;

  // Discoverable countdown timer
  Timer? _discoverableTimer;
  int _discoverableSecondsRemaining = 0;

  // Track which device cards are expanded (ALL COLLAPSED BY DEFAULT)
  final Set<String> _expandedAddresses = {};

  GamepadController get _activeController =>
      widget.controller ?? widget.hidRegister.activeController ?? NesGamepadController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initListeners();
    _loadData();
  }

  void _initListeners() {
    _statusSub = widget.connManager.statusStream.listen((status) {
      if (mounted) setState(() => _connectionStatus = status);
    });

    _bondedSub = widget.connManager.bondedDevicesStream.listen((list) {
      if (mounted) setState(() => _bondedDevices = list);
    });

    _availSub = widget.connManager.availableDevicesStream.listen((list) {
      if (mounted) setState(() => _availableDevices = list);
    });

    _scanSub = widget.connManager.isDiscoveringStream.listen((isScanning) {
      if (mounted) {
        setState(() => _isDiscovering = isScanning);
        if (isScanning && _tabController.index != 1) {
          _tabController.animateTo(1);
        }
      }
    });

    _hidSub = widget.hidRegister.registrationStateStream.listen((reg) {
      if (mounted) setState(() => _isHidRegistered = reg);
    });

    _btStateSub = widget.connManager.bluetoothStateStream.listen((enabled) {
      if (mounted) {
        setState(() {
          _isBtEnabled = enabled;
          _discoverableSecondsRemaining = 0;
          _discoverableTimer?.cancel();
          _isDiscovering = false;
          _availableDevices = [];
          _bondedDevices = [];
          _isHidRegistered = false;
          widget.hidRegister.resetRegistration();
        });
        if (enabled) {
          _loadData();
        }
      }
    });
  }

  Future<void> _loadData() async {
    final info = await widget.connManager.getAdapterInfo();
    final bonded = await widget.connManager.refreshBondedDevices();
    final isRegistered = info?['isHidRegistered'] as bool? ?? widget.hidRegister.isRegistered;
    if (!mounted) return;
    setState(() {
      _adapterInfo = info;
      _isBtEnabled = info?['isEnabled'] as bool? ?? widget.connManager.isBluetoothEnabled;
      _isHidRegistered = isRegistered;
      _bondedDevices = bonded;
      _connectionStatus = widget.connManager.status;
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _bondedSub?.cancel();
    _availSub?.cancel();
    _scanSub?.cancel();
    _hidSub?.cancel();
    _btStateSub?.cancel();
    _discoverableTimer?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  void _handleTurnOnBluetooth() async {
    setState(() {
      _availableDevices = [];
      _bondedDevices = [];
      _isHidRegistered = false;
      widget.hidRegister.resetRegistration();
    });
    final ok = await widget.connManager.enableBluetooth();
    // Native system dialog handles the prompt. When allowed, ACTION_STATE_CHANGED
    // receiver automatically updates _isBtEnabled and reloads UI.
    if (!ok && mounted) {
      final current = await widget.connManager.checkBluetoothEnabled();
      if (mounted) setState(() => _isBtEnabled = current);
    }
  }

  void _handleTurnOffBluetooth() async {
    final ok = await widget.connManager.disableBluetooth();
    if (ok) {
      if (mounted) {
        setState(() {
          _isBtEnabled = false;
          _discoverableSecondsRemaining = 0;
          _discoverableTimer?.cancel();
          _isDiscovering = false;
          _availableDevices = [];
          _bondedDevices = [];
          _isHidRegistered = false;
          widget.hidRegister.resetRegistration();
        });
      }
    } else {
      // Android 13+ requires user to toggle off from Quick Settings or Settings
      if (mounted) {
        _showBluetoothDisableDialog();
      }
    }
  }

  void _showBluetoothDisableDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B1B22),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Colors.white12),
        ),
        icon: const Icon(Icons.bluetooth_disabled_rounded, color: Color(0xFFEF5350), size: 36),
        title: const Text(
          'Turn Off Bluetooth',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
        ),
        content: const Text(
          'Android security policies prevent apps from turning off Bluetooth directly to safeguard active connections (smartwatches, earbuds, etc.).\n\nYou can turn off Bluetooth from your Quick Settings swipe-down panel or in Settings.',
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E88E5),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.settings, size: 14),
            label: const Text('Open Settings'),
            onPressed: () {
              Navigator.pop(ctx);
              widget.connManager.openBluetoothSettings();
            },
          ),
        ],
      ),
    );
  }

  void _makeDiscoverable() async {
    const duration = 300;
    final ok = await widget.connManager.makeDiscoverable(duration: duration);
    if (ok && mounted) {
      _discoverableTimer?.cancel();
      setState(() => _discoverableSecondsRemaining = duration);
      _discoverableTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        if (_discoverableSecondsRemaining <= 1) {
          timer.cancel();
          setState(() => _discoverableSecondsRemaining = 0);
        } else {
          setState(() => _discoverableSecondsRemaining--);
        }
      });
    }
  }

  void _toggleScan() async {
    if (_isDiscovering) {
      debugPrint('[SCAN] User tapped Stop Scan. Halting discovery...');
      setState(() => _isDiscovering = false);
      await widget.connManager.stopDiscovery();
      return;
    }

    debugPrint('[SCAN] User tapped Scan. Running pre-scan validation...');
    final permResult = await _permService.checkPermissions();
    debugPrint('[SCAN] Pre-scan status: granted=${permResult.permissionsGranted}, btEnabled=${permResult.bluetoothEnabled}, locServicesOn=${permResult.locationEnabled}, missing=${permResult.missingPermissions}');

    // 1. Check if Bluetooth is enabled
    if (!permResult.bluetoothEnabled) {
      debugPrint('[SCAN_FAIL] Bluetooth is OFF. Redirecting to permission/setup screen...');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bluetooth is OFF. Opening setup...'),
            backgroundColor: Colors.redAccent,
            duration: Duration(seconds: 2),
          ),
        );
      }
      widget.onOpenPermissions();
      return;
    }

    // 2. Check if runtime permissions are missing
    if (!permResult.permissionsGranted || permResult.missingPermissions.isNotEmpty) {
      final names = permResult.missingPermissions.map((p) => p.split('.').last).join(', ');
      debugPrint('[SCAN_FAIL] Missing permissions: $names. Redirecting to setup screen...');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Missing required permission: $names. Opening setup...'),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 3),
          ),
        );
      }
      widget.onOpenPermissions();
      return;
    }

    // 3. Check Location (GPS) & Permission for Bluetooth Scanning
    final hasLocPerm = await _permService.isLocationPermissionGranted();
    final isLocOn = await _permService.isLocationServicesEnabled();

    if (!hasLocPerm || !isLocOn) {
      if (!mounted) return;
      final shouldProceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1B1B22),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Colors.white12),
          ),
          icon: const Icon(Icons.location_on, color: Color(0xFF42A5F5), size: 36),
          title: const Text(
            'Location Required to Scan',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17),
          ),
          content: const Text(
            'Android requires Location access to discover nearby Bluetooth devices. Your location is never collected, tracked, or sent anywhere.\n\nAlready paired? You can connect directly from the Paired Devices list without scanning.',
            style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1E88E5),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Grant & Scan'),
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      );

      if (shouldProceed != true) {
        return;
      }

      if (!hasLocPerm) {
        final granted = await _permService.requestLocationPermission();
        if (!granted && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Location permission denied. Nearby scanning may be restricted.'),
              backgroundColor: Colors.orangeAccent,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }

      if (!isLocOn && mounted) {
        await _permService.openLocationSettings();
      }
    }

    // 4. Start active discovery
    setState(() => _isDiscovering = true);
    if (_tabController.index != 1) {
      _tabController.animateTo(1);
    }

    debugPrint('[SCAN] Invoking native startDiscovery()...');
    final ok = await widget.connManager.startDiscovery();
    debugPrint('[SCAN] Native startDiscovery() returned: $ok');

    if (!ok && mounted) {
      setState(() => _isDiscovering = false);
      debugPrint('[SCAN_FAIL] Native Bluetooth discovery failed. Redirecting to verify permissions...');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Scan failed to start. Redirecting to permission setup...'),
          backgroundColor: Colors.redAccent,
          duration: Duration(seconds: 3),
        ),
      );
      widget.onOpenPermissions();
    }
  }

  Future<void> _registerGamepad() async {
    final success = await widget.hidRegister.registerGamepad(_activeController);
    if (!mounted) return;
    if (success) {
      setState(() => _isHidRegistered = true);
    }
    await _loadData();
  }

  Future<void> _unregisterGamepad() async {
    final success = await widget.hidRegister.unregisterGamepad();
    if (!mounted) return;
    if (success) {
      setState(() => _isHidRegistered = false);
    }
    await _loadData();
  }

  void _toggleDeviceExpanded(String address) {
    setState(() {
      if (_expandedAddresses.contains(address)) {
        _expandedAddresses.remove(address);
      } else {
        _expandedAddresses.add(address);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final adapterName = _adapterInfo?['name'] as String? ?? 'Android Device';

    return Scaffold(
      backgroundColor: const Color(0xFF101014),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16161D),
        elevation: 0,
        title: const Text(
          'Bluetooth',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white),
        ),
        actions: [
          // Add ROMs button (Push to TV / Local Server)
          IconButton(
            icon: const Icon(Icons.send_to_mobile_rounded, color: Color(0xFF00E676), size: 22),
            tooltip: 'Add ROMs / Push to TV',
            onPressed: () {
              showDialog(
                context: context,
                builder: (_) => AddRomsDialog(
                  targetDevice: widget.connManager.connectedDevice ?? widget.connManager.lastConnectedDevice,
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD32F2F),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              icon: const Icon(Icons.sports_esports, size: 16),
              label: const Text(
                'Gamepad',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              onPressed: widget.onOpenGamepad,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          color: const Color(0xFFD32F2F),
          backgroundColor: const Color(0xFF1A1A22),
          onRefresh: _loadData,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            children: [
              // ==========================================
              // MINIMAL TOP CARD: BLUETOOTH & HID GAMEPAD
              // ==========================================
              _buildMinimalControlCard(adapterName),
              const SizedBox(height: 12),

              // ==========================================
              // TABS & SCAN BUTTON
              // ==========================================
              _buildTabsAndScanRow(),

              // ==========================================
              // SIMPLE LINEAR SCANNING INDICATOR
              // ==========================================
              if (_isDiscovering) ...[
                const SizedBox(height: 8),
                _buildSimpleLinearScanIndicator(),
              ],
              const SizedBox(height: 10),

              // ==========================================
              // DEVICE LIST
              // ==========================================
              AnimatedBuilder(
                animation: _tabController,
                builder: (context, _) {
                  if (_tabController.index == 0) {
                    return _buildPairedList();
                  } else {
                    return _buildAvailableList();
                  }
                },
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================
  // COMPACT, MINIMAL TOP CONTROL CARD
  // ==========================================

  Widget _buildMinimalControlCard(String adapterName) {
    final bool isDiscoverable = _discoverableSecondsRemaining > 0;
    final int minutes = _discoverableSecondsRemaining ~/ 60;
    final int seconds = _discoverableSecondsRemaining % 60;
    final String timerStr = '$minutes:${seconds.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF181820),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          // Row 1: Bluetooth Status & Action Buttons
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _isBtEnabled
                      ? const Color(0xFF1E88E5).withValues(alpha: 0.15)
                      : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  _isBtEnabled ? Icons.bluetooth : Icons.bluetooth_disabled_rounded,
                  color: _isBtEnabled ? const Color(0xFF42A5F5) : Colors.white38,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          _isBtEnabled ? 'Bluetooth ON' : 'Bluetooth OFF',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isBtEnabled ? const Color(0xFF00E676) : Colors.white24,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      _isBtEnabled ? adapterName : 'Bluetooth is disabled',
                      style: const TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                  ],
                ),
              ),

              // Action Buttons for Bluetooth state
              if (_isBtEnabled) ...[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Turn OFF action button
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFEF5350),
                        side: BorderSide(color: const Color(0xFFEF5350).withValues(alpha: 0.5)),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                        minimumSize: const Size(0, 28),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                      icon: const Icon(Icons.power_settings_new, size: 12, color: Color(0xFFEF5350)),
                      label: const Text('Turn OFF', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                      onPressed: _handleTurnOffBluetooth,
                    ),
                    const SizedBox(height: 5),

                    // Small Make Visible pill below Turn OFF
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: _makeDiscoverable,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isDiscoverable
                              ? const Color(0xFF00E676).withValues(alpha: 0.12)
                              : Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: isDiscoverable
                                ? const Color(0xFF00E676)
                                : const Color(0xFF1E88E5).withValues(alpha: 0.4),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.visibility,
                              size: 10,
                              color: isDiscoverable ? const Color(0xFF00E676) : const Color(0xFF42A5F5),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              isDiscoverable ? 'Visible $timerStr' : 'Make Visible',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: isDiscoverable ? const Color(0xFF00E676) : const Color(0xFF42A5F5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                // Turn ON action button
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E88E5),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                    minimumSize: const Size(0, 30),
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  icon: const Icon(Icons.bluetooth, size: 14),
                  label: const Text('Turn ON', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  onPressed: _handleTurnOnBluetooth,
                ),
              ],
            ],
          ),

          const Divider(color: Colors.white10, height: 16),

          // Row 2: HID Gamepad Profile (User maintained)
          Row(
            children: [
              Icon(
                _isHidRegistered ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                color: _isHidRegistered ? const Color(0xFF00E676) : Colors.orangeAccent,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isHidRegistered ? 'HID Gamepad: Ready' : 'HID Gamepad: Not Ready',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: _isHidRegistered ? const Color(0xFF00E676) : Colors.orangeAccent,
                      ),
                    )
                  ],
                ),
              ),
              if (_isHidRegistered)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    minimumSize: const Size(0, 28),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: _unregisterGamepad,
                  child: const Text('Unregister', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                )
              else
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orangeAccent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    minimumSize: const Size(0, 28),
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  icon: const Icon(Icons.app_registration, size: 14),
                  label: const Text('Register', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  onPressed: _registerGamepad,
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ==========================================
  // TABS & SCAN BUTTON ROW
  // ==========================================

  Widget _buildTabsAndScanRow() {
    return Row(
      children: [
        // Tabs
        Expanded(
          child: Container(
            height: 40,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: const Color(0xFF181820),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white10),
            ),
            child: TabBar(
              controller: _tabController,
              dividerColor: Colors.transparent,
              indicatorSize: TabBarIndicatorSize.tab,
              splashFactory: NoSplash.splashFactory,
              overlayColor: WidgetStateProperty.all(Colors.transparent),
              indicator: BoxDecoration(
                color: const Color(0xFF2E323E),
                borderRadius: BorderRadius.circular(6),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 1)),
                ],
              ),
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white54,
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              tabs: [
                Tab(text: 'Paired (${_bondedDevices.length})'),
                Tab(text: 'Available (${_availableDevices.length})'),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),

        // Scan Button
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: _isDiscovering ? const Color(0xFFD32F2F) : const Color(0xFF1E88E5),
            foregroundColor: Colors.white,
            elevation: 0,
            minimumSize: const Size(0, 40),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(horizontal: 14),
          ),
          icon: _isDiscovering
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                )
              : const Icon(Icons.search, size: 16),
          label: Text(
            _isDiscovering ? 'Stop' : 'Scan',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
          onPressed: _isBtEnabled ? _toggleScan : null,
        ),
      ],
    );
  }

  // ==========================================
  // SIMPLE LINEAR SCANNING INDICATOR
  // Requested by user: "simple loading liner will be enough"
  // ==========================================

  Widget _buildSimpleLinearScanIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF141C26),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF1E88E5).withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF00E676),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Scanning nearby Bluetooth devices...',
                    style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
              Text(
                '${_availableDevices.length} found',
                style: const TextStyle(fontSize: 11, color: Color(0xFF64B5F6), fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: const LinearProgressIndicator(
              minHeight: 2.5,
              backgroundColor: Colors.white10,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF1E88E5)),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // PAIRED & AVAILABLE LISTS
  // ==========================================

  Widget _buildPairedList() {
    if (!_isBtEnabled) {
      return _buildEmptyNotice('Bluetooth is turned off.\nTap "Turn ON" above to view and connect paired gamepads.');
    }
    if (_bondedDevices.isEmpty) {
      return _buildEmptyNotice('No paired devices found.\nTap "Make Visible" above or switch to Available tab to pair.');
    }

    return Column(
      children: _bondedDevices.map((dev) => _buildDeviceCard(dev, isPaired: true)).toList(),
    );
  }

  Widget _buildAvailableList() {
    if (!_isBtEnabled) {
      return _buildEmptyNotice('Bluetooth is turned off.\nTap "Turn ON" above to search for nearby devices.');
    }
    if (_availableDevices.isEmpty) {
      return _buildEmptyNotice(
        _isDiscovering
            ? 'Searching for nearby devices...\nMake sure Android TV is searching in Remotes & Accessories.'
            : 'No available devices discovered yet.\nTap "Scan" above to search.',
      );
    }

    return Column(
      children: _availableDevices.map((dev) => _buildDeviceCard(dev, isPaired: false)).toList(),
    );
  }

  Widget _buildEmptyNotice(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF16161D),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white38, fontSize: 12, height: 1.4),
        ),
      ),
    );
  }

  // ==========================================
  // DEVICE CARD (COLLAPSED BY DEFAULT, EXPANDS ON TAP)
  // ==========================================

  Widget _buildDeviceCard(BluetoothDeviceInfo dev, {required bool isPaired}) {
    final bool isExpanded = _expandedAddresses.contains(dev.address);
    final isTarget = widget.connManager.connectedDevice?.address == dev.address;
    final isConnected = isTarget && _connectionStatus == ConnectionStatus.connected;
    final isConnecting = isTarget && _connectionStatus == ConnectionStatus.connecting;

    Color cardBg = const Color(0xFF181820);
    Color borderColor = Colors.white.withValues(alpha: 0.05);

    if (isConnected) {
      cardBg = const Color(0xFF122218);
      borderColor = const Color(0xFF00E676).withValues(alpha: 0.4);
    } else if (isConnecting) {
      cardBg = const Color(0xFF221A12);
      borderColor = Colors.orangeAccent.withValues(alpha: 0.4);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _toggleDeviceExpanded(dev.address),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ==========================================
                // COLLAPSED HEADER: NAME & STATUS ONLY
                // ==========================================
                Row(
                  children: [
                    _buildDeviceIcon(dev, isConnected: isConnected),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        dev.name.isNotEmpty ? dev.name : 'Unknown Device',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: isConnected ? const Color(0xFF00E676) : Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Status Badge
                    if (isConnected)
                      _buildPill('CONNECTED', const Color(0xFF00E676))
                    else if (isConnecting)
                      _buildPill('CONNECTING', Colors.orangeAccent, showSpinner: true)
                    else if (isPaired)
                      _buildPill('PAIRED', Colors.white38)
                    else
                      _buildPill('AVAILABLE', const Color(0xFF1E88E5)),

                    const SizedBox(width: 4),
                    Icon(
                      isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                      color: Colors.white38,
                      size: 18,
                    ),
                  ],
                ),

                // ==========================================
                // EXPANDED DETAILS (ON TAP)
                // Use for, MAC Address, Connect/Disconnect, Unpair
                // ==========================================
                if (isExpanded) ...[
                  const Divider(color: Colors.white10, height: 16),

                  // Capabilities ("Use for")
                  _buildUseForSection(dev),
                  const SizedBox(height: 8),

                  // MAC Address Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        dev.address,
                        style: const TextStyle(fontSize: 12, color: Colors.white54, fontFamily: 'monospace'),
                      ),
                      if (dev.rssi != 0)
                        Text(
                          '${dev.rssi} dBm',
                          style: const TextStyle(fontSize: 11, color: Color(0xFF42A5F5)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Action Row: Unpair & Connect/Disconnect
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (isPaired)
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF42A5F5),
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 32),
                          ),
                          icon: const Icon(Icons.link_off, size: 14),
                          label: const Text('Unpair', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          onPressed: () => widget.connManager.unpair(dev.address, deviceName: dev.name),
                        )
                      else
                        const SizedBox.shrink(),

                      Row(
                        children: [
                          if (isPaired) ...[
                            if (isConnected)
                              OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.redAccent,
                                  side: const BorderSide(color: Colors.redAccent),
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                                  minimumSize: const Size(0, 32),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                ),
                                onPressed: () => widget.connManager.disconnect(),
                                child: const Text('Disconnect', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              )
                            else
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF00C853), // Green for connect
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                  minimumSize: const Size(0, 32),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                ),
                                icon: const Icon(Icons.sports_esports, size: 14),
                                label: const Text('Connect Gamepad', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                onPressed: () => widget.connManager.connect(dev.address, deviceName: dev.name),
                              ),
                          ] else ...[
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF1E88E5),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                minimumSize: const Size(0, 32),
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                              ),
                              icon: const Icon(Icons.link, size: 14),
                              label: const Text('Pair Device', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              onPressed: () => widget.connManager.pair(dev.address, deviceName: dev.name),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ==========================================
  // CAPABILITY CHIPS ("Use for")
  // ==========================================

  Widget _buildUseForSection(BluetoothDeviceInfo dev) {
    final List<_ChipData> chips = [];

    if (dev.mediaAudio || dev.isAudio || dev.capabilities.any((c) => c.contains('Audio'))) {
      chips.add(_ChipData('Media Audio', Icons.music_note, const Color(0xFFFF9E00)));
    }
    if (dev.phoneCalls || dev.capabilities.any((c) => c.contains('Phone calls'))) {
      chips.add(_ChipData('Phone calls', Icons.phone, const Color(0xFF00B4D8)));
    }
    if (dev.contactSharing || dev.capabilities.any((c) => c.contains('Contact sharing'))) {
      chips.add(_ChipData('Contact sharing', Icons.contacts, const Color(0xFFAB47BC)));
    }
    if (dev.internetAccess || dev.hasNetworking || dev.capabilities.any((c) => c.contains('Internet'))) {
      chips.add(_ChipData('Internet access', Icons.language, const Color(0xFF29B6F6)));
    }
    if (dev.inputDevice || dev.isPeripheral || dev.capabilities.any((c) => c.contains('Input') || c.contains('Gamepad'))) {
      chips.add(_ChipData('Input device (Gamepad)', Icons.sports_esports, const Color(0xFF00E676)));
    }
    if (dev.isTv || dev.capabilities.any((c) => c.contains('TV') || c.contains('Display'))) {
      chips.add(_ChipData('TV / Display', Icons.tv, const Color(0xFF26A69A)));
    }

    if (chips.isEmpty) {
      return const SizedBox.shrink();
    }

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: chips.map((c) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: c.color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: c.color.withValues(alpha: 0.3), width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(c.icon, size: 10, color: c.color),
              const SizedBox(width: 4),
              Text(
                c.label,
                style: TextStyle(fontSize: 10, color: c.color, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ==========================================
  // HELPER ICONS & PILLS
  // ==========================================

  Widget _buildDeviceIcon(BluetoothDeviceInfo dev, {bool isConnected = false}) {
    IconData icon;
    Color color;

    if (dev.isTv || dev.name.toLowerCase().contains('tv') || dev.name.toLowerCase().contains('box')) {
      icon = Icons.tv;
      color = const Color(0xFF26A69A); // Teal for TV
    } else if (dev.isPeripheral || dev.inputDevice) {
      icon = Icons.sports_esports;
      color = const Color(0xFFAB47BC); // Purple for Gamepad
    } else if (dev.isAudio || dev.mediaAudio) {
      icon = Icons.headphones;
      color = const Color(0xFFFF9E00); // Orange for Audio
    } else if (dev.majorClass == 'Phone' || dev.name.toLowerCase().contains('moto') || dev.name.toLowerCase().contains('phone')) {
      icon = Icons.phone_android;
      color = const Color(0xFF29B6F6); // Blue for Phone
    } else {
      icon = Icons.bluetooth;
      color = Colors.white54;
    }

    if (isConnected) {
      color = const Color(0xFF00E676);
    }

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(icon, size: 16, color: color),
    );
  }

  Widget _buildPill(String text, Color color, {bool showSpinner = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showSpinner) ...[
            SizedBox(
              width: 8,
              height: 8,
              child: CircularProgressIndicator(color: color, strokeWidth: 1.5),
            ),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(color: color, fontSize: 9.5, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

class _ChipData {
  final String label;
  final IconData icon;
  final Color color;

  _ChipData(this.label, this.icon, this.color);
}
