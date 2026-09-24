import AppIntents
import Foundation

/// Intents deliberately relay into the foreground app.  SwiftData stays owned
/// by the app's main-actor repositories rather than being opened from an
/// intent process with a second ModelContext.
nonisolated enum FamilyIntentRoute: String, Sendable, Equatable {
    case todayTimetable
    case commonFree
    case newAgenda
    case reportLocation
    case reportSafety

    static let storageKey = "family.intent.pending-route"
}

enum FamilyIntentRouter {
    static func enqueue(_ route: FamilyIntentRoute) {
        UserDefaults.standard.set(route.rawValue, forKey: FamilyIntentRoute.storageKey)
    }
}

private nonisolated protocol FamilyRoutingIntent: AppIntent {
    static var route: FamilyIntentRoute { get }
}

extension FamilyRoutingIntent {
    nonisolated static var openAppWhenRun: Bool { true }

    nonisolated func perform() async throws -> some IntentResult {
        await MainActor.run { FamilyIntentRouter.enqueue(Self.route) }
        return .result()
    }
}

nonisolated struct TodayTimetableIntent: FamilyRoutingIntent {
    static let title: LocalizedStringResource = "今日课表"
    static let description = IntentDescription("在家庭协作中打开今日课表。")
    static let route: FamilyIntentRoute = .todayTimetable
}

nonisolated struct CommonFreeIntent: FamilyRoutingIntent {
    static let title: LocalizedStringResource = "共同空闲"
    static let description = IntentDescription("在家庭协作中打开共同空闲时间分析。")
    static let route: FamilyIntentRoute = .commonFree
}

nonisolated struct NewAgendaIntent: FamilyRoutingIntent {
    static let title: LocalizedStringResource = "新建日程"
    static let description = IntentDescription("在家庭协作中打开新建日程。")
    static let route: FamilyIntentRoute = .newAgenda
}

nonisolated struct ReportLocationIntent: FamilyRoutingIntent {
    static let title: LocalizedStringResource = "上报位置"
    static let description = IntentDescription("为当前登录成员写入一次本地位置记录。")
    static let route: FamilyIntentRoute = .reportLocation
}

nonisolated struct ReportSafetyIntent: FamilyRoutingIntent {
    static let title: LocalizedStringResource = "报平安"
    static let description = IntentDescription("为当前登录成员更新本地一切正常状态。")
    static let route: FamilyIntentRoute = .reportSafety
}

nonisolated struct FamilyAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .blue }

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TodayTimetableIntent(), phrases: ["查看\(.applicationName)今日课表"], shortTitle: "今日课表", systemImageName: "calendar")
        AppShortcut(intent: CommonFreeIntent(), phrases: ["查看\(.applicationName)共同空闲"], shortTitle: "共同空闲", systemImageName: "person.2")
        AppShortcut(intent: NewAgendaIntent(), phrases: ["在\(.applicationName)新建日程"], shortTitle: "新建日程", systemImageName: "plus.circle")
        AppShortcut(intent: ReportLocationIntent(), phrases: ["在\(.applicationName)上报位置"], shortTitle: "上报位置", systemImageName: "location")
        AppShortcut(intent: ReportSafetyIntent(), phrases: ["在\(.applicationName)报平安"], shortTitle: "报平安", systemImageName: "checkmark.shield")
    }
}
