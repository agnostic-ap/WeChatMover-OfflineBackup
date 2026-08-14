import SwiftUI
import AppKit

/// 「App 管理」权限指引：重签名被 TCC 拒绝（Operation not permitted）时弹出。
/// macOS Ventura+ 修改其他 App 的包（含 codesign 重签名）需要该权限，
/// osascript 提权到 root 也绕不过，必须引导用户去系统设置授权。
struct AppManagementGuideView: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("需要「App 管理」权限").font(.headline)

            Text("macOS 要求显式允许 WeChatMover 修改其他 App，否则重签名会被系统拒绝（Operation not permitted），输入管理员密码也无法绕过。授权只需一次：")
                .font(.callout)

            VStack(alignment: .leading, spacing: 6) {
                Text("1. 点击下方按钮，打开 系统设置 → 隐私与安全性 → App 管理")
                Text("2. 打开 WeChatMover 的开关（列表中没有就点「+」添加）")
                Text("3. 回到这里点「重试重签名」")
            }
            .font(.callout)

            Button("打开「App 管理」设置") { PermissionHelper.openAppManagement() }
                .buttonStyle(.borderedProminent)

            Divider()

            Text("兜底方案：在「终端」App 里执行以下命令（终端通常已有该权限，一般能成功）：")
                .font(.callout)
            Text(CodeSigner.terminalCommand)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            Button(copied ? "已复制 ✅" : "复制命令") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(CodeSigner.terminalCommand, forType: .string)
                copied = true
            }

            HStack {
                Button("以后再说") { dismiss() }
                Spacer()
                Button("重试重签名") {
                    dismiss()
                    vm.resignWeChat()
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isResigning)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
