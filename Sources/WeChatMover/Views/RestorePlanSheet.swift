import SwiftUI

/// 恢复计划（第一重确认）：默认只展示，不做任何写入。
/// 版本不一致时必须勾选知情确认才能继续；继续后还有最终 destructive 确认。
struct RestorePlanSheet: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("恢复计划")
                .font(.title3.weight(.semibold))

            if let plan = vm.restorePlan {
                planBody(plan)
            } else {
                Text("计划不可用").foregroundStyle(.secondary)
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 620)
    }

    @ViewBuilder
    private func planBody(_ plan: RestorePlan) -> some View {
        Text("快照：\(plan.snapshot.name)（微信 \(plan.backupWeChatVersion ?? "未知")）")
            .font(.callout)

        // 逐项计划
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                ForEach(plan.items) { item in
                    HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .foregroundStyle(DesignTokens.Colors.info)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.entry.displayName)
                                .font(.callout)
                            Text("→ ~/\(item.entry.relativePath)（\(DiskProbe.formatBytes(item.entry.logicalSize))，\(item.entry.fileCount) 个文件）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if item.targetExists {
                                Text("现有数据将改名保留为回滚副本（不删除）")
                                    .font(.caption)
                                    .foregroundStyle(DesignTokens.Colors.warning)
                            }
                        }
                    }
                }
                if plan.appEntry != nil {
                    HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "app.dashed")
                            .frame(width: 16)
                        Text("快照含 WeChat.app 归档：不会自动安装，可在快照目录手动解压使用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.Colors.surfaceSubtle,
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.control))

        // 执行前检查摘要
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            checkRow("恢复前逐个校验 ZIP 路径安全与 SHA-256", ok: true)
            checkRow("需要空间约 \(DiskProbe.formatBytes(plan.totalLogicalSize))，本机剩余 \(plan.freeSpaceOnHome.map(DiskProbe.formatBytes) ?? "未知")",
                     ok: (plan.freeSpaceOnHome ?? 0) > plan.totalLogicalSize)
            checkRow("当前微信版本 \(plan.currentWeChatVersion ?? "未安装") / 快照版本 \(plan.backupWeChatVersion ?? "未知")",
                     ok: !plan.versionMismatch)
        }
        .font(.caption)

        ForEach(plan.warnings, id: \.self) { warning in
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.Colors.warning)
                Text(warning)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if plan.versionMismatch {
            Toggle("我已了解版本不一致的风险，仍要继续", isOn: $vm.mismatchAcknowledged)
                .toggleStyle(.checkbox)
                .font(.callout)
        }

        HStack {
            Spacer()
            Button("取消") { vm.cancelRestorePlan() }
                .keyboardShortcut(.cancelAction)
            Button("继续，进入最终确认…") { vm.proceedFromPlan() }
                .buttonStyle(.borderedProminent)
                .disabled(plan.versionMismatch && !vm.mismatchAcknowledged)
        }
    }

    private func checkRow(_ text: String, ok: Bool) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? DesignTokens.Colors.accent : DesignTokens.Colors.warning)
            Text(text)
        }
    }
}
