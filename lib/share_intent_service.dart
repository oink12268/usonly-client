import 'dart:async';
import 'package:flutter/services.dart';

class SharedContent {
  final String type; // 'text' or 'images'
  final String? text;
  final List<String>? imagePaths;

  SharedContent({required this.type, this.text, this.imagePaths});
}

class ShareIntentService {
  static final ShareIntentService _instance = ShareIntentService._();
  factory ShareIntentService() => _instance;
  ShareIntentService._();

  static const _channel = MethodChannel('com.example.usonly_client/share');

  final StreamController<SharedContent> _controller =
      StreamController.broadcast();
  Stream<SharedContent> get stream => _controller.stream;

  SharedContent? _pending;
  SharedContent? get pending => _pending;

  void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedDataReceived') {
        final data = call.arguments;
        if (data != null) {
          final content = _parse(Map<String, dynamic>.from(data as Map));
          if (content != null) {
            _pending = content;
            _controller.add(content);
          }
        }
      }
    });
  }

  Future<void> checkInitialShare() async {
    try {
      final data = await _channel.invokeMethod<Map>('getSharedData');
      if (data != null) {
        final content = _parse(Map<String, dynamic>.from(data));
        if (content != null) {
          _pending = content;
          _controller.add(content);
        }
      }
    } catch (_) {}
  }

  SharedContent? consumePending() {
    final c = _pending;
    _pending = null;
    return c;
  }

  SharedContent? _parse(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    if (type == 'text') {
      final text = data['text'] as String?;
      if (text != null && text.isNotEmpty) {
        return SharedContent(type: 'text', text: text);
      }
    } else if (type == 'images') {
      final paths = (data['paths'] as List?)?.cast<String>();
      if (paths != null && paths.isNotEmpty) {
        return SharedContent(type: 'images', imagePaths: paths);
      }
    }
    return null;
  }
}
