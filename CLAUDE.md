# UsOnly Client - 개발 참고사항

## 프로젝트 개요
커플 전용 Flutter 앱 (Android / iOS / Windows)
- 백엔드: `usonly.iptime.org:30080` (K8s NodePort)
- WebSocket: `ws://usonly.iptime.org:30080/ws`

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
