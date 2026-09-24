import Foundation
import SwiftData

@MainActor final class DemoDataService {
    private let context: ModelContext; private let mediaStore: LocalMediaStore; private let calendar = Calendar.autoupdatingCurrent
    init(context: ModelContext, mediaStore: LocalMediaStore) { self.context = context; self.mediaStore = mediaStore }
    func seedIfNeeded() throws {
        if !(try context.fetch(FetchDescriptor<MemberProfile>())).isEmpty { return }
        try insertMissingInitialMembers()
        try seedBusinessData(); try context.save()
    }
    /// Founder identities are required for the local account directory; they
    /// are not sample conversations, courses, locations, or notices.
    func seedInitialMembersIfNeeded() throws {
        try insertMissingInitialMembers()
        try context.save()
    }
    private func insertMissingInitialMembers() throws {
        let existing = Set(try context.fetch(FetchDescriptor<MemberProfile>()).map(\.memberID))
        for member in MemberID.allCases where !existing.contains(member.rawValue) {
            context.insert(MemberProfile(memberID: member.rawValue, nickname: member.rawValue,
                                         colorKey: member.rawValue, remoteMemberID: member.remoteUUID,
                                         isInitialMember: true))
        }
    }
    func resetDemo() throws {
        try deleteBusinessData(); try mediaStore.clear(); try seedBusinessData(); try context.save()
    }
    func clearAll() throws {
        try deleteBusinessData()
        for item in try context.fetch(FetchDescriptor<MemberProfile>()) { context.delete(item) }
        // These are transport cache/outbox records, not business backup data.
        for item in try context.fetch(FetchDescriptor<PendingMutationModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<PendingImportBatchRollbackModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<SyncStateModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<RemoteEntityRecordModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<SyncConflictModel>()) { context.delete(item) }
        try mediaStore.clear(); try context.save()
    }
    private func deleteBusinessData() throws {
        for item in try context.fetch(FetchDescriptor<SemesterModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<ScheduleEntryModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<ScheduleExceptionModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<ScheduleImportBatchModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<CalendarOverrideModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<AgendaItemModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<AgendaExceptionModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<MemoModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<NoticeModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<NoticeReadModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<ChatMessageModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<MessageReceiptModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<LocationSnapshotModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<MemberStatusModel>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<FamilyPlaceModel>()) { context.delete(item) }
    }
    private func seedBusinessData() throws {
        let now = Date(); let week1 = monday(containing: now); let week1End = calendar.date(byAdding: .day, value: 6, to: week1)
        let semester = SemesterModel(name: "2026 秋季学期", week1StartDate: week1, week1EndDate: week1End, totalWeeks: 18); context.insert(semester)
        let mon = 2, wed = 4, thu = 5
        let s1 = ScheduleEntryModel(ownerID: "Sendai", semesterID: semester.id, title: "教育心理学", kind: .course, weekday: mon, startMinutes: 9 * 60, endMinutes: 10 * 60 + 30, startWeek: 1, endWeek: 16, weekType: .everyWeek, grade: "大三", className: "教育学 1 班", location: "文澜楼 204", note: "任课老师：李老师")
        let s2 = ScheduleEntryModel(ownerID: "Osaka", semesterID: semester.id, title: "数据结构", kind: .course, weekday: mon, startMinutes: 10 * 60 + 40, endMinutes: 12 * 60 + 10, startWeek: 1, endWeek: 18, weekType: .oddWeek, grade: "大二", className: "计算机 2 班", location: "东九楼 201", note: "任课老师：周老师")
        let s3 = ScheduleEntryModel(ownerID: "Kyoto", semesterID: semester.id, title: "课题组例会", kind: .groupMeeting, weekday: wed, startMinutes: 14 * 60, endMinutes: 15 * 60 + 30, startWeek: 1, endWeek: 18, weekType: .everyWeek, location: "实验室 302", labName: "智能系统实验室", advisor: "王老师")
        let s4 = ScheduleEntryModel(ownerID: "Sendai", semesterID: semester.id, title: "高等数学", kind: .course, weekday: thu, startMinutes: 10 * 60, endMinutes: 11 * 60 + 30, startWeek: 2, endWeek: 14, weekType: .evenWeek, location: "文津楼 305", note: "任课老师：陈老师")
        [s1,s2,s3,s4].forEach(context.insert)
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let dinnerDay = calendar.component(.hour, from: now) >= 20 ? tomorrow : today
        let followingDay = calendar.date(byAdding: .day, value: 1, to: dinnerDay) ?? tomorrow
        let pickupStart = time(today: dinnerDay, hour: 17, minute: 40)
        let dinnerArrival = time(today: dinnerDay, hour: 18, minute: 10)
        let dinnerTime = time(today: dinnerDay, hour: 18, minute: 40)
        let groceryStart = time(today: followingDay, hour: 17, minute: 20)
        let groupMeetingStart = time(today: followingDay, hour: 14)
        let reportDue = time(today: followingDay, hour: 21)
        context.insert(AgendaItemModel(creatorID: "Sendai", title: "取快递", kind: .normal, start: pickupStart, end: time(today: dinnerDay, hour: 18), location: "长安万科广场服务台", participantIDs: ["Sendai"]))
        context.insert(AgendaItemModel(creatorID: "Osaka", title: "一起买菜", kind: .normal, start: groceryStart, end: time(today: followingDay, hour: 18), location: "长安万科广场", note: "补齐周末食材", participantIDs: ["Osaka", "Kyoto"]))
        context.insert(AgendaItemModel(creatorID: "Kyoto", title: "课题组讨论", kind: .normal, start: groupMeetingStart, end: time(today: followingDay, hour: 15), location: "陕西师范大学长安校区", participantIDs: ["Kyoto"]))
        context.insert(AgendaItemModel(creatorID: "Kyoto", title: "作业：课堂观察报告", kind: .assignmentDeadline, dueAt: reportDue, note: "提交课程平台", participantIDs: ["Kyoto"], completion: .pending))
        context.insert(AgendaItemModel(creatorID: "Sendai", title: "今晚晚餐", kind: .orderFood, note: "少油少盐", participantIDs: ["Sendai", "Osaka", "Kyoto"], dishes: "番茄鸡蛋、清炒西兰花", ingredients: "番茄、鸡蛋、西兰花", seasonings: "盐、生抽、蒜", peopleCount: 3, estimatedArrival: dinnerArrival, desiredMealTime: dinnerTime, preparation: .waiting))
        context.insert(MemoModel(title: "本周采购", content: "牛奶\n鸡蛋\n西兰花\n洗衣液", creatorID: "Sendai", pinned: true, updatedBy: "Sendai"))
        context.insert(MemoModel(title: "周末安排", content: "周六上午补齐日用品，下午一起整理客厅。", creatorID: "Osaka", updatedBy: "Osaka"))
        let notice = NoticeModel(title: "本周家庭安排", content: "周六上午补齐日用品，周日晚上确认下周课表。", publisherID: "Kyoto", pinned: true, createdAt: now.addingTimeInterval(-2_400), updatedAt: now.addingTimeInterval(-2_400)); context.insert(notice); context.insert(NoticeReadModel(noticeID: notice.id, memberID: "Sendai", readAt: now.addingTimeInterval(-1_800))); context.insert(NoticeReadModel(noticeID: notice.id, memberID: "Osaka", readAt: now.addingTimeInterval(-1_600)))
        context.insert(NoticeModel(title: "厨房轮值", content: "本周由 Osaka 负责晚餐后的厨房整理。", publisherID: "Osaka", createdAt: now.addingTimeInterval(-5_400), updatedAt: now.addingTimeInterval(-5_400)))
        let image = try mediaStore.makeDemoImage(); let tone = try mediaStore.makeDemoTone()
        context.insert(ChatMessageModel(senderID: "Sendai", body: "我下课后去长安万科广场买菜，大概 18:10 到。", kind: .text, sentAt: now.addingTimeInterval(-3 * 60 * 60), status: .read))
        context.insert(ChatMessageModel(senderID: "Osaka", body: "晚餐食材我先记下来了。", kind: .image, sentAt: now.addingTimeInterval(-150 * 60), status: .read, mediaPath: image))
        context.insert(ChatMessageModel(senderID: "Kyoto", body: "我从实验室出发后和你们说。", kind: .audio, sentAt: now.addingTimeInterval(-90 * 60), status: .delivered, mediaPath: tone))
        context.insert(ChatMessageModel(senderID: "Sendai", body: "番茄和西兰花我来买。", kind: .text, sentAt: now.addingTimeInterval(-35 * 60), status: .read))
        context.insert(ChatMessageModel(senderID: "Osaka", body: "我 18:30 左右到家，晚饭见。", kind: .text, sentAt: now.addingTimeInterval(-8 * 60), status: .sent, isUnread: true))
        // 家庭地点只是可管理的地点，不代表成员的实时位置；只有真实
        // LocationSnapshot 才会在地图上显示“多久前更新”。
        context.insert(MemberStatusModel(memberID: "Sendai", status: .atSchool, updatedAt: now.addingTimeInterval(-12 * 60)))
        context.insert(MemberStatusModel(memberID: "Osaka", status: .atSchool, updatedAt: now.addingTimeInterval(-28 * 60)))
        context.insert(MemberStatusModel(memberID: "Kyoto", status: .allGood, updatedAt: now.addingTimeInterval(-45 * 60)))
        context.insert(FamilyPlaceModel(name: "陕西师范大学长安校区", kind: .school, latitude: FamilyMapDefaults.shaanxiNormalUniversityChangAn.latitude, longitude: FamilyMapDefaults.shaanxiNormalUniversityChangAn.longitude, radius: 500, memberID: "Sendai"))
        context.insert(FamilyPlaceModel(name: "西安交通大学兴庆校区", kind: .school, latitude: FamilyMapDefaults.xianJiaotongUniversityXingQing.latitude, longitude: FamilyMapDefaults.xianJiaotongUniversityXingQing.longitude, radius: 500, memberID: "Osaka"))
        context.insert(FamilyPlaceModel(name: "长安万科广场", kind: .custom, latitude: FamilyMapDefaults.changAnVankePlaza.latitude, longitude: FamilyMapDefaults.changAnVankePlaza.longitude, radius: 300, memberID: "Kyoto"))
    }
    private func monday(containing date: Date) -> Date { let weekday = calendar.component(.weekday, from: date); return calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: calendar.startOfDay(for: date)) ?? calendar.startOfDay(for: date) }
    private func time(today: Date, hour: Int, minute: Int = 0) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today) ?? today }
}
