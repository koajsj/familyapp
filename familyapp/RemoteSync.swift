import Foundation
import CryptoKit
import SwiftData

/// Dormant by design: the shipping Demo fixes its runtime to `localOnly` and
/// never constructs a remote client, coordinator, token store, or WebSocket.
enum AppRuntimeMode: String, Sendable { case localOnly, remoteSync }

enum RemoteOutboxState: String, Codable, Sendable {
    case pending, sending, acknowledged
}

/// Transfer state is local recovery metadata. It is deliberately separate
/// from delivery/read state and is never sent as a chat-message field.
enum RemoteMediaTransferState: String, Codable, Sendable {
    case pending, uploading, finalized, failed
}

enum RemoteRollbackRequestState: String, Codable, Sendable {
    case pending, sending, acknowledged, conflict
}

nonisolated enum RemoteChangeOperation: String, Codable, Sendable {
    case create, update, delete, upsert
}

nonisolated enum RemoteEntityType: String, CaseIterable, Sendable {
    case member, memberStatus, semester, schedule, scheduleException, calendarOverride
    case importBatch, agenda, agendaException, memo, notice, memberPlace, mediaAsset
    case message, locationSnapshot, messageReceipt, noticeRead, foodRead
    case agendaParticipant, importBatchItem, geofenceEvent

    var isAppendOnly: Bool {
        switch self {
        // Location snapshots are immutable observations. Other relation rows
        // need a tombstone so a parent deletion or participant removal can
        // converge instead of leaving an active orphan on another device.
        case .locationSnapshot:
            return true
        default:
            return false
        }
    }

    var supportsAuthoritativeRestore: Bool {
        switch self {
        case .message, .memo, .notice, .agenda, .messageReceipt,
             .noticeRead, .agendaException, .agendaParticipant, .foodRead:
            return true
        default:
            return false
        }
    }
}

nonisolated enum RemoteJSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: RemoteJSONValue]), array([RemoteJSONValue]), null

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null }
        else if let value = try? single.decode(Bool.self) { self = .bool(value) }
        else if let value = try? single.decode(Double.self) { self = .number(value) }
        else if let value = try? single.decode(String.self) { self = .string(value) }
        else if let value = try? single.decode([String: RemoteJSONValue].self) { self = .object(value) }
        else { self = .array(try single.decode([RemoteJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case let .string(value): try single.encode(value)
        case let .number(value): try single.encode(value)
        case let .bool(value): try single.encode(value)
        case let .object(value): try single.encode(value)
        case let .array(value): try single.encode(value)
        case .null: try single.encodeNil()
        }
    }
}

nonisolated struct RemoteMutation: Encodable, Sendable {
    let mutationID: UUID
    let entityType: String
    let entityID: UUID
    let operation: RemoteChangeOperation
    let baseVersion: Int?
    let payload: [String: RemoteJSONValue]
    let clientTimestamp: Date

    enum CodingKeys: String, CodingKey {
        case mutationID = "mutation_id", entityType = "entity_type", entityID = "entity_id"
        case operation, baseVersion = "base_version", payload, clientTimestamp = "client_timestamp"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mutationID, forKey: .mutationID)
        try values.encode(entityType, forKey: .entityType)
        try values.encode(entityID, forKey: .entityID)
        try values.encode(operation, forKey: .operation)
        try values.encodeIfPresent(baseVersion, forKey: .baseVersion)
        try values.encode(payload, forKey: .payload)
        try values.encode(RemoteWireDate.string(from: clientTimestamp), forKey: .clientTimestamp)
    }
}

nonisolated struct RemoteMutationConflict: Decodable, Sendable {
    let mutationID: UUID
    let entityType: String
    let entityID: UUID
    let code: String
    let currentVersion: Int
    let currentPayload: [String: RemoteJSONValue]?

    enum CodingKeys: String, CodingKey {
        case mutationID = "mutation_id", entityType = "entity_type", entityID = "entity_id"
        case code, currentVersion = "current_version", currentPayload = "current_payload"
    }
}

nonisolated struct RemotePushResponse: Decodable, Sendable {
    nonisolated struct MutationAcknowledgement: Decodable, Sendable {
        let mutationID: UUID
        let entityType: String
        let entityID: UUID
        enum CodingKeys: String, CodingKey {
            case mutationID = "mutation_id", entityType = "entity_type", entityID = "entity_id"
        }
    }

    let latestCursor: Int
    let applied: [MutationAcknowledgement]
    let conflicts: [RemoteMutationConflict]

    private enum CodingKeys: String, CodingKey { case latestCursor = "latest_cursor", applied, conflicts }
}

nonisolated struct RemoteChange: Decodable, Sendable {
    let sequence: Int
    let entityType: String
    let entityID: UUID
    let operation: RemoteChangeOperation
    let version: Int
    /// Preserves the server timestamp without relying on a locale-specific date decoder.
    let updatedAt: String
    let payload: [String: RemoteJSONValue]?
    let sourceMutationID: UUID?
    let sourceDeviceID: UUID?

    enum CodingKeys: String, CodingKey {
        case sequence = "seq", entityType = "entity_type", entityID = "entity_id"
        case operation, version, updatedAt = "updated_at", payload
        case sourceMutationID = "source_mutation_id", sourceDeviceID = "source_device_id"
    }
}

nonisolated struct RemotePullResponse: Decodable, Sendable {
    let changes: [RemoteChange]
    let latestCursor: Int
    let hasMore: Bool

    enum CodingKeys: String, CodingKey { case changes, latestCursor = "latest_cursor", hasMore = "has_more" }
}

nonisolated struct RemoteBootstrapResponse: Decodable, Sendable {
    let entities: [String: [[String: RemoteJSONValue]]]
    let latestCursor: Int
    let familyTimezone: String

    enum CodingKeys: String, CodingKey { case entities, latestCursor = "latest_cursor", familyTimezone = "family_timezone" }
}

/// The existing server recycle endpoints are an authenticated control-plane
/// operation, not a second outbox or sync protocol. Local business rows remain
/// authoritative only after their resulting SyncChange has been pulled.
nonisolated struct RemoteTrashItem: Identifiable, Sendable {
    let id: UUID
    let entityType: String
    let version: Int
    let deletedAt: Date
    let title: String
    let kind: String?
    var key: String { "\(entityType):\(id.uuidString)" }
}

private nonisolated struct RemoteTrashPage: Decodable, Sendable {
    let items: [[String: RemoteJSONValue]]
    let nextID: UUID?
    enum CodingKeys: String, CodingKey { case items, nextID = "next_id" }
}

private nonisolated struct RemoteTrashMutationBody: Encodable, Sendable {
    let mutationID: UUID
    let expectedVersion: Int
    let confirmed: Bool?
    enum CodingKeys: String, CodingKey { case mutationID = "mutation_id", expectedVersion = "expected_version", confirmed }
}

private nonisolated struct RemoteTrashMutationResult: Decodable, Sendable {
    let mutationID: UUID
    let entityType: String
    let entityID: UUID
    let version: Int
    enum CodingKeys: String, CodingKey { case mutationID = "mutation_id", entityType = "entity_type", entityID = "entity_id", version }
}

nonisolated struct RemoteTokenPair: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let deviceID: UUID

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token"
        case expiresIn = "expires_in", deviceID = "device_id"
    }
}

private nonisolated struct RemoteCurrentMemberIdentity: Decodable, Sendable {
    let memberID: UUID
    enum CodingKeys: String, CodingKey { case memberID = "member_id" }
}

/// The login endpoint returns the stable member UUID alongside the existing
/// token pair. The identifier shown in the login form is never used as a key.
nonisolated struct RemotePasswordLoginResponse: Decodable, Sendable {
    let memberID: UUID
    let tokenPair: RemoteTokenPair

    private enum CodingKeys: String, CodingKey {
        case memberID = "member_id", accessToken = "access_token"
        case refreshToken = "refresh_token", expiresIn = "expires_in"
        case deviceID = "device_id"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        memberID = try values.decode(UUID.self, forKey: .memberID)
        tokenPair = RemoteTokenPair(
            accessToken: try values.decode(String.self, forKey: .accessToken),
            refreshToken: try values.decode(String.self, forKey: .refreshToken),
            expiresIn: try values.decode(Int.self, forKey: .expiresIn),
            deviceID: try values.decode(UUID.self, forKey: .deviceID)
        )
    }
}

private nonisolated struct RemotePasswordLoginBody: Encodable, Sendable {
    let memberKey: String
    let password: String
    let installationID: String
    let deviceName: String
    enum CodingKeys: String, CodingKey {
        case memberKey = "member_key", password
        case installationID = "installation_id", deviceName = "device_name"
    }
}

private nonisolated struct RemoteLogoutBody: Encodable, Sendable {
    let refreshToken: String
    enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
}

/// Only an explicitly configured remote login calls this public Auth endpoint.
/// It creates no RemoteAPIClient and stores no password or token itself.
actor RemotePasswordLoginClient {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func login(identifier: String, password: String, installationID: String,
               deviceName: String) async throws -> RemotePasswordLoginResponse {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw RemoteSyncError.invalidConfiguration
        }
        let components = baseURL.lastPathComponent.lowercased() == "v1"
            ? ["auth", "login"] : ["v1", "auth", "login"]
        let url = components.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(RemotePasswordLoginBody(
            memberKey: identifier, password: password,
            installationID: installationID, deviceName: deviceName
        ))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteSyncError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteSyncError.server(statusCode: http.statusCode, code: nil)
        }
        do { return try JSONDecoder().decode(RemotePasswordLoginResponse.self, from: data) }
        catch { throw RemoteSyncError.invalidResponse }
    }

    func logout(refreshToken: String) async throws {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw RemoteSyncError.invalidConfiguration
        }
        let components = baseURL.lastPathComponent.lowercased() == "v1"
            ? ["auth", "logout"] : ["v1", "auth", "logout"]
        var request = URLRequest(url: components.reduce(baseURL) { $0.appendingPathComponent($1) })
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(RemoteLogoutBody(refreshToken: refreshToken))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 204 else {
            throw RemoteSyncError.invalidResponse
        }
    }
}

/// Error responses are decoded by the network actor and deliberately remain
/// value-only so decoding never requires a hop to the main actor.
private nonisolated struct RemoteErrorEnvelope: Decodable, Sendable {
    let code: String?
    let detail: RemoteJSONValue?

    var resolvedCode: String? {
        if let code { return code }
        guard case let .object(values)? = detail,
              case let .string(value)? = values["code"] else {
            return nil
        }
        return value
    }
}

nonisolated enum RemoteSyncError: LocalizedError, Sendable {
    case invalidConfiguration
    case authenticationRequired
    case cursorExpired
    case invalidResponse
    case malformedChange(String)
    case stateCorrupted
    case localChangesPending
    case alreadySynchronizing
    case unsupportedLocalData(String)
    case server(statusCode: Int, code: String?)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "远端同步配置无效。"
        case .authenticationRequired: return "远端登录已失效，需要重新认证。"
        case .cursorExpired: return "同步游标已失效，需要重新初始化。"
        case .invalidResponse: return "远端同步返回的数据无效。"
        case let .malformedChange(reason): return "远端同步变更无效：\(reason)"
        case .stateCorrupted: return "本地同步状态损坏，需要重新初始化。"
        case .localChangesPending: return "本地尚有未落盘修改，不能安全应用远端同步。"
        case .alreadySynchronizing: return "同步正在进行。"
        case let .unsupportedLocalData(reason): return "当前本地数据尚不能安全同步：\(reason)"
        case .server: return "远端同步请求失败。"
        }
    }

    var stableCode: String {
        switch self {
        case .invalidConfiguration: return "invalid_configuration"
        case .authenticationRequired: return "authentication_required"
        case .cursorExpired: return "cursor_expired"
        case .invalidResponse: return "invalid_response"
        case .malformedChange: return "malformed_change"
        case .stateCorrupted: return "state_corrupted"
        case .localChangesPending: return "local_changes_pending"
        case .alreadySynchronizing: return "already_synchronizing"
        case .unsupportedLocalData: return "unsupported_local_data"
        case let .server(statusCode, code): return code ?? "http_\(statusCode)"
        }
    }
}

/// Implemented only by a future Keychain-backed remote-auth composition. The
/// local Demo deliberately has no conformer and never requests credentials.
/// `store` must atomically replace both rotated tokens for the same device.
protocol RemoteCredentialStore: Sendable {
    func accessToken() async throws -> String
    func refreshToken() async throws -> String
    func store(_ tokenPair: RemoteTokenPair) async throws
    func invalidate() async
}

protocol RemoteSyncAPI: Sendable {
    func push(deviceID: UUID, mutations: [RemoteMutation]) async throws -> RemotePushResponse
    func pull(after cursor: Int) async throws -> RemotePullResponse
    func bootstrap() async throws -> RemoteBootstrapResponse
}

/// Cursor hints carry no business payload. Pull remains the only change source.
nonisolated struct RemoteCursorNotification: Decodable, Sendable {
    let type: String
    let latestCursor: Int
    let requiresBootstrap: Bool
    let status: String
}

protocol RemoteCursorNotificationAPI: Sendable {
    func connectCursorNotifications() async throws
    func receiveCursorNotification() async throws -> RemoteCursorNotification
    func disconnectCursorNotifications() async
}

nonisolated struct RemoteMediaUploadGrant: Decodable, Sendable {
    let mediaID: UUID
    let uploadURL: URL?
    let uploadHeaders: [String: String]
    let status: String
    enum CodingKeys: String, CodingKey {
        case mediaID = "media_id", uploadURL = "upload_url", uploadHeaders = "upload_headers", status
    }
}

nonisolated struct RemoteMediaDownloadGrant: Decodable, Sendable {
    let mediaID: UUID
    let downloadURL: URL
    enum CodingKeys: String, CodingKey { case mediaID = "media_id", downloadURL = "download_url" }
}

nonisolated struct RemoteImportBatchRollbackResponse: Decodable, Sendable {
    let mutationID: UUID
    let batchID: UUID
    let version: Int
    let latestCursor: Int
    let duplicate: Bool
    enum CodingKeys: String, CodingKey {
        case mutationID = "mutation_id", batchID = "batch_id", version
        case latestCursor = "latest_cursor", duplicate
    }
}

/// Separate from `RemoteSyncAPI` so the ordinary pull/push coordinator never
/// acquires media capabilities unless a future remote composition opts in.
protocol RemoteMediaAPI: Sendable {
    func requestMediaUpload(mediaID: UUID, mimeType: String, sizeBytes: Int, checksum: String, fileName: String?) async throws -> RemoteMediaUploadGrant
    func uploadMedia(_ data: Data, to url: URL, headers: [String: String]) async throws
    func finalizeMedia(mediaID: UUID, checksum: String) async throws -> RemoteMediaUploadGrant
    func downloadMedia(mediaID: UUID) async throws -> Data
}

protocol RemoteImportBatchRollbackAPI: Sendable {
    func rollbackImportBatch(batchID: UUID, mutationID: UUID, expectedVersion: Int) async throws -> RemoteImportBatchRollbackResponse
}

/// Future REST transport. It has no side effects until a future remoteSync
/// composition explicitly creates it. A 401 has exactly one refresh/retry.
actor RemoteAPIClient: RemoteSyncAPI, RemoteCursorNotificationAPI, RemoteMediaAPI, RemoteImportBatchRollbackAPI, RemoteRecoveryAuthenticatedAPI {
    private let baseURL: URL
    private let deviceID: UUID
    private let session: URLSession
    private let credentials: any RemoteCredentialStore
    private var refreshTask: Task<Void, Error>?
    private var cursorSocket: URLSessionWebSocketTask?

    init(baseURL: URL, deviceID: UUID, session: URLSession = .shared, credentials: any RemoteCredentialStore) {
        self.baseURL = baseURL
        self.deviceID = deviceID
        self.session = session
        self.credentials = credentials
    }

    func currentMemberID() async throws -> UUID {
        let identity: RemoteCurrentMemberIdentity = try await request(
            path: ["v1", "members", "me", "identity"], method: "GET", body: EmptyBody()
        )
        return identity.memberID
    }

    func connectCursorNotifications() async throws {
        // The ordinary authenticated request path refreshes an expired access
        // token at most once and rejects a revoked Member/Device/Session.
        _ = try await currentMemberID()
        let token = try await credentials.accessToken()
        var components = URLComponents(url: try endpoint(["v1", "ws"]), resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        guard let url = components?.url else { throw RemoteSyncError.invalidConfiguration }
        cursorSocket?.cancel(with: .goingAway, reason: nil)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        cursorSocket = socket
        socket.resume()
    }

    func receiveCursorNotification() async throws -> RemoteCursorNotification {
        guard let socket = cursorSocket else { throw RemoteSyncError.invalidConfiguration }
        let frame = try await socket.receive()
        let data: Data
        switch frame {
        case let .data(value): data = value
        case let .string(value): data = Data(value.utf8)
        @unknown default: throw RemoteSyncError.invalidResponse
        }
        let notification = try decode(RemoteCursorNotification.self, from: data)
        guard notification.type == "latestCursor", notification.latestCursor >= 0,
              notification.status == "ready" else { throw RemoteSyncError.invalidResponse }
        return notification
    }

    func disconnectCursorNotifications() {
        cursorSocket?.cancel(with: .goingAway, reason: nil)
        cursorSocket = nil
    }

    func push(deviceID: UUID, mutations: [RemoteMutation]) async throws -> RemotePushResponse {
        struct PushBody: Encodable {
            let deviceID: UUID
            let mutations: [RemoteMutation]
            enum CodingKeys: String, CodingKey { case deviceID = "device_id", mutations }
        }
        return try await request(path: ["v1", "sync", "push"], method: "POST", body: PushBody(deviceID: deviceID, mutations: mutations))
    }

    func pull(after cursor: Int) async throws -> RemotePullResponse {
        guard cursor >= 0 else { throw RemoteSyncError.stateCorrupted }
        var components = URLComponents(url: try endpoint(["v1", "sync", "pull"]), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "after", value: String(cursor))]
        guard let url = components?.url else { throw RemoteSyncError.invalidConfiguration }
        let data = try await requestData(url: url, method: "GET", body: nil, mayRefresh: true)
        return try decode(RemotePullResponse.self, from: data)
    }

    func bootstrap() async throws -> RemoteBootstrapResponse {
        try await request(path: ["v1", "sync", "bootstrap"], method: "GET", body: EmptyBody())
    }

    func trashItems() async throws -> [RemoteTrashItem] {
        var result: [RemoteTrashItem] = []
        for type in ["message", "memo", "notice", "agenda"] {
            var afterID: UUID?
            repeat {
                var components = URLComponents(url: try endpoint(["v1", "sync", "trash", type]), resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "limit", value: "100")]
                if let afterID { components?.queryItems?.append(URLQueryItem(name: "after_id", value: afterID.uuidString)) }
                guard let url = components?.url else { throw RemoteSyncError.invalidConfiguration }
                let data = try await requestData(url: url, method: "GET", body: nil, mayRefresh: true)
                let page = try decode(RemoteTrashPage.self, from: data)
                for values in page.items {
                    let fields = RemoteFields(values)
                    let title = fields.string("title") ?? fields.string("body") ?? "聊天消息"
                    result.append(RemoteTrashItem(id: try fields.requiredUUID("id"), entityType: type,
                                                  version: try fields.requiredInt("version"),
                                                  deletedAt: try fields.requiredDate("deleted_at"), title: title,
                                                  kind: fields.string("kind")))
                }
                guard page.nextID == nil || page.nextID != afterID else { throw RemoteSyncError.invalidResponse }
                afterID = page.nextID
            } while afterID != nil
        }
        return result.sorted { $0.deletedAt > $1.deletedAt }
    }

    func changeTrash(_ item: RemoteTrashItem, permanent: Bool, mutationID: UUID) async throws {
        let operation = permanent ? "permanent-delete" : "restore"
        let body = RemoteTrashMutationBody(mutationID: mutationID, expectedVersion: item.version,
                                           confirmed: permanent ? true : nil)
        let result: RemoteTrashMutationResult = try await request(
            path: ["v1", "sync", "trash", item.entityType, item.id.uuidString, operation],
            method: "POST", body: body
        )
        guard result.mutationID == mutationID, result.entityID == item.id,
              result.entityType == item.entityType, result.version > item.version else {
            throw RemoteSyncError.invalidResponse
        }
    }

    func requestMediaUpload(mediaID: UUID, mimeType: String, sizeBytes: Int, checksum: String, fileName: String?) async throws -> RemoteMediaUploadGrant {
        struct Body: Encodable {
            let mediaID: UUID; let mimeType: String; let sizeBytes: Int; let checksum: String; let fileName: String?
            enum CodingKeys: String, CodingKey { case mediaID = "media_id", mimeType = "mime_type", sizeBytes = "size_bytes", checksum, fileName = "file_name" }
        }
        return try await request(path: ["v1", "media"], method: "POST", body: Body(mediaID: mediaID, mimeType: mimeType, sizeBytes: sizeBytes, checksum: checksum, fileName: fileName))
    }

    func uploadMedia(_ data: Data, to url: URL, headers: [String: String]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (_, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteSyncError.invalidResponse
        }
    }

    func finalizeMedia(mediaID: UUID, checksum: String) async throws -> RemoteMediaUploadGrant {
        struct Body: Encodable { let checksum: String }
        return try await request(path: ["v1", "media", mediaID.uuidString, "finalize"], method: "POST", body: Body(checksum: checksum))
    }

    func downloadMedia(mediaID: UUID) async throws -> Data {
        let grant: RemoteMediaDownloadGrant = try await request(path: ["v1", "media", mediaID.uuidString, "download"], method: "GET", body: EmptyBody())
        let (data, response) = try await session.data(from: grant.downloadURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteSyncError.invalidResponse
        }
        return data
    }

    func rollbackImportBatch(batchID: UUID, mutationID: UUID, expectedVersion: Int) async throws -> RemoteImportBatchRollbackResponse {
        struct Body: Encodable {
            let mutationID: UUID; let expectedVersion: Int
            enum CodingKeys: String, CodingKey { case mutationID = "mutation_id", expectedVersion = "expected_version" }
        }
        return try await request(path: ["v1", "sync", "import-batches", batchID.uuidString, "rollback"], method: "POST", body: Body(mutationID: mutationID, expectedVersion: expectedVersion))
    }

    /// Uses the existing authenticated request/refresh path. The human-readable
    /// mnemonic is never supplied here; only the client-derived secret crosses
    /// this control-plane request.
    func registerRecoveryCredential(secret: String) async throws -> RemoteRecoveryCredentialState {
        struct Body: Encodable {
            let recoverySecret: String
            enum CodingKeys: String, CodingKey { case recoverySecret = "recovery_secret" }
        }
        return try await request(path: ["v1", "recovery", "credential"], method: "PUT", body: Body(recoverySecret: secret))
    }

    func recoveryCredentialState() async throws -> RemoteRecoveryCredentialState {
        try await request(path: ["v1", "recovery", "credential"], method: "GET", body: EmptyBody())
    }

    /// Shared by authenticated control-plane extensions. It retains the same
    /// one-refresh retry and is never called directly from SwiftUI views.
    func request<Body: Encodable, Response: Decodable>(path: [String], method: String, body: Body) async throws -> Response {
        let encoded: Data?
        if method == "GET" { encoded = nil }
        else { encoded = try JSONEncoder().encode(body) }
        let data = try await requestData(url: endpoint(path), method: method, body: encoded, mayRefresh: true)
        return try decode(Response.self, from: data)
    }

    /// Authenticated control-plane endpoints with a deliberate 204 response
    /// reuse the same bearer/refresh path without inventing a fake Codable
    /// response body.
    func requestNoResponse<Body: Encodable>(path: [String], method: String, body: Body) async throws {
        let encoded = method == "GET" ? nil : try JSONEncoder().encode(body)
        _ = try await requestData(url: endpoint(path), method: method, body: encoded, mayRefresh: true)
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw RemoteSyncError.invalidResponse }
    }

    private func requestData(url: URL, method: String, body: Data?, mayRefresh: Bool) async throws -> Data {
        let token: String
        do { token = try await credentials.accessToken() }
        catch { throw RemoteSyncError.authenticationRequired }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw error }
        guard let http = response as? HTTPURLResponse else { throw RemoteSyncError.invalidResponse }
        if http.statusCode == 401, mayRefresh {
            // Another request may have rotated the device's refresh session
            // while this in-flight request still carried the old access token.
            // Reuse that new pair; never refresh the old token a second time.
            if (try? await credentials.accessToken()) == token {
                try await refreshCredentialsOnce()
            }
            return try await requestData(url: url, method: method, body: body, mayRefresh: false)
        }
        if http.statusCode == 401 {
            await credentials.invalidate()
            throw RemoteSyncError.authenticationRequired
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = serverErrorCode(from: data)
            if http.statusCode == 409,
               ["sync_cursor_expired", "invalid_sync_cursor"].contains(code) {
                throw RemoteSyncError.cursorExpired
            }
            throw RemoteSyncError.server(statusCode: http.statusCode, code: code)
        }
        return data
    }

    private func refreshCredentialsOnce() async throws {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.refreshCredentials() }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func refreshCredentials() async throws {
        let refresh: String
        do { refresh = try await credentials.refreshToken() }
        catch {
            await credentials.invalidate()
            throw RemoteSyncError.authenticationRequired
        }
        struct RefreshBody: Encodable {
            let refreshToken: String
            enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
        }
        let url = try endpoint(["v1", "auth", "refresh"])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(RefreshBody(refreshToken: refresh))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw RemoteSyncError.authenticationRequired }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let tokens = try? JSONDecoder().decode(RemoteTokenPair.self, from: data),
              tokens.deviceID == deviceID else {
            await credentials.invalidate()
            throw RemoteSyncError.authenticationRequired
        }
        do { try await credentials.store(tokens) }
        catch {
            await credentials.invalidate()
            throw RemoteSyncError.authenticationRequired
        }
    }

    private func endpoint(_ path: [String]) throws -> URL {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw RemoteSyncError.invalidConfiguration
        }
        let components = baseURL.lastPathComponent.lowercased() == "v1" && path.first == "v1" ? path.dropFirst() : path[...]
        return components.reduce(baseURL) { partial, component in partial.appendingPathComponent(component) }
    }

    private func serverErrorCode(from data: Data) -> String? {
        (try? JSONDecoder().decode(RemoteErrorEnvelope.self, from: data))?.resolvedCode
    }
}

private nonisolated struct RemoteMediaUploadMaterial: Sendable {
    let data: Data
    let checksum: String
}

private nonisolated enum RemoteMediaFilePreparation {
    /// This deliberately has no UI or SwiftData dependencies so it can run
    /// outside the main actor before the direct upload begins.
    static func load(from url: URL) throws -> RemoteMediaUploadMaterial {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= 100_000_000 else {
            throw RemoteSyncError.unsupportedLocalData("聊天附件为空或超过 100 MB")
        }
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return RemoteMediaUploadMaterial(data: data, checksum: checksum)
    }
}

private enum RemoteChatAttachmentType {
    static func mimeType(for message: ChatMessageModel, localURL: URL) throws -> String {
        switch message.kind {
        case .image: return "image/jpeg"
        case .audio: return "audio/m4a"
        case .file:
            let extensionToMIME = [
                "pdf": "application/pdf", "doc": "application/msword",
                "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                "xls": "application/vnd.ms-excel",
                "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                "ppt": "application/vnd.ms-powerpoint",
                "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
                "txt": "text/plain", "zip": "application/zip"
            ]
            guard let type = extensionToMIME[localURL.pathExtension.lowercased()] else {
                throw RemoteSyncError.unsupportedLocalData("文件类型不支持远端同步")
            }
            return type
        case .text, .recalled:
            throw RemoteSyncError.unsupportedLocalData("消息没有可上传的附件")
        }
    }
}

/// Future remote composition calls this instead of asking `ChatRepository` to
/// serialize a media message directly. It persists the stable remote asset ID
/// before any await, resumes with that ID after termination, and creates the
/// message outbox mutation only after server finalization.
@MainActor
final class RemoteChatMediaTransferCoordinator {
    private let context: ModelContext
    private let mediaStore: LocalMediaStore
    private let api: any RemoteMediaAPI
    private let transaction: RemoteMutationTransaction
    private var activeTransfers = Set<UUID>()

    init(context: ModelContext, mediaStore: LocalMediaStore, api: any RemoteMediaAPI,
         transaction: RemoteMutationTransaction) {
        self.context = context; self.mediaStore = mediaStore
        self.api = api; self.transaction = transaction
    }

    func transferAndQueue(_ message: ChatMessageModel) async throws {
        guard message.kind == .image || message.kind == .audio || message.kind == .file,
              message.recalledAt == nil,
              message.deletedAt == nil, message.purgedAt == nil,
              let localPath = message.mediaPath,
              MemberIdentity.remoteUUID(for: message.senderID) != nil else {
            throw RemoteSyncError.unsupportedLocalData("聊天媒体缺少可上传的本地文件")
        }
        guard message.mediaTransferState != .finalized else { return }
        guard activeTransfers.insert(message.id).inserted else { return }
        defer { activeTransfers.remove(message.id) }
        let localURL = mediaStore.url(for: localPath)
        let mediaID = message.remoteMediaID ?? UUID()

        if message.modelContext == nil { context.insert(message) }
        message.remoteMediaID = mediaID
        message.mediaTransferStateRaw = RemoteMediaTransferState.pending.rawValue
        message.mediaRetryCount = message.mediaRetryCount ?? 0
        message.mediaLastErrorCode = nil
        message.statusRaw = ReceiptStatus.sending.rawValue
        message.mediaFileName = message.kind == .file ? message.body : nil
        try context.save()

        do {
            let mimeType = try RemoteChatAttachmentType.mimeType(for: message, localURL: localURL)
            let material = try await Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return try RemoteMediaFilePreparation.load(from: localURL)
            }.value
            message.mediaContentType = mimeType
            message.mediaSizeBytes = material.data.count
            message.mediaChecksum = material.checksum
            message.mediaTransferStateRaw = RemoteMediaTransferState.uploading.rawValue
            message.mediaLastAttemptAt = .now
            try context.save()
            let uploadName = message.kind == .file ? message.body : localURL.lastPathComponent
            let grant = try await api.requestMediaUpload(mediaID: mediaID, mimeType: mimeType, sizeBytes: material.data.count, checksum: material.checksum, fileName: uploadName)
            guard grant.mediaID == mediaID, grant.status == "pending" || grant.status == "ready" else {
                throw RemoteSyncError.invalidResponse
            }
            if grant.status == "pending" {
                if let uploadURL = grant.uploadURL {
                    try await api.uploadMedia(material.data, to: uploadURL, headers: grant.uploadHeaders)
                }
            }
            let finalized = try await api.finalizeMedia(mediaID: mediaID, checksum: material.checksum)
            guard finalized.mediaID == mediaID, finalized.status == "ready",
                  message.recalledAt == nil, message.deletedAt == nil, message.purgedAt == nil else {
                throw RemoteSyncError.invalidResponse
            }
            try transaction.persist(changing: {
                message.remoteMediaID = mediaID
                message.mediaTransferStateRaw = RemoteMediaTransferState.finalized.rawValue
                message.mediaRemoteStatus = "ready"
                message.mediaLastAttemptAt = .now
                message.mediaLastErrorCode = nil
            }, intents: {
                [RemoteMutationIntent(entityType: .message, entityID: message.id, operation: .create,
                                      payload: try RemoteBusinessPayload.message(message))]
            })
        } catch is CancellationError {
            // Keep the durable pending/uploading state. A later explicit
            // resume reuses the same MediaAsset ID rather than creating one.
            throw CancellationError()
        } catch {
            message.mediaTransferStateRaw = RemoteMediaTransferState.failed.rawValue
            message.statusRaw = ReceiptStatus.failed.rawValue
            message.mediaRetryCount = min((message.mediaRetryCount ?? 0) + 1, 16)
            message.mediaLastAttemptAt = .now
            message.mediaLastErrorCode = (error as? RemoteSyncError)?.stableCode ?? "media_transfer_failed"
            do { try context.save() }
            catch { context.rollback() }
            throw error
        }
    }

    func resumeRecoverableTransfers() async {
        let messages: [ChatMessageModel]
        do { messages = try context.fetch(FetchDescriptor<ChatMessageModel>()) }
        catch { return }
        for message in messages where message.mediaTransferState == .pending || message.mediaTransferState == .uploading || message.mediaTransferState == .failed {
            guard message.recalledAt == nil else { continue }
            do { try await transferAndQueue(message) }
            catch is CancellationError { return }
            catch { continue }
        }
    }
}

/// Remote pull keeps the message row immediately. This resolver fetches an
/// authorized short-lived URL only when an attachment is explicitly opened
/// and stores only the resulting local cache filename.
@MainActor
protocol RemoteChatMediaResolving: AnyObject {
    func ensureCachedMedia(messageID: UUID) async throws -> String
}

@MainActor
final class RemoteChatMediaResolver: RemoteChatMediaResolving {
    private let context: ModelContext
    private let mediaStore: LocalMediaStore
    private let api: any RemoteMediaAPI

    init(context: ModelContext, mediaStore: LocalMediaStore, api: any RemoteMediaAPI) {
        self.context = context; self.mediaStore = mediaStore; self.api = api
    }

    func ensureCachedMedia(messageID: UUID) async throws -> String {
        guard let message = try context.fetch(FetchDescriptor<ChatMessageModel>()).first(where: { $0.id == messageID }),
              message.recalledAt == nil,
              message.deletedAt == nil, message.purgedAt == nil,
              let remoteMediaID = message.remoteMediaID,
              message.mediaRemoteStatus == nil || message.mediaRemoteStatus == "ready",
              message.kind == .image || message.kind == .audio || message.kind == .file else {
            throw RemoteSyncError.unsupportedLocalData("聊天媒体不可用")
        }
        if let localPath = message.mediaPath,
           FileManager.default.fileExists(atPath: mediaStore.url(for: localPath).path) {
            return localPath
        }
        let data = try await api.downloadMedia(mediaID: remoteMediaID)
        guard !data.isEmpty else { throw RemoteSyncError.invalidResponse }
        if let expectedSize = message.mediaSizeBytes, data.count != expectedSize { throw RemoteSyncError.invalidResponse }
        if let expectedChecksum = message.mediaChecksum {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expectedChecksum else { throw RemoteSyncError.invalidResponse }
        }
        let localPath: String
        switch message.kind {
        case .image: localPath = try mediaStore.storeImage(data)
        case .audio: localPath = try mediaStore.storeAudio(data)
        case .file: localPath = try mediaStore.storeFile(data, fileName: message.mediaFileName ?? message.body)
        case .text, .recalled: throw RemoteSyncError.invalidResponse
        }
        message.mediaPath = localPath
        do { try context.save() }
        catch {
            let saveError = error
            context.rollback()
            do { try mediaStore.remove(path: localPath) }
            catch { throw RemoteSyncError.unsupportedLocalData("附件缓存保存失败，且临时文件清理失败：\(error.localizedDescription)") }
            throw saveError
        }
        return localPath
    }
}

@MainActor
final class RemoteOutbox {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    /// Future LocalRepository composition calls this only after its local save
    /// succeeds. localOnly never enqueues mutations.
    func enqueue(_ mutation: RemoteMutation) throws {
        guard RemoteEntityType(rawValue: mutation.entityType) != nil else { throw RemoteSyncError.invalidResponse }
        let payload = try RemotePayloadCodec.string(mutation.payload)
        try atomically {
            context.insert(PendingMutationModel(id: mutation.mutationID, entityType: mutation.entityType, entityID: mutation.entityID, operation: mutation.operation.rawValue, baseVersion: mutation.baseVersion, payloadJSON: payload, clientTimestamp: mutation.clientTimestamp))
        }
    }

    func recoverInterruptedSends(now: Date = .now) throws {
        let interrupted = try mutations().filter { $0.state == .sending }
        guard !interrupted.isEmpty else { return }
        try atomically {
            for mutation in interrupted {
                mutation.stateRaw = RemoteOutboxState.pending.rawValue
                mutation.nextRetryAt = now
                mutation.lastErrorCode = "interrupted"
            }
        }
    }

    /// Marks a batch as sending and saves that state before any network await.
    /// Re-sending the same mutation IDs after a process kill is therefore safe.
    func claimNextBatch(limit: Int = 200, now: Date = .now) throws -> [RemoteMutation] {
        let candidates = try mutations()
            .filter { $0.state == .pending && ($0.nextRetryAt ?? .distantPast) <= now }
            .sorted { lhs, rhs in
                let left = RemoteEntityType(rawValue: lhs.entityType)?.pushRank ?? Int.max
                let right = RemoteEntityType(rawValue: rhs.entityType)?.pushRank ?? Int.max
                return left == right ? lhs.clientTimestamp < rhs.clientTimestamp : left < right
            }
            .prefix(max(1, min(limit, 200)))
        guard !candidates.isEmpty else { return [] }
        let values = try candidates.map(remoteMutation)
        try atomically {
            for mutation in candidates {
                mutation.stateRaw = RemoteOutboxState.sending.rawValue
                mutation.lastAttemptAt = now
                mutation.lastErrorCode = nil
            }
        }
        return values
    }

    func resolve(_ sent: [RemoteMutation], response: RemotePushResponse, now: Date = .now) throws -> (acknowledged: Int, conflicts: Int) {
        let sentIDs = Set(sent.map(\.mutationID))
        let acknowledged = Set(response.applied.map(\.mutationID))
        let conflicts = Set(response.conflicts.map(\.mutationID))
        guard response.applied.count == acknowledged.count, response.conflicts.count == conflicts.count,
              acknowledged.isDisjoint(with: conflicts), acknowledged.isSubset(of: sentIDs), conflicts.isSubset(of: sentIDs) else {
            throw RemoteSyncError.invalidResponse
        }
        let items = try mutations()
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        guard sentIDs.allSatisfy({ byID[$0]?.state == .sending }) else { throw RemoteSyncError.stateCorrupted }

        let sentByID = Dictionary(uniqueKeysWithValues: sent.map { ($0.mutationID, $0) })
        guard response.applied.allSatisfy({ acknowledgement in
            guard let local = sentByID[acknowledgement.mutationID] else { return false }
            return local.entityType == acknowledgement.entityType && local.entityID == acknowledgement.entityID
        }), response.conflicts.allSatisfy({ conflict in
            guard let local = sentByID[conflict.mutationID] else { return false }
            return local.entityType == conflict.entityType && local.entityID == conflict.entityID &&
                ["version_conflict", "tombstone_conflict"].contains(conflict.code)
        }) else { throw RemoteSyncError.invalidResponse }
        let existingConflicts = try context.fetch(FetchDescriptor<SyncConflictModel>())
        let conflictIDs = Set(existingConflicts.map(\.mutationID))
        let preparedConflicts = try response.conflicts.map { conflict -> SyncConflictModel? in
            guard let local = sentByID[conflict.mutationID] else { throw RemoteSyncError.invalidResponse }
            guard !conflictIDs.contains(conflict.mutationID) else { return nil }
            return SyncConflictModel(mutationID: conflict.mutationID, entityType: conflict.entityType, entityID: conflict.entityID, localVersion: local.baseVersion, remoteVersion: conflict.currentVersion, localPayloadJSON: try RemotePayloadCodec.string(local.payload), remoteSnapshotJSON: try conflict.currentPayload.map(RemotePayloadCodec.string), conflictTypeRaw: conflict.code, createdAt: now)
        }

        try atomically {
            for mutationID in acknowledged {
                guard let item = byID[mutationID] else { throw RemoteSyncError.stateCorrupted }
                item.stateRaw = RemoteOutboxState.acknowledged.rawValue
                item.acknowledgedAt = now
                item.nextRetryAt = nil
                item.lastErrorCode = nil
            }
            for conflict in response.conflicts {
                guard let item = byID[conflict.mutationID] else { throw RemoteSyncError.stateCorrupted }
                item.stateRaw = RemoteOutboxState.pending.rawValue
                item.nextRetryAt = .distantFuture // requires future explicit resolution
                item.lastErrorCode = "conflict.\(conflict.code)"
            }
            for mutationID in sentIDs.subtracting(acknowledged).subtracting(conflicts) {
                guard let item = byID[mutationID] else { throw RemoteSyncError.stateCorrupted }
                scheduleRetry(item, code: "unacknowledged_response", now: now)
            }
            preparedConflicts.compactMap { $0 }.forEach(context.insert)
        }
        return (acknowledged.count, conflicts.count)
    }

    func returnToPending(_ sent: [RemoteMutation], after error: Error, now: Date = .now) throws {
        let sentIDs = Set(sent.map(\.mutationID))
        let code = errorCode(for: error)
        let items = try mutations().filter { sentIDs.contains($0.id) && $0.state == .sending }
        try atomically {
            for item in items { scheduleRetry(item, code: code, now: now) }
        }
    }

    /// Acknowledged entries are retained as a small local audit trail until a
    /// future settings action chooses to archive them.
    func archiveAcknowledged() throws {
        let acknowledged = try mutations().filter { $0.state == .acknowledged }
        try atomically { acknowledged.forEach(context.delete) }
    }

    private func mutations() throws -> [PendingMutationModel] {
        try context.fetch(FetchDescriptor<PendingMutationModel>(sortBy: [SortDescriptor(\.clientTimestamp)]))
    }

    private func remoteMutation(_ item: PendingMutationModel) throws -> RemoteMutation {
        guard let operation = RemoteChangeOperation(rawValue: item.operation),
              RemoteEntityType(rawValue: item.entityType) != nil,
              item.baseVersion.map({ $0 >= 0 }) ?? true else { throw RemoteSyncError.stateCorrupted }
        return RemoteMutation(mutationID: item.id, entityType: item.entityType, entityID: item.entityID, operation: operation, baseVersion: item.baseVersion, payload: try RemotePayloadCodec.value(from: item.payloadJSON), clientTimestamp: item.clientTimestamp)
    }

    private func scheduleRetry(_ item: PendingMutationModel, code: String, now: Date) {
        item.stateRaw = RemoteOutboxState.pending.rawValue
        item.retryCount = min(item.retryCount + 1, 16)
        item.lastErrorCode = code
        let delay = min(pow(2, Double(item.retryCount)) * 15, 900)
        item.nextRetryAt = now.addingTimeInterval(delay)
    }

    private func errorCode(for error: Error) -> String {
        (error as? RemoteSyncError)?.stableCode ?? "transport_error"
    }

    private func atomically(_ work: () throws -> Void) throws {
        guard !context.hasChanges else { throw RemoteSyncError.localChangesPending }
        do {
            try work()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

extension PendingMutationModel {
    var state: RemoteOutboxState { RemoteOutboxState(rawValue: stateRaw ?? "") ?? .pending }
}

/// A future remote repository uses this instead of `save(); enqueue()` as two
/// independent actions. Business changes and their durable outbox entries share
/// one `ModelContext.save()`. The local-only composition never creates it.
struct RemoteMutationIntent {
    let entityType: RemoteEntityType
    let entityID: UUID
    let operation: RemoteChangeOperation
    let payload: [String: RemoteJSONValue]

    init(entityType: RemoteEntityType, entityID: UUID, operation: RemoteChangeOperation,
         payload: [String: RemoteJSONValue] = [:]) {
        self.entityType = entityType
        self.entityID = entityID
        self.operation = operation
        self.payload = payload
    }
}

@MainActor
final class RemoteMutationTransaction {
    private let context: ModelContext
    var didCommit: (@MainActor () -> Void)?

    init(context: ModelContext) { self.context = context }

    /// `businessData` runs before `intents` so serializers observe the exact
    /// values that will be committed. The outbox is then coalesced in the same
    /// save. An interrupted process can therefore leave either both records or
    /// neither record—never a durable business edit without its mutation.
    func persist(changing businessData: () throws -> Void,
                 intents: () throws -> [RemoteMutationIntent],
                 now: Date = .now) throws {
        guard !context.hasChanges else { throw RemoteSyncError.localChangesPending }
        do {
            try businessData()
            let planned = try intents()
            try persist(planned, now: now)
            try context.save()
            didCommit?()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func persist(_ intents: [RemoteMutationIntent], now: Date) throws {
        var seen = Set<String>()
        for intent in intents {
            let key = RemoteEntityRecordModel.key(entityType: intent.entityType.rawValue, entityID: intent.entityID)
            guard seen.insert(key).inserted else { throw RemoteSyncError.stateCorrupted }
        }

        let pending = try context.fetch(FetchDescriptor<PendingMutationModel>())
        let records = try context.fetch(FetchDescriptor<RemoteEntityRecordModel>())
        for intent in intents {
            let matches = pending.filter { $0.entityType == intent.entityType.rawValue && $0.entityID == intent.entityID && ($0.state == .pending || $0.state == .sending) }
            guard matches.count <= 1 else { throw RemoteSyncError.stateCorrupted }
            if let existing = matches.first, existing.state == .sending {
                // A request is already in flight. Mutating its payload would
                // make retry semantics non-idempotent, so reject this write
                // before a SwiftData model can be changed.
                throw RemoteSyncError.localChangesPending
            }

            let recordMatches = records.filter { $0.entityType == intent.entityType.rawValue && $0.entityID == intent.entityID }
            guard recordMatches.count <= 1 else { throw RemoteSyncError.stateCorrupted }
            let mirror = recordMatches.first

            if let existing = matches.first {
                try coalesce(intent, into: existing, mirror: mirror, now: now)
            } else {
                try insert(intent, mirror: mirror, now: now)
            }
        }
    }

    private func coalesce(_ intent: RemoteMutationIntent, into existing: PendingMutationModel,
                          mirror: RemoteEntityRecordModel?, now: Date) throws {
        guard let priorOperation = RemoteChangeOperation(rawValue: existing.operation) else {
            throw RemoteSyncError.stateCorrupted
        }
        if priorOperation == .create && intent.operation == .delete {
            context.delete(existing)
            return
        }
        if priorOperation == .delete && intent.operation == .upsert {
            // The local relation was removed and re-added before its pending
            // deletion reached the server. Its remote state is unchanged, so
            // discard the unneeded mutation rather than reviving a tombstone.
            context.delete(existing)
            return
        }
        guard priorOperation != .delete else { throw RemoteSyncError.stateCorrupted }
        guard mirror?.isTombstone != true else { throw RemoteSyncError.stateCorrupted }

        let finalOperation: RemoteChangeOperation = priorOperation == .create ? .create : intent.operation
        guard finalOperation != .upsert else { throw RemoteSyncError.stateCorrupted }
        existing.operation = finalOperation.rawValue
        existing.payloadJSON = try RemotePayloadCodec.string(finalOperation == .delete ? [:] : intent.payload)
        existing.clientTimestamp = now
        existing.lastErrorCode = nil
        existing.nextRetryAt = now
    }

    private func insert(_ intent: RemoteMutationIntent, mirror: RemoteEntityRecordModel?, now: Date) throws {
        let baseVersion: Int?
        switch intent.operation {
        case .create:
            guard mirror == nil else { throw RemoteSyncError.stateCorrupted }
            baseVersion = 0
        case .upsert:
            if mirror == nil {
                baseVersion = 0
            } else {
                // Agenda-participant identity is deterministic. Re-adding a
                // removed member is the one intentional tombstone
                // reactivation; all other entities remain non-resurrectable.
                guard intent.entityType == .agendaParticipant, mirror?.isTombstone == true else {
                    throw RemoteSyncError.stateCorrupted
                }
                baseVersion = mirror?.serverVersion
            }
        case .update, .delete:
            guard let mirror, !mirror.isTombstone, mirror.serverVersion >= 1 else {
                throw RemoteSyncError.stateCorrupted
            }
            baseVersion = mirror.serverVersion
        }
        context.insert(PendingMutationModel(
            entityType: intent.entityType.rawValue,
            entityID: intent.entityID,
            operation: intent.operation.rawValue,
            baseVersion: baseVersion,
            payloadJSON: try RemotePayloadCodec.string(intent.operation == .delete ? [:] : intent.payload),
            clientTimestamp: now
        ))
    }
}

/// Repository-facing save boundary. The default path remains exactly one local
/// SwiftData save. A future remote composition passes a transaction so the same
/// repository methods become Local Business → Outbox atomic writes without any
/// View knowing about networking or calling push directly.
@MainActor
final class BusinessWriteCoordinator {
    private let context: ModelContext
    private let remoteTransaction: RemoteMutationTransaction?

    init(context: ModelContext, remoteTransaction: RemoteMutationTransaction? = nil) {
        self.context = context
        self.remoteTransaction = remoteTransaction
    }

    var isRemoteEnabled: Bool { remoteTransaction != nil }

    func commit(changing businessData: () throws -> Void,
                intents: @escaping () throws -> [RemoteMutationIntent] = { [] }) throws {
        if let remoteTransaction {
            try remoteTransaction.persist(changing: businessData, intents: intents)
            return
        }
        do {
            try businessData()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

/// Canonical serializers for the existing local business models. Future
/// remote repositories must use these values with `RemoteMutationTransaction`
/// instead of manufacturing page-specific JSON. They intentionally omit IDs,
/// versions, timestamps and server-controlled actor fields.
enum RemoteBusinessPayload {
    private static func remoteMemberID(_ localMemberID: String) throws -> UUID {
        guard let value = MemberIdentity.remoteUUID(for: localMemberID) else { throw RemoteSyncError.stateCorrupted }
        return value
    }
    static func semester(_ value: SemesterModel) -> [String: RemoteJSONValue] {
        ["name": .string(value.name), "week1_start": .string(RemoteCivilDate.string(value.week1StartDate)), "week1_end": .string(RemoteCivilDate.string(value.week1EndDate ?? value.week1StartDate)), "total_weeks": .number(Double(value.totalWeeks)), "is_current": .bool(value.isCurrent)]
    }
    static func schedule(_ value: ScheduleEntryModel) throws -> [String: RemoteJSONValue] {
        let owner = try remoteMemberID(value.ownerID)
        return ["owner_id": .string(owner.uuidString), "semester_id": .string(value.semesterID.uuidString), "kind": .string(value.kindRaw), "title": .string(value.title), "weekday": .number(Double(value.weekday)), "start_minutes": .number(Double(value.startMinutes)), "end_minutes": .number(Double(value.endMinutes)), "start_week": .number(Double(value.startWeek)), "end_week": .number(Double(value.endWeek)), "week_type": .string(value.weekTypeRaw), "metadata_json": .object(compact(["major": value.major, "grade": value.grade, "class_name": value.className, "location": value.location, "note": value.note, "lab_name": value.labName, "advisor": value.advisor]))]
    }
    static func scheduleFingerprint(_ value: ScheduleEntryModel) throws -> String {
        // This deliberately fingerprints the protocol payload, not a
        // SwiftData snapshot. The backend can reproduce it without local-only
        // properties such as `importBatchID` or a device-specific object ID.
        try RemotePayloadCodec.string(schedule(value))
    }
    static func scheduleException(_ value: ScheduleExceptionModel) -> [String: RemoteJSONValue] {
        ["schedule_id": .string(value.scheduleID.uuidString), "scope": .string(value.scopeRaw), "kind": .string(value.kindRaw), "occurrence_date": .string(RemoteCivilDate.string(value.occurrenceDate)), "replacement_json": .object(compact(["date": value.replacementDate.map(RemoteCivilDate.string), "start_minutes": value.replacementStartMinutes.map { String($0) }, "end_minutes": value.replacementEndMinutes.map { String($0) }, "weekday": value.replacementWeekday.map { String($0) }, "note": value.note], numericKeys: ["start_minutes", "end_minutes", "weekday"]))]
    }
    static func calendarOverride(_ value: CalendarOverrideModel) -> [String: RemoteJSONValue] {
        var payload: [String: RemoteJSONValue] = ["semester_id": .string(value.semesterID.uuidString), "date": .string(RemoteCivilDate.string(value.date)), "kind": .string(value.kindRaw)]
        if let weekday = value.mappedWeekday { payload["mapped_weekday"] = .number(Double(weekday)) }
        if let note = value.note { payload["note"] = .string(note) }
        return payload
    }
    static func importBatch(_ value: ScheduleImportBatchModel) throws -> [String: RemoteJSONValue] {
        let owner = try remoteMemberID(value.ownerID)
        var payload: [String: RemoteJSONValue] = [
            "semester_id": .string(value.semesterID.uuidString),
            "owner_id": .string(owner.uuidString),
            "source": .string(value.sourceRaw)
        ]
        if let sourceFileName = value.sourceFileName { payload["source_file_name"] = .string(sourceFileName) }
        if let sourceFileType = value.sourceFileType { payload["source_file_type"] = .string(sourceFileType) }
        return payload
    }
    static func importBatchItem(batchID: UUID, scheduleID: UUID, operation: String,
                                beforeSnapshot: [String: RemoteJSONValue]?, afterFingerprint: String) -> [String: RemoteJSONValue] {
        var payload: [String: RemoteJSONValue] = [
            "batch_id": .string(batchID.uuidString),
            "schedule_id": .string(scheduleID.uuidString),
            "operation": .string(operation),
            "after_fingerprint": .string(afterFingerprint)
        ]
        if let beforeSnapshot { payload["before_snapshot"] = .object(beforeSnapshot) }
        return payload
    }
    /// The server stores this exact pre-import business shape solely for a
    /// guarded ImportBatch rollback. It never receives device-local paths or
    /// SwiftData-only bookkeeping such as `importBatchID`.
    static func scheduleSnapshot(_ value: ScheduleImportEntrySnapshot) throws -> [String: RemoteJSONValue] {
        guard let semesterID = value.semesterID else {
            throw RemoteSyncError.unsupportedLocalData("导入前课程快照不完整，不能安全远端撤销")
        }
        let owner = try remoteMemberID(value.ownerID)
        return [
            "owner_id": .string(owner.uuidString),
            "semester_id": .string(semesterID.uuidString),
            "kind": .string(value.kindRaw),
            "title": .string(value.title),
            "weekday": .number(Double(value.weekday)),
            "start_minutes": .number(Double(value.startMinutes)),
            "end_minutes": .number(Double(value.endMinutes)),
            "start_week": .number(Double(value.startWeek)),
            "end_week": .number(Double(value.endWeek)),
            "week_type": .string(value.weekTypeRaw),
            "metadata_json": .object(compact([
                "major": value.major, "grade": value.grade, "class_name": value.className,
                "location": value.location, "note": value.note,
                "lab_name": value.labName, "advisor": value.advisor
            ]))
        ]
    }
    static func agenda(_ value: AgendaItemModel) throws -> [String: RemoteJSONValue] {
        let creator = try remoteMemberID(value.creatorID)
        var payload: [String: RemoteJSONValue] = ["creator_id": .string(creator.uuidString), "kind": .string(value.kindRaw), "title": .string(value.title), "detail_json": .object(compact(["location": value.location, "note": value.note, "dishes": value.dishes, "ingredients": value.ingredients, "seasonings": value.seasonings, "people_count": value.peopleCount.map { String($0) }, "estimated_arrival": value.estimatedArrival.map { RemoteWireDate.string(from: $0) }, "desired_meal_time": value.desiredMealTime.map { RemoteWireDate.string(from: $0) }, "preparation": value.preparationRaw, "completion": value.completionRaw], numericKeys: ["people_count"]))]
        if let start = value.start { payload["start_at"] = .string(RemoteWireDate.string(from: start)) }
        if let end = value.end { payload["end_at"] = .string(RemoteWireDate.string(from: end)) }
        if let due = value.dueAt { payload["due_at"] = .string(RemoteWireDate.string(from: due)) }
        if value.recurrence != .none { payload["recurrence_rule"] = .object(compact(["raw": value.recurrenceRaw, "end_at": value.recurrenceEnd.map { RemoteWireDate.string(from: $0) }])) }
        return payload
    }
    static func agendaParticipant(agendaID: UUID, memberID: String) throws -> [String: RemoteJSONValue] { ["agenda_id": .string(agendaID.uuidString), "member_id": .string(try remoteMemberID(memberID).uuidString)] }
    static func foodRead(agendaID: UUID, memberID: String, readAt: Date) throws -> [String: RemoteJSONValue] {
        ["agenda_id": .string(agendaID.uuidString), "member_id": .string(try remoteMemberID(memberID).uuidString), "read_at": .string(RemoteWireDate.string(from: readAt))]
    }
    static func agendaException(_ value: AgendaExceptionModel) -> [String: RemoteJSONValue] {
        let replacement = compact(["date": value.replacementDate.map(RemoteCivilDate.string), "start_at": value.replacementStart.map { RemoteWireDate.string(from: $0) }, "end_at": value.replacementEnd.map { RemoteWireDate.string(from: $0) }])
        return ["agenda_id": .string(value.agendaID.uuidString), "scope": .string(value.scopeRaw), "kind": .string(value.kindRaw), "occurrence_date": .string(RemoteCivilDate.string(value.occurrenceDate)), "replacement_json": .object(replacement)]
    }
    static func memo(_ value: MemoModel) throws -> [String: RemoteJSONValue] {
        let creator = try remoteMemberID(value.creatorID), updatedBy = try remoteMemberID(value.updatedBy)
        var payload: [String: RemoteJSONValue] = ["creator_id": .string(creator.uuidString), "updated_by": .string(updatedBy.uuidString), "content": .string(value.content), "pinned": .bool(value.pinned)]
        if let title = value.title { payload["title"] = .string(title) }; return payload
    }
    static func notice(_ value: NoticeModel) throws -> [String: RemoteJSONValue] {
        let publisher = try remoteMemberID(value.publisherID)
        return ["publisher_id": .string(publisher.uuidString), "title": .string(value.title), "content": .string(value.content), "pinned": .bool(value.pinned)]
    }
    static func noticeRead(_ value: NoticeReadModel) throws -> [String: RemoteJSONValue] {
        let member = try remoteMemberID(value.memberID)
        return ["notice_id": .string(value.noticeID.uuidString), "member_id": .string(member.uuidString), "read_at": .string(RemoteWireDate.string(from: value.readAt))]
    }
    static func message(_ value: ChatMessageModel) throws -> [String: RemoteJSONValue] {
        let sender = try remoteMemberID(value.senderID)
        if value.kind == .image || value.kind == .audio || value.kind == .file {
            guard value.recalledAt == nil,
                  let remoteMediaID = value.remoteMediaID,
                  value.mediaTransferState == .finalized else {
                // A local cache path is never a wire attachment. The upload
                // coordinator must first finalize a stable MediaAsset.
                throw RemoteSyncError.unsupportedLocalData("聊天媒体尚未完成远端上传")
            }
            var payload: [String: RemoteJSONValue] = [
                "chat_id": .string(FamilyRemoteIdentity.sharedChatUUID.uuidString),
                "sender_id": .string(sender.uuidString),
                "kind": .string(value.kindRaw), "body": .string(value.body),
                "sent_at": .string(RemoteWireDate.string(from: value.sentAt)),
                "media_id": .string(remoteMediaID.uuidString)
            ]
            if let reply = value.replyToID { payload["reply_to_id"] = .string(reply.uuidString) }
            return payload
        }
        var payload: [String: RemoteJSONValue] = ["chat_id": .string(FamilyRemoteIdentity.sharedChatUUID.uuidString), "sender_id": .string(sender.uuidString), "kind": .string(value.kindRaw), "body": .string(value.body), "sent_at": .string(RemoteWireDate.string(from: value.sentAt))]
        if let reply = value.replyToID { payload["reply_to_id"] = .string(reply.uuidString) }
        if let recalled = value.recalledAt {
            // Explicit null detaches a formerly ready asset. Otherwise the
            // server would retain `media_id` during a partial update and keep
            // authorizing downloads for a recalled message.
            payload["recalled_at"] = .string(RemoteWireDate.string(from: recalled))
            payload["media_id"] = .null
        }
        return payload
    }
    static func receipt(_ value: MessageReceiptModel) throws -> [String: RemoteJSONValue] {
        let member = try remoteMemberID(value.memberID)
        var payload: [String: RemoteJSONValue] = ["message_id": .string(value.messageID.uuidString), "member_id": .string(member.uuidString)]
        if let delivered = value.deliveredAt { payload["delivered_at"] = .string(RemoteWireDate.string(from: delivered)) }; if let read = value.readAt { payload["read_at"] = .string(RemoteWireDate.string(from: read)) }; return payload
    }
    static func location(_ value: LocationSnapshotModel) throws -> [String: RemoteJSONValue] {
        let member = try remoteMemberID(value.memberID)
        var payload: [String: RemoteJSONValue] = ["member_id": .string(member.uuidString), "latitude": .number(value.latitude), "longitude": .number(value.longitude), "captured_at": .string(RemoteWireDate.string(from: value.timestamp))]
        if let event = value.event { payload["event_type"] = .string(event) }
        if let accuracy = value.horizontalAccuracy { payload["horizontal_accuracy"] = .number(accuracy) }
        if let source = value.sourceRaw { payload["source"] = .string(source) }
        return payload
    }
    static func place(_ value: FamilyPlaceModel) throws -> [String: RemoteJSONValue] {
        guard let rawMember = value.memberID else { throw RemoteSyncError.stateCorrupted }
        let member = try remoteMemberID(rawMember)
        return ["member_id": .string(member.uuidString), "type": .string(value.kindRaw), "name": .string(value.name), "latitude": .number(value.latitude), "longitude": .number(value.longitude), "radius_m": .number(Double(Int(value.radius))), "enabled": .bool(value.isEnabled ?? true)]
    }
    static func status(_ value: MemberStatusModel) throws -> (entityID: UUID, payload: [String: RemoteJSONValue]) {
        let member = try remoteMemberID(value.memberID)
        var payload: [String: RemoteJSONValue] = ["member_id": .string(member.uuidString), "status_raw": .string(value.statusRaw)]
        if let arrival = value.estimatedArrival { payload["estimated_arrival"] = .string(RemoteWireDate.string(from: arrival)) }
        return (RemoteStableID.memberStatus(memberID: value.memberID), payload)
    }

    private static func compact(_ strings: [String: String?], numericKeys: Set<String> = []) -> [String: RemoteJSONValue] {
        strings.reduce(into: [:]) { result, pair in
            guard let value = pair.value else { return }
            result[pair.key] = numericKeys.contains(pair.key) ? Double(value).map(RemoteJSONValue.number) ?? .string(value) : .string(value)
        }
    }
}

/// Relation tables have no local UUID column today. These deterministic IDs
/// keep idempotency stable across a retry and across devices without treating a
/// display string as identity. They are identifiers, not cryptographic values.
enum RemoteStableID {
    static func trashMutation(entityType: String, entityID: UUID, version: Int, permanent: Bool) -> UUID {
        uuid("trash|\(entityType)|\(entityID.uuidString.lowercased())|\(version)|\(permanent ? "purge" : "restore")")
    }
    static func agendaParticipant(agendaID: UUID, memberID: String) throws -> UUID {
        uuid("agendaParticipant|\(agendaID.uuidString.lowercased())|\(try remoteMemberID(memberID).uuidString.lowercased())")
    }

    static func foodRead(agendaID: UUID, memberID: String) throws -> UUID {
        uuid("foodRead|\(agendaID.uuidString.lowercased())|\(try remoteMemberID(memberID).uuidString.lowercased())")
    }

    static func messageReceipt(messageID: UUID, memberID: String) throws -> UUID {
        uuid("messageReceipt|\(messageID.uuidString.lowercased())|\(try remoteMemberID(memberID).uuidString.lowercased())")
    }

    static func memberStatus(memberID: String) -> UUID {
        if let initial = MemberID(rawValue: memberID) { return initial.remoteStatusUUID }
        return uuid("memberStatus|\(memberID.lowercased())")
    }

    private static func remoteMemberID(_ localMemberID: String) throws -> UUID {
        guard let value = MemberIdentity.remoteUUID(for: localMemberID) else { throw RemoteSyncError.stateCorrupted }
        return value
    }

    static func importBatchItem(batchID: UUID, scheduleID: UUID) -> UUID {
        uuid("importBatchItem|\(batchID.uuidString.lowercased())|\(scheduleID.uuidString.lowercased())")
    }

    private static func uuid(_ value: String) -> UUID {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4
        for byte in value.utf8 {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte)) &* 0x100000001b3
        }
        var bytes: [UInt8] = []
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((first >> UInt64(shift)) & 0xff)) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((second >> UInt64(shift)) & 0xff)) }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

private nonisolated enum RemoteCivilDate {
    static func string(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct RemoteRecordState: Sendable, Equatable {
    let entityType: RemoteEntityType
    let entityID: UUID
    let serverVersion: Int
    let isTombstone: Bool
    let payloadJSON: String?
    let lastSequence: Int
    let serverUpdatedAt: String?

    init(entityType: RemoteEntityType, entityID: UUID, serverVersion: Int, isTombstone: Bool, payloadJSON: String?, lastSequence: Int, serverUpdatedAt: String?) {
        self.entityType = entityType; self.entityID = entityID; self.serverVersion = serverVersion
        self.isTombstone = isTombstone; self.payloadJSON = payloadJSON
        self.lastSequence = lastSequence; self.serverUpdatedAt = serverUpdatedAt
    }

    init(model: RemoteEntityRecordModel) throws {
        guard let entityType = RemoteEntityType(rawValue: model.entityType), model.serverVersion >= 1, model.lastSequence >= 0 else {
            throw RemoteSyncError.stateCorrupted
        }
        guard model.entityKey == RemoteEntityRecordModel.key(entityType: model.entityType, entityID: model.entityID) else {
            throw RemoteSyncError.stateCorrupted
        }
        if model.isTombstone {
            guard model.payloadJSON == nil else { throw RemoteSyncError.stateCorrupted }
        } else {
            guard let payloadJSON = model.payloadJSON,
                  try RemotePayload.id(from: RemotePayloadCodec.value(from: payloadJSON)) == model.entityID else {
                throw RemoteSyncError.stateCorrupted
            }
        }
        self.entityType = entityType; self.entityID = model.entityID; self.serverVersion = model.serverVersion
        self.isTombstone = model.isTombstone; self.payloadJSON = model.payloadJSON
        self.lastSequence = model.lastSequence; self.serverUpdatedAt = model.serverUpdatedAt
    }

    init(snapshotType: RemoteEntityType, payload: [String: RemoteJSONValue], cursor: Int) throws {
        let entityID = try RemotePayload.id(from: payload)
        let version = try RemotePayload.version(from: payload, entityType: snapshotType)
        self.entityType = snapshotType; self.entityID = entityID; self.serverVersion = version
        self.isTombstone = false; self.payloadJSON = try RemotePayloadCodec.string(payload)
        self.lastSequence = cursor; self.serverUpdatedAt = RemotePayload.string("updated_at", from: payload)
    }

    static func from(change: RemoteChange, entityType: RemoteEntityType) throws -> RemoteRecordState {
        guard change.sequence > 0, change.version >= 1 else { throw RemoteSyncError.malformedChange("序号或版本无效") }
        guard change.operation != .delete, let payload = change.payload else { throw RemoteSyncError.malformedChange("缺少创建实体所需内容") }
        guard try RemotePayload.id(from: payload) == change.entityID else { throw RemoteSyncError.malformedChange("实体 ID 不一致") }
        guard change.version == 1 || (change.operation == .upsert && entityType.supportsAuthoritativeRestore) else {
            throw RemoteSyncError.malformedChange("缺少实体的历史版本")
        }
        return RemoteRecordState(entityType: entityType, entityID: change.entityID, serverVersion: change.version, isTombstone: false, payloadJSON: try RemotePayloadCodec.string(payload), lastSequence: change.sequence, serverUpdatedAt: change.updatedAt)
    }

    func applying(_ change: RemoteChange) throws -> RemoteRecordState {
        guard entityID == change.entityID else { throw RemoteSyncError.malformedChange("实体 ID 不一致") }
        if change.version < serverVersion { return self }
        if change.version == serverVersion { return try validatingDuplicate(change) }
        guard change.version == serverVersion + 1 else { throw RemoteSyncError.malformedChange("实体版本不连续") }
        switch change.operation {
        case .delete:
            guard !entityType.isAppendOnly, change.payload == nil else { throw RemoteSyncError.malformedChange("删除内容无效") }
            return RemoteRecordState(entityType: entityType, entityID: entityID, serverVersion: change.version, isTombstone: true, payloadJSON: nil, lastSequence: change.sequence, serverUpdatedAt: change.updatedAt)
        case .create, .update, .upsert:
            guard let payload = change.payload, try RemotePayload.id(from: payload) == entityID else { throw RemoteSyncError.malformedChange("更新内容无效") }
            guard !isTombstone || (change.operation == .upsert && entityType.supportsAuthoritativeRestore) else {
                throw RemoteSyncError.malformedChange("删除实体不能被静默复活")
            }
            return RemoteRecordState(entityType: entityType, entityID: entityID, serverVersion: change.version, isTombstone: false, payloadJSON: try RemotePayloadCodec.string(payload), lastSequence: change.sequence, serverUpdatedAt: change.updatedAt)
        }
    }

    private func validatingDuplicate(_ change: RemoteChange) throws -> RemoteRecordState {
        switch change.operation {
        case .delete:
            guard isTombstone else { throw RemoteSyncError.malformedChange("相同版本删除不一致") }
        case .create, .update, .upsert:
            guard !isTombstone, let payload = change.payload,
                  try RemotePayload.id(from: payload) == entityID,
                  try RemotePayloadCodec.string(payload) == payloadJSON else {
                throw RemoteSyncError.malformedChange("相同版本内容不一致")
            }
        }
        return self
    }
}

/// Applies validated remote records to the existing SwiftData business models.
/// The mirror is retained only for version/tombstone diagnostics; it is never a
/// second source read by the UI. This type remains dormant while runtimeMode
/// is localOnly.
@MainActor
private final class RemoteBusinessChangeApplier {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    @discardableResult
    func apply(_ states: [RemoteRecordState], sources: [String: UUID?] = [:]) throws -> Set<UUID> {
        let pending = try context.fetch(FetchDescriptor<PendingMutationModel>())
        var removedMemberIDs = Set<UUID>()
        for state in states.sorted(by: { lhs, rhs in
            if lhs.entityType.applyRank != rhs.entityType.applyRank {
                return lhs.entityType.applyRank < rhs.entityType.applyRank
            }
            if lhs.entityType.rawValue != rhs.entityType.rawValue {
                return lhs.entityType.rawValue < rhs.entityType.rawValue
            }
            return lhs.entityID.uuidString < rhs.entityID.uuidString
        }) {
            let sourceMutationID = sources[state.key] ?? nil
            let conflicting = pending.filter { mutation in
                let belongsToSource = sourceMutationID.map { $0 == mutation.id } ?? false
                return mutation.entityType == state.entityType.rawValue && mutation.entityID == state.entityID &&
                    (mutation.state == .pending || mutation.state == .sending) && !belongsToSource
            }
            // Membership removal is authority data. A stale local member
            // mutation becomes a conflict, but cannot keep the member active.
            if state.entityType == .member, state.isTombstone {
                removedMemberIDs.insert(state.entityID)
                if !conflicting.isEmpty { try preserveConflicts(conflicting, against: state) }
                try apply(state)
                continue
            }
            if !conflicting.isEmpty {
                try preserveConflicts(conflicting, against: state)
                continue
            }
            try apply(state)
        }
        return removedMemberIDs
    }

    private func preserveConflicts(_ mutations: [PendingMutationModel], against state: RemoteRecordState) throws {
        let existing = Set(try context.fetch(FetchDescriptor<SyncConflictModel>()).map(\.mutationID))
        for mutation in mutations where !existing.contains(mutation.id) {
            context.insert(SyncConflictModel(
                mutationID: mutation.id, entityType: mutation.entityType, entityID: mutation.entityID,
                localVersion: mutation.baseVersion, remoteVersion: state.serverVersion,
                localPayloadJSON: mutation.payloadJSON, remoteSnapshotJSON: state.payloadJSON,
                conflictTypeRaw: state.isTombstone ? "remote_tombstone" : "remote_newer_version"
            ))
            mutation.stateRaw = RemoteOutboxState.pending.rawValue
            mutation.nextRetryAt = .distantFuture
            mutation.lastErrorCode = "conflict.remote_newer_version"
        }
    }

    private func apply(_ state: RemoteRecordState) throws {
        let fields = try fields(for: state)
        switch state.entityType {
        case .member: try applyMember(state, fields)
        case .semester: try applySemester(state, fields)
        case .schedule: try applySchedule(state, fields)
        case .scheduleException: try applyScheduleException(state, fields)
        case .calendarOverride: try applyCalendarOverride(state, fields)
        case .importBatch: try applyImportBatch(state, fields)
        case .importBatchItem: try applyImportBatchItem(state, fields)
        case .agenda: try applyAgenda(state, fields)
        case .agendaException: try applyAgendaException(state, fields)
        case .agendaParticipant: try applyAgendaParticipant(state, fields)
        case .foodRead: try applyFoodRead(state, fields)
        case .memo: try applyMemo(state, fields)
        case .notice: try applyNotice(state, fields)
        case .noticeRead: try applyNoticeRead(state, fields)
        case .message: try applyMessage(state, fields)
        case .messageReceipt: try applyMessageReceipt(state, fields)
        case .locationSnapshot: try applyLocationSnapshot(state, fields)
        case .memberPlace: try applyMemberPlace(state, fields)
        case .memberStatus: try applyMemberStatus(state, fields)
        // The mirror remains the version ledger. Only the attachment display
        // fields are cached on the existing Message row; never a second media
        // business model or a persisted presigned URL.
        case .mediaAsset: try applyMediaAsset(state, fields)
        case .geofenceEvent: break
        }
    }

    private func applyMember(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        let localID = MemberIdentity.localMemberID(for: state.entityID)
        if state.isTombstone {
            // Never erase a profile: historical business rows still refer to
            // this stable local key. The server's UUID-backed policy prevents
            // initial members from reaching this branch.
            guard !MemberIdentity.isInitialMember(localID) else {
                throw RemoteSyncError.malformedChange("初始成员不能被移除")
            }
            guard let removedAt = state.serverUpdatedAt else {
                throw RemoteSyncError.malformedChange("成员移除缺少服务端时间")
            }
            if let profile = try context.fetch(FetchDescriptor<MemberProfile>()).first(where: {
                $0.stableRemoteID == state.entityID || $0.memberID == localID
            }) {
                profile.isActive = false
                profile.removedAt = try RemoteDateCodec.date(removedAt, field: "member removal time")
            }
            return
        }
        let memberKey = fields.string("member_key") ?? localID
        let displayName = try fields.requiredString("display_name")
        let avatar = fields.string("avatar_symbol")
        let profile = try context.fetch(FetchDescriptor<MemberProfile>()).first {
            $0.stableRemoteID == state.entityID || $0.memberID == localID || $0.memberID == memberKey
        } ?? MemberProfile(memberID: localID, nickname: displayName, colorKey: localID, avatarSymbol: avatar, remoteMemberID: state.entityID, isInitialMember: MemberIdentity.isInitialMember(localID))
        profile.nickname = displayName
        profile.avatarSymbol = avatar ?? profile.avatarSymbol
        profile.remoteMemberID = state.entityID
        profile.isInitialMember = MemberIdentity.isInitialMember(localID)
        if let removedAt = fields.string("deleted_at") {
            guard !MemberIdentity.isInitialMember(localID) else {
                throw RemoteSyncError.malformedChange("初始成员不能被移除")
            }
            profile.isActive = false
            profile.removedAt = try RemoteDateCodec.date(removedAt, field: "member removal time")
        } else {
            profile.isActive = true
            profile.removedAt = nil
        }
        if profile.modelContext == nil { context.insert(profile) }
    }

    private func localMemberID(_ remoteID: UUID) -> String {
        MemberIdentity.localMemberID(for: remoteID)
    }

    private func fields(for state: RemoteRecordState) throws -> RemoteFields {
        if let payload = state.payloadJSON { return RemoteFields(try RemotePayloadCodec.value(from: payload)) }
        // Tombstones carry no payload. Recover the prior identity fields from
        // the diagnostic mirror before it is replaced in the enclosing save.
        let prior = try context.fetch(FetchDescriptor<RemoteEntityRecordModel>()).first {
            $0.entityType == state.entityType.rawValue && $0.entityID == state.entityID
        }
        guard let payload = prior?.payloadJSON else { return RemoteFields([:]) }
        return RemoteFields(try RemotePayloadCodec.value(from: payload))
    }

    private func applySemester(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        guard !state.isTombstone else { try deleteSemester(id: state.entityID); return }
        let item = try semester(id: state.entityID) ?? SemesterModel(id: state.entityID, name: "", week1StartDate: .now, totalWeeks: 1)
        item.name = try fields.requiredString("name")
        item.week1StartDate = try fields.requiredCivilDate("week1_start")
        item.week1EndDate = try fields.requiredCivilDate("week1_end")
        item.totalWeeks = try fields.requiredInt("total_weeks")
        item.isCurrent = try fields.requiredBool("is_current")
        insertIfNeeded(item)
    }

    private func applySchedule(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        guard !state.isTombstone else { try deleteSchedule(id: state.entityID); return }
        let owner = localMemberID(try fields.requiredUUID("owner_id"))
        guard let kind = ScheduleKind(rawValue: try fields.requiredString("kind")),
              let weekType = WeekType(rawValue: try fields.requiredString("week_type")) else { throw RemoteSyncError.malformedChange("课程成员或规则无效") }
        let metadata = RemoteFields(fields.object("metadata_json") ?? [:])
        let item = try schedule(id: state.entityID) ?? ScheduleEntryModel(id: state.entityID, ownerID: owner, semesterID: try fields.requiredUUID("semester_id"), title: "", kind: kind, weekday: 1, startMinutes: 0, endMinutes: 1, startWeek: 1, endWeek: 1, weekType: weekType)
        item.ownerID = owner; item.semesterID = try fields.requiredUUID("semester_id")
        item.title = try fields.requiredString("title"); item.kindRaw = kind.rawValue
        item.weekday = try fields.requiredInt("weekday"); item.startMinutes = try fields.requiredInt("start_minutes")
        item.endMinutes = try fields.requiredInt("end_minutes"); item.startWeek = try fields.requiredInt("start_week")
        item.endWeek = try fields.requiredInt("end_week"); item.weekTypeRaw = weekType.rawValue
        item.major = metadata.string("major"); item.grade = metadata.string("grade"); item.className = metadata.string("class_name")
        item.location = metadata.string("location"); item.note = metadata.string("note")
        item.labName = metadata.string("lab_name"); item.advisor = metadata.string("advisor")
        insertIfNeeded(item)
    }

    private func applyScheduleException(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        guard !state.isTombstone else { try delete(ScheduleExceptionModel.self, id: state.entityID); return }
        guard let kind = ExceptionKind(rawValue: try fields.requiredString("kind")),
              let scope = ExceptionScope(rawValue: try fields.requiredString("scope")) else { throw RemoteSyncError.malformedChange("课程例外规则无效") }
        let replacement = RemoteFields(fields.object("replacement_json") ?? [:])
        let item = try scheduleException(id: state.entityID) ?? ScheduleExceptionModel(id: state.entityID, scheduleID: try fields.requiredUUID("schedule_id"), kind: kind, scope: scope, occurrenceDate: try fields.requiredCivilDate("occurrence_date"))
        item.scheduleID = try fields.requiredUUID("schedule_id"); item.kindRaw = kind.rawValue; item.scopeRaw = scope.rawValue
        item.occurrenceDate = try fields.requiredCivilDate("occurrence_date")
        item.replacementDate = try replacement.civilDate("date"); item.replacementStartMinutes = replacement.int("start_minutes")
        item.replacementEndMinutes = replacement.int("end_minutes"); item.replacementWeekday = replacement.int("weekday")
        item.note = replacement.string("note")
        insertIfNeeded(item)
    }

    private func applyCalendarOverride(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        guard !state.isTombstone else { try delete(CalendarOverrideModel.self, id: state.entityID); return }
        guard let kind = CalendarOverrideKind(rawValue: try fields.requiredString("kind")) else { throw RemoteSyncError.malformedChange("校历规则无效") }
        let item = try calendarOverride(id: state.entityID) ?? CalendarOverrideModel(id: state.entityID, semesterID: try fields.requiredUUID("semester_id"), date: try fields.requiredCivilDate("date"), kind: kind)
        item.semesterID = try fields.requiredUUID("semester_id"); item.date = try fields.requiredCivilDate("date")
        item.kindRaw = kind.rawValue; item.mappedWeekday = fields.int("mapped_weekday"); item.note = fields.string("note")
        insertIfNeeded(item)
    }

    private func applyImportBatch(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        guard !state.isTombstone else { try delete(ScheduleImportBatchModel.self, id: state.entityID); return }
        let owner = localMemberID(try fields.requiredUUID("owner_id"))
        let item = try importBatch(id: state.entityID) ?? ScheduleImportBatchModel(id: state.entityID, semesterID: try fields.requiredUUID("semester_id"), ownerID: owner, source: try fields.requiredString("source"))
        item.semesterID = try fields.requiredUUID("semester_id"); item.ownerID = owner; item.sourceRaw = try fields.requiredString("source")
        item.createdAt = try fields.requiredDate("created_at"); item.sourceFileName = fields.string("source_file_name")
        item.sourceFileType = fields.string("source_file_type")
        insertIfNeeded(item)
    }

    private func applyImportBatchItem(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        let batchID = try fields.requiredUUID("batch_id")
        guard let batch = try importBatch(id: batchID) else { return }
        let scheduleID = try fields.requiredUUID("schedule_id").uuidString
        if state.isTombstone {
            batch.importedEntryIDs.removeAll { $0 == scheduleID }
            return
        }
        if !batch.importedEntryIDs.contains(scheduleID) { batch.importedEntryIDs.append(scheduleID) }
    }

    private func applyAgenda(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        guard !state.isTombstone else { try deleteAgenda(id: state.entityID); return }
        let creator = localMemberID(try fields.requiredUUID("creator_id"))
        guard let kind = AgendaKind(rawValue: try fields.requiredString("kind")) else { throw RemoteSyncError.malformedChange("日程类型无效") }
        let detail = RemoteFields(fields.object("detail_json") ?? [:])
        let recurrence = RemoteFields(fields.object("recurrence_rule") ?? [:])
        let recurrenceRaw = recurrence.string("raw") ?? recurrence.string("kind") ?? "none"
        guard let recurrenceValue = AgendaRecurrence(rawValue: recurrenceRaw) else { throw RemoteSyncError.malformedChange("日程重复规则无效") }
        let item = try agenda(id: state.entityID) ?? AgendaItemModel(id: state.entityID, creatorID: creator, title: "", kind: kind, participantIDs: [])
        item.creatorID = creator; item.title = try fields.requiredString("title"); item.kindRaw = kind.rawValue
        item.start = try fields.date("start_at"); item.end = try fields.date("end_at"); item.dueAt = try fields.date("due_at")
        item.recurrenceRaw = recurrenceValue.rawValue; item.recurrenceEnd = try recurrence.date("end_at") ?? recurrence.date("end")
        item.location = detail.string("location"); item.note = detail.string("note"); item.dishes = detail.string("dishes")
        item.ingredients = detail.string("ingredients"); item.seasonings = detail.string("seasonings")
        item.peopleCount = detail.int("people_count"); item.estimatedArrival = try detail.date("estimated_arrival")
        item.desiredMealTime = try detail.date("desired_meal_time"); item.preparationRaw = detail.string("preparation")
        item.completionRaw = detail.string("completion")
        insertIfNeeded(item)
    }

    private func applyAgendaException(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        guard !state.isTombstone else { try delete(AgendaExceptionModel.self, id: state.entityID); return }
        guard let kind = ExceptionKind(rawValue: try fields.requiredString("kind")),
              let scope = ExceptionScope(rawValue: try fields.requiredString("scope")) else { throw RemoteSyncError.malformedChange("日程例外规则无效") }
        let replacement = RemoteFields(fields.object("replacement_json") ?? [:])
        let item = try agendaException(id: state.entityID) ?? AgendaExceptionModel(id: state.entityID, agendaID: try fields.requiredUUID("agenda_id"), kind: kind, scope: scope, occurrenceDate: try fields.requiredCivilDate("occurrence_date"))
        item.agendaID = try fields.requiredUUID("agenda_id"); item.kindRaw = kind.rawValue; item.scopeRaw = scope.rawValue
        item.occurrenceDate = try fields.requiredCivilDate("occurrence_date"); item.replacementDate = try replacement.civilDate("date")
        item.replacementStart = try replacement.date("start_at"); item.replacementEnd = try replacement.date("end_at")
        item.note = replacement.string("note")
        insertIfNeeded(item)
    }

    private func applyAgendaParticipant(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        let member = localMemberID(try fields.requiredUUID("member_id"))
        let agendaID = try fields.requiredUUID("agenda_id")
        guard let item = try agenda(id: agendaID) else { throw RemoteSyncError.malformedChange("日程参与成员缺少父日程") }
        if state.isTombstone {
            item.participantIDs.removeAll { $0 == member }
        } else if !item.participantIDs.contains(member) {
            item.participantIDs.append(member)
        }
    }

    private func applyFoodRead(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        let member = localMemberID(try fields.requiredUUID("member_id"))
        let agendaID = try fields.requiredUUID("agenda_id")
        guard let item = try agenda(id: agendaID) else { return }
        if state.isTombstone {
            item.foodReadAtRecords = (item.foodReadAtRecords ?? []).filter { !$0.hasPrefix("\(member)|") }
            item.foodReadByIDs = item.foodReadReceipts.map(\.memberID)
            return
        }
        let readAt = try fields.requiredDate("read_at")
        let receipt = "\(member)|\(readAt.timeIntervalSince1970)"
        var records = (item.foodReadAtRecords ?? []).filter { !$0.hasPrefix("\(member)|") }
        records.append(receipt); item.foodReadAtRecords = records
        item.foodReadByIDs = item.foodReadReceipts.map(\.memberID)
    }

    private func applyMemo(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        guard !state.isTombstone else { try delete(MemoModel.self, id: state.entityID); return }
        let creator = localMemberID(try fields.requiredUUID("creator_id")), updatedBy = localMemberID(try fields.requiredUUID("updated_by"))
        let item = try memo(id: state.entityID) ?? MemoModel(id: state.entityID, content: "", creatorID: creator, updatedBy: updatedBy)
        item.title = fields.string("title"); item.content = try fields.requiredString("content"); item.creatorID = creator
        item.pinned = try fields.requiredBool("pinned"); item.version = state.serverVersion
        item.createdAt = try fields.requiredDate("created_at"); item.updatedAt = try fields.requiredDate("updated_at"); item.updatedBy = updatedBy
        insertIfNeeded(item)
    }

    private func applyNotice(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        guard !state.isTombstone else { try deleteNotice(id: state.entityID); return }
        let publisher = localMemberID(try fields.requiredUUID("publisher_id"))
        let createdAt = try fields.requiredDate("created_at"), updatedAt = try fields.requiredDate("updated_at")
        let item = try notice(id: state.entityID) ?? NoticeModel(id: state.entityID, title: "", content: "", publisherID: publisher)
        item.title = try fields.requiredString("title"); item.content = try fields.requiredString("content"); item.publisherID = publisher
        item.pinned = try fields.requiredBool("pinned"); item.createdAt = createdAt; item.updatedAt = updatedAt; item.isEdited = createdAt != updatedAt
        insertIfNeeded(item)
    }

    private func applyNoticeRead(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        let member = localMemberID(try fields.requiredUUID("member_id"))
        if state.isTombstone { try delete(NoticeReadModel.self, id: state.entityID); return }
        let noticeID = try fields.requiredUUID("notice_id"), readAt = try fields.requiredDate("read_at")
        let item = try noticeRead(id: state.entityID) ?? NoticeReadModel(id: state.entityID, noticeID: noticeID, memberID: member, readAt: readAt)
        item.noticeID = noticeID; item.memberID = member; item.readAt = readAt; insertIfNeeded(item)
    }

    private func applyMessage(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        guard !state.isTombstone else { try deleteMessage(id: state.entityID); return }
        let sender = localMemberID(try fields.requiredUUID("sender_id"))
        guard let kind = MessageKind(rawValue: try fields.requiredString("kind")) else { throw RemoteSyncError.malformedChange("聊天消息类型无效") }
        let remoteMediaID: UUID?
        if kind == .image || kind == .audio || kind == .file {
            guard let value = try fields.uuid("media_id") else {
                throw RemoteSyncError.malformedChange("媒体消息缺少远端资源 ID")
            }
            remoteMediaID = value
        } else {
            remoteMediaID = nil
        }
        let item = try message(id: state.entityID) ?? ChatMessageModel(id: state.entityID, senderID: sender, kind: kind)
        let previousMediaID = item.remoteMediaID
        item.senderID = sender; item.body = fields.string("body") ?? ""; item.kindRaw = kind.rawValue
        item.sentAt = try fields.requiredDate("sent_at"); item.replyToID = try fields.uuid("reply_to_id")
        item.recalledAt = try fields.date("recalled_at"); item.statusRaw = ReceiptStatus.sent.rawValue
        item.remoteMediaID = remoteMediaID
        item.mediaTransferStateRaw = remoteMediaID == nil ? nil : RemoteMediaTransferState.finalized.rawValue
        if previousMediaID != remoteMediaID {
            item.mediaPath = nil
            item.mediaFileName = nil; item.mediaContentType = nil
            item.mediaSizeBytes = nil; item.mediaRemoteStatus = nil; item.mediaChecksum = nil
        }
        if remoteMediaID == nil {
            item.mediaPath = nil
            item.mediaFileName = nil; item.mediaContentType = nil
            item.mediaSizeBytes = nil; item.mediaRemoteStatus = nil; item.mediaChecksum = nil
        } else if let remoteMediaID {
            // A media change can precede the Message in a later pull page.
            // Reuse its versioned mirror payload if it was already committed.
            let asset = try context.fetch(FetchDescriptor<RemoteEntityRecordModel>()).first {
                $0.entityType == RemoteEntityType.mediaAsset.rawValue && $0.entityID == remoteMediaID
            }
            if let asset, !asset.isTombstone, let payload = asset.payloadJSON {
                let mediaFields = RemoteFields(try RemotePayloadCodec.value(from: payload))
                guard try mediaFields.requiredUUID("owner_id") == MemberIdentity.remoteUUID(for: sender) else {
                    throw RemoteSyncError.malformedChange("附件所有者与消息发送者不一致")
                }
                try applyMediaFields(mediaFields, to: item)
            } else if asset?.isTombstone == true {
                item.mediaRemoteStatus = "deleted"
            }
        }
        insertIfNeeded(item)
    }

    private func applyMediaAsset(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        let linked = try context.fetch(FetchDescriptor<ChatMessageModel>()).filter {
            $0.remoteMediaID == state.entityID
        }
        for message in linked {
            if state.isTombstone {
                message.mediaRemoteStatus = "deleted"
            } else {
                let ownerID = try fields.requiredUUID("owner_id")
                guard MemberIdentity.remoteUUID(for: message.senderID) == ownerID else {
                    throw RemoteSyncError.malformedChange("附件所有者与消息发送者不一致")
                }
                try applyMediaFields(fields, to: message)
            }
        }
    }

    private func applyMediaFields(_ fields: RemoteFields, to message: ChatMessageModel) throws {
        let status = try fields.requiredString("status")
        guard status == "ready" || status == "missing" else {
            throw RemoteSyncError.malformedChange("聊天附件尚未完成上传")
        }
        let size = try fields.requiredInt("size_bytes")
        guard size > 0 else { throw RemoteSyncError.malformedChange("附件大小无效") }
        if status == "ready" {
            guard try fields.date("finalized_at") != nil else {
                throw RemoteSyncError.malformedChange("附件缺少完成时间")
            }
        }
        message.mediaFileName = fields.string("file_name")
        message.mediaContentType = try fields.requiredString("mime_type")
        message.mediaSizeBytes = size
        message.mediaRemoteStatus = status
        message.mediaChecksum = try fields.requiredString("checksum")
        if message.kind == .file && message.mediaFileName == nil {
            throw RemoteSyncError.malformedChange("文件附件缺少文件名")
        }
    }

    private func applyMessageReceipt(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        let member = localMemberID(try fields.requiredUUID("member_id"))
        if state.isTombstone { try delete(MessageReceiptModel.self, id: state.entityID); return }
        let messageID = try fields.requiredUUID("message_id")
        let item = try messageReceipt(id: state.entityID) ?? MessageReceiptModel(id: state.entityID, messageID: messageID, memberID: member)
        item.messageID = messageID; item.memberID = member; item.deliveredAt = try fields.date("delivered_at"); item.readAt = try fields.date("read_at")
        insertIfNeeded(item)
        if let message = try message(id: messageID), item.readAt != nil { message.statusRaw = ReceiptStatus.read.rawValue }
        else if let message = try message(id: messageID), item.deliveredAt != nil, message.status != .read { message.statusRaw = ReceiptStatus.delivered.rawValue }
    }

    private func applyLocationSnapshot(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        guard !state.isTombstone else { return }
        let member = localMemberID(try fields.requiredUUID("member_id"))
        let item = try location(id: state.entityID) ?? LocationSnapshotModel(id: state.entityID, memberID: member, latitude: 0, longitude: 0, timestamp: .now)
        item.memberID = member; item.latitude = try fields.requiredDouble("latitude"); item.longitude = try fields.requiredDouble("longitude")
        item.timestamp = try fields.requiredDate("captured_at"); item.event = fields.string("event_type")
        item.horizontalAccuracy = fields.double("horizontal_accuracy")
        if let source = fields.string("source") {
            guard LocationSnapshotSource(rawValue: source) != nil else { throw RemoteSyncError.malformedChange("位置来源无效") }
            item.sourceRaw = source
        } else {
            item.sourceRaw = nil
        }
        insertIfNeeded(item)
    }

    private func applyMemberPlace(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        guard !state.isTombstone else { try delete(FamilyPlaceModel.self, id: state.entityID); return }
        let member = localMemberID(try fields.requiredUUID("member_id"))
        guard let kind = PlaceKind(rawValue: try fields.requiredString("type")) else { throw RemoteSyncError.malformedChange("家庭地点类型无效") }
        let item = try place(id: state.entityID) ?? FamilyPlaceModel(id: state.entityID, name: "", kind: kind, latitude: 0, longitude: 0, radius: 100, memberID: member)
        item.memberID = member; item.name = try fields.requiredString("name"); item.kindRaw = kind.rawValue
        item.latitude = try fields.requiredDouble("latitude"); item.longitude = try fields.requiredDouble("longitude")
        item.radius = Double(try fields.requiredInt("radius_m")); item.isEnabled = try fields.requiredBool("enabled"); insertIfNeeded(item)
    }

    private func applyMemberStatus(_ state: RemoteRecordState, _ fields: RemoteFields) throws {
        guard let remoteMemberID = try fields.uuid("member_id") else { return }
        let member = localMemberID(remoteMemberID)
        guard !state.isTombstone else { if let item = try status(memberID: member) { context.delete(item) }; return }
        guard let statusValue = SafetyStatus(rawValue: try fields.requiredString("status_raw")) else { throw RemoteSyncError.malformedChange("成员状态无效") }
        let item = try status(memberID: member) ?? MemberStatusModel(memberID: member)
        item.statusRaw = statusValue.rawValue; item.estimatedArrival = try fields.date("estimated_arrival")
        item.updatedAt = try fields.requiredDate("updated_at"); insertIfNeeded(item)
    }

    @discardableResult
    func reconcileSnapshotAbsence(_ priorRecords: [RemoteRecordState]) throws -> Set<UUID> {
        var removedMemberIDs = Set<UUID>()
        for record in priorRecords where !record.isTombstone {
            if record.entityType == .member { removedMemberIDs.insert(record.entityID) }
            let pending = try context.fetch(FetchDescriptor<PendingMutationModel>()).filter {
                $0.entityType == record.entityType.rawValue && $0.entityID == record.entityID &&
                    ($0.state == .pending || $0.state == .sending)
            }
            if !pending.isEmpty {
                try preserveAbsentSnapshotConflicts(pending, record: record)
                continue
            }
            try deleteLocalEntity(for: record)
        }
        return removedMemberIDs
    }

    private func preserveAbsentSnapshotConflicts(_ mutations: [PendingMutationModel], record: RemoteRecordState) throws {
        let existing = Set(try context.fetch(FetchDescriptor<SyncConflictModel>()).map(\.mutationID))
        for mutation in mutations where !existing.contains(mutation.id) {
            context.insert(SyncConflictModel(
                mutationID: mutation.id,
                entityType: mutation.entityType,
                entityID: mutation.entityID,
                localVersion: mutation.baseVersion,
                remoteVersion: record.serverVersion,
                localPayloadJSON: mutation.payloadJSON,
                remoteSnapshotJSON: nil,
                conflictTypeRaw: "remote_snapshot_absent"
            ))
            mutation.stateRaw = RemoteOutboxState.pending.rawValue
            mutation.nextRetryAt = .distantFuture
            mutation.lastErrorCode = "conflict.remote_snapshot_absent"
        }
    }

    private func deleteLocalEntity(for record: RemoteRecordState) throws {
        let fields = try fields(for: record)
        switch record.entityType {
        case .member:
            // A fresh authoritative bootstrap omits inactive Members. Keep a
            // tombstoned profile for history just as pull does, rather than
            // deleting the label and turning old rows into raw UUIDs.
            try applyMember(RemoteRecordState(
                entityType: record.entityType, entityID: record.entityID,
                serverVersion: record.serverVersion, isTombstone: true,
                payloadJSON: record.payloadJSON, lastSequence: record.lastSequence,
                serverUpdatedAt: record.serverUpdatedAt
            ), fields)
        case .semester: try deleteSemester(id: record.entityID)
        case .schedule: try deleteSchedule(id: record.entityID)
        case .scheduleException: try delete(ScheduleExceptionModel.self, id: record.entityID)
        case .calendarOverride: try delete(CalendarOverrideModel.self, id: record.entityID)
        case .importBatch: try delete(ScheduleImportBatchModel.self, id: record.entityID)
        case .importBatchItem: break
        case .agenda: try deleteAgenda(id: record.entityID)
        case .agendaException: try delete(AgendaExceptionModel.self, id: record.entityID)
        case .agendaParticipant: try applyAgendaParticipant(RemoteRecordState(entityType: record.entityType, entityID: record.entityID, serverVersion: record.serverVersion, isTombstone: true, payloadJSON: record.payloadJSON, lastSequence: record.lastSequence, serverUpdatedAt: record.serverUpdatedAt), fields)
        case .foodRead: break
        case .memo: try delete(MemoModel.self, id: record.entityID)
        case .notice: try deleteNotice(id: record.entityID)
        case .noticeRead: try delete(NoticeReadModel.self, id: record.entityID)
        case .message: try deleteMessage(id: record.entityID)
        case .messageReceipt: try delete(MessageReceiptModel.self, id: record.entityID)
        case .locationSnapshot: try delete(LocationSnapshotModel.self, id: record.entityID)
        case .memberPlace: try delete(FamilyPlaceModel.self, id: record.entityID)
        case .memberStatus:
            let member = localMemberID(try fields.requiredUUID("member_id"))
            if let item = try status(memberID: member) { context.delete(item) }
        case .mediaAsset, .geofenceEvent: break
        }
    }

    private func deleteAgenda(id: UUID) throws {
        if let item = try agenda(id: id) { context.delete(item) }
        for exception in try context.fetch(FetchDescriptor<AgendaExceptionModel>()) where exception.agendaID == id {
            context.delete(exception)
        }
    }

    private func deleteSchedule(id: UUID) throws {
        if let item = try schedule(id: id) { context.delete(item) }
        for exception in try context.fetch(FetchDescriptor<ScheduleExceptionModel>()) where exception.scheduleID == id {
            context.delete(exception)
        }
    }

    private func deleteSemester(id: UUID) throws {
        if let item = try semester(id: id) { context.delete(item) }
        for schedule in try context.fetch(FetchDescriptor<ScheduleEntryModel>()) where schedule.semesterID == id {
            try deleteSchedule(id: schedule.id)
        }
        for override in try context.fetch(FetchDescriptor<CalendarOverrideModel>()) where override.semesterID == id {
            context.delete(override)
        }
        for batch in try context.fetch(FetchDescriptor<ScheduleImportBatchModel>()) where batch.semesterID == id {
            context.delete(batch)
        }
    }

    private func deleteNotice(id: UUID) throws {
        if let item = try notice(id: id) { context.delete(item) }
        for read in try context.fetch(FetchDescriptor<NoticeReadModel>()) where read.noticeID == id {
            context.delete(read)
        }
    }

    private func deleteMessage(id: UUID) throws {
        try delete(ChatMessageModel.self, id: id)
        for receipt in try context.fetch(FetchDescriptor<MessageReceiptModel>()) where receipt.messageID == id {
            context.delete(receipt)
        }
    }

    private func insertIfNeeded<T: PersistentModel>(_ item: T) { if item.modelContext == nil { context.insert(item) } }
    private func delete<T: PersistentModel>(_ type: T.Type, id: UUID) throws {
        if let item = try context.fetch(FetchDescriptor<T>()).first(where: { modelID($0) == id }) {
            context.delete(item)
        }
    }
    private func modelID<T: PersistentModel>(_ item: T) -> UUID? {
        switch item {
        case let item as SemesterModel: return item.id
        case let item as ScheduleEntryModel: return item.id
        case let item as ScheduleExceptionModel: return item.id
        case let item as CalendarOverrideModel: return item.id
        case let item as ScheduleImportBatchModel: return item.id
        case let item as AgendaItemModel: return item.id
        case let item as AgendaExceptionModel: return item.id
        case let item as MemoModel: return item.id
        case let item as NoticeModel: return item.id
        case let item as NoticeReadModel: return item.id
        case let item as ChatMessageModel: return item.id
        case let item as MessageReceiptModel: return item.id
        case let item as LocationSnapshotModel: return item.id
        case let item as FamilyPlaceModel: return item.id
        default: return nil
        }
    }
    private func semester(id: UUID) throws -> SemesterModel? { try context.fetch(FetchDescriptor<SemesterModel>()).first { $0.id == id } }
    private func schedule(id: UUID) throws -> ScheduleEntryModel? { try context.fetch(FetchDescriptor<ScheduleEntryModel>()).first { $0.id == id } }
    private func scheduleException(id: UUID) throws -> ScheduleExceptionModel? { try context.fetch(FetchDescriptor<ScheduleExceptionModel>()).first { $0.id == id } }
    private func calendarOverride(id: UUID) throws -> CalendarOverrideModel? { try context.fetch(FetchDescriptor<CalendarOverrideModel>()).first { $0.id == id } }
    private func importBatch(id: UUID) throws -> ScheduleImportBatchModel? { try context.fetch(FetchDescriptor<ScheduleImportBatchModel>()).first { $0.id == id } }
    private func agenda(id: UUID) throws -> AgendaItemModel? { try context.fetch(FetchDescriptor<AgendaItemModel>()).first { $0.id == id } }
    private func agendaException(id: UUID) throws -> AgendaExceptionModel? { try context.fetch(FetchDescriptor<AgendaExceptionModel>()).first { $0.id == id } }
    private func memo(id: UUID) throws -> MemoModel? { try context.fetch(FetchDescriptor<MemoModel>()).first { $0.id == id } }
    private func notice(id: UUID) throws -> NoticeModel? { try context.fetch(FetchDescriptor<NoticeModel>()).first { $0.id == id } }
    private func noticeRead(id: UUID) throws -> NoticeReadModel? { try context.fetch(FetchDescriptor<NoticeReadModel>()).first { $0.id == id } }
    private func message(id: UUID) throws -> ChatMessageModel? { try context.fetch(FetchDescriptor<ChatMessageModel>()).first { $0.id == id } }
    private func messageReceipt(id: UUID) throws -> MessageReceiptModel? { try context.fetch(FetchDescriptor<MessageReceiptModel>()).first { $0.id == id } }
    private func location(id: UUID) throws -> LocationSnapshotModel? { try context.fetch(FetchDescriptor<LocationSnapshotModel>()).first { $0.id == id } }
    private func place(id: UUID) throws -> FamilyPlaceModel? { try context.fetch(FetchDescriptor<FamilyPlaceModel>()).first { $0.id == id } }
    private func status(memberID: String) throws -> MemberStatusModel? { try context.fetch(FetchDescriptor<MemberStatusModel>()).first { $0.memberID == memberID } }
}

private extension RemoteEntityType {
    var applyRank: Int {
        switch self {
        case .member: 0
        case .semester: 1
        case .agenda, .schedule, .importBatch, .notice, .memo, .message, .memberPlace, .memberStatus: 2
        case .scheduleException, .calendarOverride, .agendaException, .locationSnapshot: 3
        case .agendaParticipant, .foodRead, .noticeRead, .messageReceipt, .importBatchItem: 4
        case .mediaAsset, .geofenceEvent: 5
        }
    }

    /// Parent records must reach the server before child/receipt mutations in
    /// the same outbox batch; sequence within one rank stays chronological.
    var pushRank: Int {
        switch self {
        case .member: 0
        case .semester: 1
        case .agenda, .schedule, .importBatch, .notice, .memo, .message, .memberPlace, .memberStatus: 2
        case .scheduleException, .calendarOverride, .agendaException, .locationSnapshot: 3
        case .agendaParticipant, .foodRead, .noticeRead, .messageReceipt, .importBatchItem: 4
        case .mediaAsset, .geofenceEvent: 5
        }
    }
}

private nonisolated struct RemoteFields {
    private let values: [String: RemoteJSONValue]
    init(_ values: [String: RemoteJSONValue]) { self.values = values }
    func string(_ key: String) -> String? { guard case let .string(value)? = values[key] else { return nil }; return value }
    func int(_ key: String) -> Int? { guard case let .number(value)? = values[key], value.rounded() == value else { return nil }; return Int(value) }
    func bool(_ key: String) -> Bool? { guard case let .bool(value)? = values[key] else { return nil }; return value }
    func double(_ key: String) -> Double? { guard case let .number(value)? = values[key] else { return nil }; return value }
    func uuid(_ key: String) throws -> UUID? { guard let string = string(key) else { return nil }; guard let value = UUID(uuidString: string) else { throw RemoteSyncError.malformedChange("UUID 字段无效：\(key)") }; return value }
    func object(_ key: String) -> [String: RemoteJSONValue]? { guard case let .object(value)? = values[key] else { return nil }; return value }
    func date(_ key: String) throws -> Date? { guard let raw = string(key) else { return nil }; return try RemoteDateCodec.date(raw, field: key) }
    func civilDate(_ key: String) throws -> Date? { guard let raw = string(key) else { return nil }; return try RemoteDateCodec.civilDate(raw, field: key) }
    func requiredString(_ key: String) throws -> String { guard let value = string(key), !value.isEmpty else { throw RemoteSyncError.malformedChange("缺少字段：\(key)") }; return value }
    func requiredUUID(_ key: String) throws -> UUID { guard let value = try uuid(key) else { throw RemoteSyncError.malformedChange("缺少 UUID 字段：\(key)") }; return value }
    func requiredInt(_ key: String) throws -> Int { guard let value = int(key) else { throw RemoteSyncError.malformedChange("缺少整数字段：\(key)") }; return value }
    func requiredBool(_ key: String) throws -> Bool { guard let value = bool(key) else { throw RemoteSyncError.malformedChange("缺少布尔字段：\(key)") }; return value }
    func requiredDouble(_ key: String) throws -> Double { guard let value = double(key) else { throw RemoteSyncError.malformedChange("缺少数值字段：\(key)") }; return value }
    func requiredDate(_ key: String) throws -> Date { guard let value = try date(key) else { throw RemoteSyncError.malformedChange("缺少时间字段：\(key)") }; return value }
    func requiredCivilDate(_ key: String) throws -> Date { guard let value = try civilDate(key) else { throw RemoteSyncError.malformedChange("缺少日期字段：\(key)") }; return value }
}

private nonisolated enum RemoteDateCodec {
    static func date(_ raw: String, field: String) throws -> Date {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: raw) { return value }
        let fallback = ISO8601DateFormatter()
        guard let value = fallback.date(from: raw) else { throw RemoteSyncError.malformedChange("时间字段无效：\(field)") }
        return value
    }
    static func civilDate(_ raw: String, field: String) throws -> Date {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        guard let value = formatter.date(from: raw) else { throw RemoteSyncError.malformedChange("日期字段无效：\(field)") }
        return value
    }
}

/// The one place that applies bootstrap and pull data. Remote payloads are
/// validated into versioned states before a single SwiftData transaction writes
/// the existing business models, diagnostic mirror, and cursor together.
@MainActor
final class RemoteChangeApplier {
    private let context: ModelContext
    private let stateKey = "primary"
    private(set) var lastRemovedMemberIDs = Set<UUID>()

    init(context: ModelContext) { self.context = context }

    func storedCursor() throws -> Int? {
        let states = try syncStates()
        guard states.count <= 1 else { throw RemoteSyncError.stateCorrupted }
        guard let state = states.first else { return nil }
        guard state.lastAppliedCursor >= 0 else { throw RemoteSyncError.stateCorrupted }
        return state.lastAppliedCursor
    }

    /// Snapshot rows and the cursor are committed in one SwiftData save. The
    /// caller only receives success after both are durable together.
    func applyBootstrap(_ snapshot: RemoteBootstrapResponse) throws -> Int {
        guard snapshot.latestCursor >= 0, !snapshot.familyTimezone.isEmpty else { throw RemoteSyncError.invalidResponse }
        if try syncStates().isEmpty {
            // A pre-existing localOnly family is not silently merged with a
            // newly authenticated remote family. That requires an explicit
            // migration decision; this phase only restores server-backed data.
            let hasChat = try !context.fetch(FetchDescriptor<ChatMessageModel>()).isEmpty
            let hasAgenda = try !context.fetch(FetchDescriptor<AgendaItemModel>()).isEmpty
            let hasSchedule = try !context.fetch(FetchDescriptor<ScheduleEntryModel>()).isEmpty
            let hasMemo = try !context.fetch(FetchDescriptor<MemoModel>()).isEmpty
            let hasNotice = try !context.fetch(FetchDescriptor<NoticeModel>()).isEmpty
            let hasLocation = try !context.fetch(FetchDescriptor<LocationSnapshotModel>()).isEmpty
            let hasPlace = try !context.fetch(FetchDescriptor<FamilyPlaceModel>()).isEmpty
            let hasLocalBusinessData = hasChat || hasAgenda || hasSchedule || hasMemo ||
                hasNotice || hasLocation || hasPlace
            guard !hasLocalBusinessData else {
                throw RemoteSyncError.unsupportedLocalData("已有本地数据需要先决定迁移方式")
            }
        }
        // A snapshot may replace local business objects only when every
        // unsent edit has either been acknowledged or durably captured as a
        // SyncConflict. Otherwise its payload would be silently overwritten.
        let conflictIDs = Set(try context.fetch(FetchDescriptor<SyncConflictModel>()).map(\.mutationID))
        let unprotected = try context.fetch(FetchDescriptor<PendingMutationModel>())
            .contains { $0.state != .acknowledged && !conflictIDs.contains($0.id) }
        guard !unprotected else { throw RemoteSyncError.localChangesPending }
        let records = try materialize(snapshot)
        var removedMemberIDs = Set<UUID>()
        try atomically {
            let mirrorModels = try context.fetch(FetchDescriptor<RemoteEntityRecordModel>())
            let previous = try mirrorModels.map { try RemoteRecordState(model: $0) }
            let incomingKeys = Set(records.map(\.key))
            let absent = previous.filter { !incomingKeys.contains($0.key) }
            let businessApplier = RemoteBusinessChangeApplier(context: context)
            // Only models that were previously known as remote records are
            // reconciled away. Local-only records have no mirror and therefore
            // remain untouched during first activation or cursor recovery.
            removedMemberIDs.formUnion(try businessApplier.reconcileSnapshotAbsence(absent))
            removedMemberIDs.formUnion(try businessApplier.apply(records))
            for record in try context.fetch(FetchDescriptor<RemoteEntityRecordModel>()) { context.delete(record) }
            for state in try syncStates() { context.delete(state) }
            records.forEach { state in context.insert(state.model) }
            context.insert(SyncStateModel(key: stateKey, lastAppliedCursor: snapshot.latestCursor))
        }
        lastRemovedMemberIDs = removedMemberIDs
        return snapshot.latestCursor
    }

    /// Applies an ordered pull page and saves its last actual server sequence
    /// with the changes. `latest_cursor` is not trusted as a client cursor,
    /// because newer writes can race a pull response.
    func apply(_ changes: [RemoteChange], after cursor: Int) throws -> Int {
        guard cursor >= 0 else { throw RemoteSyncError.stateCorrupted }
        guard !changes.isEmpty else { return cursor }
        let current = try storedCursor()
        guard current == cursor else { throw RemoteSyncError.stateCorrupted }

        let existingModels = try context.fetch(FetchDescriptor<RemoteEntityRecordModel>())
        var states = [String: RemoteRecordState]()
        for model in existingModels {
            guard states[model.entityKey] == nil else { throw RemoteSyncError.stateCorrupted }
            states[model.entityKey] = try RemoteRecordState(model: model)
        }
        var nextCursor = cursor
        var touched = Set<String>()
        var sources = [String: UUID?]()
        for change in changes {
            guard change.sequence == nextCursor + 1,
                  let entityType = RemoteEntityType(rawValue: change.entityType) else {
                throw RemoteSyncError.malformedChange("服务端序号或实体类型不连续")
            }
            let key = RemoteEntityRecordModel.key(entityType: change.entityType, entityID: change.entityID)
            let next = try states[key]?.applying(change) ?? RemoteRecordState.from(change: change, entityType: entityType)
            states[key] = next
            touched.insert(key)
            sources[key] = change.sourceMutationID
            nextCursor = change.sequence
        }

        let conflictIDs = Set(try context.fetch(FetchDescriptor<SyncConflictModel>()).map(\.mutationID))
        let pending = try context.fetch(FetchDescriptor<PendingMutationModel>())
        guard !pending.contains(where: {
            $0.state != .acknowledged && !conflictIDs.contains($0.id) &&
            touched.contains(RemoteEntityRecordModel.key(entityType: $0.entityType, entityID: $0.entityID))
        }) else { throw RemoteSyncError.localChangesPending }

        var removedMemberIDs = Set<UUID>()
        try atomically {
            removedMemberIDs = try RemoteBusinessChangeApplier(context: context).apply(touched.compactMap { states[$0] }, sources: sources)
            var modelsByKey = [String: RemoteEntityRecordModel]()
            for model in try context.fetch(FetchDescriptor<RemoteEntityRecordModel>()) {
                guard modelsByKey[model.entityKey] == nil else { throw RemoteSyncError.stateCorrupted }
                modelsByKey[model.entityKey] = model
            }
            for state in states.values {
                if let model = modelsByKey[state.key] { state.apply(to: model) }
                else { context.insert(state.model) }
            }
            let syncState = try requiredSyncState()
            syncState.lastAppliedCursor = nextCursor
        }
        lastRemovedMemberIDs = removedMemberIDs
        return nextCursor
    }

    private func materialize(_ snapshot: RemoteBootstrapResponse) throws -> [RemoteRecordState] {
        let expected = Set(RemoteEntityType.allCases.map(\.rawValue))
        guard Set(snapshot.entities.keys) == expected else { throw RemoteSyncError.invalidResponse }
        var result = [RemoteRecordState]()
        var keys = Set<String>()
        for entityType in RemoteEntityType.allCases {
            guard let payloads = snapshot.entities[entityType.rawValue] else { throw RemoteSyncError.invalidResponse }
            for payload in payloads {
                let record = try RemoteRecordState(snapshotType: entityType, payload: payload, cursor: snapshot.latestCursor)
                guard keys.insert(record.key).inserted else { throw RemoteSyncError.malformedChange("快照包含重复实体") }
                result.append(record)
            }
        }
        return result
    }

    private func requiredSyncState() throws -> SyncStateModel {
        let states = try syncStates()
        guard states.count == 1, let state = states.first, state.lastAppliedCursor >= 0 else { throw RemoteSyncError.stateCorrupted }
        return state
    }

    private func syncStates() throws -> [SyncStateModel] {
        try context.fetch(FetchDescriptor<SyncStateModel>()).filter { $0.key == stateKey }
    }

    private func atomically(_ work: () throws -> Void) throws {
        guard !context.hasChanges else { throw RemoteSyncError.localChangesPending }
        do {
            try work()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

@MainActor
final class RemoteSyncCoordinator {
    private let api: any RemoteSyncAPI
    private let cursorAPI: (any RemoteCursorNotificationAPI)?
    private let rollbackAPI: (any RemoteImportBatchRollbackAPI)?
    private let context: ModelContext
    private let deviceID: UUID
    private let outbox: RemoteOutbox
    private let applier: RemoteChangeApplier
    private let currentMemberRemoteID: UUID?
    private let onCurrentMemberRemoved: @MainActor (UUID) -> Void
    private let onCursorHint: @MainActor (Int) -> Void
    private let onAuthenticationRequired: @MainActor () -> Void
    private var isSynchronizing = false
    private var accessRevoked = false
    private var notificationTask: Task<Void, Never>?
    private var notificationsWanted = false
    private var isStoppingNotifications = false

    init(context: ModelContext, api: any RemoteSyncAPI, deviceID: UUID,
         cursorAPI: (any RemoteCursorNotificationAPI)? = nil,
         rollbackAPI: (any RemoteImportBatchRollbackAPI)? = nil,
         currentMemberRemoteID: UUID? = nil,
         onCurrentMemberRemoved: @escaping @MainActor (UUID) -> Void = { _ in },
         onCursorHint: @escaping @MainActor (Int) -> Void = { _ in },
         onAuthenticationRequired: @escaping @MainActor () -> Void = {}) {
        self.api = api; self.rollbackAPI = rollbackAPI; self.context = context; self.deviceID = deviceID
        self.cursorAPI = cursorAPI
        self.outbox = RemoteOutbox(context: context)
        self.applier = RemoteChangeApplier(context: context)
        self.currentMemberRemoteID = currentMemberRemoteID
        self.onCurrentMemberRemoved = onCurrentMemberRemoved
        self.onCursorHint = onCursorHint
        self.onAuthenticationRequired = onAuthenticationRequired
    }

    /// One foreground listener per remote coordinator. Hints coalesce through
    /// AppEnvironment's existing single sync task; no business data travels on
    /// this socket and the localOnly composition never constructs it.
    func startCursorNotifications() {
        guard cursorAPI != nil, !accessRevoked else { return }
        notificationsWanted = true
        guard notificationTask == nil, !isStoppingNotifications else { return }
        notificationTask = Task { [weak self] in await self?.listenForCursorHints() }
    }

    func stopCursorNotifications() async {
        notificationsWanted = false
        isStoppingNotifications = true
        notificationTask?.cancel()
        if let cursorAPI { await cursorAPI.disconnectCursorNotifications() }
        await notificationTask?.value
        isStoppingNotifications = false
        if notificationsWanted { startCursorNotifications() }
    }

    private func listenForCursorHints() async {
        guard let cursorAPI else { notificationTask = nil; return }
        var failures = 0
        while notificationsWanted && !Task.isCancelled && failures < 5 {
            do {
                try await cursorAPI.connectCursorNotifications()
                while notificationsWanted && !Task.isCancelled {
                    let hint = try await cursorAPI.receiveCursorNotification()
                    guard notificationsWanted && !Task.isCancelled else { break }
                    let localCursor = try? applier.storedCursor()
                    if hint.requiresBootstrap || hint.latestCursor > (localCursor ?? 0) {
                        onCursorHint(hint.latestCursor)
                    }
                }
            } catch is CancellationError {
                break
            } catch RemoteSyncError.authenticationRequired {
                notificationsWanted = false
                onAuthenticationRequired()
                break
            } catch {
                failures += 1
                await cursorAPI.disconnectCursorNotifications()
                guard notificationsWanted && !Task.isCancelled && failures < 5 else { break }
                do { try await Task.sleep(for: .seconds(min(1 << failures, 30))) }
                catch { break }
            }
        }
        await cursorAPI.disconnectCursorNotifications()
        notificationTask = nil
        if notificationsWanted && !isStoppingNotifications && !Task.isCancelled {
            // Reconnection is deliberately bounded for this foreground stay.
            // A later foreground transition may explicitly start another run.
            notificationsWanted = false
        }
    }

    /// Future remote composition supplies this bridge with its current member
    /// UUID. Keeping it here prevents Views from competing to consume a remote
    /// removal event; localOnly never constructs a coordinator.
    static func membershipRemovalHandler(environment: AppEnvironment) -> @MainActor (UUID) -> Void {
        { [weak environment] remoteMemberID in
            environment?.handleRemoteMembershipRemoval(remoteMemberID)
        }
    }

    func synchronize() async throws -> RemoteSyncRunSummary {
        try Task.checkCancellation()
        guard !isSynchronizing else { throw RemoteSyncError.alreadySynchronizing }
        guard !accessRevoked else { throw RemoteSyncError.authenticationRequired }
        isSynchronizing = true
        defer { isSynchronizing = false }

        try outbox.recoverInterruptedSends()
        let needsBootstrap: Bool
        do { needsBootstrap = try applier.storedCursor() == nil }
        catch RemoteSyncError.stateCorrupted { needsBootstrap = true }
        var bootstrapped = false
        if needsBootstrap {
            _ = try await bootstrap()
            bootstrapped = true
        }
        try Task.checkCancellation()
        // A fresh device has no local edits and catches up before it pushes.
        // An already-used device must send pending edits first, otherwise a
        // pull could overwrite its unsent local business model.
        let hadPending = try context.fetch(FetchDescriptor<PendingMutationModel>())
            .contains { $0.state != .acknowledged && ($0.nextRetryAt ?? .distantPast) <= .now }
        let initialPush = hadPending ? try await pushAllPending() : (acknowledged: 0, conflicts: 0)
        let initialPull = try await pullAll()
        try Task.checkCancellation()
        let pushSummary = hadPending ? (acknowledged: 0, conflicts: 0) : try await pushAllPending()
        try await submitPendingImportRollbacks()
        let pullSummary = try await pullAll()
        return RemoteSyncRunSummary(bootstrapped: bootstrapped,
                                    pushed: initialPush.acknowledged + pushSummary.acknowledged,
                                    conflicts: initialPush.conflicts + pushSummary.conflicts,
                                    pulledChanges: initialPull + pullSummary)
    }

    private func bootstrap() async throws -> Int {
        let snapshot = try await api.bootstrap()
        let cursor = try applier.applyBootstrap(snapshot)
        try handleMembershipRemovalIfNeeded()
        return cursor
    }

    private func pushAllPending() async throws -> (acknowledged: Int, conflicts: Int) {
        var acknowledged = 0
        var conflicts = 0
        while true {
            let batch = try outbox.claimNextBatch()
            guard !batch.isEmpty else { break }
            do {
                let response = try await api.push(deviceID: deviceID, mutations: batch)
                let result = try outbox.resolve(batch, response: response)
                acknowledged += result.acknowledged
                conflicts += result.conflicts
            } catch {
                try outbox.returnToPending(batch, after: error)
                throw error
            }
        }
        return (acknowledged, conflicts)
    }

    /// A rollback request never mutates local schedules. Only the subsequent
    /// authoritative SyncChange page does that, so a killed app can retry the
    /// same request ID without deleting or restoring anything twice.
    private func submitPendingImportRollbacks() async throws {
        guard let rollbackAPI else { return }
        let requests = try context.fetch(FetchDescriptor<PendingImportBatchRollbackModel>())
            .filter { $0.state == .pending && ($0.nextRetryAt ?? .distantPast) <= .now }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        for request in requests {
            request.stateRaw = RemoteRollbackRequestState.sending.rawValue
            request.lastAttemptAt = .now
            request.lastErrorCode = nil
            try context.save()
            do {
                let result = try await rollbackAPI.rollbackImportBatch(
                    batchID: request.batchID, mutationID: request.id,
                    expectedVersion: request.expectedBatchVersion
                )
                guard result.batchID == request.batchID, result.mutationID == request.id else {
                    throw RemoteSyncError.invalidResponse
                }
                request.stateRaw = RemoteRollbackRequestState.acknowledged.rawValue
                request.acknowledgedAt = .now
                request.nextRetryAt = nil
                try context.save()
            } catch let error as RemoteSyncError {
                if case let .server(statusCode, code) = error,
                   statusCode == 409, code == "import_batch_rollback_conflict" {
                    try recordRollbackConflict(request)
                    continue
                }
                try retryRollback(request, code: error.stableCode)
                throw error
            } catch {
                try retryRollback(request, code: "rollback_transport_error")
                throw error
            }
        }
    }

    private func recordRollbackConflict(_ request: PendingImportBatchRollbackModel) throws {
        let conflicts = try context.fetch(FetchDescriptor<SyncConflictModel>())
        if !conflicts.contains(where: { $0.mutationID == request.id }) {
            context.insert(SyncConflictModel(
                mutationID: request.id, entityType: RemoteEntityType.importBatch.rawValue,
                entityID: request.batchID, localVersion: request.expectedBatchVersion,
                remoteVersion: 0, localPayloadJSON: "{}", remoteSnapshotJSON: nil,
                conflictTypeRaw: "import_batch_rollback_conflict"
            ))
        }
        request.stateRaw = RemoteRollbackRequestState.conflict.rawValue
        request.lastErrorCode = "conflict.import_batch_rollback_conflict"
        request.nextRetryAt = .distantFuture
        try context.save()
    }

    private func retryRollback(_ request: PendingImportBatchRollbackModel, code: String) throws {
        request.stateRaw = RemoteRollbackRequestState.pending.rawValue
        request.retryCount = min(request.retryCount + 1, 16)
        request.lastErrorCode = code
        request.nextRetryAt = .now.addingTimeInterval(min(pow(2, Double(request.retryCount)) * 15, 900))
        try context.save()
    }

    private func pullAll() async throws -> Int {
        var cursor = try applier.storedCursor() ?? 0
        var applied = 0
        var didRebootstrap = false
        while true {
            do {
                let page = try await api.pull(after: cursor)
                if page.changes.isEmpty {
                    guard !page.hasMore else { throw RemoteSyncError.invalidResponse }
                    return applied
                }
                let next = try applier.apply(page.changes, after: cursor)
                try handleMembershipRemovalIfNeeded()
                applied += page.changes.count
                cursor = next
                if !page.hasMore { return applied }
            } catch RemoteSyncError.cursorExpired {
                guard !didRebootstrap else { throw RemoteSyncError.cursorExpired }
                cursor = try await bootstrap()
                didRebootstrap = true
            } catch RemoteSyncError.stateCorrupted {
                guard !didRebootstrap else { throw RemoteSyncError.stateCorrupted }
                cursor = try await bootstrap()
                didRebootstrap = true
            }
        }
    }

    private func handleMembershipRemovalIfNeeded() throws {
        guard let currentMemberRemoteID,
              applier.lastRemovedMemberIDs.contains(currentMemberRemoteID) else { return }
        accessRevoked = true
        onCurrentMemberRemoved(currentMemberRemoteID)
        throw RemoteSyncError.authenticationRequired
    }
}

struct RemoteSyncRunSummary: Sendable {
    let bootstrapped: Bool
    let pushed: Int
    let conflicts: Int
    let pulledChanges: Int
}

private nonisolated enum RemotePayload {
    static func id(from payload: [String: RemoteJSONValue]) throws -> UUID {
        guard case let .string(rawID)? = payload["id"], let id = UUID(uuidString: rawID) else {
            throw RemoteSyncError.malformedChange("缺少有效实体 ID")
        }
        return id
    }

    static func version(from payload: [String: RemoteJSONValue], entityType: RemoteEntityType) throws -> Int {
        if let value = integer("version", from: payload) {
            guard value >= 1 else { throw RemoteSyncError.malformedChange("实体版本无效") }
            return value
        }
        guard entityType.isAppendOnly else { throw RemoteSyncError.malformedChange("缺少实体版本") }
        return 1
    }

    static func string(_ key: String, from payload: [String: RemoteJSONValue]) -> String? {
        guard case let .string(value)? = payload[key] else { return nil }
        return value
    }

    private static func integer(_ key: String, from payload: [String: RemoteJSONValue]) -> Int? {
        guard case let .number(number)? = payload[key], number.rounded() == number,
              number >= Double(Int.min), number <= Double(Int.max) else { return nil }
        return Int(number)
    }
}

private nonisolated enum RemotePayloadCodec {
    static func string(_ value: [String: RemoteJSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func value(from string: String) throws -> [String: RemoteJSONValue] {
        guard let data = string.data(using: .utf8) else { throw RemoteSyncError.stateCorrupted }
        do { return try JSONDecoder().decode([String: RemoteJSONValue].self, from: data) }
        catch { throw RemoteSyncError.stateCorrupted }
    }
}

private nonisolated enum RemoteWireDate {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private nonisolated struct EmptyBody: Encodable, Sendable {}

private extension RemoteRecordState {
    var key: String { RemoteEntityRecordModel.key(entityType: entityType.rawValue, entityID: entityID) }

    var model: RemoteEntityRecordModel {
        RemoteEntityRecordModel(entityType: entityType.rawValue, entityID: entityID, serverVersion: serverVersion, isTombstone: isTombstone, payloadJSON: payloadJSON, lastSequence: lastSequence, serverUpdatedAt: serverUpdatedAt)
    }

    func apply(to model: RemoteEntityRecordModel) {
        model.serverVersion = serverVersion
        model.isTombstone = isTombstone
        model.payloadJSON = payloadJSON
        model.lastSequence = lastSequence
        model.serverUpdatedAt = serverUpdatedAt
    }
}
