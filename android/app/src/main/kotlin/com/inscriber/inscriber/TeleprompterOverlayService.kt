package com.inscriber.inscriber

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs

/**
 * Android 透明悬浮提词前台服务
 * - 悬浮在任意第三方 App 之上（相机、抖音、微信视频等）
 * - 支持两种滚动驱动：本地固定速率 / Flutter 后台 Sherpa-ONNX 实时 syncProgress 同步
 * - 在 Android 14+ 自动声明 specialUse|microphone 前台服务类型，防止切后台后系统静音麦克风
 */
class TeleprompterOverlayService : Service() {

    companion object {
        const val ACTION_START = "com.inscriber.action.START_OVERLAY"
        const val ACTION_UPDATE_SETTINGS = "com.inscriber.action.UPDATE_SETTINGS"
        const val ACTION_STOP = "com.inscriber.action.STOP_OVERLAY"

        const val EXTRA_TITLE = "title"
        const val EXTRA_LINES = "lines"
        const val EXTRA_CPM = "charsPerMinute"
        const val EXTRA_FONT_SIZE = "fontSize"
        const val EXTRA_VISIBLE_LINES = "visibleLines"
        const val EXTRA_ACTIVE_COLOR = "activeTextColor"
        const val EXTRA_INACTIVE_COLOR = "inactiveTextColor"
        const val EXTRA_BG_OPACITY = "backgroundOpacity"
        const val EXTRA_ENABLE_SHADOW = "enableTextShadow"
        const val EXTRA_MIRROR_MODE = "mirrorMode"
        const val EXTRA_AI_VOICE_MODE = "aiVoiceMode"

        private const val NOTIFICATION_CHANNEL_ID = "inscriber_overlay_channel"
        private const val NOTIFICATION_ID = 20261

        @Volatile
        var activeInstance: TeleprompterOverlayService? = null
            private set
    }

    private lateinit var windowManager: WindowManager
    private var rootContainer: LinearLayout? = null
    private var lyricView: LyricTeleprompterOverlayView? = null
    private var controlBar: LinearLayout? = null
    private var playPauseBtn: TextView? = null
    private var speedLabel: TextView? = null
    private var slowerBtn: TextView? = null
    private var fasterBtn: TextView? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    private val handler = Handler(Looper.getMainLooper())
    private val hideControlsRunnable = Runnable {
        controlBar?.visibility = View.GONE
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        activeInstance = this
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Inscriber 提词"
        val aiVoiceMode = intent?.getBooleanExtra(EXTRA_AI_VOICE_MODE, false) ?: false
        startForegroundSafely(title, aiVoiceMode)

        if (rootContainer == null) {
            createOverlayView()
        }

        intent?.let { applyIntentConfig(it) }
        return START_STICKY
    }

    private fun startForegroundSafely(title: String, aiVoiceMode: Boolean) {
        val notification = buildNotification(title, aiVoiceMode)
        val hasMicPerm = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val fgType = if (aiVoiceMode && hasMicPerm) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            }
            startForeground(NOTIFICATION_ID, notification, fgType)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (aiVoiceMode && hasMicPerm) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /// 由 MainActivity.syncProgress 直接在主线程调用，零 Intent 分配开销
    fun syncExternalProgress(lineProgress: Float, charRatio: Float) {
        handler.post {
            lyricView?.syncExternalProgress(lineProgress, charRatio)
        }
    }

    /// 切换外部 AI 语音跟读 / 本地固定速率模式（含麦克风被抢占时自动降级回定速）
    fun setAiVoiceMode(enabled: Boolean) {
        handler.post {
            val view = lyricView ?: return@post
            view.externalFollowMode = enabled
            updateModeControlLabels(view)
        }
    }

    private fun applyIntentConfig(intent: Intent) {
        val view = lyricView ?: return
        intent.getStringArrayListExtra(EXTRA_LINES)?.let {
            view.lines = it
            view.reset()
        }
        if (intent.hasExtra(EXTRA_CPM)) {
            view.charsPerMinute = intent.getIntExtra(EXTRA_CPM, 180)
        }
        if (intent.hasExtra(EXTRA_FONT_SIZE)) {
            view.fontSizeSp = intent.getFloatExtra(EXTRA_FONT_SIZE, 22f)
        }
        if (intent.hasExtra(EXTRA_VISIBLE_LINES)) {
            view.visibleLines = intent.getIntExtra(EXTRA_VISIBLE_LINES, 3)
        }
        if (intent.hasExtra(EXTRA_ACTIVE_COLOR)) {
            view.activeTextColor = intent.getIntExtra(EXTRA_ACTIVE_COLOR, Color.WHITE)
        }
        if (intent.hasExtra(EXTRA_INACTIVE_COLOR)) {
            view.inactiveTextColor =
                intent.getIntExtra(EXTRA_INACTIVE_COLOR, 0xB3E2E8F0.toInt())
        }
        if (intent.hasExtra(EXTRA_BG_OPACITY)) {
            view.backgroundOpacity = intent.getFloatExtra(EXTRA_BG_OPACITY, 0f)
        }
        if (intent.hasExtra(EXTRA_ENABLE_SHADOW)) {
            view.enableTextShadow = intent.getBooleanExtra(EXTRA_ENABLE_SHADOW, true)
        }
        if (intent.hasExtra(EXTRA_MIRROR_MODE)) {
            view.mirrorMode = intent.getBooleanExtra(EXTRA_MIRROR_MODE, false)
        }
        if (intent.hasExtra(EXTRA_AI_VOICE_MODE)) {
            view.externalFollowMode = intent.getBooleanExtra(EXTRA_AI_VOICE_MODE, false)
        }
        updateModeControlLabels(view)
        view.invalidate()
        scheduleAutoHideControls()
    }

    private fun updateModeControlLabels(view: LyricTeleprompterOverlayView) {
        if (view.externalFollowMode) {
            speedLabel?.text = "AI语音跟读"
            speedLabel?.setTextColor(0xFF86EFAC.toInt())
            slowerBtn?.visibility = View.GONE
            fasterBtn?.visibility = View.GONE
        } else {
            speedLabel?.text = "${view.charsPerMinute}字/分"
            speedLabel?.setTextColor(0xFF93C5FD.toInt())
            slowerBtn?.visibility = View.VISIBLE
            fasterBtn?.visibility = View.VISIBLE
        }
    }

    private fun createOverlayView() {
        val metrics = resources.displayMetrics
        val overlayWidth = (metrics.widthPixels * 0.92f).toInt()

        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setBackgroundColor(Color.TRANSPARENT)
        }

        val teleprompterView = LyricTeleprompterOverlayView(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        }

        // 极简微控条（默认 2.8 秒后隐藏，避免遮挡底层界面）
        val controls = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(10), dp(6), dp(10), dp(6))
            background = GradientDrawable().apply {
                setColor(0xD820201E.toInt())
                cornerRadius = dp(20).toFloat()
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = dp(6)
            }
        }

        val playBtn = createMiniButton("暂停") {
            val playing = teleprompterView.togglePlay()
            playPauseBtn?.text = if (playing) "暂停" else "播放"
            MainActivity.notifyOverlayEvent("onOverlayPlayStateChanged", playing)
            if (playing) scheduleAutoHideControls() else handler.removeCallbacks(hideControlsRunnable)
        }
        playPauseBtn = playBtn

        val minusBtn = createMiniButton("-20") {
            val cpm = teleprompterView.adjustSpeed(-20)
            speedLabel?.text = "${cpm}字/分"
            scheduleAutoHideControls()
        }
        slowerBtn = minusBtn

        val speedTv = TextView(this).apply {
            text = "${teleprompterView.charsPerMinute}字/分"
            setTextColor(0xFF93C5FD.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setPadding(dp(6), 0, dp(6), 0)
        }
        speedLabel = speedTv

        val plusBtn = createMiniButton("+20") {
            val cpm = teleprompterView.adjustSpeed(20)
            speedLabel?.text = "${cpm}字/分"
            scheduleAutoHideControls()
        }
        fasterBtn = plusBtn

        val resetBtn = createMiniButton("重头") {
            teleprompterView.reset()
            playPauseBtn?.text = "暂停"
            MainActivity.notifyOverlayEvent("onOverlayReset")
            scheduleAutoHideControls()
        }

        val closeBtn = createMiniButton("关闭", textColor = 0xFFFCA5A5.toInt()) {
            stopSelf()
        }

        controls.addView(playBtn)
        controls.addView(minusBtn)
        controls.addView(speedTv)
        controls.addView(plusBtn)
        controls.addView(resetBtn)
        controls.addView(closeBtn)

        container.addView(teleprompterView)
        container.addView(controls)

        val windowType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        val params = WindowManager.LayoutParams(
            overlayWidth,
            WindowManager.LayoutParams.WRAP_CONTENT,
            windowType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            x = 0
            y = dp(64)
        }

        attachDragAndTapHandler(teleprompterView, params)

        rootContainer = container
        lyricView = teleprompterView
        controlBar = controls
        layoutParams = params

        windowManager.addView(container, params)
        teleprompterView.startLoop()
        scheduleAutoHideControls()
    }

    private fun attachDragAndTapHandler(
        target: View,
        params: WindowManager.LayoutParams
    ) {
        var startX = 0
        var startY = 0
        var touchX = 0f
        var touchY = 0f
        var moved = false

        target.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = params.x
                    startY = params.y
                    touchX = event.rawX
                    touchY = event.rawY
                    moved = false
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - touchX).toInt()
                    val dy = (event.rawY - touchY).toInt()
                    if (abs(dx) > 8 || abs(dy) > 8) {
                        moved = true
                        params.x = startX + dx
                        params.y = (startY + dy).coerceAtLeast(0)
                        rootContainer?.let { windowManager.updateViewLayout(it, params) }
                    }
                    true
                }

                MotionEvent.ACTION_UP -> {
                    if (!moved) {
                        toggleControlBar()
                    }
                    true
                }

                else -> false
            }
        }
    }

    private fun toggleControlBar() {
        val bar = controlBar ?: return
        if (bar.visibility == View.VISIBLE) {
            bar.visibility = View.GONE
            handler.removeCallbacks(hideControlsRunnable)
        } else {
            bar.visibility = View.VISIBLE
            scheduleAutoHideControls()
        }
    }

    private fun scheduleAutoHideControls() {
        handler.removeCallbacks(hideControlsRunnable)
        handler.postDelayed(hideControlsRunnable, 2800L)
    }

    private fun createMiniButton(
        label: String,
        textColor: Int = Color.WHITE,
        onClick: () -> Unit
    ): TextView {
        return TextView(this).apply {
            text = label
            setTextColor(textColor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
            setPadding(dp(8), dp(4), dp(8), dp(4))
            setOnClickListener { onClick() }
        }
    }

    private fun buildNotification(title: String, aiVoiceMode: Boolean): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "悬浮提词运行中",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }

        val stopIntent = Intent(this, TeleprompterOverlayService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            0,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val subtitle = if (aiVoiceMode) {
            "AI 离线语音跟随运行中，轻点悬浮文字可暂停或关闭"
        } else {
            "轻点悬浮文字可暂停或调速，点击此处可关闭"
        }

        return builder
            .setContentTitle("正在悬浮提词：$title")
            .setContentText(subtitle)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .addAction(
                Notification.Action.Builder(
                    null,
                    "关闭悬浮提词",
                    stopPendingIntent
                ).build()
            )
            .setOngoing(true)
            .build()
    }

    private fun dp(value: Int): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            resources.displayMetrics
        ).toInt()
    }

    override fun onDestroy() {
        activeInstance = null
        handler.removeCallbacks(hideControlsRunnable)
        lyricView?.stopLoop()
        rootContainer?.let {
            try {
                windowManager.removeView(it)
            } catch (_: Exception) {
            }
        }
        rootContainer = null
        lyricView = null
        controlBar = null
        MainActivity.notifyOverlayEvent("onOverlayStopped")
        super.onDestroy()
    }
}
