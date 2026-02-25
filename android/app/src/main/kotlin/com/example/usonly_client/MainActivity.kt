package com.example.usonly_client

import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Edge-to-edge 모드 활성화
        // adjustResize 방식: Samsung 키보드가 창을 2번 resize (본체 + 자동완성 바) → "뚜뚝" 이중 점프
        // Edge-to-edge + adjustNothing: Android가 창 리사이즈 안 하고
        //   WindowInsetsAnimationCallback으로 키보드 높이를 프레임마다 연속 전달 → 부드러운 단일 이동
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }
}
