package com.inscriber.inscriber

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.util.TypedValue
import android.view.Choreographer
import android.view.View
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Android 原生 3 行歌词式透明悬浮提词渲染视图
 * - 60fps Choreographer 驱动平滑滚动
 * - 背景默认 100% 透明，只渲染居中高亮当前行及上下过渡行
 */
class LyricTeleprompterOverlayView(context: Context) : View(context) {

    private var rawLines: List<String> = listOf("（暂无提词内容）")

    var lines: List<String> = listOf("（暂无提词内容）")
        set(value) {
            rawLines = if (value.isEmpty()) listOf("（暂无提词内容）") else value
            field = wrapLinesToCurrentWidth(rawLines)
            progress = progress.coerceIn(0f, maxProgress())
            invalidate()
        }

    var charsPerMinute: Int = 180
        set(value) {
            field = value.coerceIn(60, 480)
        }

    var fontSizeSp: Float = 22f
        set(value) {
            field = value.coerceIn(14f, 40f)
            lines = rawLines
            requestLayout()
            invalidate()
        }

    var visibleLines: Int = 3
        set(value) {
            field = value.coerceIn(1, 5)
            requestLayout()
            invalidate()
        }

    var activeTextColor: Int = Color.WHITE
    var inactiveTextColor: Int = 0xB3E2E8F0.toInt()
    var backgroundOpacity: Float = 0f
    var enableTextShadow: Boolean = true
    var mirrorMode: Boolean = false

    var isPlaying: Boolean = true
        private set

    var progress: Float = 0f
        private set

    private var lastFrameNanos: Long = 0L
    private var frameLoopRunning = false

    private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val bgRect = RectF()
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
    }

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!frameLoopRunning) return
            if (lastFrameNanos != 0L && isPlaying) {
                val dtSeconds = (frameTimeNanos - lastFrameNanos) / 1_000_000_000.0f
                advanceProgress(dtSeconds)
            }
            lastFrameNanos = frameTimeNanos
            invalidate()
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    init {
        // 启用软件层阴影以确保描边阴影在透明窗口下稳定显示
        setLayerType(LAYER_TYPE_SOFTWARE, null)
        setBackgroundColor(Color.TRANSPARENT)
    }

    fun startLoop() {
        if (frameLoopRunning) return
        frameLoopRunning = true
        lastFrameNanos = 0L
        Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    fun stopLoop() {
        frameLoopRunning = false
        Choreographer.getInstance().removeFrameCallback(frameCallback)
    }

    fun togglePlay(): Boolean {
        if (isPlaying) {
            isPlaying = false
        } else {
            if (progress >= maxProgress()) {
                progress = 0f
            }
            isPlaying = true
        }
        invalidate()
        return isPlaying
    }

    fun reset() {
        progress = 0f
        isPlaying = true
        invalidate()
    }

    fun adjustSpeed(deltaCpm: Int): Int {
        charsPerMinute = (charsPerMinute + deltaCpm).coerceIn(60, 480)
        return charsPerMinute
    }

    private fun maxProgress(): Float = max(0, lines.size - 1).toFloat()

    private fun advanceProgress(dtSeconds: Float) {
        if (dtSeconds <= 0f || lines.size <= 1) return
        val currentIdx = floor(progress.toDouble()).toInt().coerceIn(0, lines.lastIndex)
        val lineDuration = secondsForLine(currentIdx)
        val next = progress + (dtSeconds / lineDuration)
        val maxP = maxProgress()
        if (next >= maxP) {
            progress = maxP
            isPlaying = false
        } else {
            progress = next
        }
    }

    private fun secondsForLine(index: Int): Float {
        val text = lines.getOrNull(index) ?: return 2.0f
        val stripped = text.replace(Regex("[\\s，。！？；：、,.!?;:]"), "")
        var units = 0.0
        for (ch in stripped) {
            units += if (ch.code <= 0x007F) 0.55 else 1.0
        }
        val readable = max(1, ceil(units).toInt())
        val cps = charsPerMinute / 60.0f
        return (readable / cps).coerceIn(0.85f, 25.0f)
    }

    private fun spToPx(sp: Float): Float {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_SP,
            sp,
            resources.displayMetrics
        )
    }

    private fun dpToPx(dp: Float): Float {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            dp,
            resources.displayMetrics
        )
    }

    fun desiredHeightPx(): Int {
        val lineHeight = spToPx(fontSizeSp) * 1.65f
        return (lineHeight * visibleLines + dpToPx(8f)).roundToInt()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w > 0 && w != oldw) {
            lines = rawLines
        }
    }

    private fun wrapLinesToCurrentWidth(source: List<String>): List<String> {
        if (width <= 0) return source
        val maxTextWidth = width - dpToPx(28f)
        if (maxTextWidth <= 40f) return source

        val measurePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = spToPx(fontSizeSp) * 1.04f
            typeface = Typeface.DEFAULT_BOLD
        }
        val wrapped = mutableListOf<String>()
        for (rawLine in source) {
            val trimmed = rawLine.trim()
            if (trimmed.isEmpty()) continue
            if (measurePaint.measureText(trimmed) <= maxTextWidth) {
                wrapped.add(trimmed)
                continue
            }
            var start = 0
            while (start < trimmed.length) {
                val count = measurePaint.breakText(
                    trimmed,
                    start,
                    trimmed.length,
                    true,
                    maxTextWidth,
                    null
                ).coerceAtLeast(1)
                val part = trimmed.substring(start, start + count).trim()
                if (part.isNotEmpty()) wrapped.add(part)
                start += count
            }
        }
        return if (wrapped.isEmpty()) listOf("（暂无提词内容）") else wrapped
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val height = desiredHeightPx()
        setMeasuredDimension(width, height)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (width == 0 || height == 0) return

        // 可选半透明底框；当 backgroundOpacity == 0 时完全不绘制底色（100% 透明）
        if (backgroundOpacity > 0.005f) {
            bgPaint.color = Color.argb(
                (backgroundOpacity.coerceIn(0f, 0.9f) * 255).roundToInt(),
                0,
                0,
                0
            )
            bgRect.set(0f, 0f, width.toFloat(), height.toFloat())
            val radius = dpToPx(14f)
            canvas.drawRoundRect(bgRect, radius, radius, bgPaint)
        }

        canvas.save()
        if (mirrorMode) {
            canvas.scale(-1f, 1f, width / 2f, height / 2f)
        }

        val baseFontSizePx = spToPx(fontSizeSp)
        val lineHeight = baseFontSizePx * 1.65f
        val centerY = height / 2f
        val centerX = width / 2f
        val maxTextWidth = width - dpToPx(24f)

        val centerIdx = progress.roundToInt()
        val halfSpan = (visibleLines / 2) + 2
        val startIdx = max(0, centerIdx - halfSpan)
        val endIdx = min(lines.lastIndex, centerIdx + halfSpan)
        val maxVisibleDelta = (visibleLines / 2f) + 0.15f

        for (i in startIdx..endIdx) {
            val delta = i - progress
            val absDelta = abs(delta)
            if (absDelta >= maxVisibleDelta) continue

            val alphaRatio = when {
                absDelta <= 0.2f -> 1.0f
                else -> {
                    val t = ((absDelta - 0.2f) / (maxVisibleDelta - 0.2f)).coerceIn(0f, 1f)
                    val baseFade = if (delta < 0f) 0.38f else 0.56f
                    if (absDelta <= 1.0f) {
                        1.0f - (1.0f - baseFade) * absDelta
                    } else {
                        baseFade * (1.0f - t)
                    }
                }
            }.coerceIn(0f, 1f)

            val focus = (1.0f - absDelta.coerceIn(0f, 1.0f))
            val scale = 0.88f + 0.14f * focus

            textPaint.textSize = baseFontSizePx * scale
            textPaint.typeface = if (focus > 0.55f) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
            textPaint.color = lerpColor(inactiveTextColor, activeTextColor, focus)
            textPaint.alpha = (Color.alpha(textPaint.color) * alphaRatio).roundToInt()

            if (enableTextShadow) {
                val shadowAlpha = (210 * alphaRatio).roundToInt()
                textPaint.setShadowLayer(
                    dpToPx(3.5f),
                    0f,
                    dpToPx(1f),
                    Color.argb(shadowAlpha, 0, 0, 0)
                )
            } else {
                textPaint.clearShadowLayer()
            }

            val fm = textPaint.fontMetrics
            val baselineY = centerY + delta * lineHeight - (fm.ascent + fm.descent) / 2f
            canvas.drawText(lines[i], centerX, baselineY, textPaint)
        }

        canvas.restore()
    }

    private fun lerpColor(startColor: Int, endColor: Int, fraction: Float): Int {
        val f = fraction.coerceIn(0f, 1f)
        val a = (Color.alpha(startColor) + (Color.alpha(endColor) - Color.alpha(startColor)) * f).roundToInt()
        val r = (Color.red(startColor) + (Color.red(endColor) - Color.red(startColor)) * f).roundToInt()
        val g = (Color.green(startColor) + (Color.green(endColor) - Color.green(startColor)) * f).roundToInt()
        val b = (Color.blue(startColor) + (Color.blue(endColor) - Color.blue(startColor)) * f).roundToInt()
        return Color.argb(a, r, g, b)
    }
}
