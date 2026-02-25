import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FontSizeNotifier extends ChangeNotifier {
  static const _key = 'font_scale';

  double _scale = 1.0;
  double get scale => _scale;

  FontSizeNotifier() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _scale = prefs.getDouble(_key) ?? 1.0;
    notifyListeners();
  }

  Future<void> setScale(double scale) async {
    _scale = scale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_key, scale);
    notifyListeners();
  }
}

// 앱 전역에서 하나의 인스턴스만 사용
final fontSizeNotifier = FontSizeNotifier();
