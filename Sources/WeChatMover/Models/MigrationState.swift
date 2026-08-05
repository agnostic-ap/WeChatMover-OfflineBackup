import Foundation
import AppKit

/// 单个候选子目录的迁移状态。
enum ItemState: Equatable, Sendable {
    case missing        // 源不存在（该目录无数据）
    case local          // 源是普通目录，尚未迁移
    case migrated       // 源是有效软链，目标可达
    case brokenSymlink  // 源是软链但目标不可达（外置盘未插入）
    case interrupted    // 迁移中断残留：源位不是软链但 _backup 已存在
}

/// 推断某子目录当前状态（纯逻辑，单测用临时目录验证）。
func itemState(at source: URL) -> ItemState {
    let fm = FileManager.default
    if DiskProbe.isSymlink(source) {
        return fm.fileExists(atPath: source.path) ? .migrated : .brokenSymlink
    }
    let backupExists = fm.fileExists(atPath: WeChatPaths.backupDirectory(for: source).path)
    if fm.fileExists(atPath: source.path) {
        return backupExists ? .interrupted : .local
    }
    return backupExists ? .interrupted : .missing
}

struct ItemStatus: Identifiable, Sendable {
    let subdir: String
    let source: URL
    let state: ItemState
    var size: Int64
    var hasBackup: Bool
    var backupSize: Int64
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
    /// 数据大小递归枚举（可能分钟级）是否已完成；未完成时大小字段显示"统计中…"。
    @Published var sizesLoaded = false
    @Published var homeFreeSpace: Int64? = nil
    @Published var showBackupConfirm = false

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
    var interruptedItems: [ItemStatus] { items.filter { $0.state == .interrupted } }
    var backupItems: [ItemStatus] { items.filter { $0.hasBackup } }
    var totalLocalSize: Int64 { localItems.reduce(0) { $0 + $1.size } }
    var totalDataSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var totalBackupSize: Int64 { backupItems.reduce(0) { $0 + $1.backupSize } }

    var modeDescription: String {
        if !migratedItems.isEmpty {
            return backupItems.isEmpty ? "已外置（部分或全部）" : "已外置（本地备份待清理）"
        }
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
            && containerReadable && interruptedItems.isEmpty && !isBusy
    }

    var canRestore: Bool {
        !migratedItems.isEmpty && !wechat.isRunning && !isBusy
    }

    var canDeleteBackups: Bool {
        !backupItems.isEmpty && !isBusy
    }

    // MARK: - 刷新（渐进式并行加载）

    /// 每类字段独立后台填充：版本/来源与磁盘余量秒出，数据大小"统计中…"，
    /// 签名校验不在启动路径（默认"未检测"，由用户手动触发或重签名后自动跑）。
    func refresh() {
        isLoading = true
        sizesLoaded = false
        let containerRoot = self.containerRoot
        let savedTarget = UserDefaults.standard.string(forKey: DefaultsKey.targetBasePath)
        if let savedTarget {
            targetBase = URL(fileURLWithPath: savedTarget)
        }

        // 1) 微信本体检测：只读 /Applications/WeChat.app 的 Info.plist，毫秒级。
        Task.detached { [weak self] in
            let info = WeChatDetector.detect()
            await self?.applyWeChat(info)
        }

        // 2) 磁盘余量与目标卷格式：statfs，秒出。
        Task.detached { [weak self] in
            let homeFree = DiskProbe.freeSpace(path: NSHomeDirectory())
            var fsType: String? = nil
            var free: Int64? = nil
            if let savedTarget {
                fsType = DiskProbe.volumeFSType(path: savedTarget)
                free = DiskProbe.freeSpace(path: savedTarget)
            }
            await self?.applyDiskInfo(homeFree: homeFree, targetFSType: fsType, targetFree: free)
        }

        // 3) 容器状态（首次可能触发 TCC 授权弹窗，先出状态不含大小），
        //    随后才做可能分钟级的目录大小枚举。
        Task.detached { [weak self] in
            let readable = PermissionHelper.canReadContainer(path: containerRoot.path)
            let items: [ItemStatus] = WeChatPaths.candidateSubdirs.compactMap { subdir in
                let source = WeChatPaths.sourceDirectory(containerRoot: containerRoot, subdir: subdir)
                let state = itemState(at: source)
                guard state != .missing else { return nil }
                let hasBackup = FileManager.default.fileExists(
                    atPath: WeChatPaths.backupDirectory(for: source).path)
                return ItemStatus(subdir: subdir, source: source, state: state,
                                  size: 0, hasBackup: hasBackup, backupSize: 0)
            }
            await self?.applyItems(items, readable: readable)

            // 慢速：递归统计大小（含备份大小），完成后单独填充。
            var sized = items
            for i in sized.indices {
                switch sized[i].state {
                case .local:
                    sized[i].size = DiskProbe.directorySize(at: sized[i].source)
                case .migrated:
                    sized[i].size = DiskProbe.directorySize(at: Self.resolvingSymlink(sized[i].source))
                case .brokenSymlink, .missing, .interrupted:
                    sized[i].size = 0
                }
                if sized[i].hasBackup {
                    sized[i].backupSize = DiskProbe.directorySize(
                        at: WeChatPaths.backupDirectory(for: sized[i].source))
                }
            }
            await self?.applySizes(sized)
        }
    }

    private func applyWeChat(_ info: WeChatInfo) {
        // 保留已检测过的签名状态（refresh 不清空手动检测结果）
        var info = info
        info.signatureValid = wechat.signatureValid
        wechat = info
        isLoading = false
    }

    private func applyDiskInfo(homeFree: Int64?, targetFSType fs: String?, targetFree: Int64?) {
        homeFreeSpace = homeFree
        targetFSType = fs
        targetFreeSpace = targetFree
    }

    private func applyItems(_ items: [ItemStatus], readable: Bool) {
        self.items = items
        containerReadable = readable
    }

    private func applySizes(_ sized: [ItemStatus]) {
        items = sized
        sizesLoaded = true
    }

    /// 手动触发签名校验（codesign --verify 要扫整个 App，较慢，后台执行）。
    func checkSignatureNow() {
        guard wechat.isInstalled else { return }
        wechat.signatureValid = nil
        Task.detached { [weak self] in
            let ok = WeChatDetector.checkSignature()
            await self?.applySignature(ok)
        }
    }

    private func applySignature(_ ok: Bool) {
        wechat.signatureValid = ok
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
        if error == nil { checkSignatureNow() }
    }

    // MARK: - 删除备份

    /// 一键删除全部本地备份（逐个做安全检查，失败的跳过并记录日志）。
    func deleteAllBackups() {
        let todo = backupItems
        guard !todo.isEmpty else { return }
        isBusy = true
        log("开始删除 \(todo.count) 个本地备份 …")
        Task.detached { [weak self] in
            var freed: Int64 = 0
            var failures: [String] = []
            for item in todo {
                do {
                    freed += try Migrator.deleteBackup(source: item.source)
                    await self?.log("✅ 已删除备份：\(item.displayName)_backup")
                } catch {
                    failures.append("\(item.displayName)：\(error.localizedDescription)")
                }
            }
            await self?.deleteBackupsFinished(freed: freed, failures: failures)
        }
    }

    private func deleteBackupsFinished(freed: Int64, failures: [String]) {
        isBusy = false
        log("备份清理完成，释放空间 \(DiskProbe.formatBytes(freed))")
        for failure in failures {
            log("⚠️ 跳过：\(failure)")
        }
        if freed == 0, let first = failures.first {
            lastError = first
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
