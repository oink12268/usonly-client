import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'debug_log_service.dart';

class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  LogLevel? _filter; // null = 전체

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Logs'),
        actions: [
          // 필터 버튼
          PopupMenuButton<LogLevel?>(
            icon: const Icon(Icons.filter_list),
            onSelected: (v) => setState(() => _filter = v),
            itemBuilder: (_) => [
              const PopupMenuItem(value: null, child: Text('전체')),
              const PopupMenuItem(value: LogLevel.info, child: Text('INFO')),
              const PopupMenuItem(value: LogLevel.warn, child: Text('WARN')),
              const PopupMenuItem(value: LogLevel.error, child: Text('ERROR')),
            ],
          ),
          // 복사 버튼
          ValueListenableBuilder(
            valueListenable: appLog.logs,
            builder: (_, logs, __) => IconButton(
              icon: const Icon(Icons.copy),
              tooltip: '전체 복사',
              onPressed: () {
                final text = logs.map((e) => '[${e.timeLabel}][${e.levelLabel}] ${e.message}').join('\n');
                Clipboard.setData(ClipboardData(text: text));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('로그가 클립보드에 복사됐습니다.')),
                );
              },
            ),
          ),
          // 초기화 버튼
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '로그 지우기',
            onPressed: () {
              appLog.clear();
            },
          ),
        ],
      ),
      body: ValueListenableBuilder<List<LogEntry>>(
        valueListenable: appLog.logs,
        builder: (context, logs, _) {
          final filtered = _filter == null ? logs : logs.where((e) => e.level == _filter).toList();

          if (filtered.isEmpty) {
            return const Center(child: Text('로그 없음', style: TextStyle(color: Colors.grey)));
          }

          return ListView.builder(
            reverse: true, // 최신 로그가 맨 위
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final entry = filtered[filtered.length - 1 - index];
              final color = switch (entry.level) {
                LogLevel.error => Colors.red.shade300,
                LogLevel.warn => Colors.orange.shade300,
                LogLevel.info => Colors.grey,
              };
              return InkWell(
                onLongPress: () {
                  Clipboard.setData(ClipboardData(text: entry.message));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('복사됨')),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.timeLabel,
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500, fontFamily: 'monospace'),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          entry.levelLabel,
                          style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          entry.message,
                          style: TextStyle(fontSize: 12, color: color, fontFamily: 'monospace'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
