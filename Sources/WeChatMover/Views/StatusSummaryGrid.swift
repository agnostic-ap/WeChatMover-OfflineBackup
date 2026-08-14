import SwiftUI

/// 三张摘要卡片（规范 5.3）：微信数据 / 目标磁盘 / 安全检查。
/// 窄窗口（<820pt 等效）时由 ViewThatFits 自动从三列退化为单列。
struct StatusSummaryGrid: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var showSafetyDetails = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.sm) { cards }
            VStack(spacing: DesignTokens.Spacing.sm) { cards }
        }

        if showSafetyDetails {
            safetyDetails
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var cards: some View {
        ForEach(vm.summaryCards) { card in
            if card.id == "safety" {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showSafetyDetails.toggle()
                    }
                } label: {
                    StatusCard(model: card)
                }
                .buttonStyle(.plain)
                .help("点击查看安全检查详情")
            } else {
                StatusCard(model: card)
            }
        }
    }

    /// 安全检查卡片点开的技术详情（规范 5.3）。
    private var safetyDetails: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            detailRow("微信来源", Copywriting.sourceName(isAppStoreVersion: vm.wechat.isAppStoreVersion))
            detailRow("微信版本", vm.wechat.version ?? "未安装")
            HStack {
                detailRow("应用签名", signatureText)
                if vm.wechat.signatureValid == nil && vm.wechat.isInstalled {
                    Button("检测") { vm.checkSignatureNow() }.controlSize(.small)
                }
                if vm.wechatVersionChanged || vm.wechat.signatureValid == false {
                    Button("重新签名微信") { vm.resignWeChat() }
                        .controlSize(.small)
                        .disabled(vm.isBusy || vm.isResigning)
                }
            }
            detailRow("目标磁盘格式", vm.targetFSType ?? "未选择")
            detailRow("内置盘剩余", vm.homeFreeSpace.map(DiskProbe.formatBytes) ?? "—")
            if !vm.safetyIssues.isEmpty {
                ForEach(vm.safetyIssues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Colors.warning)
                }
            }
        }
        .cardStyle()
    }

    private var signatureText: String {
        switch vm.wechat.signatureValid {
        case .some(true): return "应用签名有效"
        case .some(false): return "应用签名已失效"
        case .none: return "未检测"
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

/// 单张摘要卡片：左上标签、左下主值+副文案、右上 SF Symbol。
struct StatusCard: View {
    let model: StatusCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Text(model.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: model.symbol)
                    .font(.title2)
                    .foregroundStyle(DesignTokens.toneColor(model.tone))
            }
            Spacer(minLength: 0)
            Text(model.value)
                .font(.title3.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(model.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}
