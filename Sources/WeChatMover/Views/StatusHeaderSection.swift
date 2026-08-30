import SwiftUI

/// 状态卡片行：微信状态 + 备份位置状态。
struct StatusHeaderSection: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            wechatCard
            vaultCard
        }
    }

    private var wechatCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Label("微信", systemImage: "message.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.Colors.accent)
            if vm.wechat.isInstalled {
                Text("版本 \(vm.wechat.version ?? "未知")（build \(vm.wechat.build ?? "?")）")
                    .font(.callout)
                Text(vm.wechat.isRunning ? "正在运行（备份/恢复前会自动退出）" : "未运行")
                    .font(.caption)
                    .foregroundStyle(vm.wechat.isRunning ? DesignTokens.Colors.warning : .secondary)
            } else {
                Text("未安装")
                    .font(.callout)
                Text("仍可备份本机残留的微信数据；恢复前建议先安装同版本微信。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var vaultCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Label("备份位置", systemImage: "externaldrive.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.Colors.accent)
            if let base = vm.vaultBase {
                Text(base.path)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if vm.vaultReachable {
                    Text("卷「\(vm.vaultVolumeName ?? "未知")」· \(fsTypeLabel) · 剩余 \(vm.vaultFreeSpace.map(DiskProbe.formatBytes) ?? "未知")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("当前不可访问（硬盘未连接？）。备份的数据不受影响，插回硬盘即可查看。")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Colors.warning)
                }
            } else {
                Text("尚未选择")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("选择备份位置…") { vm.chooseVaultBase() }
                .controlSize(.small)
                .disabled(vm.isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// exFAT 等格式友好提示：归档为 tar 单文件，任何格式都安全。
    private var fsTypeLabel: String {
        guard let fs = vm.vaultFSType else { return "格式未知" }
        if fs.lowercased() == "exfat" {
            return "exFAT（兼容，备份以 tar 归档存放，安全）"
        }
        return fs
    }
}
