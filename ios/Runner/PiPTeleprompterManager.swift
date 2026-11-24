import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import UIKit

/// iOS 画中画（PiP）3 行歌词式提词渲染管理器
/// 使用合规的 AVSampleBufferDisplayLayer + AVPictureInPictureController：
/// 按 30fps 将 3 行歌词滚动画面离屏渲染成 CVPixelBuffer 推入画中画窗口
@available(iOS 15.0, *)
final class PiPTeleprompterManager: NSObject,
    AVPictureInPictureControllerDelegate,
    AVPictureInPictureSampleBufferPlaybackDelegate
{
    static let shared = PiPTeleprompterManager()

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var hostContainerView: UIView?
    private var pipController: AVPictureInPictureController?
    private var displayLink: CADisplayLink?

    private var rawLines: [String] = ["（暂无提词内容）"]
    private var lines: [String] = ["（暂无提词内容）"]
    private var charsPerMinute: Int = 180
    private var fontSize: CGFloat = 22
    private var visibleLines: Int = 3
    private var activeColor: UIColor = .white
    private var inactiveColor: UIColor = UIColor(white: 0.85, alpha: 0.65)
    private var mirrorMode: Bool = false

    private var progress: Double = 0.0
    private var isPlaying: Bool = true
    private var lastTimestamp: CFTimeInterval = 0

    // PiP 视频帧分辨率（16:7 宽扁比例，适合贴近手机顶部摄像头展示 3 行文字）
    private let frameWidth = 640
    private let frameHeight = 260

    var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    func start(
        in parentView: UIView,
        lines: [String],
        charsPerMinute: Int,
        fontSize: CGFloat,
        visibleLines: Int,
        activeColorHex: UInt32,
        inactiveColorHex: UInt32,
        mirrorMode: Bool
    ) -> Bool {
        guard isSupported else { return false }

        self.rawLines = lines.isEmpty ? ["（暂无提词内容）"] : lines
        self.charsPerMinute = max(60, min(480, charsPerMinute))
        self.fontSize = max(14, min(40, fontSize))
        self.visibleLines = max(1, min(5, visibleLines))
        self.activeColor = Self.color(fromARGB: activeColorHex)
        self.inactiveColor = Self.color(fromARGB: inactiveColorHex)
        self.mirrorMode = mirrorMode
        self.lines = rewrapLinesForFrame(self.rawLines)
        self.progress = 0.0
        self.isPlaying = true
        self.lastTimestamp = 0

        configureAudioSession()
        setupDisplayLayerIfNeeded(in: parentView)
        startRenderLoop()

        // 延迟 120ms 等待首帧写入 displayLayer 后再拉起 PiP
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let controller = self.pipController else { return }
            if !controller.isPictureInPictureActive {
                controller.startPictureInPicture()
            }
        }
        return true
    }

    func updateSettings(
        charsPerMinute: Int,
        fontSize: CGFloat,
        visibleLines: Int,
        activeColorHex: UInt32,
        inactiveColorHex: UInt32,
        mirrorMode: Bool
    ) {
        self.charsPerMinute = max(60, min(480, charsPerMinute))
        self.fontSize = max(14, min(40, fontSize))
        self.visibleLines = max(1, min(5, visibleLines))
        self.activeColor = Self.color(fromARGB: activeColorHex)
        self.inactiveColor = Self.color(fromARGB: inactiveColorHex)
        self.mirrorMode = mirrorMode
        self.lines = rewrapLinesForFrame(self.rawLines)
    }

    /// 按画中画实际宽度自动换行，避免任何文字被截断为“...”
    private func rewrapLinesForFrame(_ source: [String]) -> [String] {
        let maxTextWidth = CGFloat(frameWidth - 56)
        let activeFont = UIFont.systemFont(ofSize: fontSize * 1.45 * 1.04, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: activeFont]
        var result: [String] = []

        for raw in source {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if (trimmed as NSString).size(withAttributes: attrs).width <= maxTextWidth {
                result.append(trimmed)
                continue
            }
            var current = ""
            for ch in trimmed {
                let candidate = current + String(ch)
                if !current.isEmpty && (candidate as NSString).size(withAttributes: attrs).width > maxTextWidth {
                    result.append(current)
                    current = String(ch)
                } else {
                    current = candidate
                }
            }
            if !current.isEmpty {
                result.append(current)
            }
        }
        return result.isEmpty ? ["（暂无提词内容）"] : result
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        if let controller = pipController, controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        }
        displayLayer?.flushAndRemoveImage()
        hostContainerView?.removeFromSuperview()
        hostContainerView = nil
        displayLayer = nil
        pipController = nil
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func setupDisplayLayerIfNeeded(in parentView: UIView) {
        if pipController != nil { return }

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        container.alpha = 0.01
        container.isUserInteractionEnabled = false
        parentView.addSubview(container)

        let layer = AVSampleBufferDisplayLayer()
        layer.frame = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        layer.videoGravity = .resizeAspect
        container.layer.addSublayer(layer)

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true

        hostContainerView = container
        displayLayer = layer
        pipController = controller
    }

    private func startRenderLoop() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(onDisplayLink(_:)))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func onDisplayLink(_ link: CADisplayLink) {
        if lastTimestamp > 0 && isPlaying {
            let dt = link.timestamp - lastTimestamp
            advanceProgress(dt: dt)
        }
        lastTimestamp = link.timestamp
        renderAndEnqueueCurrentFrame()
    }

    private func maxProgress() -> Double {
        Double(max(0, lines.count - 1))
    }

    private func advanceProgress(dt: Double) {
        guard dt > 0, lines.count > 1 else { return }
        let idx = max(0, min(lines.count - 1, Int(floor(progress))))
        let lineDuration = secondsForLine(idx)
        let next = progress + dt / lineDuration
        if next >= maxProgress() {
            progress = maxProgress()
            isPlaying = false
            pipController?.invalidatePlaybackState()
        } else {
            progress = next
        }
    }

    private func secondsForLine(_ index: Int) -> Double {
        let text = lines[index]
        var units = 0.0
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            units += scalar.value <= 0x007F ? 0.55 : 1.0
        }
        let readable = max(1.0, ceil(units))
        let cps = Double(charsPerMinute) / 60.0
        return max(0.85, min(25.0, readable / cps))
    }

    private func renderAndEnqueueCurrentFrame() {
        guard let layer = displayLayer else { return }
        if layer.status == .failed {
            layer.flush()
        }
        guard let pixelBuffer = renderLyricPixelBuffer() else { return }
        guard let sampleBuffer = makeSampleBuffer(from: pixelBuffer) else { return }
        layer.enqueue(sampleBuffer)
    }

    private func renderLyricPixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            frameWidth,
            frameHeight,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let ctx = CGContext(
            data: baseAddress,
            width: frameWidth,
            height: frameHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // 深色低干扰画中画背景
        ctx.setFillColor(UIColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1.0).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))

        // 翻转坐标系以使用 UIKit 文字绘制
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        ctx.translateBy(x: 0, y: CGFloat(frameHeight))
        ctx.scaleBy(x: 1, y: -1)
        if mirrorMode {
            ctx.translateBy(x: CGFloat(frameWidth), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }

        let scaledFont = fontSize * 1.45
        let lineHeight = scaledFont * 1.65
        let centerY = CGFloat(frameHeight) / 2.0

        let centerIdx = Int(round(progress))
        let halfSpan = (visibleLines / 2) + 2
        let startIdx = max(0, centerIdx - halfSpan)
        let endIdx = min(lines.count - 1, centerIdx + halfSpan)
        let maxVisibleDelta = Double(visibleLines) / 2.0 + 0.15

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byClipping

        for i in startIdx...endIdx {
            let delta = Double(i) - progress
            let absDelta = abs(delta)
            if absDelta >= maxVisibleDelta { continue }

            let alphaRatio: CGFloat
            if absDelta <= 0.2 {
                alphaRatio = 1.0
            } else {
                let t = CGFloat(min(1.0, max(0.0, (absDelta - 0.2) / (maxVisibleDelta - 0.2))))
                let baseFade: CGFloat = delta < 0 ? 0.38 : 0.56
                alphaRatio = absDelta <= 1.0
                    ? 1.0 - (1.0 - baseFade) * CGFloat(absDelta)
                    : baseFade * (1.0 - t)
            }

            let focus = CGFloat(1.0 - min(1.0, absDelta))
            let scale = 0.88 + 0.14 * focus
            let font = UIFont.systemFont(
                ofSize: scaledFont * scale,
                weight: focus > 0.55 ? .bold : .regular
            )
            let baseColor = focus > 0.5 ? activeColor : inactiveColor
            let drawColor = baseColor.withAlphaComponent(max(0, min(1, alphaRatio)))

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: drawColor,
                .paragraphStyle: paragraphStyle,
            ]

            let yPos = centerY + CGFloat(delta) * lineHeight - (font.lineHeight / 2.0)
            let rect = CGRect(
                x: 24,
                y: yPos,
                width: CGFloat(frameWidth - 48),
                height: lineHeight
            )
            (lines[i] as NSString).draw(in: rect, withAttributes: attrs)
        }

        return buffer
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let descStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard descStatus == noErr, let format = formatDescription else { return nil }

        let now = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sample = sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }

    private static func color(fromARGB argb: UInt32) -> UIColor {
        let a = CGFloat((argb >> 24) & 0xFF) / 255.0
        let r = CGFloat((argb >> 16) & 0xFF) / 255.0
        let g = CGFloat((argb >> 8) & 0xFF) / 255.0
        let b = CGFloat(argb & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }

    // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        if playing && progress >= maxProgress() {
            progress = 0
        }
        isPlaying = playing
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        !isPlaying
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        let deltaLines = skipInterval.seconds >= 0 ? 1.0 : -1.0
        progress = max(0.0, min(maxProgress(), progress + deltaLines))
        completionHandler()
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        stop()
    }
}
