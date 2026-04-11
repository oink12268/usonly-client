import 'package:flutter/material.dart';
import '../google_calendar_service.dart';
import '../utils/date_formatter.dart';
import '../utils/korean_holidays.dart';

class _EventBar {
  final GoogleCalEvent event;
  final int startCol;
  final int endCol;
  final bool capLeft;
  final bool capRight;

  _EventBar({
    required this.event,
    required this.startCol,
    required this.endCol,
    required this.capLeft,
    required this.capRight,
  });
}

class CalendarGrid extends StatelessWidget {
  final DateTime focusedMonth;
  final DateTime? selectedDate;
  final List<dynamic> schedules;
  final List<dynamic> anniversaries;
  final List<GoogleCalEvent> googleEvents;
  final void Function(DateTime) onDateSelected;
  final VoidCallback onPrevMonth;
  final VoidCallback onNextMonth;
  final VoidCallback onYearMonthPicker;

  const CalendarGrid({
    super.key,
    required this.focusedMonth,
    required this.selectedDate,
    required this.schedules,
    required this.anniversaries,
    required this.googleEvents,
    required this.onDateSelected,
    required this.onPrevMonth,
    required this.onNextMonth,
    required this.onYearMonthPicker,
  });

  // ─── Helpers ─────────────────────────────────────────────────────────────

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

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

  bool _hasSchedule(DateTime day) {
    final dayStr = _toDateStr(day);
    return schedules.any((s) => s['date'] == dayStr);
  }

  bool _hasAnniversary(DateTime day) {
    return anniversaries.any((a) {
      final d = _anniversaryDateInMonth(a);
      return d != null && d.day == day.day;
    });
  }

  List<GoogleCalEvent> _googleEventsForDate(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return googleEvents.where((e) => !e.start.isAfter(d) && !e.end.isBefore(d)).toList();
  }

  List<_EventBar> _getBarsForWeek(List<DateTime?> weekDays, List<GoogleCalEvent> events) {
    final weekFirst = weekDays.firstWhere((d) => d != null);
    final weekLast = weekDays.lastWhere((d) => d != null);
    if (weekFirst == null || weekLast == null) return [];

    final bars = <_EventBar>[];
    for (final event in events) {
      if (!event.isMultiDay) continue;
      if (event.start.isAfter(weekLast) || event.end.isBefore(weekFirst)) continue;

      final clippedStart = event.start.isBefore(weekFirst) ? weekFirst : event.start;
      final clippedEnd = event.end.isAfter(weekLast) ? weekLast : event.end;

      bars.add(_EventBar(
        event: event,
        startCol: clippedStart.weekday % 7,
        endCol: clippedEnd.weekday % 7,
        capLeft: !event.start.isBefore(weekFirst),
        capRight: !event.end.isAfter(weekLast),
      ));
    }
    return bars;
  }

  List<List<_EventBar>> _assignLanes(List<_EventBar> bars) {
    bars.sort((a, b) => a.startCol.compareTo(b.startCol));
    final lanes = <List<_EventBar>>[];

    for (final bar in bars) {
      bool placed = false;
      for (final lane in lanes) {
        final conflict = lane.any((b) => b.endCol >= bar.startCol && b.startCol <= bar.endCol);
        if (!conflict) {
          lane.add(bar);
          placed = true;
          break;
        }
      }
      if (!placed) lanes.add([bar]);
    }
    return lanes;
  }

  // ─── Widgets ─────────────────────────────────────────────────────────────

  Widget _dot(Color color) => Container(
        width: 5,
        height: 5,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );

  Widget _buildEventBarWidget(BuildContext context, _EventBar bar) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.outline,
        borderRadius: BorderRadius.horizontal(
          left: bar.capLeft ? const Radius.circular(4) : Radius.zero,
          right: bar.capRight ? const Radius.circular(4) : Radius.zero,
        ),
      ),
      padding: EdgeInsets.only(
        left: bar.capLeft ? 4 : 0,
        right: bar.capRight ? 4 : 0,
      ),
      child: bar.capLeft
          ? Text(
              bar.event.title,
              style: TextStyle(fontSize: 9, color: Theme.of(context).colorScheme.onInverseSurface),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            )
          : null,
    );
  }

  Widget _buildDateCell(BuildContext context, DateTime date, double width, double height,
      Map<DateTime, String> holidays) {
    final isSelected = selectedDate != null && _isSameDay(date, selectedDate!);
    final isToday = _isSameDay(date, DateTime.now());
    final hasSchedule = _hasSchedule(date);
    final hasAnniversary = _hasAnniversary(date);
    final holidayName = holidays[DateTime(date.year, date.month, date.day)];
    final hasSingleDayGoogle =
        _googleEventsForDate(date).where((e) => !e.isMultiDay).isNotEmpty;

    Color dateColor() {
      if (isSelected) return Theme.of(context).colorScheme.onPrimary;
      if (holidayName != null) return Theme.of(context).colorScheme.onSurfaceVariant;
      if (date.weekday == DateTime.sunday) return Colors.red;
      if (date.weekday == DateTime.saturday) return Colors.blue;
      return Theme.of(context).colorScheme.onSurface;
    }

    return GestureDetector(
      onTap: () => onDateSelected(date),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: isSelected ? Theme.of(context).colorScheme.primary : null,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  "${date.day}",
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                    color: dateColor(),
                  ),
                ),
              ),
            ),
            if (holidayName != null || hasSchedule || hasAnniversary || hasSingleDayGoogle)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (holidayName != null)
                    _dot(isSelected
                        ? Theme.of(context).colorScheme.onPrimary
                        : Theme.of(context).colorScheme.onSurfaceVariant),
                  if (holidayName != null && (hasSchedule || hasAnniversary || hasSingleDayGoogle))
                    const SizedBox(width: 2),
                  if (hasSchedule)
                    _dot(isSelected
                        ? Theme.of(context).colorScheme.onPrimary
                        : Theme.of(context).colorScheme.onSurface),
                  if (hasSchedule && (hasAnniversary || hasSingleDayGoogle)) const SizedBox(width: 2),
                  if (hasAnniversary)
                    _dot(isSelected
                        ? Theme.of(context).colorScheme.onPrimary.withOpacity(0.7)
                        : Theme.of(context).colorScheme.onSurfaceVariant),
                  if (hasAnniversary && hasSingleDayGoogle) const SizedBox(width: 2),
                  if (hasSingleDayGoogle)
                    _dot(isSelected
                        ? Theme.of(context).colorScheme.onPrimary.withOpacity(0.6)
                        : Theme.of(context).colorScheme.outline),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWeekRow(BuildContext context, List<DateTime?> weekDays, double cellWidth,
      Map<DateTime, String> holidays) {
    const dateCellHeight = 42.0;
    const barHeight = 14.0;
    const barSpacing = 2.0;

    final bars = _getBarsForWeek(weekDays, googleEvents);
    final lanes = _assignLanes(bars);
    final barsHeight = lanes.isEmpty ? 0.0 : lanes.length * (barHeight + barSpacing);

    return SizedBox(
      height: dateCellHeight + barsHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Row(
            children: weekDays.map((date) {
              if (date == null) return SizedBox(width: cellWidth, height: dateCellHeight);
              return _buildDateCell(context, date, cellWidth, dateCellHeight, holidays);
            }).toList(),
          ),
          ...lanes.asMap().entries.expand((laneEntry) {
            final laneIdx = laneEntry.key;
            return laneEntry.value.map((bar) {
              final left = bar.startCol * cellWidth + 2;
              final width = (bar.endCol - bar.startCol + 1) * cellWidth - 4;
              final top = dateCellHeight + laneIdx * (barHeight + barSpacing);
              return Positioned(
                left: left,
                top: top,
                width: width,
                height: barHeight,
                child: GestureDetector(
                  onTap: () => onDateSelected(bar.event.start),
                  child: _buildEventBarWidget(context, bar),
                ),
              );
            });
          }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final year = focusedMonth.year;
    final month = focusedMonth.month;
    final firstDay = DateTime(year, month, 1);
    final lastDay = DateTime(year, month + 1, 0);
    final startWeekday = firstDay.weekday % 7;

    final holidays = _buildYearHolidays(year);

    final weeks = <List<DateTime?>>[];
    var currentWeek = List<DateTime?>.filled(7, null);
    int col = startWeekday;

    for (int d = 1; d <= lastDay.day; d++) {
      if (col == 7) {
        weeks.add(List.from(currentWeek));
        currentWeek = List<DateTime?>.filled(7, null);
        col = 0;
      }
      currentWeek[col] = DateTime(year, month, d);
      col++;
    }
    if (currentWeek.any((d) => d != null)) {
      weeks.add(List.from(currentWeek));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cellWidth = constraints.maxWidth / 7;
          return Column(
            children: [
              // 월 네비게이션
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(onPressed: onPrevMonth, icon: const Icon(Icons.chevron_left)),
                  GestureDetector(
                    onTap: onYearMonthPicker,
                    child: Text(
                      "${year}년 ${month}월",
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(onPressed: onNextMonth, icon: const Icon(Icons.chevron_right)),
                ],
              ),
              const SizedBox(height: 8),
              // 요일 헤더
              Row(
                children: ['일', '월', '화', '수', '목', '금', '토']
                    .map((d) => SizedBox(
                          width: cellWidth,
                          child: Center(
                            child: Text(
                              d,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: d == '일'
                                    ? Colors.red
                                    : d == '토'
                                        ? Colors.blue
                                        : Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 4),
              // 주 단위 행
              ...weeks.map((week) => _buildWeekRow(context, week, cellWidth, holidays)),
            ],
          );
        },
      ),
    );
  }
}
