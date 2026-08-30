import Foundation

/// 卷相关的只读探测。
enum DiskProbe {
    /// 读取路径所在卷的文件系统类型名（如 "apfs"、"exfat"、"ntfs"）。
    static func volumeFSType(path: String) -> String? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return withUnsafeBytes(of: &s.f_fstypename) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    /// 路径所在卷的剩余空间（字节）。
    static func freeSpace(path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? Int64 else { return nil }
        return free
    }

    /// 真实可用空间：volumeAvailableCapacityForImportantUsage（系统可为重要
    /// 写入清理 purgeable 后的可用量）。systemFreeSize 在磁盘临界满时被
    /// purgeable 空间虚高（实测 df 显示 2.8G 可用但 0 字节文件都建不出来），
    /// 本地盘（克隆/恢复暂存）的空间预检必须用这个。取不到时退回 freeSpace。
    static func usableSpace(path: String) -> Int64? {
        if let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage,
           capacity > 0 {
            return capacity
        }
        return freeSpace(path: path)
    }

    /// 路径所在卷的卷名（仅 UI 展示用，只读）。
    static func volumeName(path: String) -> String? {
        try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeNameKey]).volumeName
    }

    /// 格式化字节数为可读字符串。
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
