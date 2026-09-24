import Foundation
import SwiftData
import SwiftUI
import Security
import UIKit
import Observation
import AVFoundation
import EventKit
import CoreLocation

struct MemoDraft { var title: String?; var content: String; var pinned: Bool }
struct NoticeDraft { var title: String; var content: String; var pinned: Bool }
struct AgendaDraft { var title: String; var kind: AgendaKind; var start: Date?; var end: Date?; var dueAt: Date?; var location: String?; var note: String?; var participantIDs: [String]; var recurrence: AgendaRecurrence; var recurrenceEnd: Date?; var dishes: String?; var ingredients: String?; var seasonings: String?; var peopleCount: Int?; var estimatedArrival: Date?; var desiredMealTime: Date?; var preparation: PreparationState?; var completion: CompletionState? }
struct AgendaExceptionDraft { var kind: ExceptionKind; var scope: ExceptionScope; var occurrenceDate: Date; var replacementStart: Date?; var replacementEnd: Date? }
struct ScheduleExceptionDraft { var kind: ExceptionKind; var scope: ExceptionScope; var occurrenceDate: Date; var replacementDate: Date?; var replacementStartMinutes: Int?; var replacementEndMinutes: Int?; var replacementWeekday: Int? }
struct CalendarOverrideDraft { var date: Date; var kind: CalendarOverrideKind; var mappedWeekday: Int?; var note: String? }
struct FamilyPlaceDraft { var name: String; var kind: PlaceKind; var memberID: String; var latitude: Double; var longitude: Double; var radius: Int; var isEnabled: Bool }

/// The only local membership lookup used by repositories.  It deliberately
/// accepts both legacy initial keys and future UUID-backed profiles, avoiding
/// scattered `MemberID.allCases` authorization and validation checks.
@MainActor enum MemberDirectory {
    /// Historical rows retain departed profiles so old authors and senders can
    /// still be rendered accurately; they never authorize new business writes.
    static func allMembersIncludingHistory(in context: ModelContext) throws -> [MemberProfile] {
        try context.fetch(FetchDescriptor<MemberProfile>(sortBy: [SortDescriptor(\.nickname)]))
    }

    static func activeMembers(in context: ModelContext) throws -> [MemberProfile] {
        try allMembersIncludingHistory(in: context).filter(\.isActiveMember)
    }

    /// Views receive reactive @Query results; keep their selection semantics
    /// identical to repositories without inventing missing founder profiles.
    static func activeMembers(from profiles: [MemberProfile]) -> [MemberProfile] {
        profiles.filter(\.isActiveMember)
    }

    static func allMembersIncludingHistory(from profiles: [MemberProfile]) -> [MemberProfile] {
        profiles
    }

    static func activeMemberIDs(in context: ModelContext) throws -> Set<String> {
        Set(try activeMembers(in: context).map(\.memberID))
    }

    static func containsActive(_ memberID: String, in context: ModelContext) throws -> Bool {
        try activeMemberIDs(in: context).contains(memberID)
    }

    static func localID(for remoteID: UUID, in context: ModelContext) throws -> String {
        if let profile = try allMembersIncludingHistory(in: context).first(where: { $0.stableRemoteID == remoteID }) {
            return profile.memberID
        }
        return MemberIdentity.localMemberID(for: remoteID)
    }
}

@MainActor protocol ChatRepository { func messages() throws -> [ChatMessageModel]; func create(_ message: ChatMessageModel) throws; func recall(_ message: ChatMessageModel, by memberID: String, now: Date) throws; func delete(_ message: ChatMessageModel, by memberID: String) throws; func restore(_ message: ChatMessageModel, deletedAt: Date, by memberID: String) throws; func permanentlyDelete(_ message: ChatMessageModel, deletedAt: Date, by memberID: String) throws; func retry(_ message: ChatMessageModel, by memberID: String) throws; func markIncomingMessagesRead(by memberID: String) throws }
@MainActor protocol AgendaRepository { func items() throws -> [AgendaItemModel]; func save(_ item: AgendaItemModel, draft: AgendaDraft, by memberID: String) throws; func delete(_ item: AgendaItemModel, by memberID: String) throws; func restore(_ item: AgendaItemModel, deletedAt: Date, by memberID: String) throws; func permanentlyDelete(_ item: AgendaItemModel, deletedAt: Date, by memberID: String) throws; func save(exception: AgendaExceptionModel, draft: AgendaExceptionDraft, for item: AgendaItemModel, by memberID: String) throws; func delete(exception: AgendaExceptionModel, for item: AgendaItemModel, by memberID: String) throws; func markFoodRead(_ item: AgendaItemModel, by memberID: String) throws; func setCompletion(_ item: AgendaItemModel, state: CompletionState, by memberID: String) throws }
@MainActor protocol ScheduleRepository { func entries() throws -> [ScheduleEntryModel]; func exceptions() throws -> [ScheduleExceptionModel]; func calendarOverrides() throws -> [CalendarOverrideModel]; func importBatches() throws -> [ScheduleImportBatchModel]; func save(_ entry: ScheduleEntryModel, draft: ScheduleDraft, by memberID: String) throws; func delete(_ entry: ScheduleEntryModel, by memberID: String) throws; func save(exception: ScheduleExceptionModel, draft: ScheduleExceptionDraft, by memberID: String) throws; func delete(exception: ScheduleExceptionModel, by memberID: String) throws; func save(calendarOverride: CalendarOverrideModel, draft: CalendarOverrideDraft, by memberID: String) throws; func delete(calendarOverride: CalendarOverrideModel, by memberID: String) throws; func importBatch(drafts: [ImportedScheduleDraft], semesterID: UUID, source: ScheduleImportSource, sourceFileName: String?, sourceFileType: String?, conflictPolicy: ScheduleImportConflictPolicy, by memberID: String) throws -> ScheduleImportBatchModel; func undoImport(_ batch: ScheduleImportBatchModel, by memberID: String) throws }
@MainActor protocol SemesterRepository { func save(_ semester: SemesterModel, name: String, week1StartDate: Date, week1EndDate: Date, totalWeeks: Int, isCurrent: Bool, by memberID: String) throws; func setCurrent(_ semester: SemesterModel, by memberID: String) throws }
@MainActor protocol MemoRepository { func memos() throws -> [MemoModel]; func create(draft: MemoDraft, by memberID: String) throws; func save(_ memo: MemoModel, draft: MemoDraft, expectedVersion: Int, by memberID: String) throws; func delete(_ memo: MemoModel, by memberID: String) throws; func restore(_ memo: MemoModel, deletedAt: Date, expectedVersion: Int, by memberID: String) throws; func permanentlyDelete(_ memo: MemoModel, deletedAt: Date, expectedVersion: Int, by memberID: String) throws }
@MainActor protocol NoticeRepository { func notices() throws -> [NoticeModel]; func markRead(_ notice: NoticeModel, memberID: String) throws; func create(draft: NoticeDraft, by memberID: String) throws; func save(_ notice: NoticeModel, draft: NoticeDraft, by memberID: String) throws; func delete(_ notice: NoticeModel, by memberID: String) throws; func restore(_ notice: NoticeModel, deletedAt: Date, by memberID: String) throws; func permanentlyDelete(_ notice: NoticeModel, deletedAt: Date, by memberID: String) throws }
@MainActor protocol LocationRepository { func snapshots() throws -> [LocationSnapshotModel]; func places() throws -> [FamilyPlaceModel]; func statuses() throws -> [MemberStatusModel]; func add(_ snapshot: LocationSnapshotModel) throws; func save(_ place: FamilyPlaceModel, draft: FamilyPlaceDraft, by memberID: String) throws; func delete(_ place: FamilyPlaceModel, by memberID: String) throws; func saveStatus(memberID: String, status: SafetyStatus, estimatedArrival: Date?, by actorID: String) throws; func purgeHistory(now: Date) throws }

enum RepositoryError: LocalizedError { case versionConflict, forbidden, invalidData, recallExpired, importUndoConflict, trashConflict, trashExpired
    var errorDescription: String? { switch self { case .versionConflict: return "这条备忘录已被其他成员修改，请查看最新内容后再保存。"; case .forbidden: return "当前成员没有执行此操作的权限。"; case .invalidData: return "数据无效，请检查日期、周次和时间。"; case .recallExpired: return "消息发送超过 5 分钟，不能撤回。"; case .importUndoConflict: return "导入后的课程已被修改或删除，不能安全撤销。请手动核对后处理。"; case .trashConflict: return "内容在打开回收站后发生变化，请刷新后重试。"; case .trashExpired: return "已超过 30 天恢复期限，无法恢复。" } }
}

enum RecycleRetention {
    static func canRestore(_ deletedAt: Date, now: Date = .now) -> Bool {
        deletedAt <= now && deletedAt >= (Calendar.autoupdatingCurrent.date(byAdding: .day, value: -30, to: now) ?? now)
    }
    static func isCurrent(_ actual: Date?, expected: Date, purgedAt: Date?) -> Bool {
        actual == expected && purgedAt == nil
    }
}

enum AppleCalendarExportError: LocalizedError {
    case denied, restricted, unavailable, notTimed
    var errorDescription: String? {
        switch self {
        case .denied: return "Apple 日历权限已被拒绝，请在系统设置中允许后重试。"
        case .restricted: return "此设备不允许访问 Apple 日历。"
        case .unavailable: return "未获得 Apple 日历访问权限。"
        case .notTimed: return "只有带开始和结束时间的日程可以加入 Apple 日历。"
        }
    }
}

@MainActor final class AppleCalendarExporter {
    static func isExportable(_ item: AgendaItemModel) -> Bool {
        item.deletedAt == nil && item.purgedAt == nil && timing(for: item) != nil
    }

    func add(_ item: AgendaItemModel) async throws {
        guard Self.isExportable(item), let timing = Self.timing(for: item) else { throw AppleCalendarExportError.notTimed }
        let store = EKEventStore()
        switch EKEventStore.authorizationStatus(for: .event) {
        case .denied: throw AppleCalendarExportError.denied
        case .restricted: throw AppleCalendarExportError.restricted
        default: break
        }
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { throw AppleCalendarExportError.unavailable }
        let event = EKEvent(eventStore: store)
        event.title = item.title
        event.startDate = timing.start
        event.endDate = timing.end
        event.location = item.location
        event.notes = item.note ?? (item.kind == .orderFood ? "家庭点菜" : nil)
        guard let calendar = store.defaultCalendarForNewEvents else { throw AppleCalendarExportError.unavailable }
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
    }

    private static func timing(for item: AgendaItemModel) -> (start: Date, end: Date)? {
        if let start = item.start, let end = item.end, start < end { return (start, end) }
        // A meal with a confirmed serving time is a real family activity; the
        // one-hour default is presentation metadata only and never affects Busy.
        if item.kind == .orderFood, let meal = item.desiredMealTime {
            return (meal, meal.addingTimeInterval(60 * 60))
        }
        return nil
    }
}

struct ScheduleDraft {
    var title: String; var kind: ScheduleKind; var weekday: Int; var startMinutes: Int; var endMinutes: Int
    var startWeek: Int; var endWeek: Int; var weekType: WeekType
    var major: String?; var grade: String?; var className: String?; var location: String?; var note: String?; var labName: String?; var advisor: String?
}

@MainActor final class LocalChatRepository: ChatRepository {
    private let context: ModelContext; private let mediaStore: LocalMediaStore; private let writes: BusinessWriteCoordinator
    /// Injected only by a future remote composition. The shipping local-only
    /// environment deliberately leaves it nil and never starts a transfer.
    private let remoteMediaTransfer: RemoteChatMediaTransferCoordinator?

    init(context: ModelContext, mediaStore: LocalMediaStore,
         remoteTransaction: RemoteMutationTransaction? = nil,
         remoteMediaTransfer: RemoteChatMediaTransferCoordinator? = nil) {
        self.context = context; self.mediaStore = mediaStore
        self.writes = BusinessWriteCoordinator(context: context, remoteTransaction: remoteTransaction)
        self.remoteMediaTransfer = remoteMediaTransfer
    }
    func messages() throws -> [ChatMessageModel] { try context.fetch(FetchDescriptor<ChatMessageModel>(sortBy: [SortDescriptor(\.sentAt)])).filter { $0.deletedAt == nil && $0.purgedAt == nil } }
    func create(_ message: ChatMessageModel) throws {
        guard try MemberDirectory.containsActive(message.senderID, in: context) else { throw RepositoryError.forbidden }
        if let replyID = message.replyToID {
            guard try messages().contains(where: { $0.id == replyID && $0.kind != .recalled }) else { throw RepositoryError.trashConflict }
        }
        let mentionedIDs = message.mentionedMemberIDs ?? []
        if !mentionedIDs.isEmpty {
            let activeIDs = Set(try MemberDirectory.activeMembers(in: context).compactMap(\.stableRemoteID))
            guard Set(mentionedIDs).count == mentionedIDs.count,
                  Set(mentionedIDs).isSubset(of: activeIDs) else { throw RepositoryError.invalidData }
        }
        // Member mentions remain local until their UUID relation is part of
        // the wire protocol; never silently drop them from a remote message.
        if writes.isRemoteEnabled && !mentionedIDs.isEmpty {
            throw RemoteSyncError.unsupportedLocalData("远端聊天尚不支持成员提及")
        }
        if message.kind == .file {
            guard let path = message.mediaPath,
                  FileManager.default.fileExists(atPath: mediaStore.url(for: path).path) else {
                throw RepositoryError.invalidData
            }
        }
        if (message.kind == .image || message.kind == .audio || message.kind == .file) && writes.isRemoteEnabled {
            guard let remoteMediaTransfer else {
                throw RemoteSyncError.unsupportedLocalData("远端媒体传输尚未配置")
            }
            guard message.recalledAt == nil, message.mediaPath != nil else {
                throw RemoteSyncError.unsupportedLocalData("聊天媒体缺少可上传的本地文件")
            }

            // A media message becomes visible locally before it is remotely
            // finalized, but it intentionally has no Message outbox row yet.
            // If the process exits here, the durable pending state lets the
            // transfer coordinator resume with this same stable media ID.
            try writes.commit(changing: {
                message.remoteMediaID = message.remoteMediaID ?? UUID()
                message.mediaTransferStateRaw = RemoteMediaTransferState.pending.rawValue
                message.mediaRetryCount = message.mediaRetryCount ?? 0
                message.mediaLastErrorCode = nil
                context.insert(message)
            })
            Task { @MainActor [remoteMediaTransfer, message] in
                do { try await remoteMediaTransfer.transferAndQueue(message) }
                catch is CancellationError { }
                catch { /* coordinator persists recoverable failure state */ }
            }
            return
        }
        try writes.commit(changing: { context.insert(message) }, intents: {
            [RemoteMutationIntent(entityType: .message, entityID: message.id, operation: .create, payload: try RemoteBusinessPayload.message(message))]
        })
    }
    func recall(_ message: ChatMessageModel, by memberID: String, now: Date = .now) throws {
        guard message.senderID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard message.deletedAt == nil, message.purgedAt == nil else { throw RepositoryError.trashConflict }
        guard now.timeIntervalSince(message.sentAt) <= 300 else { throw RepositoryError.recallExpired }
        if writes.isRemoteEnabled,
           message.kind == .image || message.kind == .audio || message.kind == .file,
           message.mediaTransferState != .finalized {
            // The server has no Message to update until its asset is ready.
            throw RemoteSyncError.unsupportedLocalData("附件上传完成前不能撤回远端消息")
        }
        if writes.isRemoteEnabled, try hasUncommittedRemoteCreate(message.id) {
            throw RemoteSyncError.localChangesPending
        }
        let mediaPath = message.mediaPath
        try writes.commit(changing: {
            message.body = "该消息已被撤回"; message.kindRaw = MessageKind.recalled.rawValue
            message.mediaPath = nil; message.recalledAt = now
        }, intents: {
            [RemoteMutationIntent(entityType: .message, entityID: message.id, operation: .update, payload: try RemoteBusinessPayload.message(message))]
        })
        // Do not delete a local file before the business/outbox transaction is
        // durable: a failed remote-mode validation would otherwise restore the
        // message row while leaving it pointed at a missing attachment.
        if let mediaPath {
            do { try mediaStore.remove(path: mediaPath) }
            catch { assertionFailure("Unable to remove recalled media: \(error.localizedDescription)") }
        }
    }
    func delete(_ message: ChatMessageModel, by memberID: String) throws {
        guard message.senderID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard message.deletedAt == nil, message.purgedAt == nil else { throw RepositoryError.trashConflict }
        if writes.isRemoteEnabled && (message.kind == .image || message.kind == .audio || message.kind == .file),
           message.mediaTransferState != .finalized {
            throw RemoteSyncError.unsupportedLocalData("媒体上传完成前不能移入远端回收站")
        }
        if writes.isRemoteEnabled, try hasUncommittedRemoteCreate(message.id) {
            // Coalescing create+delete would discard the Message mutation
            // while leaving its already finalized MediaAsset unreferenced.
            throw RemoteSyncError.localChangesPending
        }
        try writes.commit(changing: {
            if writes.isRemoteEnabled {
                context.delete(message)
                for receipt in try context.fetch(FetchDescriptor<MessageReceiptModel>()) where receipt.messageID == message.id { context.delete(receipt) }
            } else { message.deletedAt = .now }
        }, intents: { [RemoteMutationIntent(entityType: .message, entityID: message.id, operation: .delete)] })
    }
    func restore(_ message: ChatMessageModel, deletedAt: Date, by memberID: String) throws {
        guard message.senderID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard RecycleRetention.isCurrent(message.deletedAt, expected: deletedAt, purgedAt: message.purgedAt) else { throw RepositoryError.trashConflict }
        guard RecycleRetention.canRestore(deletedAt) else { throw RepositoryError.trashExpired }
        guard !writes.isRemoteEnabled else { throw RemoteSyncError.unsupportedLocalData("远端恢复必须等待服务器权威结果") }
        try writes.commit(changing: { message.deletedAt = nil })
    }
    func permanentlyDelete(_ message: ChatMessageModel, deletedAt: Date, by memberID: String) throws {
        guard message.senderID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard RecycleRetention.isCurrent(message.deletedAt, expected: deletedAt, purgedAt: message.purgedAt) else { throw RepositoryError.trashConflict }
        guard !writes.isRemoteEnabled else { throw RemoteSyncError.unsupportedLocalData("远端永久删除必须等待服务器权威结果") }
        let mediaPath = message.mediaPath
        try writes.commit(changing: { try LocalRecycleMaintenance.scrub(message, in: context) })
        if let mediaPath {
            if try LocalRecycleMaintenance.canRemoveMedia(mediaPath, excluding: message.id, in: context) {
                try mediaStore.remove(path: mediaPath)
            }
            message.mediaPath = nil
            do { try context.save() }
            catch { context.rollback(); throw error }
        }
    }
    func retry(_ message: ChatMessageModel, by memberID: String) throws {
        guard message.senderID == memberID, message.status == .failed,
              message.deletedAt == nil, message.purgedAt == nil,
              try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        if writes.isRemoteEnabled, let remoteMediaTransfer,
           message.kind == .image || message.kind == .audio || message.kind == .file,
           message.mediaTransferState == .failed {
            message.statusRaw = ReceiptStatus.sending.rawValue
            message.mediaTransferStateRaw = RemoteMediaTransferState.pending.rawValue
            try context.save()
            Task { @MainActor [remoteMediaTransfer, message] in
                do { try await remoteMediaTransfer.transferAndQueue(message) }
                catch is CancellationError { }
                catch { /* durable failure state is recorded by the coordinator */ }
            }
            return
        }
        message.statusRaw = ReceiptStatus.sending.rawValue
        try context.save()
    }
    private func hasUncommittedRemoteCreate(_ messageID: UUID) throws -> Bool {
        try context.fetch(FetchDescriptor<PendingMutationModel>()).contains {
            $0.entityType == RemoteEntityType.message.rawValue && $0.entityID == messageID &&
            $0.operation == RemoteChangeOperation.create.rawValue && $0.state != .acknowledged
        }
    }
    func markIncomingMessagesRead(by memberID: String) throws {
        guard try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        let incoming = try messages().filter { $0.senderID != memberID && $0.isUnread }
        guard !incoming.isEmpty else { return }
        let existingReceipts = try context.fetch(FetchDescriptor<MessageReceiptModel>())
        var createdReceipts: [MessageReceiptModel] = []
        let readAt = Date.now
        try writes.commit(changing: {
            for message in incoming {
                message.isUnread = false
                if message.status != .failed { message.statusRaw = ReceiptStatus.read.rawValue }
                guard writes.isRemoteEnabled else { continue }
                let id = try RemoteStableID.messageReceipt(messageID: message.id, memberID: memberID)
                guard !existingReceipts.contains(where: { $0.id == id }) else { continue }
                let receipt = MessageReceiptModel(id: id, messageID: message.id, memberID: memberID, deliveredAt: readAt, readAt: readAt)
                context.insert(receipt); createdReceipts.append(receipt)
            }
        }, intents: {
            try createdReceipts.map {
                RemoteMutationIntent(entityType: .messageReceipt, entityID: $0.id, operation: .create, payload: try RemoteBusinessPayload.receipt($0))
            }
        })
    }
}

/// Deterministic local-only receipt simulation. It never represents a network delivery.
@MainActor final class DemoChatTransport {
    private let context: ModelContext
    private let enabled: Bool
    init(context: ModelContext, enabled: Bool = true) { self.context = context; self.enabled = enabled }
    func simulateReceipts(for message: ChatMessageModel) {
        guard enabled else { return }
        let context = context
        Task { @MainActor [context, message] in
            do { try await Task.sleep(for: .milliseconds(350)); message.statusRaw = ReceiptStatus.sent.rawValue; try context.save(); try await Task.sleep(for: .milliseconds(650)); guard message.kind != .recalled else { return }; message.statusRaw = ReceiptStatus.delivered.rawValue; try context.save(); try await Task.sleep(for: .milliseconds(900)); guard message.kind != .recalled else { return }; message.statusRaw = ReceiptStatus.read.rawValue; try context.save() } catch { message.statusRaw = ReceiptStatus.failed.rawValue; do { try context.save() } catch { assertionFailure("Unable to persist demo receipt failure: \(error.localizedDescription)") } }
        }
    }
}

/// Semester writes use the same durable business/outbox boundary as schedules.
/// The shipping Demo constructs this repository without a remote transaction.
@MainActor final class LocalSemesterRepository: SemesterRepository {
    private let context: ModelContext
    private let writes: BusinessWriteCoordinator

    init(context: ModelContext, remoteTransaction: RemoteMutationTransaction? = nil) {
        self.context = context
        self.writes = BusinessWriteCoordinator(context: context, remoteTransaction: remoteTransaction)
    }

    func save(_ semester: SemesterModel, name: String, week1StartDate: Date, week1EndDate: Date, totalWeeks: Int, isCurrent: Bool, by memberID: String) throws {
        guard try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, week1EndDate >= week1StartDate, (1...52).contains(totalWeeks) else {
            throw RepositoryError.invalidData
        }

        let isNew = semester.modelContext == nil
        let allSemesters = try context.fetch(FetchDescriptor<SemesterModel>())
        var displaced: [SemesterModel] = []
        try writes.commit(changing: {
            if isNew { context.insert(semester) }
            semester.name = normalizedName
            semester.week1StartDate = week1StartDate
            semester.week1EndDate = week1EndDate
            semester.totalWeeks = totalWeeks
            semester.isCurrent = isCurrent
            if isCurrent {
                displaced = allSemesters.filter { $0.id != semester.id && $0.isCurrent }
                displaced.forEach { $0.isCurrent = false }
            }
        }, intents: {
            var intents = [RemoteMutationIntent(
                entityType: .semester,
                entityID: semester.id,
                operation: isNew ? .create : .update,
                payload: RemoteBusinessPayload.semester(semester)
            )]
            intents.append(contentsOf: displaced.map {
                RemoteMutationIntent(entityType: .semester, entityID: $0.id, operation: .update, payload: RemoteBusinessPayload.semester($0))
            })
            return intents
        })
    }

    func setCurrent(_ semester: SemesterModel, by memberID: String) throws {
        guard try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        let allSemesters = try context.fetch(FetchDescriptor<SemesterModel>())
        guard allSemesters.contains(where: { $0.id == semester.id }) else { throw RepositoryError.invalidData }
        guard !semester.isCurrent else { return }

        var changed: [SemesterModel] = []
        try writes.commit(changing: {
            for item in allSemesters where item.isCurrent || item.id == semester.id {
                item.isCurrent = item.id == semester.id
                changed.append(item)
            }
        }, intents: {
            changed.map {
                RemoteMutationIntent(entityType: .semester, entityID: $0.id, operation: .update, payload: RemoteBusinessPayload.semester($0))
            }
        })
    }
}

@MainActor final class LocalAgendaRepository: AgendaRepository {
    private let context: ModelContext; private let writes: BusinessWriteCoordinator
    init(context: ModelContext, remoteTransaction: RemoteMutationTransaction? = nil) {
        self.context = context; self.writes = BusinessWriteCoordinator(context: context, remoteTransaction: remoteTransaction)
    }
    func items() throws -> [AgendaItemModel] { try context.fetch(FetchDescriptor<AgendaItemModel>(sortBy: [SortDescriptor(\.start), SortDescriptor(\.dueAt)])).filter { $0.deletedAt == nil && $0.purgedAt == nil } }
    func save(_ item: AgendaItemModel, draft: AgendaDraft, by memberID: String) throws {
        guard item.modelContext == nil || item.creatorID == memberID else { throw RepositoryError.forbidden }
        guard item.deletedAt == nil, item.purgedAt == nil else { throw RepositoryError.trashConflict }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        let knownMembers = try MemberDirectory.activeMemberIDs(in: context)
        let validParticipants = !draft.participantIDs.isEmpty && Set(draft.participantIDs).isSubset(of: knownMembers)
        let validTimed = draft.start != nil && draft.end != nil && draft.start! < draft.end!
        let validDeadline = draft.kind != .assignmentDeadline || draft.dueAt != nil
        let validFood = draft.kind != .orderFood || !(draft.dishes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard !title.isEmpty,
              validParticipants,
              (draft.kind != .normal && draft.kind != .exam || validTimed),
              validDeadline,
              validFood,
              (draft.recurrence == .none || (draft.kind == .normal || draft.kind == .exam) && draft.recurrenceEnd != nil && draft.recurrenceEnd! >= Calendar.autoupdatingCurrent.startOfDay(for: draft.start!)) else { throw RepositoryError.invalidData }
        let isNew = item.modelContext == nil
        let previousParticipants = isNew ? Set<String>() : Set(item.participantIDs)
        let nextParticipants = Set(draft.participantIDs)
        let removedExceptionIDs = try context.fetch(FetchDescriptor<AgendaExceptionModel>())
            .filter { $0.agendaID == item.id && !(draft.kind == .normal || draft.kind == .exam) }
            .map(\.id)
        try writes.commit(changing: {
            if isNew { context.insert(item) }
            let supportsRecurrence = draft.kind == .normal || draft.kind == .exam
            if !supportsRecurrence {
                for exception in try context.fetch(FetchDescriptor<AgendaExceptionModel>()) where exception.agendaID == item.id { context.delete(exception) }
            }
            item.title = title; item.kindRaw = draft.kind.rawValue; item.start = draft.start; item.end = draft.end; item.dueAt = draft.dueAt; item.location = draft.location; item.note = draft.note; item.participantIDs = Array(nextParticipants).sorted(); item.recurrenceRaw = supportsRecurrence ? draft.recurrence.rawValue : AgendaRecurrence.none.rawValue; item.recurrenceEnd = supportsRecurrence && draft.recurrence != .none ? draft.recurrenceEnd : nil; item.dishes = draft.dishes; item.ingredients = draft.ingredients; item.seasonings = draft.seasonings; item.peopleCount = draft.peopleCount; item.estimatedArrival = draft.estimatedArrival; item.desiredMealTime = draft.desiredMealTime; item.preparationRaw = draft.preparation?.rawValue; item.completionRaw = draft.completion?.rawValue
        }, intents: {
            var intents = [RemoteMutationIntent(entityType: .agenda, entityID: item.id, operation: isNew ? .create : .update, payload: try RemoteBusinessPayload.agenda(item))]
            for rawMemberID in nextParticipants.subtracting(previousParticipants) {
                intents.append(RemoteMutationIntent(
                    entityType: .agendaParticipant,
                    entityID: try RemoteStableID.agendaParticipant(agendaID: item.id, memberID: rawMemberID),
                    operation: .upsert,
                    payload: try RemoteBusinessPayload.agendaParticipant(agendaID: item.id, memberID: rawMemberID)
                ))
            }
            for rawMemberID in previousParticipants.subtracting(nextParticipants) {
                intents.append(RemoteMutationIntent(
                    entityType: .agendaParticipant,
                    entityID: try RemoteStableID.agendaParticipant(agendaID: item.id, memberID: rawMemberID),
                    operation: .delete
                ))
            }
            intents.append(contentsOf: removedExceptionIDs.map {
                RemoteMutationIntent(entityType: .agendaException, entityID: $0, operation: .delete)
            })
            return intents
        })
    }
    func delete(_ item: AgendaItemModel, by memberID: String) throws {
        guard item.creatorID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard item.deletedAt == nil, item.purgedAt == nil else { throw RepositoryError.trashConflict }
        try writes.commit(changing: {
            if writes.isRemoteEnabled {
                for exception in try context.fetch(FetchDescriptor<AgendaExceptionModel>()) where exception.agendaID == item.id { context.delete(exception) }
                context.delete(item)
            } else { item.deletedAt = .now }
        }, intents: { [RemoteMutationIntent(entityType: .agenda, entityID: item.id, operation: .delete)] })
    }
    func restore(_ item: AgendaItemModel, deletedAt: Date, by memberID: String) throws {
        guard item.creatorID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard RecycleRetention.isCurrent(item.deletedAt, expected: deletedAt, purgedAt: item.purgedAt) else { throw RepositoryError.trashConflict }
        guard RecycleRetention.canRestore(deletedAt) else { throw RepositoryError.trashExpired }
        guard !writes.isRemoteEnabled else { throw RemoteSyncError.unsupportedLocalData("远端恢复必须等待服务器权威结果") }
        try writes.commit(changing: { item.deletedAt = nil })
    }
    func permanentlyDelete(_ item: AgendaItemModel, deletedAt: Date, by memberID: String) throws {
        guard item.creatorID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard RecycleRetention.isCurrent(item.deletedAt, expected: deletedAt, purgedAt: item.purgedAt) else { throw RepositoryError.trashConflict }
        guard !writes.isRemoteEnabled else { throw RemoteSyncError.unsupportedLocalData("远端永久删除必须等待服务器权威结果") }
        try writes.commit(changing: { try LocalRecycleMaintenance.scrub(item, in: context) })
    }
    func save(exception: AgendaExceptionModel, draft: AgendaExceptionDraft, for item: AgendaItemModel, by memberID: String) throws {
        guard item.deletedAt == nil, item.purgedAt == nil else { throw RepositoryError.trashConflict }
        guard item.creatorID == memberID, exception.agendaID == item.id, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard item.recurrence != .none,
              TimeAnalysisService().isAgendaOccurrence(item, on: draft.occurrenceDate) else { throw RepositoryError.invalidData }
        if draft.kind != .cancelled {
            guard let start = draft.replacementStart, let end = draft.replacementEnd, start < end else { throw RepositoryError.invalidData }
        }
        let isNew = exception.modelContext == nil
        try writes.commit(changing: {
            exception.kindRaw = draft.kind.rawValue; exception.scopeRaw = draft.scope.rawValue
            exception.occurrenceDate = draft.occurrenceDate
            exception.replacementDate = draft.kind == .cancelled ? nil : draft.replacementStart
            exception.replacementStart = draft.kind == .cancelled ? nil : draft.replacementStart
            exception.replacementEnd = draft.kind == .cancelled ? nil : draft.replacementEnd
            if isNew { context.insert(exception) }
        }, intents: { [RemoteMutationIntent(entityType: .agendaException, entityID: exception.id, operation: isNew ? .create : .update, payload: RemoteBusinessPayload.agendaException(exception))] })
    }
    func delete(exception: AgendaExceptionModel, for item: AgendaItemModel, by memberID: String) throws { guard item.creatorID == memberID, item.deletedAt == nil, item.purgedAt == nil, exception.agendaID == item.id, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }; try writes.commit(changing: { context.delete(exception) }, intents: { [RemoteMutationIntent(entityType: .agendaException, entityID: exception.id, operation: .delete)] }) }
    func markFoodRead(_ item: AgendaItemModel, by memberID: String) throws {
        guard item.deletedAt == nil, item.purgedAt == nil else { throw RepositoryError.trashConflict }
        guard item.kind == .orderFood, item.participantIDs.contains(memberID) else { throw RepositoryError.forbidden }
        guard !item.foodReadReceipts.contains(where: { $0.memberID == memberID }), try MemberDirectory.containsActive(memberID, in: context) else { return }
        let readAt = Date.now
        try writes.commit(changing: {
            item.foodReadAtRecords = (item.foodReadAtRecords ?? []) + ["\(memberID)|\(readAt.timeIntervalSince1970)"]
            item.foodReadByIDs = item.foodReadReceipts.map(\.memberID)
        }, intents: {
            [RemoteMutationIntent(
                entityType: .foodRead,
                entityID: try RemoteStableID.foodRead(agendaID: item.id, memberID: memberID),
                operation: .create,
                payload: try RemoteBusinessPayload.foodRead(agendaID: item.id, memberID: memberID, readAt: readAt)
            )]
        })
    }
    func setCompletion(_ item: AgendaItemModel, state: CompletionState, by memberID: String) throws {
        guard item.deletedAt == nil, item.purgedAt == nil else { throw RepositoryError.trashConflict }
        guard item.kind == .assignmentDeadline, item.participantIDs.contains(memberID), try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        try writes.commit(changing: { item.completionRaw = state.rawValue }, intents: {
            [RemoteMutationIntent(entityType: .agenda, entityID: item.id, operation: .update, payload: try RemoteBusinessPayload.agenda(item))]
        })
    }
}
@MainActor final class LocalScheduleRepository: ScheduleRepository {
    private let context: ModelContext; private let writes: BusinessWriteCoordinator
    init(context: ModelContext, remoteTransaction: RemoteMutationTransaction? = nil) {
        self.context = context; self.writes = BusinessWriteCoordinator(context: context, remoteTransaction: remoteTransaction)
    }
    func entries() throws -> [ScheduleEntryModel] { try context.fetch(FetchDescriptor<ScheduleEntryModel>()) }
    func exceptions() throws -> [ScheduleExceptionModel] { try context.fetch(FetchDescriptor<ScheduleExceptionModel>()) }
    func calendarOverrides() throws -> [CalendarOverrideModel] { try context.fetch(FetchDescriptor<CalendarOverrideModel>()) }
    func importBatches() throws -> [ScheduleImportBatchModel] { try context.fetch(FetchDescriptor<ScheduleImportBatchModel>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])) }
    func save(_ entry: ScheduleEntryModel, draft: ScheduleDraft, by memberID: String) throws {
        guard entry.ownerID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard let semester = try context.fetch(FetchDescriptor<SemesterModel>()).first(where: { $0.id == entry.semesterID }) else { throw RepositoryError.invalidData }
        let candidate = ScheduleEntryModel(ownerID: entry.ownerID, semesterID: entry.semesterID, title: draft.title, kind: draft.kind, weekday: draft.weekday, startMinutes: draft.startMinutes, endMinutes: draft.endMinutes, startWeek: draft.startWeek, endWeek: draft.endWeek, weekType: draft.weekType, major: draft.major, grade: draft.grade, className: draft.className, location: draft.location, note: draft.note, labName: draft.labName, advisor: draft.advisor)
        guard !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              TimeAnalysisService.isValid(candidate, totalWeeks: semester.totalWeeks) else { throw RepositoryError.invalidData }
        let isNew = entry.modelContext == nil
        try writes.commit(changing: {
            if isNew { context.insert(entry) }
            entry.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines); entry.kindRaw = draft.kind.rawValue; entry.weekday = draft.weekday; entry.startMinutes = draft.startMinutes; entry.endMinutes = draft.endMinutes; entry.startWeek = draft.startWeek; entry.endWeek = draft.endWeek; entry.weekTypeRaw = draft.weekType.rawValue; entry.major = draft.major; entry.grade = draft.grade; entry.className = draft.className; entry.location = draft.location; entry.note = draft.note; entry.labName = draft.labName; entry.advisor = draft.advisor
        }, intents: { [RemoteMutationIntent(entityType: .schedule, entityID: entry.id, operation: isNew ? .create : .update, payload: try RemoteBusinessPayload.schedule(entry))] })
    }
    func delete(_ entry: ScheduleEntryModel, by memberID: String) throws {
        guard entry.ownerID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        try writes.commit(changing: {
            for exception in try exceptions() where exception.scheduleID == entry.id { context.delete(exception) }
            context.delete(entry)
        }, intents: { [RemoteMutationIntent(entityType: .schedule, entityID: entry.id, operation: .delete)] })
    }
    func save(exception: ScheduleExceptionModel, draft: ScheduleExceptionDraft, by memberID: String) throws {
        let entries = try entries()
        guard let entry = entries.first(where: { $0.id == exception.scheduleID }), entry.ownerID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard let semester = try context.fetch(FetchDescriptor<SemesterModel>()).first(where: { $0.id == entry.semesterID }) else { throw RepositoryError.invalidData }
        guard (1...7).contains(draft.replacementWeekday ?? 1) || draft.replacementWeekday == nil,
              draft.replacementStartMinutes.map({ (0..<1_440).contains($0) }) ?? true,
              draft.replacementEndMinutes.map({ (1...1_440).contains($0) }) ?? true,
              draft.replacementStartMinutes == nil || draft.replacementEndMinutes == nil || draft.replacementStartMinutes! < draft.replacementEndMinutes! else { throw RepositoryError.invalidData }
        if draft.kind != .cancelled {
            guard draft.replacementDate != nil, draft.replacementStartMinutes != nil, draft.replacementEndMinutes != nil else { throw RepositoryError.invalidData }
        }
        let calendar = try calendarOverrides().filter { $0.semesterID == semester.id }
        guard TimeAnalysisService().isScheduleOccurrenceCandidate(entry, on: draft.occurrenceDate, calendarOverrides: calendar, semester: semester, allowsHolidayOverride: draft.kind != .cancelled) else { throw RepositoryError.invalidData }
        let isNew = exception.modelContext == nil
        try writes.commit(changing: {
            exception.kindRaw = draft.kind.rawValue; exception.scopeRaw = draft.scope.rawValue; exception.occurrenceDate = draft.occurrenceDate
            exception.replacementDate = draft.kind == .cancelled ? nil : draft.replacementDate
            exception.replacementStartMinutes = draft.kind == .cancelled ? nil : draft.replacementStartMinutes
            exception.replacementEndMinutes = draft.kind == .cancelled ? nil : draft.replacementEndMinutes
            exception.replacementWeekday = draft.kind == .cancelled ? nil : draft.replacementWeekday
            if isNew { context.insert(exception) }
        }, intents: { [RemoteMutationIntent(entityType: .scheduleException, entityID: exception.id, operation: isNew ? .create : .update, payload: RemoteBusinessPayload.scheduleException(exception))] })
    }
    func delete(exception: ScheduleExceptionModel, by memberID: String) throws {
        let entries = try entries()
        guard entries.first(where: { $0.id == exception.scheduleID })?.ownerID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        try writes.commit(changing: { context.delete(exception) }, intents: { [RemoteMutationIntent(entityType: .scheduleException, entityID: exception.id, operation: .delete)] })
    }
    func save(calendarOverride: CalendarOverrideModel, draft: CalendarOverrideDraft, by memberID: String) throws {
        guard try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard let semester = try context.fetch(FetchDescriptor<SemesterModel>()).first(where: { $0.id == calendarOverride.semesterID }),
              semester.weekNumber(on: draft.date) != nil,
              (draft.kind != .mappedWeekday || (draft.mappedWeekday.map { (1...7).contains($0) } ?? false)) else { throw RepositoryError.invalidData }
        let normalizedDay = Calendar.autoupdatingCurrent.startOfDay(for: draft.date)
        guard !(try calendarOverrides()).contains(where: { $0.id != calendarOverride.id && $0.semesterID == calendarOverride.semesterID && Calendar.autoupdatingCurrent.isDate($0.date, inSameDayAs: normalizedDay) }) else { throw RepositoryError.invalidData }
        let isNew = calendarOverride.modelContext == nil
        try writes.commit(changing: {
            if isNew { context.insert(calendarOverride) }
            calendarOverride.date = normalizedDay
            calendarOverride.kindRaw = draft.kind.rawValue
            calendarOverride.mappedWeekday = draft.kind == .mappedWeekday ? draft.mappedWeekday : nil
            calendarOverride.note = draft.note
        }, intents: { [RemoteMutationIntent(entityType: .calendarOverride, entityID: calendarOverride.id, operation: isNew ? .create : .update, payload: RemoteBusinessPayload.calendarOverride(calendarOverride))] })
    }
    func delete(calendarOverride: CalendarOverrideModel, by memberID: String) throws { guard try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }; try writes.commit(changing: { context.delete(calendarOverride) }, intents: { [RemoteMutationIntent(entityType: .calendarOverride, entityID: calendarOverride.id, operation: .delete)] }) }
    func importBatch(drafts: [ImportedScheduleDraft], semesterID: UUID, source: ScheduleImportSource, sourceFileName: String?, sourceFileType: String?, conflictPolicy: ScheduleImportConflictPolicy, by memberID: String) throws -> ScheduleImportBatchModel {
        guard try MemberDirectory.containsActive(memberID, in: context),
              let semester = try context.fetch(FetchDescriptor<SemesterModel>()).first(where: { $0.id == semesterID }) else { throw RepositoryError.forbidden }
        let owned = try entries().filter { $0.ownerID == memberID && $0.semesterID == semesterID }
        // OCR may emit the same visual cell more than once.  Collapse it
        // before any SwiftData mutation so an existing entry can be updated
        // at most once and undo always has one record per affected entry.
        var seenDraftKeys = Set<String>()
        let uniqueDrafts = drafts.filter { seenDraftKeys.insert(importBusinessKey(for: $0, semesterID: semesterID, ownerID: memberID)).inserted }
        let validated = try uniqueDrafts.map { draft -> (ImportedScheduleDraft, ScheduleEntryModel?) in
            guard draft.isReadyToImport else { throw RepositoryError.invalidData }
            let candidate = ScheduleEntryModel(ownerID: memberID, semesterID: semesterID, title: draft.title, kind: .course, weekday: draft.weekday, startMinutes: draft.startMinutes, endMinutes: draft.endMinutes, startWeek: draft.startWeek, endWeek: draft.endWeek, weekType: draft.weekType)
            guard TimeAnalysisService.isValid(candidate, totalWeeks: semester.totalWeeks) else { throw RepositoryError.invalidData }
            let duplicate = owned.first { importBusinessKey(for: $0) == importBusinessKey(for: draft, semesterID: semesterID, ownerID: memberID) }
            return (draft, duplicate)
        }
        let batch = ScheduleImportBatchModel(semesterID: semesterID, ownerID: memberID, source: source.rawValue, sourceFileName: sourceFileName, sourceFileType: sourceFileType)
        var createdIDs: [String] = []
        var snapshots: [ScheduleImportEntrySnapshot] = []
        var undoRecords: [ScheduleImportUndoRecord] = []
        var affectedEntries: [UUID: ScheduleEntryModel] = [:]
        try writes.commit(changing: {
            for (draft, duplicate) in validated {
                if let duplicate {
                    switch conflictPolicy {
                    case .skip: continue
                    case .keep:
                        let entry = makeImportedEntry(from: draft, semesterID: semesterID, ownerID: memberID, batchID: batch.id)
                        context.insert(entry)
                        createdIDs.append(entry.id.uuidString)
                        affectedEntries[entry.id] = entry
                        undoRecords.append(ScheduleImportUndoRecord(entry: entry, previous: nil))
                    case .update:
                        let previous = ScheduleImportEntrySnapshot(entry: duplicate)
                        snapshots.append(previous)
                        applyImportedDraft(draft, to: duplicate)
                        affectedEntries[duplicate.id] = duplicate
                        undoRecords.append(ScheduleImportUndoRecord(entry: duplicate, previous: previous))
                    }
                } else {
                    let entry = makeImportedEntry(from: draft, semesterID: semesterID, ownerID: memberID, batchID: batch.id)
                    context.insert(entry)
                    createdIDs.append(entry.id.uuidString)
                    affectedEntries[entry.id] = entry
                    undoRecords.append(ScheduleImportUndoRecord(entry: entry, previous: nil))
                }
            }
            guard !createdIDs.isEmpty || !snapshots.isEmpty else { throw RepositoryError.invalidData }
            batch.importedEntryIDs = createdIDs
            batch.updatedEntrySnapshots = try JSONEncoder().encode(snapshots).base64EncodedString()
            batch.undoRecords = try JSONEncoder().encode(undoRecords).base64EncodedString()
            context.insert(batch)
        }, intents: {
            var intents = [RemoteMutationIntent(entityType: .importBatch, entityID: batch.id, operation: .create, payload: try RemoteBusinessPayload.importBatch(batch))]
            for record in undoRecords {
                guard let entry = affectedEntries[record.entryID] else { throw RemoteSyncError.stateCorrupted }
                let operation: RemoteChangeOperation = record.previous == nil ? .create : .update
                intents.append(RemoteMutationIntent(entityType: .schedule, entityID: entry.id, operation: operation, payload: try RemoteBusinessPayload.schedule(entry)))
                intents.append(RemoteMutationIntent(
                    entityType: .importBatchItem,
                    entityID: RemoteStableID.importBatchItem(batchID: batch.id, scheduleID: entry.id),
                    operation: .create,
                    payload: RemoteBusinessPayload.importBatchItem(
                        batchID: batch.id,
                        scheduleID: entry.id,
                        operation: record.previous == nil ? "created" : "updated",
                        beforeSnapshot: try record.previous.map(RemoteBusinessPayload.scheduleSnapshot),
                        afterFingerprint: try RemoteBusinessPayload.scheduleFingerprint(entry)
                    )
                ))
            }
            return intents
        })
        return batch
    }
    func undoImport(_ batch: ScheduleImportBatchModel, by memberID: String) throws {
        guard batch.ownerID == memberID else { throw RepositoryError.forbidden }
        if writes.isRemoteEnabled {
            // Remote rollback is authoritative. Do not locally restore or
            // delete anything: a future coordinator submits this durable
            // request and ChangeApplier applies the server transaction.
            let mirrors = try context.fetch(FetchDescriptor<RemoteEntityRecordModel>())
            guard let mirror = mirrors.first(where: {
                $0.entityType == RemoteEntityType.importBatch.rawValue &&
                $0.entityID == batch.id && !$0.isTombstone && $0.serverVersion >= 1
            }) else { throw RemoteSyncError.unsupportedLocalData("导入批次尚未取得远端权威版本") }
            let pending = try context.fetch(FetchDescriptor<PendingImportBatchRollbackModel>())
            if let existing = pending.first(where: { $0.batchID == batch.id }) {
                guard existing.state != .conflict else { throw RepositoryError.importUndoConflict }
                return // Stable request identity makes repeated taps idempotent.
            }
            context.insert(PendingImportBatchRollbackModel(batchID: batch.id, requestedByID: memberID, expectedBatchVersion: mirror.serverVersion))
            do { try context.save() }
            catch { context.rollback(); throw error }
            return
        }
        let allEntries = try entries()
        guard let encoded = batch.undoRecords, let data = Data(base64Encoded: encoded) else {
            // Historic batches lack a post-import state. Restoring them could
            // overwrite a later manual edit, so they intentionally require
            // explicit manual handling.
            throw RepositoryError.importUndoConflict
        }
        let records = try JSONDecoder().decode([ScheduleImportUndoRecord].self, from: data)
        guard !records.isEmpty else { throw RepositoryError.importUndoConflict }
        // Validate every affected object before changing any SwiftData model.
        for record in records {
            guard let entry = allEntries.first(where: { $0.id == record.entryID }),
                  entry.ownerID == memberID,
                  ScheduleImportEntrySnapshot(entry: entry).fingerprint() == record.expectedPostImportFingerprint,
                  record.previous != nil || entry.importBatchID == batch.id else { throw RepositoryError.importUndoConflict }
        }
        for record in records {
            guard let entry = allEntries.first(where: { $0.id == record.entryID }) else { throw RepositoryError.importUndoConflict }
            if let previous = record.previous { previous.apply(to: entry) }
            else { context.delete(entry) }
        }
        context.delete(batch)
        try context.save()
    }
    private func makeImportedEntry(from draft: ImportedScheduleDraft, semesterID: UUID, ownerID: String, batchID: UUID) -> ScheduleEntryModel {
        let entry = ScheduleEntryModel(ownerID: ownerID, semesterID: semesterID, title: draft.title, kind: .course, weekday: draft.weekday, startMinutes: draft.startMinutes, endMinutes: draft.endMinutes, startWeek: draft.startWeek, endWeek: draft.endWeek, weekType: draft.weekType, major: draft.major, grade: draft.grade, className: draft.className, location: draft.location, note: draft.note)
        entry.importBatchID = batchID
        return entry
    }
    private func applyImportedDraft(_ draft: ImportedScheduleDraft, to entry: ScheduleEntryModel) {
        entry.title = draft.title; entry.weekday = draft.weekday; entry.startMinutes = draft.startMinutes; entry.endMinutes = draft.endMinutes
        entry.startWeek = draft.startWeek; entry.endWeek = draft.endWeek; entry.weekTypeRaw = draft.weekType.rawValue
        entry.major = draft.major; entry.grade = draft.grade; entry.className = draft.className; entry.location = draft.location; entry.note = draft.note
    }

    private func importBusinessKey(for draft: ImportedScheduleDraft, semesterID: UUID, ownerID: String) -> String {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return [ownerID, semesterID.uuidString, title, String(draft.weekday), String(draft.startMinutes), String(draft.endMinutes), String(draft.startWeek), String(draft.endWeek), draft.weekType.rawValue].joined(separator: "|")
    }

    private func importBusinessKey(for entry: ScheduleEntryModel) -> String {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return [entry.ownerID, entry.semesterID.uuidString, title, String(entry.weekday), String(entry.startMinutes), String(entry.endMinutes), String(entry.startWeek), String(entry.endWeek), entry.weekTypeRaw].joined(separator: "|")
    }
}
@MainActor final class LocalMemoRepository: MemoRepository {
    private let context: ModelContext; private let writes: BusinessWriteCoordinator
    init(context: ModelContext, remoteTransaction: RemoteMutationTransaction? = nil) { self.context = context; self.writes = BusinessWriteCoordinator(context: context, remoteTransaction: remoteTransaction) }
    func memos() throws -> [MemoModel] { try context.fetch(FetchDescriptor<MemoModel>()).filter { $0.deletedAt == nil && $0.purgedAt == nil }.sorted { $0.pinned == $1.pinned ? $0.updatedAt > $1.updatedAt : $0.pinned && !$1.pinned } }
    func create(draft: MemoDraft, by memberID: String) throws {
        guard try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        let memo = MemoModel(title: draft.title, content: draft.content, creatorID: memberID, pinned: draft.pinned, updatedBy: memberID)
        try writes.commit(changing: { context.insert(memo) }, intents: { [RemoteMutationIntent(entityType: .memo, entityID: memo.id, operation: .create, payload: try RemoteBusinessPayload.memo(memo))] })
    }
    func save(_ memo: MemoModel, draft: MemoDraft, expectedVersion: Int, by memberID: String) throws {
        guard try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard memo.deletedAt == nil, memo.purgedAt == nil else { throw RepositoryError.trashConflict }
        guard memo.version == expectedVersion else { throw RepositoryError.versionConflict }
        try writes.commit(changing: { memo.title = draft.title; memo.content = draft.content; memo.pinned = draft.pinned; memo.updatedBy = memberID; memo.version += 1; memo.updatedAt = .now }, intents: { [RemoteMutationIntent(entityType: .memo, entityID: memo.id, operation: .update, payload: try RemoteBusinessPayload.memo(memo))] })
    }
    func delete(_ memo: MemoModel, by memberID: String) throws {
        guard memo.creatorID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard memo.deletedAt == nil, memo.purgedAt == nil else { throw RepositoryError.trashConflict }
        try writes.commit(changing: {
            if writes.isRemoteEnabled { context.delete(memo) }
            else { memo.deletedAt = .now; memo.version += 1 }
        }, intents: { [RemoteMutationIntent(entityType: .memo, entityID: memo.id, operation: .delete)] })
    }
    func restore(_ memo: MemoModel, deletedAt: Date, expectedVersion: Int, by memberID: String) throws {
        guard memo.creatorID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard RecycleRetention.isCurrent(memo.deletedAt, expected: deletedAt, purgedAt: memo.purgedAt), memo.version == expectedVersion else { throw RepositoryError.trashConflict }
        guard RecycleRetention.canRestore(deletedAt) else { throw RepositoryError.trashExpired }
        guard !writes.isRemoteEnabled else { throw RemoteSyncError.unsupportedLocalData("远端恢复必须等待服务器权威结果") }
        try writes.commit(changing: { memo.deletedAt = nil; memo.version += 1 })
    }
    func permanentlyDelete(_ memo: MemoModel, deletedAt: Date, expectedVersion: Int, by memberID: String) throws {
        guard memo.creatorID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard RecycleRetention.isCurrent(memo.deletedAt, expected: deletedAt, purgedAt: memo.purgedAt), memo.version == expectedVersion else { throw RepositoryError.trashConflict }
        guard !writes.isRemoteEnabled else { throw RemoteSyncError.unsupportedLocalData("远端永久删除必须等待服务器权威结果") }
        try writes.commit(changing: { LocalRecycleMaintenance.scrub(memo) })
    }
}
@MainActor final class LocalNoticeRepository: NoticeRepository {
    private let context: ModelContext; private let writes: BusinessWriteCoordinator
    init(context: ModelContext, remoteTransaction: RemoteMutationTransaction? = nil) { self.context = context; self.writes = BusinessWriteCoordinator(context: context, remoteTransaction: remoteTransaction) }
    func notices() throws -> [NoticeModel] { try context.fetch(FetchDescriptor<NoticeModel>()).filter { $0.deletedAt == nil && $0.purgedAt == nil }.sorted { lhs, rhs in lhs.pinned == rhs.pinned ? (lhs.pinned ? lhs.updatedAt > rhs.updatedAt : lhs.createdAt > rhs.createdAt) : lhs.pinned && !rhs.pinned } }
    func create(draft: NoticeDraft, by memberID: String) throws { guard try MemberDirectory.containsActive(memberID, in: context), !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RepositoryError.invalidData }; let notice = NoticeModel(title: draft.title, content: draft.content, publisherID: memberID, pinned: draft.pinned); try writes.commit(changing: { context.insert(notice) }, intents: { [RemoteMutationIntent(entityType: .notice, entityID: notice.id, operation: .create, payload: try RemoteBusinessPayload.notice(notice))] }) }
    func save(_ notice: NoticeModel, draft: NoticeDraft, by memberID: String) throws { guard notice.publisherID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }; guard notice.deletedAt == nil, notice.purgedAt == nil else { throw RepositoryError.trashConflict }; guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RepositoryError.invalidData }; try writes.commit(changing: { notice.title = draft.title; notice.content = draft.content; notice.pinned = draft.pinned; notice.isEdited = true; notice.updatedAt = .now }, intents: { [RemoteMutationIntent(entityType: .notice, entityID: notice.id, operation: .update, payload: try RemoteBusinessPayload.notice(notice))] }) }
    func delete(_ notice: NoticeModel, by memberID: String) throws {
        guard notice.publisherID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard notice.deletedAt == nil, notice.purgedAt == nil else { throw RepositoryError.trashConflict }
        try writes.commit(changing: {
            if writes.isRemoteEnabled {
                for read in try context.fetch(FetchDescriptor<NoticeReadModel>()) where read.noticeID == notice.id { context.delete(read) }
                context.delete(notice)
            } else { notice.deletedAt = .now }
        }, intents: { [RemoteMutationIntent(entityType: .notice, entityID: notice.id, operation: .delete)] })
    }
    func restore(_ notice: NoticeModel, deletedAt: Date, by memberID: String) throws {
        guard notice.publisherID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard RecycleRetention.isCurrent(notice.deletedAt, expected: deletedAt, purgedAt: notice.purgedAt) else { throw RepositoryError.trashConflict }
        guard RecycleRetention.canRestore(deletedAt) else { throw RepositoryError.trashExpired }
        guard !writes.isRemoteEnabled else { throw RemoteSyncError.unsupportedLocalData("远端恢复必须等待服务器权威结果") }
        try writes.commit(changing: { notice.deletedAt = nil })
    }
    func permanentlyDelete(_ notice: NoticeModel, deletedAt: Date, by memberID: String) throws {
        guard notice.publisherID == memberID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard RecycleRetention.isCurrent(notice.deletedAt, expected: deletedAt, purgedAt: notice.purgedAt) else { throw RepositoryError.trashConflict }
        guard !writes.isRemoteEnabled else { throw RemoteSyncError.unsupportedLocalData("远端永久删除必须等待服务器权威结果") }
        try writes.commit(changing: { try LocalRecycleMaintenance.scrub(notice, in: context) })
    }
    func markRead(_ notice: NoticeModel, memberID: String) throws { guard notice.deletedAt == nil, notice.purgedAt == nil else { throw RepositoryError.trashConflict }; guard notice.publisherID != memberID, try MemberDirectory.containsActive(memberID, in: context) else { return }; let reads = try context.fetch(FetchDescriptor<NoticeReadModel>()); guard !reads.contains(where: { $0.noticeID == notice.id && $0.memberID == memberID }) else { return }; let read = NoticeReadModel(noticeID: notice.id, memberID: memberID); try writes.commit(changing: { context.insert(read) }, intents: { [RemoteMutationIntent(entityType: .noticeRead, entityID: read.id, operation: .create, payload: try RemoteBusinessPayload.noticeRead(read))] }) }
}

/// Local retention shares the same content-scrubbing operations as a manual
/// permanent delete. It never touches remote state or creates a second sync
/// route; the backend owns retention in remoteSync mode.
@MainActor enum LocalRecycleMaintenance {
    static func canRemoveMedia(_ path: String, excluding messageID: UUID, in context: ModelContext) throws -> Bool {
        !(try context.fetch(FetchDescriptor<ChatMessageModel>())).contains {
            $0.id != messageID && $0.mediaPath == path && $0.purgedAt == nil
        }
    }

    static func scrub(_ message: ChatMessageModel, in context: ModelContext) throws {
        message.purgedAt = .now
        message.body = ""
        message.kindRaw = MessageKind.recalled.rawValue
        message.recalledAt = message.recalledAt ?? .now
        message.replyToID = nil
        message.mentionedMemberIDs = nil
        message.remoteMediaID = nil
        message.mediaTransferStateRaw = nil
        for receipt in try context.fetch(FetchDescriptor<MessageReceiptModel>()) where receipt.messageID == message.id {
            context.delete(receipt)
        }
    }

    static func scrub(_ item: AgendaItemModel, in context: ModelContext) throws {
        for exception in try context.fetch(FetchDescriptor<AgendaExceptionModel>()) where exception.agendaID == item.id {
            context.delete(exception)
        }
        item.purgedAt = .now; item.title = ""; item.location = nil; item.note = nil
        item.dishes = nil; item.ingredients = nil; item.seasonings = nil; item.participantIDs = []
        item.foodReadAtRecords = nil; item.foodReadByIDs = nil
        item.start = nil; item.end = nil; item.dueAt = nil; item.recurrenceRaw = AgendaRecurrence.none.rawValue
        item.recurrenceEnd = nil; item.estimatedArrival = nil; item.desiredMealTime = nil
    }

    static func scrub(_ memo: MemoModel) {
        memo.purgedAt = .now; memo.title = nil; memo.content = ""; memo.version += 1
    }

    static func scrub(_ notice: NoticeModel, in context: ModelContext) throws {
        for read in try context.fetch(FetchDescriptor<NoticeReadModel>()) where read.noticeID == notice.id {
            context.delete(read)
        }
        notice.purgedAt = .now; notice.title = ""; notice.content = ""
    }

    static func purgeExpired(in context: ModelContext, mediaStore: LocalMediaStore, now: Date = .now) throws {
        let cutoff = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -30, to: now) ?? now
        let messages = try context.fetch(FetchDescriptor<ChatMessageModel>())
        let agendas = try context.fetch(FetchDescriptor<AgendaItemModel>())
        let memos = try context.fetch(FetchDescriptor<MemoModel>())
        let notices = try context.fetch(FetchDescriptor<NoticeModel>())
        do {
            for value in messages where value.deletedAt.map({ $0 < cutoff }) == true && value.purgedAt == nil {
                try scrub(value, in: context)
            }
            for value in agendas where value.deletedAt.map({ $0 < cutoff }) == true && value.purgedAt == nil {
                try scrub(value, in: context)
            }
            for value in memos where value.deletedAt.map({ $0 < cutoff }) == true && value.purgedAt == nil {
                scrub(value)
            }
            for value in notices where value.deletedAt.map({ $0 < cutoff }) == true && value.purgedAt == nil {
                try scrub(value, in: context)
            }
            if context.hasChanges { try context.save() }
        } catch {
            context.rollback()
            throw error
        }
        // Retry media removal even if a prior file operation failed after the
        // tombstone commit. Keep its opaque path until the file is gone.
        for value in messages where value.purgedAt != nil {
            if let path = value.mediaPath {
                if try canRemoveMedia(path, excluding: value.id, in: context) {
                    try mediaStore.remove(path: path)
                }
                value.mediaPath = nil
                do { try context.save() }
                catch { context.rollback(); throw error }
            }
        }
    }
}
@MainActor final class LocalLocationRepository: LocationRepository {
    private let context: ModelContext; private let writes: BusinessWriteCoordinator
    init(context: ModelContext, remoteTransaction: RemoteMutationTransaction? = nil) { self.context = context; self.writes = BusinessWriteCoordinator(context: context, remoteTransaction: remoteTransaction) }
    func snapshots() throws -> [LocationSnapshotModel] { try context.fetch(FetchDescriptor<LocationSnapshotModel>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])) }
    func places() throws -> [FamilyPlaceModel] { try context.fetch(FetchDescriptor<FamilyPlaceModel>()) }
    func statuses() throws -> [MemberStatusModel] { try context.fetch(FetchDescriptor<MemberStatusModel>()) }
    func add(_ snapshot: LocationSnapshotModel) throws { guard try MemberDirectory.containsActive(snapshot.memberID, in: context) else { throw RepositoryError.forbidden }; try writes.commit(changing: { context.insert(snapshot) }, intents: { [RemoteMutationIntent(entityType: .locationSnapshot, entityID: snapshot.id, operation: .create, payload: try RemoteBusinessPayload.location(snapshot))] }) }
    func save(_ place: FamilyPlaceModel, draft: FamilyPlaceDraft, by memberID: String) throws {
        guard try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, [100, 200, 500, 1000].contains(draft.radius), (-90...90).contains(draft.latitude), (-180...180).contains(draft.longitude), try MemberDirectory.containsActive(draft.memberID, in: context) else { throw RepositoryError.invalidData }
        if draft.isEnabled, draft.kind == .home || draft.kind == .school {
            let duplicate = try places().contains { existing in
                existing.id != place.id && existing.memberID == draft.memberID && existing.kind == draft.kind && (existing.isEnabled ?? true)
            }
            guard !duplicate else { throw RepositoryError.invalidData }
        }
        let isNew = place.modelContext == nil
        try writes.commit(changing: {
            if isNew { context.insert(place) }
            place.name = draft.name
            place.kindRaw = draft.kind.rawValue
            place.memberID = draft.memberID
            place.latitude = draft.latitude
            place.longitude = draft.longitude
            place.radius = Double(draft.radius)
            place.isEnabled = draft.isEnabled
        }, intents: { [RemoteMutationIntent(entityType: .memberPlace, entityID: place.id, operation: isNew ? .create : .update, payload: try RemoteBusinessPayload.place(place))] })
    }
    func delete(_ place: FamilyPlaceModel, by memberID: String) throws { guard try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }; try writes.commit(changing: { context.delete(place) }, intents: { [RemoteMutationIntent(entityType: .memberPlace, entityID: place.id, operation: .delete)] }) }
    func saveStatus(memberID: String, status: SafetyStatus, estimatedArrival: Date?, by actorID: String) throws {
        guard memberID == actorID, try MemberDirectory.containsActive(memberID, in: context) else { throw RepositoryError.forbidden }
        let value = try statuses().first(where: { $0.memberID == memberID }) ?? MemberStatusModel(memberID: memberID)
        let isNew = value.modelContext == nil
        try writes.commit(changing: {
            if isNew { context.insert(value) }
            value.statusRaw = status.rawValue
            value.estimatedArrival = status == .headingHome ? estimatedArrival : nil
            value.updatedAt = .now
        }, intents: {
            let remote = try RemoteBusinessPayload.status(value)
            return [RemoteMutationIntent(entityType: .memberStatus, entityID: remote.entityID, operation: isNew ? .create : .update, payload: remote.payload)]
        })
    }
    func purgeHistory(now: Date = .now) throws { let calendar = Calendar.autoupdatingCurrent; let cutoff = calendar.date(byAdding: .day, value: -30, to: now) ?? now; for item in try snapshots() where item.timestamp < cutoff { context.delete(item) }; try context.save() }
}

enum LocationSharingPreference {
    static let enabledKey = "location.sharing.enabled"
    private static let requestedAlwaysKey = "location.sharing.requested-always"

    static var didRequestAlwaysAuthorization: Bool {
        get { UserDefaults.standard.bool(forKey: requestedAlwaysKey) }
        set { UserDefaults.standard.set(newValue, forKey: requestedAlwaysKey) }
    }
}

private struct LocationReading: Sendable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let horizontalAccuracy: Double
}

/// A single Core Location owner for the app. It never uploads directly: every
/// accepted reading is written through the existing location repository, which
/// keeps local-only and a future Outbox composition on the same data path.
@MainActor final class LowPowerLocationService: NSObject, CLLocationManagerDelegate {
    private enum TrackingProfile {
        case background, foreground, map

        var distanceFilter: CLLocationDistance {
            switch self {
            case .background: 400
            case .foreground: 250
            case .map: 75
            }
        }

        var minimumInterval: TimeInterval {
            switch self {
            case .background: 10 * 60
            case .foreground: 5 * 60
            case .map: 60
            }
        }

        var maximumAccuracy: CLLocationAccuracy {
            switch self {
            case .background: 500
            case .foreground: 250
            case .map: 100
            }
        }

        var desiredAccuracy: CLLocationAccuracy {
            switch self {
            case .background: kCLLocationAccuracyKilometer
            case .foreground: kCLLocationAccuracyHundredMeters
            case .map: kCLLocationAccuracyNearestTenMeters
            }
        }
    }

    private let manager = CLLocationManager()
    private let repository: LocationRepository
    private var memberID: String?
    private var sharingEnabled = false
    private var appIsActive = true
    private var mapIsVisible = false
    private var pendingManualRequest = false

    /// AppEnvironment supplies UI presentation; the service itself has no
    /// SwiftUI state and never decides whether an alert should be shown.
    var onAuthorizationMessageChanged: (@MainActor (String?) -> Void)?
    var onStorageError: (@MainActor (String) -> Void)?

    /// A map surface uses this only to decide whether it should offer the
    /// Settings shortcut. It never triggers another authorization request.
    var isPermissionUnavailable: Bool {
        guard CLLocationManager.locationServicesEnabled() else { return true }
        switch manager.authorizationStatus {
        case .denied, .restricted: return true
        default: return false
        }
    }

    init(repository: LocationRepository) {
        self.repository = repository
        super.init()
        manager.delegate = self
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
        manager.showsBackgroundLocationIndicator = false
    }

    func configureSharing(enabled: Bool, memberID: String?) {
        sharingEnabled = enabled
        self.memberID = memberID
        guard enabled, self.memberID != nil else {
            stopAllUpdates()
            onAuthorizationMessageChanged?(nil)
            return
        }
        applyAuthorizationState(requestingIfNeeded: true)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            appIsActive = true
            if sharingEnabled { applyAuthorizationState(requestingIfNeeded: false, requestFreshLocation: true) }
        case .background:
            appIsActive = false
            if sharingEnabled { applyAuthorizationState(requestingIfNeeded: false) }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func setMapVisible(_ visible: Bool) {
        mapIsVisible = visible
        guard sharingEnabled else { return }
        applyAuthorizationState(requestingIfNeeded: false, requestFreshLocation: visible)
    }

    /// Explicit user action only. It does not turn continuous sharing on.
    func requestImmediateUpdate(for memberID: String?) {
        guard let memberID, !memberID.isEmpty else { return }
        self.memberID = memberID
        pendingManualRequest = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.desiredAccuracy = currentProfile.desiredAccuracy
            manager.distanceFilter = currentProfile.distanceFilter
            manager.requestLocation()
        case .denied, .restricted:
            pendingManualRequest = false
            onAuthorizationMessageChanged?(authorizationMessage(for: manager.authorizationStatus))
        @unknown default:
            pendingManualRequest = false
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.handleAuthorizationChange(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.max(by: { $0.timestamp < $1.timestamp }) else { return }
        let reading = LocationReading(latitude: latest.coordinate.latitude,
                                      longitude: latest.coordinate.longitude,
                                      timestamp: latest.timestamp,
                                      horizontalAccuracy: latest.horizontalAccuracy)
        Task { @MainActor [weak self, reading] in
            self?.handle(reading)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let isLocationUnknown = (error as? CLError)?.code == .locationUnknown
        let message = error.localizedDescription
        Task { @MainActor [weak self, isLocationUnknown, message] in
            self?.handleLocationFailure(isLocationUnknown: isLocationUnknown, message: message)
        }
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        onAuthorizationMessageChanged?(authorizationMessage(for: status))
        if pendingManualRequest, isAuthorized(manager.authorizationStatus) {
            manager.requestLocation()
        }
        if sharingEnabled { applyAuthorizationState(requestingIfNeeded: true, requestFreshLocation: appIsActive) }
    }

    private func handle(_ reading: LocationReading) {
        let source: LocationSnapshotSource = pendingManualRequest ? .manual : .automatic
        pendingManualRequest = false
        storeIfMeaningful(reading, source: source)
    }

    private func handleLocationFailure(isLocationUnknown: Bool, message: String) {
        guard !isLocationUnknown else { return }
        pendingManualRequest = false
        onStorageError?("无法更新位置：\(message)")
    }

    private func applyAuthorizationState(requestingIfNeeded: Bool, requestFreshLocation: Bool = false) {
        let status = manager.authorizationStatus
        onAuthorizationMessageChanged?(authorizationMessage(for: status))
        switch status {
        case .notDetermined:
            if requestingIfNeeded { manager.requestWhenInUseAuthorization() }
        case .authorizedAlways:
            start(profile: currentProfile, requestFreshLocation: requestFreshLocation)
        case .authorizedWhenInUse:
            if requestingIfNeeded, !LocationSharingPreference.didRequestAlwaysAuthorization {
                LocationSharingPreference.didRequestAlwaysAuthorization = true
                manager.requestAlwaysAuthorization()
            }
            start(profile: currentProfile, requestFreshLocation: requestFreshLocation)
        case .denied, .restricted:
            stopAllUpdates()
        @unknown default:
            stopAllUpdates()
        }
    }

    private var currentProfile: TrackingProfile {
        if mapIsVisible { return .map }
        return appIsActive ? .foreground : .background
    }

    private func start(profile: TrackingProfile, requestFreshLocation: Bool) {
        manager.desiredAccuracy = profile.desiredAccuracy
        manager.distanceFilter = profile.distanceFilter
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = manager.authorizationStatus == .authorizedAlways
        if profile == .background {
            manager.stopUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()
        } else if profile == .map {
            manager.stopMonitoringSignificantLocationChanges()
            manager.startUpdatingLocation()
            if requestFreshLocation { manager.requestLocation() }
        } else {
            // Foreground sharing is deliberately request-based. Significant
            // change monitoring can wake this low-power path without keeping
            // the GPS hardware running between meaningful updates.
            manager.stopUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()
            if requestFreshLocation { manager.requestLocation() }
        }
    }

    private func stopAllUpdates() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        pendingManualRequest = false
    }

    private func storeIfMeaningful(_ reading: LocationReading, source: LocationSnapshotSource) {
        guard let memberID, reading.timestamp >= Date().addingTimeInterval(-5 * 60),
              reading.timestamp <= Date().addingTimeInterval(60), reading.horizontalAccuracy >= 0,
              reading.horizontalAccuracy <= currentProfile.maximumAccuracy else { return }
        do {
            let latest = try repository.snapshots().first { $0.memberID == memberID }
            if let latest, !isMeaningfullyNew(reading, comparedTo: latest, profile: currentProfile, source: source) { return }
            let snapshot = LocationSnapshotModel(memberID: memberID,
                                                 latitude: reading.latitude,
                                                 longitude: reading.longitude,
                                                 timestamp: reading.timestamp,
                                                 horizontalAccuracy: reading.horizontalAccuracy,
                                                 source: source)
            try repository.add(snapshot)
            try repository.purgeHistory(now: .now)
        } catch {
            onStorageError?("无法保存位置：\(error.localizedDescription)")
        }
    }

    private func isMeaningfullyNew(_ reading: LocationReading, comparedTo snapshot: LocationSnapshotModel, profile: TrackingProfile, source: LocationSnapshotSource) -> Bool {
        let prior = CLLocation(latitude: snapshot.latitude, longitude: snapshot.longitude)
        let incoming = CLLocation(latitude: reading.latitude, longitude: reading.longitude)
        let distance = incoming.distance(from: prior)
        let elapsed = reading.timestamp.timeIntervalSince(snapshot.timestamp)
        // A person explicitly asking for an update may refresh a stale
        // stationary reading, but never more often than five minutes. Automatic
        // updates always require meaningful movement and therefore do not keep
        // writing while someone remains still.
        if source == .manual, elapsed >= 5 * 60 { return true }
        guard distance >= profile.distanceFilter else { return false }
        return elapsed >= profile.minimumInterval || distance >= profile.distanceFilter * 2
    }

    private func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways || status == .authorizedWhenInUse
    }

    private func authorizationMessage(for status: CLAuthorizationStatus) -> String? {
        switch status {
        case .authorizedAlways: nil
        case .authorizedWhenInUse: "当前位置仅会在使用 App 时更新；如需后台低功耗更新，请在系统设置中选择“始终允许”。"
        case .denied: "位置权限已关闭，已保留最后有效位置。"
        case .restricted: "此设备当前不允许使用位置服务，已保留最后有效位置。"
        case .notDetermined: "开启位置共享后，系统会请求定位权限。"
        @unknown default: "位置权限状态不可用。"
        }
    }
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
    /// A remote download is cached as opaque media data; no presigned URL is
    /// retained in SwiftData or on disk.
    func storeAudio(_ data: Data) throws -> String { let name = UUID().uuidString + ".m4a"; try data.write(to: root.appendingPathComponent(name), options: .atomic); return name }
    func storeFile(from source: URL) throws -> String {
        let fileExtension = source.pathExtension.lowercased()
        guard Self.allowedFileExtensions.contains(fileExtension),
              (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw RepositoryError.invalidData
        }
        let name = "\(UUID().uuidString).\(fileExtension)"
        let destination = root.appendingPathComponent(name)
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            throw error
        }
        return name
    }
    func storeFile(_ data: Data, fileName: String) throws -> String {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard Self.allowedFileExtensions.contains(fileExtension), !data.isEmpty else { throw RepositoryError.invalidData }
        let name = "\(UUID().uuidString).\(fileExtension)"
        try data.write(to: root.appendingPathComponent(name), options: .atomic)
        return name
    }
    private static let allowedFileExtensions: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "zip"]
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

/// Shared initial map coordinates for seeded places and the map viewport.
enum FamilyMapDefaults {
    struct Coordinate { let latitude: Double; let longitude: Double }

    static let shaanxiNormalUniversityChangAn = Coordinate(latitude: 34.155040, longitude: 108.886710)
    static let xianJiaotongUniversityXingQing = Coordinate(latitude: 34.246233, longitude: 108.983741)
    static let changAnVankePlaza = Coordinate(latitude: 34.158382, longitude: 108.895452)
    static let initialCenter = Coordinate(latitude: 34.200637, longitude: 108.935226)
}

/// Read-only local consistency checks. It deliberately does not repair records
/// because a health check must not surprise a person by changing SwiftData.
struct DataHealthService {
    func evaluate(semesters: [SemesterModel], entries: [ScheduleEntryModel], scheduleExceptions: [ScheduleExceptionModel], agendas: [AgendaItemModel], agendaExceptions: [AgendaExceptionModel], places: [FamilyPlaceModel]) -> [DataHealthIssue] {
        var issues: [DataHealthIssue] = []
        let semestersByID = Dictionary(uniqueKeysWithValues: semesters.map { ($0.id, $0) })
        let currentCount = semesters.filter(\.isCurrent).count
        if currentCount != 1 { issues.append(DataHealthIssue(severity: .error, message: "当前学期数量应为 1，当前为 \(currentCount)。", symbol: "exclamationmark.triangle.fill")) }
        for entry in entries {
            guard let semester = semestersByID[entry.semesterID] else {
                issues.append(DataHealthIssue(severity: .error, message: "课程“\(entry.title)”没有对应学期。", symbol: "link.badge.plus")); continue
            }
            if !TimeAnalysisService.isValid(entry, totalWeeks: semester.totalWeeks) {
                issues.append(DataHealthIssue(severity: .error, message: "课程“\(entry.title)”的时间或周次无效。", symbol: "calendar.badge.exclamationmark"))
            }
        }
        let entryIDs = Set(entries.map(\.id))
        for exception in scheduleExceptions where !entryIDs.contains(exception.scheduleID) {
            issues.append(DataHealthIssue(severity: .warning, message: "存在已删除课程的例外规则。", symbol: "calendar.badge.exclamationmark"))
        }
        let agendaIDs = Set(agendas.map(\.id))
        for exception in agendaExceptions where !agendaIDs.contains(exception.agendaID) {
            issues.append(DataHealthIssue(severity: .warning, message: "存在已删除日程的周期例外规则。", symbol: "calendar.badge.exclamationmark"))
        }
        for kind in [PlaceKind.home, .school] {
            for memberID in Set(places.compactMap(\.memberID)) {
                let enabled = places.filter { $0.memberID == memberID && $0.kind == kind && ($0.isEnabled ?? true) }
                if enabled.count > 1 { issues.append(DataHealthIssue(severity: .warning, message: "\(memberID) 有多个启用中的“\(kind.localizedName)”。", symbol: "mappin.and.ellipse")) }
            }
        }
        return issues
    }
}

struct TimeAnalysisService {
    let calendar: Calendar = .autoupdatingCurrent
    static func isValid(_ entry: ScheduleEntryModel, totalWeeks: Int? = nil) -> Bool { !entry.ownerID.isEmpty && (1...7).contains(entry.weekday) && (0..<1_440).contains(entry.startMinutes) && (1...1_440).contains(entry.endMinutes) && entry.startMinutes < entry.endMinutes && entry.startWeek > 0 && entry.startWeek <= entry.endWeek && (totalWeeks.map { entry.endWeek <= $0 } ?? true) && WeekType(rawValue: entry.weekTypeRaw) != nil }
    func weekNumber(on date: Date, semester: SemesterModel) -> Int? {
        semester.weekNumber(on: date, calendar: calendar)
    }
    /// Validates that a date has an actual periodic-schedule candidate before
    /// individual exceptions are applied. A holiday candidate is intentionally
    /// retained so a course-specific reschedule can override that holiday.
    func isScheduleOccurrenceCandidate(_ entry: ScheduleEntryModel, on date: Date, calendarOverrides: [CalendarOverrideModel], semester: SemesterModel, allowsHolidayOverride: Bool = false) -> Bool {
        guard entry.semesterID == semester.id, Self.isValid(entry, totalWeeks: semester.totalWeeks),
              let week = semester.weekNumber(on: date, calendar: calendar),
              (entry.startWeek...entry.endWeek).contains(week), matches(entry.weekType, week: week) else { return false }
        let day = calendar.startOfDay(for: date)
        let natural = calendar.component(.weekday, from: day)
        let effective = effectiveWeekday(on: day, overrides: calendarOverrides, semesterID: semester.id)
        if effective == nil { return allowsHolidayOverride && natural == entry.weekday }
        return natural == entry.weekday || effective == entry.weekday
    }
    func busyIntervals(memberIDs: [String], in range: DateInterval, entries: [ScheduleEntryModel], exceptions: [ScheduleExceptionModel], agendas: [AgendaItemModel], agendaExceptions: [AgendaExceptionModel] = [], calendarOverrides: [CalendarOverrideModel] = [], semester: SemesterModel) -> [String: [BusyInterval]] {
        busyReasons(memberIDs: memberIDs, in: range, entries: entries, exceptions: exceptions, agendas: agendas, agendaExceptions: agendaExceptions, calendarOverrides: calendarOverrides, semester: semester).mapValues(merge)
    }

    /// The unmerged source list is used only for explanation UI. Free-time
    /// arithmetic always uses the merged output above and real wall-clock
    /// intervals, never the six-row presentation grid.
    func busyReasons(memberIDs: [String], in range: DateInterval, entries: [ScheduleEntryModel], exceptions: [ScheduleExceptionModel], agendas: [AgendaItemModel], agendaExceptions: [AgendaExceptionModel] = [], calendarOverrides: [CalendarOverrideModel] = [], semester: SemesterModel?) -> [String: [BusyInterval]] {
        guard range.start < range.end else { return [:] }
        let people = Array(Set(memberIDs.filter { !$0.isEmpty }))
        var result: [String: [BusyInterval]] = Dictionary(uniqueKeysWithValues: people.map { ($0, []) })
        if let semester {
            for entry in entries where people.contains(entry.ownerID) && entry.semesterID == semester.id && Self.isValid(entry, totalWeeks: semester.totalWeeks) {
                for interval in scheduleIntervals(entry, exceptions: exceptions.filter { $0.scheduleID == entry.id }, calendarOverrides: calendarOverrides, semester: semester, intersecting: range) { result[entry.ownerID, default: []].append(interval) }
            }
        }
        for agenda in agendas where agenda.deletedAt == nil && agenda.purgedAt == nil && (agenda.kind == .normal || agenda.kind == .exam) {
            for occurrence in agendaOccurrences(agenda, exceptions: agendaExceptions.filter { $0.agendaID == agenda.id }, in: range) {
                let category: BusyCategory = agenda.kind == .exam ? .exam : .normalAgenda
                for member in agenda.participantIDs where people.contains(member) { result[member, default: []].append(BusyInterval(start: occurrence.start, end: occurrence.end, source: agenda.title, category: category)) }
            }
        }
        return result.mapValues { $0.sorted { $0.start < $1.start } }
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
    func commonFree(memberIDs: [String], range: DateInterval, minimumMinutes: Int, bufferMinutes: Int = 0, entries: [ScheduleEntryModel], exceptions: [ScheduleExceptionModel], agendas: [AgendaItemModel], agendaExceptions: [AgendaExceptionModel] = [], calendarOverrides: [CalendarOverrideModel] = [], semester: SemesterModel) -> [AvailabilitySlot] {
        let people = Array(Set(memberIDs)).sorted(); guard people.count >= 2, minimumMinutes > 0 else { return [] }
        let busy = busyIntervals(memberIDs: people, in: range, entries: entries, exceptions: exceptions, agendas: agendas, agendaExceptions: agendaExceptions, calendarOverrides: calendarOverrides, semester: semester)
        let buffered = people.flatMap { busy[$0] ?? [] }.map { interval -> BusyInterval in
            guard bufferMinutes > 0 else { return interval }
            let start = max(range.start, calendar.date(byAdding: .minute, value: -bufferMinutes, to: interval.start) ?? interval.start)
            let end = min(range.end, calendar.date(byAdding: .minute, value: bufferMinutes, to: interval.end) ?? interval.end)
            return BusyInterval(start: start, end: end, source: interval.source, category: interval.category)
        }
        let combined = merge(buffered); var slots: [AvailabilitySlot] = []; var cursor = range.start
        for interval in combined { if cursor < interval.start { let candidate = AvailabilitySlot(start: cursor, end: interval.start, participants: memberIDs); if calendar.dateComponents([.minute], from: candidate.start, to: candidate.end).minute ?? 0 >= minimumMinutes { slots.append(candidate) } }; if interval.end > cursor { cursor = interval.end } }
        if cursor < range.end { let candidate = AvailabilitySlot(start: cursor, end: range.end, participants: memberIDs); if calendar.dateComponents([.minute], from: candidate.start, to: candidate.end).minute ?? 0 >= minimumMinutes { slots.append(candidate) } }; return slots
    }
    func rank(slots: [AvailabilitySlot], preferences: CoordinationPreferences, busyReasons: [String: [BusyInterval]]) -> [AvailabilitySlot] {
        slots.sorted { score($0, preferences: preferences, busyReasons: busyReasons) < score($1, preferences: preferences, busyReasons: busyReasons) }
    }
    func availabilityDetails(for slot: AvailabilitySlot, memberIDs: [String], entries: [ScheduleEntryModel], exceptions: [ScheduleExceptionModel], agendas: [AgendaItemModel], agendaExceptions: [AgendaExceptionModel] = [], calendarOverrides: [CalendarOverrideModel] = [], semester: SemesterModel) -> [MemberAvailabilityDetail] {
        let reasons = busyReasons(memberIDs: memberIDs, in: DateInterval(start: slot.start, end: slot.end), entries: entries, exceptions: exceptions, agendas: agendas, agendaExceptions: agendaExceptions, calendarOverrides: calendarOverrides, semester: semester)
        return memberIDs.map { memberID in
            MemberAvailabilityDetail(memberID: memberID, intervals: (reasons[memberID] ?? []).filter { $0.start < slot.end && slot.start < $0.end })
        }
    }
    private func score(_ slot: AvailabilitySlot, preferences: CoordinationPreferences, busyReasons: [String: [BusyInterval]]) -> Int {
        let hour = calendar.component(.hour, from: slot.start)
        var result = 0
        if preferences.avoidEarly && hour < 9 { result += 40 }
        if preferences.avoidLate && hour >= 20 { result += 40 }
        if preferences.avoidMeals && ((11...13).contains(hour) || (17...19).contains(hour)) { result += 20 }
        if preferences.avoidBeforeExam {
            let nextTwoHours = calendar.date(byAdding: .hour, value: 2, to: slot.end) ?? slot.end
            if busyReasons.values.flatMap({ $0 }).contains(where: { $0.category == .exam && $0.start >= slot.end && $0.start <= nextTwoHours }) { result += 30 }
        }
        return result
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
            return BusyInterval(start: occurrence.start, end: occurrence.end, source: entry.title, category: entry.kind == .course ? .course : .groupMeeting)
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
    private func merge(_ intervals: [BusyInterval]) -> [BusyInterval] { let sorted = intervals.sorted { $0.start < $1.start }; var result: [BusyInterval] = []; for interval in sorted { if let last = result.last, interval.start < last.end { result.removeLast(); result.append(BusyInterval(start: last.start, end: max(last.end, interval.end), source: last.source, category: last.category)) } else { result.append(interval) } }; return result }
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
@MainActor struct AIService {
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
    private let key: String
    var currentMemberID: String? { didSet { UserDefaults.standard.set(currentMemberID, forKey: key) } }
    let rememberedMemberID: String?
    init(storageKey: String = "family.session.member", restorePersistedSession: Bool = true) {
        key = storageKey
        rememberedMemberID = UserDefaults.standard.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
        currentMemberID = restorePersistedSession ? rememberedMemberID : nil
    }
    func login(identifier: String, password: String, in context: ModelContext) throws -> Bool {
        guard password == "qwer1234" else { return false }
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
        guard !normalized.isEmpty,
              let profile = try MemberDirectory.activeMembers(in: context).first(where: {
                  $0.memberID.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current) == normalized ||
                  $0.nickname.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current) == normalized
              }) else { return false }
        currentMemberID = profile.memberID
        return true
    }
    /// A future remote control-plane composition calls this only after storing
    /// a server-issued access/refresh pair. It is not a second login system.
    func establishRemoteSession(memberRemoteID: UUID) { currentMemberID = MemberIdentity.localMemberID(for: memberRemoteID) }
    func logout() { currentMemberID = nil }
}

@MainActor @Observable final class AppEnvironment {
    private static let pendingRemoteMemberKey = "family.remote.pending-member"
    /// The current Demo deliberately constructs only local repositories.
    /// A future opt-in may compose remoteSync separately; it is not selectable here.
    let runtimeMode: AppRuntimeMode
    private let remoteBaseURL: URL?
    private var remoteCoordinator: RemoteSyncCoordinator?
    private var remoteTrashAPI: RemoteAPIClient?
    private let remoteTransaction: RemoteMutationTransaction?
    private var remoteSyncTask: Task<Void, Never>?
    private var needsRemoteSync = false
    private var remoteSceneActive = true
    let context: ModelContext; let mediaStore: LocalMediaStore; let keychain = KeychainService(); let session: SessionStore; let timeAnalysis = TimeAnalysisService()
    /// Nil in the shipped localOnly composition. A future remote composition
    /// may inject a resolver without allowing views to construct a client.
    var remoteChatMediaResolver: (any RemoteChatMediaResolving)?
    /// Nil for the shipped Demo, so localOnly cannot trigger remote recovery.
    var recoveryFlow: RecoveryFlow?
    /// Nil in localOnly. Registration never constructs a remote client in a View.
    var registrationFlow: RegistrationFlow?
    var chatRepository: ChatRepository; let chatTransport: DemoChatTransport; let semesterRepository: SemesterRepository; let agendaRepository: AgendaRepository; let scheduleRepository: ScheduleRepository; let memoRepository: MemoRepository; let noticeRepository: NoticeRepository; let locationRepository: LocationRepository
    let automaticLocationService: LowPowerLocationService
    var locationPermissionMessage: String?
    /// The server is the authority in future remoteSync. Until the current
    /// installation has fetched or selected this role, automatic samples stay
    /// off; explicit manual updates keep their existing local behavior.
    private var remoteLocationSourceActive = false
    var lastError: String?; var refreshToken = UUID()

    init(modelContext: ModelContext, runtimeMode: AppRuntimeMode = .localOnly,
         remoteBaseURL: URL? = nil, remoteChatMediaResolver: (any RemoteChatMediaResolving)? = nil,
         recoveryFlow: RecoveryFlow? = nil, registrationFlow: RegistrationFlow? = nil) {
        self.runtimeMode = runtimeMode
        self.remoteBaseURL = runtimeMode == .remoteSync ? remoteBaseURL : nil
        session = SessionStore(
            storageKey: runtimeMode == .localOnly ? "family.session.member" : "family.session.remote-member",
            restorePersistedSession: runtimeMode == .localOnly
        )
        context = modelContext
        mediaStore = LocalMediaStore()
        self.remoteChatMediaResolver = runtimeMode == .remoteSync ? remoteChatMediaResolver : nil
        self.recoveryFlow = runtimeMode == .remoteSync ? recoveryFlow : nil
        self.registrationFlow = runtimeMode == .remoteSync ? registrationFlow : nil
        remoteTransaction = runtimeMode == .remoteSync ? RemoteMutationTransaction(context: modelContext) : nil
        chatRepository = LocalChatRepository(context: modelContext, mediaStore: mediaStore)
        chatTransport = DemoChatTransport(context: modelContext, enabled: runtimeMode == .localOnly)
        semesterRepository = LocalSemesterRepository(context: modelContext, remoteTransaction: remoteTransaction)
        agendaRepository = LocalAgendaRepository(context: modelContext, remoteTransaction: remoteTransaction)
        scheduleRepository = LocalScheduleRepository(context: modelContext, remoteTransaction: remoteTransaction)
        memoRepository = LocalMemoRepository(context: modelContext, remoteTransaction: remoteTransaction)
        noticeRepository = LocalNoticeRepository(context: modelContext, remoteTransaction: remoteTransaction)
        let locations = LocalLocationRepository(context: modelContext, remoteTransaction: remoteTransaction)
        locationRepository = locations
        automaticLocationService = LowPowerLocationService(repository: locations)
        automaticLocationService.onAuthorizationMessageChanged = { [weak self] message in self?.locationPermissionMessage = message }
        automaticLocationService.onStorageError = { [weak self] message in self?.lastError = message }
    }

    func bootstrap() {
        do {
            if runtimeMode == .remoteSync {
                try locationRepository.purgeHistory(now: .now)
                Task { @MainActor in
                    do {
                        let installationID = try RemoteInstallationIDStore().installationID()
                        if let remoteBaseURL { configureRemoteFlows(installationID: installationID, baseURL: remoteBaseURL) }
                        if let remembered = UserDefaults.standard.string(forKey: Self.pendingRemoteMemberKey)
                            ?? session.rememberedMemberID {
                            try await restoreRemoteSession(memberID: remembered)
                        }
                    } catch is CancellationError { }
                    catch RemoteSyncError.authenticationRequired {
                        invalidateRemoteAccess()
                        lastError = RemoteSyncError.authenticationRequired.localizedDescription
                    } catch { lastError = error.localizedDescription; session.logout() }
                }
                return
            }
            #if DEBUG
            try DemoDataService(context: context, mediaStore: mediaStore).seedIfNeeded()
            #else
            try DemoDataService(context: context, mediaStore: mediaStore).seedInitialMembersIfNeeded()
            #endif
            try LocalRecycleMaintenance.purgeExpired(in: context, mediaStore: mediaStore)
            if let memberID = session.currentMemberID,
               !(try MemberDirectory.containsActive(memberID, in: context)) {
                session.logout()
                if runtimeMode == .remoteSync { KeychainRemoteCredentialStore.clear() }
            }
            try locationRepository.purgeHistory(now: .now)
            refreshLocationSharing()
            refreshToken = UUID()
        } catch { lastError = error.localizedDescription }
    }
    var isRemoteLogin: Bool { runtimeMode == .remoteSync }

    private func configureRemoteFlows(installationID: String, baseURL: URL,
                                      authenticatedAPI: RemoteAPIClient? = nil) {
        let credentials = KeychainRemoteCredentialStore()
        let recovery = RecoveryFlow(
            publicAPI: RemoteRecoveryAPIClient(baseURL: baseURL),
            authenticatedAPI: authenticatedAPI, credentials: credentials,
            installationID: installationID,
            sessionReadyHandler: { [weak self] memberID in
                guard let self else { throw RemoteSyncError.invalidConfiguration }
                try await self.activateRemoteSession(memberID: memberID, credentials: credentials)
            }
        )
        recoveryFlow = recovery
        registrationFlow = RegistrationFlow(
            publicAPI: RemoteRegistrationAPIClient(baseURL: baseURL),
            approvalAPI: authenticatedAPI, memberManagementAPI: authenticatedAPI,
            deviceManagementAPI: authenticatedAPI, credentials: credentials,
            installationID: installationID, recoveryFlow: recovery,
            activationHandler: { [weak self] memberID, _ in
                guard let self else { throw RemoteSyncError.invalidConfiguration }
                try await self.activateRemoteSession(memberID: memberID, credentials: credentials)
            }
        )
    }

    func loginRemote(identifier: String, password: String) async throws {
        guard runtimeMode == .remoteSync, let remoteBaseURL else { throw RemoteSyncError.invalidConfiguration }
        let installationID = try RemoteInstallationIDStore().installationID()
        let result = try await RemotePasswordLoginClient(baseURL: remoteBaseURL).login(
            identifier: identifier, password: password, installationID: installationID,
            deviceName: "此设备"
        )
        let credentials = KeychainRemoteCredentialStore()
        try await credentials.store(result.tokenPair)
        try await activateRemoteSession(memberID: result.memberID, credentials: credentials)
    }

    func logoutCurrentSession() async throws {
        guard runtimeMode == .remoteSync else { session.logout(); return }
        guard let remoteBaseURL else { throw RemoteSyncError.invalidConfiguration }
        await remoteCoordinator?.stopCursorNotifications()
        remoteSyncTask?.cancel()
        await remoteSyncTask?.value
        let credentials = KeychainRemoteCredentialStore()
        let refresh = try await credentials.refreshToken()
        try await RemotePasswordLoginClient(baseURL: remoteBaseURL).logout(refreshToken: refresh)
        await credentials.invalidate()
        UserDefaults.standard.removeObject(forKey: Self.pendingRemoteMemberKey)
        remoteCoordinator = nil
        remoteTrashAPI = nil
        remoteTransaction?.didCommit = nil
        needsRemoteSync = false
        remoteChatMediaResolver = nil
        remoteLocationSourceActive = false
        automaticLocationService.configureSharing(enabled: false, memberID: nil)
        session.logout()
    }

    private func restoreRemoteSession(memberID: String) async throws {
        guard let remoteID = MemberIdentity.remoteUUID(for: memberID) else {
            throw RemoteSyncError.authenticationRequired
        }
        let credentials = KeychainRemoteCredentialStore()
        _ = try await credentials.accessToken()
        try await activateRemoteSession(memberID: remoteID, credentials: credentials)
    }

    private func activateRemoteSession(memberID: UUID, credentials: KeychainRemoteCredentialStore) async throws {
        guard runtimeMode == .remoteSync, let remoteBaseURL else { throw RemoteSyncError.invalidConfiguration }
        // Only a nonsecret UUID is kept while a committed token pair waits
        // for bootstrap. A crash at this boundary can safely resume recovery.
        UserDefaults.standard.set(MemberIdentity.localMemberID(for: memberID), forKey: Self.pendingRemoteMemberKey)
        let deviceID = try await credentials.deviceID()
        let api = RemoteAPIClient(baseURL: remoteBaseURL, deviceID: deviceID, credentials: credentials)
        guard try await api.currentMemberID() == memberID else {
            await credentials.invalidate()
            UserDefaults.standard.removeObject(forKey: Self.pendingRemoteMemberKey)
            throw RemoteSyncError.authenticationRequired
        }
        let coordinator = RemoteSyncCoordinator(
            context: context, api: api, deviceID: deviceID,
            cursorAPI: api,
            currentMemberRemoteID: memberID,
            onCurrentMemberRemoved: RemoteSyncCoordinator.membershipRemovalHandler(environment: self),
            onCursorHint: { [weak self] _ in self?.synchronizeRemoteIfActive() },
            onAuthenticationRequired: { [weak self] in self?.invalidateRemoteAccess() }
        )
        _ = try await coordinator.synchronize()
        guard try MemberDirectory.containsActive(MemberIdentity.localMemberID(for: memberID), in: context) else {
            await credentials.invalidate()
            throw RemoteSyncError.authenticationRequired
        }
        guard let transaction = remoteTransaction else { throw RemoteSyncError.invalidConfiguration }
        let transfer = RemoteChatMediaTransferCoordinator(context: context, mediaStore: mediaStore, api: api, transaction: transaction)
        chatRepository = LocalChatRepository(context: context, mediaStore: mediaStore,
                                             remoteTransaction: transaction, remoteMediaTransfer: transfer)
        remoteChatMediaResolver = RemoteChatMediaResolver(context: context, mediaStore: mediaStore, api: api)
        let installationID = try RemoteInstallationIDStore().installationID()
        configureRemoteFlows(installationID: installationID, baseURL: remoteBaseURL, authenticatedAPI: api)
        let devices = try await api.devices()
        setRemoteLocationSourceActive(devices.first(where: { $0.id == deviceID })?.isLocationSource == true)
        remoteCoordinator = coordinator
        remoteTrashAPI = api
        session.establishRemoteSession(memberRemoteID: memberID)
        UserDefaults.standard.removeObject(forKey: Self.pendingRemoteMemberKey)
        transaction.didCommit = { [weak self] in self?.synchronizeRemoteIfActive() }
        await transfer.resumeRecoverableTransfers()
        if remoteSceneActive { coordinator.startCursorNotifications() }
        refreshToken = UUID()
    }

    func synchronizeRemoteIfActive() {
        guard runtimeMode == .remoteSync, session.currentMemberID != nil,
              let remoteCoordinator else { return }
        needsRemoteSync = true
        guard remoteSyncTask == nil else { return }
        remoteSyncTask = Task { @MainActor in
            while needsRemoteSync && session.currentMemberID != nil {
                needsRemoteSync = false
                do { _ = try await remoteCoordinator.synchronize(); refreshToken = UUID() }
                catch is CancellationError { break }
                catch RemoteSyncError.authenticationRequired {
                    invalidateRemoteAccess()
                    lastError = RemoteSyncError.authenticationRequired.localizedDescription
                    break
                }
                catch { lastError = error.localizedDescription; break }
            }
            remoteSyncTask = nil
        }
    }
    func remoteTrashItems() async throws -> [RemoteTrashItem] {
        guard runtimeMode == .remoteSync, session.currentMemberID != nil,
              let remoteTrashAPI else { throw RemoteSyncError.authenticationRequired }
        return try await remoteTrashAPI.trashItems()
    }

    func changeRemoteTrash(_ item: RemoteTrashItem, permanent: Bool) async throws {
        guard runtimeMode == .remoteSync, session.currentMemberID != nil,
              let remoteTrashAPI, let remoteCoordinator else { throw RemoteSyncError.authenticationRequired }
        let mutationID = RemoteStableID.trashMutation(entityType: item.entityType, entityID: item.id,
                                                      version: item.version, permanent: permanent)
        try await remoteTrashAPI.changeTrash(item, permanent: permanent, mutationID: mutationID)
        // The server has committed the original-ID recovery or tombstone.
        // Never mutate a SwiftData business row optimistically in this path.
        _ = try await remoteCoordinator.synchronize()
        refreshToken = UUID()
    }
    func resetDemo() {
        #if DEBUG
        do { try DemoDataService(context: context, mediaStore: mediaStore).resetDemo(); refreshToken = UUID() }
        catch { lastError = error.localizedDescription }
        #endif
    }
    func clearAllLocalData() { do { try DemoDataService(context: context, mediaStore: mediaStore).clearAll(); keychain.clear(); RemoteInstallationIDStore.clear(); KeychainRemoteCredentialStore.clear(); KeychainPendingRegistrationStore.clear(); UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "FamilyApp"); session.logout(); automaticLocationService.configureSharing(enabled: false, memberID: nil); refreshToken = UUID() } catch { lastError = error.localizedDescription } }
    func send(_ message: ChatMessageModel) { do { try chatRepository.create(message); chatTransport.simulateReceipts(for: message); refreshToken = UUID(); synchronizeRemoteIfActive() } catch { lastError = error.localizedDescription } }
    func refreshLocationSharing() {
        let localPreference = UserDefaults.standard.bool(forKey: LocationSharingPreference.enabledKey)
        let canAutomaticallyShare = runtimeMode == .localOnly || remoteLocationSourceActive
        automaticLocationService.configureSharing(
            enabled: localPreference && canAutomaticallyShare,
            memberID: session.currentMemberID,
        )
    }
    func setRemoteLocationSourceActive(_ isActive: Bool) {
        guard runtimeMode == .remoteSync else { return }
        remoteLocationSourceActive = isActive
        refreshLocationSharing()
    }
    /// Invoked by the dormant remote-sync composition only after a committed
    /// Member tombstone identifies the signed-in remote UUID. History stays in
    /// SwiftData, while the local session and credentials stop further writes.
    func handleRemoteMembershipRemoval(_ remoteMemberID: UUID) {
        guard runtimeMode == .remoteSync,
              let localMemberID = session.currentMemberID,
              let profile = try? context.fetch(FetchDescriptor<MemberProfile>()).first(where: {
                  $0.memberID == localMemberID && $0.stableRemoteID == remoteMemberID
              }),
              profile.isActiveMember == false else { return }
        invalidateRemoteAccess()
    }

    private func invalidateRemoteAccess() {
        if let remoteCoordinator {
            Task { @MainActor in await remoteCoordinator.stopCursorNotifications() }
        }
        session.logout()
        remoteLocationSourceActive = false
        automaticLocationService.configureSharing(enabled: false, memberID: nil)
        KeychainRemoteCredentialStore.clear()
        remoteSyncTask?.cancel()
        remoteCoordinator = nil
        remoteTrashAPI = nil
        remoteTransaction?.didCommit = nil
        needsRemoteSync = false
        UserDefaults.standard.removeObject(forKey: Self.pendingRemoteMemberKey)
        remoteChatMediaResolver = nil
        refreshToken = UUID()
    }
    func locationScenePhaseChanged(_ phase: ScenePhase) async {
        automaticLocationService.scenePhaseChanged(phase)
        remoteSceneActive = phase == .active
        guard runtimeMode == .remoteSync, let remoteCoordinator else { return }
        if remoteSceneActive {
            remoteCoordinator.startCursorNotifications()
            synchronizeRemoteIfActive()
        } else {
            await remoteCoordinator.stopCursorNotifications()
        }
    }
    func setMapLocationTrackingActive(_ active: Bool) { automaticLocationService.setMapVisible(active) }
    func requestImmediateLocationUpdate() { automaticLocationService.requestImmediateUpdate(for: session.currentMemberID) }
}
