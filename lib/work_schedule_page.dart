import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:typed_data';
import 'api_config.dart';
import 'api_client.dart';

class WorkSchedulePage extends StatefulWidget {
  final String? nickname;

  const WorkSchedulePage({super.key, this.nickname});

  @override
  State<WorkSchedulePage> createState() => _WorkSchedulePageState();
}

class _WorkSchedulePageState extends State<WorkSchedulePage> {
  final ImagePicker _picker = ImagePicker();

  static const String _prefsKeySchedules = 'work_schedules';
  static const String _prefsKeyName = 'work_schedule_name';

  static const Map<String, String> _shiftMap = {
    'DD': '휴무',
    'E': '12:00~22:00',
    'A': '08:30~17:30',
    'B': '11:00~21:00',
  };

  String _shiftDisplay(String code) {
    return _shiftMap[code] ?? code;
  }

  XFile? _selectedImage;
  Uint8List? _imageBytes;
  bool _isAnalyzing = false;
  String? _errorMessage;
  List<dynamic>? _schedules;
  String? _resultName;

  String get _name => widget.nickname ?? '최진화';

  @override
  void initState() {
    super.initState();
    _loadSavedSchedules();
  }

  Future<void> _loadSavedSchedules() async {
    final prefs = await SharedPreferences.getInstance();
    final savedJson = prefs.getString(_prefsKeySchedules);
    final savedName = prefs.getString(_prefsKeyName);
    if (savedJson != null) {
      setState(() {
        _schedules = jsonDecode(savedJson);
        _resultName = savedName;
      });
    }
  }

  Future<void> _saveSchedules() async {
    if (_schedules == null || _schedules!.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeySchedules, jsonEncode(_schedules));
    if (_resultName != null) {
      await prefs.setString(_prefsKeyName, _resultName!);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final XFile? image = await _picker.pickImage(
      source: source,
      imageQuality: 90,
      maxWidth: 2000,
    );
    if (image != null) {
      final bytes = await image.readAsBytes();
      setState(() {
        _selectedImage = image;
        _imageBytes = bytes;
        _errorMessage = null;
      });
      _analyze();
    }
  }

  Future<void> _analyze() async {
    if (_selectedImage == null) {
      setState(() => _errorMessage = '사진을 먼저 선택해주세요.');
      return;
    }
    if (_name.trim().isEmpty) {
      setState(() => _errorMessage = '닉네임이 설정되지 않았습니다.');
      return;
    }

    setState(() {
      _isAnalyzing = true;
      _errorMessage = null;
    });

    try {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('${ApiConfig.baseUrl}/api/work-schedule/analyze'),
      );
      request.fields['name'] = _name.trim();
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          _imageBytes!,
          filename: _selectedImage!.name,
        ),
      );

      var response = await ApiClient.sendMultipart(request);
      var responseBody = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        final data = jsonDecode(responseBody);
        setState(() {
          _resultName = data['name'];
          _schedules = data['schedules'];
          if (_schedules != null && _schedules!.isEmpty) {
            _errorMessage = '이름 "${_name.trim()}"에 해당하는 스케쥴을 찾지 못했습니다.\n닉네임을 확인해주세요.';
          }
        });
        await _saveSchedules();
      } else {
        setState(() => _errorMessage = '분석 실패: $responseBody');
      }
    } catch (e) {
      setState(() => _errorMessage = '오류 발생: $e');
    } finally {
      setState(() => _isAnalyzing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('근무 스케쥴 분석'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 이미지 미리보기
            Container(
              height: 200,
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: _imageBytes != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        _imageBytes!,
                        fit: BoxFit.contain,
                      ),
                    )
                  : const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.image_outlined, size: 48, color: Colors.grey),
                          SizedBox(height: 8),
                          Text('근무 스케쥴표 사진을 선택해주세요',
                              style: TextStyle(color: Colors.grey)),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 12),

            // 갤러리/카메라 버튼
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library),
                    label: const Text('갤러리'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF8B7E74),
                      side: const BorderSide(color: Color(0xFF8B7E74)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickImage(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('카메라'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF8B7E74),
                      side: const BorderSide(color: Color(0xFF8B7E74)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 분석 중 표시
            if (_isAnalyzing)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF8B7E74),
                      ),
                    ),
                    SizedBox(width: 10),
                    Text('분석 중...', style: TextStyle(color: Color(0xFF8B7E74))),
                  ],
                ),
              ),

            // 에러 메시지
            if (_errorMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: Colors.red[700]),
                ),
              ),

            // 결과 테이블
            if (_schedules != null && _schedules!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '$_resultName 님의 근무 스케쥴',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowColor: WidgetStateProperty.all(const Color(0xFFF5F0EB)),
                  columns: const [
                    DataColumn(label: Text('날짜', style: TextStyle(fontWeight: FontWeight.bold))),
                    DataColumn(label: Text('요일', style: TextStyle(fontWeight: FontWeight.bold))),
                    DataColumn(label: Text('근무', style: TextStyle(fontWeight: FontWeight.bold))),
                  ],
                  rows: _schedules!.map<DataRow>((s) {
                    final dayOfWeek = s['dayOfWeek'] ?? '';
                    final rawShift = (s['shift'] ?? '').toUpperCase();
                    final display = _shiftDisplay(rawShift);
                    final isOff = rawShift == 'DD' || display.contains('휴무');
                    return DataRow(cells: [
                      DataCell(Text(s['date'] ?? '')),
                      DataCell(Text(
                        dayOfWeek,
                        style: TextStyle(
                          color: dayOfWeek == '일' ? Colors.red : dayOfWeek == '토' ? Colors.blue : null,
                        ),
                      )),
                      DataCell(Text(
                        display,
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          color: isOff ? Colors.grey : const Color(0xFF8B7E74),
                        ),
                      )),
                    ]);
                  }).toList(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
