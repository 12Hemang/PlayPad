import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import '../hid/ble_logger.dart';

class RomFileItem {
  final String name;
  final int size;
  final DateTime modified;
  final String extension;

  RomFileItem({
    required this.name,
    required this.size,
    required this.modified,
    required this.extension,
  });

  Map<String, dynamic> toMap() => {
        'name': name,
        'size': size,
        'modified': modified.millisecondsSinceEpoch,
        'extension': extension,
      };
}

enum RomServerEventType {
  started,
  stopped,
  fileUploaded,
  fileDeleted,
  error,
}

class RomServerEvent {
  final RomServerEventType type;
  final String message;
  final String? fileName;
  final int? fileSize;

  RomServerEvent({
    required this.type,
    required this.message,
    this.fileName,
    this.fileSize,
  });
}

/// Embedded HTTP Server for uploading and managing ROM files over local Wi-Fi.
class RomServer {
  static final RomServer instance = RomServer._internal();
  RomServer._internal();

  static const MethodChannel _channel = MethodChannel('com.example.ble/gamepad');

  HttpServer? _server;
  String? _romsDirectoryPath;
  String? _cachedLocalIp;
  int _port = 8080;

  final StreamController<RomServerEvent> _eventController =
      StreamController<RomServerEvent>.broadcast();

  Stream<RomServerEvent> get events => _eventController.stream;
  bool get isRunning => _server != null;
  int get port => _port;
  String? get localIp => _cachedLocalIp;
  String? get romsDirectory => _romsDirectoryPath;

  String get serverUrl => 'http://${_cachedLocalIp ?? "127.0.0.1"}:$_port';

  /// Resolves the storage directory for ROM files.
  Future<String> getOrInitRomsDirectory() async {
    if (_romsDirectoryPath != null) return _romsDirectoryPath!;

    try {
      final nativePath = await _channel.invokeMethod<String>('getRomsDirectory');
      if (nativePath != null && nativePath.isNotEmpty) {
        _romsDirectoryPath = nativePath;
        final dir = Directory(nativePath);
        if (!await dir.exists()) await dir.create(recursive: true);
        return _romsDirectoryPath!;
      }
    } catch (_) {}

    // Fallback to system temp / local directory if running outside Android
    final fallback = Directory('${Directory.systemTemp.path}/roms');
    if (!await fallback.exists()) await fallback.create(recursive: true);
    _romsDirectoryPath = fallback.path;
    return _romsDirectoryPath!;
  }

  /// Discovers the device's local Wi-Fi / LAN IP address.
  Future<String?> getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      // 1. Prefer standard private LAN subnets (192.168.x, 10.x, 172.16-31.x)
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) {
            final ip = addr.address;
            if (ip.startsWith('192.168.') ||
                ip.startsWith('10.') ||
                (ip.startsWith('172.') && _is172Private(ip))) {
              _cachedLocalIp = ip;
              return ip;
            }
          }
        }
      }

      // 2. Fallback to any non-loopback IPv4
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) {
            _cachedLocalIp = addr.address;
            return addr.address;
          }
        }
      }
    } catch (e) {
      BleLogger.instance.error('ROM_SERVER', 'Error finding IP: $e');
    }

    _cachedLocalIp = '127.0.0.1';
    return _cachedLocalIp;
  }

  bool _is172Private(String ip) {
    final parts = ip.split('.');
    if (parts.length >= 2) {
      final second = int.tryParse(parts[1]) ?? 0;
      return second >= 16 && second <= 31;
    }
    return false;
  }

  /// Starts the embedded HTTP server on local port (default 8080).
  Future<bool> start({int initialPort = 8080}) async {
    if (_server != null) return true;

    await getOrInitRomsDirectory();
    await getLocalIpAddress();

    int targetPort = initialPort;
    HttpServer? boundServer;

    // Try target port, incrementing up to 5 times if occupied
    for (int i = 0; i < 5; i++) {
      try {
        boundServer = await HttpServer.bind(
          InternetAddress.anyIPv4,
          targetPort,
          shared: true,
        );
        _port = targetPort;
        break;
      } catch (e) {
        targetPort++;
      }
    }

    if (boundServer == null) {
      _eventController.add(RomServerEvent(
        type: RomServerEventType.error,
        message: 'Could not bind server to port $initialPort-${targetPort - 1}',
      ));
      return false;
    }

    _server = boundServer;
    _server!.listen(_handleRequest, onError: (e) {
      BleLogger.instance.error('ROM_SERVER', 'Server error: $e');
    });

    BleLogger.instance.info('ROM_SERVER', 'Started at $serverUrl (Path: $_romsDirectoryPath)');
    _eventController.add(RomServerEvent(
      type: RomServerEventType.started,
      message: 'Server started at $serverUrl',
    ));
    return true;
  }

  /// Stops the embedded HTTP server.
  Future<void> stop() async {
    if (_server == null) return;
    try {
      await _server!.close(force: true);
    } catch (_) {}
    _server = null;
    BleLogger.instance.info('ROM_SERVER', 'Server stopped');
    _eventController.add(RomServerEvent(
      type: RomServerEventType.stopped,
      message: 'Server stopped',
    ));
  }

  /// Dispatches incoming HTTP requests.
  Future<void> _handleRequest(HttpRequest request) async {
    // Add CORS headers for LAN clients
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
    request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    final path = request.uri.path;

    try {
      if (path == '/' || path == '/index.html') {
        await _serveWebManagerHtml(request);
      } else if (path == '/api/files' && request.method == 'GET') {
        await _handleListFiles(request);
      } else if (path == '/api/upload' && request.method == 'POST') {
        await _handleFileUpload(request);
      } else if (path == '/api/download' && request.method == 'GET') {
        await _handleFileDownload(request);
      } else if (path == '/api/delete' && request.method == 'DELETE') {
        await _handleFileDelete(request);
      } else if (path == '/api/info' && request.method == 'GET') {
        await _handleServerInfo(request);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('404 Not Found');
        await request.response.close();
      }
    } catch (e) {
      BleLogger.instance.error('ROM_SERVER', 'Request handler error: $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(jsonEncode({'error': e.toString()}));
        await request.response.close();
      } catch (_) {}
    }
  }

  /// Returns list of ROM files.
  Future<void> _handleListFiles(HttpRequest request) async {
    final dirPath = await getOrInitRomsDirectory();
    final dir = Directory(dirPath);
    final items = <RomFileItem>[];

    if (await dir.exists()) {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          final stat = await entity.stat();
          final fileName = entity.uri.pathSegments.last;
          final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
          items.add(RomFileItem(
            name: fileName,
            size: stat.size,
            modified: stat.modified,
            extension: ext,
          ));
        }
      }
    }

    // Sort by newest first
    items.sort((a, b) => b.modified.compareTo(a.modified));

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'files': items.map((e) => e.toMap()).toList(),
      'directory': dirPath,
    }));
    await request.response.close();
  }

  /// Handles direct file streaming upload.
  Future<void> _handleFileUpload(HttpRequest request) async {
    final rawName = request.uri.queryParameters['filename'];
    if (rawName == null || rawName.trim().isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write(jsonEncode({'error': 'Missing filename parameter'}));
      await request.response.close();
      return;
    }

    // Sanitize filename to prevent directory traversal
    final fileName = rawName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final dirPath = await getOrInitRomsDirectory();
    final targetFile = File('$dirPath/$fileName');

    final sink = targetFile.openWrite();
    await for (final chunk in request) {
      sink.add(chunk);
    }
    await sink.flush();
    await sink.close();

    final fileSize = await targetFile.length();
    BleLogger.instance.info('ROM_SERVER', 'Uploaded: $fileName (${_formatSize(fileSize)})');

    _eventController.add(RomServerEvent(
      type: RomServerEventType.fileUploaded,
      message: 'Uploaded $fileName (${_formatSize(fileSize)})',
      fileName: fileName,
      fileSize: fileSize,
    ));

    request.response.headers.contentType = ContentType.json;
    request.response.statusCode = HttpStatus.ok;
    request.response.write(jsonEncode({
      'success': true,
      'filename': fileName,
      'size': fileSize,
    }));
    await request.response.close();
  }

  /// Downloads a ROM file.
  Future<void> _handleFileDownload(HttpRequest request) async {
    final fileName = request.uri.queryParameters['file'];
    if (fileName == null || fileName.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final sanitized = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final dirPath = await getOrInitRomsDirectory();
    final file = File('$dirPath/$sanitized');

    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    request.response.headers.add(
      'Content-Disposition',
      'attachment; filename="$sanitized"',
    );
    request.response.headers.contentType = ContentType.binary;
    await request.response.addStream(file.openRead());
    await request.response.close();
  }

  /// Deletes a ROM file.
  Future<void> _handleFileDelete(HttpRequest request) async {
    final fileName = request.uri.queryParameters['file'];
    if (fileName == null || fileName.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final sanitized = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final dirPath = await getOrInitRomsDirectory();
    final file = File('$dirPath/$sanitized');

    if (await file.exists()) {
      await file.delete();
      BleLogger.instance.info('ROM_SERVER', 'Deleted: $sanitized');
      _eventController.add(RomServerEvent(
        type: RomServerEventType.fileDeleted,
        message: 'Deleted $sanitized',
        fileName: sanitized,
      ));
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'success': true}));
    } else {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(jsonEncode({'error': 'File not found'}));
    }
    await request.response.close();
  }

  /// Returns server info & stats.
  Future<void> _handleServerInfo(HttpRequest request) async {
    final dirPath = await getOrInitRomsDirectory();
    final dir = Directory(dirPath);
    int count = 0;
    int totalBytes = 0;

    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File) {
          count++;
          totalBytes += (await entity.stat()).size;
        }
      }
    }

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'ip': _cachedLocalIp,
      'port': _port,
      'directory': dirPath,
      'romCount': count,
      'totalBytes': totalBytes,
      'totalSizeFormatted': _formatSize(totalBytes),
    }));
    await request.response.close();
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Serves the embedded HTML5 Web File Manager.
  Future<void> _serveWebManagerHtml(HttpRequest request) async {
    request.response.headers.contentType = ContentType.html;
    request.response.write(_webManagerHtml);
    await request.response.close();
  }

  static const String _webManagerHtml = '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ROMs File Manager - Retro Gamepad</title>
  <style>
    :root {
      --bg: #0F0F14;
      --card-bg: #1A1A24;
      --card-border: #2A2A38;
      --accent: #00E676;
      --accent-glow: rgba(0, 230, 118, 0.25);
      --text: #FFFFFF;
      --text-muted: #9E9EA8;
      --danger: #FF5252;
      --blue: #42A5F5;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    body { background: var(--bg); color: var(--text); padding: 16px; min-height: 100vh; }
    .container { max-width: 860px; margin: 0 auto; }
    header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 20px; padding-bottom: 14px; border-bottom: 1px solid var(--card-border); flex-wrap: wrap; gap: 12px; }
    .title-group { display: flex; align-items: center; gap: 12px; }
    .logo { font-size: 28px; }
    h1 { font-size: 20px; font-weight: 700; color: #FFF; }
    .badge { background: rgba(0,230,118,0.15); color: var(--accent); border: 1px solid var(--accent); font-size: 11px; padding: 3px 8px; border-radius: 12px; font-weight: 600; }
    .path-banner { background: var(--card-bg); border: 1px solid var(--card-border); padding: 10px 14px; border-radius: 8px; font-size: 12px; color: var(--text-muted); margin-bottom: 20px; word-break: break-all; }
    .dropzone { border: 2px dashed #3D3D52; background: var(--card-bg); border-radius: 12px; padding: 32px 16px; text-align: center; cursor: pointer; transition: all 0.2s; margin-bottom: 20px; }
    .dropzone:hover, .dropzone.dragover { border-color: var(--accent); background: rgba(0,230,118,0.04); box-shadow: 0 0 16px var(--accent-glow); }
    .dropzone-icon { font-size: 42px; margin-bottom: 8px; }
    .dropzone p { font-size: 14px; color: var(--text); font-weight: 500; }
    .dropzone span { font-size: 11px; color: var(--text-muted); display: block; margin-top: 4px; }
    .btn { background: var(--accent); color: #000; border: none; font-weight: 700; padding: 9px 18px; border-radius: 8px; cursor: pointer; font-size: 13px; display: inline-flex; align-items: center; gap: 6px; transition: opacity 0.2s; margin-top: 12px; }
    .btn:hover { opacity: 0.9; }
    .progress-card { background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 8px; padding: 14px; margin-bottom: 20px; display: none; }
    .progress-bar-bg { background: #262636; height: 8px; border-radius: 4px; overflow: hidden; margin: 8px 0; }
    .progress-bar { background: var(--accent); height: 100%; width: 0%; transition: width 0.15s; }
    .progress-text { display: flex; justify-content: space-between; font-size: 12px; color: var(--text-muted); }
    .files-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
    .files-count { font-size: 14px; font-weight: 600; }
    .search-input { background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 6px; padding: 6px 12px; color: #FFF; font-size: 12px; width: 160px; outline: none; }
    .search-input:focus { border-color: var(--accent); }
    .file-list { background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 12px; overflow: hidden; }
    .file-item { display: flex; align-items: center; justify-content: space-between; padding: 12px 16px; border-bottom: 1px solid var(--card-border); transition: background 0.15s; }
    .file-item:last-child { border-bottom: none; }
    .file-item:hover { background: rgba(255,255,255,0.02); }
    .file-info { display: flex; align-items: center; gap: 12px; min-width: 0; flex: 1; }
    .file-icon { font-size: 20px; }
    .file-details { min-width: 0; flex: 1; }
    .file-name { font-size: 13px; font-weight: 600; color: #FFF; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .file-meta { font-size: 11px; color: var(--text-muted); margin-top: 2px; }
    .file-actions { display: flex; gap: 8px; margin-left: 12px; }
    .action-btn { background: #262636; border: 1px solid #36364A; color: var(--text); border-radius: 6px; padding: 5px 10px; font-size: 11px; font-weight: 600; cursor: pointer; text-decoration: none; display: inline-flex; align-items: center; gap: 4px; }
    .action-btn:hover { background: #323246; }
    .action-btn.del { color: var(--danger); border-color: rgba(255,82,82,0.3); }
    .action-btn.del:hover { background: rgba(255,82,82,0.15); }
    .empty-state { text-align: center; padding: 40px 16px; color: var(--text-muted); font-size: 13px; }
    #fileInput { display: none; }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div class="title-group">
        <div class="logo">🎮</div>
        <div>
          <h1>ROMs File Manager</h1>
          <span style="font-size:11px; color:var(--text-muted);">Transfer ROMs directly to your TV or device</span>
        </div>
      </div>
      <div class="badge" id="statusBadge">ONLINE</div>
    </header>

    <div class="path-banner">
      📁 <b>Storage Path:</b> <span id="storagePath">Loading...</span>
    </div>

    <!-- Drag & Drop Upload Card -->
    <div class="dropzone" id="dropzone" onclick="document.getElementById('fileInput').click()">
      <div class="dropzone-icon">📥</div>
      <p>Drop ROM files here or click to browse</p>
      <span>Supported: .nes, .sfc, .smc, .gba, .gbc, .gb, .bin, .md, .zip, .z64, .iso</span>
      <button class="btn" type="button" onclick="event.stopPropagation(); document.getElementById('fileInput').click()">Select Files to Upload</button>
      <input type="file" id="fileInput" multiple>
    </div>

    <!-- Upload Progress Card -->
    <div class="progress-card" id="progressCard">
      <div style="font-size:13px; font-weight:600;" id="uploadingFileName">Uploading...</div>
      <div class="progress-bar-bg">
        <div class="progress-bar" id="progressBar"></div>
      </div>
      <div class="progress-text">
        <span id="uploadPercent">0%</span>
        <span id="uploadDetails">Uploading to device...</span>
      </div>
    </div>

    <!-- File List Section -->
    <div class="files-header">
      <div class="files-count" id="filesCountHeader">ROMs on Device (0)</div>
      <input type="text" class="search-input" id="searchInput" placeholder="Search ROMs..." oninput="filterFiles()">
    </div>

    <div class="file-list" id="fileList">
      <div class="empty-state">Loading ROM files...</div>
    </div>
  </div>

  <script>
    let allFiles = [];

    // Drag & Drop event listeners
    const dropzone = document.getElementById('dropzone');
    const fileInput = document.getElementById('fileInput');

    ['dragenter', 'dragover'].forEach(e => {
      dropzone.addEventListener(e, (evt) => {
        evt.preventDefault();
        dropzone.classList.add('dragover');
      });
    });

    ['dragleave', 'drop'].forEach(e => {
      dropzone.addEventListener(e, (evt) => {
        evt.preventDefault();
        dropzone.classList.remove('dragover');
      });
    });

    dropzone.addEventListener('drop', (evt) => {
      const files = evt.dataTransfer.files;
      if (files.length) uploadFilesSequentially(Array.from(files));
    });

    fileInput.addEventListener('change', (evt) => {
      const files = evt.target.files;
      if (files.length) uploadFilesSequentially(Array.from(files));
      fileInput.value = '';
    });

    async function uploadFilesSequentially(files) {
      const card = document.getElementById('progressCard');
      const bar = document.getElementById('progressBar');
      const nameEl = document.getElementById('uploadingFileName');
      const percentEl = document.getElementById('uploadPercent');
      card.style.display = 'block';

      for (let i = 0; i < files.length; i++) {
        const file = files[i];
        nameEl.innerText = `[\${i + 1}/\${files.length}] Uploading \${file.name}...`;

        await new Promise((resolve) => {
          const xhr = new XMLHttpRequest();
          xhr.open('POST', `/api/upload?filename=\${encodeURIComponent(file.name)}`);

          xhr.upload.onprogress = (e) => {
            if (e.lengthComputable) {
              const p = Math.round((e.loaded / e.total) * 100);
              bar.style.width = p + '%';
              percentEl.innerText = p + '%';
            }
          };

          xhr.onload = () => {
            resolve();
          };

          xhr.onerror = () => {
            alert('Upload error for ' + file.name);
            resolve();
          };

          xhr.send(file);
        });
      }

      card.style.display = 'none';
      bar.style.width = '0%';
      loadFiles();
    }

    async function loadFiles() {
      try {
        const res = await fetch('/api/files');
        const data = await res.json();
        document.getElementById('storagePath').innerText = data.directory || '/roms';
        allFiles = data.files || [];
        renderFiles(allFiles);
      } catch (e) {
        document.getElementById('fileList').innerHTML = '<div class="empty-state">Error connecting to device.</div>';
      }
    }

    function renderFiles(files) {
      const listEl = document.getElementById('fileList');
      document.getElementById('filesCountHeader').innerText = `ROMs on Device (\${files.length})`;

      if (!files.length) {
        listEl.innerHTML = '<div class="empty-state">No ROMs uploaded yet. Drag & drop files above to start!</div>';
        return;
      }

      listEl.innerHTML = files.map(f => {
        const sizeStr = formatSize(f.size);
        const dateStr = new Date(f.modified).toLocaleDateString() + ' ' + new Date(f.modified).toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'});
        const icon = getExtIcon(f.extension);

        return `
          <div class="file-item">
            <div class="file-info">
              <div class="file-icon">\${icon}</div>
              <div class="file-details">
                <div class="file-name" title="\${f.name}">\${f.name}</div>
                <div class="file-meta">\${sizeStr} • \${dateStr}</div>
              </div>
            </div>
            <div class="file-actions">
              <a class="action-btn" href="/api/download?file=\${encodeURIComponent(f.name)}" download>⬇ Download</a>
              <button class="action-btn del" onclick="deleteFile('\${encodeURIComponent(f.name)}')">✕ Delete</button>
            </div>
          </div>
        `;
      }).join('');
    }

    function filterFiles() {
      const q = document.getElementById('searchInput').value.toLowerCase().trim();
      if (!q) {
        renderFiles(allFiles);
        return;
      }
      renderFiles(allFiles.filter(f => f.name.toLowerCase().includes(q)));
    }

    async function deleteFile(encodedName) {
      if (!confirm('Are you sure you want to delete this ROM?')) return;
      try {
        await fetch('/api/delete?file=' + encodedName, { method: 'DELETE' });
        loadFiles();
      } catch (e) {
        alert('Could not delete file.');
      }
    }

    function formatSize(bytes) {
      if (bytes < 1024) return bytes + ' B';
      if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
      return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
    }

    function getExtIcon(ext) {
      const e = (ext || '').toLowerCase();
      if (e === 'nes') return '🕹';
      if (e === 'sfc' || e === 'smc') return '🎮';
      if (e === 'gba' || e === 'gbc' || e === 'gb') return '👾';
      if (e === 'zip') return '📦';
      return '💾';
    }

    // Initial load
    loadFiles();
  </script>
</body>
</html>
''';
}
