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

/// 备份核心：逐组件 tar 归档 → SHA-256 → 写清单 → 写完成标记 → 目录去掉
/// .inprogress 后缀。全程只读微信数据；对备份盘只写快照目录。
/// 同步实现，由调用方放到后台线程执行。
enum BackupEngine {

    /// path 是否等于 other、位于其内部或包含它（先解析符号链接与 ../）。
    static func pathsOverlap(_ a: URL, _ b: URL) -> Bool {
        let pa = a.standardizedFileURL.resolvingSymlinksInPath().path
        let pb = b.standardizedFileURL.resolvingSymlinksInPath().path
        return pa == pb || pa.hasPrefix(pb + "/") || pb.hasPrefix(pa + "/")
    }

    /// 备份仓库不得与任何源组件目录重叠（相同 / 在其内部 / 包含源目录），
    /// 否则会递归归档或把源写进仓库。比较时解析符号链接。
    static func checkVaultDoesNotOverlapSources(_ request: BackupRequest) throws {
        let vaultRoot = VaultStore.vaultRoot(base: request.vaultBase)
        for component in request.components {
            let src = request.environment.url(for: component)
            if pathsOverlap(vaultRoot, src) {
                throw BackupError.vaultOverlapsSource(
                    "\(vaultRoot.path) ↔ \(src.path)（\(component.displayName)）")
            }
        }
    }

    /// 执行备份，返回完成的快照。
    /// 失败/取消时清理未完成的快照目录（仅限本次新建的 .inprogress 目录）。
    /// isWeChatRunning 在第一次写盘前和每个组件归档前都会复查，
    /// 防止「退出微信后又被立即重开」的竞态；测试注入假闭包，不触碰真实微信。
    static func performBackup(
        _ request: BackupRequest,
        log: (String) -> Void = { _ in },
        progress: (Double) -> Void = { _ in },
        isCancelled: () -> Bool = { false },
        isWeChatRunning: () -> Bool = { WeChatDetector.isRunning() }
    ) throws -> SnapshotInfo {
        guard !request.components.isEmpty else { throw BackupError.nothingToBackup }
        try checkVaultDoesNotOverlapSources(request)
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

        // 2. 目标盘空间预检（tar 不压缩，按逻辑大小 + 余量）。
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
        // 第一次写盘前复查微信确实没在运行（防退出后立即重开的竞态）。
        guard !isWeChatRunning() else { throw BackupError.wechatStillRunning }
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
            // 每个组件归档前复查：微信中途被打开会导致归档内容不一致。
            if isWeChatRunning() { try cleanupAndThrow(BackupError.wechatStillRunning) }
            let src = request.environment.url(for: component)
            let archiveName = component.id + ".tar"
            let archiveURL = workDir.appendingPathComponent(archiveName)

            // 容器组件先整树克隆到容器外再归档（见 ContainerCloner 注释）；
            // 应用本体不在容器内，直接归档。克隆失败则退回直接归档。
            var archiveSource = src
            var cloneParent: URL? = nil
            defer { if let cloneParent { ContainerCloner.removeClone(cloneParent) } }
            var entryStats = stats[component.id] ?? (0, 0)
            if component.kind != .application {
                let parent = ContainerCloner.makeCloneParent()
                let need = ContainerCloner.estimatedCloneOverhead(fileCount: entryStats.fileCount)
                let free = DiskProbe.usableSpace(path: fm.temporaryDirectory.path) ?? .max
                if free > need {
                    do {
                        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                        let cloneRoot = parent.appendingPathComponent(
                            src.lastPathComponent, isDirectory: true)
                        try ContainerCloner.cloneTree(source: src, to: cloneRoot, log: log)
                        for name in ContainerCloner.pruneProtectedFiles(inCloneRoot: cloneRoot) {
                            log("已剔除受系统保护的元数据文件：\(name)（恢复后系统自动重建）")
                        }
                        cloneParent = parent
                        archiveSource = cloneRoot
                        // 用克隆重新统计：与归档实际内容严格一致。
                        entryStats = FileStats.measure(at: cloneRoot)
                    } catch {
                        ContainerCloner.removeClone(parent)
                        let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                        log("⚠️ 容器外克隆失败（\(msg)），改为直接归档原目录（大容器可能明显变慢）")
                    }
                } else {
                    log("⚠️ 本地空间不足以克隆（需约 \(DiskProbe.formatBytes(need))），改为直接归档原目录")
                }
            }

            log("归档 \(component.displayName)…")
            do {
                try Archiver.createArchive(source: archiveSource, archive: archiveURL)
                // 打包后自检：条目安全且都在期望顶层目录下。
                let list = try Archiver.listEntries(archive: archiveURL)
                try Archiver.validateEntries(
                    list, expectedTopLevel: archiveSource.lastPathComponent)
            } catch {
                try cleanupAndThrow(error)
            }
            // 归档完成后复查：本组件归档期间微信重开，内容不可信，
            // 即便是唯一/最后一个组件也整体作废，不生成快照。
            if isWeChatRunning() { try cleanupAndThrow(BackupError.wechatStillRunning) }
            let s = entryStats
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
