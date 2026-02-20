# UsOnly Client

커플 전용 Flutter 앱 - 앨범, 캘린더, 채팅, 기념일, 근무일정 분석

## 지원 플랫폼

| 플랫폼 | 상태 |
|--------|------|
| Android | ✅ |
| iOS | ✅ |
| Windows | ✅ (MSIX) |

## 시작하기

### 1. 의존성 설치

```bash
flutter pub get
```

### 2. Firebase 설정

`firebase_options.dart`는 보안상 git에서 제외되어 있습니다. 클론 후 반드시 생성 필요:

```bash
npm install -g firebase-tools
firebase login
flutterfire configure
```

### 3. 실행

```bash
# Android / iOS
flutter run

# Windows
flutter run -d windows
```

---

## Windows 설치파일 (MSIX) 빌드

### 사전 준비

Windows **개발자 모드** 활성화:
```powershell
start ms-settings:developers
```

### 빌드

```powershell
flutter build windows --release
dart run msix:create
```

결과물: `build\windows\x64\runner\Release\usonly_client.msix`

### 설치

더블클릭 또는 PowerShell (관리자):
```powershell
Add-AppxPackage .\usonly_client.msix
```

**재설치 시 버전 충돌 오류가 나면:**
```powershell
Get-AppxPackage *usonly* | Remove-AppxPackage
```

---

## 서버 정보

- API: `http://usonly.iptime.org:30080`
- WebSocket: `ws://usonly.iptime.org:30080/ws`
