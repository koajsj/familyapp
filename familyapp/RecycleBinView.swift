import SwiftUI
import SwiftData

private enum LocalTrashItem {
    case message(ChatMessageModel, Date)
    case memo(MemoModel, Date, Int)
    case notice(NoticeModel, Date)
    case agenda(AgendaItemModel, Date)

    var id: UUID {
        switch self {
        case .message(let value, _): value.id
        case .memo(let value, _, _): value.id
        case .notice(let value, _): value.id
        case .agenda(let value, _): value.id
        }
    }

    var entityType: String {
        switch self {
        case .message: "message"
        case .memo: "memo"
        case .notice: "notice"
        case .agenda: "agenda"
        }
    }

    var deletedAt: Date {
        switch self {
        case .message(_, let date), .notice(_, let date), .agenda(_, let date): date
        case .memo(_, let date, _): date
        }
    }

    var title: String {
        switch self {
        case .message(let value, _):
            switch value.kind {
            case .image: return "照片"
            case .audio: return "语音"
            case .file, .text, .recalled: return value.body.isEmpty ? "聊天消息" : value.body
            }
        case .memo(let value, _, _): return value.title?.isEmpty == false ? value.title! : String(value.content.prefix(80))
        case .notice(let value, _): return value.title
        case .agenda(let value, _): return value.title
        }
    }

    var kind: String? {
        if case .agenda(let value, _) = self { return value.kindRaw }
        return nil
    }
}

private struct TrashEntry: Identifiable {
    let id: String
    let entityType: String
    let kind: String?
    let title: String
    let deletedAt: Date
    let local: LocalTrashItem?
    let remote: RemoteTrashItem?

    init(local: LocalTrashItem) {
        id = "\(local.entityType):\(local.id.uuidString)"
        entityType = local.entityType; kind = local.kind
        title = local.title; deletedAt = local.deletedAt
        self.local = local; remote = nil
    }

    init(remote: RemoteTrashItem) {
        id = remote.key; entityType = remote.entityType; kind = remote.kind
        title = remote.title; deletedAt = remote.deletedAt
        local = nil; self.remote = remote
    }

    var typeLabel: String {
        switch entityType {
        case "message": return "议事堂"
        case "memo": return "备忘录"
        case "notice": return "公告"
        case "agenda": return kind == AgendaKind.orderFood.rawValue ? "点菜" : "日程"
        default: return "家庭内容"
        }
    }

    var symbol: String {
        switch entityType {
        case "message": return "bubble.left"
        case "memo": return "note.text"
        case "notice": return "megaphone"
        case "agenda": return kind == AgendaKind.orderFood.rawValue ? "fork.knife" : "calendar"
        default: return "trash"
        }
    }

    var remaining: String {
        let expiry = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 30, to: deletedAt) ?? deletedAt
        let hours = max(0, Int(ceil(expiry.timeIntervalSinceNow / 3_600)))
        return hours > 24 ? "剩余 \(Int(ceil(Double(hours) / 24))) 天" : "剩余 \(hours) 小时"
    }
}

struct RecycleBinView: View {
    @Environment(AppEnvironment.self) private var env
    @Query private var messages: [ChatMessageModel]
    @Query private var memos: [MemoModel]
    @Query private var notices: [NoticeModel]
    @Query private var agendas: [AgendaItemModel]
    @State private var remoteItems: [RemoteTrashItem] = []
    @State private var isLoading = false
    @State private var isOperating = false
    @State private var permanentCandidate: TrashEntry?

    private var localItems: [TrashEntry] {
        guard let memberID = env.session.currentMemberID else { return [] }
        let chat = messages.compactMap { value -> TrashEntry? in
            guard value.senderID == memberID, let date = value.deletedAt,
                  value.purgedAt == nil, RecycleRetention.canRestore(date) else { return nil }
            return TrashEntry(local: .message(value, date))
        }
        let notes = memos.compactMap { value -> TrashEntry? in
            guard value.creatorID == memberID, let date = value.deletedAt,
                  value.purgedAt == nil, RecycleRetention.canRestore(date) else { return nil }
            return TrashEntry(local: .memo(value, date, value.version))
        }
        let announcements = notices.compactMap { value -> TrashEntry? in
            guard value.publisherID == memberID, let date = value.deletedAt,
                  value.purgedAt == nil, RecycleRetention.canRestore(date) else { return nil }
            return TrashEntry(local: .notice(value, date))
        }
        let events = agendas.compactMap { value -> TrashEntry? in
            guard value.creatorID == memberID, let date = value.deletedAt,
                  value.purgedAt == nil, RecycleRetention.canRestore(date) else { return nil }
            return TrashEntry(local: .agenda(value, date))
        }
        return (chat + notes + announcements + events).sorted { $0.deletedAt > $1.deletedAt }
    }

    private var items: [TrashEntry] {
        env.runtimeMode == .localOnly ? localItems : remoteItems.map(TrashEntry.init(remote:))
    }

    var body: some View {
        List {
            if isLoading && items.isEmpty {
                ProgressView("正在读取回收站").frame(maxWidth: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView("回收站为空", systemImage: "trash", description: Text("删除的家庭内容会在这里保留 30 天。"))
            } else {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.symbol).frame(width: 24).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).lineLimit(2)
                            Text("\(item.typeLabel) · \(FamilyFormatters.dateTime.string(from: item.deletedAt)) · \(item.remaining)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Menu {
                            Button("恢复", systemImage: "arrow.uturn.backward") { perform(item, permanent: false) }
                            Button("永久删除", systemImage: "trash", role: .destructive) { permanentCandidate = item }
                        } label: {
                            Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                        }
                        .disabled(isOperating)
                        .accessibilityLabel("管理\(item.typeLabel)：\(item.title)")
                    }
                    .padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("恢复") { perform(item, permanent: false) }.tint(.blue).disabled(isOperating)
                        Button("永久删除", role: .destructive) { permanentCandidate = item }.disabled(isOperating)
                    }
                    .contextMenu {
                        Button("恢复") { perform(item, permanent: false) }
                        Button("永久删除", role: .destructive) { permanentCandidate = item }
                    }
                }
            }
        }
        .navigationTitle("回收站")
        .refreshable { await loadRemoteIfNeeded() }
        .task(id: env.session.currentMemberID) {
            remoteItems = []
            await loadRemoteIfNeeded()
        }
        .confirmationDialog("永久删除后无法恢复，确定继续？", isPresented: Binding(
            get: { permanentCandidate != nil },
            set: { if !$0 { permanentCandidate = nil } }
        ), titleVisibility: .visible) {
            Button("永久删除", role: .destructive) {
                guard let item = permanentCandidate else { return }
                permanentCandidate = nil
                perform(item, permanent: true)
            }
            Button("取消", role: .cancel) { permanentCandidate = nil }
        }
    }

    private func loadRemoteIfNeeded() async {
        guard env.runtimeMode == .remoteSync else { return }
        isLoading = true
        defer { isLoading = false }
        do { remoteItems = try await env.remoteTrashItems() }
        catch is CancellationError { }
        catch { env.lastError = error.localizedDescription }
    }

    private func perform(_ item: TrashEntry, permanent: Bool) {
        guard !isOperating, let memberID = env.session.currentMemberID else { return }
        isOperating = true
        if let remote = item.remote {
            Task { @MainActor in
                defer { isOperating = false }
                do {
                    try await env.changeRemoteTrash(remote, permanent: permanent)
                    await loadRemoteIfNeeded()
                } catch is CancellationError { }
                catch { env.lastError = error.localizedDescription }
            }
            return
        }
        defer { isOperating = false }
        guard let local = item.local else { return }
        do {
            switch local {
            case .message(let value, let date):
                if permanent { try env.chatRepository.permanentlyDelete(value, deletedAt: date, by: memberID) }
                else { try env.chatRepository.restore(value, deletedAt: date, by: memberID) }
            case .memo(let value, let date, let version):
                if permanent { try env.memoRepository.permanentlyDelete(value, deletedAt: date, expectedVersion: version, by: memberID) }
                else { try env.memoRepository.restore(value, deletedAt: date, expectedVersion: version, by: memberID) }
            case .notice(let value, let date):
                if permanent { try env.noticeRepository.permanentlyDelete(value, deletedAt: date, by: memberID) }
                else { try env.noticeRepository.restore(value, deletedAt: date, by: memberID) }
            case .agenda(let value, let date):
                if permanent { try env.agendaRepository.permanentlyDelete(value, deletedAt: date, by: memberID) }
                else { try env.agendaRepository.restore(value, deletedAt: date, by: memberID) }
            }
            env.refreshToken = UUID()
        } catch { env.lastError = error.localizedDescription }
    }
}
