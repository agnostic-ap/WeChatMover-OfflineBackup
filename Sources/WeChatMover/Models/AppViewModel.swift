import Foundation
import SwiftUI
import AppKit

/// 应用状态机：备份 / 快照管理 / 恢复。
/// 所有耗时操作走后台 Task，引擎为纯同步函数；UI 状态只在主线程改。
@MainActor
final class AppViewModel: ObservableObject {

    // MARK: - 状态

    @Published var wechat = WeChatInfo()
    @Published var components: [BackupComponent] = []
    @Published var componentSizes: [String: Int64] = [:]

    @Published var vaultBase: URL?
    @Published var vaultVolumeName: String?
    @Published var vaultFSType: String?
    @Published var vaultFreeSpace: Int64?
    @Published var vaultReachable = false

    @Published var snapshots: [SnapshotInfo] = []

    @Published var busy: BusyKind? = nil
    @Published var progress: Double? = nil
    @Published var logs: [String] = []

    @Published var includeAppArchive = false

    @Published var activeDialog: ActiveDialog?
    @Published var activeSheet: ActiveSheet?
    @Published var lastError: String?
    @Published var notice: String?

    /// 主容器存在但读不了 → 缺「完全磁盘访问」权限。
    @Published var needsFullDiskAccess = false

    @Published var restorePlan: RestorePlan?
    @Published var mismatchAcknowledged = false
    @Published var pendingDeleteSnapshot: SnapshotInfo?
    @Published var detailSnapshot: SnapshotInfo?

    private let vaultKey = "vaultBasePath"
    private var sizingTask: Task<Void, Never>?

    var isBusy: Bool { busy != nil }

    var toolVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var macOSVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // MARK: - 刷新

    func refresh() {
        wechat = WeChatDetector.detect()
        components = WeChatEnvironment.live.discoverComponents()
        let mainData = WeChatEnvironment.live.home
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data")
        needsFullDiskAccess = components.contains { $0.id == "container-com.tencent.xinWeChat" }
            && !PermissionHelper.canReadContainer(path: mainData.path)
        if vaultBase == nil,
           let saved = UserDefaults.standard.string(forKey: vaultKey) {
            vaultBase = URL(fileURLWithPath: saved, isDirectory: true)
        }
        refreshVaultStatus()
        refreshComponentSizes()
    }

    func refreshVaultStatus() {
        guard let base = vaultBase else {
            vaultReachable = false
            vaultVolumeName = nil
            vaultFSType = nil
            vaultFreeSpace = nil
            snapshots = []
            return
        }
        var isDir: ObjCBool = false
        vaultReachable = FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir)
            && isDir.boolValue
        if vaultReachable {
            vaultVolumeName = DiskProbe.volumeName(path: base.path)
            vaultFSType = DiskProbe.volumeFSType(path: base.path)
            vaultFreeSpace = DiskProbe.freeSpace(path: base.path)
            snapshots = VaultStore.listSnapshots(base: base)
        } else {
            snapshots = []
        }
    }

    /// 后台统计各组件大小（只读遍历元数据，用于展示与预估）。
    private func refreshComponentSizes() {
        sizingTask?.cancel()
        let comps = components
        let env = WeChatEnvironment.live
        sizingTask = Task { [weak self] in
            for component in comps {
                if Task.isCancelled { return }
                let url = env.url(for: component)
                let size = await Task.detached(priority: .utility) {
                    FileStats.measure(at: url).logicalSize
                }.value
                await MainActor.run { self?.componentSizes[component.id] = size }
            }
        }
    }

    var estimatedBackupSize: Int64? {
        guard !components.isEmpty,
              components.allSatisfy({ componentSizes[$0.id] != nil }) else { return nil }
        return components.reduce(0) { $0 + (componentSizes[$1.id] ?? 0) }
    }

    // MARK: - 备份仓库选择

    func chooseVaultBase() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择备份存放位置（如移动硬盘上的文件夹）。备份会写入其中的 WeChatBackups 目录。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vaultBase = url
        UserDefaults.standard.set(url.path, forKey: vaultKey)
        refreshVaultStatus()
        appendLog("备份位置：\(url.path)（卷 \(vaultVolumeName ?? "未知")，格式 \(vaultFSType ?? "未知")）")
    }

    // MARK: - 备份

    func requestBackup() {
        guard vaultReachable, !components.isEmpty, !isBusy else { return }
        activeDialog = .backupConfirm
    }

    func confirmBackup() {
        guard let base = vaultBase else { return }
        var comps = components
        if includeAppArchive, wechat.isInstalled {
            comps.append(WeChatEnvironment.weChatAppComponent)
        }
        let request = BackupRequest(
            components: comps,
            environment: .live,
            vaultBase: base,
            wechatVersion: wechat.version,
            wechatBuild: wechat.build,
            macOSVersion: Self.macOSVersionString,
            toolVersion: toolVersion)

        busy = .quittingWeChat
        progress = nil
        Task { [weak self] in
            let quit = await WeChatQuitter.ensureQuit()
            guard let self else { return }
            guard quit else {
                self.finishOperation(error: BackupError.wechatStillRunning)
                return
            }
            self.wechat.isRunning = false
            self.busy = .backingUp
            self.progress = 0
            self.appendLog("开始备份到 \(base.path)")
            let log = self.backgroundLogger()
            let prog = self.backgroundProgress()
            let result: Result<SnapshotInfo, Error> = await Task.detached(priority: .utility) {
                do {
                    return .success(try BackupEngine.performBackup(
                        request, log: log, progress: prog,
                        isWeChatRunning: { WeChatDetector.isRunning() }))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let snapshot):
                self.finishOperation()
                self.refreshVaultStatus()
                self.notice = "备份完成：\(snapshot.name)\n共 \(snapshot.manifest?.entries.count ?? 0) 个归档，占用 \(DiskProbe.formatBytes(snapshot.totalArchiveSize))。\n现在可以安全推出并拔下移动硬盘。"
                self.activeDialog = .notice
            case .failure(let error):
                self.finishOperation(error: error)
            }
        }
    }

    // MARK: - 恢复

    func requestRestore(_ snapshot: SnapshotInfo) {
        guard !isBusy else { return }
        busy = .planningRestore
        let version = wechat.version
        Task { [weak self] in
            let result: Result<RestorePlan, Error> = await Task.detached(priority: .utility) {
                do {
                    return .success(try RestoreEngine.makePlan(
                        snapshot: snapshot,
                        environment: .live,
                        currentWeChatVersion: version))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch result {
            case .success(let plan):
                self.busy = nil
                self.restorePlan = plan
                self.mismatchAcknowledged = false
                self.activeSheet = .restorePlan
            case .failure(let error):
                self.finishOperation(error: error)
            }
        }
    }

    /// 计划页第一重确认 → 弹最终 destructive 确认。
    func proceedFromPlan() {
        activeSheet = nil
        activeDialog = .restoreFinalConfirm
    }

    func cancelRestorePlan() {
        activeSheet = nil
        restorePlan = nil
        mismatchAcknowledged = false
    }

    func confirmRestoreFinal() {
        guard let plan = restorePlan else { return }
        busy = .quittingWeChat
        progress = nil
        Task { [weak self] in
            let quit = await WeChatQuitter.ensureQuit()
            guard let self else { return }
            guard quit else {
                self.finishOperation(error: BackupError.wechatStillRunning)
                return
            }
            self.wechat.isRunning = false
            self.busy = .restoring
            self.progress = 0
            self.appendLog("开始恢复快照 \(plan.snapshot.name)")
            let log = self.backgroundLogger()
            let prog = self.backgroundProgress()
            let result: Result<RestoreResult, Error> = await Task.detached(priority: .utility) {
                do {
                    return .success(try RestoreEngine.performRestore(
                        plan: plan, environment: .live,
                        isWeChatRunning: { WeChatDetector.isRunning() },
                        log: log, progress: prog))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let res):
                self.finishOperation()
                self.restorePlan = nil
                var msg = "恢复完成，共 \(res.restored.count) 项。"
                if !res.rollbackDirs.isEmpty {
                    msg += "\n\n恢复前的原数据已改名保留（未删除）：\n"
                        + res.rollbackDirs.map { "· " + $0 }.joined(separator: "\n")
                        + "\n确认微信一切正常后，可在对应目录手动删除这些副本以释放空间。"
                }
                if plan.appEntry != nil {
                    msg += "\n\n快照内含 WeChat.app 归档，不会自动安装。如需同版本微信，请手动解压快照中的 app-WeChat.tar 并拖入「应用程序」。"
                }
                self.notice = msg
                self.activeDialog = .notice
            case .failure(let error):
                self.finishOperation(error: error)
            }
        }
    }

    // MARK: - 快照验证 / 详情 / 删除

    func verifySnapshot(_ snapshot: SnapshotInfo) {
        guard !isBusy else { return }
        busy = .verifying
        progress = nil
        let log = backgroundLogger()
        Task { [weak self] in
            let problems = await Task.detached(priority: .utility) {
                VaultStore.verify(snapshot: snapshot, log: log)
            }.value
            guard let self else { return }
            self.finishOperation()
            if problems.isEmpty {
                self.appendLog("✅ 快照 \(snapshot.name) 验证通过")
                self.notice = "快照「\(snapshot.name)」验证通过：所有归档存在、大小与 SHA-256 均一致，路径安全。"
            } else {
                for p in problems { self.appendLog("❌ \(p)") }
                self.notice = "快照「\(snapshot.name)」验证发现 \(problems.count) 个问题：\n"
                    + problems.map { "· " + $0 }.joined(separator: "\n")
                    + "\n\n该快照不建议用于恢复。"
            }
            self.activeDialog = .notice
        }
    }

    func showDetail(_ snapshot: SnapshotInfo) {
        detailSnapshot = snapshot
        activeSheet = .snapshotDetail(snapshot.id)
    }

    func requestDeleteSnapshot(_ snapshot: SnapshotInfo) {
        guard !isBusy else { return }
        pendingDeleteSnapshot = snapshot
        activeDialog = .deleteSnapshotConfirm
    }

    func confirmDeleteSnapshot() {
        guard let snapshot = pendingDeleteSnapshot, let base = vaultBase else { return }
        pendingDeleteSnapshot = nil
        busy = .deletingSnapshot
        Task { [weak self] in
            let result: Result<Void, Error> = await Task.detached {
                do {
                    try VaultStore.deleteSnapshot(snapshot, base: base)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch result {
            case .success:
                self.finishOperation()
                self.appendLog("已删除快照 \(snapshot.name)")
                self.refreshVaultStatus()
            case .failure(let error):
                self.finishOperation(error: error)
            }
        }
    }

    // MARK: - 日志

    func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 2000 { logs.removeFirst(logs.count - 2000) }
    }

    func copyLogs() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logs.joined(separator: "\n"), forType: .string)
    }

    func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "WeChatMover-日志.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? logs.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func clearLogs() { logs = [] }

    // MARK: - 内部

    private func finishOperation(error: Error? = nil) {
        busy = nil
        progress = nil
        if let error {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            appendLog("❌ \(message)")
            lastError = message
            activeDialog = .error
        }
    }

    private func backgroundLogger() -> @Sendable (String) -> Void {
        { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
    }

    private func backgroundProgress() -> @Sendable (Double) -> Void {
        { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }
    }
}
