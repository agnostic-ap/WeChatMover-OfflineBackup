import SwiftUI

/// 迁移后「重新授权截图/麦克风」图文指引。
struct GuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("迁移完成，还需两步").font(.headline)

            Text("由于数据位置变化并重签名，macOS 会重置微信的部分权限。首次使用以下功能时，请重新授权：")
                .font(.callout)

            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Label("屏幕录制（截图/视频通话共享屏幕）", systemImage: "rectangle.dashed.badge.record")
                    Label("麦克风（语音/视频通话）", systemImage: "mic")
                }
                .font(.callout)
                Spacer()
                VStack(spacing: 6) {
                    Button("打开设置") { PermissionHelper.openScreenRecording() }
                    Button("打开设置") { PermissionHelper.openMicrophone() }
                }
            }

            Text("提示：授权后若微信未立即生效，请彻底退出微信再重新打开。外置盘未连接时请不要启动微信。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("知道了") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
