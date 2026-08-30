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
        let fm = FileManager.default
        var warnings: [String] = []
        var items: [RestorePlan.Item] = []
        for entry in manifest.restorableEntries {
            let archive = snapshot.directoryURL.appendingPathComponent(entry.archiveName)
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

    static func performRestore(
        plan: RestorePlan,
        environment: WeChatEnvironment,
        now: Date = Date(),
        spaceMargin: Int64 = 256 << 20,
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
        var committed: [(item: RestorePlan.Item, rollback: URL?)] = []
        func rollbackCommitted(_ error: Error) throws -> Never {
            log("❌ 落位失败，开始自动回滚…")
            for (item, rollback) in committed.reversed() {
                // 新落位的数据让开（改名保留，不删除），原数据改回原名。
                let failedURL = item.targetURL.deletingLastPathComponent()
                    .appendingPathComponent(
                        "\(item.targetURL.lastPathComponent).wcm-failed-\(ts)", isDirectory: true)
                try? PathGuard.move(item.targetURL, to: failedURL, home: home)
                if let rollback {
                    try? PathGuard.move(rollback, to: item.targetURL, home: home)
                }
            }
            cleanupStaging()
            log("已回滚到恢复前状态；如有 .wcm-failed-\(ts) 目录为失败残留，可手动检查后删除")
            throw error
        }
        var rollbackDirs: [String] = []
        for (item, stagedURL, _) in staged {
            let name = item.targetURL.lastPathComponent
            var rollback: URL? = nil
            if fm.fileExists(atPath: item.targetURL.path) {
                let rollbackURL = item.targetURL.deletingLastPathComponent()
                    .appendingPathComponent("\(name).wcm-rollback-\(ts)", isDirectory: true)
                do {
                    try PathGuard.move(item.targetURL, to: rollbackURL, home: home)
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
                try fm.moveItem(at: stagedURL, to: item.targetURL)
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
