import Foundation
import Darwin

/// 容器外克隆：备份前把组件整树 clonefile 到本地临时目录（同卷 CoW，
/// 秒级、near-zero 空间），再对克隆归档。
///
/// 为什么需要：macOS 26 对「逐文件访问其他 App 容器」有逐文件系统审查，
/// 大批量读取时每个文件都被拖慢，且高负载下随机超时返回 EINTR，导致
/// ditto 直接归档容器又慢又必然失败（实测 45GB 容器无法完成）。
/// 整树 clonefile 只需一次调用，7 秒即可克隆 45GB；克隆位于容器外，
/// 后续归档不再受审查，快 15 倍且零错误。
enum ContainerCloner {
    /// 克隆后从副本中剔除的文件（仅容器根层）：
    /// containermanagerd 的元数据 plist 受系统保护、应用读不了也不该备份，
    /// 恢复后系统会自动重建。
    static let skipRootNames: Set<String> = [".com.apple.containermanagerd.metadata.plist"]

    /// 克隆临时目录名前缀（删除白名单：只允许删带此前缀的目录）。
    static let clonePrefix = "wcm-clone-"

    enum CloneError: Error, LocalizedError, Equatable {
        case interrupted            // EINTR，可重试
        case failed(errno: Int32)

        var errorDescription: String? {
            switch self {
            case .interrupted: return "克隆被系统中断（EINTR）"
            case .failed(let code):
                return "clonefile 失败：\(String(cString: strerror(code)))"
            }
        }
    }

    /// 默认克隆操作：clonefile(2)，不跟随符号链接。
    static func systemCloneFile(_ source: URL, _ destination: URL) throws {
        guard clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            throw errno == EINTR ? CloneError.interrupted : CloneError.failed(errno: errno)
        }
    }

    /// 整树克隆 source → destination（destination 不得已存在）。
    /// EINTR 自动重试（整树克隆是原子的，重试代价为零）。
    static func cloneTree(
        source: URL,
        to destination: URL,
        maxAttempts: Int = 5,
        cloneOp: (URL, URL) throws -> Void = systemCloneFile,
        log: (String) -> Void = { _ in }
    ) throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try cloneOp(source, destination)
                return
            } catch CloneError.interrupted where attempt < maxAttempts {
                log("克隆被中断，重试（第 \(attempt) 次）…")
                usleep(200_000)
            }
        }
    }

    /// 剔除克隆根层的受保护系统文件，返回剔除的文件名。
    /// 只在我们自己的克隆副本上操作，源目录分毫不动。
    @discardableResult
    static func pruneProtectedFiles(inCloneRoot root: URL) -> [String] {
        var pruned: [String] = []
        for name in skipRootNames {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                if (try? FileManager.default.removeItem(at: url)) != nil {
                    pruned.append(name)
                }
            }
        }
        return pruned
    }

    /// 删除克隆临时目录。微信数据里可能有只读权限的目录（如收到的文件夹），
    /// 克隆保留了这些权限，直接删会 Permission denied，所以先递归加回写权限。
    /// 安全约束：只允许删除名称带 clonePrefix 的目录。
    static func removeClone(_ directory: URL) {
        guard directory.lastPathComponent.hasPrefix(clonePrefix) else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        if (try? fm.removeItem(at: directory)) != nil { return }
        // 只读目录挡路：递归解除后重删。
        _ = ZipArchiver.runProcess("/bin/chmod", ["-R", "u+w", directory.path])
        try? fm.removeItem(at: directory)
    }

    /// 为一次组件克隆生成临时父目录（位于用户临时目录，与 home 同卷）。
    static func makeCloneParent() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(clonePrefix + UUID().uuidString, isDirectory: true)
    }

    /// 克隆所需的本地空间估计（CoW 只耗元数据：按文件数估 + 固定余量）。
    static func estimatedCloneOverhead(fileCount: Int) -> Int64 {
        Int64(fileCount) * 16_384 + (256 << 20)
    }
}
