package com.example.usonly_client

import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // WindowInsetsAnimationCallback 활성화:
        // 이게 없으면 adjustNothing 상태에서 Flutter가 키보드 height를 실시간으로 못 받음
        // → 키보드 애니메이션 완료 후 한꺼번에 body resize → "닿았다가 뒤늦게 올라가는" 동작
        // 이 설정으로 키보드 height가 프레임마다 Flutter에 전달 → body가 키보드와 함께 부드럽게 이동
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }
}
