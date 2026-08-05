import Foundation

/// codesign 封装 + osascript 提权执行。
enum CodeSigner {
    static let wechatAppPath = "/Applications/WeChat.app"

    /// 需要在管理员密码框中执行的 shell 命令。
    static var shellCommand: String {
        "codesign --sign - --force --deep \(wechatAppPath)"
    }

    /// 完整的 osascript AppleScript 源码（弹系统密码框提权）。
    static var appleScriptSource: String {
        "do shell script \"\(shellCommand)\" with administrator privileges"
    }

    /// 弹出系统密码框，对微信执行 ad-hoc 重签名。返回错误信息（成功为 nil）。
    @discardableResult
    static func resignWeChat() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScriptSource]
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "无法启动提权工具：\(error.localizedDescription)"
        }
        guard process.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if err.contains("User canceled") || err.contains("(-128)") { return "已取消授权" }
            return "签名失败：\(err.isEmpty ? "退出码 \(process.terminationStatus)" : err)"
        }
        return nil
    }
}
