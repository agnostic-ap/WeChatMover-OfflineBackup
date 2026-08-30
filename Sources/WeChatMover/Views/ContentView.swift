import SwiftUI
import AppKit

/// 根视图：页头 → 提醒 → 状态卡片 → 备份区 → 快照列表 → 日志；底部 GitHub 链接。
/// View 只消费 AppViewModel 的展示状态。
struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    pageHeader
                    riskNotice
                    if let busy = vm.busy {
                        busyBanner(busy)
                    }
                    StatusHeaderSection()
                    BackupSection()
                    SnapshotListSection()
                    LogDisclosureGroup()
                }
                .padding(DesignTokens.Spacing.xl)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            githubFooter
        }
        .background(DesignTokens.Colors.background)
        .toolbar { toolbarItems }
        .alert(item: $vm.activeDialog, content: dialog)
        .sheet(item: $vm.activeSheet, content: sheet)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("微信离线备份")
                .font(.title2.weight(.semibold))
            Text("把微信聊天记录与文件完整打包到移动硬盘，随时可验证、可恢复。备份完成后硬盘即可拔下。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// 固定风险提示：不吓人，但把关键前提讲清楚。
    private var riskNotice: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(DesignTokens.Colors.info)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("使用须知")
                    .font(.subheadline.weight(.semibold))
                Text("备份与恢复前会自动完全退出微信。恢复到同一台 Mac、同一系统用户、同版本微信最可靠；换 Mac 恢复属实验性质。本工具不能替代官方「聊天记录备份与迁移」，建议两者并存。恢复时原数据只改名保留、绝不删除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func busyBanner(_ busy: BusyKind) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(busy.title)
                    .font(.subheadline.weight(.medium))
            }
            if let progress = vm.progress {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var githubFooter: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "https://github.com/agnostic-ap/WeChatMover-OfflineBackup")!)
        } label: {
            HStack(spacing: 6) {
                if let mark = Self.githubMark {
                    Image(nsImage: mark)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text("github.com/agnostic-ap/WeChatMover-OfflineBackup")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("在 GitHub 上查看源码与使用指南")
    }

    private static let githubMark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "GitHub-Mark", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }()

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { vm.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新")
            .accessibilityLabel("刷新")
            .disabled(vm.isBusy)
        }
    }

    @ViewBuilder
    private func sheet(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .restorePlan:
            RestorePlanSheet().environmentObject(vm)
        case .snapshotDetail:
            SnapshotDetailSheet().environmentObject(vm)
        }
    }

    private func dialog(_ dialog: ActiveDialog) -> Alert {
        switch dialog {
        case .backupConfirm:
            let est = vm.estimatedBackupSize.map { "约 \(DiskProbe.formatBytes($0))" } ?? "统计中"
            return Alert(
                title: Text("开始备份微信数据？"),
                message: Text("将备份 \(vm.components.count) 个数据目录（\(est)）到：\n\(vm.vaultBase?.path ?? "")\n\n如微信正在运行会先自动退出。备份期间请勿打开微信、勿拔硬盘；完成后硬盘可随时拔下。备份只读取微信数据，不做任何修改。"),
                primaryButton: .default(Text("退出微信并开始备份")) { vm.confirmBackup() },
                secondaryButton: .cancel())
        case .restoreFinalConfirm:
            let name = vm.restorePlan?.snapshot.name ?? ""
            return Alert(
                title: Text("确认恢复快照？"),
                message: Text("将按刚才的计划把快照「\(name)」恢复到本机。现有微信数据会改名保留为回滚副本（不会删除），失败时自动回滚。如微信正在运行会先自动退出。"),
                primaryButton: .destructive(Text("开始恢复")) { vm.confirmRestoreFinal() },
                secondaryButton: .cancel { vm.cancelRestorePlan() })
        case .deleteSnapshotConfirm:
            let s = vm.pendingDeleteSnapshot
            return Alert(
                title: Text("删除快照「\(s?.name ?? "")」？"),
                message: Text("将从备份盘删除该快照（约 \(DiskProbe.formatBytes(s?.totalArchiveSize ?? 0))）。删除后不可恢复；本机微信数据不受影响。"),
                primaryButton: .destructive(Text("删除")) { vm.confirmDeleteSnapshot() },
                secondaryButton: .cancel { vm.pendingDeleteSnapshot = nil })
        case .error:
            return Alert(
                title: Text("操作失败"),
                message: Text(vm.lastError ?? ""),
                dismissButton: .default(Text("好")) { vm.lastError = nil })
        case .notice:
            return Alert(
                title: Text("提示"),
                message: Text(vm.notice ?? ""),
                dismissButton: .default(Text("好")) { vm.notice = nil })
        }
    }
}
