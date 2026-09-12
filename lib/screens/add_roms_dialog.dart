import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../hid/bluetooth_connection_manager.dart';
import '../models/log_entry.dart';
import '../server/rom_server.dart';
import '../server/tv_pusher_service.dart';

class AddRomsDialog extends StatefulWidget {
  final BluetoothDeviceInfo? targetDevice;

  const AddRomsDialog({super.key, this.targetDevice});

  @override
  State<AddRomsDialog> createState() => _AddRomsDialogState();
}

class _AddRomsDialogState extends State<AddRomsDialog> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final RomServer _server = RomServer.instance;
  final TvPusherService _pusher = TvPusherService.instance;
  final BluetoothConnectionManager _connMgr = BluetoothConnectionManager.instance;

  // Local Web Server state
  StreamSubscription<RomServerEvent>? _serverEventSub;
  final List<String> _recentUploads = [];
  bool _isServerToggling = false;
  String? _romsDir;
  int _romCount = 0;

  // TV Pusher state
  StreamSubscription<TvPushEvent>? _pusherEventSub;
  RomFileInfo? _selectedRom;
  List<RomFileInfo> _storedRoms = [];
  BluetoothDeviceInfo? _activeTargetDevice;
  bool _isPushing = false;
  double _pushProgress = 0.0;
  String _pushStatusText = 'Select a ROM to push to your Android TV';
  bool _isPushSuccess = false;
  bool _isPushError = false;

  // Wi-Fi push input
  final TextEditingController _tvIpController = TextEditingController();
  bool _showWifiOptions = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initData();
    _listenToEvents();
  }

  Future<void> _initData() async {
    final dir = await _server.getOrInitRomsDirectory();
    await _server.getLocalIpAddress();

    final device = widget.targetDevice ??
        _connMgr.connectedDevice ??
        _connMgr.lastConnectedDevice;

    final stored = await _pusher.listStoredRoms();

    if (mounted) {
      setState(() {
        _romsDir = dir;
        _activeTargetDevice = device;
        _storedRoms = stored;
      });
      _refreshRomCount();
    }
  }

  void _listenToEvents() {
    _serverEventSub = _server.events.listen((event) {
      if (!mounted) return;
      if (event.type == RomServerEventType.fileUploaded && event.fileName != null) {
        setState(() {
          _recentUploads.insert(0, '${event.fileName} (${_server.isRunning ? "Ready" : ""})');
          if (_recentUploads.length > 5) _recentUploads.removeLast();
          _romCount++;
        });
        _refreshStoredRoms();
      } else {
        setState(() {});
      }
    });

    _pusherEventSub = _pusher.eventStream.listen((event) {
      if (!mounted) return;
      setState(() {
        _pushStatusText = event.message;
        _pushProgress = event.progress;
        if (event.type == TvPushEventType.transferStarted) {
          _isPushing = true;
          _isPushSuccess = false;
          _isPushError = false;
        } else if (event.type == TvPushEventType.transferCompleted) {
          _isPushing = false;
          _isPushSuccess = true;
          _isPushError = false;
        } else if (event.type == TvPushEventType.transferFailed) {
          _isPushing = false;
          _isPushSuccess = false;
          _isPushError = true;
        }
      });
    });
  }

  Future<void> _refreshStoredRoms() async {
    final stored = await _pusher.listStoredRoms();
    if (mounted) {
      setState(() {
        _storedRoms = stored;
      });
    }
  }

  Future<void> _refreshRomCount() async {
    try {
      final dir = await _server.getOrInitRomsDirectory();
      final count = await _getFilesCount(dir);
      if (mounted) setState(() => _romCount = count);
    } catch (_) {}
  }

  Future<int> _getFilesCount(String path) async {
    int count = 0;
    try {
      final dir = Directory(path);
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is File) count++;
        }
      }
    } catch (_) {}
    return count;
  }

  @override
  void dispose() {
    _tabController.dispose();
    _serverEventSub?.cancel();
    _pusherEventSub?.cancel();
    _tvIpController.dispose();
    super.dispose();
  }

  Future<void> _pickRomFile() async {
    final info = await _pusher.pickRomFromDevice();
    if (info != null && mounted) {
      setState(() {
        _selectedRom = info;
        _isPushSuccess = false;
        _isPushError = false;
        _pushStatusText = 'Ready to send ${info.name} to ${_activeTargetDevice?.name ?? "Android TV"}';
      });
      _refreshStoredRoms();
      _refreshRomCount();
    }
  }

  Future<void> _pushViaBluetooth() async {
    if (_selectedRom == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select or pick a ROM file first.')),
      );
      return;
    }

    final target = _activeTargetDevice ?? _connMgr.connectedDevice;
    final success = await _pusher.pushViaBluetooth(
      filePath: _selectedRom!.path,
      deviceAddress: target?.address,
      deviceName: target?.name ?? 'Android TV',
    );

    if (mounted && success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF00E676),
          content: Text(
            'Transfer sent to ${target?.name ?? "TV"}! Check TV screen to Accept.',
            style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
          ),
        ),
      );
    }
  }

  Future<void> _pushViaWifi() async {
    if (_selectedRom == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select or pick a ROM file first.')),
      );
      return;
    }

    final ip = _tvIpController.text.trim();
    if (ip.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter the TV IP address.')),
      );
      return;
    }

    await _pusher.pushViaWifi(
      filePath: _selectedRom!.path,
      tvIp: ip,
    );
  }

  Future<void> _toggleServer() async {
    setState(() => _isServerToggling = true);
    if (_server.isRunning) {
      await _server.stop();
    } else {
      await _server.start();
    }
    if (mounted) {
      setState(() => _isServerToggling = false);
      _refreshRomCount();
    }
  }

  void _copyUrl(String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied $url to clipboard!'),
        backgroundColor: const Color(0xFF00E676),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return Dialog(
      backgroundColor: const Color(0xFF161B22),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFF30363D), width: 1.5),
      ),
      insetPadding: EdgeInsets.symmetric(
        horizontal: isLandscape ? 40 : 20,
        vertical: isLandscape ? 20 : 30,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isLandscape ? 660 : 480,
          maxHeight: isLandscape ? 480 : 640,
        ),
        child: Column(
          children: [
            // Title Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: const BoxDecoration(
                color: Color(0xFF1F242C),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                border: Border(bottom: BorderSide(color: Color(0xFF30363D))),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00E676).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.folder_zip_rounded,
                      color: Color(0xFF00E676),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Add ROMs',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                        Text(
                          'Push games directly to TV or use local web server',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),

            // Tab Bar Selector
            Container(
              color: const Color(0xFF1F242C),
              child: TabBar(
                controller: _tabController,
                indicatorColor: const Color(0xFF00E676),
                indicatorWeight: 3,
                labelColor: const Color(0xFF00E676),
                unselectedLabelColor: Colors.white54,
                labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                tabs: const [
                  Tab(
                    icon: Icon(Icons.send_rounded, size: 18),
                    text: 'Push to Android TV',
                  ),
                  Tab(
                    icon: Icon(Icons.wifi_tethering_rounded, size: 18),
                    text: 'Local Web Server',
                  ),
                ],
              ),
            ),

            // Tab Content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildPushToTvTab(),
                  _buildLocalServerTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // TAB 1: PUSH TO ANDROID TV
  // ==========================================

  Widget _buildPushToTvTab() {
    final connected = _connMgr.connectedDevice;
    final target = _activeTargetDevice ?? connected;
    final isDeviceConnected = connected != null && connected.address == target?.address;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Connected Target TV Card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF0D1117),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isDeviceConnected
                    ? const Color(0xFF00E676).withValues(alpha: 0.4)
                    : const Color(0xFFFF9100).withValues(alpha: 0.4),
                width: 1.5,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (isDeviceConnected ? const Color(0xFF00E676) : const Color(0xFFFF9100))
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.tv_rounded,
                    color: isDeviceConnected ? const Color(0xFF00E676) : const Color(0xFFFF9100),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              target?.name ?? 'Android TV',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: (isDeviceConnected ? const Color(0xFF00E676) : const Color(0xFFFF9100))
                                  .withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              isDeviceConnected ? 'CONNECTED' : 'PAIRED / LAST HOST',
                              style: TextStyle(
                                color: isDeviceConnected ? const Color(0xFF00E676) : const Color(0xFFFF9100),
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        target?.address ?? 'Bluetooth MAC not detected',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
                if (_connMgr.bondedDevices.length > 1)
                  PopupMenuButton<BluetoothDeviceInfo>(
                    icon: const Icon(Icons.arrow_drop_down_circle_outlined, color: Colors.white54),
                    tooltip: 'Change Target TV',
                    onSelected: (dev) => setState(() => _activeTargetDevice = dev),
                    itemBuilder: (_) => _connMgr.bondedDevices
                        .map(
                          (d) => PopupMenuItem(
                            value: d,
                            child: Text('${d.name} (${d.address})'),
                          ),
                        )
                        .toList(),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 2. ROM Selection Section
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF0D1117),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF30363D)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'SELECT ROM TO PUSH',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 10),

                // If a ROM is selected, show preview card
                if (_selectedRom != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161B22),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF00E676).withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00E676).withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _selectedRom!.platformBadge,
                            style: const TextStyle(
                              color: Color(0xFF00E676),
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _selectedRom!.name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _selectedRom!.formattedSize,
                                style: const TextStyle(color: Colors.white54, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                          onPressed: () => setState(() => _selectedRom = null),
                          tooltip: 'Deselect',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],

                // Action buttons: Pick from Phone & Select Stored
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _pickRomFile,
                        icon: const Icon(Icons.file_open_rounded, size: 16),
                        label: const Text('Pick from Phone Storage'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF21262D),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: const BorderSide(color: Color(0xFF30363D)),
                          ),
                        ),
                      ),
                    ),
                    if (_storedRoms.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      PopupMenuButton<RomFileInfo>(
                        icon: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF21262D),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFF30363D)),
                          ),
                          child: const Icon(Icons.history_rounded, color: Colors.white70, size: 18),
                        ),
                        tooltip: 'Choose from stored ROMs (${_storedRoms.length})',
                        onSelected: (rom) {
                          setState(() {
                            _selectedRom = rom;
                            _isPushSuccess = false;
                            _isPushError = false;
                            _pushStatusText = 'Selected ${rom.name}';
                          });
                        },
                        itemBuilder: (_) => _storedRoms
                            .map(
                              (r) => PopupMenuItem(
                                value: r,
                                child: Text('${r.platformBadge}: ${r.name} (${r.formattedSize})'),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 3. Push Action Buttons
          ElevatedButton.icon(
            onPressed: (_isPushing || _selectedRom == null) ? null : _pushViaBluetooth,
            icon: const Icon(Icons.bluetooth_audio_rounded, size: 20),
            label: Text(
              _isPushing
                  ? 'Transferring...'
                  : 'Push to ${target?.name ?? "Android TV"} (Bluetooth)',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E676),
              foregroundColor: Colors.black,
              disabledBackgroundColor: Colors.white12,
              disabledForegroundColor: Colors.white38,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),

          const SizedBox(height: 8),

          // Wi-Fi Push Expandable
          InkWell(
            onTap: () => setState(() => _showWifiOptions = !_showWifiOptions),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _showWifiOptions ? Icons.keyboard_arrow_up : Icons.wifi_rounded,
                    size: 16,
                    color: Colors.white54,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _showWifiOptions ? 'Hide Wi-Fi push' : 'Or push over Local Wi-Fi network',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),

          if (_showWifiOptions) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1117),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF30363D)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _tvIpController,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: 'Enter TV IP (e.g. 192.168.1.50)',
                            hintStyle: TextStyle(color: Colors.white38, fontSize: 11),
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: (_isPushing || _selectedRom == null) ? null : _pushViaWifi,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2979FF),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        ),
                        child: const Text('Send Wi-Fi', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Pushes directly to "Send Files to TV" (port 6835) or TV network receiver.',
                    style: TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 14),

          // 4. Progress / Status Box
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0D1117),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _isPushSuccess
                    ? const Color(0xFF00E676).withValues(alpha: 0.5)
                    : (_isPushError
                        ? const Color(0xFFFF5252).withValues(alpha: 0.5)
                        : const Color(0xFF30363D)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _isPushSuccess
                          ? Icons.check_circle_rounded
                          : (_isPushError
                              ? Icons.error_outline_rounded
                              : (_isPushing
                                  ? Icons.hourglass_top_rounded
                                  : Icons.info_outline_rounded)),
                      size: 14,
                      color: _isPushSuccess
                          ? const Color(0xFF00E676)
                          : (_isPushError ? const Color(0xFFFF5252) : Colors.white54),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _pushStatusText,
                        style: TextStyle(
                          color: _isPushSuccess
                              ? const Color(0xFF00E676)
                              : (_isPushError ? const Color(0xFFFF5252) : Colors.white70),
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_isPushing) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _pushProgress > 0 ? _pushProgress : null,
                      backgroundColor: Colors.white12,
                      color: const Color(0xFF00E676),
                      minHeight: 4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // TAB 2: LOCAL WEB SERVER (EXISTING FEATURE)
  // ==========================================

  Widget _buildLocalServerTab() {
    final serverUrl = _server.serverUrl;
    final isRunning = _server.isRunning;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Server Status & Action Card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF0D1117),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isRunning
                    ? const Color(0xFF00E676).withValues(alpha: 0.4)
                    : const Color(0xFF30363D),
                width: 1.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isRunning ? const Color(0xFF00E676) : Colors.white24,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isRunning ? 'SERVER RUNNING' : 'SERVER STOPPED',
                      style: TextStyle(
                        color: isRunning ? const Color(0xFF00E676) : Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    const Spacer(),
                    ElevatedButton.icon(
                      onPressed: _isServerToggling ? null : _toggleServer,
                      icon: Icon(
                        isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
                        size: 16,
                      ),
                      label: Text(isRunning ? 'Stop Server' : 'Start Server'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isRunning ? const Color(0xFFFF5252) : const Color(0xFF00E676),
                        foregroundColor: isRunning ? Colors.white : Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
                ),
                if (isRunning) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Open this URL in any browser on TV or PC:',
                    style: TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161B22),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF00E676).withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.link_rounded, color: Color(0xFF00E676), size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SelectableText(
                            serverUrl,
                            style: const TextStyle(
                              color: Color(0xFF00E676),
                              fontSize: 13,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => _copyUrl(serverUrl),
                          icon: const Icon(Icons.copy_rounded, color: Colors.white70, size: 16),
                          tooltip: 'Copy URL',
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 14),

          // Storage Directory Card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0D1117),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF30363D)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.folder_outlined, color: Colors.white54, size: 16),
                    const SizedBox(width: 6),
                    const Text(
                      'App ROM Storage:',
                      style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    Text(
                      '$_romCount file(s)',
                      style: const TextStyle(color: Color(0xFF00E676), fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _romsDir ?? 'Resolving path...',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),

          if (_recentUploads.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text(
              'RECENT UPLOADS VIA BROWSER',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 6),
            ..._recentUploads.map(
              (item) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_outline, color: Color(0xFF00E676), size: 14),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        item,
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
