import 'dart:convert';
import 'package:flutter/material.dart';
import 'api_client.dart';
import 'api_endpoints.dart';
import 'fcm_service.dart';
import 'google_calendar_service.dart';
import 'utils/date_formatter.dart';
import 'widgets/confirm_delete_dialog.dart';
import 'widgets/calendar_grid.dart';
import 'widgets/schedule_list_view.dart';

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
    // 페이지 진입 = 일정/기념일 알림을 본 것으로 간주 → other 배지 카운터 0
    FcmService().clearOtherNotifications();
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
        Uri.parse(ApiEndpoints.schedules(_focusedMonth.year, _focusedMonth.month)),
      );
      if (response.statusCode == 200) {
        setState(() {
          _schedules = ApiClient.decodeBody(response) as List;
        });
      }
    } catch (e) {
      debugPrint("일정 로딩 에러: $e");
    }
  }

  Future<void> _fetchAnniversaries() async {
    try {
      final response = await ApiClient.get(
        Uri.parse(ApiEndpoints.anniversaries),
      );
      if (response.statusCode == 200) {
        setState(() {
          _anniversaries = ApiClient.decodeBody(response) as List;
        });
      }
    } catch (e) {
      debugPrint("기념일 로딩 에러: $e");
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

  String _toDateStr(DateTime day) => DateFormatter.formatDate(day);

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
        Uri.parse(ApiEndpoints.schedulesBase),
        body: jsonEncode({'title': title, 'memo': memo, 'date': dateStr}),
      );
      if (response.statusCode == 200) {
        if (syncToGoogle) {
          await GoogleCalendarService().createEvent(title, _selectedDate!, memo: memo);
        }
        await Future.wait([_fetchSchedules(), if (syncToGoogle) _fetchGoogleEvents()]);
      }
    } catch (e) {
      debugPrint("일정 추가 에러: $e");
    }
  }

  Future<void> _updateSchedule(int id, String title, String memo, String date) async {
    try {
      final response = await ApiClient.put(
        Uri.parse(ApiEndpoints.scheduleById(id)),
        body: jsonEncode({'title': title, 'memo': memo, 'date': date}),
      );
      if (response.statusCode == 200) {
        _fetchSchedules();
      }
    } catch (e) {
      debugPrint("일정 수정 에러: $e");
    }
  }

  Future<void> _deleteSchedule(int id) async {
    try {
      final response = await ApiClient.delete(
        Uri.parse(ApiEndpoints.scheduleById(id)),
      );
      if (response.statusCode == 200) {
        _fetchSchedules();
      }
    } catch (e) {
      debugPrint("일정 삭제 에러: $e");
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
            child: CalendarGrid(
              focusedMonth: _focusedMonth,
              selectedDate: _selectedDate,
              schedules: _schedules,
              anniversaries: _anniversaries,
              googleEvents: _googleEvents,
              onDateSelected: (date) => setState(() => _selectedDate = date),
              onPrevMonth: _prevMonth,
              onNextMonth: _nextMonth,
              onYearMonthPicker: _showYearMonthPicker,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ScheduleListView(
              selectedDate: _selectedDate,
              isLoading: _isLoading,
              focusedMonth: _focusedMonth,
              schedules: _schedules,
              anniversaries: _anniversaries,
              googleEvents: _googleEvents,
              onDeleteSchedule: _deleteSchedule,
              onEditSchedule: _showScheduleDetailDialog,
              onDeleteGoogleEvent: _deleteGoogleEvent,
            ),
          ),
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
}
