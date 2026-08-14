import SwiftUI

/// 操作区（规范 5.5/5.6）：迁移中是进度面板；平时是单一主按钮 + 次按钮。
struct ActionSection: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        if vm.busyKind == .migrating {
            progressPanel
        } else {
            actionRow
        }
    }

    /// 迁移进度面板：真实字节进度，不靠日志。
    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("正在复制微信数据")
                .font(.headline)
            HStack {
                ProgressView(value: vm.progress)
                Text("\(Int((vm.progress * 100).rounded()))%")
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityValue("\(Int((vm.progress * 100).rounded()))%")
            Text("迁移期间请不要退出微信或拔出硬盘")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var actionRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // 已外置（无待迁移）时隐藏主按钮
            if !vm.localItems.isEmpty {
                Button(vm.primaryActionTitle) { vm.requestMigration() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.Colors.accent)
                    .controlSize(.large)
                    .frame(minHeight: 40)
                    .disabled(!vm.canMigrate)
                    .keyboardShortcut(.defaultAction)
            }

            if !vm.migratedItems.isEmpty {
                Button("还原到 Mac…") { vm.activeDialog = .restoreConfirm }
                    .controlSize(.large)
                    .disabled(!vm.canRestore)
            }
        }
    }
}

/// 管理行：恢复内置备份 / 本地备份 / 外置数据清理入口（均二次确认）。
struct ManageSection: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        if !vm.restorableBackupItems.isEmpty || !vm.backupItems.isEmpty || vm.hasExternalData {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                if !vm.restorableBackupItems.isEmpty {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .foregroundStyle(.secondary)
                        Text("内置备份可恢复（放弃迁移，回到 Mac 上的旧数据）")
                            .font(.callout)
                        Spacer()
                        Button("恢复内置备份…") { vm.activeDialog = .backupRestoreConfirm }
                            .controlSize(.small)
                            .disabled(!vm.canRestoreBackups)
                    }
                }
                if !vm.backupItems.isEmpty {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(.secondary)
                        Text("本地备份占用 \(DiskProbe.formatBytes(vm.totalBackupSize))")
                            .font(.callout)
                            .monospacedDigit()
                        Spacer()
                        Button("清理备份…") { vm.activeDialog = .backupConfirm }
                            .controlSize(.small)
                            .disabled(!vm.canDeleteBackups)
                    }
                }
                if vm.hasExternalData {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "externaldrive")
                            .foregroundStyle(.secondary)
                        Text("外置数据占用 \(vm.externalDataSize.map(DiskProbe.formatBytes) ?? "统计中…")"
                             + (vm.canCleanExternalData || vm.isBusy ? "" : " · 还原到 Mac 后可清理"))
                            .font(.callout)
                            .monospacedDigit()
                        Spacer()
                        Button("清理外置数据…") { vm.requestCleanExternalData() }
                            .controlSize(.small)
                            .disabled(!vm.canCleanExternalData)
                            .help(vm.canCleanExternalData
                                  ? "删除外置硬盘上的 WeChatData"
                                  : "还原到 Mac 后可清理")
                    }
                }
            }
            .cardStyle()
        }
    }
}
