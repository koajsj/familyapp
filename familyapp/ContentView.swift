//
//  ContentView.swift
//  familyapp
//
//  Created by wyc on 2026/9/18.
//

import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation
import MapKit
import Observation

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        Group { if env.session.currentMemberID == nil { LoginView() } else { MainTabsView() } }
            .task { env.bootstrap() }
            .alert("提示", isPresented: Binding(get: { env.lastError != nil }, set: { if !$0 { env.lastError = nil } })) { Button("好", role: .cancel) { env.lastError = nil } } message: { Text(env.lastError ?? "") }
    }
}

private struct LoginView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var member: MemberID = .sendai; @State private var password = ""; @State private var error = false
    var body: some View { NavigationStack { Form {
        Section("成员") { Picker("选择成员", selection: $member) { ForEach(MemberID.allCases) { Text($0.rawValue).tag($0) } }.accessibilityLabel("选择家庭成员") }
        Section("密码") { SecureField("固定密码", text: $password).textContentType(.password); if error { Text("密码不正确，请重试。").foregroundStyle(.red) } }
        Section { Button("登录") { if !env.session.login(member: member, password: password) { error = true } }.frame(maxWidth: .infinity) }
        Section { Text("本地 Demo 使用已确认的共享密码，不将其作为强安全边界。 ").font(.footnote).foregroundStyle(.secondary) }
    }.navigationTitle("家庭协作") } }
}

private struct MainTabsView: View {
    var body: some View { TabView {
        ChatView().tabItem { Label("聊天", systemImage: "message") }
        AgendaView().tabItem { Label("日程", systemImage: "calendar") }
        ScheduleView().tabItem { Label("课表", systemImage: "calendar.badge.clock") }
        FamilyMapView().tabItem { Label("地图", systemImage: "map") }
        MoreView().tabItem { Label("更多", systemImage: "ellipsis.circle") }
    } }
}

struct MemberLabel: View {
    let memberID: String
    @Query private var profiles: [MemberProfile]
    private var profile: MemberProfile? { profiles.first { $0.memberID == memberID } }
    var body: some View { HStack(spacing: 5) { Image(systemName: profile?.avatarSymbol ?? "person.crop.circle.fill").foregroundStyle((MemberID(rawValue: memberID) ?? .sendai).color); Text(profile?.nickname ?? memberID) }.accessibilityLabel("\(profile?.nickname ?? memberID)（\(memberID)）") }
}

private struct ChatView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \ChatMessageModel.sentAt) private var messages: [ChatMessageModel]
    @State private var text = ""; @State private var pickerItem: PhotosPickerItem?; @State private var playback = AudioPlaybackState(); @State private var recorder = VoiceRecorder(); @State private var replyTo: ChatMessageModel?; @State private var imagePreview: ChatMessageModel?
    private var latestOutgoingID: UUID? { messages.last(where: { $0.senderID == env.session.currentMemberID })?.id }
    private var firstUnreadID: UUID? { messages.first(where: { $0.isUnread })?.id }
    var body: some View { NavigationStack { ScrollViewReader { proxy in
        ScrollView {
            ChatMessageList(messages: messages, firstUnreadID: firstUnreadID, latestOutgoingID: latestOutgoingID, playback: playback, previewImage: { imagePreview = $0 }, reply: { replyTo = $0 }, recall: recall, retry: retry)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle("家庭群聊")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Text("Demo simulated").font(.caption).foregroundStyle(.secondary) } }
        .task { markIncomingMessagesRead(); scrollToBottom(proxy, animated: false) }
        .onAppear { recorder.onFinished = finishRecording }
        .onChange(of: messages.map(\.id)) { _, _ in scrollToBottom(proxy, animated: true) }
        .onChange(of: pickerItem) { _, item in Task { do { guard let data = try await item?.loadTransferable(type: Data.self) else { return }; let path = try env.mediaStore.storeImage(data); env.send(ChatMessageModel(senderID: env.session.currentMemberID ?? "Sendai", body: "图片", kind: .image, status: .sending, mediaPath: path, replyToID: replyTo?.id)); replyTo = nil } catch { env.lastError = "无法处理图片：\(error.localizedDescription)" } } }
    } }
    .sheet(item: $imagePreview) { message in FullscreenChatImage(message: message) }
    }
    private var composer: some View { VStack(spacing: 7) {
        if let replyTo { HStack(spacing: 8) { Image(systemName: "arrowshape.turn.up.left.fill").foregroundStyle(.secondary); Text("回复 \(replySummary(replyTo))").lineLimit(1); Spacer(); Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { self.replyTo = nil } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("取消引用回复") }.font(.footnote).padding(.horizontal, 14).transition(.move(edge: .bottom).combined(with: .opacity)) }
        HStack(spacing: 8) { PhotosPicker(selection: $pickerItem, matching: .images) { Image(systemName: "photo").font(.title3).frame(width: 32, height: 36) }.accessibilityLabel("选择图片")
            TextField("消息", text: $text, axis: .vertical).lineLimit(1...5).padding(.horizontal, 12).padding(.vertical, 8).background(Color.secondary.opacity(0.12), in: Capsule())
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Button { toggleRecording() } label: { Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill").font(.body.weight(.semibold)).frame(width: 34, height: 34).foregroundStyle(recorder.isRecording ? .red : .secondary) }.accessibilityLabel(recorder.isRecording ? "结束录音" : "录制语音").transition(.opacity) }
            else { Button { sendText() } label: { Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white).frame(width: 34, height: 34).background(Color.accentColor, in: Circle()) }.accessibilityLabel("发送消息").transition(.scale.combined(with: .opacity)) }
        }.padding(.horizontal, 10).padding(.bottom, 7)
    }.padding(.top, 7).background(.bar).animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: text.isEmpty).animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: replyTo?.id) }
    private func sendText() { let value = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty else { return }; env.send(ChatMessageModel(senderID: env.session.currentMemberID ?? "Sendai", body: value, kind: .text, status: .sending, replyToID: replyTo?.id)); text = ""; replyTo = nil }
    private func recall(_ message: ChatMessageModel) { do { try env.chatRepository.recall(message, by: env.session.currentMemberID ?? "", now: .now); env.refreshToken = UUID() } catch { env.lastError = error.localizedDescription } }
    private func retry(_ message: ChatMessageModel) { do { try env.chatRepository.retry(message, by: env.session.currentMemberID ?? ""); env.chatTransport.simulateReceipts(for: message) } catch { env.lastError = error.localizedDescription } }
    private func toggleRecording() { recorder.isRecording ? recorder.stop() : recorder.start() }
    private func finishRecording(_ url: URL, _ succeeded: Bool) { defer { do { try FileManager.default.removeItem(at: url) } catch { env.lastError = error.localizedDescription } }; guard succeeded else { env.lastError = "录音没有成功保存。"; return }; do { let path = try env.mediaStore.storeAudio(from: url); env.send(ChatMessageModel(senderID: env.session.currentMemberID ?? "Sendai", body: "语音消息", kind: .audio, status: .sending, mediaPath: path, replyToID: replyTo?.id)); replyTo = nil } catch { env.lastError = "无法保存录音：\(error.localizedDescription)" } }
    private func markIncomingMessagesRead() { do { try env.chatRepository.markIncomingMessagesRead(by: env.session.currentMemberID ?? "") } catch { env.lastError = error.localizedDescription } }
    private func replySummary(_ source: ChatMessageModel) -> String { source.kind == .recalled ? "该消息已撤回" : source.kind == .image ? "图片" : source.kind == .audio ? "语音消息" : source.body }
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) { let action = { proxy.scrollTo("chat-bottom", anchor: .bottom) }; if animated && !reduceMotion { withAnimation(.spring(response: 0.32, dampingFraction: 0.9), action) } else { action() } }
}

private struct ChatMessageList: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let messages: [ChatMessageModel]
    let firstUnreadID: UUID?
    let latestOutgoingID: UUID?
    let playback: AudioPlaybackState
    let previewImage: (ChatMessageModel) -> Void
    let reply: (ChatMessageModel) -> Void
    let recall: (ChatMessageModel) -> Void
    let retry: (ChatMessageModel) -> Void
    var body: some View {
        LazyVStack(spacing: 4) {
            ForEach(messages) { message in
                if message.id == firstUnreadID { Text("以下为新消息").font(.footnote.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 8) }
                MessageRow(message: message, messages: messages, showsSender: shouldShowSender(for: message), showsStatus: message.id == latestOutgoingID, playback: playback, previewImage: { previewImage(message) }, reply: { reply(message) }, recall: { recall(message) }, retry: { retry(message) })
                    .id(message.id)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            Color.clear.frame(height: 1).id("chat-bottom")
        }
    }
    private func shouldShowSender(for message: ChatMessageModel) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == message.id }), index > 0 else { return true }
        return messages[index - 1].senderID != message.senderID
    }
}

private struct MessageRow: View {
    @Environment(AppEnvironment.self) private var env
    let message: ChatMessageModel; let messages: [ChatMessageModel]; let showsSender: Bool; let showsStatus: Bool; let playback: AudioPlaybackState; let previewImage: () -> Void; let reply: () -> Void; let recall: () -> Void; let retry: () -> Void
    var isMine: Bool { message.senderID == env.session.currentMemberID }
    var body: some View { HStack(alignment: .bottom) { if isMine { Spacer(minLength: 44) }; VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
        if !isMine && showsSender { MemberLabel(memberID: message.senderID).font(.caption2).foregroundStyle(.secondary).padding(.leading, 4).padding(.top, 5) }
        VStack(alignment: .leading, spacing: 5) { if let id = message.replyToID { HStack(spacing: 4) { Rectangle().fill(isMine ? Color.white.opacity(0.7) : Color.accentColor).frame(width: 2); Text(messages.first(where: { $0.id == id }).map(replySummary) ?? "原消息已不可用").lineLimit(1) }.font(.caption2).foregroundStyle(isMine ? .white.opacity(0.85) : .secondary) }
            messageContent
        }.padding(message.kind == .image ? 0 : 9).background(message.kind == .image ? Color.clear : (isMine ? Color.accentColor : Color.secondary.opacity(0.14)), in: RoundedRectangle(cornerRadius: 18, style: .continuous)).foregroundStyle(isMine && message.kind != .image ? .white : .primary)
        if showsStatus && isMine { Text(statusText).font(.caption2).foregroundStyle(message.status == .failed ? .red : .secondary).padding(.trailing, 4) }
    }.frame(maxWidth: UIScreen.main.bounds.width * 0.74, alignment: isMine ? .trailing : .leading); if !isMine { Spacer(minLength: 44) } }
    .contextMenu { Button("引用回复", action: reply); if isMine && message.status == .failed { Button("重试发送", action: retry) }; if isMine && message.kind != .recalled && Calendar.autoupdatingCurrent.dateComponents([.minute], from: message.sentAt, to: .now).minute ?? 6 <= 5 { Button("撤回", role: .destructive, action: recall) } }
    }
    @ViewBuilder private var messageContent: some View { switch message.kind { case .image: if let image = image { Button(action: previewImage) { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 230, maxHeight: 190).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) }.buttonStyle(.plain).accessibilityLabel("全屏查看图片消息") } else { Label("图片不可用", systemImage: "photo") }; case .audio: Button { guard let path = message.mediaPath else { return }; do { try playback.toggle(messageID: message.id, url: env.mediaStore.url(for: path)) } catch { env.lastError = "语音不可播放：\(error.localizedDescription)" } } label: { VStack(alignment: .leading, spacing: 4) { Label(audioLabel, systemImage: playback.isPlaying(message.id) ? "pause.circle.fill" : "play.circle.fill"); ProgressView(value: playback.progress(for: message.id)).frame(width: 150) } }; default: Text(message.body).textSelection(.enabled) } }
    private func replySummary(_ source: ChatMessageModel) -> String { source.kind == .recalled ? "该消息已撤回" : source.kind == .image ? "图片" : source.kind == .audio ? "语音消息" : source.body }
    private var image: UIImage? { guard let path = message.mediaPath else { return nil }; do { return UIImage(data: try Data(contentsOf: env.mediaStore.url(for: path))) } catch { return nil } }
    private var audioLabel: String { guard let path = message.mediaPath else { return "语音不可用" }; do { let duration = try playback.duration(for: message.id, url: env.mediaStore.url(for: path)); return "\(playback.isPlaying(message.id) ? "暂停" : "播放")语音 · \(Int(duration.rounded())) 秒" } catch { return "语音不可用" } }
    private var statusText: String { switch message.status { case .sending: return "发送中"; case .sent: return "已发送"; case .delivered: return "已送达"; case .read: return "已读"; case .failed: return "发送失败" } }
}

private struct FullscreenChatImage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    let message: ChatMessageModel
    var body: some View { NavigationStack { Group { if let path = message.mediaPath, let data = try? Data(contentsOf: env.mediaStore.url(for: path)), let image = UIImage(data: data) { ZoomableImage(image: image) } else { ContentUnavailableView("图片不可用", systemImage: "photo") } }.navigationTitle("图片").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } } } }
}

private struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    var body: some View { Image(uiImage: image).resizable().scaledToFit().scaleEffect(scale).gesture(MagnifyGesture().onChanged { scale = min(4, max(1, $0.magnification)) }.onEnded { _ in if scale < 1.05 { scale = 1 } }).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black) }
}

@MainActor @Observable private final class AudioPlaybackState: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private(set) var activeMessageID: UUID?
    private(set) var playbackProgress: [UUID: Double] = [:]
    func toggle(messageID: UUID, url: URL) throws {
        if activeMessageID == messageID, player?.isPlaying == true { player?.pause(); timer?.invalidate(); return }
        player?.stop(); timer?.invalidate()
        let next = try AVAudioPlayer(contentsOf: url)
        next.delegate = self; next.prepareToPlay(); next.play()
        player = next; activeMessageID = messageID; playbackProgress[messageID] = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateProgress() } }
    }
    func isPlaying(_ messageID: UUID) -> Bool { activeMessageID == messageID && player?.isPlaying == true }
    func progress(for messageID: UUID) -> Double { playbackProgress[messageID] ?? 0 }
    func duration(for messageID: UUID, url: URL) throws -> TimeInterval { if activeMessageID == messageID, let player { return player.duration }; return try AVAudioPlayer(contentsOf: url).duration }
    private func updateProgress() { guard let player, let id = activeMessageID, player.duration > 0 else { return }; playbackProgress[id] = player.currentTime / player.duration }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { Task { @MainActor [weak self] in self?.finish() } }
    private func finish() { if let id = activeMessageID { playbackProgress[id] = 1 }; timer?.invalidate(); timer = nil; player = nil; activeMessageID = nil }
}

@MainActor @Observable private final class VoiceRecorder: NSObject, AVAudioRecorderDelegate, @unchecked Sendable { var isRecording = false; private var recorder: AVAudioRecorder?; private var url: URL?; var onFinished: ((URL, Bool) -> Void)?
    func start() { if #available(iOS 17.0, *) { AVAudioApplication.requestRecordPermission { [weak self] granted in guard granted else { return }; Task { @MainActor [weak self] in self?.begin() } } } else { AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in guard granted else { return }; Task { @MainActor [weak self] in self?.begin() } } } }
    private func begin() { let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a"); do { try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default); try AVAudioSession.sharedInstance().setActive(true); recorder = try AVAudioRecorder(url: target, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]); recorder?.delegate = self; recorder?.record(forDuration: 300); url = target; isRecording = true } catch { isRecording = false } }
    func stop() { recorder?.stop() }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) { Task { @MainActor [weak self] in self?.finish(successfully: flag) } }
    private func finish(successfully: Bool) { guard let url else { return }; recorder = nil; self.url = nil; isRecording = false; onFinished?(url, successfully) }
}

private struct AgendaView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \AgendaItemModel.start) private var items: [AgendaItemModel]
    @State private var presentingEditor = false
    var body: some View { NavigationStack { List {
        ForEach(items) { item in
            NavigationLink { AgendaEditor(item: item) } label: { AgendaRow(item: item) }
                .swipeActions {
                    if item.creatorID == env.session.currentMemberID {
                        Button("删除", role: .destructive) {
                            do { try env.agendaRepository.delete(item, by: env.session.currentMemberID ?? "") }
                            catch { env.lastError = error.localizedDescription }
                        }
                    }
                }
        }
    }
        .navigationTitle("日程").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { presentingEditor = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建日程") } }.sheet(isPresented: $presentingEditor) { NavigationStack { AgendaEditor(item: nil) } }
    } }
}
private struct AgendaRow: View { @Environment(AppEnvironment.self) private var env; let item: AgendaItemModel
    var body: some View { HStack { Image(systemName: symbol).foregroundStyle(item.kind == .exam ? .red : .blue).frame(width: 28); VStack(alignment: .leading) { Text(item.title); if let start = item.start, let end = item.end { Text("\(FamilyFormatters.dateTime.string(from: start)) – \(FamilyFormatters.time.string(from: end))").font(.caption).foregroundStyle(.secondary) } else if let due = item.dueAt { Text("截止：\(FamilyFormatters.dateTime.string(from: due)) · \(deadlineState)").font(.caption).foregroundStyle(.secondary) } else if let dishes = item.dishes { HStack(spacing: 4) { Image(systemName: FoodIconResolver().symbol(for: dishes)); Text(dishes).lineLimit(1) }.font(.caption).foregroundStyle(.secondary) } }; Spacer(); VStack(alignment: .trailing) { Text(item.kind.localizedName).font(.caption2).foregroundStyle(.secondary); if item.kind == .orderFood { Text("已读 \(item.foodReadReceipts.count)/\(item.participantIDs.count)").font(.caption2).foregroundStyle(.secondary) } } } .accessibilityLabel("\(item.kind.localizedName)：\(item.title)").contextMenu { if item.kind == .orderFood { Button("标记已读") { do { try env.agendaRepository.markFoodRead(item, by: env.session.currentMemberID ?? "") } catch { env.lastError = error.localizedDescription } } }; if item.kind == .assignmentDeadline { Button("标记完成") { do { try env.agendaRepository.setCompletion(item, state: .completed, by: env.session.currentMemberID ?? "") } catch { env.lastError = error.localizedDescription } } } } }
    private var deadlineState: String { if item.completionRaw == CompletionState.completed.rawValue { return "已完成" }; if item.completionRaw == CompletionState.overdue.rawValue || (item.dueAt ?? .distantFuture) < .now { return "已逾期" }; return "待完成" }
    private var symbol: String { switch item.kind { case .normal: return "calendar"; case .exam: return "pencil"; case .assignmentDeadline: return "checklist"; case .orderFood: return "fork.knife" } }
}
struct AgendaEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    let item: AgendaItemModel?
    let proposedSlot: AvailabilitySlot?
    @State private var title = ""; @State private var kind: AgendaKind = .normal; @State private var start = Date(); @State private var end = Date().addingTimeInterval(3600); @State private var participants: Set<String> = ["Sendai"]; @State private var location = ""; @State private var note = ""; @State private var recurrence: AgendaRecurrence = .none; @State private var recurrenceEnd = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 7, to: .now) ?? .now; @State private var dishes = ""; @State private var ingredients = ""; @State private var seasonings = ""; @State private var arrival = Date(); @State private var mealTime = Date().addingTimeInterval(3600); @State private var preparation: PreparationState = .waiting; @State private var completion: CompletionState = .pending; @State private var error: String?; @State private var confirmDelete = false
    init(item: AgendaItemModel?, proposedSlot: AvailabilitySlot? = nil) { self.item = item; self.proposedSlot = proposedSlot }
    private var canEdit: Bool { item == nil || item?.creatorID == env.session.currentMemberID }
    var body: some View {
        Form {
            if !canEdit { Text("仅创建者可以编辑或删除此日程。 ").font(.caption).foregroundStyle(.secondary) }
            Section {
                TextField("标题", text: $title).disabled(!canEdit)
                Picker("类型", selection: $kind) { ForEach(AgendaKind.allCases, id: \.self) { Text($0.localizedName).tag($0) } }.disabled(!canEdit)
                if kind == .normal || kind == .exam { DatePicker("开始", selection: $start).disabled(!canEdit); DatePicker("结束", selection: $end).disabled(!canEdit); Picker("重复", selection: $recurrence) { ForEach(AgendaRecurrence.allCases, id: \.self) { Text($0.localizedName).tag($0) } }.disabled(!canEdit); if recurrence != .none { DatePicker("重复结束", selection: $recurrenceEnd, in: start..., displayedComponents: .date).disabled(!canEdit) } }
                else if kind == .assignmentDeadline { DatePicker("截止", selection: $end).disabled(!canEdit); Picker("状态", selection: $completion) { Text("待完成").tag(CompletionState.pending); Text("已完成").tag(CompletionState.completed); Text("已逾期").tag(CompletionState.overdue) }.disabled(!canEdit) }
                else { TextField("菜品（用顿号或逗号分隔）", text: $dishes).disabled(!canEdit); TextField("食材", text: $ingredients).disabled(!canEdit); TextField("调料", text: $seasonings).disabled(!canEdit); DatePicker("到家时间", selection: $arrival).disabled(!canEdit); DatePicker("吃饭时间", selection: $mealTime).disabled(!canEdit); Picker("状态", selection: $preparation) { Text(PreparationState.waiting.localizedName).tag(PreparationState.waiting); Text(PreparationState.preparing.localizedName).tag(PreparationState.preparing) }.disabled(!canEdit) }
                TextField("地点（可选）", text: $location).disabled(!canEdit); TextField("备注（可选）", text: $note, axis: .vertical).disabled(!canEdit)
            }
            Section("参与成员") { ForEach(MemberID.allCases) { member in Toggle(member.rawValue, isOn: Binding(get: { participants.contains(member.rawValue) }, set: { enabled in if enabled { participants.insert(member.rawValue) } else { participants.remove(member.rawValue) } })).disabled(!canEdit) } }
            if kind == .orderFood, let item { Section("点菜状态") { ForEach(MemberID.allCases.filter { item.participantIDs.contains($0.rawValue) }) { member in let receipt = item.foodReadReceipts.first(where: { $0.memberID == member.rawValue }); HStack { MemberLabel(memberID: member.rawValue); Spacer(); Text(receipt.map { FamilyFormatters.dateTime.string(from: $0.readAt) } ?? "未读").font(.caption).foregroundStyle(receipt == nil ? .secondary : .primary) } } } }
            if let item, item.recurrence != .none { Section("周期例外") { NavigationLink("查看和管理例外") { AgendaExceptionList(item: item) } } }
            if canEdit { BusinessAIAssistButton(title: "AI 生成日程草稿", instruction: "Draft an agenda title and concise notes from natural language. Return plain text only; do not invent a saved action.", source: "\(title) \(note)") { note = $0 } }
        }
        .navigationTitle(item == nil ? "新建日程" : "日程详情")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(!canEdit || title.trimmingCharacters(in: .whitespaces).isEmpty) }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; if item != nil && canEdit { ToolbarItem(placement: .bottomBar) { Button("删除", role: .destructive) { confirmDelete = true } } } }
        .onAppear(perform: load)
        .confirmationDialog("删除日程？", isPresented: $confirmDelete, titleVisibility: .visible) { Button("删除", role: .destructive, action: delete) }
        .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
    }
    private func load() { guard let item else { if let proposedSlot { start = proposedSlot.start; end = proposedSlot.end; participants = Set(proposedSlot.participants) } else { participants = [env.session.currentMemberID ?? "Sendai"] }; return }; title = item.title; kind = item.kind; start = item.start ?? .now; end = item.end ?? item.dueAt ?? .now; participants = Set(item.participantIDs); location = item.location ?? ""; note = item.note ?? ""; recurrence = item.recurrence; recurrenceEnd = item.recurrenceEnd ?? recurrenceEnd; dishes = item.dishes ?? ""; ingredients = item.ingredients ?? ""; seasonings = item.seasonings ?? ""; arrival = item.estimatedArrival ?? .now; mealTime = item.desiredMealTime ?? .now; preparation = PreparationState(rawValue: item.preparationRaw ?? "") ?? .waiting; completion = CompletionState(rawValue: item.completionRaw ?? "") ?? .pending }
    private func save() { guard (kind != .normal && kind != .exam) || start < end else { error = "结束时间必须晚于开始时间。"; return }; let member = env.session.currentMemberID ?? ""; let value = item ?? AgendaItemModel(creatorID: member, title: title, kind: kind, participantIDs: Array(participants)); let draft = AgendaDraft(title: title, kind: kind, start: (kind == .normal || kind == .exam) ? start : nil, end: (kind == .normal || kind == .exam) ? end : nil, dueAt: kind == .assignmentDeadline ? end : nil, location: location.isEmpty ? nil : location, note: note.isEmpty ? nil : note, participantIDs: Array(participants), recurrence: recurrence, recurrenceEnd: recurrence == .none ? nil : recurrenceEnd, dishes: kind == .orderFood ? dishes : nil, ingredients: kind == .orderFood ? ingredients : nil, seasonings: kind == .orderFood ? seasonings : nil, peopleCount: kind == .orderFood ? participants.count : nil, estimatedArrival: kind == .orderFood ? arrival : nil, desiredMealTime: kind == .orderFood ? mealTime : nil, preparation: kind == .orderFood ? preparation : nil, completion: kind == .assignmentDeadline ? completion : nil); do { try env.agendaRepository.save(value, draft: draft, by: member); dismiss() } catch { self.error = error.localizedDescription } }
    private func delete() { guard let item else { return }; do { try env.agendaRepository.delete(item, by: env.session.currentMemberID ?? ""); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct AgendaExceptionList: View {
    @Environment(AppEnvironment.self) private var env
    @Query private var exceptions: [AgendaExceptionModel]
    let item: AgendaItemModel
    @State private var editing: AgendaExceptionModel?
    @State private var showingNew = false
    @State private var confirmDelete: AgendaExceptionModel?
    private var rules: [AgendaExceptionModel] { exceptions.filter { $0.agendaID == item.id }.sorted { $0.occurrenceDate < $1.occurrenceDate } }
    private var canEdit: Bool { item.creatorID == env.session.currentMemberID }
    var body: some View { List { if rules.isEmpty { ContentUnavailableView("没有周期例外", systemImage: "calendar.badge.clock", description: Text("可以为某次或后续重复日程添加取消、改期或临时修改。")) } else { ForEach(rules) { rule in Button { editing = rule } label: { VStack(alignment: .leading, spacing: 3) { Text("\(kindTitle(rule.kind)) · \(scopeTitle(rule.scope))"); Text(FamilyFormatters.day.string(from: rule.occurrenceDate)).font(.caption).foregroundStyle(.secondary); if let date = rule.replacementStart { Text("调整至 \(FamilyFormatters.dateTime.string(from: date))").font(.caption).foregroundStyle(.secondary) } } }.foregroundStyle(.primary).swipeActions { if canEdit { Button("删除", role: .destructive) { confirmDelete = rule } } } } } }.navigationTitle("日程例外").toolbar { if canEdit { ToolbarItem(placement: .topBarTrailing) { Button { showingNew = true } label: { Image(systemName: "plus") } } } }.sheet(isPresented: $showingNew) { NavigationStack { AgendaExceptionEditor(item: item) } }.sheet(item: $editing) { rule in NavigationStack { AgendaExceptionEditor(item: item, exception: rule) } }.confirmationDialog("删除此例外规则？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) { Button("删除", role: .destructive) { guard let rule = confirmDelete else { return }; do { try env.agendaRepository.delete(exception: rule, for: item, by: env.session.currentMemberID ?? "") } catch { env.lastError = error.localizedDescription }; confirmDelete = nil } } }
    private func kindTitle(_ value: ExceptionKind) -> String { switch value { case .cancelled: return "取消"; case .rescheduled: return "改期"; case .modified: return "临时修改" } }
    private func scopeTitle(_ value: ExceptionScope) -> String { switch value { case .thisOccurrence: return "仅本次"; case .thisAndFuture: return "本次及以后"; case .entireSeries: return "整个系列" } }
}

private struct AgendaExceptionEditor: View {
    @Environment(\.dismiss) private var dismiss; @Environment(AppEnvironment.self) private var env
    let item: AgendaItemModel; let exception: AgendaExceptionModel?
    @State private var kind: ExceptionKind = .cancelled; @State private var scope: ExceptionScope = .thisOccurrence; @State private var occurrence = Date(); @State private var replacementStart = Date(); @State private var replacementEnd = Date().addingTimeInterval(3600); @State private var error: String?
    init(item: AgendaItemModel, exception: AgendaExceptionModel? = nil) { self.item = item; self.exception = exception }
    private var canEdit: Bool { item.creatorID == env.session.currentMemberID }
    var body: some View { Form { if !canEdit { Text("仅创建者可以修改例外规则。 ").font(.caption).foregroundStyle(.secondary) }; Picker("操作", selection: $kind) { Text("取消本次").tag(ExceptionKind.cancelled); Text("改期").tag(ExceptionKind.rescheduled); Text("临时修改").tag(ExceptionKind.modified) }.disabled(!canEdit); Picker("范围", selection: $scope) { Text("仅本次").tag(ExceptionScope.thisOccurrence); Text("本次及以后").tag(ExceptionScope.thisAndFuture); Text("整个系列").tag(ExceptionScope.entireSeries) }.disabled(!canEdit); DatePicker("发生日期", selection: $occurrence, in: (item.start ?? .distantPast)...(item.recurrenceEnd ?? .distantFuture), displayedComponents: .date).disabled(!canEdit); if kind != .cancelled { DatePicker("新开始", selection: $replacementStart).disabled(!canEdit); DatePicker("新结束", selection: $replacementEnd).disabled(!canEdit) } }.navigationTitle(exception == nil ? "新增日程例外" : "编辑日程例外").toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(!canEdit) }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }.onAppear(perform: load).alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") } }
    private func load() { guard let exception else { occurrence = item.start ?? .now; replacementStart = occurrence; replacementEnd = occurrence.addingTimeInterval((item.end ?? occurrence.addingTimeInterval(3600)).timeIntervalSince(item.start ?? occurrence)); return }; kind = exception.kind; scope = exception.scope; occurrence = exception.occurrenceDate; replacementStart = exception.replacementStart ?? occurrence; replacementEnd = exception.replacementEnd ?? replacementStart.addingTimeInterval(3600) }
    private func save() { guard kind == .cancelled || replacementStart < replacementEnd else { error = "结束时间必须晚于开始时间。"; return }; let rule = exception ?? AgendaExceptionModel(agendaID: item.id, kind: kind, scope: scope, occurrenceDate: occurrence); rule.kindRaw = kind.rawValue; rule.scopeRaw = scope.rawValue; rule.occurrenceDate = occurrence; rule.replacementDate = kind == .cancelled ? nil : replacementStart; rule.replacementStart = kind == .cancelled ? nil : replacementStart; rule.replacementEnd = kind == .cancelled ? nil : replacementEnd; do { try env.agendaRepository.save(exception: rule, for: item, by: env.session.currentMemberID ?? ""); dismiss() } catch { self.error = error.localizedDescription } }
}
