import Foundation
import AppKit

struct WeChatInfo: Sendable {
    var isInstalled: Bool = false
    var version: String? = nil       // CFBundleShortVersionString
    var build: String? = nil         // CFBundleVersion
    var isAppStoreVersion: Bool = false
    var isRunning: Bool = false
}

/// 微信本体探测：是否安装、版本/build、是否 App Store 版、是否运行中。
/// 本工具不修改微信、不重签名，仅只读检测。
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

    static func versionAndBuild(appURL: URL) -> (version: String?, build: String?) {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) else { return (nil, nil) }
        return (dict["CFBundleShortVersionString"] as? String,
                dict["CFBundleVersion"] as? String)
    }

    /// 微信是否正在运行（NSRunningApplication 查询，毫秒级，任意线程可调）。
    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func detect(appURL: URL = WeChatDetector.defaultAppURL) -> WeChatInfo {
        let installed = FileManager.default.fileExists(atPath: appURL.path)
        var info = WeChatInfo()
        info.isInstalled = installed
        if installed {
            let vb = versionAndBuild(appURL: appURL)
            info.version = vb.version
            info.build = vb.build
            info.isAppStoreVersion = isAppStoreVersion(appURL: appURL)
        }
        info.isRunning = isRunning()
        return info
    }
}
