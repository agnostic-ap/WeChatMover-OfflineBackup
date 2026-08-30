import Foundation

/// 备份仓库：<所选目录>/WeChatBackups/<快照目录>/。
/// 快照目录内：<组件id>.zip × N + manifest.json + COMPLETE。
/// 目录与文件名全部为 exFAT 安全的 ASCII。
enum VaultStore {
    static let vaultDirName = "WeChatBackups"
    static let manifestFileName = "manifest.json"
    static let completionMarkerName = "COMPLETE"
    static let inProgressSuffix = ".inprogress"

    static func vaultRoot(base: URL) -> URL {
        base.appendingPathComponent(vaultDirName, isDirectory: true)
    }

    /// 快照目录名：WeChatBackup-yyyyMMdd-HHmmss（本地时区，固定 POSIX 历法）。
    static func snapshotName(date: Date) -> String {
        "WeChatBackup-" + timestampString(date)
    }

    static func timestampString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    // MARK: - 列表与读取

    /// 列出仓库内全部快照（含未完成的，isComplete=false），按名称倒序（新在前）。
    static func listSnapshots(base: URL) -> [SnapshotInfo] {
        let root = vaultRoot(base: base)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        return names
            .filter { $0.hasPrefix("WeChatBackup-") }
            .sorted(by: >)
            .compactMap { name in
                var isDir: ObjCBool = false
                let dir = root.appendingPathComponent(name, isDirectory: true)
                guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                      isDir.boolValue else { return nil }
                return loadSnapshot(at: dir)
            }
    }

    /// 读取单个快照目录：清单 + 完成标记校验。
    static func loadSnapshot(at directory: URL) -> SnapshotInfo {
        var manifest: BackupManifest?
        var complete = false
        let manifestURL = directory.appendingPathComponent(manifestFileName)
        if let data = try? Data(contentsOf: manifestURL) {
            manifest = try? BackupManifest.decode(data)
            if manifest != nil,
               let marker = try? String(
                   contentsOf: directory.appendingPathComponent(completionMarkerName),
                   encoding: .utf8) {
                complete = marker.trimmingCharacters(in: .whitespacesAndNewlines)
                    == Checksum.sha256(data: data)
            }
        }
        return SnapshotInfo(
            directoryURL: directory,
            name: directory.lastPathComponent,
            manifest: manifest,
            isComplete: complete)
    }

    // MARK: - 写入

    static func writeManifest(_ manifest: BackupManifest, to directory: URL) throws {
        try manifest.encoded().write(to: directory.appendingPathComponent(manifestFileName))
    }

    /// 完成标记内容 = manifest.json 的 SHA-256，防止「清单在、归档没写完」的假完整。
    static func writeCompletionMarker(in directory: URL) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent(manifestFileName))
        try (Checksum.sha256(data: data) + "\n")
            .write(to: directory.appendingPathComponent(completionMarkerName),
                   atomically: true, encoding: .utf8)
    }

    // MARK: - 验证

    /// 深度验证快照：完成标记、每个归档存在、大小一致、SHA-256 一致、条目路径安全。
    /// 返回问题列表（空 = 全部通过）。
    static func verify(snapshot: SnapshotInfo, log: (String) -> Void = { _ in }) -> [String] {
        var problems: [String] = []
        guard let manifest = snapshot.manifest else {
            return ["缺少或无法解析 manifest.json"]
        }
        if !snapshot.isComplete {
            problems.append("缺少完成标记（COMPLETE）或标记与清单不一致")
        }
        if manifest.formatVersion > BackupManifest.currentFormatVersion {
            problems.append("清单格式版本 \(manifest.formatVersion) 高于本工具支持的版本")
        }
        let fm = FileManager.default
        for entry in manifest.entries {
            let archive = snapshot.directoryURL.appendingPathComponent(entry.archiveName)
            log("验证 \(entry.displayName)…")
            guard fm.fileExists(atPath: archive.path) else {
                problems.append("缺少归档：\(entry.archiveName)")
                continue
            }
            let size = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? nil
            if let size, size != entry.archiveSize {
                problems.append("归档大小不符：\(entry.archiveName)（清单 \(entry.archiveSize)，实际 \(size)）")
            }
            if let sha = try? Checksum.sha256(of: archive) {
                if sha != entry.sha256 {
                    problems.append("SHA-256 不匹配：\(entry.archiveName)")
                }
            } else {
                problems.append("无法读取归档：\(entry.archiveName)")
            }
            if let entries = try? ZipArchiver.listEntries(archive: archive) {
                let unsafe = ZipArchiver.unsafeEntries(entries)
                if !unsafe.isEmpty {
                    problems.append("归档含不安全路径：\(entry.archiveName)")
                }
            }
        }
        return problems
    }

    // MARK: - 删除

    /// 删除快照目录。唯一允许的删除位置：所选仓库 base 的 WeChatBackups 下、
    /// 名称以 WeChatBackup- 开头的直接子目录；其余一律拒绝。
    static func deleteSnapshot(_ snapshot: SnapshotInfo, base: URL) throws {
        let dir = snapshot.directoryURL.standardizedFileURL
        let root = vaultRoot(base: base).standardizedFileURL
        guard dir.deletingLastPathComponent().path == root.path,
              dir.lastPathComponent.hasPrefix("WeChatBackup-") else {
            throw BackupError.vaultPathInvalid(dir.path)
        }
        try FileManager.default.removeItem(at: dir)
    }
}
