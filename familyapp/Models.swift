import Foundation
import SwiftData

@Model final class MemberProfile {
    @Attribute(.unique) var memberID: String
    var nickname: String
    var colorKey: String
    var avatarSymbol: String?
    /// Initial records retain their historical name keys. New remote members
    /// use their UUID string as `memberID`; this optional field permits old
    /// stores to migrate without rewriting existing business rows.
    var remoteMemberID: UUID?
    /// `nil` is interpreted from `memberID` for records created before this
    /// dynamic-member compatibility layer.
    var isInitialMember: Bool?
    /// Optional fields preserve old stores while retaining a departed member's
    /// identity for historical chat, agenda, notice, and location records.
    var isActive: Bool?
    var removedAt: Date?
    init(memberID: String, nickname: String, colorKey: String, avatarSymbol: String? = "person.crop.circle.fill", remoteMemberID: UUID? = nil, isInitialMember: Bool? = nil, isActive: Bool? = nil, removedAt: Date? = nil) {
        self.memberID = memberID; self.nickname = nickname; self.colorKey = colorKey; self.avatarSymbol = avatarSymbol
        self.remoteMemberID = remoteMemberID ?? MemberIdentity.remoteUUID(for: memberID)
        self.isInitialMember = isInitialMember ?? MemberIdentity.isInitialMember(memberID)
        self.isActive = isActive
        self.removedAt = removedAt
    }

    var stableRemoteID: UUID? { remoteMemberID ?? MemberIdentity.remoteUUID(for: memberID) }
    var isProtectedInitialMember: Bool { isInitialMember ?? MemberIdentity.isInitialMember(memberID) }
    var isActiveMember: Bool { removedAt == nil && (isActive ?? true) }
    var displayName: String { isActiveMember ? nickname : "\(nickname)（已退出）" }
}

@Model final class SemesterModel {
    @Attribute(.unique) var id: UUID
    var name: String
    var week1StartDate: Date
    /// Optional so stores created before the explicit range UI migrate in place.
    /// A missing value is treated as the sixth calendar day after the start.
    var week1EndDate: Date?
    var totalWeeks: Int
    var isCurrent: Bool
    init(id: UUID = UUID(), name: String, week1StartDate: Date, week1EndDate: Date? = nil, totalWeeks: Int, isCurrent: Bool = true) { self.id = id; self.name = name; self.week1StartDate = week1StartDate; self.week1EndDate = week1EndDate; self.totalWeeks = totalWeeks; self.isCurrent = isCurrent }
}

@Model final class ScheduleEntryModel {
    @Attribute(.unique) var id: UUID
    var ownerID: String; var semesterID: UUID; var title: String
    var kindRaw: String; var weekday: Int; var startMinutes: Int; var endMinutes: Int
    var startWeek: Int; var endWeek: Int; var weekTypeRaw: String
    var major: String?; var grade: String?; var className: String?; var location: String?; var note: String?; var labName: String?; var advisor: String?
    /// Optional to keep existing local stores compatible. A non-nil value is
    /// only assigned by the local import repository after confirmation.
    var importBatchID: UUID?
    init(id: UUID = UUID(), ownerID: String, semesterID: UUID, title: String, kind: ScheduleKind, weekday: Int, startMinutes: Int, endMinutes: Int, startWeek: Int, endWeek: Int, weekType: WeekType, major: String? = nil, grade: String? = nil, className: String? = nil, location: String? = nil, note: String? = nil, labName: String? = nil, advisor: String? = nil) {
        self.id = id; self.ownerID = ownerID; self.semesterID = semesterID; self.title = title; self.kindRaw = kind.rawValue; self.weekday = weekday; self.startMinutes = startMinutes; self.endMinutes = endMinutes; self.startWeek = startWeek; self.endWeek = endWeek; self.weekTypeRaw = weekType.rawValue; self.major = major; self.grade = grade; self.className = className; self.location = location; self.note = note; self.labName = labName; self.advisor = advisor; self.importBatchID = nil
    }
    var kind: ScheduleKind { ScheduleKind(rawValue: kindRaw) ?? .course }
    var weekType: WeekType { WeekType(rawValue: weekTypeRaw) ?? .everyWeek }
}

/// A reversible local import record. String arrays are used intentionally: they
/// are already SwiftData-compatible in the existing store and avoid a new
/// relationship migration solely for import history.
@Model final class ScheduleImportBatchModel {
    @Attribute(.unique) var id: UUID
    var semesterID: UUID
    var ownerID: String
    var sourceRaw: String
    var createdAt: Date
    var importedEntryIDs: [String]
    var updatedEntrySnapshots: String?
    /// Optional metadata keeps import history readable for stores created
    /// before file provenance and guarded undo were added.
    var sourceFileName: String?
    var sourceFileType: String?
    /// A base64 encoded set of expected post-import states.  It makes undo a
    /// compare-and-apply operation instead of overwriting later edits.
    var undoRecords: String?

    init(id: UUID = UUID(), semesterID: UUID, ownerID: String, source: String,
         createdAt: Date = .now, importedEntryIDs: [String] = [], updatedEntrySnapshots: String? = nil,
         sourceFileName: String? = nil, sourceFileType: String? = nil, undoRecords: String? = nil) {
        self.id = id; self.semesterID = semesterID; self.ownerID = ownerID
        self.sourceRaw = source; self.createdAt = createdAt
        self.importedEntryIDs = importedEntryIDs; self.updatedEntrySnapshots = updatedEntrySnapshots
        self.sourceFileName = sourceFileName; self.sourceFileType = sourceFileType; self.undoRecords = undoRecords
    }
}

@Model final class ScheduleExceptionModel {
    @Attribute(.unique) var id: UUID
    var scheduleID: UUID; var kindRaw: String; var scopeRaw: String; var occurrenceDate: Date
    var replacementDate: Date?; var replacementStartMinutes: Int?; var replacementEndMinutes: Int?; var replacementWeekday: Int?; var note: String?
    init(id: UUID = UUID(), scheduleID: UUID, kind: ExceptionKind, scope: ExceptionScope = .thisOccurrence, occurrenceDate: Date, replacementDate: Date? = nil, replacementStartMinutes: Int? = nil, replacementEndMinutes: Int? = nil, replacementWeekday: Int? = nil, note: String? = nil) { self.id = id; self.scheduleID = scheduleID; self.kindRaw = kind.rawValue; self.scopeRaw = scope.rawValue; self.occurrenceDate = occurrenceDate; self.replacementDate = replacementDate; self.replacementStartMinutes = replacementStartMinutes; self.replacementEndMinutes = replacementEndMinutes; self.replacementWeekday = replacementWeekday; self.note = note }
    var kind: ExceptionKind { ExceptionKind(rawValue: kindRaw) ?? .modified }; var scope: ExceptionScope { ExceptionScope(rawValue: scopeRaw) ?? .thisOccurrence }
}

/// A local academic-calendar rule. Optional fields keep stores created before
/// calendar overrides readable without a destructive migration.
@Model final class CalendarOverrideModel {
    @Attribute(.unique) var id: UUID
    var semesterID: UUID
    var date: Date
    var kindRaw: String
    var mappedWeekday: Int?
    var note: String?

    init(id: UUID = UUID(), semesterID: UUID, date: Date, kind: CalendarOverrideKind,
         mappedWeekday: Int? = nil, note: String? = nil) {
        self.id = id; self.semesterID = semesterID; self.date = date
        self.kindRaw = kind.rawValue; self.mappedWeekday = mappedWeekday; self.note = note
    }

    var kind: CalendarOverrideKind { CalendarOverrideKind(rawValue: kindRaw) ?? .normal }
}

@Model final class AgendaItemModel {
    @Attribute(.unique) var id: UUID
    var creatorID: String; var title: String; var kindRaw: String; var start: Date?; var end: Date?; var dueAt: Date?
    var location: String?; var note: String?; var participantIDs: [String]; var recurrenceRaw: String; var recurrenceEnd: Date?; var dishes: String?; var ingredients: String?; var seasonings: String?; var peopleCount: Int?; var estimatedArrival: Date?; var desiredMealTime: Date?; var preparationRaw: String?; var completionRaw: String?; var foodReadByIDs: [String]?; var foodReadAtRecords: [String]?
    /// Optional recycle metadata preserves existing SwiftData stores.
    var deletedAt: Date?
    var purgedAt: Date?
    init(id: UUID = UUID(), creatorID: String, title: String, kind: AgendaKind, start: Date? = nil, end: Date? = nil, dueAt: Date? = nil, location: String? = nil, note: String? = nil, participantIDs: [String], recurrence: AgendaRecurrence = .none, recurrenceEnd: Date? = nil, dishes: String? = nil, ingredients: String? = nil, seasonings: String? = nil, peopleCount: Int? = nil, estimatedArrival: Date? = nil, desiredMealTime: Date? = nil, preparation: PreparationState? = nil, completion: CompletionState? = nil, foodReadByIDs: [String] = [], foodReadAtRecords: [String]? = nil) { self.id = id; self.creatorID = creatorID; self.title = title; self.kindRaw = kind.rawValue; self.start = start; self.end = end; self.dueAt = dueAt; self.location = location; self.note = note; self.participantIDs = participantIDs; self.recurrenceRaw = recurrence.rawValue; self.recurrenceEnd = recurrenceEnd; self.dishes = dishes; self.ingredients = ingredients; self.seasonings = seasonings; self.peopleCount = peopleCount; self.estimatedArrival = estimatedArrival; self.desiredMealTime = desiredMealTime; self.preparationRaw = preparation?.rawValue; self.completionRaw = completion?.rawValue; self.foodReadByIDs = foodReadByIDs; self.foodReadAtRecords = foodReadAtRecords }
    var kind: AgendaKind { AgendaKind(rawValue: kindRaw) ?? .normal }; var recurrence: AgendaRecurrence { AgendaRecurrence(rawValue: recurrenceRaw) ?? .none }
}

/// Exceptions are stored as rules, not pre-generated Agenda instances.
@Model final class AgendaExceptionModel {
    @Attribute(.unique) var id: UUID
    var agendaID: UUID; var kindRaw: String; var scopeRaw: String; var occurrenceDate: Date
    var replacementDate: Date?; var replacementStart: Date?; var replacementEnd: Date?; var note: String?
    init(id: UUID = UUID(), agendaID: UUID, kind: ExceptionKind, scope: ExceptionScope = .thisOccurrence, occurrenceDate: Date, replacementDate: Date? = nil, replacementStart: Date? = nil, replacementEnd: Date? = nil, note: String? = nil) { self.id = id; self.agendaID = agendaID; self.kindRaw = kind.rawValue; self.scopeRaw = scope.rawValue; self.occurrenceDate = occurrenceDate; self.replacementDate = replacementDate; self.replacementStart = replacementStart; self.replacementEnd = replacementEnd; self.note = note }
    var kind: ExceptionKind { ExceptionKind(rawValue: kindRaw) ?? .modified }
    var scope: ExceptionScope { ExceptionScope(rawValue: scopeRaw) ?? .thisOccurrence }
}

@Model final class MemoModel { @Attribute(.unique) var id: UUID; var title: String?; var content: String; var creatorID: String; var pinned: Bool; var version: Int; var createdAt: Date; var updatedAt: Date; var updatedBy: String
    var deletedAt: Date?; var purgedAt: Date?
    init(id: UUID = UUID(), title: String? = nil, content: String, creatorID: String, pinned: Bool = false, version: Int = 1, createdAt: Date = .now, updatedAt: Date = .now, updatedBy: String) { self.id = id; self.title = title; self.content = content; self.creatorID = creatorID; self.pinned = pinned; self.version = version; self.createdAt = createdAt; self.updatedAt = updatedAt; self.updatedBy = updatedBy }
}
@Model final class NoticeModel { @Attribute(.unique) var id: UUID; var title: String; var content: String; var publisherID: String; var pinned: Bool; var createdAt: Date; var updatedAt: Date; var isEdited: Bool
    var deletedAt: Date?; var purgedAt: Date?
    init(id: UUID = UUID(), title: String, content: String, publisherID: String, pinned: Bool = false, createdAt: Date = .now, updatedAt: Date = .now, isEdited: Bool = false) { self.id = id; self.title = title; self.content = content; self.publisherID = publisherID; self.pinned = pinned; self.createdAt = createdAt; self.updatedAt = updatedAt; self.isEdited = isEdited }
}
@Model final class NoticeReadModel { @Attribute(.unique) var id: UUID; var noticeID: UUID; var memberID: String; var readAt: Date
    init(id: UUID = UUID(), noticeID: UUID, memberID: String, readAt: Date = .now) { self.id = id; self.noticeID = noticeID; self.memberID = memberID; self.readAt = readAt }
}
@Model final class ChatMessageModel { @Attribute(.unique) var id: UUID; var senderID: String; var body: String; var kindRaw: String; var sentAt: Date; var statusRaw: String; var mediaPath: String?; var replyToID: UUID?; var recalledAt: Date?; var isUnread: Bool
    var deletedAt: Date?
    var purgedAt: Date?
    /// Optional for compatibility with messages stored before member mentions.
    var mentionedMemberIDs: [UUID]?
    /// Future remoteSync keeps only a stable asset ID here. The object-store
    /// URL is intentionally never persisted because every download grant is
    /// short lived and authorization-dependent.
    var remoteMediaID: UUID?
    /// Server-authoritative attachment metadata cached on the existing message.
    /// All fields are optional so existing SwiftData stores remain readable.
    var mediaFileName: String?
    var mediaContentType: String?
    var mediaSizeBytes: Int?
    var mediaRemoteStatus: String?
    var mediaChecksum: String?
    var mediaTransferStateRaw: String?
    var mediaRetryCount: Int?
    var mediaLastAttemptAt: Date?
    var mediaLastErrorCode: String?
    init(id: UUID = UUID(), senderID: String, body: String = "", kind: MessageKind, sentAt: Date = .now, status: ReceiptStatus = .sent, mediaPath: String? = nil, replyToID: UUID? = nil, recalledAt: Date? = nil, isUnread: Bool = false, mentionedMemberIDs: [UUID]? = nil, remoteMediaID: UUID? = nil, mediaTransferState: RemoteMediaTransferState? = nil, mediaRetryCount: Int? = nil, mediaLastAttemptAt: Date? = nil, mediaLastErrorCode: String? = nil) { self.id = id; self.senderID = senderID; self.body = body; self.kindRaw = kind.rawValue; self.sentAt = sentAt; self.statusRaw = status.rawValue; self.mediaPath = mediaPath; self.replyToID = replyToID; self.recalledAt = recalledAt; self.isUnread = isUnread; self.mentionedMemberIDs = mentionedMemberIDs; self.remoteMediaID = remoteMediaID; self.mediaTransferStateRaw = mediaTransferState?.rawValue; self.mediaRetryCount = mediaRetryCount; self.mediaLastAttemptAt = mediaLastAttemptAt; self.mediaLastErrorCode = mediaLastErrorCode }
    var kind: MessageKind { MessageKind(rawValue: kindRaw) ?? .text }; var status: ReceiptStatus { ReceiptStatus(rawValue: statusRaw) ?? .sent }
    var mediaTransferState: RemoteMediaTransferState? { mediaTransferStateRaw.flatMap(RemoteMediaTransferState.init(rawValue:)) }
}
/// Per-member receipt data is kept separately from the compact chat-row
/// status. It is dormant in localOnly, but prevents a future remote receipt
/// pull from collapsing multiple readers into one mutable message flag.
@Model final class MessageReceiptModel {
    @Attribute(.unique) var id: UUID
    var messageID: UUID
    var memberID: String
    var deliveredAt: Date?
    var readAt: Date?
    init(id: UUID = UUID(), messageID: UUID, memberID: String, deliveredAt: Date? = nil, readAt: Date? = nil) {
        self.id = id; self.messageID = messageID; self.memberID = memberID
        self.deliveredAt = deliveredAt; self.readAt = readAt
    }
}
@Model final class LocationSnapshotModel { @Attribute(.unique) var id: UUID; var memberID: String; var latitude: Double; var longitude: Double; var timestamp: Date; var event: String?
    /// Optional fields preserve stores created before automatic location sharing.
    var horizontalAccuracy: Double?
    var sourceRaw: String?
    init(id: UUID = UUID(), memberID: String, latitude: Double, longitude: Double, timestamp: Date, event: String? = nil, horizontalAccuracy: Double? = nil, source: LocationSnapshotSource? = nil) { self.id = id; self.memberID = memberID; self.latitude = latitude; self.longitude = longitude; self.timestamp = timestamp; self.event = event; self.horizontalAccuracy = horizontalAccuracy; self.sourceRaw = source?.rawValue }
    var source: LocationSnapshotSource { sourceRaw.flatMap(LocationSnapshotSource.init(rawValue:)) ?? .manual }
}
@Model final class MemberStatusModel {
    @Attribute(.unique) var memberID: String
    var statusRaw: String
    var estimatedArrival: Date?
    var updatedAt: Date

    init(memberID: String, status: SafetyStatus = .allGood, estimatedArrival: Date? = nil, updatedAt: Date = .now) {
        self.memberID = memberID; self.statusRaw = status.rawValue
        self.estimatedArrival = estimatedArrival; self.updatedAt = updatedAt
    }

    var status: SafetyStatus { SafetyStatus(rawValue: statusRaw) ?? .allGood }
}
/// Dormant remoteSync outbox. localOnly neither writes nor reads these rows.
@Model final class PendingMutationModel {
    @Attribute(.unique) var id: UUID
    var entityType: String; var entityID: UUID; var operation: String; var baseVersion: Int?
    var payloadJSON: String; var clientTimestamp: Date; var retryCount: Int
    /// Optional fields keep stores created for the local-only Demo compatible.
    /// A missing state is interpreted as pending by the dormant sync path.
    var stateRaw: String?
    var lastAttemptAt: Date?
    var nextRetryAt: Date?
    var lastErrorCode: String?
    var acknowledgedAt: Date?
    init(id: UUID = UUID(), entityType: String, entityID: UUID, operation: String, baseVersion: Int?, payloadJSON: String, clientTimestamp: Date = .now, retryCount: Int = 0, stateRaw: String? = RemoteOutboxState.pending.rawValue, lastAttemptAt: Date? = nil, nextRetryAt: Date? = nil, lastErrorCode: String? = nil, acknowledgedAt: Date? = nil) {
        self.id = id; self.entityType = entityType; self.entityID = entityID; self.operation = operation
        self.baseVersion = baseVersion; self.payloadJSON = payloadJSON; self.clientTimestamp = clientTimestamp; self.retryCount = retryCount
        self.stateRaw = stateRaw; self.lastAttemptAt = lastAttemptAt; self.nextRetryAt = nextRetryAt
        self.lastErrorCode = lastErrorCode; self.acknowledgedAt = acknowledgedAt
    }
}

/// A future remote rollback is a server-authoritative operation, not a local
/// delete mutation. Keeping the request durable means a process termination
/// cannot turn a tap on “撤销导入” into an irreversible local divergence.
@Model final class PendingImportBatchRollbackModel {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var batchID: UUID
    var requestedByID: String
    var expectedBatchVersion: Int
    var stateRaw: String
    var retryCount: Int
    var lastAttemptAt: Date?
    var nextRetryAt: Date?
    var lastErrorCode: String?
    var acknowledgedAt: Date?

    init(id: UUID = UUID(), batchID: UUID, requestedByID: String, expectedBatchVersion: Int,
         state: RemoteRollbackRequestState = .pending, retryCount: Int = 0,
         lastAttemptAt: Date? = nil, nextRetryAt: Date? = nil, lastErrorCode: String? = nil,
         acknowledgedAt: Date? = nil) {
        self.id = id; self.batchID = batchID; self.requestedByID = requestedByID
        self.expectedBatchVersion = expectedBatchVersion; self.stateRaw = state.rawValue
        self.retryCount = retryCount; self.lastAttemptAt = lastAttemptAt
        self.nextRetryAt = nextRetryAt; self.lastErrorCode = lastErrorCode
        self.acknowledgedAt = acknowledgedAt
    }

    var state: RemoteRollbackRequestState { RemoteRollbackRequestState(rawValue: stateRaw) ?? .pending }
}
@Model final class SyncStateModel {
    @Attribute(.unique) var key: String
    var lastAppliedCursor: Int
    init(key: String = "primary", lastAppliedCursor: Int = 0) { self.key = key; self.lastAppliedCursor = lastAppliedCursor }
}
/// A dormant, transport-level version/tombstone ledger. The future
/// ChangeApplier updates the ordinary business models in the same transaction;
/// this ledger exists only to validate sequence continuity and diagnose sync.
@Model final class RemoteEntityRecordModel {
    @Attribute(.unique) var entityKey: String
    var entityType: String
    var entityID: UUID
    var serverVersion: Int
    var isTombstone: Bool
    var payloadJSON: String?
    var lastSequence: Int
    /// Retained verbatim from the remote wire format; no local timezone or
    /// decoder interpretation is needed for ordering, which uses sequence.
    var serverUpdatedAt: String?

    init(entityType: String, entityID: UUID, serverVersion: Int, isTombstone: Bool, payloadJSON: String?, lastSequence: Int, serverUpdatedAt: String? = nil) {
        self.entityType = entityType; self.entityID = entityID
        self.entityKey = RemoteEntityRecordModel.key(entityType: entityType, entityID: entityID)
        self.serverVersion = serverVersion; self.isTombstone = isTombstone
        self.payloadJSON = payloadJSON; self.lastSequence = lastSequence; self.serverUpdatedAt = serverUpdatedAt
    }

    static func key(entityType: String, entityID: UUID) -> String {
        "\(entityType)|\(entityID.uuidString.lowercased())"
    }
}

/// Conflicts are retained for a future explicit-resolution UI. They are never
/// auto-resolved or used to overwrite a local mutation.
@Model final class SyncConflictModel {
    @Attribute(.unique) var mutationID: UUID
    var entityType: String
    var entityID: UUID
    var localVersion: Int?
    var remoteVersion: Int
    var localPayloadJSON: String
    var remoteSnapshotJSON: String?
    var conflictTypeRaw: String
    var createdAt: Date

    init(mutationID: UUID, entityType: String, entityID: UUID, localVersion: Int?, remoteVersion: Int, localPayloadJSON: String, remoteSnapshotJSON: String?, conflictTypeRaw: String, createdAt: Date = .now) {
        self.mutationID = mutationID; self.entityType = entityType; self.entityID = entityID
        self.localVersion = localVersion; self.remoteVersion = remoteVersion
        self.localPayloadJSON = localPayloadJSON; self.remoteSnapshotJSON = remoteSnapshotJSON
        self.conflictTypeRaw = conflictTypeRaw; self.createdAt = createdAt
    }
}
@Model final class FamilyPlaceModel { @Attribute(.unique) var id: UUID; var name: String; var kindRaw: String; var latitude: Double; var longitude: Double; var radius: Double; var isEnabled: Bool?
    /// nil denotes legacy shared places. New records always belong to one of
    /// one member. Existing nil values remain shared legacy places.
    var memberID: String?
    init(id: UUID = UUID(), name: String, kind: PlaceKind, latitude: Double, longitude: Double, radius: Double, isEnabled: Bool? = true, memberID: String? = nil) { self.id = id; self.name = name; self.kindRaw = kind.rawValue; self.latitude = latitude; self.longitude = longitude; self.radius = radius; self.isEnabled = isEnabled; self.memberID = memberID }
    var kind: PlaceKind { PlaceKind(rawValue: kindRaw) ?? .custom }
}
