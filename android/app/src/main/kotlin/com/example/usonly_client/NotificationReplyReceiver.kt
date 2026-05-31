package com.example.usonly_client

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

class NotificationReplyReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION = "com.example.usonly_client.NOTIFICATION_REPLY"
        const val ACTION_DISMISS = "com.example.usonly_client.NOTIFICATION_DISMISS"
        const val KEY_REPLY = "chat_reply_input"
        const val EXTRA_UID = "uid"

        // Kotlin이 표시하는 채팅 알림 ID.
        // Dart _kChatNotifId=1 과 동일 → Flutter cancel(1)이 이 알림도 취소함.
        const val CHAT_NOTIF_ID = 1

        // 뱃지 홀더 알림 ID.
        // Dart _kOtherNotifId=2 와 충돌하지 않도록 999로 설정.
        // flutter_local_notifications.cancel(2)가 이 알림을 건드리지 않음.
        const val BADGE_NOTIF_ID = 999

        private const val BADGE_CHANNEL_ID = "badge_holder_channel"

        /**
         * 무음 뱃지 홀더 알림을 게시한다.
         *
         * 목적: 채팅 알림을 스와이프로 지워도 런처 뱃지가 살아있게 하기 위함.
         * Samsung One UI 6+ 에서는 알림이 0개이면 ContentProvider 뱃지를 덮어쓰므로
         * 활성 알림을 1개 유지하는 방식으로 우회한다.
         *
         * 채널 중요도는 IMPORTANCE_LOW (소리·팝업 없음, 뱃지 표시).
         * IMPORTANCE_MIN 은 Samsung에서 뱃지를 표시하지 않는 기기가 있어 사용하지 않음.
         */
        fun postBadgeNotification(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    BADGE_CHANNEL_ID,
                    "읽지 않은 메시지",
                    NotificationManager.IMPORTANCE_LOW  // MIN → LOW (뱃지 보장)
                ).apply {
                    setShowBadge(true)
                    enableVibration(false)
                    enableLights(false)
                    setSound(null, null)
                }
                context.getSystemService(NotificationManager::class.java)
                    ?.createNotificationChannel(channel)
            }

            val tapIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            val tapPendingIntent = PendingIntent.getActivity(
                context, 10, tapIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val notif = NotificationCompat.Builder(context, BADGE_CHANNEL_ID)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("읽지 않은 메시지")
                .setContentText("채팅 메시지를 확인하세요")
                .setSilent(true)
                .setNumber(1)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setVisibility(NotificationCompat.VISIBILITY_SECRET)
                .setContentIntent(tapPendingIntent)
                .setAutoCancel(true)  // 탭하면 자동 취소 (앱 열리면서 clearChatNotifications 호출됨)
                .build()

            NotificationManagerCompat.from(context).notify(BADGE_NOTIF_ID, notif)
        }

        /** Samsung ContentProvider 뱃지 (구형 삼성 호환 보조 수단). */
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
        // 알림 스와이프 → 아직 안 읽음 → 뱃지 홀더 알림으로 뱃지 유지
        if (intent.action == ACTION_DISMISS) {
            postBadgeNotification(context)
            setSamsungBadge(context, 1)  // 구형 삼성 보조
            return
        }

        // 인라인 답장 처리
        val bundle = RemoteInput.getResultsFromIntent(intent) ?: return
        val replyText = bundle.getCharSequence(KEY_REPLY)?.toString()?.trim()
        if (replyText.isNullOrEmpty()) return

        // 채팅 알림 + 뱃지 홀더 알림 모두 취소
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(CHAT_NOTIF_ID)
        nm.cancel(BADGE_NOTIF_ID)
        setSamsungBadge(context, 0)

        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val token = prefs.getString("flutter.cached_firebase_token", null) ?: return
        val uid = intent.getStringExtra(EXTRA_UID)
            ?: prefs.getString("flutter.cached_user_uid", null)
            ?: return
        val apiUrl = prefs.getString("flutter.api_chats_url", "https://usonly.duckdns.org/api/chats")
            ?: "https://usonly.duckdns.org/api/chats"

        Thread {
            try {
                val body = JSONObject().apply {
                    put("message", replyText)
                    put("writerUid", uid)
                }.toString()
                val url = java.net.URL(apiUrl)
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
            } catch (_: Exception) {}
        }.start()
    }
}
