import SwiftUI

/// 仪表盘根视图：PageHeader → ReadinessBanner → 摘要卡片 → 目标选择器
/// → 单一主操作区 → 可折叠日志。View 只消费展示模型。
struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                pageHeader
                ReadinessBanner(model: vm.banner)
                StatusSummaryGrid()
                DestinationPickerRow()
                ActionSection()
                ManageSection()
                LogDisclosureGroup()
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.Colors.background)
        .toolbar { toolbarItems }
        .alert(item: alertOnlyDialog, content: dialog)
        // 三选项弹窗用 confirmationDialog（Alert 只支持两个按钮），
        // 仍由 ActiveDialog 单一枚举驱动，这里只是按呈现方式拆绑定。
        .confirmationDialog(
            "外置数据与内置备份一致",
            isPresented: restoreSameChoicePresented,
            titleVisibility: .visible
        ) {
            Button("使用内置备份（更快）") { vm.confirmRestoreBackups() }
            Button("仍从外置硬盘拷贝") { vm.confirmRestoreFromExternal() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("两侧数据内容一致。使用内置备份无需拷贝、速度更快，外置硬盘上的数据保留不动。")
        }
        .confirmationDialog(
            "外置数据比内置备份新",
            isPresented: restoreNewerChoicePresented,
            titleVisibility: .visible
        ) {
            Button("改用外置数据还原（推荐）") { vm.confirmRestoreFromExternal() }
            Button("仍使用内置备份（将丢失外置盘上的新数据）", role: .destructive) { vm.confirmRestoreBackups() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("外置硬盘上的数据比内置备份新（通常是迁移后有新聊天记录写入外置盘），建议优先还原外置数据。")
        }
        .sheet(item: $vm.activeSheet, content: sheet)
    }

    /// .alert 绑定：三选项弹窗走 confirmationDialog，这里过滤掉避免双弹。
    private var alertOnlyDialog: Binding<ActiveDialog?> {
        Binding(
            get: {
                switch vm.activeDialog {
                case .restoreSameChoice, .restoreNewerChoice: return nil
                default: return vm.activeDialog
                }
            },
            set: { vm.activeDialog = $0 }
        )
    }

    private var restoreSameChoicePresented: Binding<Bool> {
        Binding(
            get: { vm.activeDialog == .restoreSameChoice },
            set: { if !$0 { vm.activeDialog = nil } }
        )
    }

    private var restoreNewerChoicePresented: Binding<Bool> {
        Binding(
            get: { vm.activeDialog == .restoreNewerChoice },
            set: { if !$0 { vm.activeDialog = nil } }
        )
    }

    /// 规范 5.1：标题 + 副标题，不重复完整产品名。
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("微信数据迁移")
                .font(.title2.weight(.semibold))
            Text("将微信数据安全迁移到外置硬盘，释放 Mac 空间。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Toolbar 右侧：刷新（图标 + Tooltip）、帮助。
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { vm.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新")
            .accessibilityLabel("刷新")

            Menu {
                Button("权限重新授权指南") { vm.activeSheet = .guide }
                Button("App 管理授权指南") {
                    vm.resignGuideReason = .appManagementDenied
                    vm.activeSheet = .appManagementGuide
                }
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .help("帮助")
            .accessibilityLabel("帮助")
        }
    }

    @ViewBuilder
    private func sheet(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .guide:
            GuideView()
        case .appManagementGuide:
            AppManagementGuideView().environmentObject(vm)
        }
    }

    /// 所有确认/提示弹窗由 ActiveDialog 单一枚举驱动。
    private func dialog(_ dialog: ActiveDialog) -> Alert {
        switch dialog {
        case .migrateConfirm:
            return Alert(
                title: Text("迁移微信数据到“\(vm.destinationName)”？"),
                message: Text(vm.migrateConfirmMessage),
                primaryButton: .default(Text("退出微信并开始迁移")) { vm.confirmMigration() },
                secondaryButton: .cancel())
        case .restoreConfirm:
            return Alert(
                title: Text("还原外置存储数据到 Mac？"),
                message: Text((vm.restoreNote.map { $0 + "\n\n" } ?? "")
                    + "来源：外置硬盘上的 WeChatData → 目标：Mac 内置盘原位置。如微信正在运行，将先自动退出。"),
                primaryButton: .destructive(Text("确认还原")) { vm.confirmRestore() },
                secondaryButton: .cancel())
        case .restoreSameChoice, .restoreNewerChoice:
            // 由 confirmationDialog 呈现（Alert 不支持三个按钮），不会走到这里
            return Alert(title: Text("还原方式选择"))
        case .backupRestoreConfirm:
            return Alert(
                title: Text("还原内置存储数据到 Mac？"),
                message: Text("来源：Mac 内置盘上的本地备份（_backup）→ 目标：Mac 内置盘原位置。将删除符号链接、把备份改回原名：放弃迁移，回到 Mac 上的旧数据。全程不访问外置硬盘（不插盘也能用），外置数据保留不动，可之后用「清理外置数据…」删除。如需保留外置盘上的最新数据，请改用「还原外置存储数据到 Mac…」。如微信正在运行，将先自动退出。"),
                primaryButton: .destructive(Text("确认还原")) { vm.confirmRestoreBackups() },
                secondaryButton: .cancel())
        case .backupConfirm:
            return Alert(
                title: Text("清理本地备份？"),
                message: Text("将删除 \(vm.backupItems.count) 个备份目录，释放约 \(DiskProbe.formatBytes(vm.totalBackupSize))。已逐项确认软链有效后才会删除，但删除后不可恢复。"),
                primaryButton: .destructive(Text("删除")) { vm.deleteAllBackups() },
                secondaryButton: .cancel())
        case .existingTarget:
            return Alert(
                title: Text("目标位置已有数据"),
                message: Text("\(vm.conflictingTargetPath ?? "") 已存在数据，可能来自上次迁移中断或重复迁移。删除后不可恢复，确认删除并重新迁移？"),
                primaryButton: .destructive(Text("删除旧数据并重新迁移")) { vm.removeConflictingTargetAndMigrate() },
                secondaryButton: .cancel())
        case .cleanExternal:
            return Alert(
                title: Text("清理外置数据？"),
                message: Text("将删除外置硬盘上的 \(vm.externalDataURL?.path ?? "")（约 \(DiskProbe.formatBytes(vm.externalDataSize ?? 0))）。删除后不可恢复；本机数据不受影响。"),
                primaryButton: .destructive(Text("删除")) { vm.cleanExternalData() },
                secondaryButton: .cancel())
        case .overwriteConfirm:
            return Alert(
                title: Text("用外置数据覆盖内置？"),
                message: Text("将用外置硬盘上的数据覆盖 Mac 内置盘上的现有数据。覆盖前会先把当前内置数据备份为 _backup（安全网，可事后用「还原内置存储数据到 Mac…」恢复，或确认无误后用「清理备份…」释放空间）；外置硬盘上的数据保留不动。如微信正在运行，将先自动退出。"),
                primaryButton: .destructive(Text("确认覆盖")) { vm.confirmOverwriteWithExternal() },
                secondaryButton: .cancel())
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
