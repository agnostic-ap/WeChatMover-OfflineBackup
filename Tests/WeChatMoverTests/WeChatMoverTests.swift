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

@Test func unsafeZipEntriesDetection() {
    let entries = [
        "ok/file.txt",
        "ok/nested/dir/",
        "/etc/passwd",              // 绝对路径
        "../escape.txt",            // 上跳
        "a/../../b.txt",            // 内嵌上跳
        "~root/x",                  // ~ 开头
        "a\\..\\b",                 // 反斜杠
        "weird/..",                 // 结尾上跳
    ]
    let unsafe = ZipArchiver.unsafeEntries(entries)
    #expect(unsafe.sorted() == [
        "/etc/passwd", "../escape.txt", "a/../../b.txt", "a\\..\\b", "weird/..", "~root/x",
    ].sorted())
}

@Test func validateEntriesRejectsStrayTopLevel() throws {
    // 顶层目录之外的条目（可能覆盖任意同级目录）→ 拒绝
    #expect(throws: BackupError.self) {
        try ZipArchiver.validateEntries(["expected/a.txt", "other/b.txt"],
                                        expectedTopLevel: "expected")
    }
    // 正常结构 + __MACOSX 伴生目录 → 通过
    try ZipArchiver.validateEntries(
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

// MARK: - ditto ZIP 往返（含扩展属性）

@Test func zipRoundTripPreservesContentAndXattr() throws {
    try withTempDir { dir in
        let src = try makeDataDir(root: dir, "payload", fileSizes: [128, 256])
        let fileWithXattr = src.appendingPathComponent("file0.bin")
        let xattrName = "com.wechatmover.test"
        let xattrValue = Data("元数据往返".utf8)
        let setResult = xattrValue.withUnsafeBytes { bytes in
            setxattr(fileWithXattr.path, xattrName, bytes.baseAddress, xattrValue.count, 0, 0)
        }
        #expect(setResult == 0)

        let archive = dir.appendingPathComponent("payload.zip")
        try ZipArchiver.createZip(source: src, archive: archive)
        #expect(FileManager.default.fileExists(atPath: archive.path))

        // 条目列出且全部安全、位于顶层目录内
        let entries = try ZipArchiver.listEntries(archive: archive)
        #expect(!entries.isEmpty)
        try ZipArchiver.validateEntries(entries, expectedTopLevel: "payload")

        // 解包到别处，内容与 xattr 均还原
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try ZipArchiver.extractZip(archive: archive, to: out)
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
                  archiveName: "container-com.tencent.xinWeChat.zip",
                  fileCount: 42, logicalSize: 1234, archiveSize: 999, sha256: "ab" ),
            .init(id: "app-WeChat", kind: .application,
                  displayName: "微信应用本体（WeChat.app）",
                  relativePath: "Applications/WeChat.app",
                  archiveName: "app-WeChat.zip",
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
        let snapshot = try BackupEngine.performBackup(request)
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
        _ = try BackupEngine.performBackup(makeBackupRequest(env: env, vault: vault, now: t1))
        _ = try BackupEngine.performBackup(makeBackupRequest(env: env, vault: vault, now: t2))
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
        let snapshot = try BackupEngine.performBackup(makeBackupRequest(env: env, vault: vault))
        #expect(VaultStore.verify(snapshot: snapshot).isEmpty)

        // 破坏一个归档 → 验证报大小与 SHA-256 问题
        let archive = snapshot.directoryURL
            .appendingPathComponent("container-com.tencent.xinWeChat.zip")
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
        let snapshot = try BackupEngine.performBackup(makeBackupRequest(env: env, vault: vault))
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
        let snapshot = try BackupEngine.performBackup(
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
            _ = try BackupEngine.performBackup(
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
            _ = try BackupEngine.performBackup(
                makeBackupRequest(env: env, vault: vault),
                isCancelled: { calls += 1; return calls > 2 })   // 第三个组件前取消
        }
        // 不留下任何 .inprogress 或完成快照
        #expect(VaultStore.listSnapshots(base: vault).isEmpty)
        let rootEntries = (try? FileManager.default.contentsOfDirectory(
            atPath: VaultStore.vaultRoot(base: vault).path)) ?? []
        #expect(rootEntries.isEmpty)
    }
}

// MARK: - RestoreEngine

@Test func makePlanRequiresCompleteSnapshot() throws {
    try withTempDir { root in
        let vault = root.appendingPathComponent("vault")
        let env = try makeFixtureHome(root.appendingPathComponent("home"))
        let snapshot = try BackupEngine.performBackup(makeBackupRequest(env: env, vault: vault))
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
        let snapshot = try BackupEngine.performBackup(makeBackupRequest(env: env, vault: vault))

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

        let snapshot = try BackupEngine.performBackup(makeBackupRequest(env: env, vault: vault))

        // 备份后数据被「破坏」：改写内容 + 加新文件
        try Data("已损坏".utf8).write(to: originalFile)
        try Data([1]).write(to: mainDir.appendingPathComponent("junk.bin"))

        let plan = try RestoreEngine.makePlan(
            snapshot: snapshot, environment: env, currentWeChatVersion: "4.0.6")
        let result = try RestoreEngine.performRestore(
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
        let snapshot = try BackupEngine.performBackup(makeBackupRequest(env: env, vault: vault))

        // 模拟换机/清空：删除主容器
        let mainDir = env.home.appendingPathComponent(
            "Library/Containers/com.tencent.xinWeChat", isDirectory: true)
        try FileManager.default.removeItem(at: mainDir)

        let plan = try RestoreEngine.makePlan(
            snapshot: snapshot, environment: env, currentWeChatVersion: "4.0.6")
        #expect(plan.items.first {
            $0.entry.id == "container-com.tencent.xinWeChat"
        }?.targetExists == false)

        let result = try RestoreEngine.performRestore(plan: plan, environment: env)
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
        let snapshot = try BackupEngine.performBackup(makeBackupRequest(env: env, vault: vault))
        let plan = try RestoreEngine.makePlan(
            snapshot: snapshot, environment: env, currentWeChatVersion: "4.0.6")

        // 篡改归档
        let archive = snapshot.directoryURL
            .appendingPathComponent("container-com.tencent.xinWeChat.zip")
        var data = try Data(contentsOf: archive)
        data[data.count - 1] ^= 0xff
        try data.write(to: archive)

        let mainDir = env.home.appendingPathComponent(
            "Library/Containers/com.tencent.xinWeChat", isDirectory: true)
        let before = FileStats.measure(at: mainDir)
        #expect(throws: BackupError.self) {
            _ = try RestoreEngine.performRestore(plan: plan, environment: env)
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
