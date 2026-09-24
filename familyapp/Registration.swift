import Foundation
import Security
import SwiftData
import SwiftUI
import UIKit

/// Registration is a remote auth control-plane concern. These value-only DTOs
/// contain no SwiftData objects and can be decoded off the main actor.
nonisolated enum PendingRegistrationStatus: String, Codable, Sendable {
    case pending, approved, rejected

    var localizedName: String {
        switch self {
        case .pending: "等待审批"
        case .approved: "已通过"
        case .rejected: "未通过"
        }
    }
}

nonisolated struct RemotePendingRegistration: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let status: PendingRegistrationStatus
    let createdAt: Date
    let expiresAt: Date
    let memberID: UUID?
    let approvedBy: UUID?
    let rejectedBy: UUID?
    let decidedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, status
        case displayName = "display_name", createdAt = "created_at", expiresAt = "expires_at"
        case memberID = "member_id", approvedBy = "approved_by", rejectedBy = "rejected_by"
        case decidedAt = "decided_at"
    }
}

nonisolated struct RemoteRegistrationCreated: Decodable, Sendable {
    let registration: RemotePendingRegistration
    let activationToken: String

    enum CodingKeys: String, CodingKey { case activationToken = "activation_token" }

    init(from decoder: Decoder) throws {
        registration = try RemotePendingRegistration(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        activationToken = try values.decode(String.self, forKey: .activationToken)
    }
}

nonisolated struct RemoteRegistrationActivation: Decodable, Sendable {
    let memberID: UUID
    let tokenPair: RemoteTokenPair

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id", accessToken = "access_token", refreshToken = "refresh_token"
        case expiresIn = "expires_in", deviceID = "device_id"
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

nonisolated enum RemoteRegistrationError: LocalizedError, Sendable {
    case invalidConfiguration, invalidResponse, requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "注册服务配置无效。"
        case .invalidResponse: "注册服务返回的数据无效。"
        case .requestFailed: "注册请求未能完成。"
        }
    }
}

protocol RemoteRegistrationAPI: Sendable {
    func submit(displayName: String, password: String, inviteCode: String, installationID: String) async throws -> RemoteRegistrationCreated
    func status(registrationID: UUID, installationID: String, activationToken: String) async throws -> RemotePendingRegistration
    func cancel(registrationID: UUID, installationID: String, activationToken: String) async throws -> RemotePendingRegistration
    func activate(registrationID: UUID, installationID: String, activationToken: String, deviceName: String) async throws -> RemoteRegistrationActivation
}

protocol RemoteRegistrationApprovalAPI: Sendable {
    func pendingRegistrations() async throws -> [RemotePendingRegistration]
    func decideRegistration(id: UUID, approved: Bool) async throws -> RemotePendingRegistration
}

nonisolated enum RemoteMemberRemovalStatus: String, Codable, Sendable {
    case pending, approved, rejected, cancelled
}

nonisolated struct RemoteMemberRemovalRequest: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let targetMemberID: UUID
    let requesterID: UUID
    let approverID: UUID?
    let status: RemoteMemberRemovalStatus
    let createdAt: Date
    let decidedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, status
        case targetMemberID = "target_member_id", requesterID = "requester_id"
        case approverID = "approver_id", createdAt = "created_at", decidedAt = "decided_at"
    }
}

/// Authenticated control-plane API. It never uses Sync Outbox because a
/// removal is authoritative server identity/revocation work, not a local edit.
protocol RemoteMemberManagementAPI: Sendable {
    func requestMemberRemoval(targetMemberID: UUID) async throws -> RemoteMemberRemovalRequest
    func pendingMemberRemovalRequests() async throws -> [RemoteMemberRemovalRequest]
    func decideMemberRemoval(id: UUID, approved: Bool) async throws -> RemoteMemberRemovalRequest
    func leaveFamily() async throws
}

/// This is control-plane metadata, not a Sync entity. The server derives the
/// current-device flag from the access token rather than trusting the UI.
nonisolated struct RemoteDeviceSummary: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let firstSeenAt: Date
    let lastSeenAt: Date
    let revokedAt: Date?
    let isCurrent: Bool
    let isLocationSource: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case revokedAt = "revoked_at"
        case isCurrent = "is_current"
        case isLocationSource = "is_location_source"
    }
}

protocol RemoteDeviceManagementAPI: Sendable {
    func devices() async throws -> [RemoteDeviceSummary]
    func revokeDevice(id: UUID) async throws
    func revokeOtherDevices() async throws
    func selectCurrentDeviceAsLocationSource() async throws
}

private nonisolated struct RegistrationEmptyBody: Encodable, Sendable {}

/// Separate unauthenticated transport for an installation-bound application.
/// It never accepts or creates ordinary access/refresh credentials.
actor RemoteRegistrationAPIClient: RemoteRegistrationAPI {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func submit(displayName: String, password: String, inviteCode: String, installationID: String) async throws -> RemoteRegistrationCreated {
        struct Body: Encodable {
            let displayName, password, confirmPassword, inviteCode, installationID: String
            enum CodingKeys: String, CodingKey {
                case displayName = "display_name", password, confirmPassword = "confirm_password"
                case inviteCode = "invite_code", installationID = "installation_id"
            }
        }
        return try await request(
            path: ["v1", "auth", "registrations"], method: "POST",
            body: Body(displayName: displayName, password: password, confirmPassword: password,
                       inviteCode: inviteCode, installationID: installationID),
            response: RemoteRegistrationCreated.self
        )
    }

    func status(registrationID: UUID, installationID: String, activationToken: String) async throws -> RemotePendingRegistration {
        try await request(
            path: ["v1", "auth", "registrations", registrationID.uuidString], method: "GET",
            body: EmptyRegistrationBody(), response: RemotePendingRegistration.self,
            headers: applicantHeaders(installationID: installationID, activationToken: activationToken)
        )
    }

    func cancel(registrationID: UUID, installationID: String, activationToken: String) async throws -> RemotePendingRegistration {
        try await request(
            path: ["v1", "auth", "registrations", registrationID.uuidString], method: "DELETE",
            body: ApplicantBody(installationID: installationID, activationToken: activationToken, deviceName: nil),
            response: RemotePendingRegistration.self
        )
    }

    func activate(registrationID: UUID, installationID: String, activationToken: String, deviceName: String) async throws -> RemoteRegistrationActivation {
        try await request(
            path: ["v1", "auth", "registrations", registrationID.uuidString, "activate"], method: "POST",
            body: ApplicantBody(installationID: installationID, activationToken: activationToken, deviceName: deviceName),
            response: RemoteRegistrationActivation.self
        )
    }

    private struct EmptyRegistrationBody: Encodable {}

    private struct ApplicantBody: Encodable {
        let installationID: String
        let activationToken: String
        let deviceName: String?
        enum CodingKeys: String, CodingKey {
            case installationID = "installation_id", activationToken = "activation_token"
            case deviceName = "device_name"
        }
    }

    private func applicantHeaders(installationID: String, activationToken: String) -> [String: String] {
        [
            "X-FamilyApp-Installation-ID": installationID,
            "X-FamilyApp-Registration-Token": activationToken,
        ]
    }

    private func request<Body: Encodable, Response: Decodable>(
        path: [String], method: String, body: Body, response: Response.Type, headers: [String: String] = [:]
    ) async throws -> Response {
        guard baseURL.scheme?.lowercased() == "https" else { throw RemoteRegistrationError.invalidConfiguration }
        let suffix = baseURL.lastPathComponent.lowercased() == "v1" && path.first == "v1" ? path.dropFirst() : path[...]
        let url = suffix.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if method != "GET" {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, responseValue) = try await session.data(for: request)
        guard let http = responseValue as? HTTPURLResponse else { throw RemoteRegistrationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw RemoteRegistrationError.requestFailed(http.statusCode) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(Response.self, from: data) }
        catch { throw RemoteRegistrationError.invalidResponse }
    }
}

/// Reuses `RemoteAPIClient`'s authenticated request/refresh path rather than
/// introducing another bearer-token implementation for approvals.
extension RemoteAPIClient: RemoteRegistrationApprovalAPI {
    func pendingRegistrations() async throws -> [RemotePendingRegistration] {
        try await request(path: ["v1", "members", "join-requests"], method: "GET", body: RegistrationEmptyBody())
    }

    func decideRegistration(id: UUID, approved: Bool) async throws -> RemotePendingRegistration {
        struct Body: Encodable { let decision: String }
        return try await request(
            path: ["v1", "members", "join-requests", id.uuidString, "decision"], method: "POST",
            body: Body(decision: approved ? "approved" : "rejected")
        )
    }
}

extension RemoteAPIClient: RemoteMemberManagementAPI {
    func requestMemberRemoval(targetMemberID: UUID) async throws -> RemoteMemberRemovalRequest {
        struct Body: Encodable {
            let targetMemberID: UUID
            enum CodingKeys: String, CodingKey { case targetMemberID = "target_member_id" }
        }
        return try await request(
            path: ["v1", "members", "removal-requests"], method: "POST",
            body: Body(targetMemberID: targetMemberID)
        )
    }

    func pendingMemberRemovalRequests() async throws -> [RemoteMemberRemovalRequest] {
        try await request(path: ["v1", "members", "removal-requests"], method: "GET", body: RegistrationEmptyBody())
    }

    func decideMemberRemoval(id: UUID, approved: Bool) async throws -> RemoteMemberRemovalRequest {
        struct Body: Encodable { let decision: String }
        return try await request(
            path: ["v1", "members", "removal-requests", id.uuidString, "decision"], method: "POST",
            body: Body(decision: approved ? "approved" : "rejected")
        )
    }

    func leaveFamily() async throws {
        struct Body: Encodable { let confirmed = true }
        try await requestNoResponse(path: ["v1", "members", "me", "leave"], method: "POST", body: Body())
    }
}

/// Reuses the authenticated client so device operations get the same one-time
/// refresh retry and no separate bearer-token path is introduced.
extension RemoteAPIClient: RemoteDeviceManagementAPI {
    func devices() async throws -> [RemoteDeviceSummary] {
        try await request(path: ["v1", "members", "me", "devices"], method: "GET", body: RegistrationEmptyBody())
    }

    func revokeDevice(id: UUID) async throws {
        try await requestNoResponse(path: ["v1", "members", "me", "devices", id.uuidString], method: "DELETE", body: RegistrationEmptyBody())
    }

    func revokeOtherDevices() async throws {
        try await requestNoResponse(path: ["v1", "members", "me", "devices", "revoke-others"], method: "POST", body: RegistrationEmptyBody())
    }

    func selectCurrentDeviceAsLocationSource() async throws {
        try await requestNoResponse(path: ["v1", "members", "me", "devices", "current", "location-source"], method: "POST", body: RegistrationEmptyBody())
    }
}

/// Persist only the applicant's short-lived activation capability. It has a
/// separate Keychain namespace from normal tokens and recovery credentials.
nonisolated struct PendingRegistrationCredential: Codable, Sendable {
    let registrationID: UUID
    let installationID: String
    let activationToken: String
    let displayName: String
}

actor KeychainPendingRegistrationStore {
    private let service = "FamilyApp.PendingRegistration"
    private let account = "activation-capability"

    func store(_ credential: PendingRegistrationCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            let item = query.merging([
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]) { _, newValue in newValue }
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        } else if update != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(update))
        }
    }

    func credential() throws -> PendingRegistrationCredential? {
        var item: CFTypeRef?
        let result = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ] as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
        do { return try JSONDecoder().decode(PendingRegistrationCredential.self, from: data) }
        catch { throw RemoteRegistrationError.invalidResponse }
    }

    func clearStoredCredential() { Self.clear() }

    nonisolated static func clear() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "FamilyApp.PendingRegistration",
            kSecAttrAccount: "activation-capability",
        ] as CFDictionary)
    }
}

/// The remote composition can set this handler to establish the existing
/// session and run the existing bootstrap after the token pair is persisted.
typealias RegistrationActivationHandler = @MainActor (UUID, RemoteTokenPair) async throws -> Void

@MainActor
final class RegistrationFlow {
    private let publicAPI: any RemoteRegistrationAPI
    private let approvalAPI: (any RemoteRegistrationApprovalAPI)?
    private let memberManagementAPI: (any RemoteMemberManagementAPI)?
    private let deviceManagementAPI: (any RemoteDeviceManagementAPI)?
    private let credentials: (any RemoteCredentialStore)?
    private let pendingStore: KeychainPendingRegistrationStore
    private let activationHandler: RegistrationActivationHandler?
    let installationID: String
    let recoveryFlow: RecoveryFlow?

    init(
        publicAPI: any RemoteRegistrationAPI,
        approvalAPI: (any RemoteRegistrationApprovalAPI)? = nil,
        memberManagementAPI: (any RemoteMemberManagementAPI)? = nil,
        deviceManagementAPI: (any RemoteDeviceManagementAPI)? = nil,
        credentials: (any RemoteCredentialStore)? = nil,
        pendingStore: KeychainPendingRegistrationStore = KeychainPendingRegistrationStore(),
        installationID: String,
        recoveryFlow: RecoveryFlow? = nil,
        activationHandler: RegistrationActivationHandler? = nil
    ) {
        self.publicAPI = publicAPI
        self.approvalAPI = approvalAPI
        self.memberManagementAPI = memberManagementAPI
        self.deviceManagementAPI = deviceManagementAPI
        self.credentials = credentials
        self.pendingStore = pendingStore
        self.installationID = installationID
        self.recoveryFlow = recoveryFlow
        self.activationHandler = activationHandler
    }

    var canReviewApplications: Bool { approvalAPI != nil }
    var canManageMembers: Bool { memberManagementAPI != nil }
    var canManageDevices: Bool { deviceManagementAPI != nil }

    /// Future remote composition passes this to the flow so a successful
    /// activation follows the existing sync bootstrap before the UI exposes
    /// the approved member's family data. localOnly never constructs either.
    static func bootstrapHandler(
        session: SessionStore, coordinator: RemoteSyncCoordinator
    ) -> RegistrationActivationHandler {
        { memberID, _ in
            _ = try await coordinator.synchronize()
            session.establishRemoteSession(memberRemoteID: memberID)
        }
    }

    func submit(displayName: String, password: String, invitationCode: String) async throws -> RemotePendingRegistration {
        let created = try await publicAPI.submit(
            displayName: displayName, password: password, inviteCode: invitationCode, installationID: installationID
        )
        try await pendingStore.store(PendingRegistrationCredential(
            registrationID: created.registration.id, installationID: installationID,
            activationToken: created.activationToken, displayName: created.registration.displayName
        ))
        return created.registration
    }

    func storedRegistration() async throws -> RemotePendingRegistration? {
        guard let credential = try await pendingStore.credential() else { return nil }
        return try await publicAPI.status(
            registrationID: credential.registrationID, installationID: credential.installationID,
            activationToken: credential.activationToken
        )
    }

    func cancelStoredRegistration() async throws -> RemotePendingRegistration? {
        guard let credential = try await pendingStore.credential() else { return nil }
        let result = try await publicAPI.cancel(
            registrationID: credential.registrationID, installationID: credential.installationID,
            activationToken: credential.activationToken
        )
        await pendingStore.clearStoredCredential()
        return result
    }

    func activateApprovedRegistration() async throws -> RemoteRegistrationActivation? {
        guard let credential = try await pendingStore.credential() else { return nil }
        let status = try await publicAPI.status(
            registrationID: credential.registrationID, installationID: credential.installationID,
            activationToken: credential.activationToken
        )
        guard status.status == .approved else { return nil }
        let result = try await publicAPI.activate(
            registrationID: credential.registrationID, installationID: credential.installationID,
            activationToken: credential.activationToken, deviceName: UIDevice.current.name
        )
        guard let credentials else { throw RemoteRegistrationError.invalidConfiguration }
        try await credentials.store(result.tokenPair)
        try await activationHandler?(result.memberID, result.tokenPair)
        await pendingStore.clearStoredCredential()
        return result
    }

    func reviewableRegistrations() async throws -> [RemotePendingRegistration] {
        guard let approvalAPI else { throw RemoteRegistrationError.invalidConfiguration }
        return try await approvalAPI.pendingRegistrations()
    }

    func decide(registrationID: UUID, approved: Bool) async throws -> RemotePendingRegistration {
        guard let approvalAPI else { throw RemoteRegistrationError.invalidConfiguration }
        return try await approvalAPI.decideRegistration(id: registrationID, approved: approved)
    }

    func requestMemberRemoval(targetMemberID: UUID) async throws -> RemoteMemberRemovalRequest {
        guard let memberManagementAPI else { throw RemoteRegistrationError.invalidConfiguration }
        return try await memberManagementAPI.requestMemberRemoval(targetMemberID: targetMemberID)
    }

    func pendingMemberRemovalRequests() async throws -> [RemoteMemberRemovalRequest] {
        guard let memberManagementAPI else { throw RemoteRegistrationError.invalidConfiguration }
        return try await memberManagementAPI.pendingMemberRemovalRequests()
    }

    func decideMemberRemoval(id: UUID, approved: Bool) async throws -> RemoteMemberRemovalRequest {
        guard let memberManagementAPI else { throw RemoteRegistrationError.invalidConfiguration }
        return try await memberManagementAPI.decideMemberRemoval(id: id, approved: approved)
    }

    func leaveFamily() async throws {
        guard let memberManagementAPI else { throw RemoteRegistrationError.invalidConfiguration }
        try await memberManagementAPI.leaveFamily()
        if let credentials { await credentials.invalidate() }
    }

    func devices() async throws -> [RemoteDeviceSummary] {
        guard let deviceManagementAPI else { throw RemoteRegistrationError.invalidConfiguration }
        return try await deviceManagementAPI.devices()
    }

    func revokeDevice(id: UUID) async throws {
        guard let deviceManagementAPI else { throw RemoteRegistrationError.invalidConfiguration }
        try await deviceManagementAPI.revokeDevice(id: id)
    }

    func revokeOtherDevices() async throws {
        guard let deviceManagementAPI else { throw RemoteRegistrationError.invalidConfiguration }
        try await deviceManagementAPI.revokeOtherDevices()
    }

    func selectCurrentDeviceAsLocationSource() async throws {
        guard let deviceManagementAPI else { throw RemoteRegistrationError.invalidConfiguration }
        try await deviceManagementAPI.selectCurrentDeviceAsLocationSource()
    }

    func invalidateRemoteCredentials() async {
        if let credentials { await credentials.invalidate() }
    }
}

/// Dormant remote-only UI. Local-only keeps the existing fixed-password login
/// and never creates a RegistrationFlow or sends an invitation anywhere.
struct RegistrationStartView: View {
    let flow: RegistrationFlow
    @State private var displayName = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var invitationCode = ""
    @State private var registration: RemotePendingRegistration?
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    var body: some View {
        Form {
            Section("加入家庭") {
                TextField("昵称", text: $displayName).textContentType(.nickname)
                SecureField("密码", text: $password).textContentType(.newPassword)
                SecureField("确认密码", text: $confirmation).textContentType(.newPassword)
                TextField("邀请码", text: $invitationCode)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("邀请码仅用于提交申请；审批通过前不能查看任何家庭内容。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("提交加入申请", action: submit)
                    .disabled(isSubmitting || !isValidInput)
            }
        }
        .navigationTitle("申请加入")
        .navigationDestination(item: $registration) { value in
            RegistrationWaitingView(flow: flow, initialRegistration: value)
        }
        .alert("加入申请", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var isValidInput: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        password.count >= 8 && password == confirmation && !invitationCode.isEmpty
    }

    private func submit() {
        Task { @MainActor in
            isSubmitting = true
            defer { isSubmitting = false }
            do {
                registration = try await flow.submit(
                    displayName: displayName, password: password, invitationCode: invitationCode
                )
                password = ""
                confirmation = ""
                invitationCode = ""
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct RegistrationWaitingView: View {
    let flow: RegistrationFlow
    let initialRegistration: RemotePendingRegistration
    @State private var registration: RemotePendingRegistration?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var showRecoverySetup = false

    private var current: RemotePendingRegistration { registration ?? initialRegistration }

    var body: some View {
        Form {
            Section("申请状态") {
                LabeledContent("昵称", value: current.displayName)
                LabeledContent("状态", value: current.status.localizedName)
                LabeledContent("提交时间", value: FamilyFormatters.dateTime.string(from: current.createdAt))
                if current.status == .pending {
                    Text("审批通过前，你无法查看议事堂、地图、日程、课表或其他家庭数据。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("刷新状态", action: refresh).disabled(isWorking)
                if current.status == .pending {
                    Button("取消申请", role: .destructive, action: cancel).disabled(isWorking)
                }
                if current.status == .approved {
                    Button("完成登录", action: activate).disabled(isWorking)
                }
            }
        }
        .navigationTitle("等待审批")
        .task { await loadStoredStatus() }
        .sheet(isPresented: $showRecoverySetup) {
            if let recoveryFlow = flow.recoveryFlow {
                NavigationStack { RecoverySetupView(flow: recoveryFlow) }
            }
        }
        .alert("加入申请", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func loadStoredStatus() async {
        do { registration = try await flow.storedRegistration() }
        catch is CancellationError { return }
        catch { errorMessage = error.localizedDescription }
    }

    private func refresh() { Task { @MainActor in await run { registration = try await flow.storedRegistration() } } }

    private func cancel() { Task { @MainActor in await run { registration = try await flow.cancelStoredRegistration() } } }

    private func activate() {
        Task { @MainActor in
            await run {
                let result = try await flow.activateApprovedRegistration()
                if result != nil, flow.recoveryFlow != nil { showRecoverySetup = true }
            }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do { try await action() }
        catch is CancellationError { return }
        catch { errorMessage = error.localizedDescription }
    }
}

/// Restores only the current installation's Keychain-backed application. It
/// cannot enumerate registrations or turn a pending request into a session.
struct StoredRegistrationView: View {
    let flow: RegistrationFlow
    @State private var registration: RemotePendingRegistration?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let registration {
                RegistrationWaitingView(flow: flow, initialRegistration: registration)
            } else if isLoading {
                ProgressView()
            } else {
                ContentUnavailableView("没有待处理申请", systemImage: "person.badge.clock")
            }
        }
        .navigationTitle("加入申请")
        .task {
            defer { isLoading = false }
            do { registration = try await flow.storedRegistration() }
            catch is CancellationError { return }
            catch { errorMessage = error.localizedDescription }
        }
        .alert("加入申请", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}

/// Remote-only account control. It is reachable only when a future remote
/// composition injects the authenticated API; localOnly never constructs the
/// flow or performs a device request.
struct LoggedInDevicesView: View {
    private enum PendingAction: Identifiable {
        case revoke(RemoteDeviceSummary)
        case revokeOthers

        var id: String {
            switch self {
            case .revoke(let device): "revoke-\(device.id.uuidString)"
            case .revokeOthers: "revoke-others"
            }
        }
    }

    let flow: RegistrationFlow
    @Environment(AppEnvironment.self) private var env
    @State private var devices: [RemoteDeviceSummary] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var pendingAction: PendingAction?

    private var currentDevice: RemoteDeviceSummary? { devices.first(where: \.isCurrent) }
    private var otherDevices: [RemoteDeviceSummary] { devices.filter { !$0.isCurrent } }

    var body: some View {
        List {
            if let currentDevice {
                Section("当前设备") { deviceRow(currentDevice, isCurrent: true) }
            } else if !isLoading {
                Section { ContentUnavailableView("当前设备不可用", systemImage: "iphone.slash") }
            }
            if !otherDevices.isEmpty {
                Section("其他设备") {
                    ForEach(otherDevices) { deviceRow($0, isCurrent: false) }
                    Button("退出其他所有设备", role: .destructive) { pendingAction = .revokeOthers }
                        .disabled(isLoading)
                }
            }
        }
        .overlay { if isLoading { ProgressView() } }
        .navigationTitle("已登录设备")
        .task { await reload() }
        .confirmationDialog(dialogTitle, isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }
        ), titleVisibility: .visible) {
            Button(dialogButtonTitle, role: .destructive) { performPendingAction() }
        } message: { Text(dialogMessage) }
        .alert("已登录设备", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("好", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private func deviceRow(_ device: RemoteDeviceSummary, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(device.displayName, systemImage: isCurrent ? "iphone" : "laptopcomputer")
                Spacer()
                if device.isLocationSource {
                    Text("位置来源").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("首次登录：\(FamilyFormatters.dateTime.string(from: device.firstSeenAt))")
                .font(.caption).foregroundStyle(.secondary)
            Text("最近活跃：\(FamilyFormatters.dateTime.string(from: device.lastSeenAt))")
                .font(.caption).foregroundStyle(.secondary)
            if isCurrent {
                if !device.isLocationSource {
                    Button("使用此设备共享我的位置", action: selectLocationSource)
                        .buttonStyle(.bordered)
                        .disabled(isLoading)
                }
                Button("退出当前设备", role: .destructive) { pendingAction = .revoke(device) }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
            } else {
                Button("退出此设备", role: .destructive) { pendingAction = .revoke(device) }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
            }
        }
        .padding(.vertical, 2)
    }

    private var dialogTitle: String {
        guard let pendingAction else { return "" }
        switch pendingAction {
        case .revoke(let device): return device.isCurrent ? "退出当前设备？" : "退出此设备？"
        case .revokeOthers: return "退出其他所有设备？"
        }
    }

    private var dialogButtonTitle: String {
        guard let pendingAction else { return "" }
        switch pendingAction {
        case .revoke(let device): return device.isCurrent ? "退出当前设备" : "退出此设备"
        case .revokeOthers: return "退出其他所有设备"
        }
    }

    private var dialogMessage: String {
        guard let pendingAction else { return "" }
        switch pendingAction {
        case .revoke(let device):
            return device.isCurrent ? "当前设备会立即失去远端会话。" : "该设备的所有刷新会话会立即失效。"
        case .revokeOthers:
            return "其他设备的所有刷新会话会立即失效，不影响当前设备。"
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            devices = try await flow.devices()
            env.setRemoteLocationSourceActive(currentDevice?.isLocationSource == true)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectLocationSource() {
        Task { @MainActor in
            isLoading = true
            defer { isLoading = false }
            do {
                try await flow.selectCurrentDeviceAsLocationSource()
                await reload()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performPendingAction() {
        guard let action = pendingAction else { return }
        Task { @MainActor in
            isLoading = true
            defer { isLoading = false; pendingAction = nil }
            do {
                switch action {
                case .revoke(let device):
                    try await flow.revokeDevice(id: device.id)
                    if device.isCurrent {
                        env.setRemoteLocationSourceActive(false)
                        await flow.invalidateRemoteCredentials()
                        env.session.logout()
                    } else {
                        await reload()
                    }
                case .revokeOthers:
                    try await flow.revokeOtherDevices()
                    await reload()
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct FamilyMembersView: View {
    let flow: RegistrationFlow
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \MemberProfile.nickname) private var profiles: [MemberProfile]
    @State private var removalTarget: MemberProfile?
    @State private var confirmDeparture = false
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var activeProfiles: [MemberProfile] { profiles.filter(\.isActiveMember) }
    private var departedProfiles: [MemberProfile] { profiles.filter { !$0.isActiveMember } }
    private var currentRemoteID: UUID? {
        guard let value = env.session.currentMemberID else { return nil }
        return MemberIdentity.remoteUUID(for: value)
    }

    var body: some View {
        List {
            Section("家庭成员") {
                ForEach(activeProfiles) { profile in memberRow(profile) }
            }
            if !departedProfiles.isEmpty {
                Section("历史成员") {
                    ForEach(departedProfiles) { profile in memberRow(profile) }
                }
            }
            if flow.canReviewApplications {
                Section {
                    NavigationLink { JoinRequestListView(flow: flow) } label: {
                        Label("加入申请", systemImage: "person.badge.clock")
                    }
                }
            }
            if flow.canManageMembers {
                Section("成员管理") {
                    NavigationLink { MemberRemovalRequestListView(flow: flow) } label: {
                        Label("移除申请", systemImage: "person.badge.minus")
                    }
                    if let profile = profiles.first(where: { $0.stableRemoteID == currentRemoteID }),
                       profile.isActiveMember, !profile.isProtectedInitialMember {
                        Button("退出家庭", role: .destructive) { confirmDeparture = true }
                    }
                }
            }
        }
        .navigationTitle("家庭成员")
        .confirmationDialog("申请移除 \(removalTarget?.nickname ?? "该成员")？", isPresented: Binding(
            get: { removalTarget != nil }, set: { if !$0 { removalTarget = nil } }
        ), titleVisibility: .visible) {
            Button("提交移除申请", role: .destructive) { requestRemoval() }
        } message: {
            Text("需要另一名有效成员批准后才会移除，历史记录会保留。")
        }
        .confirmationDialog("确认退出家庭？", isPresented: $confirmDeparture, titleVisibility: .visible) {
            Button("退出家庭", role: .destructive) { leaveFamily() }
        } message: {
            Text("退出后将立即失去家庭数据访问权限，历史记录会保留。")
        }
        .alert("成员管理", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private func memberRow(_ profile: MemberProfile) -> some View {
        HStack {
            MemberAvatar(memberID: profile.memberID)
            VStack(alignment: .leading) {
                Text(profile.displayName)
                if profile.isProtectedInitialMember {
                    Text("初始成员").font(.caption).foregroundStyle(.secondary)
                } else if !profile.isActiveMember {
                    Text("历史记录仍会保留").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if flow.canManageMembers,
               profile.isActiveMember,
               !profile.isProtectedInitialMember,
               profile.stableRemoteID != currentRemoteID {
                Button("移除") { removalTarget = profile }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .accessibilityLabel("申请移除 \(profile.nickname)")
            }
        }
    }

    private func requestRemoval() {
        guard let target = removalTarget?.stableRemoteID else { return }
        Task { @MainActor in
            isWorking = true
            defer { isWorking = false; removalTarget = nil }
            do { _ = try await flow.requestMemberRemoval(targetMemberID: target) }
            catch is CancellationError { return }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func leaveFamily() {
        Task { @MainActor in
            isWorking = true
            defer { isWorking = false }
            do {
                try await flow.leaveFamily()
                env.session.logout()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct MemberRemovalRequestListView: View {
    let flow: RegistrationFlow
    @Environment(AppEnvironment.self) private var env
    @Query private var profiles: [MemberProfile]
    @State private var requests: [RemoteMemberRemovalRequest] = []
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        List {
            if requests.isEmpty && !isLoading {
                ContentUnavailableView("暂无移除申请", systemImage: "person.badge.minus")
            } else {
                ForEach(requests) { request in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(memberName(for: request.targetMemberID)).font(.headline)
                        Text("发起人：\(memberName(for: request.requesterID)) · \(FamilyFormatters.dateTime.string(from: request.createdAt))")
                            .font(.caption).foregroundStyle(.secondary)
                        if request.status == .pending, canDecide(request) {
                            HStack {
                                Button("批准移除", role: .destructive) { decide(request, approved: true) }
                                Button("拒绝") { decide(request, approved: false) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .overlay { if isLoading { ProgressView() } }
        .navigationTitle("移除申请")
        .task { await reload() }
        .alert("成员管理", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func memberName(for remoteID: UUID) -> String {
        profiles.first(where: { $0.stableRemoteID == remoteID })?.displayName ?? "成员"
    }

    private func canDecide(_ request: RemoteMemberRemovalRequest) -> Bool {
        guard let current = env.session.currentMemberID.flatMap(MemberIdentity.remoteUUID(for:)) else { return false }
        return current != request.requesterID && current != request.targetMemberID
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do { requests = try await flow.pendingMemberRemovalRequests() }
        catch is CancellationError { return }
        catch { errorMessage = error.localizedDescription }
    }

    private func decide(_ request: RemoteMemberRemovalRequest, approved: Bool) {
        Task { @MainActor in
            do {
                _ = try await flow.decideMemberRemoval(id: request.id, approved: approved)
                await reload()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct JoinRequestListView: View {
    let flow: RegistrationFlow
    @State private var registrations: [RemotePendingRegistration] = []
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        List {
            if registrations.isEmpty && !isLoading {
                ContentUnavailableView("暂无加入申请", systemImage: "person.badge.clock")
            } else {
                ForEach(registrations) { registration in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(registration.displayName).font(.headline)
                        Text(FamilyFormatters.dateTime.string(from: registration.createdAt))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("批准") { decide(registration, approved: true) }
                            Button("拒绝", role: .destructive) { decide(registration, approved: false) }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .overlay { if isLoading { ProgressView() } }
        .navigationTitle("加入申请")
        .task { await reload() }
        .alert("加入申请", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do { registrations = try await flow.reviewableRegistrations() }
        catch is CancellationError { return }
        catch { errorMessage = error.localizedDescription }
    }

    private func decide(_ registration: RemotePendingRegistration, approved: Bool) {
        Task { @MainActor in
            do {
                _ = try await flow.decide(registrationID: registration.id, approved: approved)
                await reload()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
