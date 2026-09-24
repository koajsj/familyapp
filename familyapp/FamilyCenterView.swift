import SwiftUI
import SwiftData

private struct FamilyTodayActivity: Identifiable {
    let id: String
    let start: Date
    let title: String
    let category: BusyCategory
    var memberIDs: [String]
}

/// A read-only overview of existing family records. Schedule and recurring
/// Agenda occurrences come from the same time engine used by the timetable.
struct FamilyCenterView: View {
    @Environment(AppEnvironment.self) private var env
    @Query private var profiles: [MemberProfile]
    @Query private var statuses: [MemberStatusModel]
    @Query private var semesters: [SemesterModel]
    @Query private var entries: [ScheduleEntryModel]
    @Query private var scheduleExceptions: [ScheduleExceptionModel]
    @Query private var calendarOverrides: [CalendarOverrideModel]
    @Query private var agendas: [AgendaItemModel]
    @Query private var agendaExceptions: [AgendaExceptionModel]
    @Query private var notices: [NoticeModel]
    @Query private var noticeReads: [NoticeReadModel]
    @Binding var routedScheduleIntent: FamilyIntentRoute?
    @State private var showingSchedule = false

    private var activeMembers: [MemberProfile] { MemberDirectory.activeMembers(from: profiles) }
    private var currentSemester: SemesterModel? { semesters.first(where: \.isCurrent) }
    private var latestNotice: NoticeModel? { notices.filter { $0.deletedAt == nil && $0.purgedAt == nil }.max { $0.createdAt < $1.createdAt } }
    private var todayRange: DateInterval {
        let start = Calendar.autoupdatingCurrent.startOfDay(for: .now)
        let end = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }
    private var todayBusy: [FamilyTodayActivity] {
        let reasons = env.timeAnalysis.busyReasons(
            memberIDs: activeMembers.map(\.memberID), in: todayRange,
            entries: entries, exceptions: scheduleExceptions, agendas: agendas,
            agendaExceptions: agendaExceptions, calendarOverrides: calendarOverrides,
            semester: currentSemester
        )
        var activities: [String: FamilyTodayActivity] = [:]
        for (memberID, intervals) in reasons {
            for interval in intervals {
                let key = "\(interval.category.rawValue)|\(interval.source)|\(interval.start.timeIntervalSinceReferenceDate)|\(interval.end.timeIntervalSinceReferenceDate)"
                if activities[key] == nil {
                    activities[key] = FamilyTodayActivity(id: key, start: interval.start, title: interval.source, category: interval.category, memberIDs: [])
                }
                activities[key]?.memberIDs.append(memberID)
            }
        }
        return activities.values.sorted { $0.start < $1.start }
    }
    private var todayUntimed: [AgendaItemModel] {
        agendas.filter { item in
            guard item.deletedAt == nil, item.purgedAt == nil else { return false }
            let isUntimed = item.kind == .assignmentDeadline || item.kind == .orderFood
            guard isUntimed else { return false }
            let date = item.dueAt ?? item.desiredMealTime ?? item.start
            return date.map { Calendar.autoupdatingCurrent.isDateInToday($0) } ?? false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                memberSection
                todaySection
                noticeSection
                mattersSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("家庭")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSchedule = true } label: { Image(systemName: "calendar.badge.clock") }
                        .accessibilityLabel("查看课表与共同空闲")
                }
            }
            .sheet(isPresented: $showingSchedule) {
                ScheduleView(routedIntent: $routedScheduleIntent)
            }
            .onAppear(perform: openRoutedScheduleIfNeeded)
            .onChange(of: routedScheduleIntent) { _, _ in openRoutedScheduleIfNeeded() }
        }
    }

    private var memberSection: some View {
        Section("成员状态") {
            if activeMembers.isEmpty {
                emptyRow("暂无家庭成员", detail: "家庭成员会显示在这里。", symbol: "person.3")
            } else {
                ForEach(activeMembers) { profile in
                    let state = statuses.first { $0.memberID == profile.memberID }
                    HStack(spacing: 10) {
                        MemberAvatar(memberID: profile.memberID, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(state?.status.localizedName ?? "暂无状态")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        if let state {
                            Text(FamilyRelativeTime.locationUpdated(at: state.updatedAt))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var todaySection: some View {
        Section {
            if todayBusy.isEmpty && todayUntimed.isEmpty {
                emptyRow("暂无安排", detail: "可以查看课表或共同空闲时间。", symbol: "calendar")
            } else {
                ForEach(todayBusy.prefix(5)) { entry in
                    HStack(spacing: 10) {
                        Text(FamilyFormatters.time.string(from: entry.start))
                            .font(.caption.monospacedDigit()).frame(width: 46, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).lineLimit(1)
                            Text("\(entry.memberIDs.sorted().map(displayName(for:)).joined(separator: " · ")) · \(entry.category.localizedName)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                ForEach(todayUntimed.prefix(3)) { item in
                    Label(item.title, systemImage: item.kind == .orderFood ? "fork.knife" : "checklist")
                        .lineLimit(1)
                }
            }
            Button { showingSchedule = true } label: { Label("课表与共同空闲", systemImage: "calendar.badge.clock") }
            NavigationLink { AgendaView() } label: { Label("全部日程", systemImage: "calendar") }
        } header: { Text("今日安排") }
    }

    private var noticeSection: some View {
        Section("最新公告") {
            if let notice = latestNotice {
                NavigationLink { NoticeDetail(notice: notice, reads: noticeReads) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(notice.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(notice.content).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } else {
                emptyRow("暂无公告", detail: "家庭重要消息会显示在这里。", symbol: "megaphone")
            }
            NavigationLink { NoticeListView() } label: { Label("查看全部公告", systemImage: "megaphone") }
        }
    }

    private var mattersSection: some View {
        Section("家庭事项") {
            NavigationLink { MemoListView() } label: { Label("备忘录", systemImage: "note.text") }
            NavigationLink { AgendaView(filterKind: .orderFood) } label: { Label("点菜", systemImage: "fork.knife") }
            if env.runtimeMode == .remoteSync, let flow = env.registrationFlow {
                NavigationLink { FamilyMembersView(flow: flow) } label: { Label("成员管理", systemImage: "person.3") }
            } else {
                NavigationLink { LocalFamilyDirectoryView() } label: { Label("家庭成员", systemImage: "person.3") }
            }
        }
    }

    private func displayName(for memberID: String) -> String {
        profiles.first(where: { $0.memberID == memberID })?.displayName ?? memberID
    }

    private func emptyRow(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(detail).font(.caption)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func openRoutedScheduleIfNeeded() {
        if routedScheduleIntent != nil { showingSchedule = true }
    }
}
