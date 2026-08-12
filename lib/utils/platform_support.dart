import 'package:flutter/foundation.dart';

/// 플랫폼별 기능 지원 여부를 한 곳에서 판단한다.
/// 데스크톱에서는 모바일 전용 플러그인이 동작하지 않으므로 UI 단에서 미리 걸러낸다.

bool get isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

/// image_picker의 ImageSource.camera는 데스크톱·웹에서 지원되지 않는다.
/// (갤러리 선택은 파일 다이얼로그로 대체되어 정상 동작)
bool get supportsCamera => !kIsWeb && !isDesktop;

/// super_clipboard 기반 이미지 붙여넣기를 입력창 컨텍스트 메뉴에 노출할지 여부.
/// iOS는 기존 동작(비활성)을 유지하고 Android와 데스크톱에서만 켠다.
bool get supportsClipboardPaste =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android || isDesktop);
