import Foundation
import SwiftUI

nonisolated enum MemberID: String, CaseIterable, Codable, Identifiable {
    case sendai = "Sendai", osaka = "Osaka", kyoto = "Kyoto"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .sendai: return .blue
        case .osaka: return .teal
        case .kyoto: return .indigo
        }
    }
    /// Immutable family identities shared with the future backend. Display
    /// names remain local presentation data; sync never matches by a nickname
    /// or the order of this enum.
    var remoteUUID: UUID {
        switch self {
        case .sendai: UUID(uuidString: "e7fda0a8-08b2-5ee0-b4ef-fcd4a381591a")!
        case .osaka: UUID(uuidString: "62d93a27-bb70-57b4-8d10-c43e80f612d1")!
        case .kyoto: UUID(uuidString: "f24af69c-3fd8-59bc-ab96-0b2610a1a4e5")!
        }
    }

    static func from(remoteUUID: UUID) -> MemberID? {
        allCases.first { $0.remoteUUID == remoteUUID }
    }

    /// The backend's one-status-per-member rows also need stable entity IDs,
    /// because the local status model is keyed by memberID rather than UUID.
    var remoteStatusUUID: UUID {
        switch self {
        case .sendai: UUID(uuidString: "1e0f6ad0-5b92-5ae3-9257-6e10948fb2e1")!
        case .osaka: UUID(uuidString: "f61c09e6-43a5-5ee3-b413-595b4df7df88")!
        case .kyoto: UUID(uuidString: "2b0d2442-1e9d-5fd4-bbd9-2d1f31859f9d")!
        }
    }
}

/// Compatibility bridge while the local store moves from the original three
/// display-keyed records to stable member UUIDs.  The three initial keys stay
/// untouched so existing SwiftData rows keep their identity; later members use
/// their remote UUID string as the local business key.
nonisolated enum MemberIdentity {
    static func remoteUUID(for localMemberID: String) -> UUID? {
        MemberID(rawValue: localMemberID)?.remoteUUID ?? UUID(uuidString: localMemberID)
    }

    static func localMemberID(for remoteUUID: UUID) -> String {
        MemberID.from(remoteUUID: remoteUUID)?.rawValue ?? remoteUUID.uuidString.lowercased()
    }

    static func isInitialMember(_ localMemberID: String) -> Bool {
        MemberID(rawValue: localMemberID) != nil
    }

    static func color(for localMemberID: String) -> Color {
        if let initial = MemberID(rawValue: localMemberID) { return initial.color }
        let palette: [Color] = [.cyan, .mint, .purple, .orange, .pink, .indigo]
        let index = localMemberID.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % palette.count }
        return palette[index]
    }
}

/// Backend-only shared chat identity. It is deterministic so two devices do
/// not create parallel family chat rows when remote sync is enabled later.
enum FamilyRemoteIdentity {
    static let sharedChatUUID = UUID(uuidString: "e6e4f080-93bd-5d58-a48d-1f18d1390217")!
}

enum ScheduleKind: String, CaseIterable, Codable { case course, groupMeeting }
enum WeekType: String, CaseIterable, Codable, Sendable { case everyWeek, oddWeek, evenWeek }
enum ExceptionKind: String, Codable { case cancelled, rescheduled, modified }
enum ExceptionScope: String, Codable { case thisOccurrence, thisAndFuture, entireSeries }
enum CalendarOverrideKind: String, CaseIterable, Codable, Hashable { case holiday, normal, mappedWeekday }
enum AgendaKind: String, CaseIterable, Codable { case normal, exam, assignmentDeadline, orderFood }
enum AgendaRecurrence: String, CaseIterable, Codable { case none, daily, weekly }
enum PreparationState: String, Codable { case waiting, preparing }
enum CompletionState: String, Codable { case pending, completed, overdue }
enum MessageKind: String, Codable { case text, image, audio, file, recalled }
enum ReceiptStatus: String, Codable { case sending, sent, delivered, read, failed }
enum PlaceKind: String, CaseIterable, Codable { case home, school, company, custom }
enum SafetyStatus: String, CaseIterable, Codable, Hashable { case allGood, headingHome, atHome, atSchool }
/// Kept separate from an optional persisted raw value so stores written before
/// automatic sharing continue to treat their existing snapshots as manual.
enum LocationSnapshotSource: String, Codable, Sendable { case automatic, manual }

extension ExceptionKind {
    var localizedName: String {
        switch self { case .cancelled: "取消"; case .rescheduled: "调期"; case .modified: "临时修改" }
    }
}

extension ExceptionScope {
    var localizedName: String {
        switch self { case .thisOccurrence: "仅本次"; case .thisAndFuture: "本次及以后"; case .entireSeries: "整个系列" }
    }
}

extension PlaceKind {
    var localizedName: String {
        switch self { case .home: "家"; case .school: "学校"; case .company: "公司"; case .custom: "自定义地点" }
    }
}

extension SafetyStatus {
    var localizedName: String {
        switch self {
        case .allGood: "一切正常"
        case .headingHome: "预计到家"
        case .atHome: "已到家"
        case .atSchool: "已到学校"
        }
    }

    var symbol: String {
        switch self {
        case .allGood: "checkmark.shield.fill"
        case .headingHome: "house.and.flag.fill"
        case .atHome: "house.fill"
        case .atSchool: "building.columns.fill"
        }
    }
}

extension LocationSnapshotSource {
    var localizedName: String {
        switch self {
        case .automatic: "自动"
        case .manual: "手动"
        }
    }
}

struct FoodReadReceipt: Identifiable {
    let memberID: String
    let readAt: Date
    var id: String { memberID }
}

extension AgendaItemModel {
    /// Persisted as small strings for automatic SwiftData migration compatibility.
    var foodReadReceipts: [FoodReadReceipt] {
        (foodReadAtRecords ?? []).compactMap { record in
            let parts = record.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, let timestamp = TimeInterval(parts[1]) else { return nil }
            return FoodReadReceipt(memberID: parts[0], readAt: Date(timeIntervalSince1970: timestamp))
        }.filter { participantIDs.contains($0.memberID) }.sorted { $0.readAt < $1.readAt }
    }
}

extension AgendaKind {
    var localizedName: String {
        switch self {
        case .normal: "普通日程"
        case .exam: "考试"
        case .assignmentDeadline: "作业截止"
        case .orderFood: "点菜"
        }
    }
}

extension AgendaRecurrence {
    var localizedName: String {
        switch self {
        case .none: "不重复"
        case .daily: "每天"
        case .weekly: "每周"
        }
    }
}

extension PreparationState {
    var localizedName: String { self == .waiting ? "待准备" : "准备中" }
}

extension CompletionState {
    var localizedName: String {
        switch self {
        case .pending: "待完成"
        case .completed: "已完成"
        case .overdue: "已逾期"
        }
    }
}

extension SemesterModel {
    /// The first academic week may be any non-empty local date range. Old
    /// records safely retain the historical seven-day interpretation.
    func firstWeekRange(calendar: Calendar = .autoupdatingCurrent) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: week1StartDate)
        let fallback = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let stored = week1EndDate.map(calendar.startOfDay(for:)) ?? fallback
        let days = calendar.dateComponents([.day], from: start, to: stored).day
        return days != nil && days! >= 0 ? (start, stored) : (start, fallback)
    }

    func weekNumber(on date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int? {
        guard totalWeeks > 0 else { return nil }
        let first = firstWeekRange(calendar: calendar)
        let day = calendar.startOfDay(for: date)
        if day >= first.start && day <= first.end { return 1 }
        guard totalWeeks > 1,
              let secondWeekStart = calendar.date(byAdding: .day, value: 1, to: first.end),
              day >= secondWeekStart,
              let offset = calendar.dateComponents([.day], from: secondWeekStart, to: day).day else { return nil }
        let week = offset / 7 + 2
        return (2...totalWeeks).contains(week) ? week : nil
    }

    func day(week: Int, weekday: Int, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard (1...totalWeeks).contains(week), (1...7).contains(weekday) else { return nil }
        let first = firstWeekRange(calendar: calendar)
        if week == 1 {
            let offset = (weekday - calendar.component(.weekday, from: first.start) + 7) % 7
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: first.start), candidate <= first.end else { return nil }
            return candidate
        }
        guard let weekStart = calendar.date(byAdding: .day, value: 1 + (week - 2) * 7, to: first.end) else { return nil }
        let offset = (weekday - calendar.component(.weekday, from: weekStart) + 7) % 7
        return calendar.date(byAdding: .day, value: offset, to: weekStart)
    }

    func academicDateRange(calendar: Calendar = .autoupdatingCurrent) -> DateInterval? {
        let first = firstWeekRange(calendar: calendar)
        guard let end = calendar.date(byAdding: .day, value: 1 + max(0, totalWeeks - 1) * 7, to: first.end) else { return nil }
        return DateInterval(start: first.start, end: end)
    }
}

extension CalendarOverrideKind {
    var localizedName: String {
        switch self { case .holiday: "节假日停课"; case .normal: "正常上课"; case .mappedWeekday: "按指定星期课表" }
    }
}

/// The compact calendar is a presentation of these real wall-clock ranges.
/// Conflict detection never uses the template; it always uses the stored times.
nonisolated enum ClassPeriodTemplate: Int, CaseIterable, Identifiable {
    case morningOne, morningTwo, afternoonOne, afternoonTwo, eveningOne, eveningTwo
    var id: Int { rawValue }
    var title: String { ["上午①", "上午②", "下午①", "下午②", "晚上①", "晚上②"][rawValue] }
    var startMinutes: Int { [8 * 60, 9 * 60 + 50, 13 * 60, 14 * 60 + 50, 18 * 60, 19 * 60 + 50][rawValue] }
    var endMinutes: Int { [9 * 60 + 40, 11 * 60 + 30, 14 * 60 + 40, 16 * 60 + 30, 19 * 60 + 40, 21 * 60 + 30][rawValue] }
    static func coveredPeriods(start: Int, end: Int) -> ClosedRange<Int>? {
        let hits = allCases.filter { start < $0.endMinutes && end > $0.startMinutes }.map(\.rawValue)
        guard let first = hits.first, let last = hits.last else { return nil }
        return first...last
    }

    /// The grid has only six presentation rows.  Valid wall-clock events in a
    /// break are attached to the nearest row instead of silently disappearing;
    /// their actual times remain visible on the block and are still the only
    /// values used by the time-analysis service.
    static func displayedPeriods(start: Int, end: Int) -> (periods: ClosedRange<Int>, isInGap: Bool)? {
        guard (0..<1_440).contains(start), (1...1_440).contains(end), start < end else { return nil }
        if let covered = coveredPeriods(start: start, end: end) { return (covered, false) }
        let midpoint = start + (end - start) / 2
        let nearest = allCases.min { lhs, rhs in
            min(abs(midpoint - lhs.startMinutes), abs(midpoint - lhs.endMinutes)) < min(abs(midpoint - rhs.startMinutes), abs(midpoint - rhs.endMinutes))
        } ?? .morningOne
        return (nearest.rawValue...nearest.rawValue, true)
    }
}

struct ScheduleOccurrence: Identifiable {
    let entryID: UUID
    let ownerID: String
    let start: Date
    let end: Date
    let title: String
    let kind: ScheduleKind
    let location: String?
    let grade: String?
    let className: String?
    var id: String { "\(entryID.uuidString)-\(start.timeIntervalSinceReferenceDate)" }
}

struct BusyInterval: Identifiable, Equatable {
    let id = UUID()
    let start: Date
    let end: Date
    let source: String
    var category: BusyCategory = .course
}

enum BusyCategory: String, Codable {
    case course, groupMeeting, exam, normalAgenda

    var localizedName: String {
        switch self {
        case .course: "课程"
        case .groupMeeting: "组会"
        case .exam: "考试"
        case .normalAgenda: "普通日程"
        }
    }
}

struct AvailabilitySlot: Identifiable, Equatable {
    let id = UUID()
    let start: Date
    let end: Date
    let participants: [String]
}

struct CoordinationPreferences: Equatable {
    var avoidEarly: Bool
    var avoidLate: Bool
    var avoidMeals: Bool
    var avoidBeforeExam: Bool
}

struct MemberAvailabilityDetail: Identifiable {
    let memberID: String
    let intervals: [BusyInterval]
    var id: String { memberID }
    var isBusy: Bool { !intervals.isEmpty }
}

struct DataHealthIssue: Identifiable {
    enum Severity: Equatable { case warning, error }
    let id = UUID()
    let severity: Severity
    let message: String
    let symbol: String
}

enum FamilyFormatters {
    static let time: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    static let dateTime: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
}

/// One presentation rule for all map surfaces. A stale timestamp only changes
/// its wording; it never changes whether a snapshot remains valid business data.
enum FamilyRelativeTime {
    static func locationUpdated(at timestamp: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(timestamp))
        if seconds < 60 { return "刚刚" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)分钟前" }
        let hours = Int(seconds / 3_600)
        if hours < 24 { return "\(hours)小时前" }
        return "\(Int(seconds / 86_400))天前"
    }
}
