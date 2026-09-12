import 'dart:async';
import '../models/log_entry.dart';

class BleLogger {
  BleLogger._();
  static final BleLogger instance = BleLogger._();

  static const int maxEntries = 300;
  final List<LogEntry> _history = [];
  final StreamController<LogEntry> _streamController = StreamController<LogEntry>.broadcast();

  List<LogEntry> get history => List.unmodifiable(_history);
  Stream<LogEntry> get stream => _streamController.stream;

  void addEntry(LogEntry entry) {
    if (_history.length >= maxEntries) {
      _history.removeAt(0);
    }
    _history.add(entry);
    _streamController.add(entry);
    print('[${entry.level}] [${entry.tag}] ${entry.message}');
  }

  void info(String tag, String message) {
    addEntry(LogEntry(
      timestamp: DateTime.now(),
      formattedTime: _currentTime(),
      level: 'INFO',
      tag: tag,
      message: message,
    ));
  }

  void warn(String tag, String message) {
    addEntry(LogEntry(
      timestamp: DateTime.now(),
      formattedTime: _currentTime(),
      level: 'WARN',
      tag: tag,
      message: message,
    ));
  }

  void error(String tag, String message) {
    addEntry(LogEntry(
      timestamp: DateTime.now(),
      formattedTime: _currentTime(),
      level: 'ERROR',
      tag: tag,
      message: message,
    ));
  }

  void debug(String tag, String message) {
    addEntry(LogEntry(
      timestamp: DateTime.now(),
      formattedTime: _currentTime(),
      level: 'DEBUG',
      tag: tag,
      message: message,
    ));
  }

  void clear() {
    _history.clear();
    info('LOGGER', 'Logs cleared.');
  }

  static String _currentTime() {
    final dt = DateTime.now();
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final ms = dt.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}
