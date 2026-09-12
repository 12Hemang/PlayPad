import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../hid/ble_logger.dart';
import 'rom_server.dart';

enum TvPushEventType {
  idle,
  fileSelected,
  transferStarted,
  transferProgress,
  transferCompleted,
  transferFailed,
}

class TvPushEvent {
  final TvPushEventType type;
  final String message;
  final String? fileName;
  final int? fileSize;
  final double progress; // 0.0 to 1.0
  final String? targetDevice;

  const TvPushEvent({
    required this.type,
    required this.message,
    this.fileName,
    this.fileSize,
    this.progress = 0.0,
    this.targetDevice,
  });
}

class RomFileInfo {
  final String path;
  final String name;
  final int size;

  RomFileInfo({
    required this.path,
    required this.name,
    required this.size,
  });

  factory RomFileInfo.fromMap(Map<dynamic, dynamic> map) {
    return RomFileInfo(
      path: map['path'] as String? ?? '',
      name: map['name'] as String? ?? 'rom.bin',
      size: (map['size'] as num?)?.toInt() ?? 0,
    );
  }

  String get formattedSize => TvPusherService.formatSize(size);
  String get platformBadge => TvPusherService.getPlatformBadge(name);
}

/// Service dedicated to pushing ROM files directly from Android phone to Android TV.
/// Supports both Bluetooth OPP (Direct to paired TV) and Local Wi-Fi transfer.
class TvPusherService {
  static final TvPusherService instance = TvPusherService._internal();
  TvPusherService._internal();

  static const MethodChannel _channel = MethodChannel('com.example.ble/gamepad');
  final BleLogger _logger = BleLogger.instance;

  final StreamController<TvPushEvent> _eventController =
      StreamController<TvPushEvent>.broadcast();

  Stream<TvPushEvent> get eventStream => _eventController.stream;

  /// Launches the native Android file picker to select a ROM file.
  /// Automatically copies it into the app's ROMs storage directory.
  Future<RomFileInfo?> pickRomFromDevice() async {
    try {
      _logger.info('TV_PUSHER', 'Opening system file picker for ROM...');
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('pickRomFile');
      if (result != null) {
        final info = RomFileInfo.fromMap(result);
        _logger.info(
          'TV_PUSHER',
          'Selected ROM: ${info.name} (${info.formattedSize}, badge=${info.platformBadge})',
        );
        _eventController.add(TvPushEvent(
          type: TvPushEventType.fileSelected,
          message: 'Selected ${info.name} (${info.formattedSize})',
          fileName: info.name,
          fileSize: info.size,
        ));
        return info;
      }
      return null;
    } on PlatformException catch (e) {
      _logger.error('TV_PUSHER', 'File picker error: ${e.message}');
      return null;
    } catch (e) {
      _logger.error('TV_PUSHER', 'Failed to pick ROM: $e');
      return null;
    }
  }

  /// Sends a ROM file directly to the connected Android TV using native Bluetooth OPP.
  /// Android TV accepts files and saves them to /storage/emulated/0/Download.
  Future<bool> pushViaBluetooth({
    required String filePath,
    String? deviceAddress,
    String? deviceName,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      _eventController.add(const TvPushEvent(
        type: TvPushEventType.transferFailed,
        message: 'File does not exist on phone storage.',
      ));
      return false;
    }

    final fileName = file.uri.pathSegments.last;
    final fileSize = await file.length();
    final target = deviceName ?? 'Android TV';

    _eventController.add(TvPushEvent(
      type: TvPushEventType.transferStarted,
      message: 'Sending $fileName to $target via Bluetooth...',
      fileName: fileName,
      fileSize: fileSize,
      targetDevice: target,
      progress: 0.1,
    ));

    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('pushRomToDevice', {
        'filePath': filePath,
        'deviceAddress': deviceAddress,
        'deviceName': target,
      });

      _logger.info('TV_PUSHER', 'Bluetooth push initiated for $fileName to $target: $res');
      _eventController.add(TvPushEvent(
        type: TvPushEventType.transferCompleted,
        message: 'Bluetooth transfer sent to $target! Check TV prompt to Accept.',
        fileName: fileName,
        fileSize: fileSize,
        targetDevice: target,
        progress: 1.0,
      ));
      return true;
    } on PlatformException catch (e) {
      _logger.error('TV_PUSHER', 'Bluetooth push failed: ${e.message}');
      _eventController.add(TvPushEvent(
        type: TvPushEventType.transferFailed,
        message: 'Bluetooth push failed: ${e.message}',
        fileName: fileName,
        fileSize: fileSize,
        targetDevice: target,
      ));
      return false;
    } catch (e) {
      _logger.error('TV_PUSHER', 'Bluetooth push exception: $e');
      _eventController.add(TvPushEvent(
        type: TvPushEventType.transferFailed,
        message: 'Failed to send file: $e',
        fileName: fileName,
        fileSize: fileSize,
        targetDevice: target,
      ));
      return false;
    }
  }

  /// Sends a ROM file to an Android TV over local Wi-Fi.
  /// Can push to "Send Files to TV" (port 6835) or a generic HTTP/TCP receiver on TV.
  Future<bool> pushViaWifi({
    required String filePath,
    required String tvIp,
    int port = 6835,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      _eventController.add(const TvPushEvent(
        type: TvPushEventType.transferFailed,
        message: 'File does not exist on phone storage.',
      ));
      return false;
    }

    final fileName = file.uri.pathSegments.last;
    final totalBytes = await file.length();

    _eventController.add(TvPushEvent(
      type: TvPushEventType.transferStarted,
      message: 'Connecting to TV at $tvIp:$port...',
      fileName: fileName,
      fileSize: totalBytes,
      progress: 0.05,
    ));

    Socket? socket;
    try {
      socket = await Socket.connect(tvIp, port, timeout: const Duration(seconds: 5));
      _logger.info('TV_PUSHER', 'Connected to TV Wi-Fi receiver at $tvIp:$port');

      final reader = file.openRead();
      int bytesSent = 0;

      await for (final chunk in reader) {
        socket.add(chunk);
        bytesSent += chunk.length;
        final progress = totalBytes > 0 ? (bytesSent / totalBytes).clamp(0.0, 1.0) : 1.0;
        _eventController.add(TvPushEvent(
          type: TvPushEventType.transferProgress,
          message: 'Sending ${formatSize(bytesSent)} / ${formatSize(totalBytes)}',
          fileName: fileName,
          fileSize: totalBytes,
          progress: progress,
        ));
      }

      await socket.flush();
      await socket.close();

      _eventController.add(TvPushEvent(
        type: TvPushEventType.transferCompleted,
        message: 'Successfully pushed $fileName to TV over Wi-Fi!',
        fileName: fileName,
        fileSize: totalBytes,
        progress: 1.0,
      ));
      return true;
    } catch (e) {
      _logger.warn('TV_PUSHER', 'Wi-Fi push to $tvIp:$port failed: $e');
      _eventController.add(TvPushEvent(
        type: TvPushEventType.transferFailed,
        message: 'Wi-Fi push to TV ($tvIp:$port) failed: $e',
        fileName: fileName,
        fileSize: totalBytes,
      ));
      return false;
    } finally {
      socket?.destroy();
    }
  }

  /// Lists all stored ROMs in the app's local ROM directory.
  Future<List<RomFileInfo>> listStoredRoms() async {
    try {
      final dirPath = await RomServer.instance.getOrInitRomsDirectory();
      final dir = Directory(dirPath);
      if (!await dir.exists()) return [];

      final list = <RomFileInfo>[];
      await for (final entity in dir.list()) {
        if (entity is File) {
          final size = await entity.length();
          final name = entity.uri.pathSegments.last;
          list.add(RomFileInfo(path: entity.path, name: name, size: size));
        }
      }
      list.sort((a, b) => b.name.compareTo(a.name));
      return list;
    } catch (e) {
      _logger.error('TV_PUSHER', 'Failed to list stored ROMs: $e');
      return [];
    }
  }

  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String getPlatformBadge(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.nes') || lower.endsWith('.fds')) return 'NES';
    if (lower.endsWith('.sfc') || lower.endsWith('.smc')) return 'SNES';
    if (lower.endsWith('.gba')) return 'GBA';
    if (lower.endsWith('.gb') || lower.endsWith('.gbc')) return 'GAME BOY';
    if (lower.endsWith('.n64') || lower.endsWith('.z64')) return 'N64';
    if (lower.endsWith('.md') || lower.endsWith('.gen') || lower.endsWith('.smd')) return 'GENESIS';
    if (lower.endsWith('.iso') || lower.endsWith('.cso') || lower.endsWith('.pbp')) return 'PSP/PSX';
    if (lower.endsWith('.bin') || lower.endsWith('.cue')) return 'PS1/ARCADE';
    if (lower.endsWith('.nds')) return 'NDS';
    if (lower.endsWith('.zip') || lower.endsWith('.7z')) return 'ARCHIVE';
    return 'ROM';
  }
}
