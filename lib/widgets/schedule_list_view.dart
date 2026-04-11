import 'package:flutter/material.dart';
import '../google_calendar_service.dart';
import '../utils/date_formatter.dart';
import '../utils/korean_holidays.dart';
import 'confirm_delete_dialog.dart';

class ScheduleListView extends StatelessWidget {
  final DateTime? selectedDate;
  final bool isLoading;
  final DateTime focusedMonth;
  final List<dynamic> schedules;
  final List<dynamic> anniversaries;
  final List<GoogleCalEvent> googleEvents;
  final void Function(int id) onDeleteSchedule;
  final void Function(dynamic schedule) onEditSchedule;
  final void Function(GoogleCalEvent event) onDeleteGoogleEvent;

  const ScheduleListView({
    super.key,
    required this.selectedDate,
    required this.isLoading,
    required this.focusedMonth,
    required this.schedules,
    required this.anniversaries,
    required this.googleEvents,
    required this.onDeleteSchedule,
    required this.onEditSchedule,
    required this.onDeleteGoogleEvent,
  });

  // ─── Helpers ─────────────────────────────────────────────────────────────

  String _toDateStr(DateTime day) => DateFormatter.formatDate(day);

  Map<DateTime, String> _buildYearHolidays(int year) =>
      KoreanHolidays.buildYearHolidays(year);

  DateTime? _anniversaryDateInMonth(dynamic anniversary) {
    final dateStr = anniversary['date'] as String?;
    if (dateStr == null) return null;
    final date = DateTime.parse(dateStr);
    final bool recurring = anniversary['recurring'] == true;
    final int year = focusedMonth.year;
    final int month = focusedMonth.month;

    if (!recurring) {
      if (date.year == year && date.month == month) return date;
      return null;
    }
    if (date.month == month) {
      try {
        return DateTime(year, month, date.day);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  List<dynamic> _schedulesForDate(DateTime day) {
    final dayStr = _toDateStr(day);
    return schedules.where((s) => s['date'] == dayStr).toList();
  }

  List<dynamic> _anniversariesForDate(DateTime day) {
    return anniversaries.where((a) {
      final d = _anniversaryDateInMonth(a);
      return d != null && d.day == day.day;
    }).toList();
  }

  List<GoogleCalEvent> _googleEventsForDate(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return googleEvents.where((e) => !e.start.isAfter(d) && !e.end.isBefore(d)).toList();
  }

  // ─── Item Builders ───────────────────────────────────────────────────────

  Widget _buildHolidayItem(BuildContext context, String name) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.flag, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.outline.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text("공휴일",
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }

  Widget _buildAnniversaryItem(BuildContext context, dynamic anniversary) {
    final bool isLunar = anniversary['lunar'] == true;
    final int? lunarMonth = anniversary['lunarMonth'];
    final int? lunarDay = anniversary['lunarDay'];
    final bool recurring = anniversary['recurring'] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.favorite, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      anniversary['title'] ?? "",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (recurring) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.repeat, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ],
                  ],
                ),
                if (isLunar && lunarMonth != null && lunarDay != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    "음력 $lunarMonth월 $lunarDay일",
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.outline.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text("기념일",
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleItem(BuildContext context, dynamic schedule) {
    return Dismissible(
      key: Key(schedule['id'].toString()),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.delete, color: Theme.of(context).colorScheme.onPrimary),
      ),
      confirmDismiss: (_) async => ConfirmDeleteDialog.show(
        context,
        content: "'${schedule['title']}'을(를) 삭제할까요?",
      ),
      onDismissed: (_) => onDeleteSchedule(schedule['id']),
      child: GestureDetector(
        onTap: () => onEditSchedule(schedule),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.event, size: 18, color: Theme.of(context).colorScheme.onSurface),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      schedule['title'] ?? "",
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (schedule['writerNickname'] != null &&
                      schedule['writerNickname'].toString().isNotEmpty)
                    Text(
                      schedule['writerNickname'],
                      style: TextStyle(
                          fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
              if (schedule['memo'] != null && schedule['memo'].toString().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  schedule['memo'],
                  style: TextStyle(
                      fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGoogleEventItem(BuildContext context, GoogleCalEvent event) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.event, size: 18, color: Theme.of(context).colorScheme.onSurface),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                if (event.isMultiDay) ...[
                  const SizedBox(height: 2),
                  Text(
                    '${_toDateStr(event.start)} ~ ${_toDateStr(event.end)}',
                    style: TextStyle(
                        fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Google',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () => onDeleteGoogleEvent(event),
            child: Icon(Icons.delete_outline,
                size: 20, color: Theme.of(context).colorScheme.outline),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (selectedDate == null) {
      return const Center(child: Text("날짜를 선택해주세요"));
    }

    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final daySchedules = _schedulesForDate(selectedDate!);
    final dayAnniversaries = _anniversariesForDate(selectedDate!);
    final dayGoogleEvents = _googleEventsForDate(selectedDate!);
    final dayHoliday = _buildYearHolidays(selectedDate!.year)[
        DateTime(selectedDate!.year, selectedDate!.month, selectedDate!.day)];

    if (daySchedules.isEmpty &&
        dayAnniversaries.isEmpty &&
        dayGoogleEvents.isEmpty &&
        dayHoliday == null) {
      return Center(
        child: Text(
          "${selectedDate!.month}월 ${selectedDate!.day}일 일정이 없습니다",
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (dayHoliday != null) _buildHolidayItem(context, dayHoliday),
        ...dayAnniversaries.map((a) => _buildAnniversaryItem(context, a)),
        ...daySchedules.map((s) => _buildScheduleItem(context, s)),
        ...dayGoogleEvents.map((e) => _buildGoogleEventItem(context, e)),
      ],
    );
  }
}
