import Foundation
import SwiftData

@MainActor final class DemoDataService {
    private let context: ModelContext; private let mediaStore: LocalMediaStore; private let calendar = Calendar.autoupdatingCurrent
    init(context: ModelContext, mediaStore: LocalMediaStore) { self.context = context; self.mediaStore = mediaStore }
    func seedIfNeeded() throws {
        if !(try context.fetch(FetchDescriptor<MemberProfile>())).isEmpty { return }
        for member in MemberID.allCases { context.insert(MemberProfile(memberID: member.rawValue, nickname: member.rawValue, colorKey: member.rawValue)) }
        try seedBusinessData(); try context.save()
    }
    func resetDemo() throws {
        try deleteBusinessData(); try mediaStore.clear(); try seedBusinessData(); try context.save()
    }
    func clearAll() throws {
        try deleteBusinessData()
        for item in try context.fetch(FetchDescriptor<MemberProfile>()) { context.delete(item) }
        try mediaStore.clear(); try context.save()
    }
    private func deleteBusinessData() throws {
        for item in try context.fetch(FetchDescriptor<SemesterModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<ScheduleEntryModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<ScheduleExceptionModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<CalendarOverrideModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<AgendaItemModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<AgendaExceptionModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<MemoModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<NoticeModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<NoticeReadModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<ChatMessageModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<LocationSnapshotModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<FamilyPlaceModel>()) { context.delete(item) }
    }
    private func seedBusinessData() throws {
        let now = Date(); let week1 = monday(containing: now); let week1End = calendar.date(byAdding: .day, value: 6, to: week1)
        let semester = SemesterModel(name: "2026 秋季学期", week1StartDate: week1, week1EndDate: week1End, totalWeeks: 18); context.insert(semester)
        let mon = 2, wed = 4, thu = 5
        let s1 = ScheduleEntryModel(ownerID: "Sendai", semesterID: semester.id, title: "移动应用开发", kind: .course, weekday: mon, startMinutes: 9 * 60, endMinutes: 10 * 60 + 30, startWeek: 1, endWeek: 16, weekType: .everyWeek, grade: "大三", className: "1班", location: "A201")
        let s2 = ScheduleEntryModel(ownerID: "Osaka", semesterID: semester.id, title: "数据结构", kind: .course, weekday: mon, startMinutes: 9 * 60 + 30, endMinutes: 11 * 60, startWeek: 1, endWeek: 18, weekType: .oddWeek, grade: "大二", className: "2班", location: "B101")
        let s3 = ScheduleEntryModel(ownerID: "Kyoto", semesterID: semester.id, title: "机器学习组会", kind: .groupMeeting, weekday: wed, startMinutes: 14 * 60, endMinutes: 15 * 60 + 30, startWeek: 1, endWeek: 18, weekType: .everyWeek, location: "实验室", labName: "AI Lab", advisor: "田中教授")
        let s4 = ScheduleEntryModel(ownerID: "Sendai", semesterID: semester.id, title: "线性代数", kind: .course, weekday: thu, startMinutes: 10 * 60, endMinutes: 11 * 60 + 30, startWeek: 2, endWeek: 14, weekType: .evenWeek, location: "C305")
        [s1,s2,s3,s4].forEach(context.insert)
        let wednesday = calendar.date(byAdding: .day, value: 2, to: week1) ?? now
        let thursday = calendar.date(byAdding: .day, value: 3, to: week1) ?? now
        context.insert(ScheduleExceptionModel(scheduleID: s3.id, kind: .cancelled, occurrenceDate: wednesday, note: "单次组会取消"))
        context.insert(ScheduleExceptionModel(scheduleID: s4.id, kind: .rescheduled, occurrenceDate: thursday, replacementDate: thursday, replacementStartMinutes: 13 * 60, replacementEndMinutes: 14 * 60 + 30, note: "临时调课"))
        let today0900 = time(today: now, hour: 9); let today1100 = time(today: now, hour: 11); let today1330 = time(today: now, hour: 13, minute: 30); let today1500 = time(today: now, hour: 15)
        context.insert(AgendaItemModel(creatorID: "Sendai", title: "家庭晚餐", kind: .normal, start: today1330, end: today1500, location: "家", note: "确认菜单", participantIDs: ["Sendai", "Osaka", "Kyoto"]))
        context.insert(AgendaItemModel(creatorID: "Osaka", title: "算法考试", kind: .exam, start: today0900, end: today1100, location: "D102", participantIDs: ["Osaka"]))
        context.insert(AgendaItemModel(creatorID: "Kyoto", title: "实验报告截止", kind: .assignmentDeadline, dueAt: today1500, note: "提交 PDF", participantIDs: ["Kyoto"], completion: .pending))
        context.insert(AgendaItemModel(creatorID: "Sendai", title: "点菜：番茄牛腩", kind: .orderFood, note: "少辣", participantIDs: ["Sendai", "Osaka", "Kyoto"], dishes: "番茄牛腩、青菜", peopleCount: 3, estimatedArrival: today1330, desiredMealTime: today1500, preparation: .preparing))
        context.insert(AgendaItemModel(creatorID: "Kyoto", title: "晨间复习", kind: .normal, start: today0900, end: today1100, participantIDs: ["Kyoto"], recurrence: .weekly, recurrenceEnd: calendar.date(byAdding: .weekOfYear, value: 4, to: now)))
        context.insert(MemoModel(title: "本周采购", content: "牛奶\n蔬菜\n洗衣液", creatorID: "Sendai", pinned: true, updatedBy: "Sendai"))
        context.insert(MemoModel(content: "周末一起整理客厅。", creatorID: "Osaka", version: 2, updatedBy: "Kyoto"))
        let notice = NoticeModel(title: "周日家庭会议", content: "本周日 19:00 讨论下周安排。", publisherID: "Kyoto", pinned: true); context.insert(notice); context.insert(NoticeReadModel(noticeID: notice.id, memberID: "Sendai"))
        let edited = NoticeModel(title: "厨房清洁", content: "轮值表已更新。", publisherID: "Osaka", isEdited: true); context.insert(edited)
        let image = try mediaStore.makeDemoImage(); let tone = try mediaStore.makeDemoTone()
        context.insert(ChatMessageModel(senderID: "Sendai", body: "晚上一起吃饭吗？", kind: .text, sentAt: now.addingTimeInterval(-7200), status: .read))
        context.insert(ChatMessageModel(senderID: "Osaka", body: "菜单在这里", kind: .image, sentAt: now.addingTimeInterval(-6500), status: .read, mediaPath: image))
        context.insert(ChatMessageModel(senderID: "Kyoto", body: "语音消息", kind: .audio, sentAt: now.addingTimeInterval(-6100), status: .delivered, mediaPath: tone))
        let recalled = ChatMessageModel(senderID: "Sendai", body: "该消息已被撤回", kind: .recalled, sentAt: now.addingTimeInterval(-5800), status: .read, recalledAt: now.addingTimeInterval(-5700)); context.insert(recalled)
        context.insert(ChatMessageModel(senderID: "Osaka", body: "我 18:30 到家。", kind: .text, sentAt: now.addingTimeInterval(-1200), status: .sent, isUnread: true))
        context.insert(ChatMessageModel(senderID: "Kyoto", body: "网络模拟失败示例", kind: .text, sentAt: now.addingTimeInterval(-300), status: .failed, isUnread: true))
        for snapshot in DemoLocationProvider().locations(now: now) { context.insert(snapshot) }
        context.insert(LocationSnapshotModel(memberID: "Sendai", latitude: 35.6762, longitude: 139.6503, timestamp: calendar.date(byAdding: .day, value: -31, to: now)!, event: "old demo"))
        context.insert(FamilyPlaceModel(name: "Sendai 的家", kind: .home, latitude: 35.6812, longitude: 139.7671, radius: 200, memberID: "Sendai"))
        context.insert(FamilyPlaceModel(name: "Osaka 的学校", kind: .school, latitude: 35.6762, longitude: 139.6503, radius: 500, memberID: "Osaka"))
        context.insert(FamilyPlaceModel(name: "Kyoto 的地点", kind: .custom, latitude: 35.6895, longitude: 139.6917, radius: 1000, memberID: "Kyoto"))
    }
    private func monday(containing date: Date) -> Date { let weekday = calendar.component(.weekday, from: date); return calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: calendar.startOfDay(for: date)) ?? calendar.startOfDay(for: date) }
    private func time(today: Date, hour: Int, minute: Int = 0) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today) ?? today }
}
