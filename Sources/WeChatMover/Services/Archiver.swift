import Foundation

/// 归档：系统 bsdtar（libarchive）tar + --mac-metadata。
/// tar 用 AppleDouble 机制把 macOS 扩展属性与资源叉封进单文件归档，
/// 可安全落在 exFAT 等不支持这些元数据的文件系统上，解包自动还原。
///
/// 为什么不用 ditto ZIP：ditto 对超过 4GB 的归档写不出标准 ZIP64，
/// 除 Apple 自家工具外一律判为损坏（实测 45GB 归档 zipinfo/bsdtar 均拒读），
/// 而微信主容器动辄数十 GB。微信数据多为已压缩媒体，tar 免压缩打包
/// 还能直接跑满磁盘速度（实测比 ditto ZIP 快约 8 倍）。
enum Archiver {
    static let tarPath = "/usr/bin/tar"

    /// 打包目录为 tar（-C 父目录 + 末级名：包内保留最外层目录名）。
    static func createArchive(source: URL, archive: URL) throws {
        let result = runProcess(tarPath, [
            "-cf", archive.path, "--mac-metadata",
            "-C", source.deletingLastPathComponent().path, source.lastPathComponent,
        ])
        guard result.status == 0 else {
            throw BackupError.archiveFailed(
                "tar 打包退出码 \(result.status)：\(truncatedForDisplay(result.stderr))")
        }
    }

    /// 解包 tar 到目录（--mac-metadata 还原扩展属性与资源叉；
    /// libarchive 默认拒绝绝对路径与 .. 穿越条目，双保险）。
    static func extractArchive(archive: URL, to directory: URL) throws {
        let result = runProcess(tarPath, [
            "-xpf", archive.path, "--mac-metadata", "-C", directory.path,
        ])
        guard result.status == 0 else {
            throw BackupError.archiveFailed(
                "tar 解包退出码 \(result.status)：\(truncatedForDisplay(result.stderr))")
        }
    }

    /// 列出归档内全部条目路径（tar -tf）。
    static func listEntries(archive: URL) throws -> [String] {
        let result = runProcess(tarPath, ["-tf", archive.path])
        guard result.status == 0 else {
            throw BackupError.archiveFailed(
                "列出归档条目失败（tar 退出码 \(result.status)）：\(truncatedForDisplay(result.stderr))")
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
