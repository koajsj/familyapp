import SwiftUI
import SwiftData
import MapKit

private enum ScheduleMode: String, CaseIterable, Identifiable { case personal = "单人", pair = "两人", family = "三人", analysis = "时间分析"; var id: String { rawValue } }

struct ScheduleView: View {
    @Environment(AppEnvironment.self) private var env
    @Query private var semesters: [SemesterModel]
    @Query private var entries: [ScheduleEntryModel]
    @Query private var exceptions: [ScheduleExceptionModel]
    @Query private var calendarOverrides: [CalendarOverrideModel]
    @Query private var agendas: [AgendaItemModel]
    @Query private var agendaExceptions: [AgendaExceptionModel]
    @State private var mode: ScheduleMode = .personal
    @State private var personalMember = MemberID.sendai.rawValue
    @State private var selectedMembers: Set<String> = [MemberID.sendai.rawValue, MemberID.osaka.rawValue]
    @State private var date = Date()
    @State private var showEditor = false
    @State private var showExceptionManager = false
    @State private var showCalendarManager = false
    @State private var showImporter = false
    @State private var minimum = 60
    @State private var analysisEnd = Date()
    @State private var dailyStartHour = 8
    @State private var dailyEndHour = 22
    @State private var proposedSlot: AvailabilitySlot?
    @State private var selectedOccurrence: ScheduleOccurrence?
    private var semester: SemesterModel? { semesters.first(where: \.isCurrent) }
    private var weekStart: Date {
        let calendar = Calendar.autoupdatingCurrent
        let weekday = calendar.component(.weekday, from: date)
        return calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: calendar.startOfDay(for: date)) ?? date
    }
    private var visiblePeople: Set<String> {
        switch mode { case .personal: return [personalMember]; case .pair: return selectedMembers; case .family: return Set(MemberID.allCases.map(\.rawValue)); case .analysis: return [] }
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
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }.accessibilityLabel("导入课表")
                    Button { showEditor = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建课程或组会")
                }
            }
            .sheet(isPresented: $showEditor) { NavigationStack { ScheduleEditor(entry: nil, semester: semester) } }
            .sheet(isPresented: $showExceptionManager) { NavigationStack { ScheduleExceptionList(entries: entries.filter { $0.ownerID == env.session.currentMemberID }) } }
            .sheet(isPresented: $showCalendarManager) { if let semester { NavigationStack { CalendarOverrideList(semester: semester) } } }
            .sheet(isPresented: $showImporter) { if let semester { NavigationStack { ScheduleImportView(semester: semester) } } }
            .sheet(item: $proposedSlot) { slot in NavigationStack { AgendaEditor(item: nil, proposedSlot: slot) } }
            .sheet(item: $selectedOccurrence) { occurrence in
                if let entry = entries.first(where: { $0.id == occurrence.entryID }) { NavigationStack { ScheduleEditor(entry: entry, semester: semester) } }
            }
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
            Picker("成员", selection: $personalMember) { ForEach(MemberID.allCases) { Text($0.rawValue).tag($0.rawValue) } }
        case .pair:
            memberToggles(limit: 2)
        case .family:
            Text("三人聚合：课程块会显示成员。空白格只表示该展示课段没有课程，不等于共同空闲。 ").font(.caption).foregroundStyle(.secondary)
        case .analysis: EmptyView()
        }
    }
    private func memberToggles(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("选择 \(limit) 名成员").font(.caption).foregroundStyle(.secondary)
            HStack { ForEach(MemberID.allCases) { person in
                Toggle(person.rawValue, isOn: Binding(get: { selectedMembers.contains(person.rawValue) }, set: { enabled in
                    if enabled, selectedMembers.count < limit { selectedMembers.insert(person.rawValue) }
                    if !enabled, selectedMembers.count > 1 { selectedMembers.remove(person.rawValue) }
                })).toggleStyle(.button).tint(person.color)
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
        let slots = days.flatMap { day -> [AvailabilitySlot] in
            let start = calendar.date(bySettingHour: dailyStartHour, minute: 0, second: 0, of: day) ?? day
            let end = calendar.date(bySettingHour: dailyEndHour, minute: 0, second: 0, of: day) ?? day
            guard start < end else { return [] }
            return env.timeAnalysis.commonFree(memberIDs: Array(selectedMembers), range: DateInterval(start: start, end: end), minimumMinutes: minimum, entries: entries, exceptions: exceptions, agendas: agendas, agendaExceptions: agendaExceptions, calendarOverrides: calendarOverrides, semester: semester)
        }
        return Group {
            Section("成员与范围") { memberToggles(limit: 3); DatePicker("开始日期", selection: $date, displayedComponents: .date); DatePicker("结束日期", selection: $analysisEnd, in: firstDay..., displayedComponents: .date); Stepper("每日开始：\(dailyStartHour):00", value: $dailyStartHour, in: 0...22); Stepper("每日结束：\(dailyEndHour):00", value: $dailyEndHour, in: 1...23); Stepper("最短连续空闲：\(minimum) 分钟", value: $minimum, in: 30...300, step: 30) }
            Section("共同空闲") {
                if selectedMembers.count < 2 { Text("至少选择两名成员。 ").foregroundStyle(.secondary) }
                else if slots.isEmpty { Text("没有符合条件的共同空闲。 ").foregroundStyle(.secondary) }
                else { ForEach(slots) { slot in HStack { Text("\(FamilyFormatters.day.string(from: slot.start))  \(FamilyFormatters.time.string(from: slot.start))–\(FamilyFormatters.time.string(from: slot.end))").font(.caption); Spacer(); Button("创建日程") { proposedSlot = slot }.font(.caption).accessibilityLabel("用该共同空闲创建日程") } } }
            }
        }
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
                        Rectangle().fill(calendar.isDateInToday(calendar.date(byAdding: .day, value: day, to: weekStart) ?? weekStart) ? Color.accentColor.opacity(0.04) : Color.secondary.opacity(0.035))
                            .overlay(Rectangle().stroke(Color.secondary.opacity(0.16), lineWidth: 0.35))
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
    private var ownerName: String { profiles.first(where: { $0.memberID == item.ownerID })?.nickname ?? item.ownerID }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !showDetails { Text(ownerName).font(.system(size: 8, weight: .medium)).lineLimit(1) }
            Text(item.title).font(.system(size: 9, weight: .semibold)).lineLimit(2)
            if let location = item.location { Text(location).font(.system(size: 8)).lineLimit(1) }
            if showDetails, let grade = item.grade { Text([grade, item.className].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 7)).lineLimit(1) }
            if isInGap { Text("间隙 · \(FamilyFormatters.time.string(from: item.start))").font(.system(size: 7)).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(3)
        .background((MemberID(rawValue: item.ownerID) ?? .sendai).color.opacity(item.kind == .groupMeeting ? 0.28 : 0.18), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel("\(ownerName) \(item.title)，\(FamilyFormatters.time.string(from: item.start)) 到 \(FamilyFormatters.time.string(from: item.end))\(isInGap ? "，课段间隙课程" : "")")
    }
}

private struct ScheduleEditor: View {
    @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env
    let entry: ScheduleEntryModel?; let semester: SemesterModel?; @State private var title = ""; @State private var kind: ScheduleKind = .course; @State private var weekday = 2; @State private var start = Date(); @State private var end = Date().addingTimeInterval(3600); @State private var startWeek = 1; @State private var endWeek = 16; @State private var type: WeekType = .everyWeek; @State private var major = ""; @State private var grade = ""; @State private var className = ""; @State private var location = ""; @State private var note = ""; @State private var labName = ""; @State private var advisor = ""; @State private var error: String?; @State private var confirmDelete = false
    private var totalWeeks: Int { max(1, semester?.totalWeeks ?? 1) }
    private let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
    var body: some View { Form { Section { TextField("名称", text: $title); LabeledContent("成员", value: env.session.currentMemberID ?? ""); Picker("类别", selection: $kind) { Text("课程").tag(ScheduleKind.course); Text("组会").tag(ScheduleKind.groupMeeting) }; Picker("星期", selection: $weekday) { ForEach(1...7, id: \.self) { Text(weekdayNames[$0 - 1]).tag($0) } }; DatePicker("开始时间", selection: $start, displayedComponents: .hourAndMinute); DatePicker("结束时间", selection: $end, displayedComponents: .hourAndMinute) }
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
    private func save() { guard let selectedID = entryID ?? entries.first?.id, let selected = entries.first(where: { $0.id == selectedID }) else { return }; let calendar = Calendar.autoupdatingCurrent; let sm = calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start); let em = calendar.component(.hour, from: end) * 60 + calendar.component(.minute, from: end); guard kind == .cancelled || sm < em else { error = "结束时间必须晚于开始时间。"; return }; let rule = exception ?? ScheduleExceptionModel(scheduleID: selected.id, kind: kind, scope: scope, occurrenceDate: occurrence); rule.kindRaw = kind.rawValue; rule.scopeRaw = scope.rawValue; rule.occurrenceDate = occurrence; rule.replacementDate = kind == .cancelled ? nil : replacement; rule.replacementStartMinutes = kind == .cancelled ? nil : sm; rule.replacementEndMinutes = kind == .cancelled ? nil : em; rule.replacementWeekday = kind == .cancelled ? nil : calendar.component(.weekday, from: replacement); do { try env.scheduleRepository.save(exception: rule, by: env.session.currentMemberID ?? ""); dismiss() } catch { self.error = error.localizedDescription } }
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
            Button("删除", role: .destructive) { if let rule = confirmDelete { do { try env.scheduleRepository.delete(calendarOverride: rule) } catch { env.lastError = error.localizedDescription } }; confirmDelete = nil }
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
        rule.date = date; rule.kindRaw = kind.rawValue; rule.mappedWeekday = kind == .mappedWeekday ? weekday : nil; rule.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
        do { try env.scheduleRepository.save(calendarOverride: rule); dismiss() } catch let err { error = err.localizedDescription }
    }
}

private struct SemesterManagerView: View {
    @Environment(AppEnvironment.self) private var env; @Query private var semesters: [SemesterModel]; @State private var editing: SemesterModel?
    private var sorted: [SemesterModel] { semesters.sorted { $0.isCurrent != $1.isCurrent ? $0.isCurrent : $0.week1StartDate > $1.week1StartDate } }
    var body: some View { List { ForEach(sorted) { semester in Button { editing = semester } label: { HStack { VStack(alignment: .leading) { Text(semester.name); let range = semester.firstWeekRange(); Text("第 1 周：\(FamilyFormatters.day.string(from: range.start)) ～ \(FamilyFormatters.day.string(from: range.end)) · \(semester.totalWeeks) 周").font(.caption).foregroundStyle(.secondary) }; Spacer(); if semester.isCurrent { Text("当前").font(.caption).foregroundStyle(.tint) } else { Text("可编辑后设为当前").font(.caption).foregroundStyle(.secondary) } } }.buttonStyle(.plain).accessibilityLabel("编辑学期 \(semester.name)").swipeActions { if !semester.isCurrent { Button("设为当前") { setCurrent(semester) }.tint(.blue) } } } }.navigationTitle("学期管理").toolbar { Button { let calendar = Calendar.autoupdatingCurrent; let start = calendar.startOfDay(for: .now); editing = SemesterModel(name: "", week1StartDate: start, week1EndDate: calendar.date(byAdding: .day, value: 6, to: start), totalWeeks: 18, isCurrent: semesters.isEmpty) } label: { Image(systemName: "plus") } }.sheet(item: $editing) { SemesterEditor(semester: $0) } }
    private func setCurrent(_ selected: SemesterModel) { for semester in semesters { semester.isCurrent = semester.id == selected.id }; do { try env.context.save() } catch { env.lastError = error.localizedDescription } }
}

private struct SemesterEditor: View {
    @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env; let semester: SemesterModel; @State private var name = ""; @State private var start = Date(); @State private var end = Date(); @State private var weeks = 18; @State private var current = false; @State private var error: String?
    var body: some View { Form { TextField("学期名称", text: $name); Section("第一周日期范围") { DatePicker("第一周开始", selection: $start, displayedComponents: .date); DatePicker("第一周结束", selection: $end, in: start..., displayedComponents: .date); Text("第一周按你设置的开始和结束日期计算；第 2 周从结束日期的下一天开始，之后每周固定 7 天。 ").font(.caption).foregroundStyle(.secondary) }; Stepper("总周数：\(weeks)", value: $weeks, in: 1...52); Toggle("设为当前学期", isOn: $current) }.navigationTitle("学期").toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }.onAppear { let range = semester.firstWeekRange(); name = semester.name; start = range.start; end = range.end; weeks = semester.totalWeeks; current = semester.isCurrent }.alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") } }
    private func save() { guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请填写学期名称。"; return }; let calendar = Calendar.autoupdatingCurrent; let normalizedStart = calendar.startOfDay(for: start); let normalizedEnd = calendar.startOfDay(for: end); guard normalizedEnd >= normalizedStart else { error = "第一周结束日期不能早于开始日期。"; return }; do { if semester.modelContext == nil { env.context.insert(semester) }; semester.name = name; semester.week1StartDate = normalizedStart; semester.week1EndDate = normalizedEnd; semester.totalWeeks = weeks; if current { for item in try env.context.fetch(FetchDescriptor<SemesterModel>()) { item.isCurrent = item.id == semester.id } } else { semester.isCurrent = false }; try env.context.save(); dismiss() } catch let failure { error = failure.localizedDescription } }
}

struct FamilyMapView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \LocationSnapshotModel.timestamp, order: .reverse) private var snapshots: [LocationSnapshotModel]; @Query private var places: [FamilyPlaceModel]
    @State private var position = MapCameraPosition.region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 35.68, longitude: 139.72), span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2))); @State private var reportingMember = MemberID.sendai.rawValue; @State private var event = "arrive 家"; @State private var visibleMembers = Set(MemberID.allCases.map(\.rawValue)); @State private var editingPlace: FamilyPlaceModel?; @State private var showingFullscreen = false
    var latest: [LocationSnapshotModel] { MemberID.allCases.compactMap { id in snapshots.first(where: { $0.memberID == id.rawValue }) } }
    private var recentSnapshots: [LocationSnapshotModel] {
        let cutoff = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
        return snapshots.filter { $0.timestamp >= cutoff }
    }
    var body: some View { NavigationStack { List { Section { Map(position: $position) { mapContent }.frame(height: 255).accessibilityLabel("演示位置地图") } header: { HStack { Text("演示模拟：不使用真实 GPS 或地址"); Spacer(); Button { showingFullscreen = true } label: { Label("全屏查看", systemImage: "arrow.up.left.and.arrow.down.right") }.font(.caption).accessibilityLabel("全屏查看地图") } }
        Section("显示成员") { HStack(spacing: 7) { ForEach(MemberID.allCases) { member in Button { toggle(member) } label: { Text(member.rawValue).font(.caption.weight(.medium)).lineLimit(1).padding(.horizontal, 9).padding(.vertical, 6).background(visibleMembers.contains(member.rawValue) ? member.color.opacity(0.18) : Color.secondary.opacity(0.08), in: Capsule()).overlay(Capsule().stroke(visibleMembers.contains(member.rawValue) ? member.color.opacity(0.45) : .clear, lineWidth: 0.7)) }.buttonStyle(.plain).accessibilityLabel("\(member.rawValue)\(visibleMembers.contains(member.rawValue) ? "，已显示" : "，未显示")") } } }
        Section("模拟手动上报") { Picker("成员", selection: $reportingMember) { ForEach(MemberID.allCases) { Text($0.rawValue).tag($0.rawValue) } }; Picker("事件", selection: $event) { Text("到达家").tag("arrive 家"); Text("离开家").tag("leave 家") }; Button("上报演示位置", action: report).accessibilityHint("仅写入本地演示位置历史") }
        Section("最后位置") { ForEach(latest.filter { visibleMembers.contains($0.memberID) }) { item in HStack { MemberLabel(memberID: item.memberID); Spacer(); VStack(alignment: .trailing) { Text("最后更新 \(FamilyFormatters.dateTime.string(from: item.timestamp))").font(.caption); if let event = item.event { Text(localizedLocationEvent(event)).font(.caption).foregroundStyle(.secondary) } } } } }
        Section("成员地点（演示到达 / 离开）") { ForEach(places) { place in Button { editingPlace = place; focus(place.latitude, place.longitude) } label: { HStack { VStack(alignment: .leading) { Text(place.name); Text("\(place.memberID ?? "共享") · \(place.kind.localizedName) · \(Int(place.radius)) 米 · \(place.isEnabled ?? true ? "启用" : "停用")").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) } }.foregroundStyle(.primary) }.onDelete { indexSet in for index in indexSet { do { try env.locationRepository.delete(places[index]) } catch { env.lastError = error.localizedDescription } } }; Button { editingPlace = FamilyPlaceModel(name: "", kind: .custom, latitude: 35.68, longitude: 139.72, radius: 200, memberID: reportingMember) } label: { Label("新建成员地点", systemImage: "plus") } }
        Section("最近 30 天位置历史") { if recentSnapshots.isEmpty { Text("最近 30 天没有位置历史。 ").foregroundStyle(.secondary) }; ForEach(recentSnapshots) { item in Button { focus(item.latitude, item.longitude) } label: { HStack { MemberLabel(memberID: item.memberID); Spacer(); Text(FamilyFormatters.dateTime.string(from: item.timestamp)).font(.caption).foregroundStyle(.secondary) } }.foregroundStyle(.primary) } }
    }.navigationTitle("地图").sheet(item: $editingPlace) { place in NavigationStack { FamilyPlaceEditor(place: place) } }.fullScreenCover(isPresented: $showingFullscreen) { FullscreenFamilyMap(position: $position, visibleMembers: $visibleMembers, latest: latest, places: places) } } }
    private func report() { let base = latest.first(where: { $0.memberID == reportingMember }); let shift = event.hasPrefix("arrive") ? 0.001 : -0.001; let snapshot = LocationSnapshotModel(memberID: reportingMember, latitude: (base?.latitude ?? 35.68) + shift, longitude: (base?.longitude ?? 139.72) + shift, timestamp: .now, event: event); do { try env.locationRepository.add(snapshot); try env.locationRepository.purgeHistory(now: .now) } catch { env.lastError = error.localizedDescription } }
    private func focus(_ latitude: Double, _ longitude: Double) { position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03))) }
    private func localizedLocationEvent(_ value: String) -> String { value.replacingOccurrences(of: "arrive", with: "到达").replacingOccurrences(of: "leave", with: "离开") }
    @MapContentBuilder private var mapContent: some MapContent { ForEach(latest.filter { visibleMembers.contains($0.memberID) }) { item in Marker(item.memberID, coordinate: CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude)).tint((MemberID(rawValue: item.memberID) ?? .sendai).color) }; ForEach(places.filter { ($0.isEnabled ?? true) && ($0.memberID == nil || visibleMembers.contains($0.memberID!)) }) { place in Marker(place.name, systemImage: "mappin.circle", coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)).tint(.orange) } }
    private func toggle(_ member: MemberID) { if visibleMembers.contains(member.rawValue) { visibleMembers.remove(member.rawValue) } else { visibleMembers.insert(member.rawValue) } }
}

private struct FullscreenFamilyMap: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var position: MapCameraPosition
    @Binding var visibleMembers: Set<String>
    let latest: [LocationSnapshotModel]
    let places: [FamilyPlaceModel]
    @State private var selection: UUID?
    var body: some View {
        NavigationStack {
            Map(position: $position, selection: $selection) {
                ForEach(latest.filter { visibleMembers.contains($0.memberID) }) { item in
                    Marker(item.memberID, coordinate: CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude))
                        .tint((MemberID(rawValue: item.memberID) ?? .sendai).color)
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
                    HStack { MemberLabel(memberID: item.memberID); Spacer(); Text("最后更新 \(FamilyFormatters.dateTime.string(from: item.timestamp))").font(.caption) }
                        .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
                } else if let selection, let place = places.first(where: { $0.id == selection }) {
                    HStack { Text(place.name); Spacer(); Text("\(place.memberID ?? "共享") · \(Int(place.radius)) 米").font(.caption) }
                        .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
                }
            }
            .navigationTitle("地图全屏查看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .accessibilityLabel("可缩放、拖动和点选标记的演示地图")
        }
    }
}

private struct FamilyPlaceEditor: View {
    @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env; let place: FamilyPlaceModel
    @State private var name = ""; @State private var kind: PlaceKind = .custom; @State private var memberID = MemberID.sendai.rawValue; @State private var latitude = ""; @State private var longitude = ""; @State private var radius = 200; @State private var enabled = true; @State private var choosingCoordinate = false
    var body: some View { Form { Picker("成员", selection: $memberID) { ForEach(MemberID.allCases) { Text($0.rawValue).tag($0.rawValue) } }; TextField("名称", text: $name); Picker("类型", selection: $kind) { ForEach(PlaceKind.allCases, id: \.self) { Text($0.localizedName).tag($0) } }; TextField("纬度", text: $latitude).keyboardType(.numbersAndPunctuation); TextField("经度", text: $longitude).keyboardType(.numbersAndPunctuation); Button("在地图上选点 / 微调") { choosingCoordinate = true }; Picker("范围", selection: $radius) { ForEach([100, 200, 500, 1000], id: \.self) { Text("\($0) 米").tag($0) } }; Toggle("启用", isOn: $enabled) }.navigationTitle("成员地点").toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }.onAppear { name = place.name; kind = place.kind; memberID = place.memberID ?? MemberID.sendai.rawValue; latitude = String(place.latitude); longitude = String(place.longitude); radius = Int(place.radius); enabled = place.isEnabled ?? true }.sheet(isPresented: $choosingCoordinate) { CoordinatePicker(latitude: Double(latitude) ?? place.latitude, longitude: Double(longitude) ?? place.longitude) { coordinate in latitude = String(format: "%.6f", coordinate.latitude); longitude = String(format: "%.6f", coordinate.longitude) } } }
    private func save() { guard let lat = Double(latitude), let lng = Double(longitude), MemberID(rawValue: memberID) != nil else { env.lastError = "请输入有效坐标和成员。"; return }; place.name = name; place.kindRaw = kind.rawValue; place.memberID = memberID; place.latitude = lat; place.longitude = lng; place.radius = Double(radius); place.isEnabled = enabled; do { try env.locationRepository.save(place); dismiss() } catch { env.lastError = error.localizedDescription } }
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
    var body: some View { NavigationStack { List { Section { NavigationLink { MemoListView() } label: { Label("备忘录", systemImage: "note.text") }; NavigationLink { NoticeListView() } label: { Label("公告", systemImage: "megaphone") }; NavigationLink { SettingsView() } label: { Label("设置", systemImage: "gearshape") } } }.navigationTitle("更多") } }
}

private struct MemoListView: View {
    @Environment(AppEnvironment.self) private var env; @Query private var memos: [MemoModel]; @State private var editor: MemoModel?
    var sorted: [MemoModel] { memos.sorted { $0.pinned == $1.pinned ? $0.updatedAt > $1.updatedAt : $0.pinned && !$1.pinned } }
    var body: some View { List { ForEach(sorted) { memo in Button { editor = memo } label: { VStack(alignment: .leading) { HStack { Text(memo.title?.isEmpty == false ? memo.title! : memo.content.components(separatedBy: .newlines).first ?? "无标题"); if memo.pinned { Image(systemName: "pin.fill").font(.caption) } }; Text("v\(memo.version) · \(memo.updatedBy)").font(.caption).foregroundStyle(.secondary) } }.foregroundStyle(.primary).swipeActions { if memo.creatorID == env.session.currentMemberID { Button("删除", role: .destructive) { do { try env.memoRepository.delete(memo, by: env.session.currentMemberID ?? "") } catch { env.lastError = error.localizedDescription } } } } } }.navigationTitle("备忘录").toolbar { Button { editor = MemoModel(content: "", creatorID: env.session.currentMemberID ?? "Sendai", updatedBy: env.session.currentMemberID ?? "Sendai") } label: { Image(systemName: "square.and.pencil") } }.sheet(item: $editor) { MemoEditor(memo: $0) } }
}
private struct MemoEditor: View {
    @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env; let memo: MemoModel; @State private var title = ""; @State private var content = ""; @State private var pinned = false; @State private var expected = 0; @State private var error: String?
    var body: some View { NavigationStack { Form { TextField("标题（可选）", text: $title); TextEditor(text: $content).frame(minHeight: 160); Toggle("置顶", isOn: $pinned); BusinessAIAssistButton(title: "AI 整理备忘录", instruction: "Polish, summarize, expand, or organize the memo according to the request. Return plain text only.", source: content) { content = $0 } }.navigationTitle("备忘录").toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }.onAppear { title = memo.title ?? ""; content = memo.content; pinned = memo.pinned; expected = memo.version }.alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") } } }
    private func save() { let draft = MemoDraft(title: title.isEmpty ? nil : title, content: content, pinned: pinned); do { if memo.modelContext == nil { try env.memoRepository.create(draft: draft, by: env.session.currentMemberID ?? "") } else { try env.memoRepository.save(memo, draft: draft, expectedVersion: expected, by: env.session.currentMemberID ?? "") }; dismiss() } catch { self.error = error.localizedDescription } }
}

private struct NoticeListView: View {
    @Environment(AppEnvironment.self) private var env; @Query private var notices: [NoticeModel]; @Query private var reads: [NoticeReadModel]; @Query private var profiles: [MemberProfile]; @State private var editor: NoticeModel?
    var sorted: [NoticeModel] { notices.sorted { lhs, rhs in lhs.pinned == rhs.pinned ? (lhs.pinned ? lhs.updatedAt > rhs.updatedAt : lhs.createdAt > rhs.createdAt) : lhs.pinned && !rhs.pinned } }
    private func publisherName(for notice: NoticeModel) -> String { profiles.first(where: { $0.memberID == notice.publisherID })?.nickname ?? notice.publisherID }
    var body: some View { List { ForEach(sorted) { notice in NavigationLink { NoticeDetail(notice: notice, reads: reads) } label: { HStack { VStack(alignment: .leading) { Text(notice.title); Text(notice.isEdited ? "\(publisherName(for: notice)) · 已编辑" : publisherName(for: notice)).font(.caption).foregroundStyle(.secondary) }; Spacer(); if notice.pinned { Image(systemName: "pin.fill").font(.caption) }; if notice.publisherID != env.session.currentMemberID && !reads.contains(where: { $0.noticeID == notice.id && $0.memberID == env.session.currentMemberID }) { Text("未读").font(.caption2).foregroundStyle(.blue) } } }.swipeActions { if notice.publisherID == env.session.currentMemberID { Button("删除", role: .destructive) { do { try env.noticeRepository.delete(notice, by: env.session.currentMemberID ?? "") } catch { env.lastError = error.localizedDescription } } } } } }.navigationTitle("公告").toolbar { Button { editor = NoticeModel(title: "", content: "", publisherID: env.session.currentMemberID ?? "Sendai") } label: { Image(systemName: "plus") } }.sheet(item: $editor) { NoticeEditor(notice: $0) } }
}
private struct NoticeDetail: View { @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env; let notice: NoticeModel; let reads: [NoticeReadModel]; @State private var editor: NoticeModel?; @State private var confirmDelete = false
    private var canEdit: Bool { notice.publisherID == env.session.currentMemberID }
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 14) { Text(notice.title).font(.title2.bold()); Text(notice.content); if notice.isEdited { Text("已编辑").font(.caption).foregroundStyle(.secondary) }; if canEdit { Divider(); Text("阅读情况").font(.subheadline.weight(.semibold)); ForEach(MemberID.allCases) { member in if member.rawValue != notice.publisherID { let read = reads.first { $0.noticeID == notice.id && $0.memberID == member.rawValue }; HStack { MemberLabel(memberID: member.rawValue); Spacer(); Text(read.map { FamilyFormatters.dateTime.string(from: $0.readAt) } ?? "未读").font(.caption).foregroundStyle(read == nil ? .blue : .secondary) } } } } }.frame(maxWidth: .infinity, alignment: .leading).padding() }.navigationTitle("公告").toolbar { if canEdit { ToolbarItemGroup(placement: .topBarTrailing) { Button("编辑") { editor = notice }; Button("删除", role: .destructive) { confirmDelete = true } } } }.sheet(item: $editor) { NoticeEditor(notice: $0) }.confirmationDialog("删除公告？", isPresented: $confirmDelete, titleVisibility: .visible) { Button("删除", role: .destructive) { do { try env.noticeRepository.delete(notice, by: env.session.currentMemberID ?? ""); dismiss() } catch { env.lastError = error.localizedDescription } } }.onAppear { do { try env.noticeRepository.markRead(notice, memberID: env.session.currentMemberID ?? "") } catch { env.lastError = error.localizedDescription } } }
}
private struct NoticeEditor: View { @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env; let notice: NoticeModel; @State private var title = ""; @State private var content = ""; @State private var pinned = false
    var body: some View { NavigationStack { Form { TextField("标题", text: $title); TextEditor(text: $content).frame(minHeight: 160); Toggle("置顶", isOn: $pinned); BusinessAIAssistButton(title: "AI 辅助撰写", instruction: "Draft a concise family notice from the input. Return plain text only.", source: "\(title)\n\(content)") { content = $0 } }.navigationTitle("发布公告").toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { do { let draft = NoticeDraft(title: title, content: content, pinned: pinned); if notice.modelContext == nil { try env.noticeRepository.create(draft: draft, by: env.session.currentMemberID ?? "") } else { try env.noticeRepository.save(notice, draft: draft, by: env.session.currentMemberID ?? "") }; dismiss() } catch { env.lastError = error.localizedDescription } } }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }.onAppear { title = notice.title; content = notice.content; pinned = notice.pinned } } }
}

private struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env; @Query private var profiles: [MemberProfile]; @AppStorage("ai.enabled") private var enabled = false; @AppStorage("ai.contents") private var allowContent = false; @AppStorage("ai.baseURL") private var baseURL = ""; @AppStorage("ai.model") private var model = ""; @State private var apiKey = ""; @State private var testResult: String?; @State private var showClear = false; @State private var showClearKey = false; @State private var profileEditor: MemberProfile?
    var body: some View { Form { Section("个人资料") { if let profile = profiles.first(where: { $0.memberID == env.session.currentMemberID }) { Button { profileEditor = profile } label: { HStack { Image(systemName: profile.avatarSymbol ?? "person.crop.circle.fill").font(.title3); VStack(alignment: .leading) { Text(profile.nickname); Text(profile.memberID).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) } }.foregroundStyle(.primary) } }
        Section("通知设置") { Toggle("本地通知开关（未接入 APNs）", isOn: .constant(false)).disabled(true) }
        Section("定位设置") { Toggle("演示位置开关（未接入后台定位）", isOn: .constant(true)).disabled(true) }
        Section("AI 设置") { Toggle("启用 AI", isOn: $enabled); Toggle("允许业务内容发送 AI", isOn: $allowContent).disabled(!enabled); TextField("Base URL", text: $baseURL).textInputAutocapitalization(.never).keyboardType(.URL); SecureField("API Key（Keychain）", text: $apiKey); TextField("Model", text: $model); Button("保存 API Key") { do { try env.keychain.saveAPIKey(apiKey); apiKey = ""; testResult = "已保存到 Keychain。" } catch { testResult = error.localizedDescription } }; Button("清除 API Key", role: .destructive) { showClearKey = true }; Button("测试连接") { Task { do { try await AIService(keychain: env.keychain).testConnection(baseURL: baseURL, model: model); testResult = "连接成功。" } catch { testResult = error.localizedDescription } } }; if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }; Text("关闭业务内容发送后，AI 仍可仅处理你在请求框手工输入的文字；不会自动带入业务数据。聊天和地图不会发送给 AI。 ").font(.footnote).foregroundStyle(.secondary) }
        Section("关于") { Text("本地 SwiftUI / SwiftData Demo"); Text("密码固定为 qwer1234；当前 Demo 不提供改密以避免悄悄改变登录规则。 ").font(.caption).foregroundStyle(.secondary) }
        Section { Button("退出登录", role: .destructive) { env.session.logout() } }
        Section("开发 / 演示数据") { Button("重置 Demo 数据") { env.resetDemo() }; Button("清除全部本地数据", role: .destructive) { showClear = true } }
    }.navigationTitle("设置").sheet(item: $profileEditor) { profile in NavigationStack { ProfileEditor(profile: profile) } }.confirmationDialog("清除 API Key？", isPresented: $showClearKey, titleVisibility: .visible) { Button("清除 API Key", role: .destructive) { env.keychain.clear(); testResult = "已清除 Keychain 中的 API Key。" } }.confirmationDialog("清除所有本地数据？", isPresented: $showClear, titleVisibility: .visible) { Button("清除全部本地数据", role: .destructive) { env.clearAllLocalData() } } message: { Text("这会删除 SwiftData、媒体、设置、登录状态和 AI Keychain 内容，无法恢复。") } }
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
    var body: some View { Button { showing = true } label: { Label(title, systemImage: "sparkles") }.sheet(isPresented: $showing) { NavigationStack { AIDraftPreview(title: title, instruction: instruction, source: source, apply: { apply($0); showing = false }) } } }
}

private struct AIDraftPreview: View {
    @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env
    @AppStorage("ai.enabled") private var enabled = false
    @AppStorage("ai.contents") private var allowContent = false
    @AppStorage("ai.baseURL") private var baseURL = ""
    @AppStorage("ai.model") private var model = ""
    let title: String; let instruction: String; let source: String; let apply: (String) -> Void
    @State private var request = ""; @State private var result = ""; @State private var isLoading = false; @State private var error: String?
    var body: some View { Form { Section("请求") { TextEditor(text: $request).frame(minHeight: 90); Text("仅在你点击生成时发送此业务内容；聊天和地图没有 AI 入口。 ").font(.caption).foregroundStyle(.secondary) }; Section("AI 预览") { if isLoading { ProgressView() } else if result.isEmpty { Text("生成结果会在这里出现，确认前不会写入本地数据。 ").foregroundStyle(.secondary) } else { TextEditor(text: $result).frame(minHeight: 180) } } }.navigationTitle(title).toolbar { ToolbarItem(placement: .confirmationAction) { Button(result.isEmpty ? "生成" : "应用到草稿") { if result.isEmpty { generate() } else { apply(result) } }.disabled(isLoading) }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }.alert("AI 不可用", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") } }
    private func generate() { guard enabled else { error = "请先在设置中启用 AI。"; return }; let manual = request.trimmingCharacters(in: .whitespacesAndNewlines); guard allowContent || !manual.isEmpty else { error = "关闭业务内容发送时，请在请求框输入要发送给 AI 的文字。"; return }; isLoading = true; let prompt = allowContent ? (manual.isEmpty ? source : "\(source)\n\n用户要求：\(manual)") : manual; Task { do { let draft = try await AIService(keychain: env.keychain).generateBusinessDraft(baseURL: baseURL, model: model, instruction: instruction, source: prompt); await MainActor.run { result = draft; isLoading = false } } catch { await MainActor.run { self.error = error.localizedDescription; isLoading = false } } } }
}
