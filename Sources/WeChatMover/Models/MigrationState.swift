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

/// 重签名指引弹窗的触发原因（决定指引文案）。
enum ResignGuideReason {
    case appManagementDenied   // TCC「App 管理」未授权（codesign EPERM）
    case notWritable           // /Applications/WeChat.app 当前用户不可写，走终端 sudo 兜底
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
    @Published var showQuitWeChatConfirm = false
    /// 正在等待微信退出（优雅退出 → 必要时强杀）。
    @Published var isQuittingWeChat = false
    /// 正在等待 codesign 重签名结果。
    @Published var isResigning = false
    /// 重签名受阻：弹指引（App 管理授权 / 终端 sudo 兜底）。
    @Published var showAppManagementGuide = false
    /// 指引弹窗的触发原因（决定文案）。
    @Published var resignGuideReason: ResignGuideReason = .appManagementDenied
    /// 迁移目标已存在数据：弹「删除旧数据并重新迁移 / 取消」确认框。
    @Published var showExistingTargetConfirm = false
    /// 冲突的目标路径（仅供确认框文案与删除用）。
    @Published var conflictingTargetPath: String? = nil
    /// 「清理外置数据」二次确认框。
    @Published var showCleanExternalConfirm = false
    /// 外置 WeChatData 占用大小（refresh 慢速统计填充；nil = 未统计）。
    @Published var externalDataSize: Int64? = nil
    /// 中性提示弹窗（非失败，如"数据仍在使用中"）。
    @Published var notice: String? = nil

    /// 运行状态探测（测试可注入假实现）。
    var isWeChatRunning: () -> Bool = WeChatDetector.isRunning
    /// 实际执行重签名的闭包（测试可注入假实现）。
    var resignRunner: (@escaping @Sendable (CodeSigner.ResignResult) -> Void) -> Void =
        CodeSigner.resignWeChat
    /// /Applications/WeChat.app 可写性探测（测试可注入假实现）。
    var isAppBundleWritable: () -> Bool = { CodeSigner.isWritableByCurrentUser() }
    /// 重签名后的 codesign -v 复核（测试可注入假实现，避免扫真实 App）。
    var signatureVerifier: @Sendable () -> Bool = { WeChatDetector.checkSignature() }

    /// 微信来源展示文案。
    var sourceDescription: String {
        guard wechat.isInstalled else { return "—" }
        return wechat.isAppStoreVersion ? "App Store 版" : "官网 DMG 版"
    }

    /// 容器根目录（测试可注入临时目录 fixture，默认真实路径）。
    var containerRoot = WeChatPaths.defaultContainerRoot

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

    /// 迁移按钮是否可用。微信正在运行不再禁用按钮：
    /// 点击后由 requestMigration() 弹确认框引导退出微信。
    var canMigrate: Bool {
        wechat.isInstalled && !wechat.isAppStoreVersion
            && !localItems.isEmpty && targetBase != nil && isTargetAPFS
            && containerReadable && interruptedItems.isEmpty && !isBusy && !isQuittingWeChat
    }

    var canRestore: Bool {
        !migratedItems.isEmpty && !wechat.isRunning && !isBusy
    }

    var canDeleteBackups: Bool {
        !backupItems.isEmpty && !isBusy
    }

    /// 外置数据根目录：<用户选择的目标文件夹>/WeChatData。
    var externalDataURL: URL? {
        targetBase.map { WeChatPaths.targetRoot(forBase: $0) }
    }

    /// 外置 WeChatData 是否存在（决定「清理外置数据」按钮显隐）。
    var hasExternalData: Bool {
        guard let url = externalDataURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    var canCleanExternalData: Bool {
        hasExternalData && !isBusy
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

            // 外置 WeChatData 占用（状态面板展示；可能分钟级，放最后）。
            var extSize: Int64? = nil
            if let savedTarget {
                let root = WeChatPaths.targetRoot(forBase: URL(fileURLWithPath: savedTarget))
                if FileManager.default.fileExists(atPath: root.path) {
                    extSize = DiskProbe.directorySize(at: root)
                }
            }
            await self?.applyExternalDataSize(extSize)
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

    private func applyExternalDataSize(_ size: Int64?) {
        externalDataSize = size
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
        externalDataSize = nil   // 目标变了，占用大小待下次 refresh 重新统计
    }

    // MARK: - 目标选择

    /// 弹系统级对话框前的统一动作：激活 App。
    /// ad-hoc 手工打包的 App 可能处于未激活状态，此时系统面板/密码框无法前置而假死。
    /// 所有系统对话框入口（NSOpenPanel、osascript 提权/自动化弹窗）都必须先调它。
    func activateApp() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    func chooseTarget() {
        let panel = NSOpenPanel()
        panel.title = "选择外置硬盘上的目标文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        // 先激活 App，再用异步 begin 弹窗（同步 runModal 会假死）。
        activateApp()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                self?.applyTargetSelection(url)
            }
        }
    }

    /// 选中目标文件夹后的处理（与弹窗解耦，可单测）。
    func applyTargetSelection(_ url: URL) {
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

    /// 「一键迁移」按钮入口：微信正在运行时先弹确认框引导退出，否则直接进迁移确认页。
    func requestMigration() {
        guard canMigrate else { return }
        // 刷新一次运行状态，避免上次探测后用户又打开了微信。
        wechat.isRunning = isWeChatRunning()
        if wechat.isRunning {
            showQuitWeChatConfirm = true
        } else {
            showMigrateSheet = true
        }
    }

    /// 确认框「退出微信并继续」：优雅退出 → 等几秒 → 必要时强杀，成功后进迁移确认页。
    func quitWeChatAndContinue() {
        // AppleScript quit 可能触发「自动化」权限弹窗，先激活 App。
        activateApp()
        isQuittingWeChat = true
        log("正在退出微信…")
        Task.detached { [weak self] in
            let quit = await WeChatQuitter.ensureQuit()
            await self?.quitWeChatFinished(quit)
        }
    }

    private func quitWeChatFinished(_ quit: Bool) {
        isQuittingWeChat = false
        wechat.isRunning = isWeChatRunning()
        if quit && !wechat.isRunning {
            log("✅ 微信已退出")
            showMigrateSheet = true
        } else {
            lastError = "无法退出微信，请手动退出后重试。"
            log("❌ 退出微信失败")
        }
    }

    func startMigration() {
        guard let base = targetBase else { return }
        // 兜底：确认页打开期间微信又被启动，拒绝迁移。
        wechat.isRunning = isWeChatRunning()
        guard !wechat.isRunning else {
            lastError = "微信正在运行，请先退出微信再迁移。"
            log("❌ 迁移被拒绝：微信正在运行")
            return
        }
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
            var failed: (any Error)? = nil
            do {
                try Migrator.checkSpace(totalBytes: total, targetPath: base.path)
                for item in todo {
                    let target = WeChatPaths.targetDirectory(base: base, subdir: item.subdir)
                    try Migrator.migrateItem(source: item.source, target: target)
                    await self?.log("✅ 已迁移：\(item.displayName)")
                }
            } catch {
                failed = error
            }
            await self?.migrationFinished(error: failed)
            poller.cancel()
        }
    }

    private func migrationFinished(error: (any Error)?) {
        isBusy = false
        progress = 1
        if let error {
            if case MigrationError.targetAlreadyExists(let path) = error {
                // 目标已存在：可能来自上次迁移中断或重复迁移，
                // 不直接判失败，弹确认框让用户选择删除旧数据后重新迁移。
                conflictingTargetPath = path
                showExistingTargetConfirm = true
                log("⚠️ 目标位置已有数据，可能来自上次迁移中断或重复迁移：\(path)")
            } else {
                lastError = error.localizedDescription
                log("❌ 迁移失败：\(error.localizedDescription)")
            }
        } else {
            log("全部迁移完成，正在重签名微信…")
            resignWeChat()
            showGuide = true
        }
        refresh()
    }

    /// 冲突路径必须形如 <base>/WeChatData/<子目录> 才允许删除，防误删（纯逻辑，可单测）。
    nonisolated static func isConflictPathInsideTarget(_ path: String, base: URL) -> Bool {
        path.hasPrefix(base.path + "/WeChatData/")
    }

    /// 确认框「删除旧数据并重新迁移」：删掉冲突目标后重跑迁移。
    func removeConflictingTargetAndMigrate() {
        guard let path = conflictingTargetPath, let base = targetBase else { return }
        guard Self.isConflictPathInsideTarget(path, base: base) else {
            conflictingTargetPath = nil
            lastError = "路径不在所选目标目录内，已拒绝删除：\(path)"
            log("❌ 拒绝删除目标目录外的路径：\(path)")
            return
        }
        conflictingTargetPath = nil
        isBusy = true
        progress = 0
        log("正在删除旧目标数据：\(path) …")
        Task.detached { [weak self] in
            do {
                try FileManager.default.removeItem(atPath: path)
                await self?.log("✅ 已删除旧数据，重新迁移…")
                await self?.startMigration()
            } catch {
                await self?.removeConflictFailed(error.localizedDescription)
            }
        }
    }

    private func removeConflictFailed(_ message: String) {
        isBusy = false
        lastError = "删除旧数据失败：\(message)"
        log("❌ 删除旧数据失败：\(message)")
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

    /// 直接执行 codesign 重签名（不提权、不弹密码框）。
    /// 包不可写（罕见：所有者不是当前用户）时直接弹终端 sudo 兜底指引。
    func resignWeChat() {
        guard !isResigning else { return }
        activateApp()
        guard isAppBundleWritable() else {
            resignGuideReason = .notWritable
            showAppManagementGuide = true
            log("⚠️ \(CodeSigner.wechatAppPath) 当前用户不可写，请按指引在终端执行 sudo 命令")
            return
        }
        isResigning = true
        log("正在重签名微信…")
        resignRunner { [weak self] result in
            Task { @MainActor [weak self] in
                self?.resignFinished(result: result)
            }
        }
    }

    private func resignFinished(result: CodeSigner.ResignResult) {
        isResigning = false
        switch result {
        case .success:
            if let v = wechat.version {
                UserDefaults.standard.set(v, forKey: DefaultsKey.lastSignedVersion)
            }
            log("✅ 微信重签名完成，正在复核签名…")
            refresh()
            // 签名后自动 codesign -v 复核，结果回日志。
            let verifier = signatureVerifier
            Task.detached { [weak self] in
                let ok = verifier()
                await self?.resignVerified(ok)
            }
        case .appManagementDenied(let detail):
            // TCC「App 管理」权限缺失：弹授权指引（含终端兜底命令）。
            resignGuideReason = .appManagementDenied
            log("⚠️ 重签名被系统拒绝：缺少「App 管理」权限（\(detail)）")
            showAppManagementGuide = true
            refresh()
        case .failed(let message):
            log("⚠️ 重签名未完成：\(message)")
            refresh()
        }
    }

    private func resignVerified(_ ok: Bool) {
        wechat.signatureValid = ok
        if ok {
            log("✅ 签名有效（codesign -v 复核通过）")
        } else {
            log("⚠️ 重签名后复核仍未通过，请重试；或按指引在终端执行兜底命令")
        }
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

    // MARK: - 清理外置数据

    /// 是否仍有迁移项的软链指向 WeChatData 内部（仍在使用，禁止删除）。纯逻辑，可单测。
    nonisolated static func isExternalDataInUse(items: [ItemStatus], dataRoot: URL) -> Bool {
        let prefix = dataRoot.path + "/"
        return items.contains { item in
            guard DiskProbe.isSymlink(item.source),
                  let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: item.source.path)
            else { return false }
            // 本工具建的软链是绝对路径；兜底兼容相对路径
            let resolved = dest.hasPrefix("/") ? dest : URL(
                fileURLWithPath: dest,
                relativeTo: item.source.deletingLastPathComponent()
            ).standardizedFileURL.path
            return resolved == dataRoot.path || resolved.hasPrefix(prefix)
        }
    }

    /// 删除前确认路径形如 <目标文件夹>/WeChatData，防误删（纯逻辑，可单测）。
    nonisolated static func isExternalDataPathValid(_ path: String, base: URL) -> Bool {
        path == WeChatPaths.targetRoot(forBase: base).path
    }

    /// 「清理外置数据…」按钮：安全校验 → 后台统计大小 → 弹二次确认框。
    func requestCleanExternalData() {
        guard let base = targetBase, let root = externalDataURL else { return }
        // 安全校验 1：仍有软链指向其中 → 数据在使用中
        guard !Self.isExternalDataInUse(items: items, dataRoot: root) else {
            notice = "外置数据仍在使用中（存在指向它的符号链接）。如不再需要，请先「一键还原」再清理。"
            log("⚠️ 清理被拒绝：外置数据仍在使用中")
            return
        }
        // 安全校验 2：路径形态必须是 <目标文件夹>/WeChatData
        guard Self.isExternalDataPathValid(root.path, base: base) else {
            lastError = "路径校验失败，已拒绝删除：\(root.path)"
            log("❌ 清理被拒绝：路径形态异常 \(root.path)")
            return
        }
        isBusy = true
        log("正在统计外置数据大小…")
        Task.detached { [weak self] in
            let size = DiskProbe.directorySize(at: root)
            await self?.externalDataSized(size)
        }
    }

    private func externalDataSized(_ size: Int64) {
        isBusy = false
        externalDataSize = size
        showCleanExternalConfirm = true
    }

    /// 二次确认「删除」后执行。
    func cleanExternalData() {
        guard let base = targetBase, let root = externalDataURL,
              Self.isExternalDataPathValid(root.path, base: base) else { return }
        // 确认框打开期间状态可能变化，再查一次使用中
        guard !Self.isExternalDataInUse(items: items, dataRoot: root) else {
            notice = "外置数据仍在使用中（存在指向它的符号链接）。如不再需要，请先「一键还原」再清理。"
            log("⚠️ 清理被拒绝：外置数据仍在使用中")
            return
        }
        isBusy = true
        log("正在删除外置数据：\(root.path) …")
        Task.detached { [weak self] in
            var failed: String? = nil
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                failed = error.localizedDescription
            }
            await self?.cleanExternalDataFinished(error: failed)
        }
    }

    private func cleanExternalDataFinished(error: String?) {
        isBusy = false
        if let error {
            lastError = "删除外置数据失败：\(error)"
            log("❌ 删除外置数据失败：\(error)")
        } else {
            log("✅ 已清理外置数据，释放空间 \(DiskProbe.formatBytes(externalDataSize ?? 0))")
            externalDataSize = nil
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
