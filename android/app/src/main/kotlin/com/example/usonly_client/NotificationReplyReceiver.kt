package com.example.usonly_client

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.RemoteInput
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * 알림창 인라인 답장 처리 네이티브 핸들러.
 *
 * flutter_local_notifications 백그라운드 isolate는 Android 14+(One UI 7)에서
 * 새 Flutter 엔진 시작이 차단되어 핸들러가 실행되지 않는 문제 발생.
 * 이 BroadcastReceiver는 Flutter 엔진 없이 순수 Kotlin으로 동작하므로 제한 없음.
 *
 * 흐름:
 *  CustomFcmService → 네이티브 알림 표시 (답장 action → 이 Receiver)
 *  → 알림 cancel → HTTP POST → 완료
 */
class NotificationReplyReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION = "com.example.usonly_client.NOTIFICATION_REPLY"
        const val KEY_REPLY = "chat_reply_input"
        const val EXTRA_UID = "uid"
        const val CHAT_NOTIF_ID = 1
    }

    override fun onReceive(context: Context, intent: Intent) {
        // RemoteInput에서 답장 텍스트 추출
        val bundle = RemoteInput.getResultsFromIntent(intent) ?: return
        val replyText = bundle.getCharSequence(KEY_REPLY)?.toString()?.trim()
        if (replyText.isNullOrEmpty()) return

        // 알림 즉시 취소 → "Sending..." 스피너 제거
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(CHAT_NOTIF_ID)

        // Samsung 뱃지도 초기화
        try {
            context.contentResolver.delete(
                Uri.parse("content://com.sec.badge/apps"),
                "package=?", arrayOf(context.packageName)
            )
        } catch (_: Exception) {}

        // Flutter SharedPreferences: 'FlutterSharedPreferences' 파일, "flutter." prefix
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val token = prefs.getString("flutter.cached_firebase_token", null) ?: return
        val uid = intent.getStringExtra(EXTRA_UID)
            ?: prefs.getString("flutter.cached_user_uid", null)
            ?: return
        val apiUrl = prefs.getString("flutter.api_chats_url", "https://usonly.duckdns.org/api/chats")
            ?: "https://usonly.duckdns.org/api/chats"

        // 백그라운드 스레드에서 HTTP POST
        Thread {
            try {
                val body = JSONObject().apply {
                    put("message", replyText)
                    put("writerUid", uid)
                }.toString()

                val url = URL(apiUrl)
                (url.openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    setRequestProperty("Content-Type", "application/json; charset=utf-8")
                    setRequestProperty("Authorization", "Bearer $token")
                    doOutput = true
                    connectTimeout = 15_000
                    readTimeout = 15_000
                    outputStream.use { out -> out.write(body.toByteArray(Charsets.UTF_8)) }
                    responseCode // 요청 실행
                    disconnect()
                }
            } catch (_: Exception) {}
        }.start()
    }
}
