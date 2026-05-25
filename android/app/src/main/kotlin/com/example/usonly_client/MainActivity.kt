package com.example.usonly_client

import android.content.ContentValues
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
                        updateSamsungBadge(count)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Samsung One UI 뱃지 카운트를 알림과 독립적으로 설정.
    // 알림이 없어도 뱃지가 유지되고, 알림을 스와이프해도 뱃지가 살아있음.
    private fun updateSamsungBadge(count: Int) {
        try {
            val uri = Uri.parse("content://com.sec.badge/apps")
            contentResolver.delete(uri, "package=?", arrayOf(packageName))
            if (count > 0) {
                val values = ContentValues()
                values.put("package", packageName)
                values.put("class", this.javaClass.name)
                values.put("badgecount", count)
                contentResolver.insert(uri, values)
            }
        } catch (e: Exception) {
            // Samsung 기기가 아니거나 API 미지원 → 무시
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 키보드 높이 실시간 전달 (WindowInsetsAnimationCallback 활성화)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
        // 앱이 이미 실행 중일 때 공유 → Flutter에 즉시 push
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
