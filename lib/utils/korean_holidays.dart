/// 한국 공휴일 계산 유틸리티
class KoreanHolidays {
  /// 해당 연도의 공휴일 Map 반환 (날짜 → 공휴일 이름)
  static Map<DateTime, String> buildYearHolidays(int year) {
    final Map<DateTime, List<String>> base = {};

    void add(DateTime date, String name) {
      final d = DateTime(date.year, date.month, date.day);
      (base[d] ??= []).add(name);
    }

    add(DateTime(year, 1, 1), '신정');
    add(DateTime(year, 3, 1), '삼일절');
    add(DateTime(year, 5, 5), '어린이날');
    add(DateTime(year, 6, 6), '현충일');
    add(DateTime(year, 8, 15), '광복절');
    add(DateTime(year, 10, 3), '개천절');
    add(DateTime(year, 10, 9), '한글날');
    add(DateTime(year, 12, 25), '크리스마스');

    final seollal = _seollalDate(year);
    if (seollal != null) {
      add(seollal.subtract(const Duration(days: 1)), '설날 전날');
      add(seollal, '설날');
      add(seollal.add(const Duration(days: 1)), '설날 연휴');
    }

    final chuseok = _chuseokDate(year);
    if (chuseok != null) {
      add(chuseok.subtract(const Duration(days: 1)), '추석 전날');
      add(chuseok, '추석');
      add(chuseok.add(const Duration(days: 1)), '추석 연휴');
    }

    final buddha = _buddhaDate(year);
    if (buddha != null) add(buddha, '부처님오신날');

    final result = <DateTime, String>{};
    final sortedDates = base.keys.toList()..sort();
    for (final date in sortedDates) {
      result[date] = base[date]!.first;
    }

    DateTime nextAvailable(DateTime from) {
      DateTime sub = from.add(const Duration(days: 1));
      while (result.containsKey(sub) ||
          sub.weekday == DateTime.saturday ||
          sub.weekday == DateTime.sunday) {
        sub = sub.add(const Duration(days: 1));
      }
      return sub;
    }

    for (final date in sortedDates) {
      final names = base[date]!;
      for (int i = 1; i < names.length; i++) {
        result[nextAvailable(date)] = '${names[i]} 대체공휴일';
      }
      if (date.weekday == DateTime.sunday) {
        final sub = nextAvailable(date);
        if (!result.containsKey(sub)) {
          result[sub] = '${names.first} 대체공휴일';
        }
      }
      if (names.contains('어린이날') && date.weekday == DateTime.saturday) {
        final sub = nextAvailable(date);
        if (!result.containsKey(sub)) result[sub] = '어린이날 대체공휴일';
      }
    }

    return result;
  }

  static DateTime? _seollalDate(int year) {
    const dates = <int, List<int>>{
      2025: [1, 29], 2026: [2, 17], 2027: [2, 6], 2028: [1, 26],
      2029: [2, 13], 2030: [2, 3], 2031: [1, 23], 2032: [2, 10],
      2033: [1, 31], 2034: [2, 19], 2035: [2, 8], 2036: [1, 28],
      2037: [2, 16], 2038: [2, 5], 2039: [1, 25], 2040: [2, 12],
    };
    final d = dates[year];
    return d == null ? null : DateTime(year, d[0], d[1]);
  }

  static DateTime? _chuseokDate(int year) {
    const dates = <int, List<int>>{
      2025: [10, 6], 2026: [9, 25], 2027: [9, 15], 2028: [10, 3],
      2029: [9, 22], 2030: [9, 12], 2031: [10, 1], 2032: [9, 19],
      2033: [9, 7], 2034: [9, 27], 2035: [9, 16], 2036: [10, 4],
      2037: [9, 24], 2038: [9, 13], 2039: [10, 2], 2040: [9, 21],
    };
    final d = dates[year];
    return d == null ? null : DateTime(year, d[0], d[1]);
  }

  static DateTime? _buddhaDate(int year) {
    const dates = <int, List<int>>{
      2025: [5, 5], 2026: [5, 24], 2027: [5, 13], 2028: [5, 2],
      2029: [5, 20], 2030: [5, 9], 2031: [5, 28], 2032: [5, 17],
      2033: [5, 6], 2034: [5, 25], 2035: [5, 14], 2036: [5, 3],
      2037: [5, 22], 2038: [5, 12], 2039: [4, 30], 2040: [5, 19],
    };
    final d = dates[year];
    return d == null ? null : DateTime(year, d[0], d[1]);
  }
}
