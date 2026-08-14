import Foundation

/// 目录指纹：遍历目录树只 stat 不读内容，每文件取（相对路径、大小、mtime）
/// 做 per-file 哈希，聚合成与遍历顺序无关的总指纹。
/// 用途：迁移时把指纹写入 manifest；还原前对比本地备份与外置数据是否一致
/// （_backup 是迁移时刻的快照，指纹不同 = 迁移后外置盘有新写入）。
enum Fingerprint {
    struct Value: Equatable, Sendable, Codable {
        var fileCount: Int64
        var totalBytes: Int64
        /// 各文件哈希的加法聚合（天然顺序无关）。
        var hash: UInt64
    }

    /// 计算目录指纹；目录不存在/不可读返回 nil（调用方按"无法判定"处理）。
    /// 大目录为秒级 stat 遍历，请在后台线程调用。
    static func compute(at url: URL) -> Value? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var count: Int64 = 0
        var bytes: Int64 = 0
        var hash: UInt64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            let rel = relativePath(of: file, under: url)
            let size = Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            hash = hash &+ fileHash(relativePath: rel, size: size, mtime: mtime)
            count += 1
            bytes += size
        }
        return Value(fileCount: count, totalBytes: bytes, hash: hash)
    }

    /// 文件相对 base 的路径。macOS 上 base 与枚举器输出的 /var ↔ /private/var
    /// 软链形态可能不一致，直接按长度截断会切错，这里显式对齐两种形态。
    static func relativePath(of file: URL, under base: URL) -> String {
        let filePath = file.path
        for basePath in Self.basePathCandidates(base.path) {
            if filePath.hasPrefix(basePath + "/") {
                return String(filePath.dropFirst(basePath.count + 1))
            }
        }
        return file.lastPathComponent   // 理论到不了；兜底
    }

    private static func basePathCandidates(_ path: String) -> [String] {
        if path.hasPrefix("/private/") {
            return [path, String(path.dropFirst("/private".count))]
        }
        return [path, "/private" + path]
    }

    /// FNV-1a 混合（路径 + 大小 + mtime），改名/增删/内容变化均可检出。
    static func fileHash(relativePath rel: String, size: Int64, mtime: Double) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for byte in rel.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        h = (h ^ UInt64(bitPattern: size)) &* 1099511628211
        h = (h ^ mtime.bitPattern) &* 1099511628211
        return h
    }

    // MARK: - 迁移清单（manifest.json）

    /// 清单文件位置：<目标文件夹>/WeChatData/manifest.json
    static func manifestURL(base: URL) -> URL {
        WeChatPaths.targetRoot(forBase: base).appendingPathComponent("manifest.json")
    }

    static func writeManifest(_ manifest: MigrationManifest, base: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(base: base), options: .atomic)
    }

    static func readManifest(base: URL) -> MigrationManifest? {
        guard let data = try? Data(contentsOf: manifestURL(base: base)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MigrationManifest.self, from: data)
    }
}

/// 迁移清单：迁移完成时写入，逐项记录（目录名、迁移时刻的指纹）。
struct MigrationManifest: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        var subdir: String
        var fingerprint: Fingerprint.Value
    }
    var toolVersion: String
    var migratedAt: Date
    var items: [Item]

    func fingerprint(for subdir: String) -> Fingerprint.Value? {
        items.first { $0.subdir == subdir }?.fingerprint
    }
}
