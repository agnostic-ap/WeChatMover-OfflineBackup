import Foundation
import AppKit

struct WeChatInfo {
    var isInstalled: Bool = false
    var version: String? = nil
    var isAppStoreVersion: Bool = false
    var isRunning: Bool = false
    var signatureValid: Bool? = nil
}

/// 微信本体探测：是否安装、版本、是否 App Store 版、是否运行中、签名状态。
enum WeChatDetector {
    static let defaultAppURL = URL(fileURLWithPath: "/Applications/WeChat.app")
    static let bundleID = "com.tencent.xinWeChat"
    static let officialDownloadURL = URL(string: "https://weixin.qq.com/")!

    /// 是否为 App Store 版：存在 Contents/_MASReceipt/receipt 即视为 MAS 版。
    static func isAppStoreVersion(appURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: appURL.appendingPathComponent("Contents/_MASReceipt/receipt").path
        )
    }

    static func version(appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    static func detect(appURL: URL = WeChatDetector.defaultAppURL) -> WeChatInfo {
        let installed = FileManager.default.fileExists(atPath: appURL.path)
        var info = WeChatInfo()
        info.isInstalled = installed
        if installed {
            info.version = version(appURL: appURL)
            info.isAppStoreVersion = isAppStoreVersion(appURL: appURL)
        }
        info.isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        return info
    }

    /// 只读校验签名是否有效（codesign --verify，不写）。
    static func checkSignature(appURL: URL = WeChatDetector.defaultAppURL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
