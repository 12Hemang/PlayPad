import 'dart:async';
import 'package:flutter/material.dart';

import 'gamepad/nes_gamepad_controller.dart';
import 'hid/ble_logger.dart';
import 'hid/bluetooth_connection_manager.dart';
import 'hid/hid_register.dart';
import 'hid/permission_service.dart';
import 'screens/bluetooth_screen.dart';
import 'screens/gamepad_screen.dart';
import 'screens/permission_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BleGamepadApp());
}

class BleGamepadApp extends StatelessWidget {
  const BleGamepadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Android Bluetooth Gamepad',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF141418),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFD32F2F),
          secondary: Color(0xFF00E676),
          surface: Color(0xFF1A1A20),
        ),
        useMaterial3: true,
      ),
      home: const BleGamepadHomePage(),
    );
  }
}

class BleGamepadHomePage extends StatefulWidget {
  const BleGamepadHomePage({super.key});

  @override
  State<BleGamepadHomePage> createState() => _BleGamepadHomePageState();
}

class _BleGamepadHomePageState extends State<BleGamepadHomePage> {
  final PermissionService _permissionService = PermissionService();
  final BluetoothConnectionManager _connManager = BluetoothConnectionManager();
  final HidRegister _hidRegister = HidRegister();
  final NesGamepadController _controller = NesGamepadController();

  bool _isLoading = true;
  bool _hasPermissions = false;
  int _selectedTab = 0; // 0: Bluetooth, 1: Gamepad, 2: Logs
  bool _isFullScreen = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    final status = await _permissionService.checkPermissions();
    if (!mounted) return;
    setState(() {
      _hasPermissions = status.isAllReady;
      _isLoading = false;
    });

    if (status.isAllReady) {
      await _initServices();
    }
  }

  Future<void> _initServices() async {
    await _connManager.init();
    await _hidRegister.registerGamepad(_controller);
  }

  @override
  void dispose() {
    _connManager.dispose();
    _hidRegister.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFF141418),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFFD32F2F)),
        ),
      );
    }

    if (!_hasPermissions) {
      return PermissionScreen(
        onAllPermissionsGranted: () async {
          setState(() {
            _hasPermissions = true;
          });
          await _initServices();
        },
      );
    }

    return Scaffold(
      body: IndexedStack(
        index: _selectedTab,
        children: [
          // Tab 0: Dedicated Bluetooth Management Page
          BluetoothScreen(
            connManager: _connManager,
            hidRegister: _hidRegister,
            controller: _controller,
            onOpenPermissions: () {
              setState(() => _hasPermissions = false);
            },
            onOpenGamepad: () {
              setState(() => _selectedTab = 1);
            },
          ),

          // Tab 1: Gamepad Controller Screen
          GamepadScreen(
            connectionManager: _connManager,
            hidRegister: _hidRegister,
            controller: _controller,
            onFullScreenChanged: (isFull) {
              setState(() => _isFullScreen = isFull);
            },
          ),

          // Tab 2: Live Event Logs Screen
          const LogViewerWidget(),
        ],
      ),
      bottomNavigationBar: (_selectedTab == 1 && _isFullScreen)
          ? null
          : BottomNavigationBar(
              backgroundColor: const Color(0xFF1B1B22),
              selectedItemColor: const Color(0xFFD32F2F),
              unselectedItemColor: Colors.white54,
              currentIndex: _selectedTab,
              onTap: (index) {
                setState(() => _selectedTab = index);
              },
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.bluetooth),
                  label: 'Bluetooth',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.sports_esports),
                  label: 'Gamepad',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.terminal),
                  label: 'Logs',
                ),
              ],
            ),
    );
  }
}

// ==========================================
// REAL-TIME LOG VIEWER WIDGET
// ==========================================

class LogViewerWidget extends StatefulWidget {
  const LogViewerWidget({super.key});

  @override
  State<LogViewerWidget> createState() => _LogViewerWidgetState();
}

class _LogViewerWidgetState extends State<LogViewerWidget> {
  final BleLogger _logger = BleLogger.instance;
  final ScrollController _scrollController = ScrollController();
  StreamSubscription? _logSub;
  String _filterLevel = 'ALL';

  @override
  void initState() {
    super.initState();
    _logSub = _logger.stream.listen((_) {
      if (mounted) {
        setState(() {});
        _scrollToBottom();
      }
    });
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Color _levelColor(String level) {
    switch (level) {
      case 'ERROR':
        return Colors.redAccent;
      case 'WARN':
        return Colors.orangeAccent;
      case 'DEBUG':
        return Colors.purpleAccent;
      case 'INFO':
      default:
        return const Color(0xFF4FC3F7);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredLogs = _logger.history.where((entry) {
      if (_filterLevel == 'ALL') return true;
      return entry.level == _filterLevel;
    }).toList();

    return Container(
      color: const Color(0xFF101014),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SafeArea(
            bottom: false,
            child: Row(
              children: [
                const Text(
                  'Bluetooth & HID Event Logs',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const Spacer(),
                DropdownButton<String>(
                  value: _filterLevel,
                  dropdownColor: const Color(0xFF1E1E24),
                  underline: const SizedBox(),
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                  items: ['ALL', 'INFO', 'WARN', 'ERROR', 'DEBUG']
                      .map((lvl) => DropdownMenuItem(value: lvl, child: Text(lvl)))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) setState(() => _filterLevel = val);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20, color: Colors.white60),
                  tooltip: 'Clear Logs',
                  onPressed: () {
                    setState(() => _logger.clear());
                  },
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white24, height: 12),

          Expanded(
            child: filteredLogs.isEmpty
                ? const Center(
                    child: Text(
                      'No logs yet. Connection and HID events will appear here.',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: filteredLogs.length,
                    itemBuilder: (context, index) {
                      final entry = filteredLogs[index];
                      final color = _levelColor(entry.level);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: RichText(
                          text: TextSpan(
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: Colors.white70,
                            ),
                            children: [
                              TextSpan(
                                text: '${entry.formattedTime} ',
                                style: const TextStyle(color: Colors.white38),
                              ),
                              TextSpan(
                                text: '[${entry.level}] ',
                                style: TextStyle(color: color, fontWeight: FontWeight.bold),
                              ),
                              TextSpan(
                                text: '[${entry.tag}] ',
                                style: const TextStyle(color: Colors.yellowAccent),
                              ),
                              TextSpan(text: entry.message),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
