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

    /// 返回不安全条目：绝对路径、含 ".." 组件或以 ~ 开头。
    ///
    /// 注意不能把反斜杠判为不安全：bsdtar 列条目时会把非 ASCII 字节
    /// 转成八进制转义（中文文件名如「2024年合同.xls」→ "2024\\345\\271\\264…"，
    /// 微信收到的文件大量命中，实测 45GB 归档因此被误杀）；tar 中反斜杠
    /// 也不是路径分隔符。穿越所需的 "/"、"." 都是 ASCII 可打印字符，
    /// bsdtar 永远原样输出，检测不受转义影响。
    static func unsafeEntries(_ entries: [String]) -> [String] {
        entries.filter { entry in
            entry.hasPrefix("/") || entry.hasPrefix("~")
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

    /// 线程安全的管道累积缓冲。
    private final class PipeBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var contents: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// 双管道并发读取（readabilityHandler），两路同时排空：
    /// - 不能顺序读两条管道：归档工具遇到问题文件会向 stderr 连续输出警告，
    ///   灌满 64KB 管道缓冲而读取方还在等另一条的 EOF 时双方互等死锁（实测踩中）；
    /// - 也不能重定向到磁盘临时文件：本地盘临界满时连 0 字节文件都建不出来
    ///   （实测踩中），进程执行不应依赖本地盘余量。
    static func runProcess(_ path: String, _ arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // utility QoS：归档工具的大流量 I/O 交给系统节流，避免和内核/其他
        // 进程抢到系统失去响应（实测全速 45GB 读写曾触发 watchdog 重启）。
        process.qualityOfService = .utility
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBuf = PipeBuffer()
        let errBuf = PipeBuffer()
        let outDone = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                outDone.signal()
            } else {
                outBuf.append(chunk)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                errDone.signal()
            } else {
                errBuf.append(chunk)
            }
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        // 先等两路 EOF（子进程退出后管道写端关闭），再取退出码。
        outDone.wait()
        errDone.wait()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: outBuf.contents, encoding: .utf8) ?? "",
            stderr: String(data: errBuf.contents, encoding: .utf8) ?? "")
    }

    /// 错误消息用的 stderr 截断（警告可能有几万行，弹窗只展示开头）。
    static func truncatedForDisplay(_ text: String, limit: Int = 1200) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return trimmed.prefix(limit) + "\n…（已截断，共 \(trimmed.count) 字符）"
    }
}
