import 'dart:convert';
import 'package:http/http.dart' as http;
import 'auth_service.dart';

class GoogleCalEvent {
  final String id;
  final String title;
  final DateTime start; // inclusive date
  final DateTime end; // inclusive date
  final bool isAllDay;

  const GoogleCalEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.isAllDay,
  });

  bool get isMultiDay =>
      start.year != end.year || start.month != end.month || start.day != end.day;
}

class GoogleCalendarService {
  static final GoogleCalendarService _instance = GoogleCalendarService._();
  factory GoogleCalendarService() => _instance;
  GoogleCalendarService._();

  static const _apiBase = 'https://www.googleapis.com';

  Future<Map<String, String>> _headers() async {
    final token = await AuthService.getGoogleAccessToken();
    if (token == null) return {};
    return {'Authorization': 'Bearer $token'};
  }

  Future<List<GoogleCalEvent>> fetchMonthEvents(int year, int month) async {
    final headers = await _headers();
    if (headers.isEmpty) return [];

    final timeMin = DateTime.utc(year, month, 1).toIso8601String();
    final timeMax = DateTime.utc(year, month + 1, 1).toIso8601String();

    try {
      final response = await http.get(
        Uri.https('www.googleapis.com', '/calendar/v3/calendars/primary/events', {
          'timeMin': timeMin,
          'timeMax': timeMax,
          'singleEvents': 'true',
          'orderBy': 'startTime',
          'maxResults': '250',
        }),
        headers: headers,
      );

      if (response.statusCode != 200) return [];

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final items = (data['items'] as List?) ?? [];

      final events = <GoogleCalEvent>[];
      for (final item in items) {
        final startObj = item['start'] as Map<String, dynamic>;
        final endObj = item['end'] as Map<String, dynamic>;
        final isAllDay = startObj['date'] != null;

        DateTime start, end;
        if (isAllDay) {
          start = DateTime.parse(startObj['date'] as String);
          // Google Calendar의 종료일은 exclusive (다음날 0시)이므로 1일 빼기
          end = DateTime.parse(endObj['date'] as String).subtract(const Duration(days: 1));
        } else {
          final startDt = DateTime.parse(startObj['dateTime'] as String).toLocal();
          final endDt = DateTime.parse(endObj['dateTime'] as String).toLocal();
          start = DateTime(startDt.year, startDt.month, startDt.day);
          end = DateTime(endDt.year, endDt.month, endDt.day);
        }

        events.add(GoogleCalEvent(
          id: item['id'] as String,
          title: item['summary'] as String? ?? '(제목 없음)',
          start: start,
          end: end,
          isAllDay: isAllDay,
        ));
      }
      return events;
    } catch (e) {
      print('Google Calendar 이벤트 가져오기 실패: $e');
      return [];
    }
  }

  /// 앱 일정을 Google Calendar에 이벤트로 생성
  /// startTime/endTime이 있으면 시간 이벤트, 없으면 종일 이벤트로 생성
  Future<String?> createEvent(
    String title,
    DateTime date, {
    String? memo,
    String? startTime, // HH:mm
    String? endTime,   // HH:mm
    String? location,
  }) async {
    final headers = await _headers();
    if (headers.isEmpty) return null;

    Map<String, dynamic> startObj;
    Map<String, dynamic> endObj;

    if (startTime != null && endTime != null) {
      const tz = 'Asia/Seoul';
      final startDt = '${_fmt(date)}T$startTime:00';
      final endDt = '${_fmt(date)}T$endTime:00';
      startObj = {'dateTime': startDt, 'timeZone': tz};
      endObj = {'dateTime': endDt, 'timeZone': tz};
    } else {
      startObj = {'date': _fmt(date)};
      endObj = {'date': _fmt(date.add(const Duration(days: 1)))};
    }

    try {
      final response = await http.post(
        Uri.parse('$_apiBase/calendar/v3/calendars/primary/events'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'summary': title,
          if (memo != null && memo.isNotEmpty) 'description': memo,
          if (location != null && location.isNotEmpty) 'location': location,
          'start': startObj,
          'end': endObj,
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return (jsonDecode(response.body) as Map<String, dynamic>)['id'] as String?;
      }
    } catch (e) {
      print('Google Calendar 이벤트 생성 실패: $e');
    }
    return null;
  }

  Future<void> updateEvent(
    String eventId,
    String title,
    DateTime date, {
    String? memo,
  }) async {
    final headers = await _headers();
    if (headers.isEmpty) return;

    try {
      await http.put(
        Uri.parse('$_apiBase/calendar/v3/calendars/primary/events/$eventId'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'summary': title,
          'description': memo ?? '',
          'start': {'date': _fmt(date)},
          'end': {'date': _fmt(date.add(const Duration(days: 1)))},
        }),
      );
    } catch (e) {
      print('Google Calendar 이벤트 수정 실패: $e');
    }
  }

  Future<void> deleteEvent(String eventId) async {
    final headers = await _headers();
    if (headers.isEmpty) return;

    try {
      await http.delete(
        Uri.parse('$_apiBase/calendar/v3/calendars/primary/events/$eventId'),
        headers: headers,
      );
    } catch (e) {
      print('Google Calendar 이벤트 삭제 실패: $e');
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
