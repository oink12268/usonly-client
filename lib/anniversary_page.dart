import 'package:flutter/material.dart';
import 'dart:convert';
import 'api_config.dart';
import 'api_client.dart';
import 'widgets/confirm_delete_dialog.dart';

class AnniversaryPage extends StatefulWidget {
  final int memberId;

  const AnniversaryPage({super.key, required this.memberId});

  @override
  State<AnniversaryPage> createState() => _AnniversaryPageState();
}

class _AnniversaryPageState extends State<AnniversaryPage> {
  List<dynamic> _anniversaries = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchAnniversaries();
  }

  Future<void> _fetchAnniversaries() async {
    try {
      final response = await ApiClient.get(
        Uri.parse('${ApiConfig.baseUrl}/api/anniversaries'),
      );
      if (response.statusCode == 200) {
        setState(() {
          _anniversaries = jsonDecode(utf8.decode(response.bodyBytes));
          // D-day 기준 정렬 (가까운 순)
          _anniversaries.sort((a, b) =>
              (a['dday'] as int).abs().compareTo((b['dday'] as int).abs()));
          _isLoading = false;
        });
      }
    } catch (e) {
      print("기념일 로딩 에러: $e");
      setState(() => _isLoading = false);
    }
  }

  void _showAddDialog() {
    final titleController = TextEditingController();
    DateTime selectedDate = DateTime.now();
    bool recurring = true;
    bool isLunar = false;
    int lunarMonth = 1;
    int lunarDay = 1;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("기념일 추가"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    hintText: "기념일 이름 (예: 100일, 생일)",
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                // 음력 토글
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("음력 날짜"),
                  activeColor: Theme.of(context).colorScheme.primary,
                  value: isLunar,
                  onChanged: (val) => setDialogState(() => isLunar = val),
                ),
                if (!isLunar) ...[
                  // 양력: 날짜 피커
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.calendar_today),
                    title: Text(
                      "${selectedDate.year}-${selectedDate.month.toString().padLeft(2, '0')}-${selectedDate.day.toString().padLeft(2, '0')}",
                    ),
                    trailing: TextButton(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: selectedDate,
                          firstDate: DateTime(1900),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setDialogState(() => selectedDate = picked);
                        }
                      },
                      child: const Text("날짜 선택"),
                    ),
                  ),
                ] else ...[
                  // 음력: 월/일 드롭다운
                  Row(
                    children: [
                      const Icon(Icons.calendar_month, size: 20),
                      const SizedBox(width: 8),
                      const Text("음력 ", style: TextStyle(fontSize: 14)),
                      DropdownButton<int>(
                        value: lunarMonth,
                        items: List.generate(12, (i) => i + 1)
                            .map((m) => DropdownMenuItem(value: m, child: Text("$m월")))
                            .toList(),
                        onChanged: (v) => setDialogState(() => lunarMonth = v!),
                      ),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        value: lunarDay,
                        items: List.generate(30, (i) => i + 1)
                            .map((d) => DropdownMenuItem(value: d, child: Text("$d일")))
                            .toList(),
                        onChanged: (v) => setDialogState(() => lunarDay = v!),
                      ),
                    ],
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("매년 반복"),
                  activeColor: Theme.of(context).colorScheme.primary,
                  value: recurring,
                  onChanged: (val) => setDialogState(() => recurring = val),
                ),
              ],
            ),
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
                  await _createAnniversary(
                    titleController.text,
                    selectedDate,
                    recurring,
                    isLunar: isLunar,
                    lunarMonth: isLunar ? lunarMonth : null,
                    lunarDay: isLunar ? lunarDay : null,
                  );
                  Navigator.pop(context);
                }
              },
              child: Text("추가", style: TextStyle(color: Theme.of(context).colorScheme.onPrimary)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createAnniversary(
    String title,
    DateTime date,
    bool recurring, {
    bool isLunar = false,
    int? lunarMonth,
    int? lunarDay,
  }) async {
    final dateStr =
        "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
    final body = <String, dynamic>{
      'title': title,
      'recurring': recurring,
      'lunar': isLunar,
    };

    if (isLunar) {
      body['lunarMonth'] = lunarMonth;
      body['lunarDay'] = lunarDay;
    } else {
      body['date'] = dateStr;
    }

    try {
      final response = await ApiClient.post(
        Uri.parse('${ApiConfig.baseUrl}/api/anniversaries'),
        body: jsonEncode(body),
      );
      if (response.statusCode == 200) {
        _fetchAnniversaries();
      }
    } catch (e) {
      print("기념일 추가 에러: $e");
    }
  }

  Future<void> _deleteAnniversary(int id) async {
    try {
      final response = await ApiClient.delete(
        Uri.parse('${ApiConfig.baseUrl}/api/anniversaries/$id'),
      );
      if (response.statusCode == 200) {
        _fetchAnniversaries();
      }
    } catch (e) {
      print("기념일 삭제 에러: $e");
    }
  }

  String _ddayText(int dday) {
    if (dday == 0) return "오늘";
    if (dday > 0) return "${dday}일 남음";
    return "${dday.abs()}일 째";
  }

  Color _ddayColor(int dday) {
    // context가 없으므로 고정 색상 유지 (의미 있는 색상)
    if (dday == 0) return const Color(0xFF5C4A44);
    if (dday > 0 && dday <= 7) return Colors.grey[600]!;
    if (dday > 0) return Colors.grey[700]!;
    return Colors.grey[500]!;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Scaffold(
      body: _anniversaries.isEmpty
          ? const Center(child: Text("우리만의 기념일을 추가해보세요!"))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _anniversaries.length,
              itemBuilder: (context, index) {
                final item = _anniversaries[index];
                final int dday = item['dday'];
                return _buildAnniversaryCard(item, dday);
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDialog,
        backgroundColor: Theme.of(context).colorScheme.primary,
        child: Icon(Icons.add, color: Theme.of(context).colorScheme.onPrimary),
      ),
    );
  }

  Widget _buildAnniversaryCard(dynamic item, int dday) {
    final bool isLunar = item['lunar'] == true;
    final int? lunarMonth = item['lunarMonth'];
    final int? lunarDay = item['lunarDay'];

    return Dismissible(
      key: Key(item['id'].toString()),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(Icons.delete, color: Theme.of(context).colorScheme.onPrimary),
      ),
      confirmDismiss: (_) async => ConfirmDeleteDialog.show(
        context,
        content: "'${item['title']}'을(를) 삭제할까요?",
      ),
      onDismissed: (_) => _deleteAnniversary(item['id']),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: dday == 0
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: dday == 0 ? Border.all(color: Theme.of(context).colorScheme.primary, width: 1.5) : null,
        ),
        child: Row(
          children: [
            // 왼쪽: 기념일 정보
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        item['title'] ?? "",
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      // if (item['recurring'] == true) ...[
                      //   const SizedBox(width: 6),
                      //   Icon(Icons.repeat, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      // ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item['date'] ?? "",
                    style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  // 음력 표시
                  if (isLunar && lunarMonth != null && lunarDay != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      "(음력 $lunarMonth월 $lunarDay일)",
                      style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
            // 오른쪽: D-day
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: _ddayColor(dday).withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _ddayText(dday),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: _ddayColor(dday),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
