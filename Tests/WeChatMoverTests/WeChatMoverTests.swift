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

        // 迁移
        try Migrator.migrateItem(source: source, target: target)
        #expect(DiskProbe.isSymlink(source))
        #expect(itemState(at: source) == .migrated)
        #expect(DiskProbe.directorySize(at: target) == 1536)
        // 通过软链能读到原文件
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("file0.bin").path))

        // 重复迁移应被拒绝
        #expect(throws: MigrationError.self) {
            try Migrator.migrateItem(source: source, target: root.appendingPathComponent("other"))
        }

        // 还原
        try Migrator.restoreItem(source: source, target: target)
        #expect(!DiskProbe.isSymlink(source))
        #expect(itemState(at: source) == .local)
        #expect(DiskProbe.directorySize(at: source) == 1536)
        #expect(!FileManager.default.fileExists(atPath: target.path))
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
