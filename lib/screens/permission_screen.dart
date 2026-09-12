import 'package:flutter/material.dart';
import '../hid/permission_service.dart';

class PermissionScreen extends StatefulWidget {
  final VoidCallback onAllPermissionsGranted;

  const PermissionScreen({
    super.key,
    required this.onAllPermissionsGranted,
  });

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> with WidgetsBindingObserver {
  final PermissionService _permService = PermissionService();

  bool _isLoading = true;
  PermissionStatusResult? _statusResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkStatus();
    }
  }

  Future<void> _checkStatus() async {
    setState(() => _isLoading = true);
    final status = await _permService.checkPermissions();
    if (!mounted) return;

    setState(() {
      _statusResult = status;
      _isLoading = false;
    });

    if (status.isAllReady) {
      widget.onAllPermissionsGranted();
    }
  }

  Future<void> _requestPermissions() async {
    await _permService.requestPermissions();
    await _checkStatus();
  }

  Future<void> _enableBluetooth() async {
    await _permService.enableBluetooth();
    await Future.delayed(const Duration(milliseconds: 1000));
    await _checkStatus();
  }

  Future<void> _openSettings() async {
    await _permService.openAppSettings();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF18181D),
      body: SafeArea(
        child: _isLoading && _statusResult == null
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFFD32F2F)),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 16),

                    // Top Gamepad Icon
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: const Color(0xFFD32F2F).withOpacity(0.12),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFFD32F2F).withOpacity(0.4),
                          width: 2,
                        ),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.sports_esports_rounded,
                          size: 44,
                          color: Color(0xFFD32F2F),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Title
                    const Text(
                      'Setup Permissions',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Description
                    Text(
                      'To act as a Bluetooth Gamepad and connect to your Android TV, the following permissions are required.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[400],
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 28),

                    // Permission Cards
                    _buildPermissionCard(
                      icon: Icons.bluetooth_connected,
                      title: 'Bluetooth HID & Nearby Devices',
                      description: 'Allows this phone to advertise as a gamepad and send button inputs to Android TV.',
                      isGranted: _statusResult?.permissionsGranted ?? false,
                    ),
                    const SizedBox(height: 12),

                    _buildPermissionCard(
                      icon: Icons.bluetooth,
                      title: 'Bluetooth Radio State',
                      description: 'Bluetooth must be switched ON to establish wireless communication.',
                      isGranted: _statusResult?.bluetoothEnabled ?? false,
                      actionWidget: (_statusResult?.bluetoothEnabled == false)
                          ? TextButton.icon(
                              style: TextButton.styleFrom(
                                foregroundColor: const Color(0xFF00E676),
                                padding: EdgeInsets.zero,
                              ),
                              icon: const Icon(Icons.power_settings_new, size: 16),
                              label: const Text('Turn On Bluetooth', style: TextStyle(fontSize: 12)),
                              onPressed: _enableBluetooth,
                            )
                          : null,
                    ),
                    const SizedBox(height: 12),

                    _buildPermissionCard(
                      icon: Icons.location_on,
                      title: 'Location Services (GPS)',
                      description: 'Android Bluetooth discovery requires Location (GPS) to be ON in phone settings.',
                      isGranted: _statusResult?.locationEnabled ?? false,
                      actionWidget: (_statusResult?.locationEnabled == false)
                          ? TextButton.icon(
                              style: TextButton.styleFrom(
                                foregroundColor: const Color(0xFF42A5F5),
                                padding: EdgeInsets.zero,
                              ),
                              icon: const Icon(Icons.settings, size: 16),
                              label: const Text('Turn ON Location', style: TextStyle(fontSize: 12)),
                              onPressed: () async {
                                await _permService.openLocationSettings();
                              },
                            )
                          : null,
                    ),
                    const SizedBox(height: 32),

                    // Action Buttons
                    if (_statusResult?.permissionsGranted == false)
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFD32F2F),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            elevation: 4,
                          ),
                          icon: const Icon(Icons.security, size: 20),
                          label: const Text(
                            'Grant Permissions',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          onPressed: _requestPermissions,
                        ),
                      )
                    else if (_statusResult?.bluetoothEnabled == false)
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00C853),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            elevation: 4,
                          ),
                          icon: const Icon(Icons.bluetooth, size: 20),
                          label: const Text(
                            'Enable Bluetooth',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          onPressed: _enableBluetooth,
                        ),
                      )
                    else if (_statusResult?.locationEnabled == false)
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1E88E5),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            elevation: 4,
                          ),
                          icon: const Icon(Icons.location_on, size: 20),
                          label: const Text(
                            'Turn ON Location (GPS)',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          onPressed: () async {
                            await _permService.openLocationSettings();
                          },
                        ),
                      )
                    else
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00E676),
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            elevation: 4,
                          ),
                          icon: const Icon(Icons.arrow_forward, size: 20),
                          label: const Text(
                            'Continue to Gamepad',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          onPressed: widget.onAllPermissionsGranted,
                        ),
                      ),

                    const SizedBox(height: 14),

                    // Open App Settings fallback
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white60,
                      ),
                      icon: const Icon(Icons.settings_outlined, size: 16),
                      label: const Text(
                        'Open App Settings',
                        style: TextStyle(fontSize: 13),
                      ),
                      onPressed: _openSettings,
                    ),

                    const SizedBox(height: 10),
                    // Re-check
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white38,
                      ),
                      onPressed: _checkStatus,
                      child: const Text('Re-check Status', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildPermissionCard({
    required IconData icon,
    required String title,
    required String description,
    required bool isGranted,
    Widget? actionWidget,
  }) {
    final statusColor = isGranted ? const Color(0xFF00E676) : Colors.orangeAccent;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF22222A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isGranted ? const Color(0xFF00E676).withOpacity(0.3) : Colors.white12,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: statusColor, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              Icon(
                isGranted ? Icons.check_circle : Icons.warning_amber_rounded,
                color: statusColor,
                size: 20,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[400],
              height: 1.3,
            ),
          ),
          if (actionWidget != null) ...[
            const SizedBox(height: 6),
            actionWidget,
          ],
        ],
      ),
    );
  }
}
