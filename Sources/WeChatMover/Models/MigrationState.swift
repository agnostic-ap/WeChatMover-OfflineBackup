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
    @Published var lastError: String? = nil {
        didSet { if lastError != nil { activeDialog = .error } }
    }
    /// 首次/刷新探测进行中：UI 显示"加载中…"占位，避免把默认值误显示成"未安装"。
    @Published var isLoading = false
    /// 数据大小递归枚举（可能分钟级）是否已完成；未完成时大小字段显示"统计中…"。
    @Published var sizesLoaded = false
    @Published var homeFreeSpace: Int64? = nil
    /// 正在等待微信退出（优雅退出 → 必要时强杀）。
    @Published var isQuittingWeChat = false
    /// 正在等待 codesign 重签名结果。
    @Published var isResigning = false
    /// 重签名受阻指引的触发原因（决定文案）。
    @Published var resignGuideReason: ResignGuideReason = .appManagementDenied
    /// 冲突的目标路径（仅供确认框文案与删除用）。
    @Published var conflictingTargetPath: String? = nil
    /// 外置 WeChatData 占用大小（refresh 慢速统计填充；nil = 未统计）。
    @Published var externalDataSize: Int64? = nil
    /// 中性提示弹窗（非失败，如"数据仍在使用中"）。
    @Published var notice: String? = nil {
        didSet { if notice != nil { activeDialog = .notice } }
    }

    // MARK: - 展示层状态（单一状态源驱动 UI）

    /// 弹窗（Alert/confirmationDialog）单一枚举驱动。
    @Published var activeDialog: ActiveDialog? = nil
    /// 弹层（Sheet）单一枚举驱动。
    @Published var activeSheet: ActiveSheet? = nil
    /// 进行中的操作种类（nil = 空闲）。
    @Published var busyKind: BusyKind? = nil
    /// 最近一次迁移的结果（驱动成功/失败横幅，「完成」或新操作清除）。
    @Published var migrationOutcome: MigrationOutcome? = nil
    /// 还原确认框附加说明（如"外置数据与本地备份一致，可直接使用本地备份"）。
    @Published var restoreNote: String? = nil

    // 兼容既有测试的只读映射（弹窗语义不变）。
    var showExistingTargetConfirm: Bool { activeDialog == .existingTarget }
    var showCleanExternalConfirm: Bool { activeDialog == .cleanExternal }
    var showAppManagementGuide: Bool { activeSheet == .appManagementGuide }

    /// 运行状态探测（测试可注入假实现）。
    var isWeChatRunning: () -> Bool = WeChatDetector.isRunning
    /// 实际执行重签名的闭包（测试可注入假实现）。
    var resignRunner: (@escaping @Sendable (CodeSigner.ResignResult) -> Void) -> Void =
        CodeSigner.resignWeChat
    /// /Applications/WeChat.app 可写性探测（测试可注入假实现）。
    var isAppBundleWritable: () -> Bool = { CodeSigner.isWritableByCurrentUser() }
    /// 重签名后的 codesign -v 复核（测试可注入假实现，避免扫真实 App）。
    var signatureVerifier: @Sendable () -> Bool = { WeChatDetector.checkSignature() }
    /// 退出微信流程（测试可注入假实现，不触碰真实微信）。
    var wechatQuitter: @Sendable () async -> Bool = { await WeChatQuitter.ensureQuit() }

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

    /// 还原按钮是否可用。微信运行中不再禁用：确认后由 confirmRestore() 先退出微信。
    var canRestore: Bool {
        !migratedItems.isEmpty && !isBusy && !isQuittingWeChat
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

    /// 清理按钮可用性收紧：只有没有任何软链还指向外置数据（即已还原/恢复）才可点；
    /// 已迁移状态置灰，Tooltip 说明「还原数据到 Mac 后可清理」。删除前的安全校验不变。
    var canCleanExternalData: Bool {
        guard let root = externalDataURL else { return false }
        return hasExternalData && !isBusy
            && !Self.isExternalDataInUse(items: items, dataRoot: root)
    }

    /// 本地 _backup 仍在且源位是软链（有效或断链均可——恢复流程不依赖外置盘）的项。
    var restorableBackupItems: [ItemStatus] {
        items.filter { $0.hasBackup && ($0.state == .migrated || $0.state == .brokenSymlink) }
    }

    var canRestoreBackups: Bool {
        !restorableBackupItems.isEmpty && !isBusy && !isQuittingWeChat
    }

    /// 仅本地备份有数据：无本地数据、无有效迁移、无中断残留，但 _backup 存在。
    /// 此时「还原内置存储数据到 Mac…」成为主操作。
    var isBackupOnlyState: Bool {
        localItems.isEmpty && migratedItems.isEmpty && interruptedItems.isEmpty
            && !backupItems.isEmpty
    }

    // MARK: - 展示模型（状态 → 横幅/卡片，纯映射，可单测）

    /// 目标磁盘显示名（卷名，取不到用文件夹名）。
    var destinationName: String {
        guard let base = targetBase else { return "" }
        return DiskProbe.volumeName(path: base.path) ?? base.lastPathComponent
    }

    /// 主按钮文案：已有部分数据外置时为「更新迁移」。
    var primaryActionTitle: String {
        migratedItems.isEmpty ? "迁移到外置硬盘" : "更新迁移"
    }

    /// 当前应显示的主操作（同一时刻只有一个）。
    var primaryAction: PrimaryAction {
        if isBackupOnlyState { return .restoreBackups }
        if !localItems.isEmpty { return .migrate }
        if !migratedItems.isEmpty { return .restore }
        return .none
    }

    /// 安全检查待处理项（安全卡片与安全详情共用）。
    var safetyIssues: [String] {
        var issues: [String] = []
        if !wechat.isInstalled { issues.append("未检测到微信") }
        if wechat.isAppStoreVersion { issues.append("App Store 版微信不受支持") }
        if !containerReadable { issues.append("需要完全磁盘访问权限") }
        if !interruptedItems.isEmpty { issues.append("存在迁移中断残留") }
        if wechat.signatureValid == false { issues.append("应用签名已失效") }
        if wechatVersionChanged { issues.append("微信已更新，需要重新签名") }
        return issues
    }

    /// 单一状态源。
    var appStatus: AppStatus {
        if isQuittingWeChat { return .busy(.quittingWeChat, progress: nil) }
        if isResigning { return .busy(.resigning, progress: nil) }
        if let busyKind {
            return .busy(busyKind, progress: busyKind == .migrating ? progress : nil)
        }
        if let migrationOutcome {
            switch migrationOutcome {
            case .succeeded(let items, let bytes):
                return .succeeded(
                    "已迁移 \(items) 项数据（共 \(DiskProbe.formatBytes(bytes))）到 \(destinationName)。"
                    + "打开微信确认正常后，可在下方清理本地备份释放空间。")
            case .failed(let message):
                return .failed(message)
            }
        }
        if isLoading { return .checking }
        guard wechat.isInstalled else { return .blocked(.notInstalled) }
        guard !wechat.isAppStoreVersion else { return .blocked(.appStoreVersion) }
        guard containerReadable else { return .blocked(.containerUnreadable) }
        guard interruptedItems.isEmpty else { return .blocked(.interruptedResidue) }
        // 仅本地备份有数据（外置未连接/未迁移）：给出恢复入口，优先于"硬盘未连接"警告
        if isBackupOnlyState {
            return .backupOnly(count: backupItems.count, bytes: totalBackupSize)
        }
        guard brokenItems.isEmpty else { return .blocked(.diskDisconnected) }
        guard targetBase != nil else { return .blocked(.noDestination) }
        guard isTargetAPFS else {
            return .blocked(.destinationNotAPFS(targetFSType ?? "未知"))
        }
        if sizesLoaded, !localItems.isEmpty,
           let free = targetFreeSpace, free < totalLocalSize {
            return .blocked(.insufficientSpace(need: totalLocalSize, free: free))
        }
        if localItems.isEmpty, !migratedItems.isEmpty { return .externalized }
        return .ready
    }

    /// 就绪状态横幅展示模型。
    var banner: BannerModel {
        switch appStatus {
        case .checking:
            return BannerModel(
                tone: .neutral, symbol: "magnifyingglass",
                title: "正在检查环境…",
                message: "正在检测微信安装状态、数据目录与目标磁盘。")
        case .ready:
            return BannerModel(
                tone: .success, symbol: "checkmark.circle.fill",
                title: "可以开始迁移",
                message: "目标磁盘空间充足，安全检查已通过。将迁移 \(localItems.count) 项数据，共 \(DiskProbe.formatBytes(totalLocalSize))。")
        case .externalized:
            return BannerModel(
                tone: .success, symbol: "checkmark.seal.fill",
                title: "微信数据已在外置硬盘",
                message: "全部数据已迁移到 \(destinationName)。外置盘未连接时请不要打开微信。")
        case .backupOnly(let count, let bytes):
            return BannerModel(
                tone: .info, symbol: "internaldrive",
                title: "检测到本地备份",
                message: "外置硬盘未连接或未迁移，但 Mac 上留有 \(count) 项本地备份（共 \(DiskProbe.formatBytes(bytes))）。可用「还原内置存储数据到 Mac…」回到 Mac 上的旧数据，全程不需要外置硬盘。")
        case .blocked(let blocker):
            return Self.bannerForBlocker(blocker)
        case .busy(let kind, let value):
            return Self.bannerForBusy(kind, progress: value)
        case .succeeded(let summary):
            return BannerModel(
                tone: .success, symbol: "checkmark.seal.fill",
                title: "迁移完成", message: summary)
        case .failed(let message):
            return BannerModel(
                tone: .danger, symbol: "xmark.octagon.fill",
                title: "迁移未完成", message: message, fix: .retryMigration)
        }
    }

    private static func bannerForBlocker(_ blocker: Blocker) -> BannerModel {
        switch blocker {
        case .notInstalled:
            return BannerModel(
                tone: .danger, symbol: "xmark.octagon.fill",
                title: "未检测到微信",
                message: "请先安装微信官网下载版，再使用本工具迁移数据。",
                fix: .openOfficialDownload)
        case .appStoreVersion:
            return BannerModel(
                tone: .danger, symbol: "xmark.octagon.fill",
                title: "暂不支持 App Store 版微信",
                message: "App Store 版受沙盒限制，迁移后软链会失效。请从官网下载 DMG 版覆盖安装。",
                fix: .openOfficialDownload)
        case .containerUnreadable:
            return BannerModel(
                tone: .warning, symbol: "lock.shield",
                title: "需要访问微信数据",
                message: "请在 系统设置 → 隐私与安全性 → 完全磁盘访问权限 中允许 WeChatMover，然后重启本 App。",
                fix: .openFullDiskAccess)
        case .interruptedResidue:
            return BannerModel(
                tone: .warning, symbol: "exclamationmark.triangle.fill",
                title: "检测到迁移中断残留",
                message: "上次迁移中途失败留下了 _backup 目录。请手工检查（一般把 _backup 改名回原名即可恢复）后再操作。")
        case .diskDisconnected:
            return BannerModel(
                tone: .warning, symbol: "exclamationmark.triangle.fill",
                title: "外置硬盘未连接",
                message: "迁移目标不可达。请先连接硬盘再打开微信，否则微信会在 Mac 上新建空数据目录。")
        case .noDestination:
            return BannerModel(
                tone: .info, symbol: "externaldrive",
                title: "选择目标位置",
                message: "在外置硬盘上选择一个文件夹，用于存放迁移后的微信数据。",
                fix: .chooseDestination)
        case .destinationNotAPFS(let fs):
            return BannerModel(
                tone: .warning, symbol: "exclamationmark.triangle.fill",
                title: "目标磁盘格式不受支持",
                message: "当前格式为 \(fs)，该磁盘格式不受支持，请选择 APFS 格式的磁盘。",
                fix: .chooseDestination)
        case .insufficientSpace(let need, let free):
            return BannerModel(
                tone: .warning, symbol: "exclamationmark.triangle.fill",
                title: "目标磁盘空间不足",
                message: "至少需要 \(DiskProbe.formatBytes(need))，当前可用 \(DiskProbe.formatBytes(free))。",
                fix: .chooseDestination)
        }
    }

    private static func bannerForBusy(_ kind: BusyKind, progress: Double?) -> BannerModel {
        switch kind {
        case .migrating:
            let percent = Int(((progress ?? 0) * 100).rounded())
            return BannerModel(
                tone: .info, symbol: "arrow.triangle.2.circlepath",
                title: "正在迁移… \(percent)%",
                message: "迁移期间请不要退出微信或拔出硬盘。",
                progress: progress)
        case .restoring:
            return BannerModel(
                tone: .info, symbol: "arrow.triangle.2.circlepath",
                title: "正在还原外置数据到 Mac…",
                message: "还原期间请不要打开微信或拔出硬盘。")
        case .restoringBackups:
            return BannerModel(
                tone: .info, symbol: "arrow.triangle.2.circlepath",
                title: "正在还原内置备份到 Mac…",
                message: "还原期间请不要打开微信。")
        case .comparing:
            return BannerModel(
                tone: .info, symbol: "arrow.triangle.2.circlepath",
                title: "正在比对数据新旧…",
                message: "对比本地备份与外置硬盘上的数据，大目录可能需要几秒。")
        case .deletingBackups:
            return BannerModel(
                tone: .info, symbol: "arrow.triangle.2.circlepath",
                title: "正在清理本地备份…",
                message: "正在逐项确认软链有效后删除备份。")
        case .sizingExternal:
            return BannerModel(
                tone: .info, symbol: "arrow.triangle.2.circlepath",
                title: "正在统计外置数据大小…",
                message: "大目录可能需要一些时间。")
        case .cleaningExternal:
            return BannerModel(
                tone: .info, symbol: "arrow.triangle.2.circlepath",
                title: "正在清理外置数据…",
                message: "删除期间请不要拔出硬盘。")
        case .quittingWeChat:
            return BannerModel(
                tone: .info, symbol: "arrow.triangle.2.circlepath",
                title: "正在退出微信…",
                message: "优先优雅退出，几秒后未退出会强制结束。")
        case .resigning:
            return BannerModel(
                tone: .info, symbol: "arrow.triangle.2.circlepath",
                title: "正在重签名微信…",
                message: "首次需要在「App 管理」中授权 WeChatMover。")
        }
    }

    /// 三张摘要卡片。
    var summaryCards: [StatusCardModel] {
        [dataCard, destinationCard, safetyCard]
    }

    private var dataCard: StatusCardModel {
        let value = sizesLoaded ? DiskProbe.formatBytes(totalDataSize) : "统计中…"
        let detail: String
        let symbol: String
        let tone: StatusTone
        if !brokenItems.isEmpty {
            detail = "已外置 · 硬盘未连接"; symbol = "externaldrive"; tone = .warning
        } else if !migratedItems.isEmpty {
            detail = backupItems.isEmpty ? "已外置" : "已外置 · 本地备份待清理"
            symbol = "externaldrive"; tone = .success
        } else {
            detail = "位于 Mac"; symbol = "internaldrive"; tone = .neutral
        }
        // 已安装时用真实微信图标；未安装降级为绿色消息气泡
        let customIcon: CardIcon? = wechat.isInstalled ? .weChatApp : nil
        return StatusCardModel(id: "data", title: "微信数据", value: value,
                               detail: detail,
                               symbol: wechat.isInstalled ? symbol : "message.circle.fill",
                               tone: wechat.isInstalled ? tone : .neutral,
                               customIcon: customIcon,
                               iconUsesAccent: !wechat.isInstalled)
    }

    private var destinationCard: StatusCardModel {
        guard targetBase != nil else {
            return StatusCardModel(id: "destination", title: "目标磁盘", value: "未选择",
                                   detail: "选择一个外置硬盘文件夹",
                                   symbol: "externaldrive", tone: .neutral,
                                   iconUsesAccent: true)
        }
        let value = targetFreeSpace.map { DiskProbe.formatBytes($0) + " 可用" } ?? "—"
        let detail = "\(destinationName) · \(targetFSType ?? "未知格式")"
        var tone: StatusTone = .neutral
        if !isTargetAPFS { tone = .warning }
        if sizesLoaded, !localItems.isEmpty,
           let free = targetFreeSpace, free < totalLocalSize { tone = .warning }
        return StatusCardModel(id: "destination", title: "目标磁盘", value: value,
                               detail: detail, symbol: "externaldrive.fill", tone: tone,
                               iconUsesAccent: true)
    }

    private var safetyCard: StatusCardModel {
        let issues = safetyIssues
        let value = isLoading ? "检查中…" : (issues.isEmpty ? "全部通过" : "\(issues.count) 项待处理")
        let signature: String
        switch wechat.signatureValid {
        case .some(true): signature = "应用签名有效"
        case .some(false): signature = "应用签名已失效"
        case .none: signature = "签名未检测"
        }
        let detail = "微信 \(wechat.version ?? "—") · \(signature)"
        return StatusCardModel(
            id: "safety", title: "安全检查", value: value, detail: detail,
            symbol: issues.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
            tone: issues.isEmpty ? .success : .warning)
    }

    /// 迁移确认框摘要（规范 6.3：数据大小、目标路径、提醒）。
    var migrateConfirmMessage: String {
        let names = localItems.map { Copywriting.itemName($0.subdir) }.joined(separator: "、")
        return "将迁移 \(names)（共 \(DiskProbe.formatBytes(totalLocalSize))）到 \(targetBase?.path ?? "")。\n\n"
            + "微信将先退出；迁移期间请不要拔出硬盘。"
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
        migrationOutcome = nil
        refreshTargetInfo()
        log("已选择目标位置：\(url.path)")
        if let fs = targetFSType {
            log("目标卷格式：\(fs)，剩余：\(DiskProbe.formatBytes(targetFreeSpace ?? 0))")
        }
    }

    // MARK: - 迁移 / 还原

    /// 主按钮入口：弹迁移确认框（微信运行中也可点，确认后会先退出微信）。
    func requestMigration() {
        guard canMigrate else { return }
        activeDialog = .migrateConfirm
    }

    /// 确认框「退出微信并开始迁移」：运行中先优雅退出（必要时强杀），成功后直接开始迁移。
    func confirmMigration() {
        quitWeChatIfRunning { [weak self] in self?.startMigration() }
    }

    /// 「还原外置存储数据到 Mac…」入口：有本地备份时先做新旧判定，再决定弹哪个确认框。
    func requestRestore() {
        guard canRestore else { return }
        restoreNote = nil
        let withBackup = migratedItems.filter { $0.hasBackup }
        guard !withBackup.isEmpty, let base = targetBase else {
            // 无本地备份：维持现状，直接从外置还原
            activeDialog = .restoreConfirm
            return
        }
        isBusy = true
        busyKind = .comparing
        log("正在比对数据新旧…")
        Task.detached { [weak self] in
            let same = Self.externalMatchesBackup(items: withBackup, base: base)
            await self?.restoreComparisonFinished(same: same)
        }
    }

    /// 新旧判定：本地备份与外置数据是否一致。
    /// 有 manifest 只重算外置侧（快）；无 manifest（旧迁移）双侧各算一次。
    /// 返回 nil = 无法判定（外置不可读等），调用方回退现有流程。
    nonisolated static func externalMatchesBackup(items: [ItemStatus], base: URL) -> Bool? {
        let manifest = Fingerprint.readManifest(base: base)
        for item in items {
            let target = WeChatPaths.targetDirectory(base: base, subdir: item.subdir)
            guard let external = Fingerprint.compute(at: target) else { return nil }
            let reference: Fingerprint.Value
            if let fromManifest = manifest?.fingerprint(for: item.subdir) {
                reference = fromManifest
            } else {
                let backup = WeChatPaths.backupDirectory(for: item.source)
                guard let fp = Fingerprint.compute(at: backup) else { return nil }
                reference = fp
            }
            if external != reference { return false }
        }
        return true
    }

    private func restoreComparisonFinished(same: Bool?) {
        isBusy = false
        busyKind = nil
        switch same {
        case .some(true):
            // 一致：不弹新旧提示，直接走本地备份还原（快），确认框注明原因
            restoreNote = "外置数据与本地备份一致，可直接使用本地备份还原（更快）。"
            log("外置数据与本地备份一致，直接使用本地备份还原")
            activeDialog = .restoreConfirm
        case .some(false):
            restoreNote = nil
            log("⚠️ 外置数据与本地备份不一致（迁移后可能有新写入）")
            activeDialog = .restoreConflict
        case .none:
            // 比对失败（外置盘断开等）：回退现有流程
            restoreNote = nil
            log("⚠️ 无法读取外置数据进行比对，按原流程继续")
            activeDialog = .restoreConfirm
        }
    }

    /// 还原外置数据确认框「确认还原」：与迁移一致，运行中先退出微信再还原。
    func confirmRestore() {
        quitWeChatIfRunning { [weak self] in self?.startRestore() }
    }

    /// 新旧不一致时「使用外置数据还原」：忽略本地备份，强制从外置盘拷回。
    func confirmRestoreFromExternal() {
        quitWeChatIfRunning { [weak self] in self?.startRestoreFromExternal() }
    }

    /// 还原内置备份确认框「确认还原」：同样先确保微信已退出。
    func confirmRestoreBackups() {
        quitWeChatIfRunning { [weak self] in self?.startRestoreBackups() }
    }

    /// 微信运行中先退出（优雅 → 必要时强杀），成功后才执行后续操作。
    private func quitWeChatIfRunning(then operation: @escaping @MainActor () -> Void) {
        // AppleScript quit 可能触发「自动化」权限弹窗，先激活 App。
        activateApp()
        wechat.isRunning = isWeChatRunning()
        guard wechat.isRunning else { operation(); return }
        isQuittingWeChat = true
        log("正在退出微信…")
        let quitter = wechatQuitter
        Task.detached { [weak self] in
            let quit = await quitter()
            await self?.quitWeChatFinished(quit, then: operation)
        }
    }

    private func quitWeChatFinished(_ quit: Bool, then operation: @MainActor () -> Void) {
        isQuittingWeChat = false
        wechat.isRunning = isWeChatRunning()
        if quit && !wechat.isRunning {
            log("✅ 微信已退出")
            operation()
        } else {
            lastError = "无法退出微信，请手动退出后重试。"
            log("❌ 退出微信失败")
        }
    }

    func startMigration() {
        guard let base = targetBase else { return }
        // 兜底：确认框打开期间微信又被启动，拒绝迁移。
        wechat.isRunning = isWeChatRunning()
        guard !wechat.isRunning else {
            lastError = "微信正在运行，请先退出微信再迁移。"
            log("❌ 迁移被拒绝：微信正在运行")
            return
        }
        let todo = localItems
        isBusy = true
        busyKind = .migrating
        migrationOutcome = nil
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
            var manifestItems: [MigrationManifest.Item] = []
            do {
                try Migrator.checkSpace(totalBytes: total, targetPath: base.path)
                for item in todo {
                    let target = WeChatPaths.targetDirectory(base: base, subdir: item.subdir)
                    try Migrator.migrateItem(source: item.source, target: target)
                    // 迁移时刻的指纹快照（stat 遍历，供还原时新旧判定）
                    if let fp = Fingerprint.compute(at: target) {
                        manifestItems.append(.init(subdir: item.subdir, fingerprint: fp))
                    }
                    await self?.log("✅ 已迁移：\(item.displayName)")
                }
            } catch {
                failed = error
            }
            if failed == nil {
                // 全部成功后写清单；失败只记日志，不影响迁移结果
                do {
                    let version = Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
                    try Fingerprint.writeManifest(
                        MigrationManifest(toolVersion: version, migratedAt: Date(),
                                          items: manifestItems),
                        base: base)
                    await self?.log("已写入迁移清单（manifest.json）")
                } catch {
                    await self?.log("⚠️ 写入迁移清单失败（不影响迁移）：\(error.localizedDescription)")
                }
            }
            await self?.migrationFinished(error: failed)
            poller.cancel()
        }
    }

    private func migrationFinished(error: (any Error)?) {
        isBusy = false
        busyKind = nil
        progress = 1
        if let error {
            if case MigrationError.targetAlreadyExists(let path) = error {
                // 目标已存在：可能来自上次迁移中断或重复迁移，
                // 不直接判失败，弹确认框让用户选择删除旧数据后重新迁移。
                conflictingTargetPath = path
                activeDialog = .existingTarget
                log("⚠️ 目标位置已有数据，可能来自上次迁移中断或重复迁移：\(path)")
            } else {
                migrationOutcome = .failed(error.localizedDescription)
                log("❌ 迁移失败：\(error.localizedDescription)")
            }
        } else {
            migrationOutcome = .succeeded(items: localItems.count, bytes: totalLocalSize)
            log("全部迁移完成，正在重签名微信…")
            resignWeChat()
            activeSheet = .guide
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
        // 兜底：确认框打开期间微信又被启动，拒绝还原。
        wechat.isRunning = isWeChatRunning()
        guard !wechat.isRunning else {
            lastError = "微信正在运行，请先退出微信再还原。"
            log("❌ 还原被拒绝：微信正在运行")
            return
        }
        let todo = migratedItems
        isBusy = true
        busyKind = .restoring
        migrationOutcome = nil
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
        busyKind = nil
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

    /// 强制从外置盘还原（新旧判定不一致、用户选「使用外置数据还原」）：
    /// 忽略本地备份，逐项从外置拷回，过期 _backup 随各项一并清除。
    func startRestoreFromExternal() {
        guard let base = targetBase else { return }
        // 兜底：确认框打开期间微信又被启动，拒绝还原。
        wechat.isRunning = isWeChatRunning()
        guard !wechat.isRunning else {
            lastError = "微信正在运行，请先退出微信再还原。"
            log("❌ 还原被拒绝：微信正在运行")
            return
        }
        let todo = migratedItems
        isBusy = true
        busyKind = .restoring
        migrationOutcome = nil
        log("开始从外置硬盘还原 \(todo.count) 个目录（忽略本地备份）…")
        Task.detached { [weak self] in
            var failed: String? = nil
            do {
                for item in todo {
                    let target = WeChatPaths.targetDirectory(base: base, subdir: item.subdir)
                    try Migrator.restoreItemFromExternal(source: item.source, target: target)
                    await self?.log("✅ 已从外置还原：\(item.displayName)")
                }
            } catch {
                failed = error.localizedDescription
            }
            await self?.restoreFinished(error: failed)
        }
    }

    // MARK: - 还原内置备份

    /// 仅用本地 _backup 还原：删软链 → 备份改名回原名，完全不访问外置盘（不插盘也能用）。
    func startRestoreBackups() {
        // 兜底：确认框打开期间微信又被启动，拒绝还原。
        wechat.isRunning = isWeChatRunning()
        guard !wechat.isRunning else {
            lastError = "微信正在运行，请先退出微信再还原内置备份。"
            log("❌ 还原内置备份被拒绝：微信正在运行")
            return
        }
        let todo = restorableBackupItems
        guard !todo.isEmpty else { return }
        isBusy = true
        busyKind = .restoringBackups
        migrationOutcome = nil
        log("开始还原内置备份 \(todo.count) 个目录 …")
        Task.detached { [weak self] in
            var failed: String? = nil
            do {
                for item in todo {
                    try Migrator.restoreFromBackup(source: item.source)
                    await self?.log("✅ 已还原内置备份：\(item.displayName)")
                }
            } catch {
                failed = error.localizedDescription
            }
            await self?.restoreBackupsFinished(error: failed)
        }
    }

    private func restoreBackupsFinished(error: String?) {
        isBusy = false
        busyKind = nil
        if let error {
            lastError = error
            log("❌ 还原内置备份失败：\(error)")
        } else {
            log("已还原内置备份，正在重签名微信…")
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
            activeSheet = .appManagementGuide
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
            activeSheet = .appManagementGuide
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
        busyKind = .deletingBackups
        migrationOutcome = nil
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
        busyKind = nil
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
        busyKind = .sizingExternal
        log("正在统计外置数据大小…")
        Task.detached { [weak self] in
            let size = DiskProbe.directorySize(at: root)
            await self?.externalDataSized(size)
        }
    }

    private func externalDataSized(_ size: Int64) {
        isBusy = false
        busyKind = nil
        externalDataSize = size
        activeDialog = .cleanExternal
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
        busyKind = .cleaningExternal
        migrationOutcome = nil
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
        busyKind = nil
        if let error {
            lastError = "删除外置数据失败：\(error)"
            log("❌ 删除外置数据失败：\(error)")
        } else {
            log("✅ 已清理外置数据，释放空间 \(DiskProbe.formatBytes(externalDataSize ?? 0))")
            externalDataSize = nil
        }
        refresh()
    }

    // MARK: - 日志与结果动作

    func copyLogs() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logs.joined(separator: "\n"), forType: .string)
        log("日志已复制到剪贴板")
    }

    func clearLogs() {
        logs.removeAll()
    }

    /// 导出日志到文件（NSSavePanel 同属系统面板，先激活 App）。
    func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "WeChatMover-日志.txt"
        activateApp()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try self.logs.joined(separator: "\n")
                        .write(to: url, atomically: true, encoding: .utf8)
                    self.log("日志已导出：\(url.path)")
                } catch {
                    self.lastError = "导出日志失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 成功横幅「在 Finder 中显示」。
    func revealExternalData() {
        guard let root = externalDataURL,
              FileManager.default.fileExists(atPath: root.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    /// 成功横幅「复制报告」。
    func copyMigrationReport() {
        var lines: [String] = ["WeChatMover 迁移报告"]
        if case .succeeded(let summary) = appStatus {
            lines.append(summary)
        }
        lines.append("目标位置：\(targetBase?.path ?? "—")")
        lines.append("")
        lines.append(contentsOf: logs)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        log("迁移报告已复制到剪贴板")
    }

    /// 成功横幅「完成」：清除结果横幅，回到常规状态。
    func dismissOutcome() {
        migrationOutcome = nil
    }

    private func setProgress(_ value: Double) {
        progress = value
    }

    func log(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(stamp)] \(message)")
    }
}
