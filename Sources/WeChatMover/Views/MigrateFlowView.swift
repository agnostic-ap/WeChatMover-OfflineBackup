import SwiftUI

/// 迁移确认页：前置检查清单 + 进度。
struct MigrateFlowView: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("迁移前检查").font(.headline)

            checkRow("微信已退出", !vm.wechat.isRunning)
            checkRow("官网 DMG 版（非 App Store 版）", !vm.wechat.isAppStoreVersion)
            checkRow("存在待迁移数据目录", !vm.localItems.isEmpty)
            checkRow("目标卷为 APFS", vm.isTargetAPFS)
            checkRow("目标卷空间充足", spaceEnough)

            if !vm.localItems.isEmpty {
                Text("将迁移：\(vm.localItems.map(\.displayName).joined(separator: "、"))（共 \(DiskProbe.formatBytes(vm.totalLocalSize))）")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if vm.isBusy {
                ProgressView(value: vm.progress) { Text("正在迁移…") }
            }

            HStack {
                Button("取消") { dismiss() }.disabled(vm.isBusy)
                Spacer()
                Button("开始迁移") {
                    vm.startMigration()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canMigrate || vm.isBusy)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: vm.isBusy) { busy in
            if !busy && vm.lastError == nil { dismiss() }
        }
    }

    private var spaceEnough: Bool {
        guard let free = vm.targetFreeSpace else { return false }
        return free >= vm.totalLocalSize
    }

    private func checkRow(_ title: String, _ ok: Bool) -> some View {
        Label(title, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(ok ? .green : .red)
            .font(.callout)
    }
}
