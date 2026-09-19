import Foundation
import SwiftUI

enum MemberID: String, CaseIterable, Codable, Identifiable {
    case sendai = "Sendai", osaka = "Osaka", kyoto = "Kyoto"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .sendai: return .blue
        case .osaka: return .teal
        case .kyoto: return .indigo
        }
    }
    var symbol: String {
        switch self { case .sendai: return "person.crop.circle.fill"; case .osaka: return "person.crop.circle.fill"; case .kyoto: return "person.crop.circle.fill" }
    }
}

enum ScheduleKind: String, CaseIterable, Codable { case course, groupMeeting }
enum WeekType: String, CaseIterable, Codable { case everyWeek, oddWeek, evenWeek }
enum ExceptionKind: String, Codable { case cancelled, rescheduled, modified }
enum ExceptionScope: String, Codable { case thisOccurrence, thisAndFuture, entireSeries }
enum CalendarOverrideKind: String, CaseIterable, Codable, Hashable { case holiday, normal, mappedWeekday }
enum AgendaKind: String, CaseIterable, Codable { case normal, exam, assignmentDeadline, orderFood }
enum AgendaRecurrence: String, CaseIterable, Codable { case none, daily, weekly }
enum PreparationState: String, Codable { case waiting, preparing }
enum CompletionState: String, Codable { case pending, completed, overdue }
enum MessageKind: String, Codable { case text, image, audio, recalled }
enum ReceiptStatus: String, Codable { case sending, sent, delivered, read, failed }
enum PlaceKind: String, CaseIterable, Codable { case home, school, company, custom }

extension PlaceKind {
    var localizedName: String {
        switch self { case .home: "家"; case .school: "学校"; case .company: "公司"; case .custom: "自定义地点" }
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
            guard parts.count == 2, MemberID(rawValue: parts[0]) != nil, let timestamp = TimeInterval(parts[1]) else { return nil }
            return FoodReadReceipt(memberID: parts[0], readAt: Date(timeIntervalSince1970: timestamp))
        }.sorted { $0.readAt < $1.readAt }
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
enum ClassPeriodTemplate: Int, CaseIterable, Identifiable {
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
    func overlaps(_ other: BusyInterval) -> Bool { start < other.end && other.start < end }
}

struct AvailabilitySlot: Identifiable, Equatable {
    let id = UUID()
    let start: Date
    let end: Date
    let participants: [String]
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
