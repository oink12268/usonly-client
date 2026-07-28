package com.example.usonly_client

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput
import com.google.android.gms.tasks.Tasks
import com.google.firebase.auth.FirebaseAuth
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * 알림창 인라인 답장 처리 네이티브 핸들러.
 *
 * flutter_local_notifications 백그라운드 isolate는 Android 14+(One UI 7)에서
 * 새 Flutter 엔진 시작이 차단되어 핸들러가 실행되지 않는 문제 발생.
 * 이 BroadcastReceiver는 Flutter 엔진 없이 순수 Kotlin으로 동작하므로 제한 없음.
 */
class NotificationReplyReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION = "com.example.usonly_client.NOTIFICATION_REPLY"
        const val KEY_REPLY = "chat_reply_input"
        const val EXTRA_UID = "uid"
        const val CHAT_NOTIF_ID = 1
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return

        val bundle = RemoteInput.getResultsFromIntent(intent) ?: return
        val replyText = bundle.getCharSequence(KEY_REPLY)?.toString()?.trim()
        if (replyText.isNullOrEmpty()) return

        // 알림 취소
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(CHAT_NOTIF_ID)

        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val cachedToken = prefs.getString("flutter.cached_firebase_token", null)
        val uid = intent.getStringExtra(EXTRA_UID)
            ?: prefs.getString("flutter.cached_user_uid", null)
            ?: return
        val apiUrl = prefs.getString("flutter.api_chats_url", "https://usonly.duckdns.org/api/chats")
            ?: "https://usonly.duckdns.org/api/chats"

        // onReceive()가 리턴하면 시스템이 이 리시버를 "완료"로 간주해 프로세스 우선순위를
        // 낮출 수 있음 — 앱이 완전히 종료된 상태에서는 아래 네트워크 스레드가 끝나기 전에
        // 프로세스가 죽어 전송이 누락될 수 있으므로 goAsync()로 완료 시점까지 붙잡아둔다.
        val pendingResult = goAsync()

        Thread {
            try {
                // SharedPreferences에 캐싱된 토큰은 Dart 쪽 백그라운드 FCM 핸들러가 갱신하는데,
                // 그 핸들러 자체가 Android 14+에서 막힐 수 있어 토큰이 만료된 채로 남아있는 경우가
                // 있었다(답장이 401로 조용히 실패). FirebaseAuth SDK는 Flutter 엔진과 무관하게
                // 프로세스 시작 시 자체적으로 로그인 상태를 복원하므로, 여기서 직접 최신 토큰을
                // 받아온다(SDK가 필요할 때만 네트워크 갱신하므로 매번 강제 리프레시하지 않음).
                val token = fetchFreshToken() ?: cachedToken ?: return@Thread

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
                    responseCode
                    disconnect()
                }
            } catch (_: Exception) {
            } finally {
                pendingResult.finish()
            }
        }.start()
    }

    // FirebaseAuth SDK로부터 유효한 ID 토큰을 동기적으로 받아온다.
    // 로그인된 유저가 없거나 네트워크 타임아웃 등으로 실패하면 null (호출부에서 캐시로 폴백).
    private fun fetchFreshToken(): String? {
        return try {
            val user = FirebaseAuth.getInstance().currentUser ?: return null
            val result = Tasks.await(user.getIdToken(false), 10, TimeUnit.SECONDS)
            result?.token
        } catch (_: Exception) {
            null
        }
    }
}
