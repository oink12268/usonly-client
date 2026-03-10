/// 날짜/시간 포맷 유틸리티
class DateFormatter {
  /// DateTime 문자열 → "오전/오후 H:MM" 포맷
  static String formatTime(String? dateTime) {
    if (dateTime == null) return '';
    try {
      final dt = DateTime.parse(dateTime);
      final hour = dt.hour;
      final minute = dt.minute.toString().padLeft(2, '0');
      if (hour == 0) return '오전 12:$minute';
      if (hour < 12) return '오전 $hour:$minute';
      if (hour == 12) return '오후 12:$minute';
      return '오후 ${hour - 12}:$minute';
    } catch (_) {
      return '';
    }
  }

  /// DateTime 문자열 → "M/D 오전/오후 H:MM" 포맷
  static String formatDateTime(String? dateTime) {
    if (dateTime == null) return '';
    try {
      final dt = DateTime.parse(dateTime);
      final timeStr = formatTime(dateTime);
      return '${dt.month}/${dt.day} $timeStr';
    } catch (_) {
      return '';
    }
  }

  /// DateTime → "YYYY-MM-DD" 포맷
  static String formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  /// 두 날짜 문자열(ISO 포맷)이 같은 날인지 확인
  static bool isSameDate(String? date1, String? date2) {
    if (date1 == null || date2 == null) return false;
    return date1.split('T')[0] == date2.split('T')[0];
  }

  /// DateTime 문자열 → "오늘 HH:MM" 또는 "M/D" 포맷 (메모 등에서 사용)
  static String formatRelative(String? dateStr) {
    if (dateStr == null) return '';
    try {
      final dt = DateTime.parse(dateStr);
      final now = DateTime.now();
      if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
        return '오늘 ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }
      return '${dt.month}/${dt.day}';
    } catch (_) {
      return '';
    }
  }
}
