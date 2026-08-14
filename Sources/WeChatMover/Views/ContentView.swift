import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("WeChatMover · 微信数据外置硬盘迁移工具")
                .font(.title2).bold()

            // App Store 版拦截
            if !vm.isLoading && vm.wechat.isInstalled && vm.wechat.isAppStoreVersion {
                masBanner
            }

            if !vm.isLoading && !vm.wechat.isInstalled {
                Label("未在 /Applications 检测到微信。", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }

            StatusCardView()

            targetSection

            actionButtons

            GroupBox("日志") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vm.logs.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(4)
                }
                .frame(minHeight: 90)
            }
        }
        .padding(18)
        .sheet(isPresented: $vm.showMigrateSheet) { MigrateFlowView().environmentObject(vm) }
        .sheet(isPresented: $vm.showGuide) { GuideView() }
        .sheet(isPresented: $vm.showAppManagementGuide) { AppManagementGuideView().environmentObject(vm) }
        .alert("目标卷不是 APFS", isPresented: $vm.showNonAPFSAlert) {
            Button("我知道了（仍要使用）", role: .cancel) {}
            Button("重新选择") { vm.chooseTarget() }
        } message: {
            Text("所选卷格式为 \(vm.targetFSType ?? "未知")。exFAT/NTFS 等格式不支持符号链接与稀疏文件，会导致空间膨胀甚至迁移失败。强烈建议改用 APFS 格式的磁盘。")
        }
        .alert("删除本地备份", isPresented: $vm.showBackupConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { vm.deleteAllBackups() }
        } message: {
            Text("将删除 \(vm.backupItems.count) 个备份目录（*_backup），释放约 \(DiskProbe.formatBytes(vm.totalBackupSize))。已逐项确认软链有效后才会删除，但删除后不可恢复。")
        }
        .alert("微信正在运行", isPresented: $vm.showQuitWeChatConfirm) {
            Button("退出微信并继续") { vm.quitWeChatAndContinue() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("需要先退出微信才能迁移。将优先优雅退出，几秒后仍未退出会强制结束；聊天记录不受影响。")
        }
        .alert("目标位置已有数据", isPresented: $vm.showExistingTargetConfirm) {
            Button("删除旧数据并重新迁移", role: .destructive) { vm.removeConflictingTargetAndMigrate() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(vm.conflictingTargetPath ?? "") 已存在数据，可能来自上次迁移中断或重复迁移。删除后不可恢复，确认删除并重新迁移？")
        }
        .alert("清理外置数据", isPresented: $vm.showCleanExternalConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { vm.cleanExternalData() }
        } message: {
            Text("将删除外置硬盘上的 \(vm.externalDataURL?.path ?? "")（约 \(DiskProbe.formatBytes(vm.externalDataSize ?? 0))）。删除后不可恢复；本机数据不受影响。")
        }
        .alert("提示", isPresented: noticePresented) {
            Button("好") { vm.notice = nil }
        } message: {
            Text(vm.notice ?? "")
        }
        .alert("操作失败", isPresented: errorPresented) {
            Button("好") { vm.lastError = nil }
        } message: {
            Text(vm.lastError ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { vm.lastError != nil }, set: { if !$0 { vm.lastError = nil } })
    }

    private var noticePresented: Binding<Bool> {
        Binding(get: { vm.notice != nil }, set: { if !$0 { vm.notice = nil } })
    }

    private var masBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("当前为 App Store 版微信，不支持此方案", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("App Store 版受沙盒限制，软链会失效。请从微信官网下载 DMG 版覆盖安装后重试。迁移功能已禁用。")
                .font(.callout)
            Button("打开微信官网下载页") {
                NSWorkspace.shared.open(WeChatDetector.officialDownloadURL)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var targetSection: some View {
        GroupBox("目标位置（外置硬盘）") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let base = vm.targetBase {
                        Text(base.path).font(.callout).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("尚未选择").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("选择文件夹…") { vm.chooseTarget() }
                }
                if vm.targetBase != nil && !vm.isTargetAPFS {
                    Label("该卷不是 APFS，建议更换磁盘或格式化为 APFS。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button("一键迁移…") { vm.requestMigration() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canMigrate)

                Button("一键还原") { vm.startRestore() }
                    .disabled(!vm.canRestore)

                if !vm.backupItems.isEmpty {
                    Button("删除备份…") { vm.showBackupConfirm = true }
                        .disabled(!vm.canDeleteBackups)
                }

                if vm.hasExternalData {
                    Button("清理外置数据…") { vm.requestCleanExternalData() }
                        .disabled(!vm.canCleanExternalData)
                }

                if vm.wechatVersionChanged || vm.wechat.signatureValid == false {
                    Button("重新签名微信") { vm.resignWeChat() }
                        .disabled(vm.isBusy || vm.isResigning)
                }

                Button("权限指引") { vm.showGuide = true }

                Spacer()

                Button("刷新") { vm.refresh() }
            }
            .controlSize(.large)

            if vm.isQuittingWeChat {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在退出微信…").foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            if vm.isResigning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在重签名微信…（首次需「App 管理」授权）")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}
