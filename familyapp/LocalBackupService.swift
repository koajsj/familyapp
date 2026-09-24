import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// A portable, versioned snapshot of local *business* records.  It deliberately
/// excludes the session, Keychain secrets, transient files, and chat media.
/// Keeping that boundary explicit prevents a restore from resurrecting stale
/// credentials or media paths that no longer point at a local file.
nonisolated struct FamilyBackupArchive: Codable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let exportedAt: Date
    let payload: FamilyBackupPayload
}

struct LocalBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var archive: FamilyBackupArchive

    init(archive: FamilyBackupArchive) { self.archive = archive }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw LocalBackupError.unreadableFile }
        archive = try JSONDecoder().decode(FamilyBackupArchive.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(archive))
    }
}

enum LocalBackupError: LocalizedError {
    case unreadableFile, unsupportedVersion, invalidArchive(String), remoteStatePresent, localChangesPending, restoreFailed

    var errorDescription: String? {
        switch self {
        case .unreadableFile: return "无法读取备份文件。"
        case .unsupportedVersion: return "此备份版本不受当前 App 支持。"
        case let .invalidArchive(reason): return "备份数据无效：\(reason)"
        case .remoteStatePresent: return "当前设备已有远端同步状态，不能用本地备份覆盖。请先处理远端会话和待同步数据。"
        case .localChangesPending: return "本地仍有未保存的修改，请稍后再恢复备份。"
        case .restoreFailed: return "恢复失败；原有本地数据未被提交。"
        }
    }
}

nonisolated struct BackupPreview: Identifiable, Sendable {
    let id = UUID()
    let exportedAt: Date
    let schemaVersion: Int
    let recordCount: Int
    let replacementCount: Int
    let summaries: [String]
}

@MainActor final class LocalBackupService {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func exportArchive() throws -> FamilyBackupArchive {
        FamilyBackupArchive(
            schemaVersion: FamilyBackupArchive.currentSchemaVersion,
            exportedAt: .now,
            payload: try makePayload()
        )
    }

    func preview(_ archive: FamilyBackupArchive) throws -> BackupPreview {
        try validate(archive)
        try validateExistingChatMembers(archive.payload)
        let payload = archive.payload
        let incoming = payload.recordCount
        let existing = try currentCoreRecordCount()
        return BackupPreview(
            exportedAt: archive.exportedAt,
            schemaVersion: archive.schemaVersion,
            recordCount: incoming,
            replacementCount: existing,
            summaries: payload.summaries
        )
    }

    /// All decoding and relationship validation happens before any managed
    /// object changes.  `save()` is the sole commit; a failed commit rolls the
    /// context back, so malformed or conflicting archives do not pollute data.
    func restore(_ archive: FamilyBackupArchive) throws {
        try validate(archive)
        try validateExistingChatMembers(archive.payload)
        guard !context.hasChanges else { throw LocalBackupError.localChangesPending }
        // A business-only archive deliberately has no cursor, mirror or
        // outbox. Replacing remote-backed rows while retaining live remote
        // credentials would make the next bootstrap/pull ambiguous and could
        // discard unacknowledged edits. Keep restore local-only and fail closed.
        guard try fetch(SyncStateModel.self).isEmpty,
              try fetch(RemoteEntityRecordModel.self).isEmpty,
              try fetch(PendingMutationModel.self).isEmpty,
              try fetch(SyncConflictModel.self).isEmpty,
              try fetch(PendingImportBatchRollbackModel.self).isEmpty else {
            throw LocalBackupError.remoteStatePresent
        }
        do {
            try deleteRestorableRecords()
            insert(archive.payload)
            try context.save()
        } catch {
            context.rollback()
            throw LocalBackupError.restoreFailed
        }
    }

    private func makePayload() throws -> FamilyBackupPayload {
        FamilyBackupPayload(
            profiles: try fetch(MemberProfile.self).map(MemberProfileBackup.init),
            semesters: try fetch(SemesterModel.self).map(SemesterBackup.init),
            schedules: try fetch(ScheduleEntryModel.self).map(ScheduleBackup.init),
            scheduleExceptions: try fetch(ScheduleExceptionModel.self).map(ScheduleExceptionBackup.init),
            importBatches: try fetch(ScheduleImportBatchModel.self).map(ImportBatchBackup.init),
            calendarOverrides: try fetch(CalendarOverrideModel.self).map(CalendarOverrideBackup.init),
            agendas: try fetch(AgendaItemModel.self).map(AgendaBackup.init),
            agendaExceptions: try fetch(AgendaExceptionModel.self).map(AgendaExceptionBackup.init),
            memos: try fetch(MemoModel.self).map(MemoBackup.init),
            notices: try fetch(NoticeModel.self).map(NoticeBackup.init),
            noticeReads: try fetch(NoticeReadModel.self).map(NoticeReadBackup.init),
            locations: try fetch(LocationSnapshotModel.self).map(LocationBackup.init),
            statuses: try fetch(MemberStatusModel.self).map(MemberStatusBackup.init),
            places: try fetch(FamilyPlaceModel.self).map(FamilyPlaceBackup.init)
        )
    }

    private func validate(_ archive: FamilyBackupArchive) throws {
        guard archive.schemaVersion == FamilyBackupArchive.currentSchemaVersion else { throw LocalBackupError.unsupportedVersion }
        let value = archive.payload
        let initialMemberIDs = Set(MemberID.allCases.map(\.rawValue))
        guard initialMemberIDs.isSubset(of: Set(value.profiles.map(\.memberID))),
              unique(value.profiles.map(\.memberID)),
              unique(value.semesters.map(\.id)), unique(value.schedules.map(\.id)),
              unique(value.scheduleExceptions.map(\.id)), unique(value.importBatches.map(\.id)),
              unique(value.calendarOverrides.map(\.id)), unique(value.agendas.map(\.id)),
              unique(value.agendaExceptions.map(\.id)), unique(value.memos.map(\.id)),
              unique(value.notices.map(\.id)), unique(value.noticeReads.map(\.id)),
              unique(value.locations.map(\.id)), unique(value.statuses.map(\.memberID)),
              unique(value.places.map(\.id)) else { throw LocalBackupError.invalidArchive("存在重复 ID 或成员档案不完整") }
        let knownMembers = Set(value.profiles.map(\.memberID))
        guard value.agendas.allSatisfy({ $0.purgedAt == nil || $0.deletedAt != nil }),
              value.memos.allSatisfy({ $0.purgedAt == nil || $0.deletedAt != nil }),
              value.notices.allSatisfy({ $0.purgedAt == nil || $0.deletedAt != nil }) else {
            throw LocalBackupError.invalidArchive("回收站删除状态不完整")
        }

        let semesterIDs = Set(value.semesters.map(\.id))
        guard value.semesters.filter(\.isCurrent).count == 1 else {
            throw LocalBackupError.invalidArchive("必须恰好有一个当前学期")
        }
        for semester in value.semesters {
            guard semester.totalWeeks > 0,
                  (semester.week1EndDate == nil || semester.week1EndDate! >= semester.week1StartDate) else {
                throw LocalBackupError.invalidArchive("学期周次或第一周日期范围无效")
            }
        }
        let scheduleIDs = Set(value.schedules.map(\.id))
        for schedule in value.schedules {
            guard semesterIDs.contains(schedule.semesterID), knownMembers.contains(schedule.ownerID),
                  ScheduleKind(rawValue: schedule.kindRaw) != nil, WeekType(rawValue: schedule.weekTypeRaw) != nil,
                  !schedule.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...7).contains(schedule.weekday), (0..<1_440).contains(schedule.startMinutes),
                  (1...1_440).contains(schedule.endMinutes), schedule.startMinutes < schedule.endMinutes,
                  schedule.startWeek > 0, schedule.startWeek <= schedule.endWeek,
                  schedule.endWeek <= (value.semesters.first { $0.id == schedule.semesterID }?.totalWeeks ?? 0) else {
                throw LocalBackupError.invalidArchive("课程字段或学期关联无效")
            }
        }
        guard value.scheduleExceptions.allSatisfy({
                  scheduleIDs.contains($0.scheduleID) &&
                  ExceptionKind(rawValue: $0.kindRaw) != nil &&
                  ExceptionScope(rawValue: $0.scopeRaw) != nil
              }),
              value.calendarOverrides.allSatisfy({
                  semesterIDs.contains($0.semesterID) &&
                  CalendarOverrideKind(rawValue: $0.kindRaw) != nil &&
                  ($0.kindRaw != CalendarOverrideKind.mappedWeekday.rawValue ||
                   ($0.mappedWeekday.map { (1...7).contains($0) } ?? false))
              }) else {
            throw LocalBackupError.invalidArchive("课程或校历例外缺少原始记录")
        }
        let agendaIDs = Set(value.agendas.map(\.id))
        guard value.profiles.allSatisfy({ profile in
            guard !profile.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let remoteID = profile.remoteMemberID ?? MemberIdentity.remoteUUID(for: profile.memberID) else { return false }
            if let initial = MemberID(rawValue: profile.memberID) {
                return remoteID == initial.remoteUUID && (profile.isInitialMember ?? true)
            }
            return UUID(uuidString: profile.memberID) == remoteID && profile.isInitialMember != true
        }) else { throw LocalBackupError.invalidArchive("成员档案缺少稳定身份或初始成员保护标记") }
        let noticeReadPairs = value.noticeReads.map { "\($0.noticeID.uuidString)|\($0.memberID)" }
        guard unique(noticeReadPairs),
              value.agendas.allSatisfy({
                  knownMembers.contains($0.creatorID) &&
                  AgendaKind(rawValue: $0.kindRaw) != nil &&
                  AgendaRecurrence(rawValue: $0.recurrenceRaw) != nil &&
                  Set($0.participantIDs).count == $0.participantIDs.count &&
                  Set($0.participantIDs).isSubset(of: knownMembers) &&
                  ($0.purgedAt != nil || !$0.participantIDs.isEmpty)
              }),
              value.agendaExceptions.allSatisfy({
                  agendaIDs.contains($0.agendaID) &&
                  ExceptionKind(rawValue: $0.kindRaw) != nil &&
                  ExceptionScope(rawValue: $0.scopeRaw) != nil
              }),
              value.memos.allSatisfy({ knownMembers.contains($0.creatorID) && knownMembers.contains($0.updatedBy) && $0.version > 0 }),
              value.notices.allSatisfy({ knownMembers.contains($0.publisherID) }),
              value.noticeReads.allSatisfy({ Set(value.notices.map(\.id)).contains($0.noticeID) && knownMembers.contains($0.memberID) }),
              value.importBatches.allSatisfy({ validImportBatch($0, schedules: value.schedules, semesterIDs: semesterIDs, knownMembers: knownMembers) }),
              value.locations.allSatisfy({
                  knownMembers.contains($0.memberID) &&
                  (-90...90).contains($0.latitude) &&
                  (-180...180).contains($0.longitude) &&
                  ($0.horizontalAccuracy.map { $0 >= 0 } ?? true) &&
                  ($0.sourceRaw.map { LocationSnapshotSource(rawValue: $0) != nil } ?? true)
              }),
              value.statuses.allSatisfy({ knownMembers.contains($0.memberID) && SafetyStatus(rawValue: $0.statusRaw) != nil }),
              value.places.allSatisfy({
                  PlaceKind(rawValue: $0.kindRaw) != nil &&
                  $0.memberID.map { knownMembers.contains($0) } ?? true &&
                  (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) &&
                  [100, 200, 500, 1000].contains(Int($0.radius))
              }) else {
            throw LocalBackupError.invalidArchive("日程、公告或成员地点关联无效")
        }
        for memberID in knownMembers {
            for kind in [PlaceKind.home, .school] {
                guard value.places.filter({ $0.memberID == memberID && $0.kindRaw == kind.rawValue && ($0.isEnabled ?? true) }).count <= 1 else {
                    throw LocalBackupError.invalidArchive("成员地点违反家或学校只能启用一个的规则")
                }
            }
        }
    }

    private func unique<T: Hashable>(_ values: [T]) -> Bool { Set(values).count == values.count }

    private func validateExistingChatMembers(_ payload: FamilyBackupPayload) throws {
        // Chat is intentionally not part of business backups and survives a
        // restore. Refuse an archive that would remove any existing sender's
        // historical profile; merging profiles is a separate product choice.
        let restoredIDs = Set(payload.profiles.map(\.memberID))
        let senderIDs = Set(try fetch(ChatMessageModel.self).map(\.senderID))
        let readerIDs = Set(try fetch(MessageReceiptModel.self).map(\.memberID))
        guard senderIDs.union(readerIDs).isSubset(of: restoredIDs) else {
            throw LocalBackupError.invalidArchive("现有聊天包含备份中缺失的历史成员，无法安全覆盖成员档案")
        }
    }

    private func validImportBatch(_ batch: ImportBatchBackup, schedules: [ScheduleBackup], semesterIDs: Set<UUID>, knownMembers: Set<String>) -> Bool {
        guard semesterIDs.contains(batch.semesterID), knownMembers.contains(batch.ownerID),
              ScheduleImportSource(rawValue: batch.sourceRaw) != nil,
              unique(batch.importedEntryIDs),
              batch.importedEntryIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else { return false }
        let scheduleIDs = Set(schedules.map(\.id))
        guard batch.importedEntryIDs.allSatisfy({ UUID(uuidString: $0).map(scheduleIDs.contains) ?? false }) else { return false }
        let decoder = JSONDecoder()
        if let snapshots = batch.updatedEntrySnapshots {
            guard let data = Data(base64Encoded: snapshots),
                  let decoded = try? decoder.decode([ScheduleImportEntrySnapshot].self, from: data),
                  unique(decoded.map(\.id)),
                  decoded.allSatisfy({ scheduleIDs.contains($0.id) }) else { return false }
        }
        guard let encoded = batch.undoRecords else {
            // Historical batches can be restored, but cannot be one-tap undone.
            return true
        }
        guard let data = Data(base64Encoded: encoded),
              let records = try? decoder.decode([ScheduleImportUndoRecord].self, from: data),
              !records.isEmpty, unique(records.map(\.entryID)) else { return false }
        return records.allSatisfy { record in
            scheduleIDs.contains(record.entryID) &&
            !record.expectedPostImportFingerprint.isEmpty &&
            (record.previous == nil || (record.previous?.id == record.entryID && record.previous?.ownerID == batch.ownerID))
        }
    }
    private func fetch<T: PersistentModel>(_ type: T.Type) throws -> [T] { try context.fetch(FetchDescriptor<T>()) }

    private func currentCoreRecordCount() throws -> Int {
        try fetch(MemberProfile.self).count + fetch(SemesterModel.self).count + fetch(ScheduleEntryModel.self).count +
        fetch(ScheduleExceptionModel.self).count + fetch(ScheduleImportBatchModel.self).count + fetch(CalendarOverrideModel.self).count +
        fetch(AgendaItemModel.self).count + fetch(AgendaExceptionModel.self).count + fetch(MemoModel.self).count +
        fetch(NoticeModel.self).count + fetch(NoticeReadModel.self).count + fetch(LocationSnapshotModel.self).count +
        fetch(MemberStatusModel.self).count + fetch(FamilyPlaceModel.self).count
    }

    private func deleteRestorableRecords() throws {
        // Remote transport state and conflicts are intentionally excluded from
        // local backups. A restore must not later push stale mutations or reuse
        // a cursor that belongs to the pre-restore data set.
        for item in try fetch(PendingMutationModel.self) { context.delete(item) }
        for item in try fetch(SyncStateModel.self) { context.delete(item) }
        for item in try fetch(RemoteEntityRecordModel.self) { context.delete(item) }
        for item in try fetch(SyncConflictModel.self) { context.delete(item) }
        for item in try fetch(PendingImportBatchRollbackModel.self) { context.delete(item) }
        for item in try fetch(MemberProfile.self) { context.delete(item) }
        for item in try fetch(SemesterModel.self) { context.delete(item) }
        for item in try fetch(ScheduleEntryModel.self) { context.delete(item) }
        for item in try fetch(ScheduleExceptionModel.self) { context.delete(item) }
        for item in try fetch(ScheduleImportBatchModel.self) { context.delete(item) }
        for item in try fetch(CalendarOverrideModel.self) { context.delete(item) }
        for item in try fetch(AgendaItemModel.self) { context.delete(item) }
        for item in try fetch(AgendaExceptionModel.self) { context.delete(item) }
        for item in try fetch(MemoModel.self) { context.delete(item) }
        for item in try fetch(NoticeModel.self) { context.delete(item) }
        for item in try fetch(NoticeReadModel.self) { context.delete(item) }
        for item in try fetch(LocationSnapshotModel.self) { context.delete(item) }
        for item in try fetch(MemberStatusModel.self) { context.delete(item) }
        for item in try fetch(FamilyPlaceModel.self) { context.delete(item) }
    }

    private func insert(_ payload: FamilyBackupPayload) {
        payload.profiles.forEach { context.insert($0.model) }
        payload.semesters.forEach { context.insert($0.model) }
        payload.schedules.forEach { context.insert($0.model) }
        payload.scheduleExceptions.forEach { context.insert($0.model) }
        payload.importBatches.forEach { context.insert($0.model) }
        payload.calendarOverrides.forEach { context.insert($0.model) }
        payload.agendas.forEach { context.insert($0.model) }
        payload.agendaExceptions.forEach { context.insert($0.model) }
        payload.memos.forEach { context.insert($0.model) }
        payload.notices.forEach { context.insert($0.model) }
        payload.noticeReads.forEach { context.insert($0.model) }
        payload.locations.forEach { context.insert($0.model) }
        payload.statuses.forEach { context.insert($0.model) }
        payload.places.forEach { context.insert($0.model) }
    }
}

nonisolated struct FamilyBackupPayload: Codable, Sendable {
    let profiles: [MemberProfileBackup]
    let semesters: [SemesterBackup]
    let schedules: [ScheduleBackup]
    let scheduleExceptions: [ScheduleExceptionBackup]
    let importBatches: [ImportBatchBackup]
    let calendarOverrides: [CalendarOverrideBackup]
    let agendas: [AgendaBackup]
    let agendaExceptions: [AgendaExceptionBackup]
    let memos: [MemoBackup]
    let notices: [NoticeBackup]
    let noticeReads: [NoticeReadBackup]
    let locations: [LocationBackup]
    let statuses: [MemberStatusBackup]
    let places: [FamilyPlaceBackup]

    var recordCount: Int { profiles.count + semesters.count + schedules.count + scheduleExceptions.count + importBatches.count + calendarOverrides.count + agendas.count + agendaExceptions.count + memos.count + notices.count + noticeReads.count + locations.count + statuses.count + places.count }
    var summaries: [String] { ["成员档案 \(profiles.count) 条", "学期与课表 \(semesters.count + schedules.count) 条", "日程与例外 \(agendas.count + agendaExceptions.count) 条", "备忘录与公告 \(memos.count + notices.count) 条", "位置与地点 \(locations.count + statuses.count + places.count) 条"] }
}

nonisolated struct MemberProfileBackup: Codable, Sendable { let memberID, nickname, colorKey: String; let avatarSymbol: String?; let remoteMemberID: UUID?; let isInitialMember: Bool?; let isActive: Bool?; let removedAt: Date?; @MainActor init(_ value: MemberProfile) { memberID = value.memberID; nickname = value.nickname; colorKey = value.colorKey; avatarSymbol = value.avatarSymbol; remoteMemberID = value.remoteMemberID; isInitialMember = value.isInitialMember; isActive = value.isActive; removedAt = value.removedAt }; @MainActor var model: MemberProfile { MemberProfile(memberID: memberID, nickname: nickname, colorKey: colorKey, avatarSymbol: avatarSymbol, remoteMemberID: remoteMemberID, isInitialMember: isInitialMember, isActive: isActive, removedAt: removedAt) } }
nonisolated struct SemesterBackup: Codable, Sendable { let id: UUID; let name: String; let week1StartDate: Date; let week1EndDate: Date?; let totalWeeks: Int; let isCurrent: Bool; @MainActor init(_ value: SemesterModel) { id = value.id; name = value.name; week1StartDate = value.week1StartDate; week1EndDate = value.week1EndDate; totalWeeks = value.totalWeeks; isCurrent = value.isCurrent }; @MainActor var model: SemesterModel { SemesterModel(id: id, name: name, week1StartDate: week1StartDate, week1EndDate: week1EndDate, totalWeeks: totalWeeks, isCurrent: isCurrent) } }
nonisolated struct ScheduleBackup: Codable, Sendable { let id, semesterID: UUID; let ownerID, title, kindRaw, weekTypeRaw: String; let weekday, startMinutes, endMinutes, startWeek, endWeek: Int; let major, grade, className, location, note, labName, advisor: String?; let importBatchID: UUID?; @MainActor init(_ value: ScheduleEntryModel) { id = value.id; semesterID = value.semesterID; ownerID = value.ownerID; title = value.title; kindRaw = value.kindRaw; weekTypeRaw = value.weekTypeRaw; weekday = value.weekday; startMinutes = value.startMinutes; endMinutes = value.endMinutes; startWeek = value.startWeek; endWeek = value.endWeek; major = value.major; grade = value.grade; className = value.className; location = value.location; note = value.note; labName = value.labName; advisor = value.advisor; importBatchID = value.importBatchID }; @MainActor var model: ScheduleEntryModel { let value = ScheduleEntryModel(id: id, ownerID: ownerID, semesterID: semesterID, title: title, kind: ScheduleKind(rawValue: kindRaw) ?? .course, weekday: weekday, startMinutes: startMinutes, endMinutes: endMinutes, startWeek: startWeek, endWeek: endWeek, weekType: WeekType(rawValue: weekTypeRaw) ?? .everyWeek, major: major, grade: grade, className: className, location: location, note: note, labName: labName, advisor: advisor); value.importBatchID = importBatchID; return value } }
nonisolated struct ScheduleExceptionBackup: Codable, Sendable { let id, scheduleID: UUID; let kindRaw, scopeRaw: String; let occurrenceDate: Date; let replacementDate: Date?; let replacementStartMinutes, replacementEndMinutes, replacementWeekday: Int?; let note: String?; @MainActor init(_ value: ScheduleExceptionModel) { id = value.id; scheduleID = value.scheduleID; kindRaw = value.kindRaw; scopeRaw = value.scopeRaw; occurrenceDate = value.occurrenceDate; replacementDate = value.replacementDate; replacementStartMinutes = value.replacementStartMinutes; replacementEndMinutes = value.replacementEndMinutes; replacementWeekday = value.replacementWeekday; note = value.note }; @MainActor var model: ScheduleExceptionModel { ScheduleExceptionModel(id: id, scheduleID: scheduleID, kind: ExceptionKind(rawValue: kindRaw) ?? .modified, scope: ExceptionScope(rawValue: scopeRaw) ?? .thisOccurrence, occurrenceDate: occurrenceDate, replacementDate: replacementDate, replacementStartMinutes: replacementStartMinutes, replacementEndMinutes: replacementEndMinutes, replacementWeekday: replacementWeekday, note: note) } }
nonisolated struct ImportBatchBackup: Codable, Sendable { let id, semesterID: UUID; let ownerID, sourceRaw: String; let createdAt: Date; let importedEntryIDs: [String]; let updatedEntrySnapshots, sourceFileName, sourceFileType, undoRecords: String?; @MainActor init(_ value: ScheduleImportBatchModel) { id = value.id; semesterID = value.semesterID; ownerID = value.ownerID; sourceRaw = value.sourceRaw; createdAt = value.createdAt; importedEntryIDs = value.importedEntryIDs; updatedEntrySnapshots = value.updatedEntrySnapshots; sourceFileName = value.sourceFileName; sourceFileType = value.sourceFileType; undoRecords = value.undoRecords }; @MainActor var model: ScheduleImportBatchModel { ScheduleImportBatchModel(id: id, semesterID: semesterID, ownerID: ownerID, source: sourceRaw, createdAt: createdAt, importedEntryIDs: importedEntryIDs, updatedEntrySnapshots: updatedEntrySnapshots, sourceFileName: sourceFileName, sourceFileType: sourceFileType, undoRecords: undoRecords) } }
nonisolated struct CalendarOverrideBackup: Codable, Sendable { let id, semesterID: UUID; let date: Date; let kindRaw: String; let mappedWeekday: Int?; let note: String?; @MainActor init(_ value: CalendarOverrideModel) { id = value.id; semesterID = value.semesterID; date = value.date; kindRaw = value.kindRaw; mappedWeekday = value.mappedWeekday; note = value.note }; @MainActor var model: CalendarOverrideModel { CalendarOverrideModel(id: id, semesterID: semesterID, date: date, kind: CalendarOverrideKind(rawValue: kindRaw) ?? .normal, mappedWeekday: mappedWeekday, note: note) } }
nonisolated struct AgendaBackup: Codable, Sendable { let id: UUID; let creatorID, title, kindRaw, recurrenceRaw: String; let start, end, dueAt: Date?; let location, note: String?; let participantIDs: [String]; let recurrenceEnd: Date?; let dishes, ingredients, seasonings: String?; let peopleCount: Int?; let estimatedArrival, desiredMealTime: Date?; let preparationRaw, completionRaw: String?; let foodReadByIDs, foodReadAtRecords: [String]?; let deletedAt, purgedAt: Date?; @MainActor init(_ value: AgendaItemModel) { id = value.id; creatorID = value.creatorID; title = value.title; kindRaw = value.kindRaw; recurrenceRaw = value.recurrenceRaw; start = value.start; end = value.end; dueAt = value.dueAt; location = value.location; note = value.note; participantIDs = value.participantIDs; recurrenceEnd = value.recurrenceEnd; dishes = value.dishes; ingredients = value.ingredients; seasonings = value.seasonings; peopleCount = value.peopleCount; estimatedArrival = value.estimatedArrival; desiredMealTime = value.desiredMealTime; preparationRaw = value.preparationRaw; completionRaw = value.completionRaw; foodReadByIDs = value.foodReadByIDs; foodReadAtRecords = value.foodReadAtRecords; deletedAt = value.deletedAt; purgedAt = value.purgedAt }; @MainActor var model: AgendaItemModel { let value = AgendaItemModel(id: id, creatorID: creatorID, title: title, kind: AgendaKind(rawValue: kindRaw) ?? .normal, start: start, end: end, dueAt: dueAt, location: location, note: note, participantIDs: participantIDs, recurrence: AgendaRecurrence(rawValue: recurrenceRaw) ?? .none, recurrenceEnd: recurrenceEnd, dishes: dishes, ingredients: ingredients, seasonings: seasonings, peopleCount: peopleCount, estimatedArrival: estimatedArrival, desiredMealTime: desiredMealTime, preparation: preparationRaw.flatMap(PreparationState.init(rawValue:)), completion: completionRaw.flatMap(CompletionState.init(rawValue:)), foodReadByIDs: foodReadByIDs ?? [], foodReadAtRecords: foodReadAtRecords); value.deletedAt = deletedAt; value.purgedAt = purgedAt; return value } }
nonisolated struct AgendaExceptionBackup: Codable, Sendable { let id, agendaID: UUID; let kindRaw, scopeRaw: String; let occurrenceDate: Date; let replacementDate, replacementStart, replacementEnd: Date?; let note: String?; @MainActor init(_ value: AgendaExceptionModel) { id = value.id; agendaID = value.agendaID; kindRaw = value.kindRaw; scopeRaw = value.scopeRaw; occurrenceDate = value.occurrenceDate; replacementDate = value.replacementDate; replacementStart = value.replacementStart; replacementEnd = value.replacementEnd; note = value.note }; @MainActor var model: AgendaExceptionModel { AgendaExceptionModel(id: id, agendaID: agendaID, kind: ExceptionKind(rawValue: kindRaw) ?? .modified, scope: ExceptionScope(rawValue: scopeRaw) ?? .thisOccurrence, occurrenceDate: occurrenceDate, replacementDate: replacementDate, replacementStart: replacementStart, replacementEnd: replacementEnd, note: note) } }
nonisolated struct MemoBackup: Codable, Sendable { let id: UUID; let title: String?; let content, creatorID: String; let pinned: Bool; let version: Int; let createdAt, updatedAt: Date; let updatedBy: String; let deletedAt, purgedAt: Date?; @MainActor init(_ value: MemoModel) { id = value.id; title = value.title; content = value.content; creatorID = value.creatorID; pinned = value.pinned; version = value.version; createdAt = value.createdAt; updatedAt = value.updatedAt; updatedBy = value.updatedBy; deletedAt = value.deletedAt; purgedAt = value.purgedAt }; @MainActor var model: MemoModel { let value = MemoModel(id: id, title: title, content: content, creatorID: creatorID, pinned: pinned, version: version, createdAt: createdAt, updatedAt: updatedAt, updatedBy: updatedBy); value.deletedAt = deletedAt; value.purgedAt = purgedAt; return value } }
nonisolated struct NoticeBackup: Codable, Sendable { let id: UUID; let title, content, publisherID: String; let pinned: Bool; let createdAt, updatedAt: Date; let isEdited: Bool; let deletedAt, purgedAt: Date?; @MainActor init(_ value: NoticeModel) { id = value.id; title = value.title; content = value.content; publisherID = value.publisherID; pinned = value.pinned; createdAt = value.createdAt; updatedAt = value.updatedAt; isEdited = value.isEdited; deletedAt = value.deletedAt; purgedAt = value.purgedAt }; @MainActor var model: NoticeModel { let value = NoticeModel(id: id, title: title, content: content, publisherID: publisherID, pinned: pinned, createdAt: createdAt, updatedAt: updatedAt, isEdited: isEdited); value.deletedAt = deletedAt; value.purgedAt = purgedAt; return value } }
nonisolated struct NoticeReadBackup: Codable, Sendable { let id, noticeID: UUID; let memberID: String; let readAt: Date; @MainActor init(_ value: NoticeReadModel) { id = value.id; noticeID = value.noticeID; memberID = value.memberID; readAt = value.readAt }; @MainActor var model: NoticeReadModel { NoticeReadModel(id: id, noticeID: noticeID, memberID: memberID, readAt: readAt) } }
nonisolated struct LocationBackup: Codable, Sendable {
    let id: UUID
    let memberID: String
    let latitude, longitude: Double
    let timestamp: Date
    let event: String?
    /// Optional to decode archives created before automatic location sharing.
    let horizontalAccuracy: Double?
    let sourceRaw: String?

    @MainActor init(_ value: LocationSnapshotModel) {
        id = value.id; memberID = value.memberID; latitude = value.latitude; longitude = value.longitude
        timestamp = value.timestamp; event = value.event; horizontalAccuracy = value.horizontalAccuracy; sourceRaw = value.sourceRaw
    }

    @MainActor var model: LocationSnapshotModel {
        LocationSnapshotModel(id: id, memberID: memberID, latitude: latitude, longitude: longitude,
                              timestamp: timestamp, event: event, horizontalAccuracy: horizontalAccuracy,
                              source: sourceRaw.flatMap(LocationSnapshotSource.init(rawValue:)))
    }
}
nonisolated struct MemberStatusBackup: Codable, Sendable { let memberID, statusRaw: String; let estimatedArrival: Date?; let updatedAt: Date; @MainActor init(_ value: MemberStatusModel) { memberID = value.memberID; statusRaw = value.statusRaw; estimatedArrival = value.estimatedArrival; updatedAt = value.updatedAt }; @MainActor var model: MemberStatusModel { MemberStatusModel(memberID: memberID, status: SafetyStatus(rawValue: statusRaw) ?? .allGood, estimatedArrival: estimatedArrival, updatedAt: updatedAt) } }
nonisolated struct FamilyPlaceBackup: Codable, Sendable { let id: UUID; let name, kindRaw: String; let latitude, longitude, radius: Double; let isEnabled: Bool?; let memberID: String?; @MainActor init(_ value: FamilyPlaceModel) { id = value.id; name = value.name; kindRaw = value.kindRaw; latitude = value.latitude; longitude = value.longitude; radius = value.radius; isEnabled = value.isEnabled; memberID = value.memberID }; @MainActor var model: FamilyPlaceModel { FamilyPlaceModel(id: id, name: name, kind: PlaceKind(rawValue: kindRaw) ?? .custom, latitude: latitude, longitude: longitude, radius: radius, isEnabled: isEnabled, memberID: memberID) } }
