import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// Presentation-only import flow. OCR, parsing, duplicate handling and all
/// SwiftData writes live in ScheduleImportService/LocalScheduleRepository.
@MainActor
struct ScheduleImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @Query private var batches: [ScheduleImportBatchModel]
    let semester: SemesterModel

    @State private var photoItem: PhotosPickerItem?
    @State private var showingFiles = false
    @State private var showingCamera = false
    @State private var isExtracting = false
    @State private var extractedText = ""
    @State private var drafts: [ImportedScheduleDraft] = []
    @State private var conflictPolicy: ScheduleImportConflictPolicy = .skip
    @State private var errorMessage: String?
    @State private var lastSource: ScheduleImportSource = .files
    @State private var sourceFileName: String?
    @State private var sourceFileType: String?
    @State private var selectedBatch: ScheduleImportBatchModel?
    @State private var extractionWorker: Task<ScheduleImportExtraction, Error>?
    @State private var activeExtractionID: UUID?

    private var totalWeeks: Int { max(1, semester.totalWeeks) }
    private var currentBatches: [ScheduleImportBatchModel] {
        batches.filter { $0.semesterID == semester.id && $0.ownerID == env.session.currentMemberID }
    }

    private var isShowingError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )
    }

    var body: some View {
        importList
            .scheduleImportPresentation(
                showingFiles: $showingFiles,
                showingCamera: $showingCamera,
                selectedBatch: $selectedBatch,
                photoItem: $photoItem,
                isShowingError: isShowingError,
                errorMessage: errorMessage,
                onFileSelection: handleFileSelection,
                onCameraImage: acceptCameraImage,
                onPhotoSelection: loadPhoto,
                onDisappear: cancelExtraction
            )
    }

    private var importList: some View {
        List {
            importSourceSection
            extractionStateSection
            recognizedTextSection
            ScheduleImportDraftSections(
                drafts: $drafts,
                totalWeeks: totalWeeks,
                conflictPolicy: $conflictPolicy,
                onCommit: commit
            )
            ScheduleImportHistorySection(
                batches: currentBatches,
                selectedBatch: $selectedBatch,
                updatedCount: updatedCount,
                sourceTitle: sourceTitle,
                onUndo: undo
            )
        }
        .navigationTitle("导入课表")
    }

    private var importSourceSection: some View {
        Section("选择课表文件") {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("从相册选择图片", systemImage: "photo.on.rectangle")
            }
            Button { showingFiles = true } label: {
                Label("从文件导入 PDF 或图片", systemImage: "folder")
            }
            Button(action: presentCamera) {
                Label("使用相机拍摄", systemImage: "camera")
            }
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Text("支持 PDF、PNG、JPG、JPEG、HEIC。文本 PDF 直接取文本；扫描 PDF 与图片逐页本地 OCR。单页失败不影响其余页面。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "当前设备没有可用相机，请从相册或文件导入。"
            return
        }
        showingCamera = true
    }

    @ViewBuilder private var extractionStateSection: some View {
        if isExtracting {
            Section { HStack { ProgressView(); Text("正在本地识别和整理草稿…") } }
        }
    }

    @ViewBuilder private var recognizedTextSection: some View {
        if !extractedText.isEmpty {
            Section("识别文本") {
                Text(extractedText).font(.caption).lineLimit(8)
                Text("无法可靠确定的字段已标为“需要确认”，请在导入前修正。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            acceptFile(url)
        case .failure(let caughtError):
            errorMessage = "无法读取文件：\(caughtError.localizedDescription)"
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "image"
            acceptImage(data, source: .photoLibrary, fileExtension: fileExtension)
        } catch let caughtError {
            errorMessage = "无法读取相册图片：\(caughtError.localizedDescription)"
        }
    }

    private func acceptFile(_ url: URL) {
        let fileName = url.lastPathComponent
        let fileType = url.pathExtension.lowercased()
        let weeks = totalWeeks
        let scoped = url.startAccessingSecurityScopedResource()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data = try Data(contentsOf: url)
            try Task.checkCancellation()
            return try ScheduleImportService.prepare(fileData: data, fileExtension: fileType, totalWeeks: weeks)
        }
        startExtraction(worker, source: .files, fileName: fileName, fileType: fileType, scopedURL: scoped ? url : nil)
    }

    private func acceptImage(_ data: Data, source: ScheduleImportSource, fileExtension: String) {
        let fileName = source == .camera ? "相机图片.\(fileExtension)" : "相册图片.\(fileExtension)"
        beginExtraction(data: data, fileExtension: fileExtension, source: source, fileName: fileName)
    }

    private func acceptCameraImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.92) else {
            errorMessage = "相机图片无法编码。"
            return
        }
        acceptImage(data, source: .camera, fileExtension: "jpg")
    }

    private func beginExtraction(data: Data, fileExtension: String, source: ScheduleImportSource, fileName: String) {
        let weeks = totalWeeks
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try ScheduleImportService.prepare(fileData: data, fileExtension: fileExtension, totalWeeks: weeks)
        }
        startExtraction(worker, source: source, fileName: fileName, fileType: fileExtension)
    }

    private func startExtraction(_ worker: Task<ScheduleImportExtraction, Error>, source: ScheduleImportSource, fileName: String?, fileType: String?, scopedURL: URL? = nil) {
        extractionWorker?.cancel()
        extractionWorker = worker
        let identifier = UUID()
        activeExtractionID = identifier
        isExtracting = true
        Task { @MainActor [worker, identifier, source, fileName, fileType, scopedURL] in
            defer {
                if activeExtractionID == identifier {
                    isExtracting = false
                    extractionWorker = nil
                }
                scopedURL?.stopAccessingSecurityScopedResource()
            }
            do {
                let extraction = try await worker.value
                guard activeExtractionID == identifier else { return }
                accept(extraction: extraction, source: source, fileName: fileName, fileType: fileType)
            } catch is CancellationError {
                // The view was dismissed or a newer source superseded this work.
            } catch let caughtError {
                guard activeExtractionID == identifier else { return }
                errorMessage = "无法识别课表：\(caughtError.localizedDescription)"
            }
        }
    }

    private func accept(extraction: ScheduleImportExtraction, source: ScheduleImportSource, fileName: String?, fileType: String?) {
        lastSource = source
        sourceFileName = fileName
        sourceFileType = fileType
        extractedText = extraction.text
        drafts = extraction.drafts
        if drafts.isEmpty {
            errorMessage = "没有找到可编辑的课程草稿，请确认图片清晰或手工新建课程。"
        }
    }

    private func commit() {
        guard let memberID = env.session.currentMemberID else { return }
        do {
            _ = try env.scheduleRepository.importBatch(
                drafts: drafts,
                semesterID: semester.id,
                source: lastSource,
                sourceFileName: sourceFileName,
                sourceFileType: sourceFileType,
                conflictPolicy: conflictPolicy,
                by: memberID
            )
            dismiss()
        } catch let caughtError {
            errorMessage = caughtError.localizedDescription
        }
    }

    private func undo(_ batch: ScheduleImportBatchModel) {
        guard let memberID = env.session.currentMemberID else { return }
        do {
            try env.scheduleRepository.undoImport(batch, by: memberID)
        } catch let caughtError {
            errorMessage = caughtError.localizedDescription
        }
    }

    private func updatedCount(for batch: ScheduleImportBatchModel) -> Int {
        guard let encoded = batch.updatedEntrySnapshots, let data = Data(base64Encoded: encoded) else { return 0 }
        do {
            return try JSONDecoder().decode([ScheduleImportEntrySnapshot].self, from: data).count
        } catch {
            return 0
        }
    }

    private func cancelExtraction() { extractionWorker?.cancel() }

    private func sourceTitle(_ batch: ScheduleImportBatchModel) -> String {
        switch ScheduleImportSource(rawValue: batch.sourceRaw) {
        case .some(.files): return "文件导入"
        case .some(.camera): return "相机导入"
        case .some(.photoLibrary): return "相册导入"
        case .none: return "历史导入"
        }
    }
}

private extension View {
    @MainActor
    func scheduleImportPresentation(
        showingFiles: Binding<Bool>,
        showingCamera: Binding<Bool>,
        selectedBatch: Binding<ScheduleImportBatchModel?>,
        photoItem: Binding<PhotosPickerItem?>,
        isShowingError: Binding<Bool>,
        errorMessage: String?,
        onFileSelection: @escaping (Result<[URL], Error>) -> Void,
        onCameraImage: @escaping (UIImage) -> Void,
        onPhotoSelection: @escaping (PhotosPickerItem) async -> Void,
        onDisappear: @escaping () -> Void
    ) -> some View {
        modifier(
            ScheduleImportPresentationModifier(
                showingFiles: showingFiles,
                showingCamera: showingCamera,
                selectedBatch: selectedBatch,
                photoItem: photoItem,
                isShowingError: isShowingError,
                errorMessage: errorMessage,
                onFileSelection: onFileSelection,
                onCameraImage: onCameraImage,
                onPhotoSelection: onPhotoSelection,
                onDisappear: onDisappear
            )
        )
    }
}

@MainActor
private struct ScheduleImportPresentationModifier: ViewModifier {
    @Binding var showingFiles: Bool
    @Binding var showingCamera: Bool
    @Binding var selectedBatch: ScheduleImportBatchModel?
    @Binding var photoItem: PhotosPickerItem?
    let isShowingError: Binding<Bool>
    let errorMessage: String?
    let onFileSelection: (Result<[URL], Error>) -> Void
    let onCameraImage: (UIImage) -> Void
    let onPhotoSelection: (PhotosPickerItem) async -> Void
    let onDisappear: () -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $showingFiles,
                allowedContentTypes: [.pdf, .image],
                allowsMultipleSelection: false,
                onCompletion: onFileSelection
            )
            .sheet(isPresented: $showingCamera) {
                CameraImagePicker(completion: onCameraImage)
            }
            .sheet(item: $selectedBatch) { batch in
                NavigationStack { ScheduleImportBatchDetail(batch: batch) }
            }
            .onChange(of: photoItem) { _, selectedItem in
                guard let selectedItem else { return }
                Task {
                    await onPhotoSelection(selectedItem)
                }
            }
            .onDisappear(perform: onDisappear)
            .alert("导入失败", isPresented: isShowingError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }
}

private struct ScheduleImportDraftSections: View {
    @Binding var drafts: [ImportedScheduleDraft]
    let totalWeeks: Int
    @Binding var conflictPolicy: ScheduleImportConflictPolicy
    let onCommit: () -> Void

    private var containsUnconfirmedDraft: Bool {
        drafts.contains { !$0.isReadyToImport }
    }

    var body: some View {
        if !drafts.isEmpty {
            draftListSection
            conflictPolicySection
            commitSection
        }
    }

    private var draftListSection: some View {
        Section("导入草稿") {
            ForEach(drafts.indices, id: \.self) { index in
                NavigationLink {
                    ScheduleImportDraftEditor(draft: $drafts[index], totalWeeks: totalWeeks)
                } label: {
                    ScheduleImportDraftRow(draft: drafts[index])
                }
            }
        }
    }

    private var conflictPolicySection: some View {
        Section("重复课程") {
            Picker("遇到重复时", selection: $conflictPolicy) {
                ForEach(ScheduleImportConflictPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            Text("重复依据：同一成员、学期、名称、星期和真实起止时间。不会根据六课段网格近似判断。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var commitSection: some View {
        Section {
            Button("确认导入", action: onCommit)
                .frame(maxWidth: .infinity)
                .disabled(containsUnconfirmedDraft)
        }
    }
}

private struct ScheduleImportHistorySection: View {
    let batches: [ScheduleImportBatchModel]
    @Binding var selectedBatch: ScheduleImportBatchModel?
    let updatedCount: (ScheduleImportBatchModel) -> Int
    let sourceTitle: (ScheduleImportBatchModel) -> String
    let onUndo: (ScheduleImportBatchModel) -> Void

    var body: some View {
        if !batches.isEmpty {
            Section("导入历史") {
                ForEach(batches) { batch in
                    ScheduleImportBatchHistoryRow(
                        batch: batch,
                        updatedCount: updatedCount(batch),
                        sourceTitle: sourceTitle(batch),
                        onOpen: { selectedBatch = batch },
                        onUndo: { onUndo(batch) }
                    )
                }
            }
        }
    }
}

private struct ScheduleImportBatchHistoryRow: View {
    let batch: ScheduleImportBatchModel
    let updatedCount: Int
    let sourceTitle: String
    let onOpen: () -> Void
    let onUndo: () -> Void

    var body: some View {
        HStack {
            Button(action: onOpen) {
                batchSummary
            }
            .buttonStyle(.plain)
            Spacer(minLength: 12)
            Button("撤销", action: onUndo)
                .font(.caption)
        }
    }

    private var batchSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayTitle)
            Text("\(FamilyFormatters.dateTime.string(from: batch.createdAt)) · 新增 \(batch.importedEntryIDs.count) 门 · 更新 \(updatedCount) 门")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let fileType = batch.sourceFileType, !fileType.isEmpty {
                Text(fileType.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var displayTitle: String {
        guard let fileName = batch.sourceFileName, !fileName.isEmpty else { return sourceTitle }
        return fileName
    }
}

private struct ScheduleImportBatchDetail: View {
    @Query private var entries: [ScheduleEntryModel]
    let batch: ScheduleImportBatchModel

    private var updatedIDs: Set<UUID> {
        guard let encoded = batch.updatedEntrySnapshots, let data = Data(base64Encoded: encoded),
              let snapshots = try? JSONDecoder().decode([ScheduleImportEntrySnapshot].self, from: data) else { return [] }
        return Set(snapshots.map(\.id))
    }

    private var affectedEntries: [ScheduleEntryModel] {
        let created = Set(batch.importedEntryIDs.compactMap(UUID.init(uuidString:)))
        return entries.filter { created.contains($0.id) || updatedIDs.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            Section("批次信息") {
                LabeledContent("时间", value: FamilyFormatters.dateTime.string(from: batch.createdAt))
                if let name = batch.sourceFileName, !name.isEmpty { LabeledContent("来源文件", value: name) }
                if let type = batch.sourceFileType, !type.isEmpty { LabeledContent("文件类型", value: type.uppercased()) }
            }
            Section("本批影响的课程") {
                if affectedEntries.isEmpty { Text("课程已被删除或不再属于此批次。").foregroundStyle(.secondary) }
                ForEach(affectedEntries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                        Text("周\(weekdayName(entry.weekday)) · \(minutesText(entry.startMinutes))–\(minutesText(entry.endMinutes)) · 第 \(entry.startWeek)-\(entry.endWeek) 周")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("导入批次")
    }

    private func weekdayName(_ weekday: Int) -> String {
        ["日", "一", "二", "三", "四", "五", "六"][max(1, min(7, weekday)) - 1]
    }

    private func minutesText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

private struct ScheduleImportDraftRow: View {
    let draft: ImportedScheduleDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(draft.title)
            Text("\(weekdayName(draft.weekday)) · \(minutesText(draft.startMinutes))–\(minutesText(draft.endMinutes)) · 第 \(draft.startWeek)-\(draft.endWeek) 周")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !draft.needsConfirmation.isEmpty {
                Text("需要确认：\(draft.needsConfirmation.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func weekdayName(_ weekday: Int) -> String {
        ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][max(1, min(7, weekday)) - 1]
    }

    private func minutesText(_ value: Int) -> String {
        String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private struct ScheduleImportDraftEditor: View {
    @Binding var draft: ImportedScheduleDraft
    let totalWeeks: Int
    @State private var start = Date()
    @State private var end = Date()
    var body: some View {
        Form {
            identitySection
            timingSection
            detailSection
            confidenceSection
        }
        .navigationTitle("修正草稿")
        .onAppear(perform: loadTimeFields)
        .onChange(of: start) { _, value in updateStartMinutes(value) }
        .onChange(of: end) { _, value in updateEndMinutes(value) }
        .onChange(of: draft.startWeek) { _, value in updateStartWeek(value) }
        .onChange(of: draft.endWeek) { _, value in updateEndWeek(value) }
    }

    private var identitySection: some View {
        Section("基本信息") {
            TextField("课程名称", text: $draft.title)
            Picker("星期", selection: $draft.weekday) {
                ForEach(ScheduleImportWeekday.allCases) { weekday in
                    Text(weekday.title).tag(weekday.rawValue)
                }
            }
        }
    }

    private var timingSection: some View {
        Section("时间与周次") {
            DatePicker("开始时间", selection: $start, displayedComponents: .hourAndMinute)
            DatePicker("结束时间", selection: $end, displayedComponents: .hourAndMinute)
            Stepper("起始周：\(draft.startWeek)", value: $draft.startWeek, in: validStartWeekRange)
            Stepper("结束周：\(draft.endWeek)", value: $draft.endWeek, in: validEndWeekRange)
            Picker("周类型", selection: $draft.weekType) {
                Text("每周").tag(WeekType.everyWeek)
                Text("单周").tag(WeekType.oddWeek)
                Text("双周").tag(WeekType.evenWeek)
            }
        }
    }

    private var detailSection: some View {
        Section("补充信息") {
            TextField("地点", text: locationBinding)
            TextField("专业", text: majorBinding)
            TextField("年级", text: gradeBinding)
            TextField("班级", text: classNameBinding)
            TextField("备注", text: noteBinding, axis: .vertical)
        }
    }

    @ViewBuilder private var confidenceSection: some View {
        if !draft.confidenceByField.isEmpty {
            Section {
                Text("本地识别可信度：\(confidenceText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var validStartWeekRange: ClosedRange<Int> { 1...max(1, totalWeeks) }

    private var validEndWeekRange: ClosedRange<Int> {
        let lowerBound = min(max(1, draft.startWeek), max(1, totalWeeks))
        return lowerBound...max(1, totalWeeks)
    }

    private var locationBinding: Binding<String> { optionalBinding(\.location) }
    private var majorBinding: Binding<String> { optionalBinding(\.major) }
    private var gradeBinding: Binding<String> { optionalBinding(\.grade) }
    private var classNameBinding: Binding<String> { optionalBinding(\.className) }
    private var noteBinding: Binding<String> { optionalBinding(\.note) }

    private func optionalBinding(_ path: WritableKeyPath<ImportedScheduleDraft, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: path] ?? "" },
            set: { value in draft[keyPath: path] = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value }
        )
    }

    private func clearConfirmation(_ value: String) {
        draft.needsConfirmation.removeAll { $0 == value }
    }

    private func loadTimeFields() {
        start = date(minutes: draft.startMinutes)
        end = date(minutes: draft.endMinutes)
    }

    private func updateStartMinutes(_ value: Date) {
        draft.startMinutes = minute(value)
        clearConfirmation("上课时间")
    }

    private func updateEndMinutes(_ value: Date) {
        draft.endMinutes = minute(value)
        clearConfirmation("上课时间")
    }

    private func updateStartWeek(_ value: Int) {
        if draft.endWeek < value { draft.endWeek = value }
        clearConfirmation("起止周")
    }

    private func updateEndWeek(_: Int) {
        clearConfirmation("起止周")
    }

    private var confidenceText: String {
        draft.confidenceByField.keys.sorted().map { field in
            "\(field) \(Int((draft.confidenceByField[field] ?? 0) * 100))%"
        }.joined(separator: " · ")
    }

    private func date(minutes: Int) -> Date {
        Calendar.autoupdatingCurrent.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
    }

    private func minute(_ date: Date) -> Int {
        let calendar = Calendar.autoupdatingCurrent
        return calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}

private enum ScheduleImportWeekday: Int, CaseIterable, Identifiable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sunday: return "周日"
        case .monday: return "周一"
        case .tuesday: return "周二"
        case .wednesday: return "周三"
        case .thursday: return "周四"
        case .friday: return "周五"
        case .saturday: return "周六"
        }
    }
}

private struct CameraImagePicker: UIViewControllerRepresentable {
    let completion: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (UIImage) -> Void
        init(completion: @escaping (UIImage) -> Void) { self.completion = completion }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { completion(image) }
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
    }
}
