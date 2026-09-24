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
import Observation
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        Group { if env.session.currentMemberID == nil { LoginView() } else { MainTabsView() } }
            .task { env.bootstrap() }
            .onChange(of: env.session.currentMemberID) { _, _ in env.refreshLocationSharing() }
            .alert("提示", isPresented: Binding(get: { env.lastError != nil }, set: { if !$0 { env.lastError = nil } })) { Button("好", role: .cancel) { env.lastError = nil } } message: { Text(env.lastError ?? "") }
    }
}

private struct LoginView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var identifier = ""
    @State private var password = ""
    @State private var error = false
    @State private var isLoggingIn = false
    @State private var remoteAccountMessage: String?

    var body: some View { NavigationStack { Form {
        Section("账号") {
            TextField("账号/昵称", text: $identifier)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        Section("密码") {
            SecureField("密码", text: $password).textContentType(.password)
            if error { Text("账号或密码不正确，请重试。").foregroundStyle(.red) }
        }
        Section { Button("登录") {
            if env.isRemoteLogin {
                Task { @MainActor in
                    isLoggingIn = true
                    defer { isLoggingIn = false }
                    do { try await env.loginRemote(identifier: identifier, password: password); error = false; password = "" }
                    catch is CancellationError { }
                    catch { env.lastError = error.localizedDescription }
                }
            } else {
                do { error = !(try env.session.login(identifier: identifier, password: password, in: env.context)) }
                catch { env.lastError = error.localizedDescription }
            }
        }.frame(maxWidth: .infinity).disabled(isLoggingIn) }
        Section {
            Text("没有账号？").font(.footnote).foregroundStyle(.secondary)
            if let registrationFlow = env.registrationFlow {
                NavigationLink { RegistrationStartView(flow: registrationFlow) } label: {
                    Label("申请加入家庭", systemImage: "person.badge.plus")
                }
                NavigationLink { StoredRegistrationView(flow: registrationFlow) } label: {
                    Label("查看加入申请", systemImage: "person.badge.clock")
                }
            } else {
                Button { remoteAccountMessage = "当前为本地使用模式，申请加入会在远端家庭服务启用后可用。" } label: {
                    Label("申请加入家庭", systemImage: "person.badge.plus")
                }
            }
        }
        Section {
            Text("忘记密码？").font(.footnote).foregroundStyle(.secondary)
            if let recoveryFlow = env.recoveryFlow {
                NavigationLink { RecoveryStartView(flow: recoveryFlow) } label: {
                    Label("使用恢复助记词", systemImage: "key.horizontal")
                }
            } else {
                Button { remoteAccountMessage = "当前为本地使用模式，恢复助记词仅用于未来远端账户恢复。" } label: {
                    Label("使用恢复助记词", systemImage: "key.horizontal")
                }
            }
        }
        if !env.isRemoteLogin {
            Section { Text("当前为本地使用模式，共享密码仅用于家庭成员确认。 ").font(.footnote).foregroundStyle(.secondary) }
        }
    }
        .navigationTitle("家庭协作")
        .alert("账户服务", isPresented: Binding(get: { remoteAccountMessage != nil }, set: { if !$0 { remoteAccountMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(remoteAccountMessage ?? "")
        }
    } }
}

private struct MainTabsView: View {
    @AppStorage(FamilyIntentRoute.storageKey) private var pendingRoute = ""
    @State private var selectedTab = 0
    @State private var showingNewAgenda = false
    @State private var scheduleRoute: FamilyIntentRoute?
    @State private var mapRoute: FamilyIntentRoute?

    var body: some View {
        TabView(selection: $selectedTab) {
            FamilyCenterView(routedScheduleIntent: $scheduleRoute).tabItem { Label("家庭", systemImage: "house") }.tag(0)
            ChatView().tabItem { Label("议事堂", systemImage: "message") }.tag(1)
            AgendaView().tabItem { Label("日程", systemImage: "calendar") }.tag(2)
            FamilyMapView(routedIntent: $mapRoute).tabItem { Label("地图", systemImage: "map") }.tag(3)
            MoreView().tabItem { Label("更多", systemImage: "ellipsis.circle") }.tag(4)
        }
        .onAppear(perform: routeIntent)
        .onChange(of: pendingRoute) { _, _ in routeIntent() }
        .sheet(isPresented: $showingNewAgenda) { NavigationStack { AgendaEditor(item: nil) } }
    }

    private func routeIntent() {
        guard let route = FamilyIntentRoute(rawValue: pendingRoute) else {
            if !pendingRoute.isEmpty { pendingRoute = "" }
            return
        }
        switch route {
        case .todayTimetable, .commonFree:
            selectedTab = 0
            scheduleRoute = route
            pendingRoute = ""
        case .newAgenda:
            selectedTab = 2
            showingNewAgenda = true
            pendingRoute = ""
        case .reportLocation, .reportSafety:
            selectedTab = 3
            mapRoute = route
            pendingRoute = ""
        }
    }
}

struct MemberLabel: View {
    let memberID: String
    @Query private var profiles: [MemberProfile]
    private var profile: MemberProfile? { profiles.first { $0.memberID == memberID } }
    var body: some View { HStack(spacing: 5) { Image(systemName: profile?.avatarSymbol ?? "person.crop.circle.fill").foregroundStyle(MemberIdentity.color(for: memberID)); Text(profile?.displayName ?? memberID) }.accessibilityLabel("\(profile?.displayName ?? memberID)（\(memberID)）") }
}

struct MemberAvatar: View {
    let memberID: String
    var size: CGFloat = 28
    @Query private var profiles: [MemberProfile]
    private var profile: MemberProfile? { profiles.first { $0.memberID == memberID } }

    var body: some View {
        Image(systemName: profile?.avatarSymbol ?? "person.fill")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(MemberIdentity.color(for: memberID), in: Circle())
            .accessibilityHidden(true)
    }
}

struct MemberChip: View {
    let memberID: String
    let isSelected: Bool
    @Query private var profiles: [MemberProfile]
    private var displayName: String { profiles.first(where: { $0.memberID == memberID })?.displayName ?? memberID }

    var body: some View {
        HStack(spacing: 5) {
            MemberAvatar(memberID: memberID, size: 20)
            Text(displayName).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
        .background(isSelected ? MemberIdentity.color(for: memberID).opacity(0.16) : Color.secondary.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(isSelected ? MemberIdentity.color(for: memberID).opacity(0.45) : .clear, lineWidth: 0.8))
    }
}

private struct ChatView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var profiles: [MemberProfile]
    @Query(sort: \ChatMessageModel.sentAt) private var messages: [ChatMessageModel]
    @State private var text = ""; @State private var pickerItem: PhotosPickerItem?; @State private var playback = AudioPlaybackState(); @State private var recorder = VoiceRecorder(); @State private var replyTo: ChatMessageModel?; @State private var imagePreview: ChatMessageModel?
    @State private var mentions: [UUID: String] = [:]
    @State private var showingAttachments = false
    @State private var showingFileImporter = false
    private static let allowedFileTypes: [UTType] = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "zip"].compactMap { UTType(filenameExtension: $0) }
    private var mentionQuery: String? {
        guard let marker = text.lastIndex(of: "@") else { return nil }
        let tail = String(text[text.index(after: marker)...])
        guard !tail.contains(where: \.isWhitespace) else { return nil }
        return tail
    }
    private var mentionCandidates: [MemberProfile] {
        guard let query = mentionQuery else { return [] }
        return MemberDirectory.activeMembers(from: profiles).filter {
            $0.displayName.localizedCaseInsensitiveContains(query) && $0.stableRemoteID != nil
        }
    }
    private var visibleMessages: [ChatMessageModel] { messages.filter { $0.deletedAt == nil && $0.purgedAt == nil } }
    private var visibleReplyID: UUID? {
        guard let replyTo, replyTo.kind != .recalled,
              visibleMessages.contains(where: { $0.id == replyTo.id }) else { return nil }
        return replyTo.id
    }
    private var latestOutgoingID: UUID? { visibleMessages.last(where: { $0.senderID == env.session.currentMemberID })?.id }
    private var firstUnreadID: UUID? { visibleMessages.first(where: { $0.isUnread })?.id }
    var body: some View { NavigationStack { ScrollViewReader { proxy in
        ScrollView {
            ChatMessageList(messages: visibleMessages, firstUnreadID: firstUnreadID, latestOutgoingID: latestOutgoingID, playback: playback, previewImage: { imagePreview = $0 }, reply: { replyTo = $0 }, recall: recall, delete: deleteMessage, retry: retry, jumpTo: { id in
                if !reduceMotion { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
                else { proxy.scrollTo(id, anchor: .center) }
            })
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle("议事堂")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Text("本地消息").font(.caption).foregroundStyle(.secondary) } }
        .task { markIncomingMessagesRead(); scrollToBottom(proxy, animated: false) }
        .onAppear { recorder.onFinished = finishRecording }
        .onChange(of: visibleMessages.map(\.id)) { _, _ in scrollToBottom(proxy, animated: true) }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { @MainActor [item] in
                await importSelectedImage(item)
            }
        }
    } }
    .sheet(item: $imagePreview) { message in FullscreenChatImage(message: message) }
    .confirmationDialog("添加附件", isPresented: $showingAttachments) {
        Button("照片") { pickerItem = nil; showingPhotoPicker = true }
        Button("文件") { showingFileImporter = true }
    }
    .photosPicker(isPresented: $showingPhotoPicker, selection: $pickerItem, matching: .images)
    .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: Self.allowedFileTypes) { result in
        importFile(result)
    }
    }
    @State private var showingPhotoPicker = false
    private var composer: some View { VStack(spacing: 7) {
        if let replyTo, replyTo.kind != .recalled, visibleMessages.contains(where: { $0.id == replyTo.id }) { HStack(spacing: 8) { Image(systemName: "arrowshape.turn.up.left.fill").foregroundStyle(.secondary); Text("回复 \(replySummary(replyTo))").lineLimit(1); Spacer(); Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { self.replyTo = nil } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("取消引用回复") }.font(.footnote).padding(.horizontal, 14).transition(.move(edge: .bottom).combined(with: .opacity)) }
        if !mentionCandidates.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(mentionCandidates, id: \.memberID) { member in
                        Button { insertMention(member) } label: { MemberChip(memberID: member.memberID, isSelected: false) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("提及 \(member.displayName)")
                    }
                }.padding(.horizontal, 12)
            }.frame(maxHeight: 48)
        }
        HStack(spacing: 8) { Button { showingAttachments = true } label: { Image(systemName: "plus.circle.fill").font(.title3).frame(width: 44, height: 44) }.accessibilityLabel("添加照片或文件")
            TextField("消息", text: $text, axis: .vertical).lineLimit(1...5).padding(.horizontal, 12).padding(.vertical, 8).background(Color.secondary.opacity(0.12), in: Capsule())
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Button { toggleRecording() } label: { Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill").font(.body.weight(.semibold)).frame(width: 44, height: 44).foregroundStyle(recorder.isRecording ? .red : .secondary) }.accessibilityLabel(recorder.isRecording ? "结束录音" : "录制语音").transition(.opacity) }
            else { Button { sendText() } label: { Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white).frame(width: 34, height: 34).background(Color.accentColor, in: Circle()).frame(width: 44, height: 44) }.accessibilityLabel("发送消息").transition(.scale.combined(with: .opacity)) }
        }.padding(.horizontal, 10).padding(.bottom, 7)
    }.padding(.top, 7).background(.bar).animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: text.isEmpty).animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: replyTo?.id) }
    private func sendText() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let memberID = env.session.currentMemberID else { return }
        let selectedIDs = mentions.compactMap { id, name in value.contains("@\(name)") ? id : nil }
        if env.runtimeMode == .remoteSync && !selectedIDs.isEmpty {
            env.lastError = "远端聊天暂不支持成员提及。"
            return
        }
        env.send(ChatMessageModel(senderID: memberID, body: value, kind: .text, status: .sending, replyToID: visibleReplyID, mentionedMemberIDs: selectedIDs.isEmpty ? nil : selectedIDs.sorted { $0.uuidString < $1.uuidString }))
        text = ""; replyTo = nil; mentions.removeAll()
    }
    private func insertMention(_ member: MemberProfile) {
        guard let id = member.stableRemoteID, let marker = text.lastIndex(of: "@") else { return }
        text.replaceSubrange(marker..., with: "@\(member.displayName) ")
        mentions[id] = member.displayName
    }
    private func importFile(_ result: Result<URL, Error>) {
        do {
            let source = try result.get()
            guard let memberID = env.session.currentMemberID else { return }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let path = try env.mediaStore.storeFile(from: source)
            let message = ChatMessageModel(senderID: memberID, body: source.lastPathComponent, kind: .file, status: .sending, mediaPath: path, replyToID: visibleReplyID)
            message.mediaFileName = source.lastPathComponent
            do { try env.chatRepository.create(message) }
            catch {
                let saveDescription = error.localizedDescription
                do { try env.mediaStore.remove(path: path) }
                catch { env.lastError = "发送失败：\(saveDescription)；本地副本清理失败：\(error.localizedDescription)"; return }
                env.lastError = "无法发送文件：\(saveDescription)"
                return
            }
            env.chatTransport.simulateReceipts(for: message)
            env.refreshToken = UUID()
            replyTo = nil
        } catch {
            env.lastError = "无法发送文件：\(error.localizedDescription)"
        }
    }
    private func importSelectedImage(_ item: PhotosPickerItem) async {
        do {
            guard let memberID = env.session.currentMemberID else { return }
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let path = try env.mediaStore.storeImage(data)
            env.send(ChatMessageModel(senderID: memberID, body: "图片", kind: .image, status: .sending, mediaPath: path, replyToID: visibleReplyID))
            replyTo = nil
        } catch {
            env.lastError = "无法处理图片：\(error.localizedDescription)"
        }
    }
    private func recall(_ message: ChatMessageModel) { do { try env.chatRepository.recall(message, by: env.session.currentMemberID ?? "", now: .now); env.refreshToken = UUID() } catch { env.lastError = error.localizedDescription } }
    private func deleteMessage(_ message: ChatMessageModel) { do { try env.chatRepository.delete(message, by: env.session.currentMemberID ?? ""); env.refreshToken = UUID() } catch { env.lastError = error.localizedDescription } }
    private func retry(_ message: ChatMessageModel) { do { try env.chatRepository.retry(message, by: env.session.currentMemberID ?? ""); env.chatTransport.simulateReceipts(for: message) } catch { env.lastError = error.localizedDescription } }
    private func toggleRecording() { recorder.isRecording ? recorder.stop() : recorder.start() }
    private func finishRecording(_ url: URL, _ succeeded: Bool) { defer { do { try FileManager.default.removeItem(at: url) } catch { env.lastError = error.localizedDescription } }; guard succeeded else { env.lastError = "录音没有成功保存。"; return }; guard let memberID = env.session.currentMemberID else { return }; do { let path = try env.mediaStore.storeAudio(from: url); env.send(ChatMessageModel(senderID: memberID, body: "语音消息", kind: .audio, status: .sending, mediaPath: path, replyToID: visibleReplyID)); replyTo = nil } catch { env.lastError = "无法保存录音：\(error.localizedDescription)" } }
    private func markIncomingMessagesRead() { do { try env.chatRepository.markIncomingMessagesRead(by: env.session.currentMemberID ?? "") } catch { env.lastError = error.localizedDescription } }
    private func replySummary(_ source: ChatMessageModel) -> String { source.kind == .image ? "照片" : source.kind == .audio ? "语音" : source.body }
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
    let delete: (ChatMessageModel) -> Void
    let retry: (ChatMessageModel) -> Void
    let jumpTo: (UUID) -> Void
    var body: some View {
        LazyVStack(spacing: 4) {
            ForEach(messages) { message in
                if message.id == firstUnreadID { Text("以下为新消息").font(.footnote.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 8) }
                MessageRow(message: message, messages: messages, showsSender: shouldShowSender(for: message), showsStatus: message.id == latestOutgoingID, playback: playback, previewImage: { previewImage(message) }, reply: { reply(message) }, recall: { recall(message) }, delete: { delete(message) }, retry: { retry(message) }, jumpTo: jumpTo)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var profiles: [MemberProfile]
    let message: ChatMessageModel; let messages: [ChatMessageModel]; let showsSender: Bool; let showsStatus: Bool; let playback: AudioPlaybackState; let previewImage: () -> Void; let reply: () -> Void; let recall: () -> Void; let delete: () -> Void; let retry: () -> Void; let jumpTo: (UUID) -> Void
    @State private var isLoadingRemoteMedia = false
    var isMine: Bool { message.senderID == env.session.currentMemberID }
    var body: some View { HStack(alignment: .bottom) { if isMine { Spacer(minLength: 44) }; VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
        if !isMine && showsSender { MemberLabel(memberID: message.senderID).font(.caption2).foregroundStyle(.secondary).padding(.leading, 4).padding(.top, 5) }
        VStack(alignment: .leading, spacing: 5) { if let id = message.replyToID, let source = messages.first(where: { $0.id == id && $0.kind != .recalled }) {
            Button { jumpTo(id) } label: {
                HStack(spacing: 5) {
                    Rectangle().fill(isMine ? Color.white.opacity(0.7) : Color.accentColor).frame(width: 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(senderName(for: source)).fontWeight(.semibold)
                        Text(replySummary(source)).lineLimit(1)
                    }
                }.font(.caption2).foregroundStyle(isMine ? .white.opacity(0.85) : .secondary)
            }.buttonStyle(.plain).accessibilityLabel("定位到 \(senderName(for: source)) 的原消息")
        }
            messageContent
        }.padding(message.kind == .image ? 0 : 9).background(message.kind == .image ? Color.clear : (isMine ? Color.accentColor : Color.secondary.opacity(0.14)), in: RoundedRectangle(cornerRadius: 18, style: .continuous)).foregroundStyle(isMine && message.kind != .image ? .white : .primary)
        if showsStatus && isMine { Text(statusText).font(.caption2).foregroundStyle(message.status == .failed ? .red : .secondary).padding(.trailing, 4) }
    }.frame(maxWidth: UIScreen.main.bounds.width * 0.74, alignment: isMine ? .trailing : .leading); if !isMine { Spacer(minLength: 44) } }
    .contextMenu { if message.kind != .recalled { Button("回复", action: reply) }; if isMine && message.status == .failed { Button("重试发送", action: retry) }; if isMine && message.kind != .recalled && Calendar.autoupdatingCurrent.dateComponents([.minute], from: message.sentAt, to: .now).minute ?? 6 <= 5 { Button("撤回", role: .destructive, action: recall) }; if isMine { Button("移到回收站", role: .destructive, action: delete) } }
    .simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { value in
        guard message.kind != .recalled, value.translation.width < -65,
              abs(value.translation.height) < 35 else { return }
        if reduceMotion { reply() } else { withAnimation(.easeInOut(duration: 0.18)) { reply() } }
    })
    }
    @ViewBuilder private var messageContent: some View {
        switch message.kind {
        case .image:
            if let image = image {
                Button(action: previewImage) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: 230, maxHeight: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }.buttonStyle(.plain).accessibilityLabel("全屏查看图片消息")
            } else {
                Button(action: loadRemoteMedia) {
                    Label(isLoadingRemoteMedia ? "正在加载图片" : "下载照片", systemImage: "photo")
                }.disabled(isLoadingRemoteMedia || env.remoteChatMediaResolver == nil)
            }
        case .audio:
            Button {
                if let path = message.mediaPath {
                    do { try playback.toggle(messageID: message.id, url: env.mediaStore.url(for: path)) }
                    catch { env.lastError = "语音不可播放：\(error.localizedDescription)" }
                } else { loadRemoteMedia() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: playback.isPlaying(message.id) ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: playback.progress(for: message.id)).frame(width: 125)
                        Text(isLoadingRemoteMedia ? "正在加载语音" : audioLabel).font(.caption)
                    }
                }
            }.buttonStyle(.plain)
                .disabled(isLoadingRemoteMedia || (message.mediaPath == nil && env.remoteChatMediaResolver == nil))
                .accessibilityLabel(audioLabel)
        case .file:
            fileContent
        case .text, .recalled:
            Text(message.body).textSelection(.enabled)
        }
    }
    private var fileContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill").font(.title2).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(message.body).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(fileSizeLabel).font(.caption2).foregroundStyle(isMine ? .white.opacity(0.8) : .secondary)
            }
            if let path = message.mediaPath,
               FileManager.default.fileExists(atPath: env.mediaStore.url(for: path).path) {
                ShareLink(item: env.mediaStore.url(for: path)) {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                }.accessibilityLabel("保存或分享 \(message.body)")
            } else {
                Button(action: loadRemoteMedia) {
                    Image(systemName: "arrow.down.circle").frame(width: 44, height: 44)
                }.disabled(isLoadingRemoteMedia || env.remoteChatMediaResolver == nil)
                    .accessibilityLabel(isLoadingRemoteMedia ? "正在下载 \(message.body)" : "下载 \(message.body)")
            }
        }.frame(maxWidth: 235, alignment: .leading)
    }
    private func loadRemoteMedia() { guard let resolver = env.remoteChatMediaResolver, !isLoadingRemoteMedia else { return }; isLoadingRemoteMedia = true; Task { @MainActor in defer { isLoadingRemoteMedia = false }; do { _ = try await resolver.ensureCachedMedia(messageID: message.id) } catch { env.lastError = "无法加载聊天媒体：\(error.localizedDescription)" } } }
    private func replySummary(_ source: ChatMessageModel) -> String {
        switch source.kind { case .image: return "照片"; case .audio: return "语音"; case .file, .text, .recalled: return source.body }
    }
    private func senderName(for source: ChatMessageModel) -> String {
        profiles.first(where: { $0.memberID == source.senderID })?.displayName ?? source.senderID
    }
    private var fileSizeLabel: String {
        if let size = message.mediaSizeBytes {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        guard let path = message.mediaPath else { return "尚未下载" }
        let url = env.mediaStore.url(for: path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "文件不可用" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
    private var image: UIImage? { guard let path = message.mediaPath else { return nil }; do { return UIImage(data: try Data(contentsOf: env.mediaStore.url(for: path))) } catch { return nil } }
    private var audioLabel: String { guard let path = message.mediaPath else { return "语音未下载" }; do { let duration = try playback.duration(for: message.id, url: env.mediaStore.url(for: path)); let elapsed = duration * playback.progress(for: message.id); return "\(playback.isPlaying(message.id) ? "暂停" : "播放")语音 · \(Int(elapsed.rounded())) / \(Int(duration.rounded())) 秒" } catch { return "语音不可用" } }
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

@MainActor @Observable private final class AudioPlaybackState: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?
    private(set) var activeMessageID: UUID?
    private(set) var playbackProgress: [UUID: Double] = [:]
    func toggle(messageID: UUID, url: URL) throws {
        if activeMessageID == messageID, let player {
            if player.isPlaying {
                player.pause()
                stopProgressUpdates()
            } else {
                player.play()
                startProgressUpdates()
            }
            return
        }
        player?.stop()
        stopProgressUpdates()
        let next = try AVAudioPlayer(contentsOf: url)
        next.delegate = self
        next.prepareToPlay()
        next.play()
        player = next
        activeMessageID = messageID
        playbackProgress[messageID] = 0
        startProgressUpdates()
    }
    func isPlaying(_ messageID: UUID) -> Bool { activeMessageID == messageID && player?.isPlaying == true }
    func progress(for messageID: UUID) -> Double { playbackProgress[messageID] ?? 0 }
    func duration(for messageID: UUID, url: URL) throws -> TimeInterval { if activeMessageID == messageID, let player { return player.duration }; return try AVAudioPlayer(contentsOf: url).duration }
    private func updateProgress() { guard let player, let id = activeMessageID, player.duration > 0 else { return }; playbackProgress[id] = player.currentTime / player.duration }
    private func startProgressUpdates() {
        stopProgressUpdates()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.updateProgress()
            }
        }
    }
    private func stopProgressUpdates() { progressTask?.cancel(); progressTask = nil }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finish() }
    }
    private func finish() { if let id = activeMessageID { playbackProgress[id] = 1 }; stopProgressUpdates(); player = nil; activeMessageID = nil }
}

@MainActor @Observable private final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    var isRecording = false
    private var recorder: AVAudioRecorder?
    private var url: URL?
    var onFinished: ((URL, Bool) -> Void)?

    func start() {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in self?.handlePermission(granted) }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in self?.handlePermission(granted) }
            }
        }
    }
    private func handlePermission(_ granted: Bool) {
        guard granted else { isRecording = false; return }
        begin()
    }
    private func begin() { let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a"); do { try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default); try AVAudioSession.sharedInstance().setActive(true); recorder = try AVAudioRecorder(url: target, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]); recorder?.delegate = self; recorder?.record(forDuration: 300); url = target; isRecording = true } catch { isRecording = false } }
    func stop() { recorder?.stop() }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) { Task { @MainActor [weak self] in self?.finish(successfully: flag) } }
    private func finish(successfully: Bool) { guard let url else { return }; recorder = nil; self.url = nil; isRecording = false; onFinished?(url, successfully) }
}

struct AgendaView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \AgendaItemModel.start) private var items: [AgendaItemModel]
    @State private var presentingEditor = false
    let filterKind: AgendaKind?
    init(filterKind: AgendaKind? = nil) { self.filterKind = filterKind }
    private var visibleItems: [AgendaItemModel] { items.filter { $0.deletedAt == nil && $0.purgedAt == nil && (filterKind == nil || $0.kind == filterKind) } }
    var body: some View { NavigationStack { List {
        if visibleItems.isEmpty {
            ContentUnavailableView(filterKind == .orderFood ? "暂无点菜" : "暂无安排", systemImage: filterKind == .orderFood ? "fork.knife" : "calendar", description: Text(filterKind == .orderFood ? "点击右上角加号，记录想吃的菜。" : "点击右上角加号添加日程，或查看共同空闲时间。"))
        } else {
            ForEach(visibleItems) { item in
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
    }
        .navigationTitle(filterKind == .orderFood ? "点菜" : "日程").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { presentingEditor = true } label: { Image(systemName: "plus") }.accessibilityLabel(filterKind == .orderFood ? "新建点菜" : "新建日程") } }.sheet(isPresented: $presentingEditor) { NavigationStack { AgendaEditor(item: nil, preferredKind: filterKind) } }
    } }
}
private struct AgendaRow: View { @Environment(AppEnvironment.self) private var env; @Query private var profiles: [MemberProfile]; let item: AgendaItemModel
    var body: some View { HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .trailing, spacing: 2) { Text(timeLabel).font(.caption.weight(.semibold)); Text(dateLabel).font(.caption2).foregroundStyle(.secondary) }.frame(width: 58, alignment: .trailing)
        RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 3).frame(minHeight: 40)
        VStack(alignment: .leading, spacing: 4) { HStack(spacing: 5) { Image(systemName: symbol).font(.caption).foregroundStyle(tint); Text(item.title).lineLimit(1) }; memberLine; detailLine }
        Spacer(minLength: 4)
        if item.kind == .orderFood { Text("已读 \(item.foodReadReceipts.count)/\(item.participantIDs.count)").font(.caption2).foregroundStyle(.secondary) }
    }.padding(.vertical, 3).accessibilityLabel("\(item.kind.localizedName)：\(item.title)，\(timeLabel)").contextMenu { if item.kind == .orderFood { Button("标记已读") { do { try env.agendaRepository.markFoodRead(item, by: env.session.currentMemberID ?? "") } catch { env.lastError = error.localizedDescription } } }; if item.kind == .assignmentDeadline { Button("标记完成") { do { try env.agendaRepository.setCompletion(item, state: .completed, by: env.session.currentMemberID ?? "") } catch { env.lastError = error.localizedDescription } } } } }
    @ViewBuilder private var memberLine: some View { HStack(spacing: 3) { Image(systemName: "person.2").font(.caption2); Text(item.participantIDs.map(displayName(for:)).joined(separator: " · ")).lineLimit(1) }.font(.caption2).foregroundStyle(.secondary) }
    private func displayName(for memberID: String) -> String { profiles.first(where: { $0.memberID == memberID })?.displayName ?? memberID }
    @ViewBuilder private var detailLine: some View { if let due = item.dueAt { Text("截止：\(FamilyFormatters.dateTime.string(from: due)) · \(deadlineState)").font(.caption).foregroundStyle(.secondary) } else if let dishes = item.dishes, item.kind == .orderFood { Text(dishes).font(.caption).foregroundStyle(.secondary).lineLimit(1) } else if let location = item.location, !location.isEmpty { Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
    private var timeLabel: String { if let start = item.start { return FamilyFormatters.time.string(from: start) }; if item.kind == .assignmentDeadline { return "截止" }; return "点菜" }
    private var dateLabel: String { if let start = item.start { return FamilyFormatters.day.string(from: start) }; if let due = item.dueAt { return FamilyFormatters.day.string(from: due) }; return item.kind.localizedName }
    private var tint: Color { switch item.kind { case .normal: return .blue; case .exam: return .red; case .assignmentDeadline: return .orange; case .orderFood: return .mint } }
    private var deadlineState: String { if item.completionRaw == CompletionState.completed.rawValue { return "已完成" }; if item.completionRaw == CompletionState.overdue.rawValue || (item.dueAt ?? .distantFuture) < .now { return "已逾期" }; return "待完成" }
    private var symbol: String { switch item.kind { case .normal: return "calendar"; case .exam: return "pencil"; case .assignmentDeadline: return "checklist"; case .orderFood: return "fork.knife" } }
}
struct AgendaEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @Query private var profiles: [MemberProfile]
    let item: AgendaItemModel?
    let proposedSlot: AvailabilitySlot?
    let preferredKind: AgendaKind?
    @State private var title = ""; @State private var kind: AgendaKind = .normal; @State private var start = Date(); @State private var end = Date().addingTimeInterval(3600); @State private var participants: Set<String> = []; @State private var location = ""; @State private var note = ""; @State private var recurrence: AgendaRecurrence = .none; @State private var recurrenceEnd = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 7, to: .now) ?? .now; @State private var dishes = ""; @State private var ingredients = ""; @State private var seasonings = ""; @State private var arrival = Date(); @State private var mealTime = Date().addingTimeInterval(3600); @State private var preparation: PreparationState = .waiting; @State private var completion: CompletionState = .pending; @State private var error: String?; @State private var confirmDelete = false; @State private var calendarExportMessage: String?
    init(item: AgendaItemModel?, proposedSlot: AvailabilitySlot? = nil, preferredKind: AgendaKind? = nil) { self.item = item; self.proposedSlot = proposedSlot; self.preferredKind = preferredKind }
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
            Section("参与成员") { ForEach(memberIDs, id: \.self) { memberID in Toggle(isOn: Binding(get: { participants.contains(memberID) }, set: { enabled in if enabled { participants.insert(memberID) } else { participants.remove(memberID) } })) { MemberLabel(memberID: memberID) }.disabled(!canEdit) } }
            if kind == .orderFood, let item { Section("点菜状态") { ForEach(item.participantIDs, id: \.self) { memberID in let receipt = item.foodReadReceipts.first(where: { $0.memberID == memberID }); HStack { MemberLabel(memberID: memberID); Spacer(); Text(receipt.map { FamilyFormatters.dateTime.string(from: $0.readAt) } ?? "未读").font(.caption).foregroundStyle(receipt == nil ? .secondary : .primary) } } } }
            if let item, AppleCalendarExporter.isExportable(item) { Section("Apple 日历") { Button("添加到 Apple 日历") { exportToAppleCalendar(item) }; Text("普通日程、考试和带吃饭时间的点菜可单向添加；不会读取或修改已有日历事件。 ").font(.caption).foregroundStyle(.secondary) } }
            if let item, item.recurrence != .none { Section("周期例外") { NavigationLink("查看和管理例外") { AgendaExceptionList(item: item) } } }
            if canEdit { BusinessAIAssistButton(title: "AI 生成日程草稿", instruction: "Draft an agenda title and concise notes from natural language. Return plain text only; do not invent a saved action.", source: "\(title) \(note)") { note = $0 } }
        }
        .navigationTitle(item == nil ? "新建日程" : "日程详情")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(!canEdit || title.trimmingCharacters(in: .whitespaces).isEmpty) }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; if item != nil && canEdit { ToolbarItem(placement: .bottomBar) { Button("删除", role: .destructive) { confirmDelete = true } } } }
        .onAppear(perform: load)
        .confirmationDialog("删除日程？", isPresented: $confirmDelete, titleVisibility: .visible) { Button("删除", role: .destructive, action: delete) }
        .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
        .alert("Apple 日历", isPresented: Binding(get: { calendarExportMessage != nil }, set: { if !$0 { calendarExportMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(calendarExportMessage ?? "") }
    }
    private var memberIDs: [String] { MemberDirectory.activeMembers(from: profiles).map(\.memberID) }
    private func load() { guard let item else { kind = preferredKind ?? .normal; if let proposedSlot { start = proposedSlot.start; end = proposedSlot.end; participants = Set(proposedSlot.participants) } else { participants = env.session.currentMemberID.map { [$0] } ?? [] }; return }; title = item.title; kind = item.kind; start = item.start ?? .now; end = item.end ?? item.dueAt ?? .now; participants = Set(item.participantIDs); location = item.location ?? ""; note = item.note ?? ""; recurrence = item.recurrence; recurrenceEnd = item.recurrenceEnd ?? recurrenceEnd; dishes = item.dishes ?? ""; ingredients = item.ingredients ?? ""; seasonings = item.seasonings ?? ""; arrival = item.estimatedArrival ?? .now; mealTime = item.desiredMealTime ?? .now; preparation = PreparationState(rawValue: item.preparationRaw ?? "") ?? .waiting; completion = CompletionState(rawValue: item.completionRaw ?? "") ?? .pending }
    private func save() { guard (kind != .normal && kind != .exam) || start < end else { error = "结束时间必须晚于开始时间。"; return }; let member = env.session.currentMemberID ?? ""; let value = item ?? AgendaItemModel(creatorID: member, title: title, kind: kind, participantIDs: Array(participants)); let draft = AgendaDraft(title: title, kind: kind, start: (kind == .normal || kind == .exam) ? start : nil, end: (kind == .normal || kind == .exam) ? end : nil, dueAt: kind == .assignmentDeadline ? end : nil, location: location.isEmpty ? nil : location, note: note.isEmpty ? nil : note, participantIDs: Array(participants), recurrence: recurrence, recurrenceEnd: recurrence == .none ? nil : recurrenceEnd, dishes: kind == .orderFood ? dishes : nil, ingredients: kind == .orderFood ? ingredients : nil, seasonings: kind == .orderFood ? seasonings : nil, peopleCount: kind == .orderFood ? participants.count : nil, estimatedArrival: kind == .orderFood ? arrival : nil, desiredMealTime: kind == .orderFood ? mealTime : nil, preparation: kind == .orderFood ? preparation : nil, completion: kind == .assignmentDeadline ? completion : nil); do { try env.agendaRepository.save(value, draft: draft, by: member); dismiss() } catch { self.error = error.localizedDescription } }
    private func delete() { guard let item else { return }; do { try env.agendaRepository.delete(item, by: env.session.currentMemberID ?? ""); dismiss() } catch { self.error = error.localizedDescription } }
    private func exportToAppleCalendar(_ item: AgendaItemModel) {
        Task { @MainActor [item] in
            do {
                try await AppleCalendarExporter().add(item)
                calendarExportMessage = "已添加到 Apple 日历。"
            } catch {
                calendarExportMessage = error.localizedDescription
            }
        }
    }
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
    private func save() { guard kind == .cancelled || replacementStart < replacementEnd else { error = "结束时间必须晚于开始时间。"; return }; let rule = exception ?? AgendaExceptionModel(agendaID: item.id, kind: kind, scope: scope, occurrenceDate: occurrence); let draft = AgendaExceptionDraft(kind: kind, scope: scope, occurrenceDate: occurrence, replacementStart: kind == .cancelled ? nil : replacementStart, replacementEnd: kind == .cancelled ? nil : replacementEnd); do { try env.agendaRepository.save(exception: rule, draft: draft, for: item, by: env.session.currentMemberID ?? ""); dismiss() } catch { self.error = error.localizedDescription } }
}
