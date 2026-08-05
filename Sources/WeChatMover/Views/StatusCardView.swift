import SwiftUI

/// 状态面板：数据位置/大小/磁盘余量/版本/签名状态。
struct StatusCardView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        GroupBox("状态面板") {
            VStack(alignment: .leading, spacing: 8) {
                row("当前模式", vm.modeDescription)
                row("数据总大小", DiskProbe.formatBytes(vm.totalDataSize))
                row("内置盘剩余", DiskProbe.formatBytes(DiskProbe.freeSpace(path: NSHomeDirectory()) ?? 0))
                row("微信版本", vm.wechat.version ?? "未安装")
                row("签名状态", signatureText)
                if let fs = vm.targetFSType {
                    row("目标卷格式", fs + (vm.isTargetAPFS ? " ✅" : " ⚠️ 非 APFS"))
                    row("目标卷剩余", DiskProbe.formatBytes(vm.targetFreeSpace ?? 0))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }

        if !vm.containerReadable {
            warningBox(
                "无法读取微信数据目录。请为本 App 授予「完全磁盘访问权限」后重启本 App。",
                buttonTitle: "打开完全磁盘访问设置",
                action: { PermissionHelper.openFullDiskAccess() }
            )
        }

        if !vm.brokenItems.isEmpty {
            warningBox("检测到外置盘未连接：软链目标不可达。请先连接硬盘再打开微信，否则微信会新建空数据目录。")
        }
    }

    private var signatureText: String {
        switch vm.wechat.signatureValid {
        case .some(true): return "有效 ✅"
        case .some(false): return "已失效 ⚠️"
        case .none: return "—"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.callout)
    }

    private func warningBox(_ text: String, buttonTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
