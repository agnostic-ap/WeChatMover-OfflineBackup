import Testing
import Foundation
@testable import WeChatMover

// 所有用例只操作临时目录 fixture，绝不触碰真实微信数据：
// WeChatEnvironment 的 home 全部注入为临时目录。

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

/// 组装一个假 home：主容器 + 两个扩展容器 + 群组容器 + Application Scripts + 干扰项。
private func makeFixtureHome(_ home: URL) throws -> WeChatEnvironment {
    try makeDataDir(root: home, "Library/Containers/com.tencent.xinWeChat/Data/Documents",
                    fileSizes: [1000, 2000])
    try makeDataDir(root: home, "Library/Containers/com.tencent.xinWeChat.WeChatMacShare",
                    fileSizes: [50])
    try makeDataDir(root: home, "Library/Containers/com.tencent.xinWeChat.WeChatFileProviderExtension",
                    fileSizes: [60])
    try makeDataDir(root: home, "Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat",
                    fileSizes: [70])
    try makeDataDir(root: home, "Library/Application Scripts/com.tencent.xinWeChat", fileSizes: [10])
    try makeDataDir(root: home, "Library/Application Scripts/5A4RE8SF68.com.tencent.xinWeChat.IPCHelper",
                    fileSizes: [10])
    // 干扰项：不应被发现
    try makeDataDir(root: home, "Library/Containers/com.apple.Notes", fileSizes: [10])
    try makeDataDir(root: home, "Library/Group Containers/group.com.apple.notes", fileSizes: [10])
    try makeDataDir(root: home, "Library/Application Scripts/com.tencent.qq", fileSizes: [10])
    return WeChatEnvironment(home: home)
}

private func makeBackupRequest(env: WeChatEnvironment, vault: URL,
                               components: [BackupComponent]? = nil,
                               now: Date = Date()) -> BackupRequest {
    BackupRequest(
        components: components ?? env.discoverComponents(),
        environment: env,
        vaultBase: vault,
        wechatVersion: "4.0.6",
        wechatBuild: "28582",
        macOSVersion: "15.5.0",
        toolVersion: "2.0-test",
        now: now,
        spaceMargin: 0)
}

/// 测试专用引擎入口：微信运行检测一律注入假闭包（默认「未运行」），
/// 保证测试绝不查询/触碰真实微信。需要覆盖竞态分支时显式传入闭包。
private func runBackup(
    _ request: BackupRequest,
    log: (String) -> Void = { _ in },
    progress: (Double) -> Void = { _ in },
    isCancelled: () -> Bool = { false },
    isWeChatRunning: () -> Bool = { false }
) throws -> SnapshotInfo {
    try BackupEngine.performBackup(
        request, log: log, progress: progress,
        isCancelled: isCancelled, isWeChatRunning: isWeChatRunning)
}

private func runRestore(
    plan: RestorePlan,
    environment: WeChatEnvironment,
    now: Date = Date(),
    fileOps: RestoreEngine.FileOps = RestoreEngine.FileOps(),
    isWeChatRunning: () -> Bool = { false }
) throws -> RestoreResult {
    try RestoreEngine.performRestore(
        plan: plan, environment: environment, now: now,
        fileOps: fileOps, isWeChatRunning: isWeChatRunning)
}

// MARK: - 微信家族名与组件发现

@Test func weChatFamilyNameMatching() {
    #expect(WeChatEnvironment.isWeChatFamilyName("com.tencent.xinWeChat"))
    #expect(WeChatEnvironment.isWeChatFamilyName("com.tencent.xinWeChat.WeChatMacShare"))
    #expect(WeChatEnvironment.isWeChatFamilyName("com.tencent.xinWeChat.WeChatFileProviderExtension"))
    #expect(WeChatEnvironment.isWeChatFamilyName("5A4RE8SF68.com.tencent.xinWeChat"))
    #expect(WeChatEnvironment.isWeChatFamilyName("5A4RE8SF68.com.tencent.xinWeChat.IPCHelper"))
    #expect(!WeChatEnvironment.isWeChatFamilyName("com.tencent.xinWeChatEvil"))   // 无点直连后缀
    #expect(!WeChatEnvironment.isWeChatFamilyName("com.tencent.qq"))
    #expect(!WeChatEnvironment.isWeChatFamilyName("com.apple.Notes"))
    #expect(!WeChatEnvironment.isWeChatFamilyName(""))
}

@Test func discoverComponentsFindsOnlyWeChatDirs() throws {
    try withTempDir { home in
        let env = try makeFixtureHome(home)
        let components = env.discoverComponents()
        let ids = Set(components.map(\.id))
        #expect(ids == [
            "container-com.tencent.xinWeChat",
            "container-com.tencent.xinWeChat.WeChatMacShare",
            "container-com.tencent.xinWeChat.WeChatFileProviderExtension",
            "group-5A4RE8SF68.com.tencent.xinWeChat",
            "scripts-com.tencent.xinWeChat",
            "scripts-5A4RE8SF68.com.tencent.xinWeChat.IPCHelper",
        ])
        // 相对路径正确且能解析回绝对路径
        for c in components {
            #expect(env.url(for: c).path.hasPrefix(home.path))
            #expect(FileManager.default.fileExists(atPath: env.url(for: c).path))
        }
        // 全部有中文显示名
        #expect(components.allSatisfy { !$0.displayName.isEmpty })
    }
}

@Test func discoverComponentsEmptyHome() throws {
    try withTempDir { home in
        let env = WeChatEnvironment(home: home)
        #expect(env.discoverComponents().isEmpty)
    }
}

// MARK: - 路径白名单（PathGuard）

@Test func pathGuardAllowsOnlyWhitelistedWeChatPaths() throws {
    try withTempDir { home in
        let containers = home.appendingPathComponent("Library/Containers")
        #expect(PathGuard.isProtectedWeChatPath(
            containers.appendingPathComponent("com.tencent.xinWeChat"), home: home))
        #expect(PathGuard.isProtectedWeChatPath(
            home.appendingPathComponent("Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat"),
            home: home))
        #expect(PathGuard.isProtectedWeChatPath(
            home.appendingPathComponent("Library/Application Scripts/com.tencent.xinWeChat.WeChatMacShare"),
            home: home))
        // 带本工具后缀的派生名也在白名单内
        #expect(PathGuard.isProtectedWeChatPath(
            containers.appendingPathComponent("com.tencent.xinWeChat.wcm-rollback-20260830-120000"),
            home: home))
        #expect(PathGuard.isProtectedWeChatPath(
            containers.appendingPathComponent("com.tencent.xinWeChat.wcm-staging-20260830-120000"),
            home: home))

        // 拒绝：非微信名、父目录不对、更深层级、home 外
        #expect(!PathGuard.isProtectedWeChatPath(
            containers.appendingPathComponent("com.apple.Notes"), home: home))
        #expect(!PathGuard.isProtectedWeChatPath(
            home.appendingPathComponent("com.tencent.xinWeChat"), home: home))
        #expect(!PathGuard.isProtectedWeChatPath(
            containers.appendingPathComponent("com.tencent.xinWeChat/Data"), home: home))
        #expect(!PathGuard.isProtectedWeChatPath(
            URL(fileURLWithPath: "/Library/Containers/com.tencent.xinWeChat"), home: home))
        #expect(!PathGuard.isProtectedWeChatPath(
            containers.appendingPathComponent("com.tencent.xinWeChatEvil.wcm-rollback-1"), home: home))
        // ".." 穿越在标准化后不再指向白名单父目录
        #expect(!PathGuard.isProtectedWeChatPath(
            containers.appendingPathComponent("../../Documents/com.tencent.xinWeChat"), home: home))
    }
}

@Test func pathGuardRemoveStagingRefusesNonStagingPaths() throws {
    try withTempDir { home in
        let real = try makeDataDir(root: home, "Library/Containers/com.tencent.xinWeChat")
        #expect(throws: BackupError.self) {
            try PathGuard.removeStaging(real, home: home)   // 无 staging 标记 → 拒绝
        }
        #expect(FileManager.default.fileExists(atPath: real.path))

        let staging = try makeDataDir(
            root: home, "Library/Containers/com.tencent.xinWeChat.wcm-staging-20260830-1")
        try PathGuard.removeStaging(staging, home: home)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }
}

@Test func pathGuardMoveRefusesOutsideWhitelist() throws {
    try withTempDir { home in
        let src = try makeDataDir(root: home, "Library/Containers/com.tencent.xinWeChat")
        let outside = home.appendingPathComponent("Desktop/com.tencent.xinWeChat")
        #expect(throws: BackupError.self) {
            try PathGuard.move(src, to: outside, home: home)
        }
        #expect(FileManager.default.fileExists(atPath: src.path))
    }
}

// MARK: - ZIP 条目安全（纯函数）

@Test func unsafeArchiveEntriesDetection() {
    let entries = [
        "ok/file.txt",
        "ok/nested/dir/",
        "ok/2024\\345\\271\\264\\345\\220\\210.xls",  // bsdtar 对中文名的八进制转义：安全
        "a\\..\\b",                 // 反斜杠非 tar 路径分隔符：安全（只是个怪名字）
        "/etc/passwd",              // 绝对路径
        "../escape.txt",            // 上跳
        "a/../../b.txt",            // 内嵌上跳
        "~root/x",                  // ~ 开头
        "weird/..",                 // 结尾上跳
    ]
    let unsafe = Archiver.unsafeEntries(entries)
    #expect(unsafe.sorted() == [
        "/etc/passwd", "../escape.txt", "a/../../b.txt", "weird/..", "~root/x",
    ].sorted())
}

@Test func chineseFilenamesSurviveArchiveValidation() throws {
    // 回归：微信收到的中文文件名（bsdtar 列条目转义成八进制）
    // 不得被安全校验误杀（实测 45GB 归档因此被整体作废）。
    try withTempDir { dir in
        let src = dir.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("测试".utf8).write(to: src.appendingPathComponent("2024年国网EAP服务合同.xls"))
        try Data("测试".utf8).write(to: src.appendingPathComponent("行政部薪资转账汇总(1).pdf"))
        let archive = dir.appendingPathComponent("p.tar")
        try Archiver.createArchive(source: src, archive: archive)
        let entries = try Archiver.listEntries(archive: archive)
        try Archiver.validateEntries(entries, expectedTopLevel: "payload")   // 不得抛出
        #expect(entries.count >= 3)
    }
}

@Test func validateEntriesRejectsStrayTopLevel() throws {
    // 顶层目录之外的条目（可能覆盖任意同级目录）→ 拒绝
    #expect(throws: BackupError.self) {
        try Archiver.validateEntries(["expected/a.txt", "other/b.txt"],
                                        expectedTopLevel: "expected")
    }
    // 正常结构 + __MACOSX 伴生目录 → 通过
    try Archiver.validateEntries(
        ["expected", "expected/a.txt", "__MACOSX/expected/._a.txt"],
        expectedTopLevel: "expected")
}

// MARK: - SHA-256

@Test func sha256KnownVector() throws {
    // FIPS 180 已知向量："abc"
    let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    #expect(Checksum.sha256(data: Data("abc".utf8)) == expected)
    try withTempDir { dir in
        let file = dir.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        #expect(try Checksum.sha256(of: file) == expected)
    }
}

@Test func fileStatsCountsHiddenFiles() throws {
    try withTempDir { dir in
        let data = try makeDataDir(root: dir, "d", fileSizes: [10, 20])
        try Data(repeating: 7, count: 5).write(to: data.appendingPathComponent(".hidden"))
        let stats = FileStats.measure(at: data)
        #expect(stats.fileCount == 3)
        #expect(stats.logicalSize == 35)
    }
}

// MARK: - tar 归档往返（含扩展属性）

@Test func archiveRoundTripPreservesContentAndXattr() throws {
    try withTempDir { dir in
        let src = try makeDataDir(root: dir, "payload", fileSizes: [128, 256])
        let fileWithXattr = src.appendingPathComponent("file0.bin")
        let xattrName = "com.wechatmover.test"
        let xattrValue = Data("元数据往返".utf8)
        let setResult = xattrValue.withUnsafeBytes { bytes in
            setxattr(fileWithXattr.path, xattrName, bytes.baseAddress, xattrValue.count, 0, 0)
        }
        #expect(setResult == 0)

        let archive = dir.appendingPathComponent("payload.tar")
        try Archiver.createArchive(source: src, archive: archive)
        #expect(FileManager.default.fileExists(atPath: archive.path))

        // 条目列出且全部安全、位于顶层目录内
        let entries = try Archiver.listEntries(archive: archive)
        #expect(!entries.isEmpty)
        try Archiver.validateEntries(entries, expectedTopLevel: "payload")

        // 解包到别处，内容与 xattr 均还原
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Archiver.extractArchive(archive: archive, to: out)
        let restored = out.appendingPathComponent("payload/file0.bin")
        #expect(try Data(contentsOf: restored) == Data(repeating: 1, count: 128))

        var buf = [UInt8](repeating: 0, count: 64)
        let n = getxattr(restored.path, xattrName, &buf, buf.count, 0, 0)
        #expect(n == xattrValue.count)
        #expect(Data(buf.prefix(max(n, 0))) == xattrValue)
    }
}

// MARK: - 清单编解码

@Test func manifestRoundTrip() throws {
    let manifest = BackupManifest(
        formatVersion: BackupManifest.currentFormatVersion,
        createdAt: Date(timeIntervalSince1970: 1_772_400_000),
        toolVersion: "2.0",
        wechatVersion: "4.0.6",
        wechatBuild: "28582",
        macOSVersion: "15.5.0",
        entries: [
            .init(id: "container-com.tencent.xinWeChat", kind: .container,
                  displayName: "微信主容器（聊天记录与文件）",
                  relativePath: "Library/Containers/com.tencent.xinWeChat",
                  archiveName: "container-com.tencent.xinWeChat.tar",
                  fileCount: 42, logicalSize: 1234, archiveSize: 999, sha256: "ab" ),
            .init(id: "app-WeChat", kind: .application,
                  displayName: "微信应用本体（WeChat.app）",
                  relativePath: "Applications/WeChat.app",
                  archiveName: "app-WeChat.tar",
                  fileCount: 10, logicalSize: 100, archiveSize: 90, sha256: "cd"),
        ])
    let decoded = try BackupManifest.decode(manifest.encoded())
    #expect(decoded == manifest)
    #expect(decoded.totalLogicalSize == 1334)
    #expect(decoded.restorableEntries.map(\.id) == ["container-com.tencent.xinWeChat"])
    #expect(decoded.appEntry?.id == "app-WeChat")
}

// MARK: - VaultStore

@Test func snapshotNameFormat() {
    let date = DateComponents(calendar: .init(identifier: .gregorian),
                              timeZone: .current,
                              year: 2026, month: 8, day: 30,
                              hour: 12, minute: 34, second: 56).date!
    #expect(VaultStore.snapshotName(date: date) == "WeChatBackup-20260830-123456")
}

@Test func completionMarkerDetectsTampering() throws {
    try withTempDir { vault in
        let env = try makeFixtureHome(vault.appendingPathComponent("home"))
        try FileManager.default.createDirectory(
            at: env.home, withIntermediateDirectories: true)
        let request = makeBackupRequest(env: env, vault: vault)
        let snapshot = try runBackup(request)
        #expect(snapshot.isComplete)

        // 篡改 manifest → 完成标记失配 → 不完整
        let manifestURL = snapshot.directoryURL.appendingPathComponent("manifest.json")
        var text = try String(contentsOf: manifestURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "4.0.6", with: "9.9.9")
        try text.write(to: manifestURL, atomically: true, encoding: .utf8)
        #expect(!VaultStore.loadSnapshot(at: snapshot.directoryURL).isComplete)

        // 删掉标记 → 不完整
        try FileManager.default.removeItem(
            at: snapshot.directoryURL.appendingPathComponent("COMPLETE"))
        #expect(!VaultStore.loadSnapshot(at: snapshot.directoryURL).isComplete)
    }
}

@Test func listSnapshotsNewestFirstIncludingIncomplete() throws {
    try withTempDir { vault in
        let env = try makeFixtureHome(vault.appendingPathComponent("home"))
        let t1 = Date(timeIntervalSinceNow: -7200)
        let t2 = Date(timeIntervalSinceNow: -3600)
        _ = try runBackup(makeBackupRequest(env: env, vault: vault, now: t1))
        _ = try runBackup(makeBackupRequest(env: env, vault: vault, now: t2))
        // 手造一个中断残留（.inprogress）
        try FileManager.default.createDirectory(
            at: VaultStore.vaultRoot(base: vault)
                .appendingPathComponent("WeChatBackup-20200101-000000.inprogress"),
            withIntermediateDirectories: true)

        let snapshots = VaultStore.listSnapshots(base: vault)
        #expect(snapshots.count == 3)
        #expect(snapshots[0].name == VaultStore.snapshotName(date: t2))
        #expect(snapshots[0].isComplete && snapshots[1].isComplete)
        #expect(!snapshots[2].isComplete)   // 残留排最后（名称最旧）且不完整
    }
}

@Test func verifyPassesAndCatchesCorruption() throws {
    try withTempDir { vault in
        let env = try makeFixtureHome(vault.appendingPathComponent("home"))
        let snapshot = try runBackup(makeBackupRequest(env: env, vault: vault))
        #expect(VaultStore.verify(snapshot: snapshot).isEmpty)

        // 破坏一个归档 → 验证报大小与 SHA-256 问题
        let archive = snapshot.directoryURL
            .appendingPathComponent("container-com.tencent.xinWeChat.tar")
        var data = try Data(contentsOf: archive)
        data.append(contentsOf: [0xde, 0xad])
        try data.write(to: archive)
        let problems = VaultStore.verify(snapshot: VaultStore.loadSnapshot(at: snapshot.directoryURL))
        #expect(problems.contains { $0.contains("SHA-256") })
    }
}

@Test func deleteSnapshotRefusesPathsOutsideVault() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let victim = try makeDataDir(root: root, "victim-WeChatBackup-x")
        let fake = SnapshotInfo(directoryURL: victim, name: victim.lastPathComponent,
                                manifest: nil, isComplete: false)
        #expect(throws: BackupError.self) {
            try VaultStore.deleteSnapshot(fake, base: vault)
        }
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }
}

@Test func deleteSnapshotRemovesRealSnapshot() throws {
    try withTempDir { vault in
        let env = try makeFixtureHome(vault.appendingPathComponent("home"))
        let snapshot = try runBackup(makeBackupRequest(env: env, vault: vault))
        try VaultStore.deleteSnapshot(snapshot, base: vault)
        #expect(VaultStore.listSnapshots(base: vault).isEmpty)
    }
}

// MARK: - BackupEngine

@Test func backupProducesCompleteSnapshotWithAccurateManifest() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        var logs: [String] = []
        var progressValues: [Double] = []
        let snapshot = try runBackup(
            makeBackupRequest(env: env, vault: vault),
            log: { logs.append($0) },
            progress: { progressValues.append($0) })

        #expect(snapshot.isComplete)
        let manifest = try #require(snapshot.manifest)
        #expect(manifest.formatVersion == BackupManifest.currentFormatVersion)
        #expect(manifest.wechatVersion == "4.0.6")
        #expect(manifest.wechatBuild == "28582")
        #expect(manifest.macOSVersion == "15.5.0")
        #expect(manifest.entries.count == 6)

        // 主容器条目：文件数/逻辑大小与 fixture 一致，SHA-256 与磁盘实际一致
        let main = try #require(manifest.entries.first {
            $0.id == "container-com.tencent.xinWeChat"
        })
        #expect(main.fileCount == 2)
        #expect(main.logicalSize == 3000)
        let archive = snapshot.directoryURL.appendingPathComponent(main.archiveName)
        #expect(try Checksum.sha256(of: archive) == main.sha256)
        let realSize = try FileManager.default
            .attributesOfItem(atPath: archive.path)[.size] as? Int64
        #expect(realSize == main.archiveSize)

        // 进度单调到 1，日志有内容，源数据未被改动
        #expect(progressValues.last == 1)
        #expect(progressValues == progressValues.sorted())
        #expect(!logs.isEmpty)
        #expect(FileStats.measure(at: env.url(for: env.discoverComponents()[0])).fileCount > 0)
    }
}

@Test func backupThrowsWhenNothingToBackup() throws {
    try withTempDir { root in
        let env = WeChatEnvironment(home: root.appendingPathComponent("home"))
        #expect(throws: BackupError.nothingToBackup) {
            _ = try runBackup(
                makeBackupRequest(env: env, vault: root, components: []))
        }
    }
}

@Test func backupCancellationLeavesNoResidue() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        var calls = 0
        #expect(throws: BackupError.cancelled) {
            _ = try runBackup(
                makeBackupRequest(env: env, vault: vault),
                isCancelled: { calls += 1; return calls > 2 })   // 第三个组件前取消
        }
        // 不留下任何 .inprogress 或完成快照
        #expect(VaultStore.listSnapshots(base: vault).isEmpty)
        let rootEntries = (try? FileManager.default.contentsOfDirectory(
            atPath: VaultStore.vaultRoot(base: vault).path)) ?? []
        #expect(rootEntries.filter { $0 != ".metadata_never_index" }.isEmpty)
    }
}

// MARK: - RestoreEngine

@Test func makePlanRequiresCompleteSnapshot() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        let snapshot = try runBackup(makeBackupRequest(env: env, vault: vault))
        try FileManager.default.removeItem(
            at: snapshot.directoryURL.appendingPathComponent("COMPLETE"))
        let incomplete = VaultStore.loadSnapshot(at: snapshot.directoryURL)
        #expect(throws: BackupError.self) {
            _ = try RestoreEngine.makePlan(
                snapshot: incomplete, environment: env, currentWeChatVersion: "4.0.6")
        }
    }
}

@Test func makePlanFlagsVersionMismatch() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        let snapshot = try runBackup(makeBackupRequest(env: env, vault: vault))

        let same = try RestoreEngine.makePlan(
            snapshot: snapshot, environment: env, currentWeChatVersion: "4.0.6")
        #expect(!same.versionMismatch)
        #expect(same.items.count == 6)
        #expect(same.items.allSatisfy { $0.targetExists })

        let diff = try RestoreEngine.makePlan(
            snapshot: snapshot, environment: env, currentWeChatVersion: "3.8.0")
        #expect(diff.versionMismatch)
        #expect(!diff.warnings.isEmpty)

        let none = try RestoreEngine.makePlan(
            snapshot: snapshot, environment: env, currentWeChatVersion: nil)
        #expect(!none.versionMismatch)   // 未安装不算不一致，仅警告
        #expect(none.warnings.contains { $0.contains("未检测到微信") })
    }
}

@Test func restoreRoundTripKeepsOldDataAsRollback() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        let mainDir = env.home.appendingPathComponent(
            "Library/Containers/com.tencent.xinWeChat", isDirectory: true)
        let originalFile = mainDir.appendingPathComponent("Data/Documents/file0.bin")
        let originalData = try Data(contentsOf: originalFile)

        let snapshot = try runBackup(makeBackupRequest(env: env, vault: vault))

        // 备份后数据被「破坏」：改写内容 + 加新文件
        try Data("已损坏".utf8).write(to: originalFile)
        try Data([1]).write(to: mainDir.appendingPathComponent("junk.bin"))

        let plan = try RestoreEngine.makePlan(
            snapshot: snapshot, environment: env, currentWeChatVersion: "4.0.6")
        let result = try runRestore(
            plan: plan, environment: env,
            now: Date(timeIntervalSince1970: 1_772_400_000))

        // 内容恢复为备份时的样子；junk 不在恢复后的目录里
        #expect(try Data(contentsOf: originalFile) == originalData)
        #expect(!FileManager.default.fileExists(
            atPath: mainDir.appendingPathComponent("junk.bin").path))

        // 原数据完整保留在回滚副本中（含 junk），绝未删除
        #expect(result.rollbackDirs.count == 6)
        let rollbackName = try #require(result.rollbackDirs.first {
            $0.hasPrefix("com.tencent.xinWeChat.wcm-rollback-")
        })
        let rollback = mainDir.deletingLastPathComponent().appendingPathComponent(rollbackName)
        #expect(FileManager.default.fileExists(
            atPath: rollback.appendingPathComponent("junk.bin").path))
        #expect(try Data(contentsOf: rollback.appendingPathComponent("Data/Documents/file0.bin"))
                == Data("已损坏".utf8))

        // 暂存目录已清理
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: mainDir.deletingLastPathComponent().path)
            .filter { $0.contains(".wcm-staging-") }
        #expect(leftovers.isEmpty)
    }
}

@Test func restoreWhenTargetMissingCreatesItWithoutRollback() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        let snapshot = try runBackup(makeBackupRequest(env: env, vault: vault))

        // 模拟换机/清空：删除主容器
        let mainDir = env.home.appendingPathComponent(
            "Library/Containers/com.tencent.xinWeChat", isDirectory: true)
        try FileManager.default.removeItem(at: mainDir)

        let plan = try RestoreEngine.makePlan(
            snapshot: snapshot, environment: env, currentWeChatVersion: "4.0.6")
        #expect(plan.items.first {
            $0.entry.id == "container-com.tencent.xinWeChat"
        }?.targetExists == false)

        let result = try runRestore(plan: plan, environment: env)
        #expect(FileManager.default.fileExists(
            atPath: mainDir.appendingPathComponent("Data/Documents/file0.bin").path))
        // 只有原本存在的 5 个目录留回滚副本
        #expect(result.rollbackDirs.count == 5)
    }
}

@Test func restoreRejectsTamperedArchiveBeforeTouchingData() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        let snapshot = try runBackup(makeBackupRequest(env: env, vault: vault))
        let plan = try RestoreEngine.makePlan(
            snapshot: snapshot, environment: env, currentWeChatVersion: "4.0.6")

        // 篡改归档
        let archive = snapshot.directoryURL
            .appendingPathComponent("container-com.tencent.xinWeChat.tar")
        var data = try Data(contentsOf: archive)
        data[data.count - 1] ^= 0xff
        try data.write(to: archive)

        let mainDir = env.home.appendingPathComponent(
            "Library/Containers/com.tencent.xinWeChat", isDirectory: true)
        let before = FileStats.measure(at: mainDir)
        #expect(throws: BackupError.self) {
            _ = try runRestore(plan: plan, environment: env)
        }
        // 数据分毫未动，也没有回滚/暂存残留
        #expect(FileStats.measure(at: mainDir) == before)
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: mainDir.deletingLastPathComponent().path)
        #expect(!siblings.contains { $0.contains(".wcm-") })
    }
}

// MARK: - 退出微信流程（全部注入，不触碰真实微信）

@Test func ensureQuitReturnsImmediatelyWhenNotRunning() async {
    var gracefulCalled = false
    let ok = await WeChatQuitter.ensureQuit(
        graceTimeout: 0.1, forceTimeout: 0.1,
        isRunning: { false },
        graceful: { gracefulCalled = true },
        force: { })
    #expect(ok)
    #expect(!gracefulCalled)
}

@Test func ensureQuitGracefulPathSucceeds() async {
    var running = true
    let ok = await WeChatQuitter.ensureQuit(
        graceTimeout: 1, forceTimeout: 1,
        isRunning: { running },
        graceful: { running = false },
        force: { })
    #expect(ok)
}

@Test func ensureQuitFallsBackToForceKill() async {
    var running = true
    var forced = false
    let ok = await WeChatQuitter.ensureQuit(
        graceTimeout: 0.2, forceTimeout: 1,
        isRunning: { running },
        graceful: { },                      // 优雅退出无效
        force: { forced = true; running = false })
    #expect(ok)
    #expect(forced)
}

@Test func ensureQuitReportsFailureWhenStillRunning() async {
    let ok = await WeChatQuitter.ensureQuit(
        graceTimeout: 0.2, forceTimeout: 0.2,
        isRunning: { true },
        graceful: { }, force: { })
    #expect(!ok)
}

// MARK: - 备份仓库与源目录重叠（防递归归档/写入源目录）

/// 改写快照清单并重写完成标记（模拟恶意/损坏 manifest 的测试辅助）。
private func rewriteManifest(
    _ snapshot: SnapshotInfo,
    mutate: (inout BackupManifest) -> Void
) throws -> SnapshotInfo {
    var manifest = try #require(snapshot.manifest)
    mutate(&manifest)
    try VaultStore.writeManifest(manifest, to: snapshot.directoryURL)
    try VaultStore.writeCompletionMarker(in: snapshot.directoryURL)
    return VaultStore.loadSnapshot(at: snapshot.directoryURL)
}

@Test func backupRefusesVaultInsideSourceComponent() throws {
    try withTempDir { root in
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        // 备份仓库选在主容器内部 → 归档时会把仓库归进去（递归），必须拒绝
        let vault = env.home.appendingPathComponent(
            "Library/Containers/com.tencent.xinWeChat/Backups", isDirectory: true)
        #expect(throws: BackupError.self) {
            _ = try runBackup(makeBackupRequest(env: env, vault: vault))
        }
        // 未在源目录里留下任何写入
        #expect(!FileManager.default.fileExists(atPath: vault.path))
    }
}

@Test func backupRefusesSourceInsideVault() throws {
    try withTempDir { root in
        // home 摆在仓库根内部 → 源目录会被写进的仓库包含，必须拒绝
        let vault = root
        let env = try makeFixtureHome(
            VaultStore.vaultRoot(base: vault).appendingPathComponent("home"))
        #expect(throws: BackupError.self) {
            _ = try runBackup(makeBackupRequest(env: env, vault: vault))
        }
    }
}

@Test func backupOverlapCheckResolvesSymlinks() throws {
    try withTempDir { root in
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        // base 下预置符号链接 WeChatBackups → 主容器：解析后仓库根 == 源目录
        let base = root.appendingPathComponent("base", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("WeChatBackups"),
            withDestinationURL: env.home.appendingPathComponent(
                "Library/Containers/com.tencent.xinWeChat"))
        #expect(throws: BackupError.self) {
            _ = try runBackup(makeBackupRequest(env: env, vault: base))
        }
        // 源目录未被写入快照内容
        let srcEntries = try FileManager.default.contentsOfDirectory(
            atPath: env.home.appendingPathComponent(
                "Library/Containers/com.tencent.xinWeChat").path)
        #expect(!srcEntries.contains { $0.hasPrefix("WeChatBackup-") })
    }
}

@Test func pathsOverlapLogic() {
    let a = URL(fileURLWithPath: "/tmp/a", isDirectory: true)
    #expect(BackupEngine.pathsOverlap(a, a))
    #expect(BackupEngine.pathsOverlap(a, URL(fileURLWithPath: "/tmp/a/b")))
    #expect(BackupEngine.pathsOverlap(URL(fileURLWithPath: "/tmp/a/b"), a))
    #expect(!BackupEngine.pathsOverlap(a, URL(fileURLWithPath: "/tmp/ab")))   // 前缀但非父子
    #expect(!BackupEngine.pathsOverlap(a, URL(fileURLWithPath: "/tmp/c")))
}

// MARK: - 清单白名单校验（恶意 manifest）

@Test func manifestArchiveNameValidation() {
    #expect(ManifestValidation.archiveNameProblem("container-x.tar") == nil)
    #expect(ManifestValidation.archiveNameProblem("../evil.tar") != nil)
    #expect(ManifestValidation.archiveNameProblem("sub/evil.tar") != nil)
    #expect(ManifestValidation.archiveNameProblem("a\\b.tar") != nil)
    #expect(ManifestValidation.archiveNameProblem(".hidden.tar") != nil)
    #expect(ManifestValidation.archiveNameProblem("..") != nil)
    #expect(ManifestValidation.archiveNameProblem("") != nil)
    #expect(ManifestValidation.archiveNameProblem("noext") != nil)
    #expect(ManifestValidation.archiveNameProblem(".tar") != nil)
}

@Test func manifestRelativePathValidation() {
    #expect(ManifestValidation.relativePathProblem(
        "Library/Containers/com.tencent.xinWeChat", kind: .container) == nil)
    #expect(ManifestValidation.relativePathProblem(
        "Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat", kind: .groupContainer) == nil)
    #expect(ManifestValidation.relativePathProblem(
        "Library/Application Scripts/com.tencent.xinWeChat.WeChatMacShare", kind: .appScripts) == nil)
    // 越界/穿越/非白名单
    #expect(ManifestValidation.relativePathProblem(
        "Desktop/com.tencent.xinWeChat", kind: .container) != nil)
    #expect(ManifestValidation.relativePathProblem(
        "/Library/Containers/com.tencent.xinWeChat", kind: .container) != nil)
    #expect(ManifestValidation.relativePathProblem(
        "Library/Containers/../../Desktop/com.tencent.xinWeChat", kind: .container) != nil)
    #expect(ManifestValidation.relativePathProblem(
        "Library/Containers/com.apple.Notes", kind: .container) != nil)
    // 父目录与 kind 不符
    #expect(ManifestValidation.relativePathProblem(
        "Library/Containers/com.tencent.xinWeChat", kind: .groupContainer) != nil)
    // 不允许恢复进 .wcm- 派生目录名
    #expect(ManifestValidation.relativePathProblem(
        "Library/Containers/com.tencent.xinWeChat.wcm-rollback-20260830-1", kind: .container) != nil)
    // 应用本体：仅需不可穿越
    #expect(ManifestValidation.relativePathProblem(
        "Applications/WeChat.app", kind: .application) == nil)
    #expect(ManifestValidation.relativePathProblem(
        "../Applications/WeChat.app", kind: .application) != nil)
}

@Test func makePlanRejectsMaliciousManifests() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        let good = try runBackup(makeBackupRequest(env: env, vault: vault))

        func expectPlanRejected(_ mutate: (inout BackupManifest) -> Void) throws {
            let bad = try rewriteManifest(good, mutate: mutate)
            #expect(throws: BackupError.self) {
                _ = try RestoreEngine.makePlan(
                    snapshot: bad, environment: env, currentWeChatVersion: "4.0.6")
            }
        }

        // archiveName 穿越 / 带子路径
        try expectPlanRejected { $0.entries[0].archiveName = "../../evil.tar" }
        try expectPlanRejected { $0.entries[0].archiveName = "sub/evil.tar" }
        // relativePath 指向白名单之外
        try expectPlanRejected { $0.entries[0].relativePath = "Desktop/com.tencent.xinWeChat" }
        try expectPlanRejected {
            $0.entries[0].relativePath = "Library/Containers/../../Desktop/com.tencent.xinWeChat"
        }
        try expectPlanRejected { $0.entries[0].relativePath = "Library/Containers/com.apple.Notes" }
        try expectPlanRejected {
            $0.entries[0].relativePath = "Library/Containers/com.tencent.xinWeChat.wcm-rollback-1"
        }
        // 重复 target / 重复 archiveName
        try expectPlanRejected { $0.entries[1].relativePath = $0.entries[0].relativePath }
        try expectPlanRejected { $0.entries[1].archiveName = $0.entries[0].archiveName }
        // 没有可自动恢复的条目
        try expectPlanRejected { m in
            m.entries = [BackupManifest.Entry(
                id: "app-WeChat", kind: .application,
                displayName: "微信应用本体（WeChat.app）",
                relativePath: "Applications/WeChat.app",
                archiveName: "app-WeChat.tar",
                fileCount: 1, logicalSize: 1, archiveSize: 1, sha256: "00")]
        }

        // 还原为合法清单后计划照常可用（fixture 未被上面破坏）
        let restored = try rewriteManifest(good) { _ in }
        _ = try RestoreEngine.makePlan(
            snapshot: restored, environment: env, currentWeChatVersion: "4.0.6")
    }
}

// MARK: - verify 的结构与清单校验

@Test func verifyReportsManifestProblems() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        let good = try runBackup(makeBackupRequest(env: env, vault: vault))

        let bad = try rewriteManifest(good) {
            $0.entries[0].archiveName = "../evil.tar"
            $0.entries[1].relativePath = "Desktop/escape"
        }
        let problems = VaultStore.verify(snapshot: bad)
        #expect(problems.contains { $0.contains("archiveName") })
        #expect(problems.contains { $0.contains("relativePath") || $0.contains("白名单") })
    }
}

@Test func verifyReportsUnexpectedTopLevelStructure() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        let good = try runBackup(makeBackupRequest(env: env, vault: vault))

        // 把 MacShare 条目的 relativePath 改成另一个合法家族名：
        // 清单本身合法，但归档顶层目录与预期不符 → 结构校验必须报告
        let entryIndex = try #require(good.manifest?.entries.firstIndex {
            $0.id == "container-com.tencent.xinWeChat.WeChatMacShare"
        })
        let bad = try rewriteManifest(good) {
            $0.entries[entryIndex].relativePath = "Library/Containers/com.tencent.xinWeChat.Other"
        }
        let problems = VaultStore.verify(snapshot: bad)
        #expect(problems.contains { $0.contains("结构校验未通过") })
        // 未被篡改的快照依旧全部通过
        let clean = try rewriteManifest(good) { _ in }
        #expect(VaultStore.verify(snapshot: clean).isEmpty)
    }
}

// MARK: - 回滚失败不吞错（可注入文件操作）

private struct TestMoveError: Error, Equatable { let tag: String }

@Test func restoreCommitFailureRollsBackAndRethrowsOriginal() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        let mainDir = env.home.appendingPathComponent(
            "Library/Containers/com.tencent.xinWeChat", isDirectory: true)
        let marker = mainDir.appendingPathComponent("Data/Documents/file0.bin")
        let snapshot = try runBackup(makeBackupRequest(env: env, vault: vault))
        try Data("备份后的新数据".utf8).write(to: marker)

        let plan = try RestoreEngine.makePlan(
            snapshot: snapshot, environment: env, currentWeChatVersion: "4.0.6")
        let groupTarget = "5A4RE8SF68.com.tencent.xinWeChat"
        // 第 4 项（群组容器）落位时注入失败；其余移动放行
        let ops = RestoreEngine.FileOps(moveItem: { from, to in
            if from.path.contains(".wcm-staging-") && to.lastPathComponent == groupTarget {
                throw TestMoveError(tag: "commit-fail")
            }
            try FileManager.default.moveItem(at: from, to: to)
        })
        var thrown: Error?
        do {
            _ = try runRestore(
                plan: plan, environment: env, fileOps: ops, isWeChatRunning: { false })
        } catch { thrown = error }

        // 抛出的是原始错误（回滚成功时不得包装成回滚错误，也不得吞掉）
        #expect(thrown as? TestMoveError == TestMoveError(tag: "commit-fail"))
        // 已回滚：恢复前的数据回到原位（含备份后的修改）
        #expect(try Data(contentsOf: marker) == Data("备份后的新数据".utf8))
        // 不留 rollback/staging；失败落位的副本以 .wcm-failed 保留（未删除）
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: mainDir.deletingLastPathComponent().path)
        #expect(!siblings.contains { $0.contains(".wcm-rollback-") })
        #expect(!siblings.contains { $0.contains(".wcm-staging-") })
        #expect(siblings.contains { $0.contains(".wcm-failed-") })
    }
}

@Test func restoreRollbackFailureThrowsSevereErrorAndKeepsData() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        let mainDir = env.home.appendingPathComponent(
            "Library/Containers/com.tencent.xinWeChat", isDirectory: true)
        let marker = mainDir.appendingPathComponent("Data/Documents/file0.bin")
        let snapshot = try runBackup(makeBackupRequest(env: env, vault: vault))
        try Data("恢复前的现网数据".utf8).write(to: marker)

        let plan = try RestoreEngine.makePlan(
            snapshot: snapshot, environment: env, currentWeChatVersion: "4.0.6")
        let now = Date(timeIntervalSince1970: 1_772_500_000)
        let ts = VaultStore.timestampString(now)
        let groupTarget = "5A4RE8SF68.com.tencent.xinWeChat"
        let mainFailedName = "com.tencent.xinWeChat.wcm-failed-\(ts)"
        // 群组容器落位失败触发回滚；回滚中主容器「移开新数据」也失败 → 回滚不完整
        let ops = RestoreEngine.FileOps(moveItem: { from, to in
            if from.path.contains(".wcm-staging-") && to.lastPathComponent == groupTarget {
                throw TestMoveError(tag: "commit-fail")
            }
            if to.lastPathComponent == mainFailedName {
                throw TestMoveError(tag: "rollback-fail")
            }
            try FileManager.default.moveItem(at: from, to: to)
        })
        var thrown: Error?
        do {
            _ = try runRestore(
                plan: plan, environment: env, now: now,
                fileOps: ops, isWeChatRunning: { false })
        } catch { thrown = error }

        // 必须是明确的严重错误，且消息列出原数据（rollback）位置
        guard case .rollbackIncomplete(let msg)? = thrown as? BackupError else {
            Issue.record("期望 rollbackIncomplete，实得 \(String(describing: thrown))")
            return
        }
        let rollbackName = "com.tencent.xinWeChat.wcm-rollback-\(ts)"
        #expect(msg.contains(rollbackName))
        #expect(msg.contains("commit-fail") || msg.contains("首因"))
        // 原数据完好保留在 rollback 目录，未被删除
        let rollbackFile = mainDir.deletingLastPathComponent()
            .appendingPathComponent(rollbackName)
            .appendingPathComponent("Data/Documents/file0.bin")
        #expect(try Data(contentsOf: rollbackFile) == Data("恢复前的现网数据".utf8))
        // 快照内容也已落到主容器原位（新数据未被移走），同样未删除
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}

// MARK: - 写操作前复查微信未运行（防退出后重开竞态；全部注入闭包）

@Test func backupRefusesWhenWeChatRunningBeforeFirstWrite() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        #expect(throws: BackupError.wechatStillRunning) {
            _ = try runBackup(
                makeBackupRequest(env: env, vault: vault),
                isWeChatRunning: { true })
        }
        // 仓库里没有任何写入残留
        #expect(!FileManager.default.fileExists(atPath: VaultStore.vaultRoot(base: vault).path))
    }
}

@Test func backupAbortsWhenWeChatRelaunchesMidway() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        var calls = 0
        #expect(throws: BackupError.wechatStillRunning) {
            _ = try runBackup(
                makeBackupRequest(env: env, vault: vault),
                isWeChatRunning: { calls += 1; return calls > 2 })   // 第二个组件前重开
        }
        // 中止后不留 .inprogress 残留
        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: VaultStore.vaultRoot(base: vault).path)) ?? []
        #expect(entries.filter { $0 != ".metadata_never_index" }.isEmpty)
    }
}

@Test func restoreAbortsBeforeCommitWhenWeChatRelaunches() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        let mainDir = env.home.appendingPathComponent(
            "Library/Containers/com.tencent.xinWeChat", isDirectory: true)
        let snapshot = try runBackup(makeBackupRequest(env: env, vault: vault))
        let plan = try RestoreEngine.makePlan(
            snapshot: snapshot, environment: env, currentWeChatVersion: "4.0.6")
        let before = FileStats.measure(at: mainDir)

        var calls = 0
        #expect(throws: BackupError.wechatStillRunning) {
            // 第 1 次检查（解压前）通过，第 2 次（落位前）发现微信重开 → 中止
            _ = try runRestore(
                plan: plan, environment: env,
                isWeChatRunning: { calls += 1; return calls >= 2 })
        }
        #expect(calls >= 2)
        // 微信目录分毫未动，暂存已清理
        #expect(FileStats.measure(at: mainDir) == before)
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: mainDir.deletingLastPathComponent().path)
        #expect(!siblings.contains { $0.contains(".wcm-") })
    }
}

// MARK: - 归档后/逐项落位前的微信重开复查（最小安全修复）

@Test func backupSingleComponentAbortsWhenWeChatReopensDuringArchive() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        let main = try #require(env.discoverComponents().first {
            $0.id == "container-com.tencent.xinWeChat"
        })
        var calls = 0
        #expect(throws: BackupError.wechatStillRunning) {
            // 1=首写前 2=归档前 3=归档完成后：唯一组件归档期间微信重开
            _ = try runBackup(
                makeBackupRequest(env: env, vault: vault, components: [main]),
                isWeChatRunning: { calls += 1; return calls >= 3 })
        }
        #expect(calls == 3)
        // 本次 .inprogress 已删除，不生成快照
        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: VaultStore.vaultRoot(base: vault).path)) ?? []
        #expect(entries.filter { $0 != ".metadata_never_index" }.isEmpty)
        #expect(VaultStore.listSnapshots(base: vault).isEmpty)
    }
}

@Test func restoreRollsBackWhenWeChatReopensAfterFirstCommit() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        let mainDir = env.home.appendingPathComponent(
            "Library/Containers/com.tencent.xinWeChat", isDirectory: true)
        let marker = mainDir.appendingPathComponent("Data/Documents/file0.bin")
        let fpDir = env.home.appendingPathComponent(
            "Library/Containers/com.tencent.xinWeChat.WeChatFileProviderExtension", isDirectory: true)
        let snapshot = try runBackup(makeBackupRequest(env: env, vault: vault))
        try Data("恢复前的现网数据".utf8).write(to: marker)

        let plan = try RestoreEngine.makePlan(
            snapshot: snapshot, environment: env, currentWeChatVersion: "4.0.6")
        #expect(plan.items.count > 1)
        let fpBefore = FileStats.measure(at: fpDir)

        var calls = 0
        #expect(throws: BackupError.wechatStillRunning) {
            // 1=解压前 2=落位循环前 3=第一项动手前 4=第二项动手前：
            // 第一项已提交后微信重开 → 必须完整回滚再抛错
            _ = try runRestore(
                plan: plan, environment: env,
                isWeChatRunning: { calls += 1; return calls >= 4 })
        }
        #expect(calls == 4)
        // 第一项已完整回滚：恢复前的数据回到原位
        #expect(try Data(contentsOf: marker) == Data("恢复前的现网数据".utf8))
        // 无 rollback/staging 残留；第一项失败落位的副本以 .wcm-failed 保留（未删除）
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: mainDir.deletingLastPathComponent().path)
        #expect(!siblings.contains { $0.contains(".wcm-rollback-") })
        #expect(!siblings.contains { $0.contains(".wcm-staging-") })
        #expect(siblings.contains { $0.hasPrefix("com.tencent.xinWeChat.wcm-failed-") })
        // 未轮到的目标分毫未动
        #expect(FileStats.measure(at: fpDir) == fpBefore)
    }
}

// MARK: - 子进程大量 stderr 输出不得死锁（回归：归档工具警告灌满管道缓冲）

@Test(.timeLimit(.minutes(1)))
func runProcessSurvivesHugeStderrOutput() {
    // 向 stderr 写约 200KB（远超 64KB 管道缓冲）后正常输出 stdout 并退出。
    // 旧的双管道顺序读实现会在此死锁；文件重定向实现应正常返回。
    let script = """
    i=0
    while [ $i -lt 8000 ]; do
      echo "warning line $i with some padding text" 1>&2
      i=$((i+1))
    done
    echo OK
    """
    let result = Archiver.runProcess("/bin/sh", ["-c", script])
    #expect(result.status == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "OK")
    #expect(result.stderr.contains("warning line 7999"))
}

@Test func truncatedForDisplayLimitsLongText() {
    let short = "短消息"
    #expect(Archiver.truncatedForDisplay(short) == short)
    let long = String(repeating: "警告行\n", count: 2000)
    let out = Archiver.truncatedForDisplay(long)
    #expect(out.count < 1400)
    #expect(out.contains("已截断"))
}

// MARK: - 容器外克隆（ContainerCloner）

@Test func cloneTreePreservesContentXattrAndSymlink() throws {
    try withTempDir { root in
        let src = try makeDataDir(root: root, "com.tencent.xinWeChat", fileSizes: [64, 128])
        // xattr + 符号链接 + 根层受保护 plist
        let f = src.appendingPathComponent("file0.bin")
        let val = Data("克隆保真".utf8)
        _ = val.withUnsafeBytes { setxattr(f.path, "com.wcm.test", $0.baseAddress, val.count, 0, 0) }
        try FileManager.default.createSymbolicLink(
            atPath: src.appendingPathComponent("link").path,
            withDestinationPath: "file0.bin")
        try Data("protected".utf8).write(
            to: src.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))

        let parent = root.appendingPathComponent(ContainerCloner.clonePrefix + "t", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let clone = parent.appendingPathComponent("com.tencent.xinWeChat", isDirectory: true)
        var logs: [String] = []
        try ContainerCloner.cloneTree(source: src, to: clone, log: { logs.append($0) })

        // 受保护 plist 在克隆阶段即被跳过（有日志），克隆里不存在
        #expect(logs.contains { $0.contains("containermanagerd") })
        #expect(!FileManager.default.fileExists(
            atPath: clone.appendingPathComponent(".com.apple.containermanagerd.metadata.plist").path))
        // 源里的 plist 分毫未动
        #expect(FileManager.default.fileExists(
            atPath: src.appendingPathComponent(".com.apple.containermanagerd.metadata.plist").path))
        // 内容、xattr、符号链接均保真
        #expect(try Data(contentsOf: clone.appendingPathComponent("file0.bin"))
                == Data(repeating: 1, count: 64))
        var buf = [UInt8](repeating: 0, count: 32)
        let n = getxattr(clone.appendingPathComponent("file0.bin").path, "com.wcm.test", &buf, buf.count, 0, 0)
        #expect(Data(buf.prefix(max(n, 0))) == val)
        let dest = try FileManager.default.destinationOfSymbolicLink(
            atPath: clone.appendingPathComponent("link").path)
        #expect(dest == "file0.bin")
    }
}

@Test func cloneTreeRetriesOnTransientErrorsThenGivesUp() throws {
    try withTempDir { root in
        // 单一顶层子目录，便于精确计数（克隆按顶层子项逐个执行）
        let src = root.appendingPathComponent("s", isDirectory: true)
        try makeDataDir(root: src, "inner")
        let dst = root.appendingPathComponent("d")
        // 第 1 次 EINTR、第 2 次瞬时 EPERM，第 3 次成功
        var calls = 0
        try ContainerCloner.cloneTree(source: src, to: dst, cloneOp: { from, to in
            calls += 1
            if calls == 1 { throw ContainerCloner.CloneError.interrupted }
            if calls == 2 { throw ContainerCloner.CloneError.failed(errno: EPERM) }
            try ContainerCloner.systemCloneFile(from, to)
        })
        #expect(calls == 3)
        #expect(FileManager.default.fileExists(
            atPath: dst.appendingPathComponent("inner/file0.bin").path))

        // 一直 EINTR → 到达上限后抛出；非瞬时错误（如 ENOENT）不重试
        var always = 0
        #expect(throws: ContainerCloner.CloneError.interrupted) {
            try ContainerCloner.cloneTree(
                source: src, to: root.appendingPathComponent("d2"),
                maxAttempts: 3, cloneOp: { _, _ in always += 1; throw ContainerCloner.CloneError.interrupted })
        }
        #expect(always == 3)
        var once = 0
        #expect(throws: ContainerCloner.CloneError.failed(errno: ENOENT)) {
            try ContainerCloner.cloneTree(
                source: src, to: root.appendingPathComponent("d3"),
                cloneOp: { _, _ in once += 1; throw ContainerCloner.CloneError.failed(errno: ENOENT) })
        }
        #expect(once == 1)
    }
}

@Test func removeCloneHandlesReadOnlyDirsAndRefusesForeignPaths() throws {
    try withTempDir { root in
        // 带只读子目录的克隆目录：能删干净
        let clone = root.appendingPathComponent(ContainerCloner.clonePrefix + "x", isDirectory: true)
        let ro = try makeDataDir(root: clone, "readonly")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        ContainerCloner.removeClone(clone)
        #expect(!FileManager.default.fileExists(atPath: clone.path))

        // 无克隆前缀的目录：拒绝删除
        let foreign = try makeDataDir(root: root, "not-a-clone")
        ContainerCloner.removeClone(foreign)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }
}

@Test func backupExcludesProtectedPlistViaClone() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        let mainDir = env.home.appendingPathComponent(
            "Library/Containers/com.tencent.xinWeChat", isDirectory: true)
        try Data("protected".utf8).write(
            to: mainDir.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))

        let snapshot = try runBackup(makeBackupRequest(env: env, vault: vault))
        let manifest = try #require(snapshot.manifest)
        let main = try #require(manifest.entries.first { $0.id == "container-com.tencent.xinWeChat" })
        // 归档与清单都不含受保护 plist（fixture 主容器只有 2 个数据文件）
        #expect(main.fileCount == 2)
        let entries = try Archiver.listEntries(
            archive: snapshot.directoryURL.appendingPathComponent(main.archiveName))
        #expect(!entries.contains { $0.contains("containermanagerd") })
        // 源目录里的 plist 原样保留
        #expect(FileManager.default.fileExists(
            atPath: mainDir.appendingPathComponent(".com.apple.containermanagerd.metadata.plist").path))
        // （克隆临时目录的清理由 removeClone 单测与引擎 defer 覆盖；
        //   并行测试各自有进行中的克隆，不能对全局临时目录做无残留断言。）
    }
}

@Test func backupWritesSpotlightNoIndexMarker() throws {
    // 备份仓库根必须带 .metadata_never_index，阻止 Spotlight 给几十 GB
    // 归档建索引、与备份写入抢 I/O。
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        _ = try runBackup(makeBackupRequest(env: env, vault: vault))
        #expect(FileManager.default.fileExists(
            atPath: VaultStore.vaultRoot(base: vault)
                .appendingPathComponent(".metadata_never_index").path))
    }
}
