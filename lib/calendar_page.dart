import 'package:flutter/material.dart';
import 'dart:convert';
import 'api_config.dart';
import 'api_client.dart';
import 'google_calendar_service.dart';
import 'utils/date_formatter.dart';
import 'utils/korean_holidays.dart';
import 'widgets/confirm_delete_dialog.dart';

// 캘린더 그리드에서 Google 이벤트를 바(bar)로 표시하기 위한 내부 모델
class _EventBar {
  final GoogleCalEvent event;
  final int startCol; // 0=일 ~ 6=토 (주 내 컬럼 인덱스)
  final int endCol;
  final bool capLeft; // 이벤트가 이 주에서 시작 → 왼쪽 둥글게
  final bool capRight; // 이벤트가 이 주에서 종료 → 오른쪽 둥글게

  _EventBar({
    required this.event,
    required this.startCol,
    required this.endCol,
    required this.capLeft,
    required this.capRight,
  });
}

class CalendarPage extends StatefulWidget {
  final int memberId;

  const CalendarPage({super.key, required this.memberId});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  DateTime _focusedMonth = DateTime.now();
  DateTime? _selectedDate;
  List<dynamic> _schedules = [];
  List<dynamic> _anniversaries = [];
  List<GoogleCalEvent> _googleEvents = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime.now();
    _fetchData();
  }

  Future<void> _fetchData() async {
    setState(() => _isLoading = true);
    await Future.wait([
      _fetchSchedules(),
      _fetchAnniversaries(),
      _fetchGoogleEvents(),
    ]);
    setState(() => _isLoading = false);
  }

  Future<void> _fetchSchedules() async {
    try {
      final response = await ApiClient.get(
        Uri.parse(
          '${ApiConfig.baseUrl}/api/schedules'
          '?year=${_focusedMonth.year}&month=${_focusedMonth.month}',
        ),
      );
      if (response.statusCode == 200) {
        setState(() {
          _schedules = jsonDecode(utf8.decode(response.bodyBytes));
        });
      }
    } catch (e) {
      print("일정 로딩 에러: $e");
    }
  }

  Future<void> _fetchAnniversaries() async {
    try {
      final response = await ApiClient.get(
        Uri.parse('${ApiConfig.baseUrl}/api/anniversaries'),
      );
      if (response.statusCode == 200) {
        setState(() {
          _anniversaries = jsonDecode(utf8.decode(response.bodyBytes));
        });
      }
    } catch (e) {
      print("기념일 로딩 에러: $e");
    }
  }

  Future<void> _fetchGoogleEvents() async {
    final events = await GoogleCalendarService().fetchMonthEvents(
      _focusedMonth.year,
      _focusedMonth.month,
    );
    setState(() => _googleEvents = events);
  }

  // ─── 날짜 헬퍼 ───────────────────────────────────────────────────────────

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _hasSchedule(DateTime day) {
    final dayStr = _toDateStr(day);
    return _schedules.any((s) => s['date'] == dayStr);
  }

  DateTime? _anniversaryDateInMonth(dynamic anniversary) {
    final dateStr = anniversary['date'] as String?;
    if (dateStr == null) return null;
    final date = DateTime.parse(dateStr);
    final bool recurring = anniversary['recurring'] == true;
    final int year = _focusedMonth.year;
    final int month = _focusedMonth.month;

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

  bool _hasAnniversary(DateTime day) {
    return _anniversaries.any((a) {
      final d = _anniversaryDateInMonth(a);
      return d != null && d.day == day.day;
    });
  }

  List<dynamic> _anniversariesForDate(DateTime day) {
    return _anniversaries.where((a) {
      final d = _anniversaryDateInMonth(a);
      return d != null && d.day == day.day;
    }).toList();
  }

  List<dynamic> _schedulesForDate(DateTime day) {
    final dayStr = _toDateStr(day);
    return _schedules.where((s) => s['date'] == dayStr).toList();
  }

  /// 선택된 날에 걸치는 Google 이벤트 (단일일 포함)
  List<GoogleCalEvent> _googleEventsForDate(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return _googleEvents.where((e) => !e.start.isAfter(d) && !e.end.isBefore(d)).toList();
  }

  String _toDateStr(DateTime day) => DateFormatter.formatDate(day);

  Map<DateTime, String> _buildYearHolidays(int year) =>
      KoreanHolidays.buildYearHolidays(year);

  // ─── 네비게이션 ───────────────────────────────────────────────────────────

  void _prevMonth() {
    setState(() {
      _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month - 1);
      _selectedDate = null;
    });
    _fetchData();
  }

  void _nextMonth() {
    setState(() {
      _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + 1);
      _selectedDate = null;
    });
    _fetchData();
  }

  void _showYearMonthPicker() {
    int selectedYear = _focusedMonth.year;
    int selectedMonth = _focusedMonth.month;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("연도/월 선택"),
          content: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 200,
                  child: ListWheelScrollView.useDelegate(
                    itemExtent: 40,
                    diameterRatio: 1.5,
                    controller: FixedExtentScrollController(initialItem: selectedYear - 1900),
                    onSelectedItemChanged: (index) {
                      setDialogState(() => selectedYear = 1900 + index);
                    },
                    childDelegate: ListWheelChildBuilderDelegate(
                      childCount: 201,
                      builder: (context, index) {
                        final y = 1900 + index;
                        return Center(
                          child: Text(
                            "$y년",
                            style: TextStyle(
                              fontSize: y == selectedYear ? 18 : 14,
                              fontWeight: y == selectedYear ? FontWeight.bold : FontWeight.normal,
                              color: y == selectedYear ? Theme.of(context).colorScheme.onSurface : Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              Expanded(
                child: SizedBox(
                  height: 200,
                  child: ListWheelScrollView.useDelegate(
                    itemExtent: 40,
                    diameterRatio: 1.5,
                    controller: FixedExtentScrollController(initialItem: selectedMonth - 1),
                    onSelectedItemChanged: (index) {
                      setDialogState(() => selectedMonth = index + 1);
                    },
                    childDelegate: ListWheelChildBuilderDelegate(
                      childCount: 12,
                      builder: (context, index) {
                        final m = index + 1;
                        return Center(
                          child: Text(
                            "$m월",
                            style: TextStyle(
                              fontSize: m == selectedMonth ? 18 : 14,
                              fontWeight: m == selectedMonth ? FontWeight.bold : FontWeight.normal,
                              color: m == selectedMonth ? Theme.of(context).colorScheme.onSurface : Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("취소"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary),
              onPressed: () {
                setState(() {
                  _focusedMonth = DateTime(selectedYear, selectedMonth);
                  _selectedDate = null;
                });
                _fetchData();
                Navigator.pop(context);
              },
              child: Text("확인", style: TextStyle(color: Theme.of(context).colorScheme.onPrimary)),
            ),
          ],
        ),
      ),
    );
  }

  // ─── 일정 CRUD ────────────────────────────────────────────────────────────

  void _showAddScheduleDialog() {
    if (_selectedDate == null) return;

    final titleController = TextEditingController();
    final memoController = TextEditingController();
    bool syncToGoogle = true;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text("${_selectedDate!.month}월 ${_selectedDate!.day}일 일정 추가"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: const InputDecoration(
                  hintText: "일정 제목",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: memoController,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: "메모 (선택)",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Checkbox(
                    value: syncToGoogle,
                    activeColor: Theme.of(context).colorScheme.primary,
                    onChanged: (v) => setDialogState(() => syncToGoogle = v ?? true),
                  ),
                  const Text("Google 캘린더에도 추가", style: TextStyle(fontSize: 13)),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("취소"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary),
              onPressed: () async {
                if (titleController.text.isNotEmpty) {
                  final nav = Navigator.of(context);
                  await _createSchedule(
                    titleController.text,
                    memoController.text,
                    syncToGoogle: syncToGoogle,
                  );
                  nav.pop();
                }
              },
              child: Text("추가", style: TextStyle(color: Theme.of(context).colorScheme.onPrimary)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createSchedule(
    String title,
    String memo, {
    bool syncToGoogle = true,
  }) async {
    final dateStr = _toDateStr(_selectedDate!);
    try {
      final response = await ApiClient.post(
        Uri.parse('${ApiConfig.baseUrl}/api/schedules'),
        body: jsonEncode({'title': title, 'memo': memo, 'date': dateStr}),
      );
      if (response.statusCode == 200) {
        if (syncToGoogle) {
          await GoogleCalendarService().createEvent(title, _selectedDate!, memo: memo);
        }
        await Future.wait([_fetchSchedules(), if (syncToGoogle) _fetchGoogleEvents()]);
      }
    } catch (e) {
      print("일정 추가 에러: $e");
    }
  }

  Future<void> _updateSchedule(int id, String title, String memo, String date) async {
    try {
      final response = await ApiClient.put(
        Uri.parse('${ApiConfig.baseUrl}/api/schedules/$id'),
        body: jsonEncode({'title': title, 'memo': memo, 'date': date}),
      );
      if (response.statusCode == 200) {
        _fetchSchedules();
      }
    } catch (e) {
      print("일정 수정 에러: $e");
    }
  }

  Future<void> _deleteSchedule(int id) async {
    try {
      final response = await ApiClient.delete(
        Uri.parse('${ApiConfig.baseUrl}/api/schedules/$id'),
      );
      if (response.statusCode == 200) {
        _fetchSchedules();
      }
    } catch (e) {
      print("일정 삭제 에러: $e");
    }
  }

  Future<void> _deleteGoogleEvent(GoogleCalEvent event) async {
    final confirmed = await ConfirmDeleteDialog.show(
      context,
      title: 'Google 일정 삭제',
      content: "'${event.title}'을(를) Google 캘린더에서 삭제할까요?",
    );

    if (confirmed) {
      await GoogleCalendarService().deleteEvent(event.id);
      await _fetchGoogleEvents();
    }
  }

  void _showScheduleDetailDialog(dynamic schedule) {
    final titleController = TextEditingController(text: schedule['title'] ?? '');
    final memoController = TextEditingController(text: schedule['memo'] ?? '');
    DateTime selectedDate = DateTime.parse(schedule['date']);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("일정 상세"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: selectedDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2030),
                  );
                  if (picked != null) {
                    setDialogState(() => selectedDate = picked);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).colorScheme.outline),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.calendar_today, size: 16, color: Theme.of(context).colorScheme.onSurface),
                      const SizedBox(width: 8),
                      Text(
                        "${selectedDate.year}년 ${selectedDate.month}월 ${selectedDate.day}일",
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: titleController,
                decoration: const InputDecoration(labelText: "제목", border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: memoController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: "메모",
                  hintText: "메모 없음",
                  border: OutlineInputBorder(),
                ),
              ),
              if (schedule['writerNickname'] != null &&
                  schedule['writerNickname'].toString().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  "작성자: ${schedule['writerNickname']}",
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("취소"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary),
              onPressed: () async {
                if (titleController.text.isNotEmpty) {
                  final nav = Navigator.of(context);
                  await _updateSchedule(
                    schedule['id'],
                    titleController.text,
                    memoController.text,
                    _toDateStr(selectedDate),
                  );
                  nav.pop();
                }
              },
              child: Text("저장", style: TextStyle(color: Theme.of(context).colorScheme.onPrimary)),
            ),
          ],
        ),
      ),
    );
  }

  // ─── 이벤트 바 계산 ──────────────────────────────────────────────────────

  /// 해당 주에 걸치는 다기간 Google 이벤트의 바 목록 반환
  List<_EventBar> _getBarsForWeek(List<DateTime?> weekDays, List<GoogleCalEvent> events) {
    final weekFirst = weekDays.firstWhere((d) => d != null);
    final weekLast = weekDays.lastWhere((d) => d != null);
    if (weekFirst == null || weekLast == null) return [];

    final bars = <_EventBar>[];
    for (final event in events) {
      // 단일일 이벤트는 점(dot)으로 표시하므로 바에서 제외
      if (!event.isMultiDay) continue;
      if (event.start.isAfter(weekLast) || event.end.isBefore(weekFirst)) continue;

      final clippedStart = event.start.isBefore(weekFirst) ? weekFirst : event.start;
      final clippedEnd = event.end.isAfter(weekLast) ? weekLast : event.end;

      bars.add(_EventBar(
        event: event,
        // weekday % 7 → 일=0, 월=1, ..., 토=6
        startCol: clippedStart.weekday % 7,
        endCol: clippedEnd.weekday % 7,
        capLeft: !event.start.isBefore(weekFirst),
        capRight: !event.end.isAfter(weekLast),
      ));
    }
    return bars;
  }

  /// 바들을 레인(행)에 배치 (겹치지 않게)
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

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          GestureDetector(
            onHorizontalDragEnd: (details) {
              if (details.primaryVelocity! < 0) {
                _nextMonth();
              } else if (details.primaryVelocity! > 0) {
                _prevMonth();
              }
            },
            child: _buildCalendar(),
          ),
          const Divider(height: 1),
          Expanded(child: _buildScheduleList()),
        ],
      ),
      floatingActionButton: _selectedDate != null
          ? FloatingActionButton(
              onPressed: _showAddScheduleDialog,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Icon(Icons.add, color: Theme.of(context).colorScheme.onPrimary),
            )
          : null,
    );
  }

  Widget _buildCalendar() {
    final year = _focusedMonth.year;
    final month = _focusedMonth.month;
    final firstDay = DateTime(year, month, 1);
    final lastDay = DateTime(year, month + 1, 0);
    final startWeekday = firstDay.weekday % 7; // 일=0, 월=1 ...

    final holidays = _buildYearHolidays(year);

    // 월을 주 단위로 분리
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
                  IconButton(onPressed: _prevMonth, icon: const Icon(Icons.chevron_left)),
                  GestureDetector(
                    onTap: _showYearMonthPicker,
                    child: Text(
                      "${year}년 ${month}월",
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(onPressed: _nextMonth, icon: const Icon(Icons.chevron_right)),
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
              // 주 단위 행 렌더링
              ...weeks.map((week) => _buildWeekRow(week, cellWidth, holidays)),
            ],
          );
        },
      ),
    );
  }

  /// 한 주의 날짜 셀 + Google 이벤트 바를 Stack으로 렌더링
  Widget _buildWeekRow(
    List<DateTime?> weekDays,
    double cellWidth,
    Map<DateTime, String> holidays,
  ) {
    const dateCellHeight = 42.0;
    const barHeight = 14.0;
    const barSpacing = 2.0;

    final bars = _getBarsForWeek(weekDays, _googleEvents);
    final lanes = _assignLanes(bars);
    final barsHeight = lanes.isEmpty ? 0.0 : lanes.length * (barHeight + barSpacing);

    return SizedBox(
      height: dateCellHeight + barsHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 날짜 셀 행
          Row(
            children: weekDays.map((date) {
              if (date == null) return SizedBox(width: cellWidth, height: dateCellHeight);
              return _buildDateCell(date, cellWidth, dateCellHeight, holidays);
            }).toList(),
          ),
          // Google 이벤트 바 레인들
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
                child: _buildEventBarWidget(bar),
              );
            });
          }),
        ],
      ),
    );
  }

  Widget _buildDateCell(
    DateTime date,
    double width,
    double height,
    Map<DateTime, String> holidays,
  ) {
    final isSelected = _selectedDate != null && _isSameDay(date, _selectedDate!);
    final isToday = _isSameDay(date, DateTime.now());
    final hasSchedule = _hasSchedule(date);
    final hasAnniversary = _hasAnniversary(date);
    final holidayName = holidays[DateTime(date.year, date.month, date.day)];
    // 단일일 Google 이벤트만 점으로 표시 (다기간은 바로 표시)
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
      onTap: () => setState(() => _selectedDate = date),
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
            if (holidayName != null ||
                hasSchedule ||
                hasAnniversary ||
                hasSingleDayGoogle)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (holidayName != null)
                    _dot(isSelected ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurfaceVariant),
                  if (holidayName != null && (hasSchedule || hasAnniversary || hasSingleDayGoogle))
                    const SizedBox(width: 2),
                  if (hasSchedule)
                    _dot(isSelected ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurface),
                  if (hasSchedule && (hasAnniversary || hasSingleDayGoogle))
                    const SizedBox(width: 2),
                  if (hasAnniversary)
                    _dot(isSelected ? Theme.of(context).colorScheme.onPrimary.withOpacity(0.7) : Theme.of(context).colorScheme.onSurfaceVariant),
                  if (hasAnniversary && hasSingleDayGoogle) const SizedBox(width: 2),
                  if (hasSingleDayGoogle)
                    _dot(isSelected ? Theme.of(context).colorScheme.onPrimary.withOpacity(0.6) : Theme.of(context).colorScheme.outline),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _dot(Color color) => Container(
        width: 5,
        height: 5,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );

  Widget _buildEventBarWidget(_EventBar bar) {
    return GestureDetector(
      onTap: () => setState(() {
        // 바를 탭하면 이벤트 시작일 선택
        _selectedDate = bar.event.start;
      }),
      child: Container(
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
        // 이벤트 제목은 시작 지점(capLeft)에만 표시
        child: bar.capLeft
            ? Text(
                bar.event.title,
                style: TextStyle(fontSize: 9, color: Theme.of(context).colorScheme.onInverseSurface),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              )
            : null,
      ),
    );
  }

  // ─── 일정 목록 ────────────────────────────────────────────────────────────

  Widget _buildScheduleList() {
    if (_selectedDate == null) {
      return const Center(child: Text("날짜를 선택해주세요"));
    }

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final daySchedules = _schedulesForDate(_selectedDate!);
    final dayAnniversaries = _anniversariesForDate(_selectedDate!);
    final dayGoogleEvents = _googleEventsForDate(_selectedDate!);
    final dayHoliday = _buildYearHolidays(_selectedDate!.year)[
        DateTime(_selectedDate!.year, _selectedDate!.month, _selectedDate!.day)];

    if (daySchedules.isEmpty &&
        dayAnniversaries.isEmpty &&
        dayGoogleEvents.isEmpty &&
        dayHoliday == null) {
      return Center(
        child: Text(
          "${_selectedDate!.month}월 ${_selectedDate!.day}일 일정이 없습니다",
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (dayHoliday != null) _buildHolidayItem(dayHoliday),
        ...dayAnniversaries.map((a) => _buildAnniversaryItem(a)),
        ...daySchedules.map((s) => _buildScheduleItem(s)),
        ...dayGoogleEvents.map((e) => _buildGoogleEventItem(e)),
      ],
    );
  }

  Widget _buildHolidayItem(String name) {
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
            child: Text("공휴일", style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }

  Widget _buildAnniversaryItem(dynamic anniversary) {
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
            child: Text("기념일", style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleItem(dynamic schedule) {
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
      onDismissed: (_) => _deleteSchedule(schedule['id']),
      child: GestureDetector(
        onTap: () => _showScheduleDetailDialog(schedule),
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
                      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
              if (schedule['memo'] != null && schedule['memo'].toString().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  schedule['memo'],
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGoogleEventItem(GoogleCalEvent event) {
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
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
            onTap: () => _deleteGoogleEvent(event),
            child: Icon(Icons.delete_outline, size: 20, color: Theme.of(context).colorScheme.outline),
          ),
        ],
      ),
    );
  }
}
