package com.inscriber.inscriber

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL_NAME = "com.inscriber/overlay"
        private val mainHandler = Handler(Looper.getMainLooper())

        @Volatile
        private var overlayChannel: MethodChannel? = null

        /// 原生悬浮窗反向通知 Flutter（暂停/继续、重头、关闭），确保后台 Sherpa-ONNX 同步启停
        fun notifyOverlayEvent(method: String, arguments: Any? = null) {
            mainHandler.post {
                overlayChannel?.invokeMethod(method, arguments)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME
        )
        overlayChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> {
                    result.success(hasOverlayPermission())
                }

                "requestPermission" -> {
                    requestOverlayPermission()
                    result.success(true)
                }

                "startOverlay" -> {
                    if (!hasOverlayPermission()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val lines = call.argument<List<String>>("lines") ?: listOf("（暂无提词内容）")
                    val intent = Intent(this, TeleprompterOverlayService::class.java).apply {
                        action = TeleprompterOverlayService.ACTION_START
                        putStringArrayListExtra(
                            TeleprompterOverlayService.EXTRA_LINES,
                            ArrayList(lines)
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_TITLE,
                            call.argument<String>("title") ?: "Inscriber 提词"
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_CPM,
                            call.argument<Int>("charsPerMinute") ?: 180
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_FONT_SIZE,
                            (call.argument<Double>("fontSize") ?: 22.0).toFloat()
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_VISIBLE_LINES,
                            call.argument<Int>("visibleLines") ?: 3
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_ACTIVE_COLOR,
                            (call.argument<Number>("activeTextColor")?.toLong()
                                ?: 0xFFFFFFFFL).toInt()
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_INACTIVE_COLOR,
                            (call.argument<Number>("inactiveTextColor")?.toLong()
                                ?: 0xB3E2E8F0L).toInt()
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_BG_OPACITY,
                            (call.argument<Double>("backgroundOpacity") ?: 0.0).toFloat()
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_ENABLE_SHADOW,
                            call.argument<Boolean>("enableTextShadow") ?: true
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_MIRROR_MODE,
                            call.argument<Boolean>("mirrorMode") ?: false
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_AI_VOICE_MODE,
                            call.argument<Boolean>("aiVoiceMode") ?: false
                        )
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }

                "syncProgress" -> {
                    val lineProgress = (call.argument<Number>("progress")?.toFloat()) ?: 0f
                    val charRatio = (call.argument<Number>("charRatio")?.toFloat()) ?: -1f
                    TeleprompterOverlayService.activeInstance?.syncExternalProgress(
                        lineProgress = lineProgress,
                        charRatio = charRatio
                    )
                    result.success(true)
                }

                "setAiVoiceMode" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    TeleprompterOverlayService.activeInstance?.setAiVoiceMode(enabled)
                    result.success(true)
                }

                "updateSettings" -> {
                    val intent = Intent(this, TeleprompterOverlayService::class.java).apply {
                        action = TeleprompterOverlayService.ACTION_UPDATE_SETTINGS
                        putExtra(
                            TeleprompterOverlayService.EXTRA_CPM,
                            call.argument<Int>("charsPerMinute") ?: 180
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_FONT_SIZE,
                            (call.argument<Double>("fontSize") ?: 22.0).toFloat()
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_VISIBLE_LINES,
                            call.argument<Int>("visibleLines") ?: 3
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_ACTIVE_COLOR,
                            (call.argument<Number>("activeTextColor")?.toLong()
                                ?: 0xFFFFFFFFL).toInt()
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_INACTIVE_COLOR,
                            (call.argument<Number>("inactiveTextColor")?.toLong()
                                ?: 0xB3E2E8F0L).toInt()
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_BG_OPACITY,
                            (call.argument<Double>("backgroundOpacity") ?: 0.0).toFloat()
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_ENABLE_SHADOW,
                            call.argument<Boolean>("enableTextShadow") ?: true
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_MIRROR_MODE,
                            call.argument<Boolean>("mirrorMode") ?: false
                        )
                        putExtra(
                            TeleprompterOverlayService.EXTRA_AI_VOICE_MODE,
                            call.argument<Boolean>("aiVoiceMode") ?: false
                        )
                    }
                    startService(intent)
                    result.success(true)
                }

                "stopOverlay" -> {
                    stopService(Intent(this, TeleprompterOverlayService::class.java))
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        overlayChannel = null
        super.onDestroy()
    }

    private fun hasOverlayPermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)
    }

    private fun requestOverlayPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName")
            )
            startActivity(intent)
        }
    }
}
