import SwiftUI
import AppKit

/// 快照详情：清单元数据 + 逐归档明细（大小、文件数、SHA-256）。
struct SnapshotDetailSheet: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if let snapshot = vm.detailSnapshot, let manifest = snapshot.manifest {
                header(snapshot, manifest)
                entryList(manifest)
            } else {
                Text("无法读取快照清单").foregroundStyle(.secondary)
            }
            HStack {
                if let snapshot = vm.detailSnapshot {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([snapshot.directoryURL])
                    }
                }
                Spacer()
                Button("关闭") {
                    vm.activeSheet = nil
                    vm.detailSnapshot = nil
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 640)
    }

    @ViewBuilder
    private func header(_ snapshot: SnapshotInfo, _ manifest: BackupManifest) -> some View {
        Text("快照详情")
            .font(.title3.weight(.semibold))
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            metaRow("名称", snapshot.name)
            metaRow("创建时间", manifest.createdAt.formatted(date: .long, time: .standard))
            metaRow("完整性", snapshot.isComplete ? "完成标记有效" : "缺少/无效完成标记（不能用于恢复）")
            metaRow("微信版本", "\(manifest.wechatVersion ?? "未知")（build \(manifest.wechatBuild ?? "?")）")
            metaRow("macOS", manifest.macOSVersion)
            metaRow("清单格式", "v\(manifest.formatVersion)，工具 \(manifest.toolVersion)")
            metaRow("总大小", "逻辑 \(DiskProbe.formatBytes(manifest.totalLogicalSize)) / 归档 \(DiskProbe.formatBytes(manifest.totalArchiveSize))")
        }
        .font(.callout)
    }

    private func entryList(_ manifest: BackupManifest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                ForEach(manifest.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.displayName)
                            .font(.callout.weight(.medium))
                        Text("\(entry.archiveName) · \(entry.fileCount) 个文件 · 逻辑 \(DiskProbe.formatBytes(entry.logicalSize)) · 归档 \(DiskProbe.formatBytes(entry.archiveSize))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("SHA-256: \(entry.sha256)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 260)
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.Colors.surfaceSubtle,
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    private func metaRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
