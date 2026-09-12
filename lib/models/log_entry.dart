class LogEntry {
  final DateTime timestamp;
  final String formattedTime;
  final String level; // INFO, WARN, ERROR, DEBUG
  final String tag;
  final String message;

  LogEntry({
    required this.timestamp,
    required this.formattedTime,
    required this.level,
    required this.tag,
    required this.message,
  });

  factory LogEntry.fromMap(Map<dynamic, dynamic> map) {
    final ts = map['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;
    return LogEntry(
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
      formattedTime: map['formattedTime'] as String? ??
          _formatTime(DateTime.fromMillisecondsSinceEpoch(ts)),
      level: (map['level'] as String? ?? 'INFO').toUpperCase(),
      tag: map['tag'] as String? ?? 'GENERAL',
      message: map['message'] as String? ?? '',
    );
  }

  static String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final ms = dt.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  @override
  String toString() => '[$formattedTime] [$level] [$tag] $message';
}

class BluetoothDeviceInfo {
  final String name;
  final String address;
  final String bondState; // bonded, bonding, none
  final String type; // CLASSIC, LE, DUAL
  final int rssi;
  final String majorClass;
  final bool isPeripheral;
  final bool isTv;
  final bool isAudio;
  final bool hasNetworking;
  final bool mediaAudio;
  final bool phoneCalls;
  final bool contactSharing;
  final bool internetAccess;
  final bool inputDevice;
  final List<String> capabilities;
  final bool isConnected;

  BluetoothDeviceInfo({
    required this.name,
    required this.address,
    required this.bondState,
    this.type = 'CLASSIC',
    this.rssi = 0,
    this.majorClass = 'Uncategorized',
    this.isPeripheral = false,
    this.isTv = false,
    this.isAudio = false,
    this.hasNetworking = false,
    this.mediaAudio = false,
    this.phoneCalls = false,
    this.contactSharing = false,
    this.internetAccess = false,
    this.inputDevice = false,
    this.capabilities = const [],
    this.isConnected = false,
  });

  bool get isBonded => bondState == 'bonded';
  bool get isBonding => bondState == 'bonding';

  factory BluetoothDeviceInfo.fromMap(Map<dynamic, dynamic> map) {
    final rawCaps = map['capabilities'];
    final caps = rawCaps is List ? rawCaps.map((e) => e.toString()).toList() : <String>[];
    return BluetoothDeviceInfo(
      name: map['name'] as String? ?? 'Unknown Device',
      address: map['address'] as String? ?? '',
      bondState: map['bondState'] as String? ?? 'none',
      type: map['type'] as String? ?? 'CLASSIC',
      rssi: (map['rssi'] as num?)?.toInt() ?? 0,
      majorClass: map['majorClass'] as String? ?? 'Uncategorized',
      isPeripheral: map['isPeripheral'] as bool? ?? false,
      isTv: map['isTv'] as bool? ?? false,
      isAudio: map['isAudio'] as bool? ?? false,
      hasNetworking: map['hasNetworking'] as bool? ?? false,
      mediaAudio: map['mediaAudio'] as bool? ?? map['isAudio'] as bool? ?? false,
      phoneCalls: map['phoneCalls'] as bool? ?? false,
      contactSharing: map['contactSharing'] as bool? ?? false,
      internetAccess: map['internetAccess'] as bool? ?? map['hasNetworking'] as bool? ?? false,
      inputDevice: map['inputDevice'] as bool? ?? map['isPeripheral'] as bool? ?? false,
      capabilities: caps,
      isConnected: map['isConnected'] as bool? ?? false,
    );
  }

  @override
  String toString() => '$name ($address)';
}
