import 'package:flutter/foundation.dart';

enum LogLevel { info, warn, error }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String message;

  LogEntry(this.level, this.message) : time = DateTime.now();

  String get levelLabel => switch (level) {
        LogLevel.info => 'INFO',
        LogLevel.warn => 'WARN',
        LogLevel.error => 'ERROR',
      };

  String get timeLabel {
    final t = time;
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }
}

class DebugLogService {
  DebugLogService._();
  static final DebugLogService instance = DebugLogService._();

  final ValueNotifier<List<LogEntry>> logs = ValueNotifier([]);

  void _add(LogLevel level, String message) {
    debugPrint('[${level.name.toUpperCase()}] $message');
    final next = [...logs.value, LogEntry(level, message)];
    logs.value = next.length > 300 ? next.sublist(next.length - 300) : next;
  }

  void info(String message) => _add(LogLevel.info, message);
  void warn(String message) => _add(LogLevel.warn, message);
  void error(String message) => _add(LogLevel.error, message);
  void clear() => logs.value = [];
}

final appLog = DebugLogService.instance;
