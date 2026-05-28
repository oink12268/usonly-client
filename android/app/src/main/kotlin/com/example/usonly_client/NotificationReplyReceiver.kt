package com.example.usonly_client

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.RemoteInput
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * 알림창 인라인 답장 / 알림 스와이프 처리 네이티브 핸들러.
 *
 * flutter_local_notifications 백그라운드 isolate는 Android 14+(One UI 7)에서
 * 새 Flutter 엔진 시작이 차단되어 핸들러가 실행되지 않는 문제 발생.
 * 이 BroadcastReceiver는 Flutter 엔진 없이 순수 Kotlin으로 동작하므로 제한 없음.
 *
 * 흐름:
 *  CustomFcmService → 네이티브 알림 표시
 *    ├── 답장 action  → ACTION (NOTIFICATION_REPLY)  → HTTP POST + 뱃지 초기화
 *    └── 스와이프     → ACTION_DISMISS               → 뱃지 재설정 (메시지 미읽음)
 */
class NotificationReplyReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION = "com.example.usonly_client.NOTIFICATION_REPLY"
        const val ACTION_DISMISS = "com.example.usonly_client.NOTIFICATION_DISMISS"
        const val KEY_REPLY = "chat_reply_input"
        const val EXTRA_UID = "uid"
        const val CHAT_NOTIF_ID = 1

        /**
         * Samsung ContentProvider 뱃지를 알림과 독립적으로 설정/해제.
         * count=0 이면 뱃지 제거, count>0 이면 해당 값으로 설정.
         * 알림이 스와이프로 삭제되어도 ContentProvider 행은 남아 뱃지가 유지됨.
         */
        fun setSamsungBadge(context: Context, count: Int) {
            try {
                val uri = Uri.parse("content://com.sec.badge/apps")
                context.contentResolver.delete(uri, "package=?", arrayOf(context.packageName))
                if (count > 0) {
                    val cv = ContentValues()
                    cv.put("package", context.packageName)
                    cv.put(
                        "class",
                        context.packageManager
                            .getLaunchIntentForPackage(context.packageName)
                            ?.component?.className
                            ?: "${context.packageName}.MainActivity"
                    )
                    cv.put("badgecount", count)
                    context.contentResolver.insert(uri, cv)
                }
            } catch (_: Exception) {}
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        // 알림 스와이프(삭제) → 메시지는 아직 안 읽음 → 뱃지 재설정 후 종료
        if (intent.action == ACTION_DISMISS) {
            setSamsungBadge(context, 1)
            return
        }

        // RemoteInput에서 답장 텍스트 추출
        val bundle = RemoteInput.getResultsFromIntent(intent) ?: return
        val replyText = bundle.getCharSequence(KEY_REPLY)?.toString()?.trim()
        if (replyText.isNullOrEmpty()) return

        // 알림 즉시 취소 → "Sending..." 스피너 제거
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(CHAT_NOTIF_ID)

        // Samsung 뱃지 초기화 (답장 완료 = 읽음)
        setSamsungBadge(context, 0)

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
