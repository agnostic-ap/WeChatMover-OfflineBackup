import Foundation

/// 恢复计划：默认只展示，不做任何写入；由用户二次确认后才执行。
struct RestorePlan: Sendable {
    struct Item: Sendable, Identifiable {
        var entry: BackupManifest.Entry
        var archiveURL: URL
        var targetURL: URL
        var targetExists: Bool
        var id: String { entry.id }
    }

    var snapshot: SnapshotInfo
    var items: [Item]                       // 仅自动恢复条目（不含微信应用本体）
    var appEntry: BackupManifest.Entry?     // 应用本体归档：仅提示手动处理
    var totalLogicalSize: Int64
    var freeSpaceOnHome: Int64?
    var currentWeChatVersion: String?
    var backupWeChatVersion: String?
    /// 已安装微信版本与快照记录版本不一致（未安装时不算不一致，仅提示）。
    var versionMismatch: Bool
    var warnings: [String]
}

/// 恢复结果。
struct RestoreResult: Sendable {
    /// 已恢复组件显示名。
    var restored: [String]
    /// 原数据让位后的回滚副本目录（保留在原位旁，确认无误后可手动删除）。
    var rollbackDirs: [String]
}

/// 恢复核心：验证（ZIP 路径安全 + SHA-256）→ 空间检查 → 全部解压到暂存 →
/// 原目录改名为回滚副本 → 暂存落位；任一步失败自动回滚，绝不静默删除用户数据。
/// 同步实现，由调用方放到后台线程执行。
enum RestoreEngine {

    // MARK: - 制定计划（只读）

    static func makePlan(
        snapshot: SnapshotInfo,
        environment: WeChatEnvironment,
        currentWeChatVersion: String?
    ) throws -> RestorePlan {
        guard let manifest = snapshot.manifest, snapshot.isComplete else {
            throw BackupError.snapshotIncomplete(snapshot.name)
        }
        // 清单本身先过白名单校验：archiveName 是安全文件名、relativePath 精确映射
        // 微信组件、无重复 target/archiveName、有可自动恢复条目。
        let manifestProblems = ManifestValidation.problems(in: manifest)
        guard manifestProblems.isEmpty else {
            throw BackupError.manifestInvalid(manifestProblems.joined(separator: "；"))
        }
        let fm = FileManager.default
        var warnings: [String] = []
        var items: [RestorePlan.Item] = []
        let snapshotDirPath = snapshot.directoryURL.standardizedFileURL.path
        for entry in manifest.restorableEntries {
            let archive = snapshot.directoryURL.appendingPathComponent(entry.archiveName)
            // 双保险：拼接后归档必须仍是快照目录的直接子项。
            guard archive.standardizedFileURL.deletingLastPathComponent().path == snapshotDirPath
            else {
                throw BackupError.manifestInvalid("归档越出快照目录：\(entry.archiveName)")
            }
            if !fm.fileExists(atPath: archive.path) {
                throw BackupError.archiveMissing(entry.archiveName)
            }
            let target = environment.home.appendingPathComponent(entry.relativePath, isDirectory: true)
            // 计划阶段就核对白名单：目标不合法直接拒绝整个计划。
            guard PathGuard.isProtectedWeChatPath(target, home: environment.home) else {
                throw BackupError.pathNotWhitelisted(target.path)
            }
            items.append(RestorePlan.Item(
                entry: entry,
                archiveURL: archive,
                targetURL: target,
                targetExists: fm.fileExists(atPath: target.path)))
        }

        let mismatch: Bool
        if let cur = currentWeChatVersion, let bak = manifest.wechatVersion {
            mismatch = cur != bak
        } else {
            mismatch = false
        }
        if mismatch {
            warnings.append("当前微信版本（\(currentWeChatVersion ?? "未知")）与快照记录版本（\(manifest.wechatVersion ?? "未知")）不一致，恢复后微信可能要求重新登录或数据不兼容。")
        }
        if currentWeChatVersion == nil {
            warnings.append("本机未检测到微信。建议先安装与快照相同版本（\(manifest.wechatVersion ?? "未知")）再恢复。")
        }
        if manifest.formatVersion > BackupManifest.currentFormatVersion {
            warnings.append("快照格式版本高于本工具支持范围，请升级本工具后再恢复。")
        }

        return RestorePlan(
            snapshot: snapshot,
            items: items,
            appEntry: manifest.appEntry,
            totalLogicalSize: manifest.restorableEntries.reduce(0) { $0 + $1.logicalSize },
            freeSpaceOnHome: DiskProbe.freeSpace(path: environment.home.path),
            currentWeChatVersion: currentWeChatVersion,
            backupWeChatVersion: manifest.wechatVersion,
            versionMismatch: mismatch,
            warnings: warnings)
    }

    // MARK: - 执行恢复

    /// 文件移动操作，可注入以便单测覆盖回滚失败分支（默认走 FileManager）。
    struct FileOps {
        var moveItem: (URL, URL) throws -> Void = {
            try FileManager.default.moveItem(at: $0, to: $1)
        }
    }

    /// isWeChatRunning 在解压暂存前与落位（唯一改动微信目录的阶段）前都会复查，
    /// 防止「退出微信后又被立即重开」的竞态；测试注入假闭包，不触碰真实微信。
    static func performRestore(
        plan: RestorePlan,
        environment: WeChatEnvironment,
        now: Date = Date(),
        spaceMargin: Int64 = 256 << 20,
        fileOps: FileOps = FileOps(),
        isWeChatRunning: () -> Bool = { WeChatDetector.isRunning() },
        log: (String) -> Void = { _ in },
        progress: (Double) -> Void = { _ in }
    ) throws -> RestoreResult {
        let fm = FileManager.default
        let home = environment.home
        let ts = VaultStore.timestampString(now)

        // 1. 逐归档验证：条目路径安全 + 顶层结构 + SHA-256。全部通过前不动任何数据。
        for (i, item) in plan.items.enumerated() {
            log("验证归档 \(item.entry.displayName)…")
            let entries = try ZipArchiver.listEntries(archive: item.archiveURL)
            try ZipArchiver.validateEntries(
                entries, expectedTopLevel: item.targetURL.lastPathComponent)
            let sha = try Checksum.sha256(of: item.archiveURL)
            guard sha == item.entry.sha256 else {
                throw BackupError.checksumMismatch(item.entry.archiveName)
            }
            progress(Double(i + 1) / Double(max(plan.items.count, 1)) * 0.3)
        }
        log("✅ 全部归档校验通过")

        // 2. 空间检查：暂存解压需要全部逻辑大小 + 余量（原数据只改名不删，不占新空间）。
        if let free = DiskProbe.freeSpace(path: home.path),
           free < plan.totalLogicalSize + spaceMargin {
            throw BackupError.insufficientSpace(
                need: plan.totalLogicalSize + spaceMargin, free: free)
        }

        // 3. 全部解压到目标同级的暂存目录（同卷，落位仅是改名）。
        // 写暂存前复查微信未运行。
        guard !isWeChatRunning() else { throw BackupError.wechatStillRunning }
        var stagedRoots: [URL] = []            // 暂存目录（可整体删除的唯一类型）
        func cleanupStaging() {
            for dir in stagedRoots { try? PathGuard.removeStaging(dir, home: home) }
        }
        var staged: [(item: RestorePlan.Item, stagedURL: URL, stagingDir: URL)] = []
        for (i, item) in plan.items.enumerated() {
            let name = item.targetURL.lastPathComponent
            let stagingDir = item.targetURL.deletingLastPathComponent()
                .appendingPathComponent("\(name).wcm-staging-\(ts)", isDirectory: true)
            guard PathGuard.isProtectedWeChatPath(stagingDir, home: home) else {
                cleanupStaging()
                throw BackupError.pathNotWhitelisted(stagingDir.path)
            }
            do {
                try? fm.removeItem(at: stagingDir)   // 同名残留暂存（带 staging 标记）可清
                try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                log("解压 \(item.entry.displayName)…")
                try ZipArchiver.extractZip(archive: item.archiveURL, to: stagingDir)
            } catch {
                cleanupStaging()
                throw error
            }
            stagedRoots.append(stagingDir)
            let extracted = stagingDir.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: extracted.path) else {
                cleanupStaging()
                throw BackupError.unexpectedArchiveLayout("解压后未找到 \(name)")
            }
            staged.append((item, extracted, stagingDir))
            progress(0.3 + Double(i + 1) / Double(max(plan.items.count, 1)) * 0.6)
        }

        // 4. 落位（每项：原目录改名回滚副本 → 暂存移入原位）。失败自动回滚已完成项。
        //    回滚自身的失败绝不吞掉：逐步收集详情、尽最大努力恢复，未能完全恢复时
        //    抛出 rollbackIncomplete 并列出原数据与失败副本的位置；全程不删除任何数据。
        func describe(_ error: Error) -> String {
            (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        var committed: [(item: RestorePlan.Item, rollback: URL?)] = []
        func rollbackCommitted(_ original: Error) throws -> Never {
            log("❌ 落位失败，开始自动回滚…")
            var failures: [String] = []
            var strandedRollbacks: [String] = []   // 未能移回原位的原数据（仍完好保留）
            var failedDataDirs: [String] = []      // 已落位新数据被移去的 .wcm-failed 位置
            for (item, rollback) in committed.reversed() {
                let target = item.targetURL
                let failedURL = target.deletingLastPathComponent()
                    .appendingPathComponent(
                        "\(target.lastPathComponent).wcm-failed-\(ts)", isDirectory: true)
                // 先把已落位的新数据移开（改名保留，不删除）。
                var targetCleared = !fm.fileExists(atPath: target.path)
                if !targetCleared {
                    do {
                        try PathGuard.validateMove(target, to: failedURL, home: home)
                        try fileOps.moveItem(target, failedURL)
                        failedDataDirs.append(failedURL.path)
                        targetCleared = true
                    } catch {
                        failures.append("无法移开新落位数据 \(target.path)：\(describe(error))")
                    }
                }
                // 再把原数据移回原位。
                if let rollback {
                    if targetCleared {
                        do {
                            try PathGuard.validateMove(rollback, to: target, home: home)
                            try fileOps.moveItem(rollback, target)
                        } catch {
                            failures.append("无法把原数据移回 \(target.path)：\(describe(error))")
                            strandedRollbacks.append(rollback.path)
                        }
                    } else {
                        failures.append("原位被占用，原数据未移回：\(rollback.path)")
                        strandedRollbacks.append(rollback.path)
                    }
                }
            }
            cleanupStaging()
            guard failures.isEmpty else {
                var msg = "\n首因：\(describe(original))"
                msg += "\n回滚失败详情：\n" + failures.map { "· " + $0 }.joined(separator: "\n")
                if !strandedRollbacks.isEmpty {
                    msg += "\n原数据完好保留在（请手动改回原名）：\n"
                        + strandedRollbacks.map { "· " + $0 }.joined(separator: "\n")
                }
                if !failedDataDirs.isEmpty {
                    msg += "\n失败落位的副本在（确认后可删除）：\n"
                        + failedDataDirs.map { "· " + $0 }.joined(separator: "\n")
                }
                log("❌ 自动回滚未完全成功，任何数据都未被删除")
                throw BackupError.rollbackIncomplete(msg)
            }
            log("已回滚到恢复前状态；如有 .wcm-failed-\(ts) 目录为失败落位的副本，可手动检查后删除")
            throw original
        }

        // 落位（唯一改动微信目录的阶段）前最后复查微信未运行。
        if isWeChatRunning() {
            cleanupStaging()
            throw BackupError.wechatStillRunning
        }
        var rollbackDirs: [String] = []
        for (item, stagedURL, _) in staged {
            let name = item.targetURL.lastPathComponent
            var rollback: URL? = nil
            if fm.fileExists(atPath: item.targetURL.path) {
                let rollbackURL = item.targetURL.deletingLastPathComponent()
                    .appendingPathComponent("\(name).wcm-rollback-\(ts)", isDirectory: true)
                do {
                    try PathGuard.validateMove(item.targetURL, to: rollbackURL, home: home)
                    try fileOps.moveItem(item.targetURL, rollbackURL)
                } catch {
                    try rollbackCommitted(error)
                }
                rollback = rollbackURL
                rollbackDirs.append(rollbackURL.lastPathComponent)
                log("原数据已改名保留：\(rollbackURL.lastPathComponent)")
            }
            do {
                // 暂存目录带 .wcm-staging- 标记也在白名单内，落位是同卷改名。
                guard PathGuard.isProtectedWeChatPath(item.targetURL, home: home) else {
                    throw BackupError.pathNotWhitelisted(item.targetURL.path)
                }
                try fileOps.moveItem(stagedURL, item.targetURL)
            } catch {
                committed.append((item, rollback))
                try rollbackCommitted(error)
            }
            committed.append((item, rollback))
            log("✅ 已恢复 \(item.entry.displayName)")
        }

        // 5. 清理暂存空壳（仅带 staging 标记的目录）。
        cleanupStaging()
        progress(1)
        log("✅ 恢复完成，共 \(committed.count) 项；原数据回滚副本保留 \(rollbackDirs.count) 个")
        return RestoreResult(
            restored: committed.map { $0.item.entry.displayName },
            rollbackDirs: rollbackDirs)
    }
}
