import Foundation
import AppKit

/// TCC 权限检测与系统设置深链。
enum PermissionHelper {
    static let fullDiskAccessURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    static let screenRecordingURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    static let microphoneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    static let appManagementURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AppManagement"

    /// 能否读取微信容器（无完全磁盘访问权限时读取会失败/为空）。
    static func canReadContainer(path: String) -> Bool {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: path) else { return false }
        return (try? fm.contentsOfDirectory(atPath: path)) != nil
    }

    static func openSettings(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    static func openFullDiskAccess() { openSettings(fullDiskAccessURL) }
    static func openScreenRecording() { openSettings(screenRecordingURL) }
    static func openMicrophone() { openSettings(microphoneURL) }
    static func openAppManagement() { openSettings(appManagementURL) }
}
