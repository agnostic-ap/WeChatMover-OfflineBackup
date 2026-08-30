import Foundation

// MARK: - 展示层模型（View 只消费这些，不解析业务状态）

/// 状态色调。
enum StatusTone: Equatable {
    case neutral, info, success, warning, danger
}

/// 进行中的操作种类（驱动横幅/进度面板文案）。
enum BusyKind: Equatable {
    case quittingWeChat
    case backingUp
    case planningRestore
    case restoring
    case verifying
    case deletingSnapshot

    var title: String {
        switch self {
        case .quittingWeChat: return "正在退出微信…"
        case .backingUp: return "正在备份（期间请勿打开微信、勿拔硬盘）…"
        case .planningRestore: return "正在生成恢复计划…"
        case .restoring: return "正在恢复（期间请勿打开微信）…"
        case .verifying: return "正在验证快照…"
        case .deletingSnapshot: return "正在删除快照…"
        }
    }
}

// MARK: - 弹窗状态（单一枚举驱动，避免同时弹出多个对话框）

enum ActiveDialog: String, Identifiable {
    case backupConfirm          // 备份前确认（退出微信 + 开始）
    case restoreFinalConfirm    // 恢复第二重确认（计划页确认后的最终 destructive 确认）
    case deleteSnapshotConfirm  // 删除快照确认
    case error, notice
    var id: String { rawValue }
}

enum ActiveSheet: Identifiable, Equatable {
    case restorePlan            // 恢复计划（第一重确认）
    case snapshotDetail(String) // 快照详情（携带快照 id）

    var id: String {
        switch self {
        case .restorePlan: return "restorePlan"
        case .snapshotDetail(let id): return "detail-\(id)"
        }
    }
}

// MARK: - 日志行展示模型（级别 → SF Symbol + 色调，正文保持主文字色）

struct LogLineModel: Equatable {
    let symbol: String
    let tone: StatusTone
    let text: String
}

enum LogPresentation {
    static func parse(_ raw: String) -> LogLineModel {
        if raw.contains("✅") {
            return LogLineModel(symbol: "checkmark.circle.fill", tone: .success,
                                text: raw.replacingOccurrences(of: "✅ ", with: ""))
        }
        if raw.contains("⚠️") {
            return LogLineModel(symbol: "exclamationmark.triangle.fill", tone: .warning,
                                text: raw.replacingOccurrences(of: "⚠️ ", with: ""))
        }
        if raw.contains("❌") {
            return LogLineModel(symbol: "xmark.octagon.fill", tone: .danger,
                                text: raw.replacingOccurrences(of: "❌ ", with: ""))
        }
        return LogLineModel(symbol: "info.circle", tone: .neutral, text: raw)
    }
}
