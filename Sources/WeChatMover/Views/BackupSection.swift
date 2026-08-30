import SwiftUI

/// 备份区：将要备份的组件清单 + 可选归档微信本体 + 开始备份。
struct BackupSection: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("备份")
                .font(.headline)

            if vm.needsFullDiskAccess {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                        .foregroundStyle(DesignTokens.Colors.warning)
                    Text("缺少「完全磁盘访问」权限，无法读取微信数据。授权后请重启本工具。")
                        .font(.caption)
                    Button("去授权…") { PermissionHelper.openFullDiskAccess() }
                        .controlSize(.small)
                }
            }

            if vm.components.isEmpty {
                Text("未发现微信数据目录。请确认本机用当前系统用户登录过微信。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    ForEach(vm.components) { component in
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(DesignTokens.Colors.accent)
                                .frame(width: 16)
                            Text(component.displayName)
                                .font(.callout)
                            Spacer()
                            Text(vm.componentSizes[component.id].map(DiskProbe.formatBytes) ?? "统计中…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                Toggle(isOn: $vm.includeAppArchive) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("同时归档微信应用本体（WeChat.app）")
                            .font(.callout)
                        Text("保留当前版本安装包，日后可手动装回同版本；恢复时不会自动覆盖「应用程序」。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!vm.wechat.isInstalled || vm.isBusy)

                HStack {
                    Button {
                        vm.requestBackup()
                    } label: {
                        Label("开始备份…", systemImage: "arrow.down.doc.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.Colors.accent)
                    .disabled(vm.isBusy || !vm.vaultReachable || vm.components.isEmpty
                              || vm.needsFullDiskAccess)

                    if !vm.vaultReachable {
                        Text("请先选择可访问的备份位置")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let est = vm.estimatedBackupSize {
                        Text("预计 \(DiskProbe.formatBytes(est))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
