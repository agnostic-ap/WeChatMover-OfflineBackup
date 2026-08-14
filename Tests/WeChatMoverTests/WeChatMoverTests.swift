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
    #expect(CodeSigner.shellCommand == "codesign --sign - --force --deep /Applications/WeChat.app")
    #expect(CodeSigner.appleScriptSource.contains("with administrator privileges"))
    #expect(CodeSigner.appleScriptSource.contains(CodeSigner.shellCommand))
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

// MARK: - osascript 提权结果解析（纯逻辑）

@Test func parseResignResultSuccess() {
    #expect(CodeSigner.parseResult(status: 0, stderr: "") == .success)
    // 退出码 0 即成功，即使 stderr 有杂散输出
    #expect(CodeSigner.parseResult(status: 0, stderr: "noise") == .success)
}

@Test func parseResignResultCancelled() {
    // osascript 提权弹窗「用户取消」的真实输出
    let real = "31:76: execution error: User canceled. (-128)\n"
    #expect(CodeSigner.parseResult(status: 1, stderr: real) == .cancelled)
    #expect(CodeSigner.parseResult(status: 1, stderr: "User canceled") == .cancelled)
    #expect(CodeSigner.parseResult(status: 1, stderr: "(-128)") == .cancelled)
}

@Test func parseResignResultFailure() {
    #expect(CodeSigner.parseResult(status: 1, stderr: "some error\n")
            == .failed("some error"))
    #expect(CodeSigner.parseResult(status: 3, stderr: "  \n") == .failed("退出码 3"))
    // 取消不算失败
    if case .failed = CodeSigner.parseResult(status: 1, stderr: "User canceled. (-128)") {
        Issue.record("用户取消不应解析为失败")
    }
}

// MARK: - 进程异步执行（用 /bin/sh fixture，不触碰提权路径）

@Test func runProcessSuccess() async {
    let result: CodeSigner.ResignResult = await withCheckedContinuation { cont in
        CodeSigner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 0"]
        ) { cont.resume(returning: $0) }
    }
    #expect(result == .success)
}

@Test func runProcessCancelledParsing() async {
    let result: CodeSigner.ResignResult = await withCheckedContinuation { cont in
        CodeSigner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'User canceled. (-128)' >&2; exit 1"]
        ) { cont.resume(returning: $0) }
    }
    #expect(result == .cancelled)
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
