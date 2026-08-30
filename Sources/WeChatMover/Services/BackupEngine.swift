import Foundation

/// 一次备份请求（全部依赖显式注入，测试用临时目录 fixture）。
struct BackupRequest: Sendable {
    var components: [BackupComponent]
    var environment: WeChatEnvironment
    var vaultBase: URL
    var wechatVersion: String?
    var wechatBuild: String?
    var macOSVersion: String
    var toolVersion: String
    var now: Date = Date()
    /// 空间预检余量（防止把目标盘写满）。
    var spaceMargin: Int64 = 256 << 20
}

/// 备份核心：逐组件 ditto ZIP → SHA-256 → 写清单 → 写完成标记 → 目录去掉
/// .inprogress 后缀。全程只读微信数据；对备份盘只写快照目录。
/// 同步实现，由调用方放到后台线程执行。
enum BackupEngine {

    /// 执行备份，返回完成的快照。
    /// 失败/取消时清理未完成的快照目录（仅限本次新建的 .inprogress 目录）。
    static func performBackup(
        _ request: BackupRequest,
        log: (String) -> Void = { _ in },
        progress: (Double) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> SnapshotInfo {
        guard !request.components.isEmpty else { throw BackupError.nothingToBackup }
        let fm = FileManager.default

        // 1. 统计源大小（逻辑字节 + 文件数），用于空间预检与进度。
        var stats: [String: (fileCount: Int, logicalSize: Int64)] = [:]
        var totalLogical: Int64 = 0
        for component in request.components {
            let src = request.environment.url(for: component)
            let s = FileStats.measure(at: src)
            stats[component.id] = s
            totalLogical += s.logicalSize
            log("统计 \(component.displayName)：\(s.fileCount) 个文件，\(DiskProbe.formatBytes(s.logicalSize))")
        }

        // 2. 目标盘空间预检（ZIP 通常更小，用逻辑大小作保守上界 + 余量）。
        if let free = DiskProbe.freeSpace(path: request.vaultBase.path),
           free < totalLogical + request.spaceMargin {
            throw BackupError.insufficientSpace(need: totalLogical + request.spaceMargin, free: free)
        }

        // 3. 建 .inprogress 快照目录（完成前的所有写入都在里面）。
        let finalDir = VaultStore.vaultRoot(base: request.vaultBase)
            .appendingPathComponent(VaultStore.snapshotName(date: request.now), isDirectory: true)
        let workDir = finalDir.appendingPathExtension(
            String(VaultStore.inProgressSuffix.dropFirst()))
        if fm.fileExists(atPath: finalDir.path) || fm.fileExists(atPath: workDir.path) {
            throw BackupError.archiveFailed("同名快照已存在：\(finalDir.lastPathComponent)")
        }
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 之后任何失败都清掉本次新建的工作目录（只删自己刚建的 .inprogress）。
        func cleanupAndThrow(_ error: Error) throws -> Never {
            try? fm.removeItem(at: workDir)
            throw error
        }

        // 4. 逐组件归档 + 校验。
        var entries: [BackupManifest.Entry] = []
        var doneLogical: Int64 = 0
        for component in request.components {
            if isCancelled() { try cleanupAndThrow(BackupError.cancelled) }
            let src = request.environment.url(for: component)
            let archiveName = component.id + ".zip"
            let archiveURL = workDir.appendingPathComponent(archiveName)
            log("归档 \(component.displayName)…")
            do {
                try ZipArchiver.createZip(source: src, archive: archiveURL)
                // 打包后自检：条目安全且都在期望顶层目录下。
                let list = try ZipArchiver.listEntries(archive: archiveURL)
                try ZipArchiver.validateEntries(list, expectedTopLevel: src.lastPathComponent)
            } catch {
                try cleanupAndThrow(error)
            }
            let s = stats[component.id] ?? (0, 0)
            let archiveSize = (try? fm.attributesOfItem(atPath: archiveURL.path)[.size] as? Int64)
                .flatMap { $0 } ?? 0
            let sha: String
            do {
                sha = try Checksum.sha256(of: archiveURL)
            } catch {
                try cleanupAndThrow(error)
            }
            entries.append(BackupManifest.Entry(
                id: component.id,
                kind: component.kind,
                displayName: component.displayName,
                relativePath: component.relativePath,
                archiveName: archiveName,
                fileCount: s.fileCount,
                logicalSize: s.logicalSize,
                archiveSize: archiveSize,
                sha256: sha))
            doneLogical += s.logicalSize
            progress(totalLogical > 0 ? Double(doneLogical) / Double(totalLogical) : 1)
            log("✅ \(component.displayName)：归档 \(DiskProbe.formatBytes(archiveSize))，SHA-256 已记录")
        }

        // 5. 写清单与完成标记，改名去掉 .inprogress。
        let manifest = BackupManifest(
            formatVersion: BackupManifest.currentFormatVersion,
            createdAt: request.now,
            toolVersion: request.toolVersion,
            wechatVersion: request.wechatVersion,
            wechatBuild: request.wechatBuild,
            macOSVersion: request.macOSVersion,
            entries: entries)
        do {
            try VaultStore.writeManifest(manifest, to: workDir)
            try VaultStore.writeCompletionMarker(in: workDir)
            try fm.moveItem(at: workDir, to: finalDir)
        } catch {
            try cleanupAndThrow(error)
        }
        log("✅ 快照完成：\(finalDir.lastPathComponent)")
        return VaultStore.loadSnapshot(at: finalDir)
    }
}
