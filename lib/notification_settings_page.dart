import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'api_client.dart';
import 'api_endpoints.dart';

class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() => _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  bool _calendarEnabled = true;
  bool _chatEnabled = true;
  bool _anniversaryEnabled = true;
  int _calendarReminderHour = 22;
  bool _loading = true;

  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await ApiClient.get(Uri.parse(ApiEndpoints.notificationSettings));
      if (res.statusCode == 200 && mounted) {
        final data = (ApiClient.decodeBody(res) as Map<String, dynamic>)['data'] as Map<String, dynamic>;
        setState(() {
          _calendarEnabled = data['calendarEnabled'] as bool? ?? true;
          _chatEnabled = data['chatEnabled'] as bool? ?? true;
          _anniversaryEnabled = data['anniversaryEnabled'] as bool? ?? true;
          _calendarReminderHour = (data['calendarReminderHour'] as num?)?.toInt() ?? 22;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _autoSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _persist);
  }

  Future<void> _persist() async {
    try {
      await ApiClient.put(
        Uri.parse(ApiEndpoints.notificationSettings),
        body: jsonEncode({
          'calendarEnabled': _calendarEnabled,
          'chatEnabled': _chatEnabled,
          'anniversaryEnabled': _anniversaryEnabled,
          'calendarReminderHour': _calendarReminderHour,
        }),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('저장 실패. 다시 시도해주세요')),
        );
      }
    }
  }

  Future<void> _pickHour() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SizedBox(
        height: 300,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('알림 시각', style: Theme.of(ctx).textTheme.titleMedium),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: 24,
                itemBuilder: (_, h) {
                  final label = '${h < 12 ? '오전' : '오후'} ${h == 0 ? 12 : h > 12 ? h - 12 : h}시';
                  return ListTile(
                    title: Text(label),
                    trailing: h == _calendarReminderHour
                        ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary)
                        : null,
                    onTap: () => Navigator.pop(ctx, h),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (selected != null && selected != _calendarReminderHour) {
      setState(() => _calendarReminderHour = selected);
      _autoSave();
    }
  }

  String _formatHour(int h) {
    final period = h < 12 ? '오전' : '오후';
    final display = h == 0 ? 12 : h > 12 ? h - 12 : h;
    return '$period $display시';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('알림 설정')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const _SectionHeader(title: '알림 켜기/끄기'),
                SwitchListTile(
                  secondary: const Icon(Icons.calendar_today_outlined),
                  title: const Text('캘린더 알림'),
                  subtitle: const Text('다음날 일정을 미리 알려줘요'),
                  value: _calendarEnabled,
                  activeColor: Theme.of(context).colorScheme.primary,
                  onChanged: (v) {
                    setState(() => _calendarEnabled = v);
                    _autoSave();
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.chat_bubble_outline),
                  title: const Text('채팅 알림'),
                  subtitle: const Text('새 메시지가 오면 알려줘요'),
                  value: _chatEnabled,
                  activeColor: Theme.of(context).colorScheme.primary,
                  onChanged: (v) {
                    setState(() => _chatEnabled = v);
                    _autoSave();
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.favorite_outline),
                  title: const Text('디데이 알림'),
                  subtitle: const Text('기념일 D-7, D-1에 알려줘요'),
                  value: _anniversaryEnabled,
                  activeColor: Theme.of(context).colorScheme.primary,
                  onChanged: (v) {
                    setState(() => _anniversaryEnabled = v);
                    _autoSave();
                  },
                ),
                const Divider(height: 32),
                const _SectionHeader(title: '캘린더 알림 시각'),
                ListTile(
                  leading: const Icon(Icons.access_time_outlined),
                  title: const Text('알림 시각'),
                  subtitle: const Text('매일 이 시각에 다음날 일정을 알려줘요'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatHour(_calendarReminderHour),
                        style: TextStyle(
                          color: _calendarEnabled
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  enabled: _calendarEnabled,
                  onTap: _calendarEnabled ? _pickHour : null,
                ),
              ],
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
