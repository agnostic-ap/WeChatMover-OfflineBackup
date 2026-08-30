import Foundation

/// 一个可备份的微信数据组件（容器 / 群组容器 / Application Scripts / 微信应用本体）。
struct BackupComponent: Identifiable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case container        // ~/Library/Containers/…
        case groupContainer   // ~/Library/Group Containers/…
        case appScripts       // ~/Library/Application Scripts/…
        case application      // /Applications/WeChat.app（可选归档，不参与自动恢复）
    }

    /// 稳定 ID，同时用作归档文件名主干（exFAT 安全：仅字母数字点划线）。
    let id: String
    let kind: Kind
    let displayName: String
    /// 相对 home 的路径（application 组件除外，见 WeChatEnvironment.url(for:)）。
    let relativePath: String
}

/// 微信数据所在环境：home 可注入，测试用临时目录 fixture，绝不触碰真实数据。
struct WeChatEnvironment: Sendable {
    var home: URL

    static let live = WeChatEnvironment(home: FileManager.default.homeDirectoryForCurrentUser)

    // MARK: - 微信标识

    static let mainBundleID = "com.tencent.xinWeChat"
    static let groupContainerID = "5A4RE8SF68.com.tencent.xinWeChat"

    /// 名称是否属于微信家族（主 ID 本身，或带 "." 的派生 ID，如
    /// com.tencent.xinWeChat.WeChatMacShare / 5A4RE8SF68.com.tencent.xinWeChat.IPCHelper）。
    static func isWeChatFamilyName(_ name: String) -> Bool {
        name == mainBundleID || name.hasPrefix(mainBundleID + ".")
            || name == groupContainerID || name.hasPrefix(groupContainerID + ".")
    }

    // MARK: - 组件发现

    static let containersDir = "Library/Containers"
    static let groupContainersDir = "Library/Group Containers"
    static let appScriptsDir = "Library/Application Scripts"

    /// 发现当前 home 下实际存在的微信数据组件（按类别扫描 + 白名单前缀匹配）。
    /// 只读操作；不存在的目录自然被跳过。
    func discoverComponents() -> [BackupComponent] {
        var result: [BackupComponent] = []
        result += scan(dir: Self.containersDir, kind: .container, idPrefix: "container")
        result += scan(dir: Self.groupContainersDir, kind: .groupContainer, idPrefix: "group")
        result += scan(dir: Self.appScriptsDir, kind: .appScripts, idPrefix: "scripts")
        return result
    }

    private func scan(dir: String, kind: BackupComponent.Kind, idPrefix: String) -> [BackupComponent] {
        let parent = home.appendingPathComponent(dir, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else {
            return []
        }
        return names.sorted()
            .filter { Self.isWeChatFamilyName($0) }
            .filter { name in
                var isDir: ObjCBool = false
                let path = parent.appendingPathComponent(name).path
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
            .map { name in
                BackupComponent(
                    id: "\(idPrefix)-\(name)",
                    kind: kind,
                    displayName: Self.displayName(kind: kind, name: name),
                    relativePath: "\(dir)/\(name)")
            }
    }

    /// 组件人类化名称。
    static func displayName(kind: BackupComponent.Kind, name: String) -> String {
        switch kind {
        case .container:
            switch name {
            case mainBundleID: return "微信主容器（聊天记录与文件）"
            case mainBundleID + ".WeChatMacShare": return "微信分享扩展容器"
            case mainBundleID + ".WeChatFileProviderExtension": return "微信文件提供扩展容器"
            default: return "微信扩展容器（\(name)）"
            }
        case .groupContainer:
            return "微信共享群组容器"
        case .appScripts:
            return "微信自动化脚本目录（\(name)）"
        case .application:
            return "微信应用本体（WeChat.app）"
        }
    }

    /// 组件的绝对路径。
    func url(for component: BackupComponent) -> URL {
        if component.kind == .application {
            return URL(fileURLWithPath: "/" + component.relativePath, isDirectory: true)
        }
        return home.appendingPathComponent(component.relativePath, isDirectory: true)
    }

    /// 可选归档的微信应用本体组件（不参与自动恢复，仅保存以便手动装回同版本）。
    static let weChatAppComponent = BackupComponent(
        id: "app-WeChat",
        kind: .application,
        displayName: displayName(kind: .application, name: "WeChat.app"),
        relativePath: "Applications/WeChat.app")
}

/// 危险操作（改名让位、落位、清理暂存）路径白名单。
/// 原则：宁可拒绝合法操作，绝不允许在微信白名单之外做任何改动。
enum PathGuard {
    /// url 是否为 home 下三个微信数据父目录之一里、名称属于微信家族
    /// （含本工具追加的 .wcm-… 后缀）的**直接子目录**。
    /// 只允许对这种路径做改名/落位等危险操作。
    static func isProtectedWeChatPath(_ url: URL, home: URL) -> Bool {
        let std = url.standardizedFileURL
        let name = std.lastPathComponent
        guard isWeChatFamilyOrDerivedName(name) else { return false }
        let parentPath = std.deletingLastPathComponent().standardizedFileURL.path
        let allowedParents = [
            WeChatEnvironment.containersDir,
            WeChatEnvironment.groupContainersDir,
            WeChatEnvironment.appScriptsDir,
        ].map { home.appendingPathComponent($0, isDirectory: true).standardizedFileURL.path }
        return allowedParents.contains(parentPath)
    }

    /// 微信家族名，或家族名 + 本工具后缀（.wcm-rollback-… / .wcm-staging-… / .wcm-failed-…）。
    static func isWeChatFamilyOrDerivedName(_ name: String) -> Bool {
        if WeChatEnvironment.isWeChatFamilyName(name) { return true }
        for marker in [".wcm-rollback-", ".wcm-staging-", ".wcm-failed-"] {
            if let range = name.range(of: marker) {
                let base = String(name[name.startIndex..<range.lowerBound])
                return WeChatEnvironment.isWeChatFamilyName(base)
            }
        }
        return false
    }

    /// 暂存目录（可整目录删除的唯一类型）：名称必须带 .wcm-staging- 标记。
    static func isStagingPath(_ url: URL) -> Bool {
        url.lastPathComponent.contains(".wcm-staging-")
    }

    /// 校验后执行删除暂存目录；路径不符白名单则拒绝。
    static func removeStaging(_ url: URL, home: URL) throws {
        guard isStagingPath(url), isProtectedWeChatPath(url, home: home) else {
            throw BackupError.pathNotWhitelisted(url.path)
        }
        try FileManager.default.removeItem(at: url)
    }

    /// 仅校验移动是否被白名单允许（源/目标都必须在白名单内），不做任何 IO。
    static func validateMove(_ from: URL, to: URL, home: URL) throws {
        guard isProtectedWeChatPath(from, home: home), isProtectedWeChatPath(to, home: home) else {
            throw BackupError.pathNotWhitelisted("\(from.path) → \(to.path)")
        }
    }

    /// 校验后执行移动；不符白名单则拒绝。
    static func move(_ from: URL, to: URL, home: URL) throws {
        try validateMove(from, to: to, home: home)
        try FileManager.default.moveItem(at: from, to: to)
    }
}

/// 清单条目合法性校验（纯函数，可单测）：
/// 恶意/损坏的 manifest 不得把恢复引导到白名单之外。
enum ManifestValidation {
    /// archiveName 必须是快照目录的安全直接文件名。返回问题描述（nil = 合法）。
    static func archiveNameProblem(_ name: String) -> String? {
        if name.isEmpty { return "archiveName 为空" }
        if name.contains("/") || name.contains("\\") || name.contains(":") {
            return "archiveName 含路径分隔符：\(name)"
        }
        if name == "." || name == ".." || name.hasPrefix(".") {
            return "archiveName 非法或为隐藏文件：\(name)"
        }
        if !name.hasSuffix(".zip") || name.count <= 4 {
            return "archiveName 不是 .zip 文件：\(name)"
        }
        return nil
    }

    /// 可自动恢复条目的 relativePath 必须精确映射到微信组件白名单：
    /// 恰为「三个允许父目录之一 / 微信家族名」两级结构，无 ".."、不以 "/" 开头，
    /// 且名称不含 .wcm- 派生后缀（不允许恢复进回滚/暂存目录名）。
    static func relativePathProblem(_ relativePath: String, kind: BackupComponent.Kind) -> String? {
        if kind == .application {
            // 应用本体不参与自动恢复，只需不可穿越。
            if relativePath.hasPrefix("/") || relativePath.split(separator: "/").contains("..") {
                return "应用归档 relativePath 非法：\(relativePath)"
            }
            return nil
        }
        if relativePath.hasPrefix("/") { return "relativePath 是绝对路径：\(relativePath)" }
        let expectedParent: String
        switch kind {
        case .container: expectedParent = WeChatEnvironment.containersDir
        case .groupContainer: expectedParent = WeChatEnvironment.groupContainersDir
        case .appScripts: expectedParent = WeChatEnvironment.appScriptsDir
        case .application: expectedParent = ""   // 上面已 return
        }
        let name = (relativePath as NSString).lastPathComponent
        guard relativePath == expectedParent + "/" + name else {
            return "relativePath 不在组件白名单目录内：\(relativePath)"
        }
        guard WeChatEnvironment.isWeChatFamilyName(name) else {
            return "relativePath 末级不是微信家族名：\(relativePath)"
        }
        // 前缀规则会放过 .wcm- 派生名（回滚/暂存目录），恢复目标必须显式排除。
        if name.contains(".wcm-") {
            return "relativePath 指向本工具的派生目录名：\(relativePath)"
        }
        return nil
    }

    /// 汇总清单问题：逐条 archiveName/relativePath，外加
    /// 重复 target、重复 archiveName、无可自动恢复条目。空数组 = 合法。
    static func problems(in manifest: BackupManifest) -> [String] {
        var problems: [String] = []
        for entry in manifest.entries {
            if let p = archiveNameProblem(entry.archiveName) { problems.append(p) }
            if let p = relativePathProblem(entry.relativePath, kind: entry.kind) { problems.append(p) }
        }
        let restorable = manifest.restorableEntries
        if restorable.isEmpty {
            problems.append("清单没有可自动恢复的条目")
        }
        let targets = restorable.map(\.relativePath)
        for dup in Set(targets.filter { t in targets.filter { $0 == t }.count > 1 }) {
            problems.append("重复的恢复目标：\(dup)")
        }
        let archives = manifest.entries.map(\.archiveName)
        for dup in Set(archives.filter { a in archives.filter { $0 == a }.count > 1 }) {
            problems.append("重复的归档文件名：\(dup)")
        }
        return problems
    }
}

/// 备份/恢复错误。
enum BackupError: Error, LocalizedError, Equatable {
    case nothingToBackup
    case wechatStillRunning
    case insufficientSpace(need: Int64, free: Int64)
    case cancelled
    case archiveFailed(String)
    case snapshotIncomplete(String)
    case archiveMissing(String)
    case checksumMismatch(String)
    case unsafeArchiveEntries(archive: String, entries: [String])
    case unexpectedArchiveLayout(String)
    case pathNotWhitelisted(String)
    case restoreFailed(String)
    case vaultPathInvalid(String)
    case vaultOverlapsSource(String)
    case manifestInvalid(String)
    case rollbackIncomplete(String)

    var errorDescription: String? {
        switch self {
        case .nothingToBackup:
            return "未发现任何微信数据，无法备份。请确认本机登录过微信。"
        case .wechatStillRunning:
            return "微信仍在运行，已停止操作。请先完全退出微信后重试。"
        case .insufficientSpace(let need, let free):
            return "磁盘空间不足：需要约 \(DiskProbe.formatBytes(need))，仅剩 \(DiskProbe.formatBytes(free))。"
        case .cancelled:
            return "操作已取消。"
        case .archiveFailed(let msg):
            return "归档失败：\(msg)"
        case .snapshotIncomplete(let name):
            return "快照「\(name)」缺少完成标记，可能是中断的备份，不能用于恢复。"
        case .archiveMissing(let name):
            return "快照缺少归档文件：\(name)"
        case .checksumMismatch(let name):
            return "校验失败（SHA-256 不匹配）：\(name)。归档可能已损坏，已停止操作。"
        case .unsafeArchiveEntries(let archive, let entries):
            return "归档 \(archive) 含不安全路径（拒绝解压）：\(entries.prefix(3).joined(separator: "、"))"
        case .unexpectedArchiveLayout(let msg):
            return "归档结构异常：\(msg)"
        case .pathNotWhitelisted(let path):
            return "路径不在微信数据白名单内，已拒绝危险操作：\(path)"
        case .restoreFailed(let msg):
            return "恢复失败：\(msg)"
        case .vaultPathInvalid(let path):
            return "备份仓库路径无效：\(path)"
        case .vaultOverlapsSource(let msg):
            return "备份位置与微信数据目录重叠，已拒绝（防止递归归档/写入源目录）：\(msg)"
        case .manifestInvalid(let msg):
            return "快照清单校验未通过，已拒绝恢复：\(msg)"
        case .rollbackIncomplete(let msg):
            return "严重：恢复失败且自动回滚未完全成功，任何数据都未被删除，请按以下路径手动处理。\(msg)"
        }
    }
}
