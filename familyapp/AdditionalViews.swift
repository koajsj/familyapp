import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import UniformTypeIdentifiers
import UIKit

private enum ScheduleMode: String, CaseIterable, Identifiable { case personal = "单人", pair = "两人", family = "家庭", analysis = "时间分析"; var id: String { rawValue } }

struct ScheduleView: View {
    @Environment(AppEnvironment.self) private var env
    @Query private var semesters: [SemesterModel]
    @Query private var entries: [ScheduleEntryModel]
    @Query private var exceptions: [ScheduleExceptionModel]
    @Query private var calendarOverrides: [CalendarOverrideModel]
    @Query private var agendas: [AgendaItemModel]
    @Query private var agendaExceptions: [AgendaExceptionModel]
    @State private var mode: ScheduleMode = .personal
    @State private var personalMember = ""
    @Query private var profiles: [MemberProfile]
    @State private var selectedMembers: Set<String> = []
    @State private var date = Date()
    @State private var showEditor = false
    @State private var showExceptionManager = false
    @State private var showCalendarManager = false
    @State private var showCalendarPreview = false
    @State private var showImporter = false
    @State private var minimum = 60
    @State private var analysisEnd = Date()
    @State private var dailyStartHour = 8
    @State private var dailyEndHour = 22
    @State private var proposedSlot: AvailabilitySlot?
    @State private var selectedAvailability: AvailabilitySlot?
    @Binding var routedIntent: FamilyIntentRoute?
    @AppStorage("coordination.buffer.minutes") private var bufferMinutes = 15
    @AppStorage("coordination.avoid.early") private var avoidEarly = true
    @AppStorage("coordination.avoid.late") private var avoidLate = true
    @AppStorage("coordination.avoid.meals") private var avoidMeals = false
    @AppStorage("coordination.avoid.beforeExam") private var avoidBeforeExam = true
    @State private var selectedOccurrence: ScheduleOccurrence?
    private var semester: SemesterModel? { semesters.first(where: \.isCurrent) }
    private var weekStart: Date {
        let calendar = Calendar.autoupdatingCurrent
        let weekday = calendar.component(.weekday, from: date)
        return calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: calendar.startOfDay(for: date)) ?? date
    }
    private var availableMemberIDs: [String] {
        MemberDirectory.activeMembers(from: profiles).map(\.memberID)
    }
    private var visiblePeople: Set<String> {
        switch mode { case .personal: return [personalMember]; case .pair: return selectedMembers; case .family: return Set(availableMemberIDs); case .analysis: return [] }
    }
    var body: some View {
        NavigationStack {
            List {
                Picker("模式", selection: $mode) { ForEach(ScheduleMode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                if let semester {
                    Section { weekControls(semester) }
                    if mode == .analysis { analysis(semester) } else { gridSection(semester) }
                } else { ContentUnavailableView("没有当前学期", systemImage: "calendar.badge.exclamationmark") }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("课表")
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { showExceptionManager = true } label: { Image(systemName: "calendar.badge.exclamationmark") }.accessibilityLabel("管理停课、调课和临时修改")
                    Button { showCalendarManager = true } label: { Image(systemName: "calendar.badge.plus") }.accessibilityLabel("管理节假日和调休")
                    Button { showCalendarPreview = true } label: { Image(systemName: "calendar.day.timeline.leading") }.accessibilityLabel("按日期预览校历和最终课程")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }.accessibilityLabel("导入课表")
                    Button { showEditor = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建课程或组会")
                }
            }
            .sheet(isPresented: $showEditor) { NavigationStack { ScheduleEditor(entry: nil, semester: semester) } }
            .sheet(isPresented: $showExceptionManager) { NavigationStack { ScheduleExceptionList(entries: entries.filter { $0.ownerID == env.session.currentMemberID }) } }
            .sheet(isPresented: $showCalendarManager) { if let semester { NavigationStack { CalendarOverrideList(semester: semester) } } }
            .sheet(isPresented: $showCalendarPreview) { if let semester { NavigationStack { AcademicCalendarPreview(semester: semester, selectedDate: $date) } } }
            .sheet(isPresented: $showImporter) { if let semester { NavigationStack { ScheduleImportView(semester: semester) } } }
            .sheet(item: $proposedSlot) { slot in NavigationStack { AgendaEditor(item: nil, proposedSlot: slot) } }
            .sheet(item: $selectedAvailability) { slot in
                NavigationStack {
                    CoordinationSlotDetail(slot: slot, semester: semester, entries: entries, exceptions: exceptions, agendas: agendas, agendaExceptions: agendaExceptions, calendarOverrides: calendarOverrides)
                }
            }
            .sheet(item: $selectedOccurrence) { occurrence in
                if let entry = entries.first(where: { $0.id == occurrence.entryID }) { NavigationStack { ScheduleEditor(entry: entry, semester: semester) } }
            }
            .onAppear { initializeForCurrentMember(); handleIntentRoute() }
            .onChange(of: routedIntent) { _, _ in handleIntentRoute() }
        }
    }

    private func handleIntentRoute() {
        guard let route = routedIntent else { return }
        switch route {
        case .todayTimetable:
            date = .now
            mode = .personal
            personalMember = env.session.currentMemberID ?? ""
            routedIntent = nil
        case .commonFree:
            date = .now
            analysisEnd = .now
            selectedMembers = Set(availableMemberIDs)
            mode = .analysis
            routedIntent = nil
        default:
            routedIntent = nil
        }
    }
    private func initializeForCurrentMember() {
        if personalMember.isEmpty || !availableMemberIDs.contains(personalMember) {
            personalMember = env.session.currentMemberID.flatMap { availableMemberIDs.contains($0) ? $0 : nil } ?? availableMemberIDs.first ?? ""
        }
        if selectedMembers.isEmpty || !selectedMembers.isSubset(of: Set(availableMemberIDs)) {
            selectedMembers = Set(availableMemberIDs.prefix(2))
        }
    }
    @ViewBuilder private func weekControls(_ semester: SemesterModel) -> some View {
        HStack {
            Button { date = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -7, to: date) ?? date } label: { Image(systemName: "chevron.left") }
            Spacer()
            NavigationLink { SemesterManagerView() } label: { VStack(spacing: 2) { Text(semester.name).font(.subheadline.weight(.semibold)); Text("第 \(env.timeAnalysis.weekNumber(on: date, semester: semester) ?? 0) 周 · 学期设置").font(.caption).foregroundStyle(.secondary) } }.buttonStyle(.plain).accessibilityLabel("学期管理：\(semester.name)")
            Spacer()
            Button { date = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 7, to: date) ?? date } label: { Image(systemName: "chevron.right") }
        }
        DatePicker("跳转日期", selection: $date, displayedComponents: .date).font(.caption)
        switch mode {
        case .personal:
            Picker("成员", selection: $personalMember) { ForEach(availableMemberIDs, id: \.self) { MemberLabel(memberID: $0).tag($0) } }
        case .pair:
            memberToggles(limit: 2)
        case .family:
            Text("家庭聚合：课程块会显示成员。空白格只表示该展示课段没有课程，不等于共同空闲。 ").font(.caption).foregroundStyle(.secondary)
        case .analysis: EmptyView()
        }
    }
    private func memberToggles(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("选择 \(limit) 名成员").font(.caption).foregroundStyle(.secondary)
            HStack { ForEach(availableMemberIDs, id: \.self) { memberID in
                Toggle(isOn: Binding(get: { selectedMembers.contains(memberID) }, set: { enabled in
                    if enabled, selectedMembers.count < limit { selectedMembers.insert(memberID) }
                    if !enabled, selectedMembers.count > 1 { selectedMembers.remove(memberID) }
                })) { MemberLabel(memberID: memberID) }.toggleStyle(.button).tint(MemberIdentity.color(for: memberID))
            } }
        }
    }
    private func gridSection(_ semester: SemesterModel) -> some View {
        let end = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let occurrences = env.timeAnalysis.scheduleOccurrences(in: DateInterval(start: weekStart, end: end), entries: entries, exceptions: exceptions, calendarOverrides: calendarOverrides, semester: semester, memberIDs: visiblePeople)
        return Section {
            WeeklyScheduleGrid(weekStart: weekStart, occurrences: occurrences, showDetails: mode == .personal, onSelect: { selectedOccurrence = $0 })
                .frame(height: 395)
            if mode == .pair { Text("色块同时显示名字：同一格出现两名成员即两人都忙。空白格不等于共同空闲，请在时间分析中按真实起止时间计算。 ").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func analysis(_ semester: SemesterModel) -> some View {
        let calendar = Calendar.autoupdatingCurrent
        let firstDay = calendar.startOfDay(for: date)
        let lastDay = max(firstDay, calendar.startOfDay(for: analysisEnd))
        var days: [Date] = []
        var cursor = firstDay
        while cursor <= lastDay {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        let memberIDs = Array(selectedMembers)
        let slots = days.flatMap { day -> [AvailabilitySlot] in
            let start = calendar.date(bySettingHour: dailyStartHour, minute: 0, second: 0, of: day) ?? day
            let end = calendar.date(bySettingHour: dailyEndHour, minute: 0, second: 0, of: day) ?? day
            guard start < end else { return [] }
            return env.timeAnalysis.commonFree(memberIDs: memberIDs, range: DateInterval(start: start, end: end), minimumMinutes: minimum, bufferMinutes: bufferMinutes, entries: entries, exceptions: exceptions, agendas: agendas, agendaExceptions: agendaExceptions, calendarOverrides: calendarOverrides, semester: semester)
        }
        let preferenceRange = DateInterval(start: firstDay, end: calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay)
        let reasons = env.timeAnalysis.busyReasons(memberIDs: memberIDs, in: preferenceRange, entries: entries, exceptions: exceptions, agendas: agendas, agendaExceptions: agendaExceptions, calendarOverrides: calendarOverrides, semester: semester)
        let preferences = CoordinationPreferences(avoidEarly: avoidEarly, avoidLate: avoidLate, avoidMeals: avoidMeals, avoidBeforeExam: avoidBeforeExam)
        let rankedSlots = env.timeAnalysis.rank(slots: slots, preferences: preferences, busyReasons: reasons)
        return Group {
            Section("今日协调") {
                if let next = rankedSlots.first {
                    HStack { VStack(alignment: .leading, spacing: 2) { Text("推荐共同空闲").font(.caption).foregroundStyle(.secondary); Text("\(FamilyFormatters.day.string(from: next.start)) · \(FamilyFormatters.time.string(from: next.start))–\(FamilyFormatters.time.string(from: next.end))").font(.subheadline.weight(.semibold)) }; Spacer(); Button("创建日程") { proposedSlot = next }.font(.caption) }
                } else {
                    Text("今天没有符合条件的共同空闲。可调整日期或筛选条件。 ").foregroundStyle(.secondary)
                }
            }
            Section("共同空闲") {
                if selectedMembers.count < 2 { Text("至少选择两名成员。 ").foregroundStyle(.secondary) }
                else if rankedSlots.isEmpty { Text("没有符合条件的共同空闲。 ").foregroundStyle(.secondary) }
                else { ForEach(rankedSlots) { slot in HStack { Button { selectedAvailability = slot } label: { Text("\(FamilyFormatters.day.string(from: slot.start))  \(FamilyFormatters.time.string(from: slot.start))–\(FamilyFormatters.time.string(from: slot.end))").font(.caption) }.buttonStyle(.plain).accessibilityLabel("查看该时段三名成员的占用原因"); Spacer(); Button("创建日程") { proposedSlot = slot }.font(.caption).accessibilityLabel("用该共同空闲创建日程") } } }
            }
            Section("不可用时段") {
                let unavailable = busyReasonRows(reasons)
                if unavailable.isEmpty { Text("所选范围内没有忙碌时段。 ").foregroundStyle(.secondary) }
                ForEach(unavailable) { row in
                    Button {
                        selectedAvailability = AvailabilitySlot(start: row.interval.start, end: row.interval.end, participants: memberIDs)
                    } label: {
                        HStack {
                            MemberLabel(memberID: row.memberID)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(row.interval.category.localizedName)：\(row.interval.source)")
                                Text("\(FamilyFormatters.day.string(from: row.interval.start)) · \(FamilyFormatters.time.string(from: row.interval.start))–\(FamilyFormatters.time.string(from: row.interval.end))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看 \(row.memberID) 的\(row.interval.category.localizedName)占用详情")
                }
            }
            Section("筛选与协调偏好") {
                DisclosureGroup("成员、日期与时长") { memberToggles(limit: 3); DatePicker("开始日期", selection: $date, displayedComponents: .date); DatePicker("结束日期", selection: $analysisEnd, in: firstDay..., displayedComponents: .date); Stepper("每日开始：\(dailyStartHour):00", value: $dailyStartHour, in: 0...22); Stepper("每日结束：\(dailyEndHour):00", value: $dailyEndHour, in: 1...23); Stepper("最短连续空闲：\(minimum) 分钟", value: $minimum, in: 30...300, step: 30); Picker("前后缓冲", selection: $bufferMinutes) { Text("不留缓冲").tag(0); Text("10 分钟").tag(10); Text("15 分钟").tag(15); Text("30 分钟").tag(30) } }
                DisclosureGroup("本地协调偏好") { Toggle("尽量避开过早", isOn: $avoidEarly); Toggle("尽量避开过晚", isOn: $avoidLate); Toggle("尽量避开吃饭时间", isOn: $avoidMeals); Toggle("尽量避开考试前", isOn: $avoidBeforeExam); Text("偏好只调整推荐顺序，不会改变真实占用时间。") .font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func busyReasonRows(_ reasons: [String: [BusyInterval]]) -> [MemberBusyReasonRow] {
        reasons.flatMap { memberID, intervals in intervals.map { MemberBusyReasonRow(memberID: memberID, interval: $0) } }
            .sorted { $0.interval.start < $1.interval.start }
    }
}

private struct MemberBusyReasonRow: Identifiable {
    let memberID: String
    let interval: BusyInterval
    var id: String { "\(memberID)-\(interval.id.uuidString)" }
}

private struct CoordinationSlotDetail: View {
    @Environment(AppEnvironment.self) private var env
    let slot: AvailabilitySlot
    let semester: SemesterModel?
    let entries: [ScheduleEntryModel]
    let exceptions: [ScheduleExceptionModel]
    let agendas: [AgendaItemModel]
    let agendaExceptions: [AgendaExceptionModel]
    let calendarOverrides: [CalendarOverrideModel]

    var body: some View {
        List {
            Section("时段") {
                Text("\(FamilyFormatters.dateTime.string(from: slot.start)) – \(FamilyFormatters.time.string(from: slot.end))")
            }
            Section("成员状态") {
                if let semester {
                    ForEach(details(semester)) { detail in
                        VStack(alignment: .leading, spacing: 3) {
                            MemberLabel(memberID: detail.memberID)
                            if detail.isBusy {
                                ForEach(detail.intervals) { interval in
                                    Text("\(interval.category.localizedName)：\(interval.source) · \(FamilyFormatters.time.string(from: interval.start))–\(FamilyFormatters.time.string(from: interval.end))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("此时段无课程、组会、考试或普通日程占用。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("时段详情")
    }

    private func details(_ semester: SemesterModel) -> [MemberAvailabilityDetail] {
        env.timeAnalysis.availabilityDetails(for: slot, memberIDs: slot.participants, entries: entries, exceptions: exceptions, agendas: agendas, agendaExceptions: agendaExceptions, calendarOverrides: calendarOverrides, semester: semester)
    }
}

private struct AcademicCalendarPreview: View {
    @Environment(AppEnvironment.self) private var env
    @Query private var entries: [ScheduleEntryModel]
    @Query private var exceptions: [ScheduleExceptionModel]
    @Query private var overrides: [CalendarOverrideModel]
    let semester: SemesterModel
    @Binding var selectedDate: Date

    private var dayRange: DateInterval {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: selectedDate)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start)
    }
    private var dayOverrides: [CalendarOverrideModel] {
        let calendar = Calendar.autoupdatingCurrent
        return overrides.filter { $0.semesterID == semester.id && calendar.isDate($0.date, inSameDayAs: selectedDate) }
    }
    private var rawEntries: [ScheduleEntryModel] {
        let calendar = Calendar.autoupdatingCurrent
        let weekday = calendar.component(.weekday, from: selectedDate)
        return entries.filter { $0.semesterID == semester.id && $0.weekday == weekday }
    }
    private var finalOccurrences: [ScheduleOccurrence] {
        env.timeAnalysis.scheduleOccurrences(in: dayRange, entries: entries, exceptions: exceptions, calendarOverrides: overrides, semester: semester)
    }

    var body: some View {
        List {
            Section {
                DatePicker("日期", selection: $selectedDate, displayedComponents: .date)
                Text(weekText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("节假日 / 调休") {
                if dayOverrides.isEmpty {
                    Text("当天没有校历覆盖规则。") .foregroundStyle(.secondary)
                } else {
                    ForEach(dayOverrides) { rule in
                        Text(rule.kind == .mappedWeekday ? "按周\(weekdayName(rule.mappedWeekday))课表" : rule.kind.localizedName)
                    }
                }
            }
            Section("原始课程定义") {
                if rawEntries.isEmpty { Text("当天自然星期没有原始课程定义。") .foregroundStyle(.secondary) }
                ForEach(rawEntries) { entry in
                    Text("\(entry.title) · \(time(entry.startMinutes))–\(time(entry.endMinutes)) · 第 \(entry.startWeek)-\(entry.endWeek) 周")
                }
            }
            Section("停课 / 调课规则") {
                let rules = exceptions.filter { rule in rawEntries.contains(where: { $0.id == rule.scheduleID }) }
                if rules.isEmpty { Text("当天相关课程没有例外规则。") .foregroundStyle(.secondary) }
                ForEach(rules) { rule in Text("\(rule.kind.localizedName) · \(rule.scope.localizedName) · \(FamilyFormatters.day.string(from: rule.occurrenceDate))") }
            }
            Section("最终实际课程") {
                if finalOccurrences.isEmpty { Text("当天没有最终有效课程。") .foregroundStyle(.secondary) }
                ForEach(finalOccurrences) { item in
                    Text("\(item.title) · \(FamilyFormatters.time.string(from: item.start))–\(FamilyFormatters.time.string(from: item.end))")
                }
            }
        }
        .navigationTitle("校历预览")
    }

    private func weekdayName(_ value: Int?) -> String {
        guard let value else { return "" }
        return ["日", "一", "二", "三", "四", "五", "六"][max(1, min(7, value)) - 1]
    }
    private func time(_ value: Int) -> String { String(format: "%02d:%02d", value / 60, value % 60) }
    private var weekText: String {
        env.timeAnalysis.weekNumber(on: selectedDate, semester: semester).map { "教学第 \($0) 周" } ?? "学期外日期"
    }
}

private struct WeeklyScheduleGrid: View {
    private struct Placement: Identifiable {
        let occurrence: ScheduleOccurrence
        let day: Int
        let periods: ClosedRange<Int>
        let isInGap: Bool
        let lane: Int
        let laneCount: Int
        var id: String { occurrence.id }
    }
    let weekStart: Date
    let occurrences: [ScheduleOccurrence]
    let showDetails: Bool
    let onSelect: (ScheduleOccurrence) -> Void
    private let calendar = Calendar.autoupdatingCurrent
    private let standardCellFill = Color(uiColor: .secondarySystemBackground)
    private let gridLine = Color(uiColor: .separator)
    var body: some View {
        GeometryReader { proxy in
            let labelWidth: CGFloat = 28
            let headerHeight: CGFloat = 31
            let column = (proxy.size.width - labelWidth) / 7
            let row = (proxy.size.height - headerHeight) / 6
            ZStack(alignment: .topLeading) {
                ForEach(0..<7, id: \.self) { day in
                    let date = calendar.date(byAdding: .day, value: day, to: weekStart) ?? weekStart
                    Text(dayTitle(date)).font(.caption2.weight(.medium)).lineLimit(1).frame(width: column, height: headerHeight)
                        .background(calendar.isDateInToday(date) ? Color.accentColor.opacity(0.12) : .clear)
                        .offset(x: labelWidth + CGFloat(day) * column)
                }
                ForEach(ClassPeriodTemplate.allCases) { period in
                    Text(period.title).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: labelWidth, height: row)
                        .offset(y: headerHeight + CGFloat(period.rawValue) * row)
                    ForEach(0..<7, id: \.self) { day in
                        Rectangle().fill(calendar.isDateInToday(calendar.date(byAdding: .day, value: day, to: weekStart) ?? weekStart) ? Color.accentColor.opacity(0.12) : standardCellFill)
                            .overlay(Rectangle().stroke(gridLine.opacity(0.7), lineWidth: 0.35))
                            .frame(width: column, height: row).offset(x: labelWidth + CGFloat(day) * column, y: headerHeight + CGFloat(period.rawValue) * row)
                    }
                }
                ForEach(placements) { placement in
                    let blockWidth = max(0, (column - 4) / CGFloat(placement.laneCount))
                    Button { onSelect(placement.occurrence) } label: { GridScheduleBlock(item: placement.occurrence, showDetails: showDetails, isInGap: placement.isInGap) }
                        .buttonStyle(.plain)
                        .frame(width: blockWidth, height: max(0, CGFloat(placement.periods.upperBound - placement.periods.lowerBound + 1) * row - 4))
                        .offset(x: labelWidth + CGFloat(placement.day) * column + 2 + CGFloat(placement.lane) * blockWidth, y: headerHeight + CGFloat(placement.periods.lowerBound) * row + 2)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("周一到周日、每天六个课段的周课表")
    }
    private func dayTitle(_ date: Date) -> String { let names = ["日", "一", "二", "三", "四", "五", "六"]; return "周\(names[calendar.component(.weekday, from: date) - 1])" }
    private func minute(_ date: Date) -> Int { calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date) }
    private var placements: [Placement] {
        let raw = occurrences.compactMap { occurrence -> (ScheduleOccurrence, Int, ClosedRange<Int>, Bool)? in
            guard let day = calendar.dateComponents([.day], from: calendar.startOfDay(for: weekStart), to: calendar.startOfDay(for: occurrence.start)).day,
                  (0..<7).contains(day),
                  let presentation = ClassPeriodTemplate.displayedPeriods(start: minute(occurrence.start), end: minute(occurrence.end)) else { return nil }
            return (occurrence, day, presentation.periods, presentation.isInGap)
        }
        return (0..<7).flatMap { day in
            let dayItems = raw.filter { $0.1 == day }.sorted { lhs, rhs in
                lhs.2.lowerBound == rhs.2.lowerBound ? lhs.2.upperBound < rhs.2.upperBound : lhs.2.lowerBound < rhs.2.lowerBound
            }
            var groups: [[(ScheduleOccurrence, Int, ClosedRange<Int>, Bool)]] = []
            var current: [(ScheduleOccurrence, Int, ClosedRange<Int>, Bool)] = []
            var currentEnd = -1
            for item in dayItems {
                if !current.isEmpty && item.2.lowerBound > currentEnd { groups.append(current); current = []; currentEnd = -1 }
                current.append(item); currentEnd = max(currentEnd, item.2.upperBound)
            }
            if !current.isEmpty { groups.append(current) }
            return groups.flatMap { group -> [Placement] in
                var laneEnds: [Int] = []
                var assigned: [(ScheduleOccurrence, Int, ClosedRange<Int>, Bool, Int)] = []
                for item in group {
                    let lane = laneEnds.firstIndex(where: { $0 < item.2.lowerBound }) ?? laneEnds.count
                    if lane == laneEnds.count { laneEnds.append(item.2.upperBound) } else { laneEnds[lane] = item.2.upperBound }
                    assigned.append((item.0, item.1, item.2, item.3, lane))
                }
                return assigned.map { Placement(occurrence: $0.0, day: $0.1, periods: $0.2, isInGap: $0.3, lane: $0.4, laneCount: laneEnds.count) }
            }
        }
    }
}

private struct GridScheduleBlock: View {
    let item: ScheduleOccurrence
    let showDetails: Bool
    let isInGap: Bool
    @Query private var profiles: [MemberProfile]
    private var ownerName: String { profiles.first(where: { $0.memberID == item.ownerID })?.displayName ?? item.ownerID }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !showDetails { Text(ownerName).font(.system(size: 8, weight: .medium)).lineLimit(1) }
            Text(item.title).font(.system(size: 9, weight: .semibold)).lineLimit(2)
            if let location = item.location { Text(location).font(.system(size: 8)).lineLimit(1) }
            if showDetails, let grade = item.grade { Text([grade, item.className].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 7)).lineLimit(1) }
            if isInGap { Text("间隙 · \(FamilyFormatters.time.string(from: item.start))").font(.system(size: 7)).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(3)
        .background(MemberIdentity.color(for: item.ownerID).opacity(item.kind == .groupMeeting ? 0.28 : 0.18), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel("\(ownerName) \(item.title)，\(FamilyFormatters.time.string(from: item.start)) 到 \(FamilyFormatters.time.string(from: item.end))\(isInGap ? "，课段间隙课程" : "")")
    }
}

private struct ScheduleEditor: View {
    @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env
    let entry: ScheduleEntryModel?; let semester: SemesterModel?; @State private var title = ""; @State private var kind: ScheduleKind = .course; @State private var weekday = 2; @State private var start = Date(); @State private var end = Date().addingTimeInterval(3600); @State private var startWeek = 1; @State private var endWeek = 16; @State private var type: WeekType = .everyWeek; @State private var major = ""; @State private var grade = ""; @State private var className = ""; @State private var location = ""; @State private var note = ""; @State private var labName = ""; @State private var advisor = ""; @State private var error: String?; @State private var confirmDelete = false
    private var totalWeeks: Int { max(1, semester?.totalWeeks ?? 1) }
    private let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
    var body: some View { Form { Section { TextField("名称", text: $title); LabeledContent("成员") { if let memberID = env.session.currentMemberID { MemberLabel(memberID: memberID) } }; Picker("类别", selection: $kind) { Text("课程").tag(ScheduleKind.course); Text("组会").tag(ScheduleKind.groupMeeting) }; Picker("星期", selection: $weekday) { ForEach(1...7, id: \.self) { Text(weekdayNames[$0 - 1]).tag($0) } }; DatePicker("开始时间", selection: $start, displayedComponents: .hourAndMinute); DatePicker("结束时间", selection: $end, displayedComponents: .hourAndMinute) }
        Section("周期") { Stepper("起始周：\(startWeek)", value: $startWeek, in: 1...totalWeeks); Stepper("结束周：\(endWeek)", value: $endWeek, in: startWeek...totalWeeks); Picker("周类型", selection: $type) { Text("每周").tag(WeekType.everyWeek); Text("单周").tag(WeekType.oddWeek); Text("双周").tag(WeekType.evenWeek) } }; Section("可选信息") { TextField("专业", text: $major); TextField("年级", text: $grade); TextField("班级", text: $className); TextField("地点", text: $location); TextField("备注", text: $note, axis: .vertical); if kind == .groupMeeting { TextField("实验室 / 课题组", text: $labName); TextField("指导老师", text: $advisor) } }; BusinessAIAssistButton(title: "AI 解析课程 / 组会", instruction: "Extract a proposed course or meeting description from natural language. Keep unknown fields blank and return plain text only.", source: "\(title) \(location) \(note)") { note = $0 }
    }.disabled(!canEdit).navigationTitle(entry == nil ? "新建安排" : "安排详情").toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(!canEdit) }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; if entry != nil && canEdit { ToolbarItem(placement: .bottomBar) { Button("删除", role: .destructive) { confirmDelete = true } } } }.onAppear(perform: load).onChange(of: startWeek) { _, value in if endWeek < value { endWeek = value } }.confirmationDialog("删除此课程或组会？", isPresented: $confirmDelete, titleVisibility: .visible) { Button("删除", role: .destructive, action: delete) }.alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") } }
    private var canEdit: Bool { entry == nil || entry?.ownerID == env.session.currentMemberID }
    private func load() { guard let entry else { endWeek = min(16, totalWeeks); return }; title = entry.title; kind = entry.kind; weekday = entry.weekday; start = time(entry.startMinutes); end = time(entry.endMinutes); startWeek = min(entry.startWeek, totalWeeks); endWeek = min(max(entry.endWeek, startWeek), totalWeeks); type = entry.weekType; major = entry.major ?? ""; grade = entry.grade ?? ""; className = entry.className ?? ""; location = entry.location ?? ""; note = entry.note ?? ""; labName = entry.labName ?? ""; advisor = entry.advisor ?? "" }
    private func time(_ minutes: Int) -> Date { Calendar.autoupdatingCurrent.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now }
    private func save() { guard let semester, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请填写名称并先创建当前学期。"; return }; let c = Calendar.autoupdatingCurrent; let sm = (c.component(.hour, from: start) * 60) + c.component(.minute, from: start); let em = (c.component(.hour, from: end) * 60) + c.component(.minute, from: end); guard sm < em else { error = "结束时间必须晚于开始时间，且不支持跨午夜。"; return }; let draft = ScheduleDraft(title: title, kind: kind, weekday: weekday, startMinutes: sm, endMinutes: em, startWeek: startWeek, endWeek: endWeek, weekType: type, major: major.isEmpty ? nil : major, grade: grade.isEmpty ? nil : grade, className: className.isEmpty ? nil : className, location: location.isEmpty ? nil : location, note: note.isEmpty ? nil : note, labName: kind == .groupMeeting && !labName.isEmpty ? labName : nil, advisor: kind == .groupMeeting && !advisor.isEmpty ? advisor : nil); let value = entry ?? ScheduleEntryModel(ownerID: env.session.currentMemberID ?? "", semesterID: semester.id, title: draft.title, kind: draft.kind, weekday: draft.weekday, startMinutes: draft.startMinutes, endMinutes: draft.endMinutes, startWeek: draft.startWeek, endWeek: draft.endWeek, weekType: draft.weekType); do { try env.scheduleRepository.save(value, draft: draft, by: env.session.currentMemberID ?? ""); dismiss() } catch { self.error = error.localizedDescription } }
    private func delete() { guard let entry else { return }; do { try env.scheduleRepository.delete(entry, by: env.session.currentMemberID ?? ""); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct ScheduleExceptionList: View {
    @Environment(AppEnvironment.self) private var env
    @Query private var exceptions: [ScheduleExceptionModel]
    let entries: [ScheduleEntryModel]
    @State private var editing: ScheduleExceptionModel?
    @State private var showingNew = false
    @State private var confirmDelete: ScheduleExceptionModel?

    private var owned: [ScheduleExceptionModel] {
        exceptions.filter { rule in entries.contains(where: { $0.id == rule.scheduleID }) }
            .sorted { $0.occurrenceDate < $1.occurrenceDate }
    }

    var body: some View {
        List {
            if owned.isEmpty {
                ContentUnavailableView("没有例外规则", systemImage: "calendar.badge.exclamationmark", description: Text("可以为自己的课程或组会添加停课、调课或临时修改。"))
            } else {
                ForEach(owned) { rule in
                    Button { editing = rule } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entries.first(where: { $0.id == rule.scheduleID })?.title ?? "已删除安排")
                            Text("\(kindTitle(rule.kind)) · \(scopeTitle(rule.scope)) · \(FamilyFormatters.day.string(from: rule.occurrenceDate))")
                                .font(.caption).foregroundStyle(.secondary)
                            if rule.kind != .cancelled, let date = rule.replacementDate {
                                Text("调整至 \(FamilyFormatters.dateTime.string(from: date))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button("删除", role: .destructive) { confirmDelete = rule }
                    }
                }
            }
        }
        .navigationTitle("课表例外")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showingNew = true } label: { Image(systemName: "plus") }.disabled(entries.isEmpty) } }
        .sheet(isPresented: $showingNew) { NavigationStack { ScheduleExceptionEditor(entries: entries) } }
        .sheet(item: $editing) { rule in NavigationStack { ScheduleExceptionEditor(entries: entries, exception: rule) } }
        .confirmationDialog("删除此例外规则？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let rule = confirmDelete else { return }
                do { try env.scheduleRepository.delete(exception: rule, by: env.session.currentMemberID ?? "") }
                catch { env.lastError = error.localizedDescription }
                confirmDelete = nil
            }
        }
    }

    private func kindTitle(_ value: ExceptionKind) -> String { switch value { case .cancelled: return "停课"; case .rescheduled: return "调课"; case .modified: return "临时修改" } }
    private func scopeTitle(_ value: ExceptionScope) -> String { switch value { case .thisOccurrence: return "仅本次"; case .thisAndFuture: return "本次及以后"; case .entireSeries: return "整个系列" } }
}

private struct ScheduleExceptionEditor: View {
    @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env
    let entries: [ScheduleEntryModel]; let exception: ScheduleExceptionModel?
    @State private var entryID: UUID?; @State private var kind: ExceptionKind = .rescheduled; @State private var scope: ExceptionScope = .thisOccurrence; @State private var occurrence = Date(); @State private var replacement = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: .now) ?? .now; @State private var start = Date(); @State private var end = Date().addingTimeInterval(3600); @State private var error: String?
    init(entries: [ScheduleEntryModel], exception: ScheduleExceptionModel? = nil) { self.entries = entries; self.exception = exception }
    var body: some View { Form { if entries.isEmpty { Text("当前成员还没有可调整的课程或组会。").foregroundStyle(.secondary) } else { Picker("安排", selection: Binding(get: { entryID ?? entries[0].id }, set: { entryID = $0 })) { ForEach(entries) { Text($0.title).tag($0.id) } }.disabled(exception != nil); Picker("操作", selection: $kind) { Text("停课").tag(ExceptionKind.cancelled); Text("调课").tag(ExceptionKind.rescheduled); Text("临时修改").tag(ExceptionKind.modified) }; Picker("范围", selection: $scope) { Text("本次").tag(ExceptionScope.thisOccurrence); Text("本次及以后").tag(ExceptionScope.thisAndFuture); Text("整个系列").tag(ExceptionScope.entireSeries) }; DatePicker("发生日期", selection: $occurrence, displayedComponents: .date); if kind != .cancelled { DatePicker("调到日期", selection: $replacement, displayedComponents: .date); DatePicker("开始时间", selection: $start, displayedComponents: .hourAndMinute); DatePicker("结束时间", selection: $end, displayedComponents: .hourAndMinute) } } }.navigationTitle(exception == nil ? "新增课表例外" : "编辑课表例外").toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(entries.isEmpty) }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }.onAppear(perform: load).alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") } }
    private func load() { guard let exception else { return }; entryID = exception.scheduleID; kind = exception.kind; scope = exception.scope; occurrence = exception.occurrenceDate; replacement = exception.replacementDate ?? occurrence; let calendar = Calendar.autoupdatingCurrent; start = time(exception.replacementStartMinutes ?? 8 * 60, calendar: calendar); end = time(exception.replacementEndMinutes ?? 9 * 60, calendar: calendar) }
    private func time(_ minutes: Int, calendar: Calendar) -> Date { calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now }
    private func save() { guard let selectedID = entryID ?? entries.first?.id, let selected = entries.first(where: { $0.id == selectedID }) else { return }; let calendar = Calendar.autoupdatingCurrent; let sm = calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start); let em = calendar.component(.hour, from: end) * 60 + calendar.component(.minute, from: end); guard kind == .cancelled || sm < em else { error = "结束时间必须晚于开始时间。"; return }; let rule = exception ?? ScheduleExceptionModel(scheduleID: selected.id, kind: kind, scope: scope, occurrenceDate: occurrence); let draft = ScheduleExceptionDraft(kind: kind, scope: scope, occurrenceDate: occurrence, replacementDate: kind == .cancelled ? nil : replacement, replacementStartMinutes: kind == .cancelled ? nil : sm, replacementEndMinutes: kind == .cancelled ? nil : em, replacementWeekday: kind == .cancelled ? nil : calendar.component(.weekday, from: replacement)); do { try env.scheduleRepository.save(exception: rule, draft: draft, by: env.session.currentMemberID ?? ""); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct CalendarOverrideList: View {
    @Environment(AppEnvironment.self) private var env
    let semester: SemesterModel
    @Query private var overrides: [CalendarOverrideModel]
    @State private var editing: CalendarOverrideModel?
    @State private var confirmDelete: CalendarOverrideModel?
    private var rules: [CalendarOverrideModel] {
        overrides.filter { $0.semesterID == semester.id }.sorted { $0.date < $1.date }
    }
    var body: some View {
        List {
            if rules.isEmpty {
                ContentUnavailableView("没有校历调整", systemImage: "calendar.badge.plus", description: Text("可添加节假日停课、正常上课或周末按指定星期课表上课。"))
            } else {
                ForEach(rules) { rule in
                    Button { editing = rule } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.kind.localizedName)
                            Text(FamilyFormatters.day.string(from: rule.date)).font(.caption).foregroundStyle(.secondary)
                            if rule.kind == .mappedWeekday, let weekday = rule.mappedWeekday { Text("按\(weekdayTitle(weekday))课表").font(.caption).foregroundStyle(.secondary) }
                            if let note = rule.note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions { Button("删除", role: .destructive) { confirmDelete = rule } }
                }
            }
        }
        .navigationTitle("校历调整")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { editing = CalendarOverrideModel(semesterID: semester.id, date: .now, kind: .holiday) } label: { Image(systemName: "plus") } } }
        .sheet(item: $editing) { rule in NavigationStack { CalendarOverrideEditor(semester: semester, rule: rule) } }
        .confirmationDialog("删除此校历调整？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let rule = confirmDelete { do { try env.scheduleRepository.delete(calendarOverride: rule, by: env.session.currentMemberID ?? "") } catch { env.lastError = error.localizedDescription } }; confirmDelete = nil }
        }
    }
    private func weekdayTitle(_ weekday: Int) -> String { ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][weekday - 1] }
}

private struct CalendarOverrideEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    let semester: SemesterModel
    let rule: CalendarOverrideModel
    @State private var date = Date()
    @State private var kind: CalendarOverrideKind = .holiday
    @State private var weekday = 2
    @State private var note = ""
    @State private var error: String?
    private let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
    var body: some View {
        Form {
            DatePicker("日期", selection: $date, displayedComponents: .date)
            Picker("类型", selection: $kind) { ForEach(CalendarOverrideKind.allCases, id: \.self) { Text($0.localizedName).tag($0) } }
            if kind == .mappedWeekday { Picker("按哪天课表", selection: $weekday) { ForEach(1...7, id: \.self) { Text(weekdays[$0 - 1]).tag($0) } } }
            TextField("备注（可选）", text: $note, axis: .vertical)
            Text("优先级：课程单独停课或调课 > 校历调整 > 正常周期课表。 ").font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("校历调整")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .onAppear { date = rule.date; kind = rule.kind; weekday = rule.mappedWeekday ?? 2; note = rule.note ?? "" }
        .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
    }
    private func save() {
        let draft = CalendarOverrideDraft(date: date, kind: kind, mappedWeekday: kind == .mappedWeekday ? weekday : nil, note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note)
        do { try env.scheduleRepository.save(calendarOverride: rule, draft: draft, by: env.session.currentMemberID ?? ""); dismiss() } catch let err { error = err.localizedDescription }
    }
}

private struct SemesterManagerView: View {
    @Environment(AppEnvironment.self) private var env; @Query private var semesters: [SemesterModel]; @State private var editing: SemesterModel?
    private var sorted: [SemesterModel] { semesters.sorted { $0.isCurrent != $1.isCurrent ? $0.isCurrent : $0.week1StartDate > $1.week1StartDate } }
    var body: some View { List { ForEach(sorted) { semester in Button { editing = semester } label: { HStack { VStack(alignment: .leading) { Text(semester.name); let range = semester.firstWeekRange(); Text("第 1 周：\(FamilyFormatters.day.string(from: range.start)) ～ \(FamilyFormatters.day.string(from: range.end)) · \(semester.totalWeeks) 周").font(.caption).foregroundStyle(.secondary) }; Spacer(); if semester.isCurrent { Text("当前").font(.caption).foregroundStyle(.tint) } else { Text("可编辑后设为当前").font(.caption).foregroundStyle(.secondary) } } }.buttonStyle(.plain).accessibilityLabel("编辑学期 \(semester.name)").swipeActions { if !semester.isCurrent { Button("设为当前") { setCurrent(semester) }.tint(.blue) } } } }.navigationTitle("学期管理").toolbar { Button { let calendar = Calendar.autoupdatingCurrent; let start = calendar.startOfDay(for: .now); editing = SemesterModel(name: "", week1StartDate: start, week1EndDate: calendar.date(byAdding: .day, value: 6, to: start), totalWeeks: 18, isCurrent: semesters.isEmpty) } label: { Image(systemName: "plus") } }.sheet(item: $editing) { SemesterEditor(semester: $0) } }
    private func setCurrent(_ selected: SemesterModel) {
        do { try env.semesterRepository.setCurrent(selected, by: env.session.currentMemberID ?? "") }
        catch { env.lastError = error.localizedDescription }
    }
}

private struct SemesterEditor: View {
    @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env; let semester: SemesterModel; @State private var name = ""; @State private var start = Date(); @State private var end = Date(); @State private var weeks = 18; @State private var current = false; @State private var error: String?
    var body: some View { Form { TextField("学期名称", text: $name); Section("第一周日期范围") { DatePicker("第一周开始", selection: $start, displayedComponents: .date); DatePicker("第一周结束", selection: $end, in: start..., displayedComponents: .date); Text("第一周按你设置的开始和结束日期计算；第 2 周从结束日期的下一天开始，之后每周固定 7 天。 ").font(.caption).foregroundStyle(.secondary) }; Stepper("总周数：\(weeks)", value: $weeks, in: 1...52); Toggle("设为当前学期", isOn: $current) }.navigationTitle("学期").toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }.onAppear { let range = semester.firstWeekRange(); name = semester.name; start = range.start; end = range.end; weeks = semester.totalWeeks; current = semester.isCurrent }.alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") } }
    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "请填写学期名称。"
            return
        }
        let calendar = Calendar.autoupdatingCurrent
        let normalizedStart = calendar.startOfDay(for: start)
        let normalizedEnd = calendar.startOfDay(for: end)
        guard normalizedEnd >= normalizedStart else {
            error = "第一周结束日期不能早于开始日期。"
            return
        }
        do {
            try env.semesterRepository.save(
                semester,
                name: name,
                week1StartDate: normalizedStart,
                week1EndDate: normalizedEnd,
                totalWeeks: weeks,
                isCurrent: current,
                by: env.session.currentMemberID ?? ""
            )
            dismiss()
        } catch let failure {
            error = failure.localizedDescription
        }
    }
}

struct FamilyMapView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \LocationSnapshotModel.timestamp, order: .reverse) private var snapshots: [LocationSnapshotModel]; @Query private var places: [FamilyPlaceModel]; @Query private var statuses: [MemberStatusModel]; @Query private var profiles: [MemberProfile]
    @Binding var routedIntent: FamilyIntentRoute?
    @State private var position = MapCameraPosition.region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: FamilyMapDefaults.initialCenter.latitude, longitude: FamilyMapDefaults.initialCenter.longitude), span: MKCoordinateSpan(latitudeDelta: 0.14, longitudeDelta: 0.14)))
    @State private var visibleMembers: Set<String> = []
    @State private var showingFullscreen = false
    @State private var showingMapPanel = false
    @State private var selectedMarkerID: UUID?
    @State private var selectedMemberID: String?
    @State private var selectedPlaceID: UUID?
    @State private var safetyStatus: SafetyStatus = .allGood
    @State private var estimatedArrival = Date()
    @State private var hasInitializedMapState = false
    private var availableMemberIDs: [String] { MemberDirectory.activeMembers(from: profiles).map(\.memberID) }
    private var visiblePlaces: [FamilyPlaceModel] {
        let activeIDs = Set(availableMemberIDs)
        return places.filter { $0.memberID == nil || activeIDs.contains($0.memberID!) }
    }
    var latest: [LocationSnapshotModel] { availableMemberIDs.compactMap { memberID in snapshots.first(where: { $0.memberID == memberID }) } }
    private var recentSnapshots: [LocationSnapshotModel] {
        let cutoff = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
        return snapshots.filter { $0.timestamp >= cutoff }
    }
    private var selectedPlace: FamilyPlaceModel? {
        selectedPlaceID.flatMap { identifier in visiblePlaces.first(where: { $0.id == identifier }) }
    }
    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Map(position: $position, selection: $selectedMarkerID) { mapContent }
                    .mapControls { MapCompass(); MapPitchToggle() }
                    .accessibilityLabel("家庭位置地图，可缩放、拖动和点选标记")
                memberFilter
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                if env.automaticLocationService.isPermissionUnavailable {
                    locationPermissionOverlay
                        .padding(.horizontal, 20)
                        .padding(.top, 68)
                }
            }
            .navigationTitle("地图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Text("本地位置").font(.caption).foregroundStyle(.secondary) }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingMapPanel = true } label: { Image(systemName: "person.2.crop.square.stack") }
                        .accessibilityLabel("查看成员状态、历史与地点")
                    Button { showingFullscreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .accessibilityLabel("全屏查看地图")
                }
            }
            .sheet(isPresented: $showingMapPanel) { NavigationStack { mapPanel } .presentationDetents([.fraction(0.45), .large]) }
            .fullScreenCover(isPresented: $showingFullscreen) { FullscreenFamilyMap(position: $position, visibleMembers: $visibleMembers, latest: latest, places: visiblePlaces) }
            .onAppear { initializeMapStateIfNeeded(); syncCurrentMemberState(); env.setMapLocationTrackingActive(true); handleIntentRoute() }
            .onDisappear { env.setMapLocationTrackingActive(false) }
            .onChange(of: routedIntent) { _, _ in handleIntentRoute() }
            .onChange(of: env.session.currentMemberID) { _, _ in syncCurrentMemberState() }
            .onChange(of: availableMemberIDs) { _, values in
                visibleMembers.formIntersection(Set(values))
                if visibleMembers.isEmpty { visibleMembers = Set(values) }
                if let selectedMemberID, !values.contains(selectedMemberID) { self.selectedMemberID = nil }
            }
            .onChange(of: latest.map(\.id)) { _, _ in refreshSelectedSnapshot() }
            .onChange(of: selectedMarkerID) { _, identifier in selectMarker(identifier) }
        }
    }

    private var memberFilter: some View {
        HStack(spacing: 6) {
            ForEach(availableMemberIDs, id: \.self) { memberID in
                Button { selectMember(memberID) } label: {
                    MemberChip(memberID: memberID, isSelected: selectedMemberID == memberID)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换到 \(displayName(for: memberID)) 的位置")
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }

    private var mapPanel: some View {
        List {
            Section(selectedPlace == nil ? "成员实时位置" : "家庭地点") {
                if let selectedPlace {
                    placeSummary(selectedPlace)
                } else if let memberID = selectedMemberID ?? env.session.currentMemberID {
                    memberSummary(memberID)
                } else {
                    ContentUnavailableView("请选择成员", systemImage: "person.crop.circle")
                }
            }
            if let current = env.session.currentMemberID {
                Section("我的状态") {
                    Picker("状态", selection: $safetyStatus) { ForEach(SafetyStatus.allCases, id: \.self) { Text($0.localizedName).tag($0) } }
                    if safetyStatus == .headingHome { DatePicker("预计到家", selection: $estimatedArrival, displayedComponents: .hourAndMinute) }
                    Button("更新报平安") { reportSafetyStatus(current) }
                        .accessibilityHint("仅更新当前成员的本地状态，不发送聊天消息")
                }
            }
            Section("位置共享") {
                Button("立即更新我的位置") { env.requestImmediateLocationUpdate() }
                    .accessibilityHint("使用当前成员的设备位置；仅写入本机位置历史")
                Text("自动共享在“设置”中开启。位置历史仅保留最近 30 天。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("成员地点") {
                ForEach(visiblePlaces) { place in
                    NavigationLink { FamilyPlaceEditor(place: place) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                            Text("\(place.memberID.map(displayName(for:)) ?? "共享") · \(place.kind.localizedName) · \(Int(place.radius)) 米 · \(place.isEnabled ?? true ? "启用" : "停用")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink { FamilyPlaceEditor(place: FamilyPlaceModel(name: "", kind: .custom, latitude: FamilyMapDefaults.initialCenter.latitude, longitude: FamilyMapDefaults.initialCenter.longitude, radius: 200, memberID: env.session.currentMemberID)) } label: {
                    Label("新建成员地点", systemImage: "plus")
                }
            }
            Section("最近 30 天位置历史") {
                if recentSnapshots.isEmpty { ContentUnavailableView("没有位置历史", systemImage: "clock.arrow.circlepath") }
                ForEach(recentSnapshots) { item in
                    Button { focus(item.latitude, item.longitude); selectedMemberID = item.memberID; showingMapPanel = false } label: {
                        HStack { MemberLabel(memberID: item.memberID); Spacer(); Text(FamilyRelativeTime.locationUpdated(at: item.timestamp)).font(.caption).foregroundStyle(.secondary) }
                    }.foregroundStyle(.primary)
                }
            }
        }
        .navigationTitle("成员位置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func memberSummary(_ memberID: String) -> some View {
        let state = statuses.first(where: { $0.memberID == memberID })
        let snapshot = latest.first(where: { $0.memberID == memberID })
        let place = currentPlace(for: memberID)
        return VStack(alignment: .leading, spacing: 6) {
            HStack { MemberLabel(memberID: memberID); Spacer(); Label(state?.status.localizedName ?? SafetyStatus.allGood.localizedName, systemImage: state?.status.symbol ?? SafetyStatus.allGood.symbol).font(.caption) }
            if let snapshot {
                Text("更新于 \(FamilyRelativeTime.locationUpdated(at: snapshot.timestamp))").font(.caption).foregroundStyle(.secondary)
                let precision = snapshot.horizontalAccuracy.map { " · ±\(Int($0.rounded())) 米" } ?? ""
                Text("\(snapshot.source.localizedName)定位\(precision)").font(.caption).foregroundStyle(.secondary)
                if let event = snapshot.event { Text(localizedLocationEvent(event)).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("暂无实时位置").font(.caption).foregroundStyle(.secondary)
            }
            if let place {
                Text("附近家庭地点：\(place.name)").font(.caption).foregroundStyle(.secondary)
            }
            if let arrival = state?.estimatedArrival { Text("预计 \(FamilyFormatters.time.string(from: arrival)) 到家").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func placeSummary(_ place: FamilyPlaceModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(place.name).font(.headline)
            Text("\(place.memberID.map(displayName(for:)) ?? "共享") · \(place.kind.localizedName) · \(Int(place.radius)) 米")
                .font(.caption).foregroundStyle(.secondary)
            Text("这是家庭地点，不代表成员的实时位置。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var locationPermissionOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("位置权限未开启", systemImage: "location.slash")
                .font(.subheadline.weight(.semibold))
            Text("仍会显示已保存的位置和家庭地点。请在系统设置中允许位置权限后再更新当前位置。")
                .font(.caption).foregroundStyle(.secondary)
            Button("前往系统设置", action: openLocationSettings)
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
    private func displayName(for memberID: String) -> String { profiles.first(where: { $0.memberID == memberID })?.displayName ?? memberID }
    private func reportSafetyStatus(_ memberID: String) { do { try env.locationRepository.saveStatus(memberID: memberID, status: safetyStatus, estimatedArrival: safetyStatus == .headingHome ? estimatedArrival : nil, by: memberID) } catch { env.lastError = error.localizedDescription } }
    private func handleIntentRoute() {
        guard let route = routedIntent,
              let currentMemberID = env.session.currentMemberID else { return }
        switch route {
        case .reportLocation:
            env.requestImmediateLocationUpdate()
            routedIntent = nil
        case .reportSafety:
            safetyStatus = .allGood
            reportSafetyStatus(currentMemberID)
            routedIntent = nil
        default:
            routedIntent = nil
        }
    }
    private func syncCurrentMemberState() {
        guard let currentMemberID = env.session.currentMemberID else { return }
        guard let saved = statuses.first(where: { $0.memberID == currentMemberID }) else { return }
        safetyStatus = saved.status
        if let arrival = saved.estimatedArrival { estimatedArrival = arrival }
    }
    private func initializeMapStateIfNeeded() {
        guard !hasInitializedMapState else { return }
        visibleMembers = Set(availableMemberIDs)
        selectedMemberID = env.session.currentMemberID.flatMap { availableMemberIDs.contains($0) ? $0 : nil }
        selectedPlaceID = nil
        hasInitializedMapState = true
    }
    private func refreshSelectedSnapshot() {
        guard let selectedMemberID,
              let snapshot = latest.first(where: { $0.memberID == selectedMemberID }) else { return }
        selectedMarkerID = snapshot.id
    }
    private func openLocationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    private func focus(_ latitude: Double, _ longitude: Double) { position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03))) }
    private func localizedLocationEvent(_ value: String) -> String { value.replacingOccurrences(of: "arrive", with: "到达").replacingOccurrences(of: "leave", with: "离开") }
    private func currentPlace(for memberID: String) -> FamilyPlaceModel? {
        guard let snapshot = latest.first(where: { $0.memberID == memberID }) else { return nil }
        let current = CLLocation(latitude: snapshot.latitude, longitude: snapshot.longitude)
        return visiblePlaces
            .filter { ($0.isEnabled ?? true) && ($0.memberID == nil || $0.memberID == memberID) }
            .first { current.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= $0.radius }
    }
    @MapContentBuilder private var mapContent: some MapContent { ForEach(latest.filter { visibleMembers.contains($0.memberID) }) { item in Annotation(displayName(for: item.memberID), coordinate: CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude), anchor: .bottom) { VStack(spacing: 2) { MemberAvatar(memberID: item.memberID, size: 32); Image(systemName: "triangle.fill").font(.caption2).foregroundStyle(MemberIdentity.color(for: item.memberID)) }.contentShape(Rectangle()).onTapGesture { selectMember(item.memberID) }.accessibilityLabel("\(displayName(for: item.memberID))的位置标记") }.tag(item.id) }; ForEach(visiblePlaces.filter { ($0.isEnabled ?? true) && ($0.memberID == nil || visibleMembers.contains($0.memberID!)) }) { place in Marker(place.name, systemImage: "mappin.circle", coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)).tint(.orange).tag(place.id) } }
    private func selectMember(_ memberID: String) {
        visibleMembers = [memberID]
        selectedMemberID = memberID
        selectedPlaceID = nil
        if let snapshot = latest.first(where: { $0.memberID == memberID }) {
            selectedMarkerID = snapshot.id
            focus(snapshot.latitude, snapshot.longitude)
        }
        showingMapPanel = true
    }
    private func selectMarker(_ identifier: UUID?) {
        guard let identifier else { return }
        if let snapshot = latest.first(where: { $0.id == identifier }) {
            selectedMemberID = snapshot.memberID
            selectedPlaceID = nil
            visibleMembers = [snapshot.memberID]
            focus(snapshot.latitude, snapshot.longitude)
            showingMapPanel = true
        } else if let place = visiblePlaces.first(where: { $0.id == identifier }) {
            selectedMemberID = nil
            selectedPlaceID = place.id
            focus(place.latitude, place.longitude)
            showingMapPanel = true
        }
    }
}

private struct FullscreenFamilyMap: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [MemberProfile]
    @Binding var position: MapCameraPosition
    @Binding var visibleMembers: Set<String>
    let latest: [LocationSnapshotModel]
    let places: [FamilyPlaceModel]
    @State private var selection: UUID?
    var body: some View {
        NavigationStack {
            Map(position: $position, selection: $selection) {
                ForEach(latest.filter { visibleMembers.contains($0.memberID) }) { item in
                    Marker(displayName(for: item.memberID), coordinate: CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude))
                        .tint(MemberIdentity.color(for: item.memberID))
                        .tag(item.id)
                }
                ForEach(places.filter { ($0.isEnabled ?? true) && ($0.memberID == nil || visibleMembers.contains($0.memberID!)) }) { place in
                    Marker(place.name, systemImage: "mappin.circle", coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude))
                        .tint(.orange)
                        .tag(place.id)
                }
            }
            .mapControls { MapCompass(); MapPitchToggle() }
            .safeAreaInset(edge: .bottom) {
                if let selection, let item = latest.first(where: { $0.id == selection }) {
                    HStack { MemberLabel(memberID: item.memberID); Spacer(); Text("更新于 \(FamilyRelativeTime.locationUpdated(at: item.timestamp))").font(.caption) }
                        .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
                } else if let selection, let place = places.first(where: { $0.id == selection }) {
                    HStack { Text(place.name); Spacer(); Text("\(place.memberID.map(displayName(for:)) ?? "共享") · \(Int(place.radius)) 米").font(.caption) }
                        .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
                }
            }
            .navigationTitle("地图全屏查看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .accessibilityLabel("可缩放、拖动和点选标记的家庭地图")
        }
    }
    private func displayName(for memberID: String) -> String { profiles.first(where: { $0.memberID == memberID })?.displayName ?? memberID }
}

private struct FamilyPlaceEditor: View {
    @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env; @Query private var profiles: [MemberProfile]; let place: FamilyPlaceModel
    @State private var name = ""; @State private var kind: PlaceKind = .custom; @State private var memberID = ""; @State private var latitude = ""; @State private var longitude = ""; @State private var radius = 200; @State private var enabled = true; @State private var choosingCoordinate = false
    private var memberIDs: [String] { MemberDirectory.activeMembers(from: profiles).map(\.memberID) }
    var body: some View { Form { Picker("成员", selection: $memberID) { ForEach(memberIDs, id: \.self) { MemberLabel(memberID: $0).tag($0) } }; TextField("名称", text: $name); Picker("类型", selection: $kind) { ForEach(PlaceKind.allCases.filter { $0 != .company }, id: \.self) { Text($0.localizedName).tag($0) } }; TextField("纬度", text: $latitude).keyboardType(.numbersAndPunctuation); TextField("经度", text: $longitude).keyboardType(.numbersAndPunctuation); Button("在地图上选点 / 微调") { choosingCoordinate = true }; Picker("范围", selection: $radius) { ForEach([100, 200, 500, 1000], id: \.self) { Text("\($0) 米").tag($0) } }; Toggle("启用", isOn: $enabled); Text("每位成员只能同时启用一个家和一个学校；自定义地点可多个。 ").font(.caption).foregroundStyle(.secondary) }.navigationTitle("成员地点").toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }.onAppear { name = place.name; kind = place.kind; memberID = [place.memberID, env.session.currentMemberID, memberIDs.first].compactMap { $0 }.first(where: { memberIDs.contains($0) }) ?? ""; latitude = String(place.latitude); longitude = String(place.longitude); radius = Int(place.radius); enabled = place.isEnabled ?? true }.sheet(isPresented: $choosingCoordinate) { CoordinatePicker(latitude: Double(latitude) ?? place.latitude, longitude: Double(longitude) ?? place.longitude) { coordinate in latitude = String(format: "%.6f", coordinate.latitude); longitude = String(format: "%.6f", coordinate.longitude) } } }
    private func save() {
        guard let lat = Double(latitude), let lng = Double(longitude), memberIDs.contains(memberID) else {
            env.lastError = "请输入有效坐标和成员。"
            return
        }
        let draft = FamilyPlaceDraft(name: name, kind: kind, memberID: memberID, latitude: lat, longitude: lng, radius: radius, isEnabled: enabled)
        do { try env.locationRepository.save(place, draft: draft, by: env.session.currentMemberID ?? ""); dismiss() }
        catch { env.lastError = error.localizedDescription }
    }
}

private struct CoordinatePicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition
    @State private var coordinate: CLLocationCoordinate2D
    @State private var cameraCenter: CLLocationCoordinate2D
    let onPick: (CLLocationCoordinate2D) -> Void
    init(latitude: Double, longitude: Double, onPick: @escaping (CLLocationCoordinate2D) -> Void) {
        let value = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        _coordinate = State(initialValue: value)
        _cameraCenter = State(initialValue: value)
        _position = State(initialValue: .region(MKCoordinateRegion(center: value, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))))
        self.onPick = onPick
    }
    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $position) { Marker("地点", coordinate: coordinate).tint(.orange) }
                    .simultaneousGesture(SpatialTapGesture().onEnded { value in if let coordinate = proxy.convert(value.location, from: .local) { self.coordinate = coordinate } })
                    .onMapCameraChange(frequency: .continuous) { context in cameraCenter = context.region.center }
                    .onLongPressGesture { coordinate = cameraCenter }
                    .accessibilityLabel("点选地图设置地点；拖动地图微调后长按可将地图中心设为地点")
            }
            .navigationTitle("点选地点")
            .safeAreaInset(edge: .bottom) { Text("点选设置；拖动地图微调后长按，将中心设为地点。 ").font(.caption).padding(8).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 6) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("确定") { onPick(coordinate); dismiss() } }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}
struct MoreView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View { NavigationStack { List {
        Section("家庭") {
            if env.runtimeMode == .remoteSync, let registrationFlow = env.registrationFlow {
                NavigationLink { FamilyMembersView(flow: registrationFlow) } label: { Label("家庭成员", systemImage: "person.3") }
            } else {
                NavigationLink { LocalFamilyDirectoryView() } label: { Label("家庭成员", systemImage: "person.3") }
            }
            NavigationLink { NoticeListView() } label: { Label("公告", systemImage: "megaphone") }
            NavigationLink { MemoListView() } label: { Label("备忘录", systemImage: "note.text") }
            NavigationLink { AgendaView() } label: { Label("日程与点菜", systemImage: "fork.knife") }
        }
        Section("其他家庭内容") {
            NavigationLink { GlobalSearchView() } label: { Label("全局搜索", systemImage: "magnifyingglass") }
        }
        Section("时间与数据") {
            NavigationLink { ScheduleImportLauncherView() } label: { Label("课表导入", systemImage: "square.and.arrow.down") }
            NavigationLink { CalendarOverrideHubView() } label: { Label("校历调整", systemImage: "calendar.badge.plus") }
            NavigationLink { DataHealthView() } label: { Label("数据健康检查", systemImage: "checklist") }
            NavigationLink { BackupRestoreView() } label: { Label("本地备份与恢复", systemImage: "externaldrive") }
        }
        Section("设置") { NavigationLink { SettingsView() } label: { Label("设置", systemImage: "gearshape") } }
    }.navigationTitle("更多") } }
}

/// The local-only mode has no remote approval controls, but the same member
/// directory remains discoverable without introducing another member model.
private struct LocalFamilyDirectoryView: View {
    @Query(sort: \MemberProfile.nickname) private var profiles: [MemberProfile]

    var body: some View {
        List {
            Section("成员") {
                ForEach(profiles) { profile in
                    HStack(spacing: 10) {
                        MemberAvatar(memberID: profile.memberID, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                            Text(profile.isInitialMember == true ? "初始成员" : "家庭成员")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("家庭成员")
    }
}

private struct ScheduleImportLauncherView: View {
    @Query private var semesters: [SemesterModel]
    private var currentSemester: SemesterModel? { semesters.first(where: \.isCurrent) }

    var body: some View {
        Group {
            if let currentSemester {
                ScheduleImportView(semester: currentSemester)
            } else {
                ContentUnavailableView("没有当前学期", systemImage: "calendar.badge.exclamationmark", description: Text("请先在课表页创建并设为当前学期。"))
            }
        }
        .navigationTitle("课表导入")
    }
}

private struct CalendarOverrideHubView: View {
    @Query private var semesters: [SemesterModel]
    private var currentSemester: SemesterModel? { semesters.first(where: \.isCurrent) }

    var body: some View {
        Group {
            if let currentSemester {
                CalendarOverrideList(semester: currentSemester)
            } else {
                ContentUnavailableView("没有当前学期", systemImage: "calendar.badge.exclamationmark", description: Text("请先在课表页创建并设为当前学期。"))
            }
        }
        .navigationTitle("校历调整")
    }
}

private struct BackupRestoreView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var exportDocument: LocalBackupDocument?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var preview: BackupPreview?
    @State private var pendingArchive: FamilyBackupArchive?
    @State private var error: String?

    var body: some View {
        List {
            Section("本地业务数据") {
                Button("导出备份", action: beginExport)
                Button("从备份恢复", action: { isImporting = true })
            }
            Section("备份范围") {
                Text("包含成员档案、课表、日程、备忘录、公告、位置和成员地点。")
                Text("导出的 JSON 含有课表、日程与位置等私人家庭数据；请仅存放在可信位置。")
                    .font(.caption).foregroundStyle(.orange)
                Text("不包含 API Key、登录凭证、聊天记录、本地图片/语音和临时缓存。恢复会替换上述业务数据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("本地备份与恢复")
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .json, defaultFilename: "familyapp-backup") { result in
            if case let .failure(caughtError) = result { error = "导出备份失败：\(caughtError.localizedDescription)" }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            guard case let .success(url) = result else {
                if case let .failure(caughtError) = result { error = "读取备份失败：\(caughtError.localizedDescription)" }
                return
            }
            loadPreview(from: url)
        }
        .sheet(item: $preview) { value in
            BackupPreviewSheet(preview: value, restore: restorePendingArchive)
        }
        .alert("备份与恢复", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
    }

    private func beginExport() {
        do {
            exportDocument = LocalBackupDocument(archive: try LocalBackupService(context: env.context).exportArchive())
            isExporting = true
        } catch { self.error = error.localizedDescription }
    }

    private func loadPreview(from url: URL) {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        Task { @MainActor [url, hasSecurityScope] in
            defer { if hasSecurityScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let archive = try await Task.detached(priority: .userInitiated) {
                    try JSONDecoder().decode(FamilyBackupArchive.self, from: Data(contentsOf: url))
                }.value
                pendingArchive = archive
                preview = try LocalBackupService(context: env.context).preview(archive)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func restorePendingArchive() {
        guard let pendingArchive else { return }
        do {
            try LocalBackupService(context: env.context).restore(pendingArchive)
            self.pendingArchive = nil
            env.refreshToken = UUID()
        } catch { self.error = error.localizedDescription }
    }
}

private struct BackupPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preview: BackupPreview
    let restore: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("备份信息") {
                    LabeledContent("导出时间", value: FamilyFormatters.dateTime.string(from: preview.exportedAt))
                    LabeledContent("格式版本", value: "v\(preview.schemaVersion)")
                    LabeledContent("备份记录", value: "\(preview.recordCount) 条")
                    LabeledContent("将替换现有记录", value: "\(preview.replacementCount) 条")
                }
                Section("内容") { ForEach(preview.summaries, id: \.self) { Text($0) } }
                Section { Text("已先完成重复 ID、关联关系、成员与课程范围校验。确认后会以单次本地保存提交；失败时回滚当前上下文。") .font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("恢复前预览")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("确认恢复", role: .destructive) { restore(); dismiss() } }
            }
        }
    }
}

private struct GlobalSearchView: View {
    @Query private var schedules: [ScheduleEntryModel]
    @Query private var agendas: [AgendaItemModel]
    @Query private var memos: [MemoModel]
    @Query private var notices: [NoticeModel]
    @Query private var places: [FamilyPlaceModel]
    @State private var query = ""

    private var needle: String { query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private func matches(_ values: String?...) -> Bool { !needle.isEmpty && values.compactMap { $0?.lowercased() }.contains { $0.localizedCaseInsensitiveContains(needle) } }
    private var matchingSchedules: [ScheduleEntryModel] { schedules.filter { matches($0.title, $0.location, $0.note, $0.major, $0.grade, $0.className) } }
    private var matchingAgendas: [AgendaItemModel] { agendas.filter { matches($0.title, $0.location, $0.note, $0.dishes) } }
    private var matchingMemos: [MemoModel] { memos.filter { matches($0.title, $0.content) } }
    private var matchingNotices: [NoticeModel] { notices.filter { matches($0.title, $0.content) } }
    private var matchingPlaces: [FamilyPlaceModel] { places.filter { matches($0.name) } }

    var body: some View {
        List {
            if needle.isEmpty { ContentUnavailableView("搜索家庭数据", systemImage: "magnifyingglass", description: Text("可搜索课程、日程、备忘录、公告和地点。")) }
            results("课程", values: matchingSchedules.map { SearchResult(title: $0.title, detail: $0.location ?? "课表") })
            results("日程", values: matchingAgendas.map { SearchResult(title: $0.title, detail: $0.kind.localizedName) })
            results("备忘录", values: matchingMemos.map { SearchResult(title: $0.title?.isEmpty == false ? $0.title! : "无标题", detail: String($0.content.prefix(70))) })
            results("公告", values: matchingNotices.map { SearchResult(title: $0.title, detail: String($0.content.prefix(70))) })
            results("地点", values: matchingPlaces.map { SearchResult(title: $0.name, detail: $0.kind.localizedName) })
        }
        .navigationTitle("全局搜索")
        .searchable(text: $query, prompt: "课程、日程、备忘录、公告、地点")
    }

    @ViewBuilder private func results(_ title: String, values: [SearchResult]) -> some View {
        if !values.isEmpty {
            Section(title) { ForEach(values) { value in VStack(alignment: .leading, spacing: 2) { Text(value.title); Text(value.detail).font(.caption).foregroundStyle(.secondary) } } }
        }
    }
}

private struct SearchResult: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

private struct DataHealthView: View {
    @Query private var semesters: [SemesterModel]
    @Query private var entries: [ScheduleEntryModel]
    @Query private var exceptions: [ScheduleExceptionModel]
    @Query private var agendas: [AgendaItemModel]
    @Query private var agendaExceptions: [AgendaExceptionModel]
    @Query private var places: [FamilyPlaceModel]

    private var issues: [DataHealthIssue] {
        DataHealthService().evaluate(semesters: semesters, entries: entries, scheduleExceptions: exceptions, agendas: agendas, agendaExceptions: agendaExceptions, places: places)
    }

    var body: some View {
        List {
            if issues.isEmpty { ContentUnavailableView("数据状态正常", systemImage: "checkmark.seal", description: Text("未发现明显的本地关联或规则问题。")) }
            else { Section("需要处理") { ForEach(issues) { issue in Label(issue.message, systemImage: issue.symbol).foregroundStyle(issue.severity == .warning ? .orange : .red) } }
            }
            Section("检查范围") { Text("检查课程周次、例外关联、当前学期、成员地点启用规则。不会修改数据。 ").font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("数据健康检查")
    }
}

private struct MemoListView: View {
    @Environment(AppEnvironment.self) private var env; @Query private var memos: [MemoModel]; @Query private var profiles: [MemberProfile]; @State private var editor: MemoModel?
    var sorted: [MemoModel] { memos.sorted { $0.pinned == $1.pinned ? $0.updatedAt > $1.updatedAt : $0.pinned && !$1.pinned } }
    private func displayName(for memberID: String) -> String { profiles.first(where: { $0.memberID == memberID })?.displayName ?? memberID }
    var body: some View { List { ForEach(sorted) { memo in Button { editor = memo } label: { VStack(alignment: .leading) { HStack { Text(memo.title?.isEmpty == false ? memo.title! : memo.content.components(separatedBy: .newlines).first ?? "无标题"); if memo.pinned { Image(systemName: "pin.fill").font(.caption) } }; Text("v\(memo.version) · \(displayName(for: memo.updatedBy))").font(.caption).foregroundStyle(.secondary) } }.foregroundStyle(.primary).swipeActions { if memo.creatorID == env.session.currentMemberID { Button("删除", role: .destructive) { do { try env.memoRepository.delete(memo, by: env.session.currentMemberID ?? "") } catch { env.lastError = error.localizedDescription } } } } } }.navigationTitle("备忘录").toolbar { Button { guard let memberID = env.session.currentMemberID else { return }; editor = MemoModel(content: "", creatorID: memberID, updatedBy: memberID) } label: { Image(systemName: "square.and.pencil") } }.sheet(item: $editor) { MemoEditor(memo: $0) } }
}
private struct MemoEditor: View {
    @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env; let memo: MemoModel; @State private var title = ""; @State private var content = ""; @State private var pinned = false; @State private var expected = 0; @State private var error: String?
    var body: some View { NavigationStack { Form { TextField("标题（可选）", text: $title); TextEditor(text: $content).frame(minHeight: 160); Toggle("置顶", isOn: $pinned); BusinessAIAssistButton(title: "AI 整理备忘录", instruction: "Polish, summarize, expand, or organize the memo according to the request. Return plain text only.", source: content) { content = $0 } }.navigationTitle("备忘录").toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }.onAppear { title = memo.title ?? ""; content = memo.content; pinned = memo.pinned; expected = memo.version }.alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") } } }
    private func save() { let draft = MemoDraft(title: title.isEmpty ? nil : title, content: content, pinned: pinned); do { if memo.modelContext == nil { try env.memoRepository.create(draft: draft, by: env.session.currentMemberID ?? "") } else { try env.memoRepository.save(memo, draft: draft, expectedVersion: expected, by: env.session.currentMemberID ?? "") }; dismiss() } catch { self.error = error.localizedDescription } }
}

private struct NoticeListView: View {
    @Environment(AppEnvironment.self) private var env; @Query private var notices: [NoticeModel]; @Query private var reads: [NoticeReadModel]; @Query private var profiles: [MemberProfile]; @State private var editor: NoticeModel?
    var sorted: [NoticeModel] { notices.sorted { lhs, rhs in lhs.pinned == rhs.pinned ? (lhs.pinned ? lhs.updatedAt > rhs.updatedAt : lhs.createdAt > rhs.createdAt) : lhs.pinned && !rhs.pinned } }
    private func publisherName(for notice: NoticeModel) -> String { profiles.first(where: { $0.memberID == notice.publisherID })?.displayName ?? notice.publisherID }
    var body: some View { List { ForEach(sorted) { notice in NavigationLink { NoticeDetail(notice: notice, reads: reads) } label: { HStack { VStack(alignment: .leading) { Text(notice.title); Text(notice.isEdited ? "\(publisherName(for: notice)) · 已编辑" : publisherName(for: notice)).font(.caption).foregroundStyle(.secondary) }; Spacer(); if notice.pinned { Image(systemName: "pin.fill").font(.caption) }; if notice.publisherID != env.session.currentMemberID && !reads.contains(where: { $0.noticeID == notice.id && $0.memberID == env.session.currentMemberID }) { Text("未读").font(.caption2).foregroundStyle(.blue) } } }.swipeActions { if notice.publisherID == env.session.currentMemberID { Button("删除", role: .destructive) { do { try env.noticeRepository.delete(notice, by: env.session.currentMemberID ?? "") } catch { env.lastError = error.localizedDescription } } } } } }.navigationTitle("公告").toolbar { Button { guard let publisherID = env.session.currentMemberID else { return }; editor = NoticeModel(title: "", content: "", publisherID: publisherID) } label: { Image(systemName: "plus") } }.sheet(item: $editor) { NoticeEditor(notice: $0) } }
}
private struct NoticeDetail: View { @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env; @Query private var profiles: [MemberProfile]; let notice: NoticeModel; let reads: [NoticeReadModel]; @State private var editor: NoticeModel?; @State private var confirmDelete = false
    private var canEdit: Bool { notice.publisherID == env.session.currentMemberID }
    private var memberIDs: [String] { MemberDirectory.allMembersIncludingHistory(from: profiles).map(\.memberID) }
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 14) { Text(notice.title).font(.title2.bold()); Text(notice.content); if notice.isEdited { Text("已编辑").font(.caption).foregroundStyle(.secondary) }; if canEdit { Divider(); Text("阅读情况").font(.subheadline.weight(.semibold)); ForEach(memberIDs, id: \.self) { memberID in if memberID != notice.publisherID { let read = reads.first { $0.noticeID == notice.id && $0.memberID == memberID }; HStack { MemberLabel(memberID: memberID); Spacer(); Text(read.map { FamilyFormatters.dateTime.string(from: $0.readAt) } ?? "未读").font(.caption).foregroundStyle(read == nil ? .blue : .secondary) } } } } }.frame(maxWidth: .infinity, alignment: .leading).padding() }.navigationTitle("公告").toolbar { if canEdit { ToolbarItemGroup(placement: .topBarTrailing) { Button("编辑") { editor = notice }; Button("删除", role: .destructive) { confirmDelete = true } } } }.sheet(item: $editor) { NoticeEditor(notice: $0) }.confirmationDialog("删除公告？", isPresented: $confirmDelete, titleVisibility: .visible) { Button("删除", role: .destructive) { do { try env.noticeRepository.delete(notice, by: env.session.currentMemberID ?? ""); dismiss() } catch { env.lastError = error.localizedDescription } } }.onAppear { do { try env.noticeRepository.markRead(notice, memberID: env.session.currentMemberID ?? "") } catch { env.lastError = error.localizedDescription } } }
}
private struct NoticeEditor: View { @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env; let notice: NoticeModel; @State private var title = ""; @State private var content = ""; @State private var pinned = false
    var body: some View { NavigationStack { Form { TextField("标题", text: $title); TextEditor(text: $content).frame(minHeight: 160); Toggle("置顶", isOn: $pinned); BusinessAIAssistButton(title: "AI 辅助撰写", instruction: "Draft a concise family notice from the input. Return plain text only.", source: "\(title)\n\(content)") { content = $0 } }.navigationTitle("发布公告").toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { do { let draft = NoticeDraft(title: title, content: content, pinned: pinned); if notice.modelContext == nil { try env.noticeRepository.create(draft: draft, by: env.session.currentMemberID ?? "") } else { try env.noticeRepository.save(notice, draft: draft, by: env.session.currentMemberID ?? "") }; dismiss() } catch { env.lastError = error.localizedDescription } } }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }.onAppear { title = notice.title; content = notice.content; pinned = notice.pinned } } }
}

private struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env; @Query private var profiles: [MemberProfile]; @AppStorage(AppearancePreference.followSystemKey) private var followSystem = true; @AppStorage(AppearancePreference.darkModeKey) private var darkMode = false; @AppStorage(LocationSharingPreference.enabledKey) private var locationSharingEnabled = false; @AppStorage("ai.enabled") private var enabled = false; @AppStorage("ai.contents") private var allowContent = false; @AppStorage("ai.baseURL") private var baseURL = ""; @AppStorage("ai.model") private var model = ""; @State private var apiKey = ""; @State private var testResult: String?; @State private var showClear = false; @State private var showClearKey = false; @State private var profileEditor: MemberProfile?
    var body: some View { Form { Section("个人资料") { if let profile = profiles.first(where: { $0.memberID == env.session.currentMemberID }) { Button { profileEditor = profile } label: { HStack { Image(systemName: profile.avatarSymbol ?? "person.crop.circle.fill").font(.title3); VStack(alignment: .leading) { Text(profile.nickname); Text(profile.memberID).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) } }.foregroundStyle(.primary) } }
        Section("外观") {
            Toggle("跟随系统", isOn: $followSystem)
            if !followSystem {
                Toggle("深色模式", isOn: $darkMode)
            }
        }
        Section("通知设置") { Toggle("本地通知开关（未接入 APNs）", isOn: .constant(false)).disabled(true) }
        Section("定位设置") {
            Toggle("共享我的位置", isOn: Binding(get: { locationSharingEnabled }, set: { enabled in
                locationSharingEnabled = enabled
                env.refreshLocationSharing()
            }))
            Text("开启后使用系统低功耗定位；地图查看时会临时提高更新频率。")
                .font(.caption).foregroundStyle(.secondary)
            if let message = env.locationPermissionMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        if env.runtimeMode == .remoteSync,
           let registrationFlow = env.registrationFlow,
           registrationFlow.canManageDevices {
            Section("账户与安全") {
                NavigationLink { LoggedInDevicesView(flow: registrationFlow) } label: {
                    Label("已登录设备", systemImage: "desktopcomputer.and.iphone")
                }
            }
        }
        Section("AI 设置") { Toggle("启用 AI", isOn: $enabled); Toggle("允许业务内容发送 AI", isOn: $allowContent).disabled(!enabled); TextField("Base URL", text: $baseURL).textInputAutocapitalization(.never).keyboardType(.URL); SecureField("API Key（Keychain）", text: $apiKey); TextField("Model", text: $model); Button("保存 API Key") { do { try env.keychain.saveAPIKey(apiKey); apiKey = ""; testResult = "已保存到 Keychain。" } catch { testResult = error.localizedDescription } }; Button("清除 API Key", role: .destructive) { showClearKey = true }; Button("验证连接") { testAIConnection() }; if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }; Text("默认采用本地算法；AI 不会自动参与业务。关闭业务内容发送后，AI 仍可仅处理你手工输入的文字；聊天和地图不会发送给 AI。 ").font(.footnote).foregroundStyle(.secondary) }
        if env.runtimeMode == .remoteSync, let recoveryFlow = env.recoveryFlow { Section("账户恢复") { NavigationLink { RecoverySetupView(flow: recoveryFlow) } label: { Label("恢复助记词", systemImage: "key.horizontal") }; Text("助记词只在生成时展示；服务器只保存独立验证器。") .font(.caption).foregroundStyle(.secondary) } }
        else { Section("账户恢复") { Text("当前为本地模式；远端同步启用后才可设置恢复助记词。") .font(.caption).foregroundStyle(.secondary) } }
        Section("关于") {
            Text("本地 SwiftUI / SwiftData 家庭协作")
            #if DEBUG
            Text("调试版本使用本地共享密码。") .font(.caption).foregroundStyle(.secondary)
            #else
            Text("当前版本使用本地账户；远端账户服务尚未启用。") .font(.caption).foregroundStyle(.secondary)
            #endif
        }
        Section { Button("退出登录", role: .destructive) { env.session.logout() } }
        Section("数据管理") {
            #if DEBUG
            Button("恢复初始数据") { env.resetDemo() }
            #endif
            Button("清除全部本地数据", role: .destructive) { showClear = true }
        }
    }.navigationTitle("设置").sheet(item: $profileEditor) { profile in NavigationStack { ProfileEditor(profile: profile) } }.confirmationDialog("清除 API Key？", isPresented: $showClearKey, titleVisibility: .visible) { Button("清除 API Key", role: .destructive) { env.keychain.clear(); testResult = "已清除 Keychain 中的 API Key。" } }.confirmationDialog("清除所有本地数据？", isPresented: $showClear, titleVisibility: .visible) { Button("清除全部本地数据", role: .destructive) { env.clearAllLocalData() } } message: { Text("这会删除 SwiftData、媒体、设置、登录状态和 AI Keychain 内容，无法恢复。") } }
    private func testAIConnection() {
        let service = AIService(keychain: env.keychain)
        let configuredBaseURL = baseURL
        let configuredModel = model
        Task { @MainActor [service, configuredBaseURL, configuredModel] in
            do {
                try await service.testConnection(baseURL: configuredBaseURL, model: configuredModel)
                testResult = "连接成功。"
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}

private struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env; let profile: MemberProfile
    @State private var nickname = ""; @State private var avatar = "person.crop.circle.fill"
    private let choices = ["person.crop.circle.fill", "face.smiling", "figure.2.and.child.holdinghands", "heart.circle.fill"]
    var body: some View { Form { TextField("昵称", text: $nickname); Picker("头像", selection: $avatar) { ForEach(choices, id: \.self) { Image(systemName: $0).tag($0) } } }.navigationTitle("个人资料").toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty else { env.lastError = "昵称不能为空。"; return }; profile.nickname = trimmed; profile.avatarSymbol = avatar; do { try env.context.save(); dismiss() } catch { env.lastError = error.localizedDescription } } }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }.onAppear { nickname = profile.nickname; avatar = profile.avatarSymbol ?? choices[0] } }
}

/// A shared BYOK presentation boundary. The result remains a local draft until
/// the person explicitly presses "应用到草稿"; no repository is called here.
struct BusinessAIAssistButton: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage("ai.enabled") private var enabled = false
    @AppStorage("ai.contents") private var allowContent = false
    @AppStorage("ai.baseURL") private var baseURL = ""
    @AppStorage("ai.model") private var model = ""
    let title: String; let instruction: String; let source: String; let apply: (String) -> Void
    @State private var showing = false
    var body: some View {
        if enabled {
            Button { showing = true } label: { Label(title, systemImage: "sparkles") }
                .accessibilityHint("仅在你主动生成后显示预览，不会直接保存。")
                .sheet(isPresented: $showing) { NavigationStack { AIDraftPreview(title: title, instruction: instruction, source: source, apply: { apply($0); showing = false }) } }
        }
    }
}

private struct AIDraftPreview: View {
    @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env
    @AppStorage("ai.enabled") private var enabled = false
    @AppStorage("ai.contents") private var allowContent = false
    @AppStorage("ai.baseURL") private var baseURL = ""
    @AppStorage("ai.model") private var model = ""
    let title: String; let instruction: String; let source: String; let apply: (String) -> Void
    @State private var request = ""; @State private var result = ""; @State private var isLoading = false; @State private var errorMessage: String?
    var body: some View { Form { Section("请求") { TextEditor(text: $request).frame(minHeight: 90); Text("仅在你点击生成时发送此业务内容；聊天和地图没有 AI 入口。 ").font(.caption).foregroundStyle(.secondary) }; Section("AI 预览") { if isLoading { ProgressView() } else if result.isEmpty { Text("生成结果会在这里出现，确认前不会写入本地数据。 ").foregroundStyle(.secondary) } else { TextEditor(text: $result).frame(minHeight: 180) } } }.navigationTitle(title).toolbar { ToolbarItem(placement: .confirmationAction) { Button(result.isEmpty ? "生成" : "应用到草稿") { if result.isEmpty { generate() } else { apply(result) } }.disabled(isLoading) }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }.alert("AI 不可用", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorMessage ?? "") } }
    private func generate() {
        guard enabled else { errorMessage = "请先在设置中启用 AI。"; return }
        let manual = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowContent || !manual.isEmpty else { errorMessage = "关闭业务内容发送时，请在请求框输入要发送给 AI 的文字。"; return }
        isLoading = true
        let prompt = allowContent ? (manual.isEmpty ? source : "\(source)\n\n用户要求：\(manual)") : manual
        let service = AIService(keychain: env.keychain)
        let configuredBaseURL = baseURL
        let configuredModel = model
        let draftInstruction = instruction
        Task { @MainActor [service, configuredBaseURL, configuredModel, draftInstruction, prompt] in
            do {
                result = try await service.generateBusinessDraft(baseURL: configuredBaseURL, model: configuredModel, instruction: draftInstruction, source: prompt)
            } catch let caughtError {
                errorMessage = caughtError.localizedDescription
            }
            isLoading = false
        }
    }
}
