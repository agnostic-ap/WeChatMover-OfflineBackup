import Foundation
import AppKit

/// TCC 权限检测与系统设置深链。
enum PermissionHelper {
    static let fullDiskAccessURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    /// 能否读取微信容器（无完全磁盘访问权限时读取会失败/为空）。
    static func canReadContainer(path: String) -> Bool {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: path) else { return false }
        return (try? fm.contentsOfDirectory(atPath: path)) != nil
    }

    static func openFullDiskAccess() {
        if let url = URL(string: fullDiskAccessURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
