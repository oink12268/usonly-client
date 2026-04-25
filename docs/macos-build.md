# macOS 빌드 가이드

## 개요

UsOnly 앱의 macOS 네이티브 빌드 설정 및 알려진 이슈/해결책 문서.

> **참고**: macOS는 Android/iOS/Windows 이후 추가된 플랫폼이며, macOS 26 베타 환경에서 특수한 우회 처리가 적용되어 있습니다.

---

## 빌드 방법

```bash
# 의존성 설치
flutter pub get
cd macos && pod install && cd ..

# 실행
flutter run -d macos

# 릴리즈 빌드
flutter build macos --release
```

### 사전 요구사항

- Xcode 설치 및 라이선스 동의: `sudo xcodebuild -license accept`
- Xcode 개발자 도구 설정: `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`
- CocoaPods: Homebrew Ruby 필요 (`brew install ruby` → `gem install cocoapods`)
- `firebase_options.dart` 생성: `flutterfire configure` (macOS 포함 선택)

---

## 적용된 설정

### 코드 서명

- **팀 ID**: `3V2TWU95TH`
- **서명 방식**: Automatic (Apple Development 인증서 자동 선택)
- `macos/Runner.xcodeproj/project.pbxproj`에 `DEVELOPMENT_TEAM = 3V2TWU95TH` 설정됨

### Entitlements (`macos/Runner/DebugProfile.entitlements`)

```xml
<key>com.apple.security.app-sandbox</key>
<false/>
<key>com.apple.security.cs.allow-jit</key>
<true/>
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.example.usonlyClient</string>
</array>
```

> `app-sandbox = false`: macOS 26 베타 keychain 이슈 우회 목적  
> `cs.disable-library-validation`: fishhook 동작에 필요

### Firebase 초기화 (`macos/Runner/AppDelegate.swift`)

```swift
FirebaseApp.configure()
try? Auth.auth().useUserAccessGroup("3V2TWU95TH.com.example.usonlyClient")
```

### macOS 배포 타겟

- `Podfile`: `platform :osx, '11.0'`
- `project.pbxproj`: `MACOSX_DEPLOYMENT_TARGET = 11.0`
- `gal` 패키지가 macOS 11.0 이상 요구

### Google Sign-In URL 스킴 (`macos/Runner/Info.plist`)

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>com.googleusercontent.apps.246087463229-jm6jg37qt4n8ndss4mo2bflnqamm3a52</string>
        </array>
    </dict>
</array>
```

---

## macOS 26 베타 Firebase Auth Keychain 우회

### 문제

macOS 26 베타에서 Firebase Auth가 keychain에 토큰을 저장할 때 `errSecMissingEntitlement (-34018)` 에러 발생. 샌드박스 on/off, entitlement 변경, `kSecUseDataProtectionKeychain` 추가 등 표준 방법으로는 해결 불가.

### 해결책: KeychainFix 로컬 Pod

`macos/LocalPods/KeychainFix/`에 위치한 로컬 CocoaPods 팟.

**동작 방식**:
1. [fishhook](https://github.com/facebook/fishhook)을 사용해 `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, `SecItemDelete` 함수를 런타임에 후킹
2. 실제 keychain 호출 시도 → 실패하면 **NSUserDefaults를 가짜 keychain으로 사용**
3. `+load` 메서드로 앱 시작 시 자동 설치 (AppDelegate 수정 불필요)

**Podfile 설정**:
```ruby
pod 'KeychainFix', :path => 'LocalPods/KeychainFix'
```

> **주의**: 이 방식은 Firebase 토큰을 암호화 없이 NSUserDefaults에 저장합니다. 개발/테스트 용도로만 사용하고, 프로덕션 배포 전 Firebase 공식 macOS 26 지원을 확인하세요.

### Google Sign-In 우회

macOS에서 `google_sign_in` 패키지의 GIDSignIn도 keychain 이슈가 있어 별도 처리.  
**Windows와 동일한 PKCE OAuth 플로우**(브라우저 기반)를 사용.

`lib/auth_service.dart`:
```dart
if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.windows ||
                defaultTargetPlatform == TargetPlatform.macOS)) {
  return await _signInWindowsGoogle();
}
```

로그인 시 브라우저가 열리고 `localhost` 콜백으로 토큰을 받습니다.

---

## 플랫폼별 기능 차이

| 기능 | Android/iOS | Windows | macOS |
|------|-------------|---------|-------|
| Google 로그인 | GIDSignIn | PKCE OAuth | PKCE OAuth |
| 파일 다운로드 | gal (갤러리) | 다운로드 폴더 | 다운로드 폴더 |
| FCM 푸시 알림 | O | X (WebSocket) | X (WebSocket) |
| keychain 저장 | 네이티브 | 해당 없음 | UserDefaults (우회) |

---

## 알려진 이슈

- **macOS 26 베타 전용 우회**: Firebase 공식 SDK가 macOS 26을 지원하면 `KeychainFix` 팟 제거 후 표준 keychain 방식으로 전환 필요
- **KeyboardEvent 경고**: macOS 26 베타에서 `A KeyDownEvent is dispatched, but the state shows...` 경고 간헐적 발생. Flutter 엔진 버그이며 동작에는 영향 없음
- **`Failed to foreground app; open returned 1`**: `flutter run` 실행 시 표시되는 경고. 앱 실행 자체는 정상
