import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

// url_launcher 패키지가 release 빌드에서 플랫폼 채널을 못 잡는 경우가 있어
// (PlatformException: Unable to establish connection on channel:
// dev.flutter.pigeon.url_launcher_android...), 네이티브 쪽에 직접 만들어둔
// 채널로 먼저 시도하고, 실패하면 url_launcher로 폴백한다.
const _shareChannel = MethodChannel('com.example.usonly_client/share');

Future<void> launchUrlWithFallback(String url) async {
  if (url.isEmpty) return;
  try {
    await _shareChannel.invokeMethod('launchUrl', {'url': url});
  } catch (_) {
    final uri = Uri.tryParse(url);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
