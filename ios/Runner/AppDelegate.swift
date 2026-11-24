import AVKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    private let channelName = "com.inscriber/overlay"

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        if let controller = window?.rootViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(
                name: channelName,
                binaryMessenger: controller.binaryMessenger
            )

            channel.setMethodCallHandler { [weak controller] call, result in
                guard #available(iOS 15.0, *) else {
                    result(FlutterError(
                        code: "UNSUPPORTED_IOS",
                        message: "画中画提词需要 iOS 15.0 及以上系统",
                        details: nil
                    ))
                    return
                }

                switch call.method {
                case "hasPermission":
                    result(PiPTeleprompterManager.shared.isSupported)

                case "requestPermission":
                    result(true)

                case "startOverlay":
                    guard let parentView = controller?.view,
                          let args = call.arguments as? [String: Any] else {
                        result(false)
                        return
                    }
                    let lines = args["lines"] as? [String] ?? ["（暂无提词内容）"]
                    let cpm = args["charsPerMinute"] as? Int ?? 180
                    let fontSize = CGFloat((args["fontSize"] as? Double) ?? 22.0)
                    let visibleLines = args["visibleLines"] as? Int ?? 3
                    let activeColor = (args["activeTextColor"] as? NSNumber)?.uint32Value ?? 0xFFFFFFFF
                    let inactiveColor = (args["inactiveTextColor"] as? NSNumber)?.uint32Value ?? 0xB3E2E8F0
                    let mirrorMode = args["mirrorMode"] as? Bool ?? false

                    let started = PiPTeleprompterManager.shared.start(
                        in: parentView,
                        lines: lines,
                        charsPerMinute: cpm,
                        fontSize: fontSize,
                        visibleLines: visibleLines,
                        activeColorHex: activeColor,
                        inactiveColorHex: inactiveColor,
                        mirrorMode: mirrorMode
                    )
                    result(started)

                case "updateSettings":
                    guard let args = call.arguments as? [String: Any] else {
                        result(false)
                        return
                    }
                    PiPTeleprompterManager.shared.updateSettings(
                        charsPerMinute: args["charsPerMinute"] as? Int ?? 180,
                        fontSize: CGFloat((args["fontSize"] as? Double) ?? 22.0),
                        visibleLines: args["visibleLines"] as? Int ?? 3,
                        activeColorHex: (args["activeTextColor"] as? NSNumber)?.uint32Value ?? 0xFFFFFFFF,
                        inactiveColorHex: (args["inactiveTextColor"] as? NSNumber)?.uint32Value ?? 0xB3E2E8F0,
                        mirrorMode: args["mirrorMode"] as? Bool ?? false
                    )
                    result(true)

                case "stopOverlay":
                    PiPTeleprompterManager.shared.stop()
                    result(true)

                default:
                    result(FlutterMethodNotImplemented)
                }
            }
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
