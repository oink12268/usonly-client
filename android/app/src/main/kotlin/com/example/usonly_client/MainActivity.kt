package com.example.usonly_client

import android.app.NotificationManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.usonly_client/share"
    private val BADGE_CHANNEL = "com.example.usonly_client/badge"
    private var pendingShare: Map<String, Any?>? = null
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "getSharedData" -> {
                    result.success(pendingShare)
                    pendingShare = null
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BADGE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateBadge" -> {
                        val count = call.argument<Int>("count") ?: 0
                        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        if (count > 0) {
                            // 뱃지 홀더 알림 게시 (삼성 최신 OS에서 알림 없으면 뱃지 0으로 강제됨)
                            NotificationReplyReceiver.postBadgeNotification(this)
                            NotificationReplyReceiver.setSamsungBadge(this, count)
                        } else {
                            // 뱃지 홀더 알림 취소 + Samsung ContentProvider 초기화
                            nm.cancel(NotificationReplyReceiver.BADGE_NOTIF_ID)
                            NotificationReplyReceiver.setSamsungBadge(this, 0)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // onResume에서 뱃지를 지우면 안 됨.
    // 앱이 포그라운드로 와도 채팅을 읽기 전까지 뱃지는 유지해야 함.
    // 뱃지 제거는 Flutter clearChatNotifications() → updateBadge(0) 경로로만 처리.

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
        methodChannel?.invokeMethod("sharedDataReceived", pendingShare)
        pendingShare = null
    }

    private fun handleIntent(intent: Intent) {
        when (intent.action) {
            Intent.ACTION_SEND -> {
                if (intent.type?.startsWith("text/") == true) {
                    val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                    if (text != null) {
                        pendingShare = mapOf("type" to "text", "text" to text)
                    }
                } else if (intent.type?.startsWith("image/") == true) {
                    val uri = getParcelableUri(intent)
                    val path = uri?.let { copyUriToCache(it) }
                    if (path != null) {
                        pendingShare = mapOf("type" to "images", "paths" to listOf(path))
                    }
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                if (intent.type?.startsWith("image/") == true) {
                    val uris = getParcelableUriList(intent)
                    val paths = uris?.mapNotNull { copyUriToCache(it) } ?: emptyList()
                    if (paths.isNotEmpty()) {
                        pendingShare = mapOf("type" to "images", "paths" to paths)
                    }
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun getParcelableUri(intent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
    }

    @Suppress("DEPRECATION")
    private fun getParcelableUriList(intent: Intent): ArrayList<Uri>? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        }
    }

    private fun copyUriToCache(uri: Uri): String? {
        return try {
            val inputStream = contentResolver.openInputStream(uri) ?: return null
            val fileName = getFileNameFromUri(uri) ?: "shared_${System.currentTimeMillis()}.jpg"
            val cacheFile = File(cacheDir, "shared_$fileName")
            cacheFile.outputStream().use { output -> inputStream.copyTo(output) }
            cacheFile.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    private fun getFileNameFromUri(uri: Uri): String? {
        if (uri.scheme == "content") {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) return cursor.getString(idx)
                }
            }
        }
        return uri.path?.substringAfterLast('/')
    }
}
