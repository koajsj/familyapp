import Foundation
import SwiftData

@Model final class MemberProfile {
    @Attribute(.unique) var memberID: String
    var nickname: String
    var colorKey: String
    var avatarSymbol: String?
    init(memberID: String, nickname: String, colorKey: String, avatarSymbol: String? = "person.crop.circle.fill") { self.memberID = memberID; self.nickname = nickname; self.colorKey = colorKey; self.avatarSymbol = avatarSymbol }
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
    init(id: UUID = UUID(), ownerID: String, semesterID: UUID, title: String, kind: ScheduleKind, weekday: Int, startMinutes: Int, endMinutes: Int, startWeek: Int, endWeek: Int, weekType: WeekType, major: String? = nil, grade: String? = nil, className: String? = nil, location: String? = nil, note: String? = nil, labName: String? = nil, advisor: String? = nil) {
        self.id = id; self.ownerID = ownerID; self.semesterID = semesterID; self.title = title; self.kindRaw = kind.rawValue; self.weekday = weekday; self.startMinutes = startMinutes; self.endMinutes = endMinutes; self.startWeek = startWeek; self.endWeek = endWeek; self.weekTypeRaw = weekType.rawValue; self.major = major; self.grade = grade; self.className = className; self.location = location; self.note = note; self.labName = labName; self.advisor = advisor
    }
    var kind: ScheduleKind { ScheduleKind(rawValue: kindRaw) ?? .course }
    var weekType: WeekType { WeekType(rawValue: weekTypeRaw) ?? .everyWeek }
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
    init(id: UUID = UUID(), title: String? = nil, content: String, creatorID: String, pinned: Bool = false, version: Int = 1, createdAt: Date = .now, updatedAt: Date = .now, updatedBy: String) { self.id = id; self.title = title; self.content = content; self.creatorID = creatorID; self.pinned = pinned; self.version = version; self.createdAt = createdAt; self.updatedAt = updatedAt; self.updatedBy = updatedBy }
}
@Model final class NoticeModel { @Attribute(.unique) var id: UUID; var title: String; var content: String; var publisherID: String; var pinned: Bool; var createdAt: Date; var updatedAt: Date; var isEdited: Bool
    init(id: UUID = UUID(), title: String, content: String, publisherID: String, pinned: Bool = false, createdAt: Date = .now, updatedAt: Date = .now, isEdited: Bool = false) { self.id = id; self.title = title; self.content = content; self.publisherID = publisherID; self.pinned = pinned; self.createdAt = createdAt; self.updatedAt = updatedAt; self.isEdited = isEdited }
}
@Model final class NoticeReadModel { @Attribute(.unique) var id: UUID; var noticeID: UUID; var memberID: String; var readAt: Date
    init(id: UUID = UUID(), noticeID: UUID, memberID: String, readAt: Date = .now) { self.id = id; self.noticeID = noticeID; self.memberID = memberID; self.readAt = readAt }
}
@Model final class ChatMessageModel { @Attribute(.unique) var id: UUID; var senderID: String; var body: String; var kindRaw: String; var sentAt: Date; var statusRaw: String; var mediaPath: String?; var replyToID: UUID?; var recalledAt: Date?; var isUnread: Bool
    init(id: UUID = UUID(), senderID: String, body: String = "", kind: MessageKind, sentAt: Date = .now, status: ReceiptStatus = .sent, mediaPath: String? = nil, replyToID: UUID? = nil, recalledAt: Date? = nil, isUnread: Bool = false) { self.id = id; self.senderID = senderID; self.body = body; self.kindRaw = kind.rawValue; self.sentAt = sentAt; self.statusRaw = status.rawValue; self.mediaPath = mediaPath; self.replyToID = replyToID; self.recalledAt = recalledAt; self.isUnread = isUnread }
    var kind: MessageKind { MessageKind(rawValue: kindRaw) ?? .text }; var status: ReceiptStatus { ReceiptStatus(rawValue: statusRaw) ?? .sent }
}
@Model final class LocationSnapshotModel { @Attribute(.unique) var id: UUID; var memberID: String; var latitude: Double; var longitude: Double; var timestamp: Date; var event: String?
    init(id: UUID = UUID(), memberID: String, latitude: Double, longitude: Double, timestamp: Date, event: String? = nil) { self.id = id; self.memberID = memberID; self.latitude = latitude; self.longitude = longitude; self.timestamp = timestamp; self.event = event }
}
@Model final class FamilyPlaceModel { @Attribute(.unique) var id: UUID; var name: String; var kindRaw: String; var latitude: Double; var longitude: Double; var radius: Double; var isEnabled: Bool?
    /// nil denotes legacy shared places. New records always belong to one of
    /// the three fixed Demo members.
    var memberID: String?
    init(id: UUID = UUID(), name: String, kind: PlaceKind, latitude: Double, longitude: Double, radius: Double, isEnabled: Bool? = true, memberID: String? = nil) { self.id = id; self.name = name; self.kindRaw = kind.rawValue; self.latitude = latitude; self.longitude = longitude; self.radius = radius; self.isEnabled = isEnabled; self.memberID = memberID }
    var kind: PlaceKind { PlaceKind(rawValue: kindRaw) ?? .custom }
}
