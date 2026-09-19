import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import PDFKit
import Vision
import UIKit

private enum ImportConflictChoice: String, CaseIterable, Identifiable {
    case skip, keep, update
    var id: String { rawValue }
    var title: String { switch self { case .skip: "跳过重复"; case .keep: "保留为新课程"; case .update: "更新现有课程" } }
}

private struct ImportedScheduleDraft: Identifiable {
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
}

/// Local-only import boundary. OCR and parsing produce editable drafts; this
/// type deliberately has no ModelContext and cannot write SwiftData itself.
struct ScheduleImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @Query private var entries: [ScheduleEntryModel]
    let semester: SemesterModel
    @State private var photoItem: PhotosPickerItem?
    @State private var showingFiles = false
    @State private var showingCamera = false
    @State private var isExtracting = false
    @State private var extractedText = ""
    @State private var drafts: [ImportedScheduleDraft] = []
    @State private var choice: ImportConflictChoice = .skip
    @State private var error: String?

    private var totalWeeks: Int { max(1, semester.totalWeeks) }
    private var ownedEntries: [ScheduleEntryModel] { entries.filter { $0.ownerID == env.session.currentMemberID && $0.semesterID == semester.id } }

    var body: some View {
        List {
            Section("选择课表文件") {
                PhotosPicker(selection: $photoItem, matching: .images) { Label("从相册选择图片", systemImage: "photo.on.rectangle") }
                Button { showingFiles = true } label: { Label("从文件导入 PDF 或图片", systemImage: "folder") }
                Button { showingCamera = true } label: { Label("使用相机拍摄", systemImage: "camera") }
                Text("支持 PDF、PNG、JPG、JPEG、HEIC。文本 PDF 会直接取文本；扫描 PDF 与图片会逐页本地 OCR。单页识别失败不会中断其余页面。 ")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isExtracting { Section { HStack { ProgressView(); Text("正在本地识别和整理草稿…") } } }
            if !extractedText.isEmpty { Section("识别文本") { Text(extractedText).font(.caption).lineLimit(8); Text("无法可靠确定的字段已标为“需要确认”，请在导入前修正。 ").font(.caption).foregroundStyle(.orange) } }
            if !drafts.isEmpty {
                Section("导入草稿") {
                    ForEach(drafts.indices, id: \.self) { index in
                        NavigationLink { ScheduleImportDraftEditor(draft: $drafts[index], totalWeeks: totalWeeks) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(drafts[index].title)
                                Text("\(weekdayName(drafts[index].weekday)) · \(minutesText(drafts[index].startMinutes))–\(minutesText(drafts[index].endMinutes)) · 第 \(drafts[index].startWeek)-\(drafts[index].endWeek) 周")
                                    .font(.caption).foregroundStyle(.secondary)
                                if !drafts[index].needsConfirmation.isEmpty { Text("需要确认：\(drafts[index].needsConfirmation.joined(separator: "、"))").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                    }
                }
                Section("重复课程") {
                    Picker("遇到重复时", selection: $choice) { ForEach(ImportConflictChoice.allCases) { Text($0.title).tag($0) } }
                    Text("重复依据：同一成员、学期、名称、星期和真实起止时间。不会根据六课段网格近似判断。 ").font(.caption).foregroundStyle(.secondary)
                }
                Section { Button("确认导入", action: commit).frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("导入课表")
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: false) { result in
            switch result { case .success(let urls): if let url = urls.first { extract(url: url) }; case .failure(let failure): error = "无法读取文件：\(failure.localizedDescription)" }
        }
        .sheet(isPresented: $showingCamera) { CameraImagePicker { image in
            guard let data = image.jpegData(compressionQuality: 0.92) else { error = "相机图片无法编码。"; return }
            extract(imageData: data)
        } }
        .onChange(of: photoItem) { _, item in
            Task { do { if let data = try await item?.loadTransferable(type: Data.self) { extract(imageData: data) } } catch { error = "无法读取相册图片：\(error.localizedDescription)" } }
        }
        .alert("导入失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
    }

    private func extract(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { accept(text: try ScheduleImportExtractor.extractText(from: url)) } catch { error = "无法识别文件：\(error.localizedDescription)" }
    }

    private func extract(imageData: Data) {
        do { accept(text: try ScheduleImportExtractor.extractText(fromImageData: imageData)) } catch { error = "无法识别图片：\(error.localizedDescription)" }
    }

    private func accept(text: String) {
        extractedText = text
        drafts = ScheduleImportParser.parse(text: text, totalWeeks: totalWeeks)
        if drafts.isEmpty { error = "没有找到可编辑的课程草稿，请确认图片清晰或手工新建课程。" }
    }

    private func commit() {
        let member = env.session.currentMemberID ?? ""
        do {
            for draft in drafts {
                let duplicate = ownedEntries.first { item in
                    item.title == draft.title && item.weekday == draft.weekday && item.startMinutes == draft.startMinutes && item.endMinutes == draft.endMinutes
                }
                if duplicate != nil && choice == .skip { continue }
                let target = choice == .update ? (duplicate ?? newEntry(from: draft, member: member)) : newEntry(from: draft, member: member)
                let value = ScheduleDraft(title: draft.title, kind: .course, weekday: draft.weekday, startMinutes: draft.startMinutes, endMinutes: draft.endMinutes, startWeek: draft.startWeek, endWeek: draft.endWeek, weekType: draft.weekType, major: draft.major, grade: draft.grade, className: draft.className, location: draft.location, note: draft.note, labName: nil, advisor: nil)
                try env.scheduleRepository.save(target, draft: value, by: member)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func newEntry(from draft: ImportedScheduleDraft, member: String) -> ScheduleEntryModel {
        ScheduleEntryModel(ownerID: member, semesterID: semester.id, title: draft.title, kind: .course, weekday: draft.weekday, startMinutes: draft.startMinutes, endMinutes: draft.endMinutes, startWeek: draft.startWeek, endWeek: draft.endWeek, weekType: draft.weekType)
    }

    private func weekdayName(_ weekday: Int) -> String { ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][max(1, min(7, weekday)) - 1] }
    private func minutesText(_ value: Int) -> String { String(format: "%02d:%02d", value / 60, value % 60) }
}

private struct ScheduleImportDraftEditor: View {
    @Binding var draft: ImportedScheduleDraft
    let totalWeeks: Int
    @State private var start = Date()
    @State private var end = Date()
    private let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
    var body: some View {
        Form {
            TextField("课程名称", text: $draft.title)
            Picker("星期", selection: $draft.weekday) { ForEach(1...7, id: \.self) { Text(weekdays[$0 - 1]).tag($0) } }
            DatePicker("开始时间", selection: $start, displayedComponents: .hourAndMinute)
            DatePicker("结束时间", selection: $end, displayedComponents: .hourAndMinute)
            Stepper("起始周：\(draft.startWeek)", value: $draft.startWeek, in: 1...totalWeeks)
            Stepper("结束周：\(draft.endWeek)", value: $draft.endWeek, in: draft.startWeek...totalWeeks)
            Picker("周类型", selection: $draft.weekType) { Text("每周").tag(WeekType.everyWeek); Text("单周").tag(WeekType.oddWeek); Text("双周").tag(WeekType.evenWeek) }
            TextField("地点", text: optionalBinding(\.location))
            TextField("专业", text: optionalBinding(\.major))
            TextField("年级", text: optionalBinding(\.grade))
            TextField("班级", text: optionalBinding(\.className))
            TextField("备注", text: optionalBinding(\.note), axis: .vertical)
        }
        .navigationTitle("修正草稿")
        .onAppear { start = date(minutes: draft.startMinutes); end = date(minutes: draft.endMinutes) }
        .onChange(of: start) { _, value in draft.startMinutes = minute(value) }
        .onChange(of: end) { _, value in draft.endMinutes = minute(value) }
        .onChange(of: draft.startWeek) { _, value in if draft.endWeek < value { draft.endWeek = value } }
    }
    private func optionalBinding(_ path: WritableKeyPath<ImportedScheduleDraft, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: path] ?? "" }, set: { draft[keyPath: path] = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 })
    }
    private func date(minutes: Int) -> Date { Calendar.autoupdatingCurrent.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now }
    private func minute(_ date: Date) -> Int { let calendar = Calendar.autoupdatingCurrent; return calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date) }
}

private enum ScheduleImportExtractor {
    static func extractText(from url: URL) throws -> String {
        if url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) {
            var pages: [String] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                if let direct = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !direct.isEmpty { pages.append(direct); continue }
                // Render one bounded page at a time so multi-page scans do not retain full-resolution images.
                if let image = page.thumbnail(of: CGSize(width: 1440, height: 2048), for: .mediaBox).cgImage, let text = try? recognize(image), !text.isEmpty { pages.append(text) }
            }
            return pages.joined(separator: "\n")
        }
        return try extractText(fromImageData: Data(contentsOf: url))
    }
    static func extractText(fromImageData data: Data) throws -> String {
        guard let image = UIImage(data: data)?.cgImage else { throw RepositoryError.invalidData }
        return try recognize(image)
    }
    private static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

private enum ScheduleImportParser {
    static func parse(text: String, totalWeeks: Int) -> [ImportedScheduleDraft] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let candidates = lines.filter { weekday(in: $0) != nil }
        return (candidates.isEmpty ? [text] : candidates).compactMap { line in
            guard let weekday = weekday(in: line) else { return nil }
            let times = timeRange(in: line)
            let weeks = weekRange(in: line, totalWeeks: totalWeeks)
            let title = title(in: line)
            guard !title.isEmpty else { return nil }
            var missing: [String] = []
            if times == nil { missing.append("上课时间") }
            if weeks == nil { missing.append("起止周") }
            return ImportedScheduleDraft(title: title, weekday: weekday, startMinutes: times?.0 ?? 8 * 60, endMinutes: times?.1 ?? 9 * 60 + 40, startWeek: weeks?.0 ?? 1, endWeek: weeks?.1 ?? totalWeeks, weekType: weekType(in: line), location: labeled("地点", in: line), major: labeled("专业", in: line), grade: labeled("年级", in: line), className: labeled("班级", in: line), note: teacherNote(in: line), needsConfirmation: missing)
        }
    }
    private static func weekday(in value: String) -> Int? {
        let map: [Character: Int] = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
        guard let range = value.range(of: "周") else { return nil }
        return range.upperBound < value.endIndex ? map[value[range.upperBound]] : nil
    }
    private static func timeRange(in value: String) -> (Int, Int)? {
        let pattern = #"(\d{1,2})\s*[:：]\s*(\d{2})\s*[-~～至]\s*(\d{1,2})\s*[:：]\s*(\d{2})"#
        guard let values = captures(pattern, value), values.count == 4, let sh = Int(values[0]), let sm = Int(values[1]), let eh = Int(values[2]), let em = Int(values[3]) else { return nil }
        let start = sh * 60 + sm, end = eh * 60 + em
        return (0..<1_440).contains(start) && (1...1_440).contains(end) && start < end ? (start, end) : nil
    }
    private static func weekRange(in value: String, totalWeeks: Int) -> (Int, Int)? {
        let pattern = #"(\d{1,2})\s*[-~～至]\s*(\d{1,2})\s*周"#
        guard let values = captures(pattern, value), values.count == 2, let start = Int(values[0]), let end = Int(values[1]), (1...totalWeeks).contains(start), (start...totalWeeks).contains(end) else { return nil }
        return (start, end)
    }
    private static func weekType(in value: String) -> WeekType { value.contains("单周") ? .oddWeek : value.contains("双周") ? .evenWeek : .everyWeek }
    private static func labeled(_ label: String, in value: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: label))\\s*[:：]\\s*([^\\s，,；;]+)"
        return captures(pattern, value)?.first
    }
    private static func teacherNote(in value: String) -> String? { labeled("教师", in: value).map { "教师：\($0)" } }
    private static func title(in value: String) -> String {
        value.replacingOccurrences(of: #"周[一二三四五六日天].*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func captures(_ pattern: String, _ value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern), let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in Range(match.range(at: index), in: value).map { String(value[$0]) } }
    }
}

private struct CameraImagePicker: UIViewControllerRepresentable {
    let completion: (UIImage) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController { let controller = UIImagePickerController(); controller.sourceType = .camera; controller.delegate = context.coordinator; return controller }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (UIImage) -> Void
        init(completion: @escaping (UIImage) -> Void) { self.completion = completion }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { if let image = info[.originalImage] as? UIImage { completion(image) }; picker.dismiss(animated: true) }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
    }
}
