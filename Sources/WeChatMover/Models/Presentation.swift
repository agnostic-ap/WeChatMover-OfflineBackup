import Foundation

// MARK: - 展示层模型（View 只消费这些，不解析业务状态）

/// 状态色调。
enum StatusTone: Equatable {
    case neutral, info, success, warning, danger
}

/// 进行中的操作种类（驱动横幅/进度面板文案）。
enum BusyKind: Equatable {
    case migrating
    case restoring
    case deletingBackups
    case sizingExternal
    case cleaningExternal
    case quittingWeChat
    case resigning
}

/// 首要阻塞原因（主按钮禁用时在横幅里解释的就是它）。
enum Blocker: Equatable {
    case notInstalled
    case appStoreVersion
    case containerUnreadable
    case interruptedResidue
    case diskDisconnected
    case noDestination
    case destinationNotAPFS(String)
    case insufficientSpace(need: Int64, free: Int64)
}

/// 迁移生命周期结果（驱动成功/失败横幅）。
enum MigrationOutcome: Equatable {
    case succeeded(items: Int, bytes: Int64)
    case failed(String)
}

/// 单一状态源。
enum AppStatus: Equatable {
    case checking
    case ready
    case externalized                       // 全部已外置，无待迁移
    case blocked(Blocker)
    case busy(BusyKind, progress: Double?)  // 拿不到字节进度时 progress 为 nil（步骤文案代替）
    case succeeded(String)                  // 摘要文案
    case failed(String)                     // 用户可理解的原因
}

/// 横幅修复动作。
enum FixAction: Equatable {
    case chooseDestination
    case openFullDiskAccess
    case openOfficialDownload
    case retryMigration
}

/// ReadinessBanner 展示模型。
struct BannerModel: Equatable {
    var tone: StatusTone
    var symbol: String
    var title: String
    var message: String
    var progress: Double? = nil
    var fix: FixAction? = nil
}

/// 卡片自定义图标（SF Symbol 之外的真实图标）。
enum CardIcon: Equatable {
    case weChatApp   // 运行时取 /Applications/WeChat.app 的真实图标
}

/// 摘要卡片展示模型。
struct StatusCardModel: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tone: StatusTone
    var customIcon: CardIcon? = nil
    /// 图标在无警告/错误时用微信绿 accent（默认跟随 tone）。
    var iconUsesAccent: Bool = false
}

// MARK: - 弹窗状态（单一枚举驱动，避免同时弹出多个对话框）

enum ActiveDialog: String, Identifiable {
    case migrateConfirm, restoreConfirm, backupRestoreConfirm, backupConfirm
    case existingTarget, cleanExternal
    case error, notice
    var id: String { rawValue }
}

enum ActiveSheet: String, Identifiable {
    case guide              // 权限重新授权指南（先移除再添加）
    case appManagementGuide // 重签名受阻指引（App 管理 / 终端兜底）
    var id: String { rawValue }
}

// MARK: - 文案映射（技术值 → 人类语言，规范第 7 节）

enum Copywriting {
    /// 数据子目录的人类化名称。
    static func itemName(_ subdir: String) -> String {
        switch (subdir as NSString).lastPathComponent {
        case "xwechat_files": return "微信聊天文件"
        case "app_data": return "微信应用数据"
        case "com.tencent.xinWeChat": return "微信兼容数据"
        default: return (subdir as NSString).lastPathComponent
        }
    }

    /// 微信来源的人类化名称。
    static func sourceName(isAppStoreVersion: Bool) -> String {
        isAppStoreVersion ? "App Store 版" : "官网下载版"
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
