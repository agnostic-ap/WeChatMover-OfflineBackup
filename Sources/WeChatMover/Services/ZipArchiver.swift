import Foundation

/// ZIP 归档：封装系统 ditto。
/// 选 ditto ZIP 的原因：把 macOS 扩展属性与资源叉打进 ZIP（--sequesterRsrc，
/// AppleDouble/__MACOSX 机制），单文件归档可安全落在 exFAT 等不支持
/// 这些元数据的文件系统上；解包时 ditto 自动还原。
enum ZipArchiver {
    static let dittoPath = "/usr/bin/ditto"
    static let zipinfoPath = "/usr/bin/zipinfo"

    /// 打包目录为 ZIP（--keepParent：包内保留最外层目录名）。
    static func createZip(source: URL, archive: URL) throws {
        let result = runProcess(dittoPath, [
            "-c", "-k", "--sequesterRsrc", "--keepParent", source.path, archive.path,
        ])
        guard result.status == 0 else {
            throw BackupError.archiveFailed(
                "ditto 打包退出码 \(result.status)：\(truncatedForDisplay(result.stderr))")
        }
    }

    /// 解包 ZIP 到目录（ditto 会还原扩展属性与资源叉）。
    static func extractZip(archive: URL, to directory: URL) throws {
        let result = runProcess(dittoPath, ["-x", "-k", archive.path, directory.path])
        guard result.status == 0 else {
            throw BackupError.archiveFailed(
                "ditto 解包退出码 \(result.status)：\(truncatedForDisplay(result.stderr))")
        }
    }

    /// 列出 ZIP 内全部条目路径（zipinfo -1）。
    static func listEntries(archive: URL) throws -> [String] {
        let result = runProcess(zipinfoPath, ["-1", archive.path])
        guard result.status == 0 else {
            throw BackupError.archiveFailed("zipinfo 退出码 \(result.status)：\(result.stderr)")
        }
        return result.stdout.split(separator: "\n").map(String.init)
    }

    // MARK: - 条目路径安全（防路径穿越，纯函数可单测）

    /// 返回不安全条目：绝对路径、含 ".." 组件、反斜杠或以 ~ 开头。
    static func unsafeEntries(_ entries: [String]) -> [String] {
        entries.filter { entry in
            entry.hasPrefix("/") || entry.hasPrefix("~") || entry.contains("\\")
                || entry.split(separator: "/").contains("..")
        }
    }

    /// 校验条目全部安全且都位于期望的顶层目录内（--keepParent 打包的结构）。
    /// __MACOSX/ 是 ditto 存放 AppleDouble 元数据的伴生目录，允许。
    static func validateEntries(_ entries: [String], expectedTopLevel: String) throws -> Void {
        let unsafe = unsafeEntries(entries)
        guard unsafe.isEmpty else {
            throw BackupError.unsafeArchiveEntries(archive: expectedTopLevel, entries: unsafe)
        }
        let allowedPrefixes = [expectedTopLevel + "/", "__MACOSX/"]
        let stray = entries.filter { entry in
            entry != expectedTopLevel && !allowedPrefixes.contains(where: entry.hasPrefix)
        }
        guard stray.isEmpty else {
            throw BackupError.unexpectedArchiveLayout(
                "存在顶层目录 \(expectedTopLevel) 之外的条目：\(stray.prefix(3).joined(separator: "、"))")
        }
    }

    // MARK: - 进程执行

    struct ProcessResult {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// 子进程输出一律重定向到临时文件，退出后再读取。
    /// 不能用 Pipe：ditto 遇到问题文件会向 stderr 连续输出警告，
    /// 一旦灌满 64KB 管道缓冲而读取方还在等另一条管道的 EOF，
    /// 双方互等造成死锁（大容量备份实测踩中）。文件重定向无此问题。
    static func runProcess(_ path: String, _ arguments: [String]) -> ProcessResult {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let outURL = tmp.appendingPathComponent("wcm-proc-\(UUID().uuidString).out")
        let errURL = tmp.appendingPathComponent("wcm-proc-\(UUID().uuidString).err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return ProcessResult(status: -1, stdout: "", stderr: "无法创建临时输出文件")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = outHandle
        process.standardError = errHandle
        do {
            try process.run()
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        process.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()
        let outData = (try? Data(contentsOf: outURL)) ?? Data()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "")
    }

    /// 错误消息用的 stderr 截断（警告可能有几万行，弹窗只展示开头）。
    static func truncatedForDisplay(_ text: String, limit: Int = 1200) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return trimmed.prefix(limit) + "\n…（已截断，共 \(trimmed.count) 字符）"
    }
}
