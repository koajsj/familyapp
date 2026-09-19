import Foundation
import SwiftData
import SwiftUI
import Security
import UIKit
import Observation
import AVFoundation

struct MemoDraft { var title: String?; var content: String; var pinned: Bool }
struct NoticeDraft { var title: String; var content: String; var pinned: Bool }
struct AgendaDraft { var title: String; var kind: AgendaKind; var start: Date?; var end: Date?; var dueAt: Date?; var location: String?; var note: String?; var participantIDs: [String]; var recurrence: AgendaRecurrence; var recurrenceEnd: Date?; var dishes: String?; var ingredients: String?; var seasonings: String?; var peopleCount: Int?; var estimatedArrival: Date?; var desiredMealTime: Date?; var preparation: PreparationState?; var completion: CompletionState? }

@MainActor protocol ChatRepository { func messages() throws -> [ChatMessageModel]; func create(_ message: ChatMessageModel) throws; func recall(_ message: ChatMessageModel, by memberID: String, now: Date) throws; func retry(_ message: ChatMessageModel, by memberID: String) throws; func markIncomingMessagesRead(by memberID: String) throws }
@MainActor protocol AgendaRepository { func items() throws -> [AgendaItemModel]; func save(_ item: AgendaItemModel, draft: AgendaDraft, by memberID: String) throws; func delete(_ item: AgendaItemModel, by memberID: String) throws; func save(exception: AgendaExceptionModel, for item: AgendaItemModel, by memberID: String) throws; func delete(exception: AgendaExceptionModel, for item: AgendaItemModel, by memberID: String) throws; func markFoodRead(_ item: AgendaItemModel, by memberID: String) throws; func setCompletion(_ item: AgendaItemModel, state: CompletionState, by memberID: String) throws }
@MainActor protocol ScheduleRepository { func entries() throws -> [ScheduleEntryModel]; func exceptions() throws -> [ScheduleExceptionModel]; func calendarOverrides() throws -> [CalendarOverrideModel]; func save(_ entry: ScheduleEntryModel, draft: ScheduleDraft, by memberID: String) throws; func delete(_ entry: ScheduleEntryModel, by memberID: String) throws; func save(exception: ScheduleExceptionModel, by memberID: String) throws; func delete(exception: ScheduleExceptionModel, by memberID: String) throws; func save(calendarOverride: CalendarOverrideModel) throws; func delete(calendarOverride: CalendarOverrideModel) throws }
@MainActor protocol MemoRepository { func memos() throws -> [MemoModel]; func create(draft: MemoDraft, by memberID: String) throws; func save(_ memo: MemoModel, draft: MemoDraft, expectedVersion: Int, by memberID: String) throws; func delete(_ memo: MemoModel, by memberID: String) throws }
@MainActor protocol NoticeRepository { func notices() throws -> [NoticeModel]; func markRead(_ notice: NoticeModel, memberID: String) throws; func create(draft: NoticeDraft, by memberID: String) throws; func save(_ notice: NoticeModel, draft: NoticeDraft, by memberID: String) throws; func delete(_ notice: NoticeModel, by memberID: String) throws }
@MainActor protocol LocationRepository { func snapshots() throws -> [LocationSnapshotModel]; func places() throws -> [FamilyPlaceModel]; func add(_ snapshot: LocationSnapshotModel) throws; func save(_ place: FamilyPlaceModel) throws; func delete(_ place: FamilyPlaceModel) throws; func purgeHistory(now: Date) throws }

enum RepositoryError: LocalizedError { case versionConflict, forbidden, invalidData, recallExpired
    var errorDescription: String? { switch self { case .versionConflict: return "这条备忘录已被其他成员修改，请查看最新内容后再保存。"; case .forbidden: return "当前成员没有执行此操作的权限。"; case .invalidData: return "数据无效，请检查日期、周次和时间。"; case .recallExpired: return "消息发送超过 5 分钟，不能撤回。" } }
}

struct ScheduleDraft {
    var title: String; var kind: ScheduleKind; var weekday: Int; var startMinutes: Int; var endMinutes: Int
    var startWeek: Int; var endWeek: Int; var weekType: WeekType
    var major: String?; var grade: String?; var className: String?; var location: String?; var note: String?; var labName: String?; var advisor: String?
}

@MainActor final class LocalChatRepository: ChatRepository {
    private let context: ModelContext; private let mediaStore: LocalMediaStore
    init(context: ModelContext, mediaStore: LocalMediaStore) { self.context = context; self.mediaStore = mediaStore }
    func messages() throws -> [ChatMessageModel] { try context.fetch(FetchDescriptor<ChatMessageModel>(sortBy: [SortDescriptor(\.sentAt)])) }
    func create(_ message: ChatMessageModel) throws { context.insert(message); try context.save() }
    func recall(_ message: ChatMessageModel, by memberID: String, now: Date = .now) throws {
        guard message.senderID == memberID else { throw RepositoryError.forbidden }
        guard now.timeIntervalSince(message.sentAt) <= 300 else { throw RepositoryError.recallExpired }
        if let path = message.mediaPath { try mediaStore.remove(path: path) }
        message.body = "该消息已被撤回"; message.kindRaw = MessageKind.recalled.rawValue; message.mediaPath = nil; message.recalledAt = now
        try context.save()
    }
    func retry(_ message: ChatMessageModel, by memberID: String) throws { guard message.senderID == memberID, message.status == .failed else { throw RepositoryError.forbidden }; message.statusRaw = ReceiptStatus.sending.rawValue; try context.save() }
    func markIncomingMessagesRead(by memberID: String) throws {
        guard MemberID(rawValue: memberID) != nil else { throw RepositoryError.forbidden }
        let incoming = try messages().filter { $0.senderID != memberID && $0.isUnread }
        guard !incoming.isEmpty else { return }
        for message in incoming { message.isUnread = false; if message.status != .failed { message.statusRaw = ReceiptStatus.read.rawValue } }
        try context.save()
    }
}

/// Deterministic local-only receipt simulation. It never represents a network delivery.
@MainActor final class DemoChatTransport {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }
    func simulateReceipts(for message: ChatMessageModel) {
        Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(350)); message.statusRaw = ReceiptStatus.sent.rawValue; try context.save(); try await Task.sleep(for: .milliseconds(650)); guard message.kind != .recalled else { return }; message.statusRaw = ReceiptStatus.delivered.rawValue; try context.save(); try await Task.sleep(for: .milliseconds(900)); guard message.kind != .recalled else { return }; message.statusRaw = ReceiptStatus.read.rawValue; try context.save() } catch { message.statusRaw = ReceiptStatus.failed.rawValue; do { try context.save() } catch { assertionFailure("Unable to persist demo receipt failure: \(error.localizedDescription)") } }
        }
    }
}
@MainActor final class LocalAgendaRepository: AgendaRepository {
    private let context: ModelContext; init(context: ModelContext) { self.context = context }
    func items() throws -> [AgendaItemModel] { try context.fetch(FetchDescriptor<AgendaItemModel>(sortBy: [SortDescriptor(\.start), SortDescriptor(\.dueAt)])) }
    func save(_ item: AgendaItemModel, draft: AgendaDraft, by memberID: String) throws {
        guard item.modelContext == nil || item.creatorID == memberID else { throw RepositoryError.forbidden }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let validParticipants = !draft.participantIDs.isEmpty && Set(draft.participantIDs).isSubset(of: Set(MemberID.allCases.map(\.rawValue)))
        let validTimed = draft.start != nil && draft.end != nil && draft.start! < draft.end!
        let validDeadline = draft.kind != .assignmentDeadline || draft.dueAt != nil
        let validFood = draft.kind != .orderFood || !(draft.dishes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard !title.isEmpty,
              validParticipants,
              (draft.kind != .normal && draft.kind != .exam || validTimed),
              validDeadline,
              validFood,
              (draft.recurrence == .none || (draft.kind == .normal || draft.kind == .exam) && draft.recurrenceEnd != nil && draft.recurrenceEnd! >= Calendar.autoupdatingCurrent.startOfDay(for: draft.start!)) else { throw RepositoryError.invalidData }
        if item.modelContext == nil { context.insert(item) }
        let supportsRecurrence = draft.kind == .normal || draft.kind == .exam
        if !supportsRecurrence {
            for exception in try context.fetch(FetchDescriptor<AgendaExceptionModel>()) where exception.agendaID == item.id { context.delete(exception) }
        }
        item.title = title; item.kindRaw = draft.kind.rawValue; item.start = draft.start; item.end = draft.end; item.dueAt = draft.dueAt; item.location = draft.location; item.note = draft.note; item.participantIDs = draft.participantIDs; item.recurrenceRaw = supportsRecurrence ? draft.recurrence.rawValue : AgendaRecurrence.none.rawValue; item.recurrenceEnd = supportsRecurrence && draft.recurrence != .none ? draft.recurrenceEnd : nil; item.dishes = draft.dishes; item.ingredients = draft.ingredients; item.seasonings = draft.seasonings; item.peopleCount = draft.peopleCount; item.estimatedArrival = draft.estimatedArrival; item.desiredMealTime = draft.desiredMealTime; item.preparationRaw = draft.preparation?.rawValue; item.completionRaw = draft.completion?.rawValue
        try context.save()
    }
    func delete(_ item: AgendaItemModel, by memberID: String) throws {
        guard item.creatorID == memberID else { throw RepositoryError.forbidden }
        for exception in try context.fetch(FetchDescriptor<AgendaExceptionModel>()) where exception.agendaID == item.id { context.delete(exception) }
        context.delete(item)
        try context.save()
    }
    func save(exception: AgendaExceptionModel, for item: AgendaItemModel, by memberID: String) throws {
        guard item.creatorID == memberID, exception.agendaID == item.id else { throw RepositoryError.forbidden }
        guard item.recurrence != .none,
              TimeAnalysisService().isAgendaOccurrence(item, on: exception.occurrenceDate) else { throw RepositoryError.invalidData }
        if exception.kind != .cancelled {
            guard let start = exception.replacementStart, let end = exception.replacementEnd, start < end else { throw RepositoryError.invalidData }
        }
        if exception.modelContext == nil { context.insert(exception) }
        try context.save()
    }
    func delete(exception: AgendaExceptionModel, for item: AgendaItemModel, by memberID: String) throws { guard item.creatorID == memberID, exception.agendaID == item.id else { throw RepositoryError.forbidden }; context.delete(exception); try context.save() }
    func markFoodRead(_ item: AgendaItemModel, by memberID: String) throws {
        guard item.kind == .orderFood, item.participantIDs.contains(memberID) else { throw RepositoryError.forbidden }
        var records = (item.foodReadAtRecords ?? []).filter { !$0.hasPrefix("\(memberID)|") }
        records.append("\(memberID)|\(Date.now.timeIntervalSince1970)")
        item.foodReadAtRecords = records
        try context.save()
    }
    func setCompletion(_ item: AgendaItemModel, state: CompletionState, by memberID: String) throws {
        guard item.kind == .assignmentDeadline, item.participantIDs.contains(memberID) else { throw RepositoryError.forbidden }
        item.completionRaw = state.rawValue; try context.save()
    }
}
@MainActor final class LocalScheduleRepository: ScheduleRepository {
    private let context: ModelContext; init(context: ModelContext) { self.context = context }
    func entries() throws -> [ScheduleEntryModel] { try context.fetch(FetchDescriptor<ScheduleEntryModel>()) }
    func exceptions() throws -> [ScheduleExceptionModel] { try context.fetch(FetchDescriptor<ScheduleExceptionModel>()) }
    func calendarOverrides() throws -> [CalendarOverrideModel] { try context.fetch(FetchDescriptor<CalendarOverrideModel>()) }
    func save(_ entry: ScheduleEntryModel, draft: ScheduleDraft, by memberID: String) throws {
        guard entry.ownerID == memberID else { throw RepositoryError.forbidden }
        guard let semester = try context.fetch(FetchDescriptor<SemesterModel>()).first(where: { $0.id == entry.semesterID }) else { throw RepositoryError.invalidData }
        let candidate = ScheduleEntryModel(ownerID: entry.ownerID, semesterID: entry.semesterID, title: draft.title, kind: draft.kind, weekday: draft.weekday, startMinutes: draft.startMinutes, endMinutes: draft.endMinutes, startWeek: draft.startWeek, endWeek: draft.endWeek, weekType: draft.weekType, major: draft.major, grade: draft.grade, className: draft.className, location: draft.location, note: draft.note, labName: draft.labName, advisor: draft.advisor)
        guard !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              TimeAnalysisService.isValid(candidate, totalWeeks: semester.totalWeeks) else { throw RepositoryError.invalidData }
        if entry.modelContext == nil { context.insert(entry) }
        entry.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines); entry.kindRaw = draft.kind.rawValue; entry.weekday = draft.weekday; entry.startMinutes = draft.startMinutes; entry.endMinutes = draft.endMinutes; entry.startWeek = draft.startWeek; entry.endWeek = draft.endWeek; entry.weekTypeRaw = draft.weekType.rawValue; entry.major = draft.major; entry.grade = draft.grade; entry.className = draft.className; entry.location = draft.location; entry.note = draft.note; entry.labName = draft.labName; entry.advisor = draft.advisor
        try context.save()
    }
    func delete(_ entry: ScheduleEntryModel, by memberID: String) throws {
        guard entry.ownerID == memberID else { throw RepositoryError.forbidden }
        for exception in try exceptions() where exception.scheduleID == entry.id { context.delete(exception) }
        context.delete(entry)
        try context.save()
    }
    func save(exception: ScheduleExceptionModel, by memberID: String) throws {
        let entries = try entries()
        guard let entry = entries.first(where: { $0.id == exception.scheduleID }), entry.ownerID == memberID else { throw RepositoryError.forbidden }
        guard let semester = try context.fetch(FetchDescriptor<SemesterModel>()).first(where: { $0.id == entry.semesterID }) else { throw RepositoryError.invalidData }
        guard (1...7).contains(exception.replacementWeekday ?? 1) || exception.replacementWeekday == nil,
              exception.replacementStartMinutes.map({ (0..<1_440).contains($0) }) ?? true,
              exception.replacementEndMinutes.map({ (1...1_440).contains($0) }) ?? true,
              exception.replacementStartMinutes == nil || exception.replacementEndMinutes == nil || exception.replacementStartMinutes! < exception.replacementEndMinutes! else { throw RepositoryError.invalidData }
        if exception.kind != .cancelled {
            guard exception.replacementDate != nil, exception.replacementStartMinutes != nil, exception.replacementEndMinutes != nil else { throw RepositoryError.invalidData }
        }
        let calendar = try calendarOverrides().filter { $0.semesterID == semester.id }
        guard TimeAnalysisService().isScheduleOccurrenceCandidate(entry, on: exception.occurrenceDate, calendarOverrides: calendar, semester: semester) else { throw RepositoryError.invalidData }
        if exception.modelContext == nil { context.insert(exception) }; try context.save()
    }
    func delete(exception: ScheduleExceptionModel, by memberID: String) throws {
        let entries = try entries()
        guard entries.first(where: { $0.id == exception.scheduleID })?.ownerID == memberID else { throw RepositoryError.forbidden }
        context.delete(exception)
        try context.save()
    }
    func save(calendarOverride: CalendarOverrideModel) throws {
        guard let semester = try context.fetch(FetchDescriptor<SemesterModel>()).first(where: { $0.id == calendarOverride.semesterID }),
              semester.weekNumber(on: calendarOverride.date) != nil,
              (calendarOverride.kind != .mappedWeekday || (calendarOverride.mappedWeekday.map { (1...7).contains($0) } ?? false)) else { throw RepositoryError.invalidData }
        let normalizedDay = Calendar.autoupdatingCurrent.startOfDay(for: calendarOverride.date)
        guard !(try calendarOverrides()).contains(where: { $0.id != calendarOverride.id && $0.semesterID == calendarOverride.semesterID && Calendar.autoupdatingCurrent.isDate($0.date, inSameDayAs: normalizedDay) }) else { throw RepositoryError.invalidData }
        if calendarOverride.modelContext == nil { context.insert(calendarOverride) }
        calendarOverride.date = normalizedDay
        try context.save()
    }
    func delete(calendarOverride: CalendarOverrideModel) throws { context.delete(calendarOverride); try context.save() }
}
@MainActor final class LocalMemoRepository: MemoRepository {
    private let context: ModelContext; init(context: ModelContext) { self.context = context }
    func memos() throws -> [MemoModel] { try context.fetch(FetchDescriptor<MemoModel>()).sorted { $0.pinned == $1.pinned ? $0.updatedAt > $1.updatedAt : $0.pinned && !$1.pinned } }
    func create(draft: MemoDraft, by memberID: String) throws { guard MemberID(rawValue: memberID) != nil else { throw RepositoryError.forbidden }; context.insert(MemoModel(title: draft.title, content: draft.content, creatorID: memberID, pinned: draft.pinned, updatedBy: memberID)); try context.save() }
    func save(_ memo: MemoModel, draft: MemoDraft, expectedVersion: Int, by memberID: String) throws {
        guard MemberID(rawValue: memberID) != nil else { throw RepositoryError.forbidden }
        guard memo.version == expectedVersion else { throw RepositoryError.versionConflict }
        memo.title = draft.title; memo.content = draft.content; memo.pinned = draft.pinned; memo.updatedBy = memberID; memo.version += 1; memo.updatedAt = .now
        try context.save()
    }
    func delete(_ memo: MemoModel, by memberID: String) throws { guard memo.creatorID == memberID else { throw RepositoryError.forbidden }; context.delete(memo); try context.save() }
}
@MainActor final class LocalNoticeRepository: NoticeRepository {
    private let context: ModelContext; init(context: ModelContext) { self.context = context }
    func notices() throws -> [NoticeModel] { try context.fetch(FetchDescriptor<NoticeModel>()).sorted { lhs, rhs in lhs.pinned == rhs.pinned ? (lhs.pinned ? lhs.updatedAt > rhs.updatedAt : lhs.createdAt > rhs.createdAt) : lhs.pinned && !rhs.pinned } }
    func create(draft: NoticeDraft, by memberID: String) throws { guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RepositoryError.invalidData }; context.insert(NoticeModel(title: draft.title, content: draft.content, publisherID: memberID, pinned: draft.pinned)); try context.save() }
    func save(_ notice: NoticeModel, draft: NoticeDraft, by memberID: String) throws { guard notice.publisherID == memberID else { throw RepositoryError.forbidden }; guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RepositoryError.invalidData }; notice.title = draft.title; notice.content = draft.content; notice.pinned = draft.pinned; notice.isEdited = true; notice.updatedAt = .now; try context.save() }
    func delete(_ notice: NoticeModel, by memberID: String) throws {
        guard notice.publisherID == memberID else { throw RepositoryError.forbidden }
        for read in try context.fetch(FetchDescriptor<NoticeReadModel>()) where read.noticeID == notice.id { context.delete(read) }
        context.delete(notice)
        try context.save()
    }
    func markRead(_ notice: NoticeModel, memberID: String) throws { guard notice.publisherID != memberID else { return }; let reads = try context.fetch(FetchDescriptor<NoticeReadModel>()); if !reads.contains(where: { $0.noticeID == notice.id && $0.memberID == memberID }) { context.insert(NoticeReadModel(noticeID: notice.id, memberID: memberID)); try context.save() } }
}
@MainActor final class LocalLocationRepository: LocationRepository {
    private let context: ModelContext; init(context: ModelContext) { self.context = context }
    func snapshots() throws -> [LocationSnapshotModel] { try context.fetch(FetchDescriptor<LocationSnapshotModel>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])) }
    func places() throws -> [FamilyPlaceModel] { try context.fetch(FetchDescriptor<FamilyPlaceModel>()) }
    func add(_ snapshot: LocationSnapshotModel) throws { context.insert(snapshot); try context.save() }
    func save(_ place: FamilyPlaceModel) throws { guard !place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, [100, 200, 500, 1000].contains(Int(place.radius)), (-90...90).contains(place.latitude), (-180...180).contains(place.longitude), place.memberID.map({ MemberID(rawValue: $0) != nil }) ?? true else { throw RepositoryError.invalidData }; if place.modelContext == nil { context.insert(place) }; try context.save() }
    func delete(_ place: FamilyPlaceModel) throws { context.delete(place); try context.save() }
    func purgeHistory(now: Date = .now) throws { let calendar = Calendar.autoupdatingCurrent; let cutoff = calendar.date(byAdding: .day, value: -30, to: now) ?? now; for item in try snapshots() where item.timestamp < cutoff { context.delete(item) }; try context.save() }
}

enum KeychainError: LocalizedError { case emptyKey
    var errorDescription: String? { "API Key 不能为空。" }
}

final class KeychainService {
    private let service = "FamilyApp.AIKey"
    func saveAPIKey(_ key: String) throws { let value = key.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty else { throw KeychainError.emptyKey }; let data = Data(value.utf8); SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary); let result = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary, nil); guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) } }
    func apiKey() -> String? { var item: CFTypeRef?; let result = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecReturnData: true] as CFDictionary, &item); guard result == errSecSuccess, let data = item as? Data else { return nil }; return String(data: data, encoding: .utf8) }
    func clear() { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary) }
}

final class LocalMediaStore {
    private let root: URL
    init() { root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FamilyMedia", isDirectory: true); do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) } catch { fatalError("Unable to create local media directory: \(error.localizedDescription)") } }
    /// Re-renders pixels before JPEG encoding so orientation and source metadata (including EXIF/GPS) are not retained.
    func storeImage(_ data: Data) throws -> String {
        guard let input = UIImage(data: data) else { throw RepositoryError.invalidData }
        let maximum: CGFloat = 1_600; let scale = min(1, maximum / max(input.size.width, input.size.height)); let size = CGSize(width: max(1, input.size.width * scale), height: max(1, input.size.height * scale))
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in input.draw(in: CGRect(origin: .zero, size: size)) }
        guard let encoded = rendered.jpegData(compressionQuality: 0.82) else { throw RepositoryError.invalidData }
        let name = UUID().uuidString + ".jpg"; try encoded.write(to: root.appendingPathComponent(name), options: .atomic); return name
    }
    func storeAudio(from source: URL) throws -> String { let name = UUID().uuidString + ".m4a"; let destination = root.appendingPathComponent(name); try FileManager.default.copyItem(at: source, to: destination); return name }
    func url(for path: String) -> URL { root.appendingPathComponent(path) }
    func remove(path: String) throws { let url = url(for: path); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
    func clear() throws { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func makeDemoImage() throws -> String { let renderer = UIGraphicsImageRenderer(size: CGSize(width: 560, height: 320)); let image = renderer.image { ctx in UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 560, height: 320)); let text = "家庭晚餐" as NSString; text.draw(at: CGPoint(x: 180, y: 130), withAttributes: [.font: UIFont.systemFont(ofSize: 38, weight: .semibold), .foregroundColor: UIColor.white]) }; return try storeImage(image.jpegData(compressionQuality: 0.85) ?? Data()) }
    func makeDemoTone() throws -> String {
        let name = UUID().uuidString + ".m4a"; let url = root.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!; let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        let file = try AVAudioFile(forWriting: url, settings: settings); let frames: AVAudioFrameCount = 22_050; guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let samples = buffer.floatChannelData?[0] else { throw NSError(domain: "FamilyMedia", code: 1) }; buffer.frameLength = frames
        for i in 0..<Int(frames) { samples[i] = Float(sin(2 * Double.pi * 440 * Double(i) / 44_100)) * 0.12 }
        try file.write(from: buffer); return name
    }
}

protocol LocationProvider { func locations(now: Date) -> [LocationSnapshotModel] }
struct DemoLocationProvider: LocationProvider { func locations(now: Date) -> [LocationSnapshotModel] { [LocationSnapshotModel(memberID: MemberID.sendai.rawValue, latitude: 35.6812, longitude: 139.7671, timestamp: now.addingTimeInterval(-600), event: "arrive 学校"), LocationSnapshotModel(memberID: MemberID.osaka.rawValue, latitude: 35.6762, longitude: 139.6503, timestamp: now.addingTimeInterval(-1800), event: "leave 家"), LocationSnapshotModel(memberID: MemberID.kyoto.rawValue, latitude: 35.0116, longitude: 135.7681, timestamp: now.addingTimeInterval(-3600), event: nil)] } }

struct FoodIconResolver {
    func symbol(for dish: String, category: String? = nil) -> String { let value = (dish + (category ?? "")).lowercased(); if value.contains("鱼") { return "fish" }; if value.contains("汤") { return "takeoutbag.and.cup.and.straw" }; if value.contains("面") { return "fork.knife" }; if value.contains("肉") { return "fork.knife.circle" }; return "takeoutbag.and.cup.and.straw" }
    func ingredients(for dish: String) -> String? { ["番茄牛腩": "牛腩、番茄、洋葱；盐、胡椒" ][dish] }
}

struct TimeAnalysisService {
    let calendar: Calendar = .autoupdatingCurrent
    static func isValid(_ entry: ScheduleEntryModel, totalWeeks: Int? = nil) -> Bool { (1...7).contains(entry.weekday) && (0..<1_440).contains(entry.startMinutes) && (1...1_440).contains(entry.endMinutes) && entry.startMinutes < entry.endMinutes && entry.startWeek > 0 && entry.startWeek <= entry.endWeek && (totalWeeks.map { entry.endWeek <= $0 } ?? true) && WeekType(rawValue: entry.weekTypeRaw) != nil && MemberID(rawValue: entry.ownerID) != nil }
    func weekNumber(on date: Date, semester: SemesterModel) -> Int? {
        semester.weekNumber(on: date, calendar: calendar)
    }
    /// Validates that a date has an actual periodic-schedule candidate before
    /// individual exceptions are applied. A holiday candidate is intentionally
    /// retained so a course-specific reschedule can override that holiday.
    func isScheduleOccurrenceCandidate(_ entry: ScheduleEntryModel, on date: Date, calendarOverrides: [CalendarOverrideModel], semester: SemesterModel) -> Bool {
        guard entry.semesterID == semester.id, Self.isValid(entry, totalWeeks: semester.totalWeeks),
              let week = semester.weekNumber(on: date, calendar: calendar),
              (entry.startWeek...entry.endWeek).contains(week), matches(entry.weekType, week: week) else { return false }
        let day = calendar.startOfDay(for: date)
        let natural = calendar.component(.weekday, from: day)
        return natural == entry.weekday || effectiveWeekday(on: day, overrides: calendarOverrides, semesterID: semester.id) == entry.weekday
    }
    func busyIntervals(memberIDs: [String], in range: DateInterval, entries: [ScheduleEntryModel], exceptions: [ScheduleExceptionModel], agendas: [AgendaItemModel], agendaExceptions: [AgendaExceptionModel] = [], calendarOverrides: [CalendarOverrideModel] = [], semester: SemesterModel) -> [String: [BusyInterval]] {
        guard range.start < range.end else { return [:] }
        let people = memberIDs.filter { MemberID(rawValue: $0) != nil }
        var result: [String: [BusyInterval]] = Dictionary(uniqueKeysWithValues: people.map { ($0, []) })
        for entry in entries where people.contains(entry.ownerID) && entry.semesterID == semester.id && Self.isValid(entry, totalWeeks: semester.totalWeeks) {
            for interval in scheduleIntervals(entry, exceptions: exceptions.filter { $0.scheduleID == entry.id }, calendarOverrides: calendarOverrides, semester: semester, intersecting: range) { result[entry.ownerID, default: []].append(interval) }
        }
        for agenda in agendas where agenda.kind == .normal || agenda.kind == .exam {
            for occurrence in agendaOccurrences(agenda, exceptions: agendaExceptions.filter { $0.agendaID == agenda.id }, in: range) {
                for member in agenda.participantIDs where people.contains(member) { result[member, default: []].append(BusyInterval(start: occurrence.start, end: occurrence.end, source: agenda.title)) }
            }
        }
        return result.mapValues(merge)
    }
    /// The schedule screen consumes these resolved instances, so the grid and
    /// availability analysis cannot diverge on week rules or exceptions.
    func scheduleOccurrences(in range: DateInterval, entries: [ScheduleEntryModel], exceptions: [ScheduleExceptionModel], calendarOverrides: [CalendarOverrideModel] = [], semester: SemesterModel, memberIDs: Set<String>? = nil) -> [ScheduleOccurrence] {
        entries
            .filter { $0.semesterID == semester.id && Self.isValid($0, totalWeeks: semester.totalWeeks) && (memberIDs == nil || memberIDs!.contains($0.ownerID)) }
            .flatMap { entry in
                scheduleIntervals(entry, exceptions: exceptions.filter { $0.scheduleID == entry.id }, calendarOverrides: calendarOverrides, semester: semester, intersecting: range).map {
                    ScheduleOccurrence(entryID: entry.id, ownerID: entry.ownerID, start: $0.start, end: $0.end, title: entry.title, kind: entry.kind, location: entry.location, grade: entry.grade, className: entry.className)
                }
            }
    }
    func commonFree(memberIDs: [String], range: DateInterval, minimumMinutes: Int, entries: [ScheduleEntryModel], exceptions: [ScheduleExceptionModel], agendas: [AgendaItemModel], agendaExceptions: [AgendaExceptionModel] = [], calendarOverrides: [CalendarOverrideModel] = [], semester: SemesterModel) -> [AvailabilitySlot] {
        let people = Array(Set(memberIDs)).sorted(); guard people.count >= 2, minimumMinutes > 0 else { return [] }
        let busy = busyIntervals(memberIDs: people, in: range, entries: entries, exceptions: exceptions, agendas: agendas, agendaExceptions: agendaExceptions, calendarOverrides: calendarOverrides, semester: semester); let combined = merge(people.flatMap { busy[$0] ?? [] }); var slots: [AvailabilitySlot] = []; var cursor = range.start
        for interval in combined { if cursor < interval.start { let candidate = AvailabilitySlot(start: cursor, end: interval.start, participants: memberIDs); if calendar.dateComponents([.minute], from: candidate.start, to: candidate.end).minute ?? 0 >= minimumMinutes { slots.append(candidate) } }; if interval.end > cursor { cursor = interval.end } }
        if cursor < range.end { let candidate = AvailabilitySlot(start: cursor, end: range.end, participants: memberIDs); if calendar.dateComponents([.minute], from: candidate.start, to: candidate.end).minute ?? 0 >= minimumMinutes { slots.append(candidate) } }; return slots
    }
    private func matches(_ type: WeekType, week: Int) -> Bool { type == .everyWeek || (type == .oddWeek && week % 2 == 1) || (type == .evenWeek && week % 2 == 0) }
    private func date(on day: Date, minutes: Int) -> Date? { guard (0..<1_440).contains(minutes) else { return nil }; return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) }
    private func scheduleIntervals(_ entry: ScheduleEntryModel, exceptions: [ScheduleExceptionModel], calendarOverrides: [CalendarOverrideModel], semester: SemesterModel, intersecting range: DateInterval) -> [BusyInterval] {
        guard semester.totalWeeks > 0, entry.startWeek <= semester.totalWeeks else { return [] }
        let firstWeek = max(1, entry.startWeek)
        let lastWeek = min(entry.endWeek, semester.totalWeeks)
        guard firstWeek <= lastWeek else { return [] }

        // A calendar override changes which weekday's schedule applies to a
        // real date. Enumerating term dates here keeps the grid, conflicts and
        // availability on one final-instance source of truth.
        return academicDays(semester: semester).compactMap { day in
            guard let week = semester.weekNumber(on: day, calendar: calendar),
                  (firstWeek...lastWeek).contains(week), matches(entry.weekType, week: week),
                  let start = date(on: day, minutes: entry.startMinutes),
                  let end = date(on: day, minutes: entry.endMinutes) else { return nil }
            let naturalWeekday = calendar.component(.weekday, from: day)
            let mappedWeekday = effectiveWeekday(on: day, overrides: calendarOverrides, semesterID: semester.id)
            let isScheduledByCalendar = mappedWeekday == entry.weekday
            let hasIndividualException = (naturalWeekday == entry.weekday || isScheduledByCalendar) && hasApplicableScheduleException(exceptions, originalStart: start)
            // Individual cancellation/reschedule/temporary rules deliberately
            // win over a holiday or mapping. Without an individual rule, the
            // academic calendar is the final source for this day.
            guard hasIndividualException || isScheduledByCalendar,
                  let occurrence = apply(scheduleExceptions: exceptions, originalStart: start, originalEnd: end),
                  occurrence.end > range.start, occurrence.start < range.end else { return nil }
            return BusyInterval(start: occurrence.start, end: occurrence.end, source: entry.title)
        }
    }

    private func academicDays(semester: SemesterModel) -> [Date] {
        guard let range = semester.academicDateRange(calendar: calendar) else { return [] }
        var result: [Date] = []
        var cursor = range.start
        while cursor < range.end {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// nil means a holiday: no periodic schedule is produced for that day.
    private func effectiveWeekday(on day: Date, overrides: [CalendarOverrideModel], semesterID: UUID) -> Int? {
        let actual = calendar.component(.weekday, from: day)
        guard let override = overrides.first(where: { $0.semesterID == semesterID && calendar.isDate($0.date, inSameDayAs: day) }) else { return actual }
        switch override.kind {
        case .holiday: return nil
        case .normal: return actual
        case .mappedWeekday: return override.mappedWeekday
        }
    }
    private func apply(scheduleExceptions: [ScheduleExceptionModel], originalStart: Date, originalEnd: Date) -> (start: Date, end: Date)? {
        var result = (start: originalStart, end: originalEnd)
        let applicable = applicableScheduleExceptions(scheduleExceptions, originalStart: originalStart)
        for exception in applicable {
            if exception.kind == .cancelled { return nil }
            let targetDay: Date
            if exception.scope == .thisOccurrence, let replacement = exception.replacementDate {
                targetDay = replacement
            } else if exception.scope == .thisAndFuture, let replacement = exception.replacementDate {
                // A series change carries the weekday offset forward; it must not
                // pin every future occurrence to the calendar week of the edit.
                let delta = calendar.dateComponents([.day], from: calendar.startOfDay(for: exception.occurrenceDate), to: calendar.startOfDay(for: replacement)).day ?? 0
                targetDay = calendar.date(byAdding: .day, value: delta, to: calendar.startOfDay(for: originalStart)) ?? originalStart
            } else if let weekday = exception.replacementWeekday {
                let current = calendar.component(.weekday, from: originalStart)
                targetDay = calendar.date(byAdding: .day, value: weekday - current, to: calendar.startOfDay(for: originalStart)) ?? originalStart
            } else {
                targetDay = calendar.startOfDay(for: originalStart)
            }
            let startMinute = exception.replacementStartMinutes ?? calendar.component(.hour, from: result.start) * 60 + calendar.component(.minute, from: result.start)
            let endMinute = exception.replacementEndMinutes ?? calendar.component(.hour, from: result.end) * 60 + calendar.component(.minute, from: result.end)
            guard startMinute < endMinute, let newStart = date(on: targetDay, minutes: startMinute), let newEnd = date(on: targetDay, minutes: endMinute) else { return nil }
            result = (newStart, newEnd)
        }
        return result
    }
    private func hasApplicableScheduleException(_ exceptions: [ScheduleExceptionModel], originalStart: Date) -> Bool {
        !applicableScheduleExceptions(exceptions, originalStart: originalStart).isEmpty
    }
    private func applicableScheduleExceptions(_ exceptions: [ScheduleExceptionModel], originalStart: Date) -> [ScheduleExceptionModel] {
        exceptions.filter { exception in
            switch exception.scope { case .thisOccurrence: return calendar.isDate(originalStart, inSameDayAs: exception.occurrenceDate); case .thisAndFuture: return originalStart >= calendar.startOfDay(for: exception.occurrenceDate); case .entireSeries: return true }
        }.sorted { $0.occurrenceDate < $1.occurrenceDate }
    }
    private func merge(_ intervals: [BusyInterval]) -> [BusyInterval] { let sorted = intervals.sorted { $0.start < $1.start }; var result: [BusyInterval] = []; for interval in sorted { if let last = result.last, interval.start < last.end { result.removeLast(); result.append(BusyInterval(start: last.start, end: max(last.end, interval.end), source: last.source)) } else { result.append(interval) } }; return result }
    func isAgendaOccurrence(_ agenda: AgendaItemModel, on date: Date) -> Bool {
        guard let start = agenda.start, let end = agenda.end, start < end else { return false }
        let target = calendar.startOfDay(for: date)
        let first = calendar.startOfDay(for: start)
        guard target >= first else { return false }
        if let recurrenceEnd = agenda.recurrenceEnd, target > calendar.startOfDay(for: recurrenceEnd) { return false }
        switch agenda.recurrence {
        case .none: return calendar.isDate(start, inSameDayAs: target)
        case .daily: return true
        case .weekly:
            let days = calendar.dateComponents([.day], from: first, to: target).day ?? -1
            return days >= 0 && days % 7 == 0
        }
    }
    private func agendaOccurrences(_ agenda: AgendaItemModel, exceptions: [AgendaExceptionModel], in range: DateInterval) -> [(start: Date, end: Date)] {
        guard let baseStart = agenda.start, let baseEnd = agenda.end, baseStart < baseEnd else { return [] }
        var starts: [Date] = []
        let unit: Calendar.Component = agenda.recurrence == .daily ? .day : .weekOfYear
        let recurrenceEndExclusive = agenda.recurrenceEnd.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
        var start = baseStart
        while start < range.end && (agenda.recurrence == .none || recurrenceEndExclusive == nil || start < recurrenceEndExclusive!) {
            starts.append(start)
            guard agenda.recurrence != .none, let next = calendar.date(byAdding: unit, value: 1, to: start) else { break }
            start = next
        }
        let duration = baseEnd.timeIntervalSince(baseStart)
        return starts.compactMap { base in
            var result = (start: base, end: base.addingTimeInterval(duration))
            for exception in exceptions.filter({ ex in switch ex.scope { case .thisOccurrence: return calendar.isDate(base, inSameDayAs: ex.occurrenceDate); case .thisAndFuture: return base >= calendar.startOfDay(for: ex.occurrenceDate); case .entireSeries: return true } }).sorted(by: { $0.occurrenceDate < $1.occurrenceDate }) {
                if exception.kind == .cancelled { return nil }
                if exception.scope == .thisOccurrence, let replacementStart = exception.replacementStart, let replacementEnd = exception.replacementEnd, replacementStart < replacementEnd {
                    result = (replacementStart, replacementEnd)
                } else if let replacementStart = exception.replacementStart, let replacementEnd = exception.replacementEnd, replacementStart < replacementEnd {
                    // Rules move forward with each recurrence. Storing the same
                    // absolute date here would incorrectly collapse all future
                    // occurrences onto one day.
                    let dayDelta = calendar.dateComponents([.day], from: calendar.startOfDay(for: exception.occurrenceDate), to: calendar.startOfDay(for: replacementStart)).day ?? 0
                    let day = calendar.date(byAdding: .day, value: dayDelta, to: calendar.startOfDay(for: base)) ?? base
                    let startMinute = calendar.component(.hour, from: replacementStart) * 60 + calendar.component(.minute, from: replacementStart)
                    guard let adjustedStart = date(on: day, minutes: startMinute) else { return nil }
                    result = (adjustedStart, adjustedStart.addingTimeInterval(replacementEnd.timeIntervalSince(replacementStart)))
                } else if exception.scope == .thisOccurrence, let replacement = exception.replacementDate {
                    result = (replacement, replacement.addingTimeInterval(duration))
                }
            }
            return result.end > range.start && result.start < range.end ? result : nil
        }
    }
}

enum AIClientError: LocalizedError { case invalidURL, insecureURL, missingKey, missingConfiguration, badResponse
    var errorDescription: String? { switch self { case .invalidURL: return "Base URL 无效。"; case .insecureURL: return "此版本仅允许 HTTPS 地址（DEBUG 下仅可使用本机地址）。"; case .missingKey: return "请先在设置中保存 API Key。"; case .missingConfiguration: return "请先在设置中启用 AI，并填写 Base URL 与 Model。"; case .badResponse: return "AI 服务返回的数据无法解析。" } }
}
struct AIService {
    let keychain: KeychainService
    func normalizedBaseURL(_ raw: String) throws -> URL { guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), let host = components.host else { throw AIClientError.invalidURL }; #if DEBUG
        let local = host == "localhost" || host == "127.0.0.1"; guard components.scheme == "https" || (components.scheme == "http" && local) else { throw AIClientError.insecureURL }
        #else
        guard components.scheme == "https" else { throw AIClientError.insecureURL }
        #endif
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = components.path.isEmpty ? "" : "/" + components.path
        components.query = nil; components.fragment = nil
        guard let url = components.url else { throw AIClientError.invalidURL }; return url
    }
    func testConnection(baseURL: String, model: String) async throws { _ = try await request(baseURL: baseURL, model: model, messages: [["role": "user", "content": "ping"]], maxTokens: 1, requireContent: false) }
    /// Makes a real OpenAI-compatible request but returns a draft only. Callers
    /// must present and explicitly apply it; this service never sees SwiftData.
    func generateBusinessDraft(baseURL: String, model: String, instruction: String, source: String) async throws -> String {
        let payload = try await request(baseURL: baseURL, model: model, messages: [
            ["role": "system", "content": "You assist a private local family app. \(instruction) Keep uncertain fields blank and never claim an action has been saved."],
            ["role": "user", "content": source]
        ], maxTokens: 700, requireContent: true)
        guard let choices = payload["choices"] as? [[String: Any]], let first = choices.first, let message = first["message"] as? [String: Any], let content = message["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIClientError.badResponse }
        return content
    }
    private func request(baseURL: String, model: String, messages: [[String: String]], maxTokens: Int, requireContent: Bool) async throws -> [String: Any] {
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIClientError.missingConfiguration }
        guard let key = keychain.apiKey(), !key.isEmpty else { throw AIClientError.missingKey }
        let root = try normalizedBaseURL(baseURL); let url = root.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "messages": messages, "max_tokens": maxTokens])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIClientError.badResponse }
        if requireContent { return payload }
        return payload
    }
}

@MainActor @Observable final class SessionStore {
    private let key = "family.session.member"; var currentMemberID: String? { didSet { UserDefaults.standard.set(currentMemberID, forKey: key) } }
    init() { let stored = UserDefaults.standard.string(forKey: key); currentMemberID = stored.flatMap { MemberID(rawValue: $0)?.rawValue } }
    func login(member: MemberID, password: String) -> Bool { guard password == "qwer1234" else { return false }; currentMemberID = member.rawValue; return true }
    func logout() { currentMemberID = nil }
}

@MainActor @Observable final class AppEnvironment {
    let context: ModelContext; let mediaStore: LocalMediaStore; let keychain = KeychainService(); let session = SessionStore(); let timeAnalysis = TimeAnalysisService()
    let chatRepository: ChatRepository; let chatTransport: DemoChatTransport; let agendaRepository: AgendaRepository; let scheduleRepository: ScheduleRepository; let memoRepository: MemoRepository; let noticeRepository: NoticeRepository; let locationRepository: LocationRepository
    var lastError: String?; var refreshToken = UUID()
    init(modelContext: ModelContext) { context = modelContext; mediaStore = LocalMediaStore(); chatRepository = LocalChatRepository(context: modelContext, mediaStore: mediaStore); chatTransport = DemoChatTransport(context: modelContext); agendaRepository = LocalAgendaRepository(context: modelContext); scheduleRepository = LocalScheduleRepository(context: modelContext); memoRepository = LocalMemoRepository(context: modelContext); noticeRepository = LocalNoticeRepository(context: modelContext); locationRepository = LocalLocationRepository(context: modelContext) }
    func bootstrap() { do { try DemoDataService(context: context, mediaStore: mediaStore).seedIfNeeded(); try locationRepository.purgeHistory(now: .now); refreshToken = UUID() } catch { lastError = error.localizedDescription } }
    func resetDemo() { do { try DemoDataService(context: context, mediaStore: mediaStore).resetDemo(); refreshToken = UUID() } catch { lastError = error.localizedDescription } }
    func clearAllLocalData() { do { try DemoDataService(context: context, mediaStore: mediaStore).clearAll(); keychain.clear(); UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "FamilyApp"); session.logout(); refreshToken = UUID() } catch { lastError = error.localizedDescription } }
    func send(_ message: ChatMessageModel) { do { try chatRepository.create(message); chatTransport.simulateReceipts(for: message); refreshToken = UUID() } catch { lastError = error.localizedDescription } }
}
