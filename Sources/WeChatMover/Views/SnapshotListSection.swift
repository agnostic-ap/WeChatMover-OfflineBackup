import SwiftUI

/// 快照列表：每行显示时间、大小、微信版本与完整性徽标，附详情/验证/恢复/删除操作。
struct SnapshotListSection: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Text("已有快照")
                    .font(.headline)
                Spacer()
                if !vm.snapshots.isEmpty {
                    Text("\(vm.snapshots.count) 个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !vm.vaultReachable {
                Text("备份位置不可访问；连接硬盘并刷新后显示快照。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if vm.snapshots.isEmpty {
                Text("还没有快照。完成一次备份后会出现在这里。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(vm.snapshots) { snapshot in
                        SnapshotRow(snapshot: snapshot)
                        if snapshot.id != vm.snapshots.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct SnapshotRow: View {
    @EnvironmentObject var vm: AppViewModel
    let snapshot: SnapshotInfo

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: snapshot.isComplete ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(snapshot.isComplete ? DesignTokens.Colors.accent : DesignTokens.Colors.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.name)
                    .font(.callout.weight(.medium))
                HStack(spacing: DesignTokens.Spacing.xs) {
                    if let created = snapshot.createdAt {
                        Text(created.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let m = snapshot.manifest {
                        Text("微信 \(m.wechatVersion ?? "未知")")
                        Text(DiskProbe.formatBytes(m.totalArchiveSize))
                    }
                    if !snapshot.isComplete {
                        Text("未完成/损坏")
                            .foregroundStyle(DesignTokens.Colors.warning)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("详情") { vm.showDetail(snapshot) }
                    .disabled(snapshot.manifest == nil)
                Button("验证") { vm.verifySnapshot(snapshot) }
                    .disabled(snapshot.manifest == nil)
                Button("恢复…") { vm.requestRestore(snapshot) }
                    .disabled(!snapshot.isComplete)
                Button("删除…", role: .destructive) { vm.requestDeleteSnapshot(snapshot) }
            }
            .controlSize(.small)
            .disabled(vm.isBusy)
        }
        .padding(.vertical, 2)
    }
}
