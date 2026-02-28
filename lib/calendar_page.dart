import 'package:flutter/material.dart';
import 'dart:convert';
import 'api_config.dart';
import 'api_client.dart';

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
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime.now();
    _fetchData();
  }

  Future<void> _fetchData() async {
    setState(() => _isLoading = true);
    await Future.wait([_fetchSchedules(), _fetchAnniversaries()]);
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

  // 해당 날짜에 일정이 있는지
  bool _hasSchedule(DateTime day) {
    final dayStr = _toDateStr(day);
    return _schedules.any((s) => s['date'] == dayStr);
  }

  // 기념일이 현재 보는 월에 해당하는 날짜 계산 (반복 기념일은 매년 같은 월/일)
  DateTime? _anniversaryDateInMonth(dynamic anniversary) {
    final dateStr = anniversary['date'] as String?;
    if (dateStr == null) return null;
    final date = DateTime.parse(dateStr);
    final bool recurring = anniversary['recurring'] == true;
    final int year = _focusedMonth.year;
    final int month = _focusedMonth.month;

    if (!recurring) {
      // 반복 없는 기념일: 정확히 해당 연/월에만 표시
      if (date.year == year && date.month == month) return date;
      return null;
    }

    // 매년 반복: 기념일 월이 현재 보는 월과 같으면 해당 연도로 날짜 생성
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

  // 선택된 날짜의 일정 목록
  List<dynamic> _schedulesForDate(DateTime day) {
    final dayStr = _toDateStr(day);
    return _schedules.where((s) => s['date'] == dayStr).toList();
  }

  String _toDateStr(DateTime day) {
    return "${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}";
  }

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
              // 연도 선택
              Expanded(
                child: SizedBox(
                  height: 200,
                  child: ListWheelScrollView.useDelegate(
                    itemExtent: 40,
                    diameterRatio: 1.5,
                    controller: FixedExtentScrollController(
                      initialItem: selectedYear - 1900,
                    ),
                    onSelectedItemChanged: (index) {
                      setDialogState(() => selectedYear = 1900 + index);
                    },
                    childDelegate: ListWheelChildBuilderDelegate(
                      childCount: 201, // 1900 ~ 2100
                      builder: (context, index) {
                        final y = 1900 + index;
                        return Center(
                          child: Text(
                            "$y년",
                            style: TextStyle(
                              fontSize: y == selectedYear ? 18 : 14,
                              fontWeight: y == selectedYear ? FontWeight.bold : FontWeight.normal,
                              color: y == selectedYear ? const Color(0xFF8B7E74) : Colors.grey,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              // 월 선택
              Expanded(
                child: SizedBox(
                  height: 200,
                  child: ListWheelScrollView.useDelegate(
                    itemExtent: 40,
                    diameterRatio: 1.5,
                    controller: FixedExtentScrollController(
                      initialItem: selectedMonth - 1,
                    ),
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
                              color: m == selectedMonth ? const Color(0xFF8B7E74) : Colors.grey,
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
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B7E74)),
              onPressed: () {
                setState(() {
                  _focusedMonth = DateTime(selectedYear, selectedMonth);
                  _selectedDate = null;
                });
                _fetchData();
                Navigator.pop(context);
              },
              child: const Text("확인", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddScheduleDialog() {
    if (_selectedDate == null) return;

    final titleController = TextEditingController();
    final memoController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          "${_selectedDate!.month}월 ${_selectedDate!.day}일 일정 추가",
        ),
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
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("취소"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B7E74)),
            onPressed: () async {
              if (titleController.text.isNotEmpty) {
                await _createSchedule(
                  titleController.text,
                  memoController.text,
                );
                Navigator.pop(context);
              }
            },
            child: const Text("추가", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _createSchedule(String title, String memo) async {
    final dateStr = _toDateStr(_selectedDate!);
    try {
      final response = await ApiClient.post(
        Uri.parse('${ApiConfig.baseUrl}/api/schedules'),
        body: jsonEncode({
          'title': title,
          'memo': memo,
          'date': dateStr,
        }),
      );
      if (response.statusCode == 200) {
        _fetchSchedules();
      }
    } catch (e) {
      print("일정 추가 에러: $e");
    }
  }

  Future<void> _updateSchedule(int id, String title, String memo, String date) async {
    try {
      final response = await ApiClient.put(
        Uri.parse('${ApiConfig.baseUrl}/api/schedules/$id'),
        body: jsonEncode({
          'title': title,
          'memo': memo,
          'date': date,
        }),
      );
      if (response.statusCode == 200) {
        _fetchSchedules();
      }
    } catch (e) {
      print("일정 수정 에러: $e");
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
              // 날짜 선택
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
                    border: Border.all(color: Colors.grey.shade400),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.calendar_today, size: 16, color: Color(0xFF8B7E74)),
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
                decoration: const InputDecoration(
                  labelText: "제목",
                  border: OutlineInputBorder(),
                ),
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
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
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
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B7E74)),
              onPressed: () async {
                if (titleController.text.isNotEmpty) {
                  await _updateSchedule(
                    schedule['id'],
                    titleController.text,
                    memoController.text,
                    _toDateStr(selectedDate),
                  );
                  Navigator.pop(context);
                }
              },
              child: const Text("저장", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // 캘린더 영역
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
          // 선택된 날짜의 일정 목록
          Expanded(child: _buildScheduleList()),
        ],
      ),
      floatingActionButton: _selectedDate != null
          ? FloatingActionButton(
              onPressed: _showAddScheduleDialog,
              backgroundColor: const Color(0xFF8B7E74),
              child: const Icon(Icons.add, color: Colors.white),
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

    final days = <Widget>[];

    // 빈 칸 채우기
    for (int i = 0; i < startWeekday; i++) {
      days.add(const SizedBox());
    }

    // 날짜 채우기
    for (int d = 1; d <= lastDay.day; d++) {
      final date = DateTime(year, month, d);
      final isSelected = _selectedDate != null &&
          _selectedDate!.year == date.year &&
          _selectedDate!.month == date.month &&
          _selectedDate!.day == date.day;
      final isToday = DateTime.now().year == date.year &&
          DateTime.now().month == date.month &&
          DateTime.now().day == date.day;
      final hasSchedule = _hasSchedule(date);
      final hasAnniversary = _hasAnniversary(date);

      days.add(
        GestureDetector(
          onTap: () => setState(() => _selectedDate = date),
          child: Container(
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFF8B7E74) : null,
              shape: BoxShape.circle,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  "$d",
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                    color: isSelected
                        ? Colors.white
                        : (date.weekday == DateTime.sunday
                            ? const Color(0xFF8B7E74)
                            : date.weekday == DateTime.saturday
                                ? Colors.blue
                                : Theme.of(context).colorScheme.onSurface),
                  ),
                ),
                if (hasSchedule || hasAnniversary)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (hasSchedule)
                        Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.white : const Color(0xFF8B7E74),
                            shape: BoxShape.circle,
                          ),
                        ),
                      if (hasSchedule && hasAnniversary) const SizedBox(width: 2),
                      if (hasAnniversary)
                        Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.white70 : Colors.pinkAccent,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          // 월 네비게이션
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(onPressed: _prevMonth, icon: const Icon(Icons.chevron_left)),
              GestureDetector(
                onTap: () => _showYearMonthPicker(),
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
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: ['일', '월', '화', '수', '목', '금', '토']
                .map((d) => SizedBox(
                      width: 40,
                      child: Center(
                        child: Text(
                          d,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: d == '일'
                                ? const Color(0xFF8B7E74)
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
          // 날짜 그리드
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 7,
            childAspectRatio: 1.0,
            children: days,
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleList() {
    if (_selectedDate == null) {
      return const Center(child: Text("날짜를 선택해주세요"));
    }

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final daySchedules = _schedulesForDate(_selectedDate!);
    final dayAnniversaries = _anniversariesForDate(_selectedDate!);

    if (daySchedules.isEmpty && dayAnniversaries.isEmpty) {
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
        // 기념일 먼저 표시
        ...dayAnniversaries.map((a) => _buildAnniversaryItem(a)),
        // 일반 일정
        ...daySchedules.map((s) => _buildScheduleItem(s)),
      ],
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
        color: Colors.pink.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.pinkAccent.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.favorite, size: 18, color: Colors.pinkAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      anniversary['title'] ?? "",
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.pinkAccent,
                      ),
                    ),
                    if (recurring) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.repeat, size: 14, color: Colors.pinkAccent),
                    ],
                  ],
                ),
                if (isLunar && lunarMonth != null && lunarDay != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    "음력 $lunarMonth월 $lunarDay일",
                    style: TextStyle(fontSize: 12, color: Colors.pink.shade300),
                  ),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.pinkAccent.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              "기념일",
              style: TextStyle(fontSize: 12, color: Colors.pinkAccent),
            ),
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
          color: const Color(0xFF8B7E74),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("삭제 확인"),
            content: Text("'${schedule['title']}'을(를) 삭제할까요?"),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text("취소"),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text("삭제", style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ) ?? false;
      },
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
                const Icon(Icons.event, size: 18, color: Color(0xFF8B7E74)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    schedule['title'] ?? "",
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (schedule['writerNickname'] != null &&
                    schedule['writerNickname'].toString().isNotEmpty)
                  Text(
                    schedule['writerNickname'],
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
              ],
            ),
            if (schedule['memo'] != null &&
                schedule['memo'].toString().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                schedule['memo'],
                style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
      ),
    );
  }
}
