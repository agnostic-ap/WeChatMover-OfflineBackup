import Foundation

/// codesign 封装 + osascript 提权执行（异步等待进程真正退出，不阻塞主线程）。
enum CodeSigner {
    static let wechatAppPath = "/Applications/WeChat.app"

    /// 提权执行的三种结果：成功 / 用户在密码框取消 / 失败。
    /// App 管理权限缺失（TCC 拒绝修改其他 App 的包）单独分类，便于给专属指引。
    enum ResignResult: Equatable, Sendable {
        case success
        case cancelled
        case appManagementDenied(String)
        case failed(String)
    }

    /// 需要在管理员密码框中执行的 shell 命令。
    static var shellCommand: String {
        "codesign --sign - --force --deep \(wechatAppPath)"
    }

    /// 兜底方案：终端里执行的命令（终端通常已有「App 管理」权限）。
    static var terminalCommand: String {
        "sudo \(shellCommand)"
    }

    /// 完整的 osascript AppleScript 源码（弹系统密码框提权）。
    static var appleScriptSource: String {
        "do shell script \"\(shellCommand)\" with administrator privileges"
    }

    /// 由退出码 + stderr 判定结果（纯逻辑，可单测）。
    /// osascript 提权弹窗「用户取消」报 error -128；
    /// stderr 含 Operation not permitted 是 macOS Ventura+ 的 TCC「App 管理」
    /// 权限拒绝修改其他 App 的包，提权到 root 也绕不过，单独分类。
    static func parseResult(status: Int32, stderr: String) -> ResignResult {
        if status == 0 { return .success }
        if stderr.contains("User canceled") || stderr.contains("(-128)") { return .cancelled }
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if stderr.contains("Operation not permitted") {
            return .appManagementDenied(detail.isEmpty ? "退出码 \(status)" : detail)
        }
        return .failed(detail.isEmpty ? "退出码 \(status)" : detail)
    }

    /// 异步启动进程并等待真正退出：
    /// - terminationHandler 回调，绝不阻塞调用线程；
    /// - stderr 用 readabilityHandler 持续排空，避免输出填满管道缓冲导致假死；
    /// - 进程退出后再读管道尾部，保证 stderr 完整。
    static func run(
        executableURL: URL,
        arguments: [String],
        completion: @escaping @Sendable (ResignResult) -> Void
    ) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        // readabilityHandler 与 terminationHandler 可能跑在不同线程，串行队列保护缓冲。
        final class Buffer: @unchecked Sendable { var data = Data() }
        let buffer = Buffer()
        let queue = DispatchQueue(label: "WeChatMover.CodeSigner.stderr")
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            queue.sync { buffer.data.append(chunk) }
        }
        process.terminationHandler = { proc in
            errPipe.fileHandleForReading.readabilityHandler = nil
            let tail = errPipe.fileHandleForReading.readDataToEndOfFile()
            queue.sync { buffer.data.append(tail) }
            let stderr = String(data: buffer.data, encoding: .utf8) ?? ""
            completion(parseResult(status: proc.terminationStatus, stderr: stderr))
        }
        do {
            try process.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            completion(.failed("无法启动提权工具：\(error.localizedDescription)"))
        }
    }

    /// 弹出系统密码框，对微信执行 ad-hoc 重签名（异步，completion 在后台线程回调）。
    /// 调用方负责在调用前激活本 App，否则系统密码框可能无法正常前置。
    static func resignWeChat(completion: @escaping @Sendable (ResignResult) -> Void) {
        run(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", appleScriptSource],
            completion: completion
        )
    }
}
