import Testing
import Foundation
@testable import WeChatMover

/// 所有用例只操作临时目录 fixture，绝不触碰真实微信数据。
private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

/// 造一个带几个文件的假数据目录。
@discardableResult
private func makeDataDir(root: URL, _ relative: String, fileSizes: [Int] = [100, 200, 300]) throws -> URL {
    let dir = root.appendingPathComponent(relative, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (i, size) in fileSizes.enumerated() {
        try Data(repeating: UInt8(i + 1), count: size)
            .write(to: dir.appendingPathComponent("file\(i).bin"))
    }
    return dir
}

// MARK: - 路径模型

@Test func targetPathMapping() {
    let base = URL(fileURLWithPath: "/Volumes/Ext/MyFolder", isDirectory: true)
    #expect(WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files").path
            == "/Volumes/Ext/MyFolder/WeChatData/xwechat_files")
    #expect(WeChatPaths.targetDirectory(base: base, subdir: "Documents/app_data").path
            == "/Volumes/Ext/MyFolder/WeChatData/app_data")
    #expect(WeChatPaths.targetDirectory(base: base, subdir: "Library/Application Support/com.tencent.xinWeChat").path
            == "/Volumes/Ext/MyFolder/WeChatData/com.tencent.xinWeChat")
}

@Test func sourcePathMapping() {
    let container = URL(fileURLWithPath: "/tmp/container/Data", isDirectory: true)
    #expect(WeChatPaths.sourceDirectory(containerRoot: container, subdir: "Documents/xwechat_files").path
            == "/tmp/container/Data/Documents/xwechat_files")
}

// MARK: - 软链识别

@Test func symlinkDetection() throws {
    try withTempDir { root in
        let real = try makeDataDir(root: root, "real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(DiskProbe.isSymlink(link))
        #expect(!DiskProbe.isSymlink(real))
        #expect(!DiskProbe.isSymlink(root.appendingPathComponent("nope")))
    }
}

// MARK: - 状态推断

@Test func itemStateMissing() throws {
    try withTempDir { root in
        #expect(itemState(at: root.appendingPathComponent("nothing")) == .missing)
    }
}

@Test func itemStateLocal() throws {
    try withTempDir { root in
        let dir = try makeDataDir(root: root, "data")
        #expect(itemState(at: dir) == .local)
    }
}

@Test func itemStateMigrated() throws {
    try withTempDir { root in
        let target = try makeDataDir(root: root, "WeChatData/xwechat_files")
        let source = root.appendingPathComponent("Documents/xwechat_files")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        #expect(itemState(at: source) == .migrated)
    }
}

@Test func itemStateBrokenSymlink() throws {
    try withTempDir { root in
        // 指向不存在目标的软链 = 外置盘未插入
        let source = root.appendingPathComponent("Documents/app_data")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: root.appendingPathComponent("unplugged"))
        #expect(itemState(at: source) == .brokenSymlink)
    }
}

// MARK: - APFS 判断（纯逻辑）

@Test func isAPFSJudgement() {
    #expect(DiskProbe.isAPFS(fsTypeName: "apfs"))
    #expect(DiskProbe.isAPFS(fsTypeName: "APFS"))
    #expect(!DiskProbe.isAPFS(fsTypeName: "exfat"))
    #expect(!DiskProbe.isAPFS(fsTypeName: "ntfs"))
    #expect(!DiskProbe.isAPFS(fsTypeName: "hfs"))
}

// MARK: - 目录大小

@Test func directorySizeCounting() throws {
    try withTempDir { root in
        let dir = try makeDataDir(root: root, "sized", fileSizes: [128, 256])
        #expect(DiskProbe.directorySize(at: dir) == 384)
        #expect(DiskProbe.directorySize(at: root.appendingPathComponent("missing")) == 0)
    }
}

// MARK: - 签名命令

@Test func codesignCommand() {
    #expect(CodeSigner.codesignArguments
            == ["--sign", "-", "--force", "--deep", "/Applications/WeChat.app"])
    #expect(CodeSigner.shellCommand == "codesign --sign - --force --deep /Applications/WeChat.app")
}

// MARK: - App Store 版检测

@Test func masReceiptDetection() throws {
    try withTempDir { root in
        let contents = root.appendingPathComponent("WeChat.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let appURL = root.appendingPathComponent("WeChat.app")
        #expect(!WeChatDetector.isAppStoreVersion(appURL: appURL))

        let receiptDir = contents.appendingPathComponent("_MASReceipt", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
        try Data().write(to: receiptDir.appendingPathComponent("receipt"))
        #expect(WeChatDetector.isAppStoreVersion(appURL: appURL))
    }
}

// MARK: - 迁移 / 还原全流程（临时目录 fixture）

@Test func migrateAndRestoreRoundtrip() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files", fileSizes: [512, 1024])
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
        let backup = WeChatPaths.backupDirectory(for: source)

        // 迁移：源改名为 _backup 保留，原位建软链
        try Migrator.migrateItem(source: source, target: target)
        #expect(DiskProbe.isSymlink(source))
        #expect(itemState(at: source) == .migrated)
        #expect(DiskProbe.directorySize(at: target) == 1536)
        #expect(DiskProbe.directorySize(at: backup) == 1536)   // 备份保留
        // 通过软链能读到原文件
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("file0.bin").path))

        // 重复迁移应被拒绝
        #expect(throws: MigrationError.self) {
            try Migrator.migrateItem(source: source, target: root.appendingPathComponent("other"))
        }

        // 秒还原：备份改名回原名，外置盘副本保留不动
        try Migrator.restoreItem(source: source, target: target)
        #expect(!DiskProbe.isSymlink(source))
        #expect(itemState(at: source) == .local)
        #expect(DiskProbe.directorySize(at: source) == 1536)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(FileManager.default.fileExists(atPath: target.path))   // 外置盘副本保留
    }
}

// MARK: - _backup 机制

@Test func backupPathMapping() {
    let source = URL(fileURLWithPath: "/tmp/c/Documents/xwechat_files", isDirectory: true)
    #expect(WeChatPaths.backupDirectory(for: source).path
            == "/tmp/c/Documents/xwechat_files_backup")
}

@Test func restorePrefersLocalBackup() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/app_data", fileSizes: [256])
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/app_data")
        try Migrator.migrateItem(source: source, target: target)

        // 删掉外置盘副本，模拟"外置盘不在手边"：有本地备份照样能秒还原
        try FileManager.default.removeItem(at: target)
        try Migrator.restoreItem(source: source, target: target)
        #expect(itemState(at: source) == .local)
        #expect(DiskProbe.directorySize(at: source) == 256)
    }
}

@Test func restoreFallsBackToExternalCopy() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/app_data", fileSizes: [256])
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/app_data")
        try Migrator.migrateItem(source: source, target: target)

        // 用户已删本地备份 → 走外置盘拷回路径，完成后删外置盘副本
        try FileManager.default.removeItem(at: WeChatPaths.backupDirectory(for: source))
        try Migrator.restoreItem(source: source, target: target)
        #expect(itemState(at: source) == .local)
        #expect(DiskProbe.directorySize(at: source) == 256)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}

@Test func deleteBackupSafetyChecks() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files", fileSizes: [512])
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
        let backup = WeChatPaths.backupDirectory(for: source)

        // 未迁移（无 _backup）→ 拒绝
        #expect(throws: MigrationError.self) { try Migrator.deleteBackup(source: source) }

        try Migrator.migrateItem(source: source, target: target)
        // 迁移完好（软链有效）→ 允许删除并返回释放空间
        let freed = try Migrator.deleteBackup(source: source)
        #expect(freed == 512)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(itemState(at: source) == .migrated)

        // 再删一次 → 备份不存在
        #expect {
            try Migrator.deleteBackup(source: source)
        } throws: { error in
            guard case MigrationError.backupMissing = error else { return false }
            return true
        }
    }
}

@Test func deleteBackupRefusesWhenSymlinkBroken() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files", fileSizes: [128])
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
        try Migrator.migrateItem(source: source, target: target)

        // 外置盘副本消失 → 软链失效，删除备份必须被拒绝
        try FileManager.default.removeItem(at: target)
        #expect {
            try Migrator.deleteBackup(source: source)
        } throws: { error in
            guard case MigrationError.unsafeToDeleteBackup = error else { return false }
            return true
        }
        // 备份仍在
        #expect(FileManager.default.fileExists(
            atPath: WeChatPaths.backupDirectory(for: source).path))
    }
}

@Test func interruptedResidueDetection() throws {
    try withTempDir { root in
        // 源位是普通目录且 _backup 已存在 = 上次迁移中断残留
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files")
        _ = try makeDataDir(root: root, "container/Documents/xwechat_files_backup", fileSizes: [64])
        #expect(itemState(at: source) == .interrupted)

        // 迁移必须明确报错而不是静默失败
        let target = root.appendingPathComponent("external/WeChatData/xwechat_files")
        #expect {
            try Migrator.migrateItem(source: source, target: target)
        } throws: { error in
            guard case MigrationError.backupAlreadyExists = error else { return false }
            return true
        }
    }
}

@Test func migratedWithBackupStateDistinction() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files", fileSizes: [128])
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
        try Migrator.migrateItem(source: source, target: target)

        // 已迁移且备份仍在
        #expect(itemState(at: source) == .migrated)
        #expect(FileManager.default.fileExists(
            atPath: WeChatPaths.backupDirectory(for: source).path))

        // 删掉备份 → 已迁移无备份，状态仍为 migrated
        _ = try Migrator.deleteBackup(source: source)
        #expect(itemState(at: source) == .migrated)
    }
}

@Test func migrateRefusesExistingTarget() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container2/Documents/app_data")
        let target = try makeDataDir(root: root, "external2/WeChatData/app_data")
        #expect {
            try Migrator.migrateItem(source: source, target: target)
        } throws: { error in
            guard case MigrationError.targetAlreadyExists = error else { return false }
            return true
        }
        // 源应保持原样
        #expect(itemState(at: source) == .local)
    }
}

@Test func restoreRefusesNonSymlink() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container3/Documents/app_data")
        #expect {
            try Migrator.restoreItem(source: source, target: root.appendingPathComponent("whatever"))
        } throws: { error in
            guard case MigrationError.notMigrated = error else { return false }
            return true
        }
    }
}


// MARK: - 安装/来源检测（Bug 2 回归：只依赖 /Applications/WeChat.app 本体）

/// 造一个假 .app（Contents/Info.plist，可选 MASReceipt）。
private func makeFakeApp(root: URL, version: String?, masReceipt: Bool) throws -> URL {
    let contents = root.appendingPathComponent("WeChat.app/Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    if let version {
        try NSDictionary(dictionary: ["CFBundleShortVersionString": version])
            .write(to: contents.appendingPathComponent("Info.plist"))
    }
    if masReceipt {
        let receiptDir = contents.appendingPathComponent("_MASReceipt", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
        try Data().write(to: receiptDir.appendingPathComponent("receipt"))
    }
    return root.appendingPathComponent("WeChat.app")
}

@Test func detectOfficialDMGVersion() throws {
    try withTempDir { root in
        let app = try makeFakeApp(root: root, version: "4.1.12", masReceipt: false)
        let info = WeChatDetector.detect(appURL: app)
        #expect(info.isInstalled)
        #expect(info.version == "4.1.12")
        #expect(!info.isAppStoreVersion)
    }
}

@Test func detectAppStoreVersion() throws {
    try withTempDir { root in
        let app = try makeFakeApp(root: root, version: "4.1.12", masReceipt: true)
        let info = WeChatDetector.detect(appURL: app)
        #expect(info.isInstalled)
        #expect(info.isAppStoreVersion)
    }
}

@Test func detectNotInstalled() throws {
    try withTempDir { root in
        let info = WeChatDetector.detect(appURL: root.appendingPathComponent("NoSuch.app"))
        #expect(!info.isInstalled)
        #expect(info.version == nil)
        #expect(!info.isAppStoreVersion)
    }
}

/// 本机真实环境只读验证：/Applications/WeChat.app 应识别为「已安装 / 官网 DMG 版」。
/// 仅在存在该 App 的机器上运行，其他机器自动跳过。
@Test(
    .enabled(if: FileManager.default.fileExists(atPath: "/Applications/WeChat.app"))
)
func detectRealWeChat() {
    let info = WeChatDetector.detect()
    #expect(info.isInstalled)
    #expect(info.version != nil)
    #expect(!info.isAppStoreVersion)  // 本机为官网 DMG 版
}

// MARK: - 目标选择回调（与 NSOpenPanel 解耦后的纯逻辑）

@MainActor @Test func applyTargetSelectionPersists() throws {
    try withTempDir { root in
        let folder = root.appendingPathComponent("ExtFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vm = AppViewModel()
        vm.applyTargetSelection(folder)
        #expect(vm.targetBase?.path == folder.path)
        #expect(UserDefaults.standard.string(forKey: DefaultsKey.targetBasePath) == folder.path)
        #expect(vm.targetFSType != nil)                       // 卷格式已探测
        #expect(vm.targetFreeSpace != nil)                    // 剩余空间已探测
        #expect(vm.logs.contains { $0.contains("已选择目标位置") })
        UserDefaults.standard.removeObject(forKey: DefaultsKey.targetBasePath)
    }
}

// MARK: - codesign 结果解析（纯逻辑）

@Test func parseResignResultSuccess() {
    #expect(CodeSigner.parseResult(status: 0, stderr: "") == .success)
    // 退出码 0 即成功，即使 stderr 有杂散输出
    #expect(CodeSigner.parseResult(status: 0, stderr: "noise") == .success)
}

@Test func parseResignResultFailure() {
    #expect(CodeSigner.parseResult(status: 1, stderr: "some error\n")
            == .failed("some error"))
    #expect(CodeSigner.parseResult(status: 3, stderr: "  \n") == .failed("退出码 3"))
}

// MARK: - 进程异步执行（用 /bin/sh fixture）

@Test func runProcessSuccess() async {
    let result: CodeSigner.ResignResult = await withCheckedContinuation { cont in
        CodeSigner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 0"]
        ) { cont.resume(returning: $0) }
    }
    #expect(result == .success)
}

@Test func runProcessFailure() async {
    let result: CodeSigner.ResignResult = await withCheckedContinuation { cont in
        CodeSigner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo boom >&2; exit 2"]
        ) { cont.resume(returning: $0) }
    }
    #expect(result == .failed("boom"))
}

/// stderr 输出超过管道缓冲（64KB）时进程不应假死：readabilityHandler 持续排空。
@Test func runProcessLargeStderrNoDeadlock() async {
    let result: CodeSigner.ResignResult = await withCheckedContinuation { cont in
        CodeSigner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 20000 ]; do echo line$i >&2; i=$((i+1)); done; exit 7"]
        ) { cont.resume(returning: $0) }
    }
    if case .failed(let msg) = result {
        #expect(msg.contains("line19999"))   // stderr 完整读完
    } else {
        Issue.record("期望 failed，实际 \(result)")
    }
}

// MARK: - 退出微信流程（注入假 closure，不触碰真实微信）

private final class QuitFixture: @unchecked Sendable {
    var running = true
    var gracefulCalls = 0
    var forceCalls = 0
}

@Test func ensureQuitSkipsWhenNotRunning() async {
    let f = QuitFixture()
    f.running = false
    let ok = await WeChatQuitter.ensureQuit(
        isRunning: { f.running },
        graceful: { f.gracefulCalls += 1 },
        force: { f.forceCalls += 1 })
    #expect(ok)
    #expect(f.gracefulCalls == 0)
    #expect(f.forceCalls == 0)
}

@Test func ensureQuitGracefulSuccess() async {
    let f = QuitFixture()
    let ok = await WeChatQuitter.ensureQuit(
        graceTimeout: 2, forceTimeout: 1,
        isRunning: { f.running },
        graceful: { f.gracefulCalls += 1; f.running = false },   // 优雅退出成功
        force: { f.forceCalls += 1 })
    #expect(ok)
    #expect(f.gracefulCalls == 1)
    #expect(f.forceCalls == 0)                                    // 不应强杀
}

@Test func ensureQuitForceKillAfterGraceTimeout() async {
    let f = QuitFixture()
    let ok = await WeChatQuitter.ensureQuit(
        graceTimeout: 0.4, forceTimeout: 2,
        isRunning: { f.running },
        graceful: { f.gracefulCalls += 1 },                       // 优雅退出无效
        force: { f.forceCalls += 1; f.running = false })          // 强杀生效
    #expect(ok)
    #expect(f.gracefulCalls == 1)
    #expect(f.forceCalls == 1)
}

@Test func ensureQuitFailsWhenProcessStubborn() async {
    let f = QuitFixture()
    let ok = await WeChatQuitter.ensureQuit(
        graceTimeout: 0.3, forceTimeout: 0.3,
        isRunning: { f.running },                                 // 始终不退
        graceful: { f.gracefulCalls += 1 },
        force: { f.forceCalls += 1 })
    #expect(!ok)
    #expect(f.gracefulCalls == 1)
    #expect(f.forceCalls == 1)
}

@Test func waitForExitTiming() async {
    let timedOut = await WeChatQuitter.waitForExit(timeout: 0.3, pollInterval: 0.1) { true }
    #expect(!timedOut)
    let exited = await WeChatQuitter.waitForExit(timeout: 1, pollInterval: 0.1) { false }
    #expect(exited)
}

// MARK: - App 管理权限缺失分类（TCC EPERM）

@Test func parseResignResultAppManagementDenied() {
    // 用户实测的真实 stderr
    let real = """
        0:105: execution error: /Applications/WeChat.app: replacing existing signature
        /Applications/WeChat.app: Operation not permitted
        In subcomponent: /Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app (1)
        """
    let result = CodeSigner.parseResult(status: 1, stderr: real)
    guard case .appManagementDenied(let detail) = result else {
        Issue.record("EPERM 应分类为 appManagementDenied，实际 \(result)")
        return
    }
    #expect(detail.contains("Operation not permitted"))
    // 不含 EPERM 的普通失败仍走 failed
    #expect(CodeSigner.parseResult(status: 1, stderr: "boom") == .failed("boom"))
}

@Test func terminalFallbackCommand() {
    #expect(CodeSigner.terminalCommand
            == "sudo codesign --sign - --force --deep /Applications/WeChat.app")
}

// MARK: - 目标冲突路径安全检查（纯逻辑）

@Test func conflictPathSafety() {
    let base = URL(fileURLWithPath: "/Volumes/Ext/test", isDirectory: true)
    #expect(AppViewModel.isConflictPathInsideTarget(
        "/Volumes/Ext/test/WeChatData/xwechat_files", base: base))
    // 目标目录外一律拒绝
    #expect(!AppViewModel.isConflictPathInsideTarget("/Volumes/Ext/test", base: base))
    #expect(!AppViewModel.isConflictPathInsideTarget(
        "/Volumes/Ext/test/WeChatData", base: base))
    #expect(!AppViewModel.isConflictPathInsideTarget("/etc/whatever", base: base))
    #expect(!AppViewModel.isConflictPathInsideTarget(
        "/Volumes/Ext/test2/WeChatData/x", base: base))
}

// MARK: - 迁移目标冲突流程（临时目录 fixture，注入假依赖）

/// 轮询等待 MainActor 上的条件成立（集成测试用）。
@MainActor
private func waitUntil(
    _ timeout: TimeInterval = 10,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return condition()
}

@MainActor @Test func migrationTargetConflictFlow() async throws {
    // withTempDir 是同步闭包，这里要 await，改为内联临时目录（同样的 fixture 约定）
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                 fileSizes: [128])
    let base = root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let target = WeChatPaths.targetDirectory(base: base,
                                             subdir: "Documents/xwechat_files")
    // 上次中断/重复迁移留下的旧数据
    _ = try makeDataDir(root: root, "external/WeChatData/xwechat_files",
                        fileSizes: [64])

    let vm = AppViewModel()
    vm.isWeChatRunning = { false }
    vm.resignRunner = { completion in completion(.success) }   // 不弹真实密码框
    // 容器根指向 fixture：refresh() 重建 items 时不会碰到真实微信数据
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = base
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files", source: source,
                           state: .local, size: 128, hasBackup: false, backupSize: 0)]

    // 1. 目标已存在 → 不判失败，弹「删除旧数据并重新迁移」确认框
    vm.startMigration()
    #expect(await waitUntil { vm.showExistingTargetConfirm })
    #expect(vm.conflictingTargetPath == target.path)
    #expect(vm.lastError == nil)
    #expect(vm.logs.contains { $0.contains("目标位置已有数据") })
    #expect(FileManager.default.fileExists(atPath: target.path))   // 旧数据还在

    // 2. 确认删除旧数据并重新迁移 → 迁移成功
    vm.removeConflictingTargetAndMigrate()
    let migrated = await waitUntil {
        !vm.isBusy && itemState(at: source) == .migrated
    }
    #expect(migrated)
    #expect(DiskProbe.directorySize(at: target) == 128)   // 新数据覆盖了旧数据
    #expect(vm.lastError == nil)
}

@MainActor @Test func resignAppManagementDeniedShowsGuide() async {
    let vm = AppViewModel()
    vm.isAppBundleWritable = { true }
    vm.resignRunner = { completion in
        completion(.appManagementDenied("Operation not permitted"))
    }
    vm.resignWeChat()
    #expect(await waitUntil { vm.showAppManagementGuide })
    #expect(vm.resignGuideReason == .appManagementDenied)
    #expect(!vm.isResigning)
    #expect(vm.lastError == nil)   // 不算普通失败，走专属指引
    #expect(vm.logs.contains { $0.contains("App 管理") })
}

@MainActor @Test func resignNotWritableShowsTerminalFallback() async {
    let vm = AppViewModel()
    var runnerCalled = false
    vm.isAppBundleWritable = { false }   // 包所有者不是当前用户
    vm.resignRunner = { _ in runnerCalled = true }
    vm.resignWeChat()
    // 直接弹终端 sudo 兜底指引，不启动 codesign
    #expect(vm.showAppManagementGuide)
    #expect(vm.resignGuideReason == .notWritable)
    #expect(!vm.isResigning)
    #expect(!runnerCalled)
    #expect(vm.logs.contains { $0.contains("不可写") })
}

@MainActor @Test func resignSuccessVerifiesSignature() async {
    let vm = AppViewModel()
    vm.isAppBundleWritable = { true }
    vm.resignRunner = { completion in completion(.success) }
    vm.signatureVerifier = { true }   // 不扫真实 App
    vm.resignWeChat()
    #expect(await waitUntil { vm.wechat.signatureValid == true })
    #expect(!vm.isResigning)
    #expect(vm.logs.contains { $0.contains("签名有效") })
}

// MARK: - 真实 codesign 直签（只签临时目录 fixture，不碰真实微信）

/// 造一个可签名的最小 .app（Info.plist + 主可执行文件）。
private func makeSignableFixtureApp(root: URL) throws -> URL {
    let contents = root.appendingPathComponent("Mini.app/Contents", isDirectory: true)
    let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    try NSDictionary(dictionary: [
        "CFBundleExecutable": "Mini",
        "CFBundleIdentifier": "com.example.mini",
        "CFBundleShortVersionString": "1.0",
    ]).write(to: contents.appendingPathComponent("Info.plist"))
    let exe = macos.appendingPathComponent("Mini")
    try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    return root.appendingPathComponent("Mini.app")
}

/// 验证本次修复的核心前提：不提权直接 codesign ad-hoc 重签 + 复核通过。
@Test func resignFixtureAppDirectly() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeSignableFixtureApp(root: root)

    let result: CodeSigner.ResignResult = await withCheckedContinuation { cont in
        CodeSigner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--sign", "-", "--force", "--deep", app.path]
        ) { cont.resume(returning: $0) }
    }
    #expect(result == .success)
    #expect(WeChatDetector.checkSignature(appURL: app))   // codesign -v 复核通过
}

// MARK: - 清理外置数据：安全校验（纯逻辑 + fixture）

@Test func externalDataPathValidation() {
    let base = URL(fileURLWithPath: "/Volumes/Ext/MyFolder", isDirectory: true)
    #expect(AppViewModel.isExternalDataPathValid(
        "/Volumes/Ext/MyFolder/WeChatData", base: base))
    // 目标目录外/形态不符一律拒绝
    #expect(!AppViewModel.isExternalDataPathValid(
        "/Volumes/Ext/MyFolder", base: base))
    #expect(!AppViewModel.isExternalDataPathValid(
        "/Volumes/Ext/MyFolder/WeChatData/xwechat_files", base: base))
    #expect(!AppViewModel.isExternalDataPathValid(
        "/Volumes/Ext/Other/WeChatData", base: base))
    #expect(!AppViewModel.isExternalDataPathValid("/etc", base: base))
}

@Test func externalDataInUseDetection() throws {
    try withTempDir { root in
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dataRoot = WeChatPaths.targetRoot(forBase: base)

        // 已迁移：源位软链 → WeChatData 内部
        let migratedSource = try makeDataDir(root: root, "c/Documents/xwechat_files")
        try Migrator.migrateItem(
            source: migratedSource,
            target: WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files"))
        let migratedItem = ItemStatus(
            subdir: "Documents/xwechat_files", source: migratedSource,
            state: .migrated, size: 0, hasBackup: true, backupSize: 0)
        #expect(AppViewModel.isExternalDataInUse(items: [migratedItem], dataRoot: dataRoot))

        // 本地（未迁移）目录不算使用
        let localSource = try makeDataDir(root: root, "c/Documents/app_data")
        let localItem = ItemStatus(
            subdir: "Documents/app_data", source: localSource,
            state: .local, size: 0, hasBackup: false, backupSize: 0)
        #expect(!AppViewModel.isExternalDataInUse(items: [localItem], dataRoot: dataRoot))
        #expect(!AppViewModel.isExternalDataInUse(items: [], dataRoot: dataRoot))

        // 指向别处的软链不算使用
        let elsewhere = root.appendingPathComponent("elsewhere_link")
        try FileManager.default.createSymbolicLink(
            at: elsewhere, withDestinationURL: root.appendingPathComponent("c"))
        let otherItem = ItemStatus(
            subdir: "elsewhere", source: elsewhere,
            state: .migrated, size: 0, hasBackup: false, backupSize: 0)
        #expect(!AppViewModel.isExternalDataInUse(items: [otherItem], dataRoot: dataRoot))

        // 软链指向 WeChatData 但目标不可达（外置盘未插）仍算使用
        let broken = root.appendingPathComponent("broken_link")
        try FileManager.default.createSymbolicLink(
            at: broken, withDestinationURL: dataRoot.appendingPathComponent("gone"))
        let brokenItem = ItemStatus(
            subdir: "broken", source: broken,
            state: .brokenSymlink, size: 0, hasBackup: false, backupSize: 0)
        #expect(AppViewModel.isExternalDataInUse(items: [brokenItem], dataRoot: dataRoot))
    }
}

// MARK: - 清理外置数据：完整流程（临时目录 fixture）

@MainActor @Test func cleanExternalDataRefusedWhenInUse() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                 fileSizes: [128])
    let base = root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try Migrator.migrateItem(
        source: source,
        target: WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files"))

    let vm = AppViewModel()
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = base
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files", source: source,
                           state: .migrated, size: 128, hasBackup: true, backupSize: 128)]

    // 迁移中 → 拒绝，弹中性提示，不弹确认框、不删数据
    vm.requestCleanExternalData()
    #expect(vm.notice?.contains("仍在使用中") == true)
    #expect(!vm.showCleanExternalConfirm)
    #expect(FileManager.default.fileExists(
        atPath: WeChatPaths.targetRoot(forBase: base).path))
}

@MainActor @Test func cleanExternalDataFlow() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // 先迁移再还原：源位恢复本地，外置 WeChatData 保留（典型清理场景）
    let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                 fileSizes: [128, 256])
    let base = root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
    try Migrator.migrateItem(source: source, target: target)
    try Migrator.restoreItem(source: source, target: target)
    #expect(itemState(at: source) == .local)

    let vm = AppViewModel()
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = base
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files", source: source,
                           state: .local, size: 384, hasBackup: false, backupSize: 0)]

    // 1. 统计大小 → 弹二次确认框
    vm.requestCleanExternalData()
    #expect(await waitUntil { vm.showCleanExternalConfirm })
    #expect(vm.externalDataSize == 384)
    #expect(vm.notice == nil && vm.lastError == nil)
    #expect(FileManager.default.fileExists(atPath: target.path))   // 尚未删除

    // 2. 确认删除 → WeChatData 整体移除，日志显示释放空间
    vm.cleanExternalData()
    #expect(await waitUntil { !vm.isBusy })
    #expect(!FileManager.default.fileExists(
        atPath: WeChatPaths.targetRoot(forBase: base).path))
    #expect(vm.lastError == nil)
    #expect(vm.logs.contains { $0.contains("释放空间") })
}

// MARK: - 展示层映射（AppStatus → 横幅/卡片，纯展示逻辑）

@MainActor
private func makePresentationVM() -> AppViewModel {
    let vm = AppViewModel()
    vm.wechat.isInstalled = true
    vm.containerReadable = true
    vm.sizesLoaded = true
    vm.targetBase = URL(fileURLWithPath: "/Volumes/Ext/test", isDirectory: true)
    vm.targetFSType = "apfs"
    vm.targetFreeSpace = 1_000_000_000
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files",
                           source: URL(fileURLWithPath: "/tmp/c/Documents/xwechat_files"),
                           state: .local, size: 100_000_000,
                           hasBackup: false, backupSize: 0)]
    return vm
}

@MainActor @Test func bannerReady() {
    let vm = makePresentationVM()
    #expect(vm.appStatus == .ready)
    #expect(vm.banner.tone == .success)
    #expect(vm.banner.title == "可以开始迁移")
    #expect(vm.primaryActionTitle == "迁移到外置硬盘")
    // 三张摘要卡片：数据 / 目标磁盘 / 安全检查
    #expect(vm.summaryCards.map(\.id) == ["data", "destination", "safety"])
    #expect(vm.summaryCards[2].value == "全部通过")
}

@MainActor @Test func bannerBlockedReasons() {
    // 未选目标
    let noDest = AppViewModel()
    noDest.wechat.isInstalled = true
    noDest.items = makePresentationVM().items
    #expect(noDest.appStatus == .blocked(.noDestination))
    #expect(noDest.banner.fix == .chooseDestination)

    // 无容器权限（优先级高于未选目标）
    let noPerm = makePresentationVM()
    noPerm.containerReadable = false
    #expect(noPerm.appStatus == .blocked(.containerUnreadable))
    #expect(noPerm.banner.fix == .openFullDiskAccess)

    // 非 APFS
    let exfat = makePresentationVM()
    exfat.targetFSType = "exfat"
    #expect(exfat.appStatus == .blocked(.destinationNotAPFS("exfat")))
    #expect(exfat.banner.message.contains("APFS"))

    // 空间不足
    let tight = makePresentationVM()
    tight.targetFreeSpace = 50_000_000
    #expect(tight.appStatus == .blocked(.insufficientSpace(need: 100_000_000, free: 50_000_000)))
    #expect(tight.banner.title == "目标磁盘空间不足")

    // App Store 版
    let mas = makePresentationVM()
    mas.wechat.isAppStoreVersion = true
    #expect(mas.appStatus == .blocked(.appStoreVersion))
    #expect(mas.banner.fix == .openOfficialDownload)
}

@MainActor @Test func bannerExternalized() {
    let vm = makePresentationVM()
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files",
                           source: URL(fileURLWithPath: "/tmp/c/Documents/xwechat_files"),
                           state: .migrated, size: 100_000_000,
                           hasBackup: false, backupSize: 0)]
    #expect(vm.appStatus == .externalized)
    #expect(vm.banner.tone == .success)
    #expect(vm.banner.title == "微信数据已在外置硬盘")
    #expect(vm.primaryActionTitle == "更新迁移")   // 有部分外置时主按钮文案
}

@MainActor @Test func bannerBusyAndOutcome() {
    let vm = makePresentationVM()
    // 迁移中：横幅带真实字节进度
    vm.busyKind = .migrating
    vm.progress = 0.42
    #expect(vm.appStatus == .busy(.migrating, progress: 0.42))
    #expect(vm.banner.title == "正在迁移… 42%")
    #expect(vm.banner.progress == 0.42)

    // 成功
    vm.busyKind = nil
    vm.migrationOutcome = .succeeded(items: 1, bytes: 100_000_000)
    guard case .succeeded = vm.appStatus else {
        Issue.record("应为 succeeded"); return
    }
    #expect(vm.banner.tone == .success)
    #expect(vm.banner.title == "迁移完成")

    // 失败：横幅给出重试动作，不走泛化错误弹窗
    vm.migrationOutcome = .failed("目标硬盘已断开")
    #expect(vm.appStatus == .failed("目标硬盘已断开"))
    #expect(vm.banner.tone == .danger)
    #expect(vm.banner.fix == .retryMigration)
}

// MARK: - 文案与日志展示映射

@Test func copywritingHumanNames() {
    #expect(Copywriting.itemName("Documents/xwechat_files") == "微信聊天文件")
    #expect(Copywriting.itemName("Documents/app_data") == "微信应用数据")
    #expect(Copywriting.itemName("Library/Application Support/com.tencent.xinWeChat") == "微信兼容数据")
    #expect(Copywriting.itemName("other") == "other")
    #expect(Copywriting.sourceName(isAppStoreVersion: false) == "官网下载版")
}

@Test func logLineParsing() {
    let ok = LogPresentation.parse("[13:49:07] ✅ 已迁移：xwechat_files")
    #expect(ok.tone == .success)
    #expect(ok.symbol == "checkmark.circle.fill")
    #expect(!ok.text.contains("✅"))

    #expect(LogPresentation.parse("[t] ⚠️ 跳过").tone == .warning)
    #expect(LogPresentation.parse("[t] ❌ 失败").tone == .danger)
    let plain = LogPresentation.parse("[13:49:07] 开始迁移")
    #expect(plain.tone == .neutral)
    #expect(plain.text == "[13:49:07] 开始迁移")
}
