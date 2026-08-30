import Foundation

/// 快照清单：记录格式版本、来源环境与每个归档的校验信息。
/// 作为 manifest.json 写在快照目录内，最后写 COMPLETE 完成标记。
struct BackupManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var createdAt: Date
    var toolVersion: String
    var wechatVersion: String?
    var wechatBuild: String?
    var macOSVersion: String
    var entries: [Entry]

    struct Entry: Codable, Equatable, Identifiable, Sendable {
        var id: String                    // 组件稳定 ID，同归档文件名主干
        var kind: BackupComponent.Kind
        var displayName: String
        var relativePath: String          // 源相对路径（application 为相对根 "/"）
        var archiveName: String           // 快照目录内的 归档文件名
        var fileCount: Int
        var logicalSize: Int64            // 源目录逻辑大小（字节）
        var archiveSize: Int64            // 归档文件大小（字节）
        var sha256: String                // 归档的 SHA-256（小写十六进制）
    }

    /// 参与自动恢复的条目（微信应用本体归档只作保存，不自动恢复）。
    var restorableEntries: [Entry] { entries.filter { $0.kind != .application } }
    /// 微信应用本体归档条目（如有）。
    var appEntry: Entry? { entries.first { $0.kind == .application } }

    var totalLogicalSize: Int64 { entries.reduce(0) { $0 + $1.logicalSize } }
    var totalArchiveSize: Int64 { entries.reduce(0) { $0 + $1.archiveSize } }

    // MARK: - 编解码（ISO8601 时间，键排序保证稳定输出）

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func encoded() throws -> Data { try Self.encoder().encode(self) }

    static func decode(_ data: Data) throws -> BackupManifest {
        try decoder().decode(BackupManifest.self, from: data)
    }
}

/// 一个磁盘上的快照（目录 + 清单 + 完成标记状态）。
struct SnapshotInfo: Identifiable, Equatable, Sendable {
    var directoryURL: URL
    var name: String
    var manifest: BackupManifest?
    /// COMPLETE 标记存在且与 manifest.json 哈希一致。
    var isComplete: Bool

    var id: String { directoryURL.path }
    var createdAt: Date? { manifest?.createdAt }
    var totalArchiveSize: Int64 { manifest?.totalArchiveSize ?? 0 }
}
