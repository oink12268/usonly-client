package com.example.usonly_client

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * FCM 서비스를 교체해 채팅 알림을 Kotlin에서 네이티브로 표시.
 *
 * 문제: flutter_local_notifications 백그라운드 isolate가 Android 14+(One UI 7)에서
 *       BroadcastReceiver goAsync() 제한으로 차단되어 인라인 답장이 동작하지 않음.
 * 해결: 이 Service가 알림을 직접 표시 → 답장 action이 NotificationReplyReceiver(순수 Kotlin)로
 *       전달 → Flutter 엔진 없이 완전히 Kotlin 레이어에서 처리.
 *
 * Dart firebaseMessagingBackgroundHandler는 FlutterFirebaseMessagingReceiver(독립 BroadcastReceiver)가
 * 별도로 트리거하므로, 이 Service를 교체해도 Dart 핸들러는 정상 실행됨.
 */
class CustomFcmService : FirebaseMessagingService() {

    override fun onMessageReceived(message: RemoteMessage) {
        // message.data는 Java Map<String,String> → 명시적 타입 지정으로 타입 추론 강제
        val data: Map<String, String> = message.data
        val type: String? = data["type"]
        val isChat: Boolean = (type == "chat" || type == null)
        val title: String? = data["title"]
        val body: String? = data["body"]

        // 채팅 + data-only(notification 필드 없음) + 내용 있음 → 네이티브 알림 표시
        // Dart 핸들러에서는 Android 채팅 알림 표시를 건너뜀 (중복 방지)
        if (isChat && message.notification == null && (title != null || body != null)) {
            showNativeChatNotification(title ?: "", body ?: "")
        }
        // Dart handler는 FlutterFirebaseMessagingReceiver가 별도로 트리거함 → super 불필요
    }

    private fun showNativeChatNotification(title: String, body: String) {
        // getApplicationContext(): Java-style 명시 호출로 컴파일 오류 방지
        val ctx: Context = getApplicationContext()

        // Flutter SharedPreferences: 'FlutterSharedPreferences' 파일, "flutter." prefix
        val prefs = ctx.getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE
        )
        val uid: String = prefs.getString("flutter.cached_user_uid", "") ?: ""

        // 알림 채널 생성 (이미 있으면 무시됨)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "chat_channel_v2",
                "채팅 알림",
                NotificationManager.IMPORTANCE_HIGH
            )
            channel.description = "새 채팅 메시지 알림"
            channel.enableVibration(true)
            val nm = ctx.getSystemService(NotificationManager::class.java)
            nm?.createNotificationChannel(channel)
        }

        // 인라인 답장 RemoteInput
        val remoteInput: RemoteInput = RemoteInput.Builder(NotificationReplyReceiver.KEY_REPLY)
            .setLabel("메시지를 입력하세요...")
            .build()

        // 답장 action → NotificationReplyReceiver (Flutter 엔진 없이 동작)
        val replyIntent = Intent(ctx, NotificationReplyReceiver::class.java)
        replyIntent.action = NotificationReplyReceiver.ACTION
        replyIntent.putExtra(NotificationReplyReceiver.EXTRA_UID, uid)

        val replyPendingIntent: PendingIntent = PendingIntent.getBroadcast(
            ctx, 0, replyIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        )

        val replyAction: NotificationCompat.Action =
            NotificationCompat.Action.Builder(0, "답장", replyPendingIntent)
                .addRemoteInput(remoteInput)
                .build()

        // 알림 탭 → 앱 열기
        val tapIntent: Intent? = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
        val tapPendingIntent: PendingIntent = PendingIntent.getActivity(
            ctx, 1, tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notif = NotificationCompat.Builder(ctx, "chat_channel_v2")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(tapPendingIntent)
            .addAction(replyAction)
            .setNumber(1)
            .build()

        NotificationManagerCompat.from(ctx)
            .notify(NotificationReplyReceiver.CHAT_NOTIF_ID, notif)
    }
}
