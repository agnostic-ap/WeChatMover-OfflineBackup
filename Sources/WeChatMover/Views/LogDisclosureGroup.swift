import SwiftUI

/// 详细信息与日志（规范 5.7）：默认折叠，折叠时显示最后一条摘要；
/// 展开后可滚动，工具栏提供复制/导出/清空。级别用 SF Symbol + 色调区分。
struct LogDisclosureGroup: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button("复制日志") { vm.copyLogs() }
                    Button("导出…") { vm.exportLogs() }
                    Button("清空显示") { vm.clearLogs() }
                    Spacer()
                }
                .controlSize(.small)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(vm.logs.enumerated()), id: \.offset) { index, line in
                                LogLineView(model: LogPresentation.parse(line))
                                    .id(index)
                            }
                        }
                        .padding(DesignTokens.Spacing.xs)
                    }
                    .frame(minHeight: 180, maxHeight: 240)
                    .background(
                        DesignTokens.Colors.surfaceSubtle,
                        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                    )
                    .onChange(of: vm.logs.count) { _ in
                        if let last = vm.logs.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.top, DesignTokens.Spacing.xs)
        } label: {
            HStack {
                Text("详细信息与日志")
                    .font(.headline)
                if !expanded, let last = vm.logs.last {
                    Spacer()
                    Text(LogPresentation.parse(last).text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

private struct LogLineView: View {
    let model: LogLineModel

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: model.symbol)
                .foregroundStyle(DesignTokens.toneColor(model.tone))
                .frame(width: 14)
            Text(model.text)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
    }
}
