import Foundation
import PDFKit
import Vision
import ImageIO

enum ScheduleImportSource: String, Codable, CaseIterable, Sendable {
    case photoLibrary, files, camera

    var localizedName: String {
        switch self {
        case .photoLibrary: "相册图片"
        case .files: "文件"
        case .camera: "相机拍摄"
        }
    }
}

enum ScheduleImportConflictPolicy: String, CaseIterable, Identifiable, Sendable {
    case skip, keep, update

    var id: String { rawValue }
    var title: String {
        switch self {
        case .skip: "跳过重复"
        case .keep: "保留为新课程"
        case .update: "更新现有课程"
        }
    }
}

struct ImportedScheduleDraft: Identifiable, Sendable {
    let id = UUID()
    var title: String
    var weekday: Int
    var startMinutes: Int
    var endMinutes: Int
    var startWeek: Int
    var endWeek: Int
    var weekType: WeekType
    var location: String?
    var major: String?
    var grade: String?
    var className: String?
    var note: String?
    var needsConfirmation: [String]
    var confidenceByField: [String: Double]

    var isReadyToImport: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (1...7).contains(weekday) &&
        (0..<1_440).contains(startMinutes) &&
        (1...1_440).contains(endMinutes) &&
        startMinutes < endMinutes && startWeek > 0 && startWeek <= endWeek &&
        needsConfirmation.isEmpty
    }
}

struct ScheduleImportExtraction: Sendable {
    let text: String
    let drafts: [ImportedScheduleDraft]
}

/// Captures only fields that this import can overwrite so one-tap undo never
/// guesses at the prior SwiftData value of an existing course.
struct ScheduleImportEntrySnapshot: Codable {
    let id: UUID
    let ownerID: String
    /// Optional solely to decode snapshots written before this field existed.
    /// New snapshots include it in the guarded undo fingerprint.
    let semesterID: UUID?
    let title: String
    let weekday: Int
    let startMinutes: Int
    let endMinutes: Int
    let startWeek: Int
    let endWeek: Int
    let weekTypeRaw: String
    let major: String?
    let grade: String?
    let className: String?
    let location: String?
    let note: String?
    let kindRaw: String
    let labName: String?
    let advisor: String?
    let importBatchID: UUID?

    private enum CodingKeys: String, CodingKey {
        case id, ownerID, semesterID, title, weekday, startMinutes, endMinutes, startWeek, endWeek, weekTypeRaw, major, grade, className, location, note, kindRaw, labName, advisor, importBatchID
    }

    init(entry: ScheduleEntryModel) {
        id = entry.id; ownerID = entry.ownerID; semesterID = entry.semesterID; title = entry.title
        weekday = entry.weekday; startMinutes = entry.startMinutes; endMinutes = entry.endMinutes
        startWeek = entry.startWeek; endWeek = entry.endWeek; weekTypeRaw = entry.weekTypeRaw
        major = entry.major; grade = entry.grade; className = entry.className
        location = entry.location; note = entry.note
        kindRaw = entry.kindRaw; labName = entry.labName; advisor = entry.advisor
        importBatchID = entry.importBatchID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        ownerID = try values.decode(String.self, forKey: .ownerID)
        semesterID = try values.decodeIfPresent(UUID.self, forKey: .semesterID)
        title = try values.decode(String.self, forKey: .title)
        weekday = try values.decode(Int.self, forKey: .weekday)
        startMinutes = try values.decode(Int.self, forKey: .startMinutes)
        endMinutes = try values.decode(Int.self, forKey: .endMinutes)
        startWeek = try values.decode(Int.self, forKey: .startWeek)
        endWeek = try values.decode(Int.self, forKey: .endWeek)
        weekTypeRaw = try values.decode(String.self, forKey: .weekTypeRaw)
        major = try values.decodeIfPresent(String.self, forKey: .major)
        grade = try values.decodeIfPresent(String.self, forKey: .grade)
        className = try values.decodeIfPresent(String.self, forKey: .className)
        location = try values.decodeIfPresent(String.self, forKey: .location)
        note = try values.decodeIfPresent(String.self, forKey: .note)
        kindRaw = try values.decodeIfPresent(String.self, forKey: .kindRaw) ?? ScheduleKind.course.rawValue
        labName = try values.decodeIfPresent(String.self, forKey: .labName)
        advisor = try values.decodeIfPresent(String.self, forKey: .advisor)
        importBatchID = try values.decodeIfPresent(UUID.self, forKey: .importBatchID)
    }

    func apply(to entry: ScheduleEntryModel) {
        entry.semesterID = semesterID ?? entry.semesterID
        entry.title = title; entry.weekday = weekday
        entry.startMinutes = startMinutes; entry.endMinutes = endMinutes
        entry.startWeek = startWeek; entry.endWeek = endWeek; entry.weekTypeRaw = weekTypeRaw
        entry.major = major; entry.grade = grade; entry.className = className
        entry.location = location; entry.note = note; entry.kindRaw = kindRaw
        entry.labName = labName; entry.advisor = advisor; entry.importBatchID = importBatchID
    }

    func fingerprint() -> String {
        // A canonical encoding makes the optimistic-concurrency token stable
        // across encoder implementations and process launches.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return data.base64EncodedString()
    }
}

struct ScheduleImportUndoRecord: Codable {
    let entryID: UUID
    let previous: ScheduleImportEntrySnapshot?
    let expectedPostImportFingerprint: String

    init(entry: ScheduleEntryModel, previous: ScheduleImportEntrySnapshot?) {
        entryID = entry.id
        self.previous = previous
        expectedPostImportFingerprint = ScheduleImportEntrySnapshot(entry: entry).fingerprint()
    }
}

nonisolated enum ScheduleImportService {
    /// Pure extraction and parsing work. Call this from a detached task; it
    /// never touches SwiftData or SwiftUI state.
    static func prepare(fileData: Data, fileExtension: String, totalWeeks: Int) throws -> ScheduleImportExtraction {
        try Task.checkCancellation()
        let text = try extractText(fromFileData: fileData, fileExtension: fileExtension)
        try Task.checkCancellation()
        return ScheduleImportExtraction(text: text, drafts: parse(text: text, totalWeeks: totalWeeks))
    }

    static func extractText(from url: URL) throws -> String {
        try extractText(fromFileData: Data(contentsOf: url), fileExtension: url.pathExtension)
    }

    static func extractText(fromFileData data: Data, fileExtension: String) throws -> String {
        if fileExtension.lowercased() == "pdf", let document = PDFDocument(data: data) {
            return try extractPDFText(document)
        }
        return try extractText(fromImageData: data)
    }

    static func extractText(fromImageData data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw RepositoryError.invalidData }
        return try recognize(image)
    }

    static func parse(text: String, totalWeeks: Int) -> [ImportedScheduleDraft] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let candidates = lines.filter { weekday(in: $0) != nil }
        return (candidates.isEmpty ? [text] : candidates).compactMap {
            guard !Task.isCancelled else { return nil }
            return parseLine($0, totalWeeks: totalWeeks)
        }
    }

    private static func extractPDFText(_ document: PDFDocument) throws -> String {
        var pages: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let directText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !directText.isEmpty {
                pages.append(directText)
                continue
            }
            // Render a single bounded page at a time. A failed OCR page is
            // intentionally skipped rather than failing the complete import.
            let image = page.thumbnail(of: CGSize(width: 1440, height: 2048), for: .mediaBox).cgImage
            if let image, let text = try? recognize(image), !text.isEmpty { pages.append(text) }
        }
        guard !pages.isEmpty else { throw RepositoryError.invalidData }
        return pages.joined(separator: "\n")
    }

    private static func recognize(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func parseLine(_ value: String, totalWeeks: Int) -> ImportedScheduleDraft? {
        guard let weekday = weekday(in: value) else { return nil }
        let explicitTimes = timeRange(in: value)
        let periodTimes = periodRange(in: value)
        let times = explicitTimes ?? periodTimes
        let weeks = weekRange(in: value, totalWeeks: totalWeeks)
        let title = title(in: value)
        guard !title.isEmpty else { return nil }
        var needsConfirmation: [String] = []
        var confidence: [String: Double] = ["名称": 0.8, "星期": 0.9]
        if times == nil { needsConfirmation.append("上课时间"); confidence["时间"] = 0 }
        else if explicitTimes == nil { needsConfirmation.append("真实时间（按节次默认时间）"); confidence["时间"] = 0.45 }
        else { confidence["时间"] = 0.8 }
        if weeks == nil { needsConfirmation.append("起止周"); confidence["周次"] = 0 }
        else { confidence["周次"] = 0.8 }
        let location = labeled(anyOf: ["地点", "教室", "上课地点"], in: value) ?? roomLocation(in: value)
        let major = labeled("专业", in: value)
        let grade = labeled("年级", in: value)
        let className = labeled("班级", in: value)
        if location != nil { confidence["地点"] = 0.8 }
        return ImportedScheduleDraft(
            title: title, weekday: weekday,
            startMinutes: times?.0 ?? 8 * 60,
            endMinutes: times?.1 ?? 9 * 60 + 40,
            startWeek: weeks?.0 ?? 1, endWeek: weeks?.1 ?? totalWeeks,
            weekType: weekType(in: value), location: location, major: major,
            grade: grade, className: className, note: teacherNote(in: value),
            needsConfirmation: needsConfirmation, confidenceByField: confidence
        )
    }

    private static func weekday(in value: String) -> Int? {
        let map: [Character: Int] = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
        let expressions = ["星期", "周"]
        for expression in expressions {
            guard let range = value.range(of: expression), range.upperBound < value.endIndex else { continue }
            let next = value[range.upperBound]
            if let day = map[next] { return day }
        }
        return nil
    }

    private static func timeRange(in value: String) -> (Int, Int)? {
        let pattern = #"(\d{1,2})\s*[:：]\s*(\d{2})\s*[-~～至]\s*(\d{1,2})\s*[:：]\s*(\d{2})"#
        guard let values = captures(pattern, value), values.count == 4,
              let startHour = Int(values[0]), let startMinute = Int(values[1]),
              let endHour = Int(values[2]), let endMinute = Int(values[3]) else { return nil }
        let start = startHour * 60 + startMinute
        let end = endHour * 60 + endMinute
        return (0..<1_440).contains(start) && (1...1_440).contains(end) && start < end ? (start, end) : nil
    }

    private static func weekRange(in value: String, totalWeeks: Int) -> (Int, Int)? {
        let rangePattern = #"(?:第?\s*)?(\d{1,2})\s*[-~～至]\s*(\d{1,2})\s*周"#
        if let values = captures(rangePattern, value), values.count == 2,
           let start = Int(values[0]), let end = Int(values[1]),
           (1...totalWeeks).contains(start), (start...totalWeeks).contains(end) { return (start, end) }
        let singlePattern = #"第?\s*(\d{1,2})\s*周(?:\b|\s|$)"#
        if let value = captures(singlePattern, value)?.first, let week = Int(value), (1...totalWeeks).contains(week) { return (week, week) }
        return nil
    }

    private static func periodRange(in value: String) -> (Int, Int)? {
        let pattern = #"第?\s*([1-6])\s*(?:[-~～至]\s*([1-6]))?\s*节?"#
        guard let values = captures(pattern, value), let first = Int(values[0]) else { return nil }
        let last = values.count > 1 ? Int(values[1]) ?? first : first
        guard first <= last,
              let start = ClassPeriodTemplate(rawValue: first - 1)?.startMinutes,
              let end = ClassPeriodTemplate(rawValue: last - 1)?.endMinutes else { return nil }
        return (start, end)
    }

    private static func weekType(in value: String) -> WeekType {
        value.contains("单周") || value.contains("(单)") ? .oddWeek : value.contains("双周") || value.contains("(双)") ? .evenWeek : .everyWeek
    }

    private static func labeled(_ label: String, in value: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: label))\\s*[:：]\\s*([^\\s，,；;]+)"
        return captures(pattern, value)?.first
    }

    private static func labeled(anyOf labels: [String], in value: String) -> String? {
        labels.lazy.compactMap { labeled($0, in: value) }.first
    }

    private static func teacherNote(in value: String) -> String? {
        if let named = labeled(anyOf: ["教师", "老师", "任课教师"], in: value) { return "教师：\(named)" }
        guard let teacher = captures(#"([\p{Han}]{2,4})老师"#, value)?.first else { return nil }
        return "教师：\(teacher)"
    }

    private static func title(in value: String) -> String {
        var result = value
        let patterns = [
            #"(?:星期|周)[一二三四五六日天]"#,
            #"\d{1,2}\s*[:：]\s*\d{2}\s*[-~～至]\s*\d{1,2}\s*[:：]\s*\d{2}"#,
            #"第?\s*\d+\s*(?:[-~～至]\s*\d+)?\s*节?"#,
            #"第?\s*\d{1,2}\s*[-~～至]\s*\d{1,2}\s*周"#,
            #"第?\s*\d{1,2}\s*周"#,
            #"(?:单周|双周|每周|全周|\(单\)|\(双\))"#,
            #"[A-Za-z]\d{3,4}"#,
            #"[\p{Han}]{2,4}老师"#
        ]
        for pattern in patterns { result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
        // Most exported schedules place metadata before the title. Remove known
        // labelled fields no matter where they occur rather than assuming an order.
        result = result.replacingOccurrences(of: #"(?:地点|教室|上课地点|教师|老师|任课教师|专业|年级|班级)\s*[:：]\s*[^\s，,；;]+"#, with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func roomLocation(in value: String) -> String? {
        captures(#"\b([A-Za-z]\d{3,4})\b"#, value)?.first
    }

    private static func captures(_ pattern: String, _ value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: value).map { String(value[$0]) }
        }
    }
}
