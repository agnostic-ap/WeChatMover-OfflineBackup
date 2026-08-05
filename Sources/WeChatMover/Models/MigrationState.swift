import Foundation
import AppKit

/// 单个候选子目录的迁移状态。
enum ItemState: Equatable, Sendable {
    case missing        // 源不存在（该目录无数据）
    case local          // 源是普通目录，尚未迁移
    case migrated       // 源是有效软链，目标可达
    case brokenSymlink  // 源是软链但目标不可达（外置盘未插入）
}

/// 推断某子目录当前状态（纯逻辑，单测用临时目录验证）。
func itemState(at source: URL) -> ItemState {
    let fm = FileManager.default
    if DiskProbe.isSymlink(source) {
        return fm.fileExists(atPath: source.path) ? .migrated : .brokenSymlink
    }
    return fm.fileExists(atPath: source.path) ? .local : .missing
}

struct ItemStatus: Identifiable, Sendable {
    let subdir: String
    let source: URL
    let state: ItemState
    let size: Int64
    var id: String { subdir }

    var displayName: String { (subdir as NSString).lastPathComponent }
}

enum DefaultsKey {
    static let targetBasePath = "targetBasePath"
    static let lastSignedVersion = "lastSignedVersion"
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var wechat = WeChatInfo()
    @Published var items: [ItemStatus] = []
    @Published var targetBase: URL? = nil
    @Published var targetFSType: String? = nil
    @Published var targetFreeSpace: Int64? = nil
    @Published var containerReadable = true
    @Published var logs: [String] = []
    @Published var isBusy = false
    @Published var progress: Double = 0
    @Published var showGuide = false
    @Published var showMigrateSheet = false
    @Published var showNonAPFSAlert = false
    @Published var lastError: String? = nil
    /// 首次/刷新探测进行中：UI 显示"加载中…"占位，避免把默认值误显示成"未安装"。
    @Published var isLoading = false

    /// 微信来源展示文案。
    var sourceDescription: String {
        guard wechat.isInstalled else { return "—" }
        return wechat.isAppStoreVersion ? "App Store 版" : "官网 DMG 版"
    }

    private let containerRoot = WeChatPaths.defaultContainerRoot

    // MARK: - 派生状态

    var localItems: [ItemStatus] { items.filter { $0.state == .local } }
    var migratedItems: [ItemStatus] { items.filter { $0.state == .migrated } }
    var brokenItems: [ItemStatus] { items.filter { $0.state == .brokenSymlink } }
    var totalLocalSize: Int64 { localItems.reduce(0) { $0 + $1.size } }
    var totalDataSize: Int64 { items.reduce(0) { $0 + $1.size } }

    var modeDescription: String {
        if !migratedItems.isEmpty { return "已外置（部分或全部）" }
        if !brokenItems.isEmpty { return "已外置（硬盘未连接）" }
        return "内置"
    }

    var isTargetAPFS: Bool {
        guard let fs = targetFSType else { return false }
        return DiskProbe.isAPFS(fsTypeName: fs)
    }

    /// 微信版本相对上次签名是否变化（提示需要重签名）。
    var wechatVersionChanged: Bool {
        guard let current = wechat.version else { return false }
        guard let last = UserDefaults.standard.string(forKey: DefaultsKey.lastSignedVersion) else { return false }
        return current != last
    }

    /// 迁移按钮是否可用。
    var canMigrate: Bool {
        wechat.isInstalled && !wechat.isAppStoreVersion && !wechat.isRunning
            && !localItems.isEmpty && targetBase != nil && isTargetAPFS
            && containerReadable && !isBusy
    }

    var canRestore: Bool {
        !migratedItems.isEmpty && !wechat.isRunning && !isBusy
    }

    // MARK: - 刷新

    /// 后台探测结果，一次性回灌到 UI。
    private struct ProbeResult: Sendable {
        var wechat: WeChatInfo
        var containerReadable: Bool
        var items: [ItemStatus]
        var targetBasePath: String?
        var targetFSType: String?
        var targetFreeSpace: Int64?
    }

    func refresh() {
        isLoading = true
        let containerRoot = self.containerRoot
        let savedTarget = UserDefaults.standard.string(forKey: DefaultsKey.targetBasePath)
        // 所有磁盘探测 / 外部进程调用都在后台线程执行，UI 立即渲染"加载中…"。
        Task.detached { [weak self] in
            // 只依赖 /Applications/WeChat.app 本体（无需任何权限），绝不依赖容器访问。
            var info = WeChatDetector.detect()
            if info.isInstalled {
                info.signatureValid = WeChatDetector.checkSignature()
            }

            let readable = PermissionHelper.canReadContainer(path: containerRoot.path)

            let items: [ItemStatus] = WeChatPaths.candidateSubdirs.compactMap { subdir in
                let source = WeChatPaths.sourceDirectory(containerRoot: containerRoot, subdir: subdir)
                let state = itemState(at: source)
                guard state != .missing else { return nil }
                let size: Int64
                switch state {
                case .local:
                    size = DiskProbe.directorySize(at: source)
                case .migrated:
                    size = DiskProbe.directorySize(at: Self.resolvingSymlink(source))
                case .brokenSymlink, .missing:
                    size = 0
                }
                return ItemStatus(subdir: subdir, source: source, state: state, size: size)
            }

            var fsType: String? = nil
            var free: Int64? = nil
            if let savedTarget {
                fsType = DiskProbe.volumeFSType(path: savedTarget)
                free = DiskProbe.freeSpace(path: savedTarget)
            }

            let result = ProbeResult(
                wechat: info, containerReadable: readable, items: items,
                targetBasePath: savedTarget, targetFSType: fsType, targetFreeSpace: free)
            await self?.applyRefresh(result)
        }
    }

    private func applyRefresh(_ result: ProbeResult) {
        wechat = result.wechat
        containerReadable = result.containerReadable
        items = result.items
        if let path = result.targetBasePath {
            targetBase = URL(fileURLWithPath: path)
        }
        targetFSType = result.targetFSType
        targetFreeSpace = result.targetFreeSpace
        isLoading = false
    }

    private nonisolated static func resolvingSymlink(_ url: URL) -> URL {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? url
    }

    func refreshTargetInfo() {
        guard let base = targetBase else {
            targetFSType = nil; targetFreeSpace = nil; return
        }
        targetFSType = DiskProbe.volumeFSType(path: base.path)
        targetFreeSpace = DiskProbe.freeSpace(path: base.path)
    }

    // MARK: - 目标选择

    func chooseTarget() {
        let panel = NSOpenPanel()
        panel.title = "选择外置硬盘上的目标文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        targetBase = url
        UserDefaults.standard.set(url.path, forKey: DefaultsKey.targetBasePath)
        refreshTargetInfo()
        log("已选择目标位置：\(url.path)")
        if let fs = targetFSType {
            log("目标卷格式：\(fs)，剩余：\(DiskProbe.formatBytes(targetFreeSpace ?? 0))")
            if !DiskProbe.isAPFS(fsTypeName: fs) { showNonAPFSAlert = true }
        }
    }

    // MARK: - 迁移 / 还原

    func startMigration() {
        guard let base = targetBase else { return }
        let todo = localItems
        isBusy = true
        progress = 0
        log("开始迁移 \(todo.count) 个目录，共 \(DiskProbe.formatBytes(totalLocalSize)) …")

        let total = max(totalLocalSize, 1)
        // 轮询也在后台做（目录大小枚举可能很慢），只把结果送回主线程。
        let poller = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, await self.isBusy else { return }
                let done = todo.reduce(Int64(0)) { sum, item in
                    let t = WeChatPaths.targetDirectory(base: base, subdir: item.subdir)
                    if FileManager.default.fileExists(atPath: t.path) {
                        return sum + min(DiskProbe.directorySize(at: t), item.size)
                    }
                    return sum + (itemState(at: item.source) == .migrated ? item.size : 0)
                }
                await self.setProgress(min(Double(done) / Double(total), 1))
            }
        }

        Task.detached { [weak self] in
            var failed: String? = nil
            do {
                try Migrator.checkSpace(totalBytes: total, targetPath: base.path)
                for item in todo {
                    let target = WeChatPaths.targetDirectory(base: base, subdir: item.subdir)
                    try Migrator.migrateItem(source: item.source, target: target)
                    await self?.log("✅ 已迁移：\(item.displayName)")
                }
            } catch {
                failed = error.localizedDescription
            }
            await self?.migrationFinished(error: failed)
            poller.cancel()
        }
    }

    private func migrationFinished(error: String?) {
        isBusy = false
        progress = 1
        if let error {
            lastError = error
            log("❌ 迁移失败：\(error)")
        } else {
            log("全部迁移完成，正在重签名微信…")
            resignWeChat()
            showGuide = true
        }
        refresh()
    }

    func startRestore() {
        guard let base = targetBase else { return }
        let todo = migratedItems
        isBusy = true
        progress = 0
        log("开始还原 \(todo.count) 个目录 …")
        Task.detached { [weak self] in
            var failed: String? = nil
            do {
                for item in todo {
                    let target = WeChatPaths.targetDirectory(base: base, subdir: item.subdir)
                    try Migrator.restoreItem(source: item.source, target: target)
                    await self?.log("✅ 已还原：\(item.displayName)")
                }
            } catch {
                failed = error.localizedDescription
            }
            await self?.restoreFinished(error: failed)
        }
    }

    private func restoreFinished(error: String?) {
        isBusy = false
        progress = 1
        if let error {
            lastError = error
            log("❌ 还原失败：\(error)")
        } else {
            log("全部还原完成，正在重签名微信…")
            resignWeChat()
        }
        refresh()
    }

    /// osascript 提权弹窗会阻塞，放后台执行。
    func resignWeChat() {
        Task.detached { [weak self] in
            let err = CodeSigner.resignWeChat()
            await self?.resignFinished(error: err)
        }
    }

    private func resignFinished(error: String?) {
        if let error {
            log("⚠️ 重签名未完成：\(error)")
        } else {
            if let v = wechat.version {
                UserDefaults.standard.set(v, forKey: DefaultsKey.lastSignedVersion)
            }
            log("✅ 微信重签名完成")
        }
        refresh()
    }

    private func setProgress(_ value: Double) {
        progress = value
    }

    func log(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(stamp)] \(message)")
    }
}
