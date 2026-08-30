import Foundation
import CryptoKit

/// SHA-256 计算（流式读文件，内存占用恒定）。
enum Checksum {
    static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 目录统计：文件数 + 逻辑大小。包含隐藏文件，不跟随符号链接（符号链接按 0 字节计）。
enum FileStats {
    static func measure(at url: URL) -> (fileCount: Int, logicalSize: Int64) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []   // 不跳隐藏文件：备份必须完整
        ) else { return (0, 0) }
        var count = 0
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            count += 1
            total += Int64(values.fileSize ?? 0)
        }
        return (count, total)
    }
}
