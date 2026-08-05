import Foundation

enum MigrationError: Error, LocalizedError {
    case sourceMissing(String)
    case sourceIsSymlink(String)
    case targetAlreadyExists(String)
    case notMigrated(String)
    case verifyFailed(String)
    case insufficientSpace(need: Int64, free: Int64)

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let p): return "源目录不存在：\(p)"
        case .sourceIsSymlink(let p): return "源位置已是符号链接，无需迁移：\(p)"
        case .targetAlreadyExists(let p): return "目标位置已存在数据：\(p)"
        case .notMigrated(let p): return "该目录尚未迁移，无法还原：\(p)"
        case .verifyFailed(let p): return "拷贝校验失败：\(p)"
        case .insufficientSpace(let need, let free):
            return "目标盘空间不足：需要 \(DiskProbe.formatBytes(need))，仅剩 \(DiskProbe.formatBytes(free))"
        }
    }
}

/// 迁移/还原核心：拷贝 → 校验 → 删源 → 建软链（失败自动回滚）。
/// 全部为同步实现，由调用方放到后台线程执行。
enum Migrator {

    // MARK: - 迁移

    /// 把 source 迁移到 target（target 必须不存在），完成后 source 变成指向 target 的软链。
    static func migrateItem(source: URL, target: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw MigrationError.sourceMissing(source.path) }
        guard !DiskProbe.isSymlink(source) else { throw MigrationError.sourceIsSymlink(source.path) }
        guard !fm.fileExists(atPath: target.path) else { throw MigrationError.targetAlreadyExists(target.path) }

        let expectedSize = DiskProbe.directorySize(at: source)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 1. 拷贝
        do {
            try fm.copyItem(at: source, to: target)
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }

        // 2. 校验
        guard DiskProbe.directorySize(at: target) == expectedSize else {
            try? fm.removeItem(at: target)
            throw MigrationError.verifyFailed(target.path)
        }

        // 3. 移走源（先备份再建链，任何一步失败可回滚）
        let backup = source.appendingPathExtension("mover-backup")
        do {
            try fm.moveItem(at: source, to: backup)
            try fm.createSymbolicLink(at: source, withDestinationURL: target)
        } catch {
            try? fm.removeItem(at: source)
            try? fm.moveItem(at: backup, to: source)
            try? fm.removeItem(at: target)
            throw error
        }

        // 4. 确认软链可达后删备份；软链异常则整体回滚
        guard fm.fileExists(atPath: source.path) else {
            try? fm.removeItem(at: source)
            try? fm.moveItem(at: backup, to: source)
            try? fm.removeItem(at: target)
            throw MigrationError.verifyFailed("软链创建后目标不可达")
        }
        try? fm.removeItem(at: backup)
    }

    // MARK: - 还原

    /// 把已迁移的目录还原：删软链 → 数据拷回原位 → 校验 → 删目标。
    static func restoreItem(source: URL, target: URL) throws {
        let fm = FileManager.default
        guard DiskProbe.isSymlink(source) else { throw MigrationError.notMigrated(source.path) }
        guard fm.fileExists(atPath: target.path) else { throw MigrationError.sourceMissing(target.path) }

        let expectedSize = DiskProbe.directorySize(at: target)

        // 1. 删软链（只删链接，不删数据）
        try fm.removeItem(at: source)

        // 2. 拷回原位
        do {
            try fm.copyItem(at: target, to: source)
        } catch {
            // 拷回失败：尽量恢复软链，数据仍在 target
            try? fm.removeItem(at: source)
            try? fm.createSymbolicLink(at: source, withDestinationURL: target)
            throw error
        }

        // 3. 校验后删目标
        guard DiskProbe.directorySize(at: source) == expectedSize else {
            try? fm.removeItem(at: source)
            try? fm.createSymbolicLink(at: source, withDestinationURL: target)
            throw MigrationError.verifyFailed(source.path)
        }
        try? fm.removeItem(at: target)
    }

    // MARK: - 前置检查

    /// 检查目标卷剩余空间是否装得下这些数据。
    static func checkSpace(totalBytes: Int64, targetPath: String) throws {
        if let free = DiskProbe.freeSpace(path: targetPath), free < totalBytes {
            throw MigrationError.insufficientSpace(need: totalBytes, free: free)
        }
    }
}
