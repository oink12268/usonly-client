# UsOnly Client - 개발 참고사항

## 프로젝트 개요
커플 전용 Flutter 앱 (Android / iOS / Windows)
- 백엔드: `usonly.duckdns.org` (HTTPS / DDNS)
- WebSocket: `wss://usonly.duckdns.org/ws`

## 지원 플랫폼
- Android / iOS (주 타겟)
- Windows (MSIX 설치파일)
- ~~linux, macos, windows 스캐폴딩 제거됨~~ (windows만 유지)

## Firebase
- `firebase_options.dart` / `google-services.json` / `GoogleService-Info.plist` 는 `.gitignore` 처리됨
- 클론 후 반드시 `flutterfire configure` 실행 필요
- Firebase CLI 먼저 설치: `npm install -g firebase-tools`

## 주요 설계 결정

### FCM (푸시 알림)
- Android / iOS에서만 동작
- Windows는 WebSocket이 상시 연결되므로 FCM 불필요
- `fcm_service.dart`와 `main.dart`에 `defaultTargetPlatform` 가드 처리됨

### 이미지 업로드
- `http.MultipartFile.fromBytes()` 사용 (web 호환)
- `fromPath()`는 `dart:io` 의존으로 web에서 동작 안 함

### Windows Google 로그인
- `google_sign_in` 패키지가 Windows 미지원
- 직접 OAuth 2.0 PKCE 플로우 구현 (`auth_service.dart`)
  - `dart:io` HttpServer로 로컬 포트 열어 콜백 수신
  - `url_launcher`로 브라우저 열기
  - Google token endpoint에서 토큰 교환
  - `client_secret` 필요 (Desktop 클라이언트는 PKCE만으로 불충분)
- 관련 상수: `_windowsClientId`, `_windowsClientSecret` (`auth_service.dart` 상단)

---

## 코드 구조 (lib/)

### 디렉토리
```
lib/
├── utils/
│   ├── date_formatter.dart      # 날짜/시간 포맷 유틸 (DateFormatter)
│   └── korean_holidays.dart     # 한국 공휴일 계산 (KoreanHolidays)
├── widgets/
│   └── confirm_delete_dialog.dart  # 공통 삭제 확인 다이얼로그 + 스와이프 배경
└── (페이지 파일들)
```

### 주요 파일
| 파일 | 역할 |
|------|------|
| `main.dart` | 앱 진입점, Firebase 초기화, 라우팅 |
| `api_client.dart` | HTTP 싱글턴 클라이언트 (토큰 자동 첨부) |
| `api_config.dart` | 서버 URL 설정 (`_host`, `_port`) |
| `auth_service.dart` | Firebase/Google 로그인, Windows OAuth PKCE |
| `home_screen.dart` | 하단 탭 네비게이션 |
| `chat_page.dart` | 채팅 메인 (WebSocket STOMP, 이미지/파일 전송) |
| `chat_search_page.dart` | 채팅 검색·달력·날짜별·전체화면 이미지 |
| `calendar_page.dart` | 월간 캘린더 (일정·기념일·Google 이벤트) |
| `album_page.dart` | 앨범 목록 + 갤러리 전환 |
| `note_page.dart` | 메모 목록 (WebSocket 실시간 동기화) |
| `anniversary_page.dart` | 기념일 D-day 관리 |

### 공통 유틸 사용법
```dart
// 날짜 포맷
DateFormatter.formatTime('2024-01-01T15:05:00')  // → '오후 3:05'
DateFormatter.formatDate(DateTime.now())           // → '2024-01-01'
DateFormatter.formatRelative(dateStr)             // → '오늘 15:05' or '1/1'

// 공휴일
KoreanHolidays.buildYearHolidays(2025)  // → Map<DateTime, String>

// 삭제 확인 다이얼로그
final ok = await ConfirmDeleteDialog.show(context, content: '삭제할까요?');
```

### 상태 관리 패턴
- 대부분 `setState` 기반 (단순 화면)
- 전역 상태: `fontSizeNotifier`, `themeNotifier` (ChangeNotifier)
- 실시간 동기화: STOMP WebSocket (`chat_page.dart`, `note_page.dart`)
- 성능 최적화: `ValueNotifier`로 일부 위젯만 rebuild (타이핑 인디케이터, 포커스 상태)

---

## Windows 설치파일 (MSIX) 빌드 방법

### 사전 준비
- Flutter SDK 설치 및 PATH 등록
- Windows 개발자 모드 활성화
  ```powershell
  start ms-settings:developers
  ```
- Firebase CLI 설치
  ```powershell
  npm install -g firebase-tools
  firebase login
  ```
- `firebase_options.dart` 생성
  ```powershell
  flutterfire configure   # Windows 플랫폼 포함해서 선택
  ```

### 빌드 순서

```powershell
# 1. 의존성 설치
flutter pub get

# 2. Windows 릴리즈 빌드
flutter build windows --release

# 3. MSIX 패키지 생성
dart run msix:create
```

빌드 결과물: `build\windows\x64\runner\Release\usonly_client.msix`

### 설치 방법
더블클릭 설치 (서명 없는 패키지이므로 최초 1회 허용 필요)

또는 PowerShell (관리자):
```powershell
Add-AppxPackage .\usonly_client.msix
```

### 재설치 시 버전 충돌 오류 (0x80073cfb)
기존 버전 제거 후 재설치:
```powershell
Get-AppxPackage *usonly* | Remove-AppxPackage
```

또는 `pubspec.yaml`에서 버전 올리기:
```yaml
version: 1.0.1+1
msix_config:
  msix_version: 1.0.1.0
```

### 빌드 중 schannel TLS 오류
`dl.google.com` 다운로드 시 일시적 오류. 재시도하거나:
```powershell
$env:FLUTTER_HTTP_NO_HTTP2 = "1"
flutter build windows --release
```
