import Foundation
import CryptoKit
import Security
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

/// Recovery is a control-plane feature. These values never enter SwiftData,
/// LocalBackupService, SyncChange, analytics, or ordinary app logs.
nonisolated enum RecoveryPurpose: String, Codable, CaseIterable, Sendable, Identifiable {
    case forgotPassword = "forgot_password"
    case newDevice = "new_device"
    case accountTakeover = "account_takeover"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .forgotPassword: "忘记密码"
        case .newDevice: "新设备恢复"
        case .accountTakeover: "账户接管"
        }
    }
}

nonisolated enum MnemonicError: LocalizedError, Sendable {
    case invalidWordCount, unknownWord, checksumMismatch, randomFailure

    var errorDescription: String? {
        switch self {
        case .invalidWordCount: "恢复助记词必须恰好包含 12 个英文单词。"
        case .unknownWord: "恢复助记词包含不在标准词表中的单词。"
        case .checksumMismatch: "恢复助记词校验失败，请检查顺序和拼写。"
        case .randomFailure: "无法安全生成恢复助记词。"
        }
    }
}

/// BIP-39 12-word validation/generation only. This deliberately does not
/// derive wallet keys or expose any cryptocurrency-related API.
nonisolated struct BIP39Mnemonic: Equatable, Sendable {
    let words: [String]

    init(words: [String]) throws {
        let normalized = Self.normalize(words)
        guard normalized.count == 12 else { throw MnemonicError.invalidWordCount }
        let indexes = try normalized.map { word -> Int in
            guard let index = BIP39EnglishWordList.indexByWord[word] else { throw MnemonicError.unknownWord }
            return index
        }
        guard Self.hasValidChecksum(indexes) else { throw MnemonicError.checksumMismatch }
        self.words = normalized
    }

    static func generate() throws -> BIP39Mnemonic {
        var entropy = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy) == errSecSuccess else {
            throw MnemonicError.randomFailure
        }
        let digest = Array(SHA256.hash(data: Data(entropy)))
        var indexes: [Int] = []
        for group in 0..<12 {
            var index = 0
            for offset in 0..<11 {
                let bitIndex = group * 11 + offset
                let bit: Int
                if bitIndex < 128 {
                    bit = Int((entropy[bitIndex / 8] >> (7 - bitIndex % 8)) & 1)
                } else {
                    let checksumBit = bitIndex - 128
                    bit = Int((digest[0] >> (7 - checksumBit)) & 1)
                }
                index = (index << 1) | bit
            }
            indexes.append(index)
        }
        return try BIP39Mnemonic(words: indexes.map { BIP39EnglishWordList.words[$0] })
    }

    static func parse(_ value: String) throws -> BIP39Mnemonic {
        try BIP39Mnemonic(words: value.decomposedStringWithCompatibilityMapping
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init))
    }

    var phrase: String { words.joined(separator: " ") }

    /// A domain-separated HKDF output is sent to the backend. The readable
    /// BIP-39 phrase stays on device and is never a server credential.
    var recoverySecret: String {
        let material = SymmetricKey(data: Data(phrase.decomposedStringWithCompatibilityMapping.utf8))
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: material,
            salt: Data("FamilyApp Recovery Secret v1".utf8),
            info: Data("BIP39 12-word account recovery".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    private static func normalize(_ values: [String]) -> [String] {
        values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .decomposedStringWithCompatibilityMapping.lowercased()
        }.filter { !$0.isEmpty }
    }

    private static func hasValidChecksum(_ indexes: [Int]) -> Bool {
        guard indexes.count == 12 else { return false }
        var entropy = [UInt8](repeating: 0, count: 16)
        var checksum = 0
        for bitIndex in 0..<132 {
            let word = indexes[bitIndex / 11]
            let bit = (word >> (10 - bitIndex % 11)) & 1
            if bitIndex < 128 {
                entropy[bitIndex / 8] |= UInt8(bit << (7 - bitIndex % 8))
            } else {
                checksum = (checksum << 1) | bit
            }
        }
        let digest = Array(SHA256.hash(data: Data(entropy)))
        let expected = Int(digest[0] >> 4)
        return checksum == expected
    }
}

nonisolated struct RemoteRecoveryCredentialState: Decodable, Sendable {
    let generation: Int?
    let configured: Bool?

    init(generation: Int? = nil, configured: Bool? = nil) {
        self.generation = generation
        self.configured = configured
    }
}

nonisolated struct RemoteRecoverySession: Decodable, Sendable {
    let recoverySessionID: UUID
    let recoveryToken: String
    let purpose: RecoveryPurpose
    let expiresAt: Date
    let recoveryGeneration: Int

    enum CodingKeys: String, CodingKey {
        case recoverySessionID = "recovery_session_id", recoveryToken = "recovery_token"
        case purpose, expiresAt = "expires_at", recoveryGeneration = "recovery_generation"
    }
}

nonisolated enum RemoteRecoveryError: LocalizedError, Sendable {
    case invalidConfiguration, invalidResponse, authorizationUnavailable, requestFailed(Int)
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "恢复服务配置无效。"
        case .invalidResponse: "恢复服务返回的数据无效。"
        case .authorizationUnavailable: "当前远端登录已失效。"
        case .requestFailed: "恢复请求未能完成。"
        }
    }
}

/// The unauthenticated half is deliberately isolated from RemoteSyncAPI: a
/// recovery session token is never an access token and cannot call business APIs.
protocol RemoteRecoveryAPI: Sendable {
    func begin(memberID: String, secret: String, purpose: RecoveryPurpose) async throws -> RemoteRecoverySession
    func resetPassword(session: RemoteRecoverySession, newPassword: String) async throws
    func issueDeviceSession(session: RemoteRecoverySession, installationID: String, deviceName: String) async throws -> RemoteTokenPair
    func completeTakeover(session: RemoteRecoverySession, newPassword: String, installationID: String, newSecret: String, deviceName: String) async throws -> RemoteTokenPair
}

protocol RemoteRecoveryAuthenticatedAPI: Sendable {
    func registerRecoveryCredential(secret: String) async throws -> RemoteRecoveryCredentialState
    func recoveryCredentialState() async throws -> RemoteRecoveryCredentialState
}

/// Future remote composition's single storage for the existing access/refresh
/// pair. It is intentionally distinct from the AI key and recovery phrase;
/// replacing the JSON item atomically keeps refresh-token rotation coherent.
actor KeychainRemoteCredentialStore: RemoteCredentialStore {
    private let service = "FamilyApp.RemoteCredentials"
    private let account = "token-pair"

    func accessToken() throws -> String { try tokenPair().accessToken }
    func refreshToken() throws -> String { try tokenPair().refreshToken }
    func deviceID() throws -> UUID { try tokenPair().deviceID }

    func store(_ tokenPair: RemoteTokenPair) throws {
        let data = try JSONEncoder().encode(tokenPair)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            let add = query.merging([
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus)) }
        } else if updateStatus != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }
    }

    func invalidate() {
        Self.clear()
    }

    nonisolated static func clear() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "FamilyApp.RemoteCredentials",
            kSecAttrAccount: "token-pair",
        ] as CFDictionary)
    }

    private func tokenPair() throws -> RemoteTokenPair {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let pair = try? JSONDecoder().decode(RemoteTokenPair.self, from: data) else {
            throw RemoteSyncError.authenticationRequired
        }
        return pair
    }
}

/// Exists only for future remote composition. Constructing it has no network
/// side effect; AppEnvironment.localOnly never constructs one.
actor RemoteRecoveryAPIClient: RemoteRecoveryAPI {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func begin(memberID: String, secret: String, purpose: RecoveryPurpose) async throws -> RemoteRecoverySession {
        guard let remoteMemberID = MemberIdentity.remoteUUID(for: memberID) else { throw RemoteRecoveryError.invalidConfiguration }
        struct Body: Encodable { let memberID: UUID; let recoverySecret, purpose: String
            enum CodingKeys: String, CodingKey { case memberID = "member_id", recoverySecret = "recovery_secret", purpose }
        }
        return try await request(path: ["v1", "recovery", "sessions"], method: "POST", body: Body(memberID: remoteMemberID, recoverySecret: secret, purpose: purpose.rawValue), response: RemoteRecoverySession.self)
    }

    func resetPassword(session authorization: RemoteRecoverySession, newPassword: String) async throws {
        struct Body: Encodable { let recoveryToken, newPassword: String
            enum CodingKeys: String, CodingKey { case recoveryToken = "recovery_token", newPassword = "new_password" }
        }
        try await requestVoid(path: ["v1", "recovery", "sessions", authorization.recoverySessionID.uuidString, "password"], method: "POST", body: Body(recoveryToken: authorization.recoveryToken, newPassword: newPassword))
    }

    func issueDeviceSession(session authorization: RemoteRecoverySession, installationID: String, deviceName: String) async throws -> RemoteTokenPair {
        struct Body: Encodable { let recoveryToken, installationID, deviceName: String
            enum CodingKeys: String, CodingKey { case recoveryToken = "recovery_token", installationID = "installation_id", deviceName = "device_name" }
        }
        return try await request(path: ["v1", "recovery", "sessions", authorization.recoverySessionID.uuidString, "device"], method: "POST", body: Body(recoveryToken: authorization.recoveryToken, installationID: installationID, deviceName: deviceName), response: RemoteTokenPair.self)
    }

    func completeTakeover(session authorization: RemoteRecoverySession, newPassword: String, installationID: String, newSecret: String, deviceName: String) async throws -> RemoteTokenPair {
        struct Body: Encodable { let recoveryToken, newPassword, installationID, recoverySecret, deviceName: String
            enum CodingKeys: String, CodingKey { case recoveryToken = "recovery_token", newPassword = "new_password", installationID = "installation_id", recoverySecret = "recovery_secret", deviceName = "device_name" }
        }
        return try await request(path: ["v1", "recovery", "sessions", authorization.recoverySessionID.uuidString, "takeover"], method: "POST", body: Body(recoveryToken: authorization.recoveryToken, newPassword: newPassword, installationID: installationID, recoverySecret: newSecret, deviceName: deviceName), response: RemoteTokenPair.self)
    }

    private func request<Body: Encodable, Response: Decodable>(path: [String], method: String, body: Body, response: Response.Type) async throws -> Response {
        let data = try await requestData(path: path, method: method, body: body)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(Response.self, from: data) }
        catch { throw RemoteRecoveryError.invalidResponse }
    }

    private func requestVoid<Body: Encodable>(path: [String], method: String, body: Body) async throws {
        _ = try await requestData(path: path, method: method, body: body)
    }

    private func requestData<Body: Encodable>(path: [String], method: String, body: Body) async throws -> Data {
        guard baseURL.scheme?.lowercased() == "https" else { throw RemoteRecoveryError.invalidConfiguration }
        let suffix = baseURL.lastPathComponent.lowercased() == "v1" && path.first == "v1" ? path.dropFirst() : path[...]
        let url = suffix.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteRecoveryError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw RemoteRecoveryError.requestFailed(http.statusCode) }
        return data
    }
}

/// The remote installation identifier is not a secret, but it must survive a
/// process restart and must not be confused with either AI or recovery data.
/// It is created only by a future remote composition, never in localOnly.
final class RemoteInstallationIDStore {
    private let service = "FamilyApp.RemoteInstallation"
    private let account = "installation-id"

    func installationID() throws -> String {
        var result: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) {
            return value
        }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let value = UUID().uuidString.lowercased()
        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus)) }
        return value
    }

    static func clear() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "FamilyApp.RemoteInstallation",
            kSecAttrAccount: "installation-id",
        ] as CFDictionary)
    }
}

/// A UI-facing coordinator injected only by a future remote composition.
/// No state here is persisted; both the phrase and short-lived authorization
/// disappear when the view is dismissed or the process exits.
@MainActor
final class RecoveryFlow {
    private let publicAPI: any RemoteRecoveryAPI
    private let authenticatedAPI: (any RemoteRecoveryAuthenticatedAPI)?
    private let credentials: (any RemoteCredentialStore)?
    private let sessionReadyHandler: (@MainActor (UUID) async throws -> Void)?
    let installationID: String

    init(publicAPI: any RemoteRecoveryAPI, authenticatedAPI: (any RemoteRecoveryAuthenticatedAPI)? = nil,
         credentials: (any RemoteCredentialStore)? = nil, installationID: String,
         sessionReadyHandler: (@MainActor (UUID) async throws -> Void)? = nil) {
        self.publicAPI = publicAPI
        self.authenticatedAPI = authenticatedAPI
        self.credentials = credentials
        self.sessionReadyHandler = sessionReadyHandler
        self.installationID = installationID
    }

    func register(_ mnemonic: BIP39Mnemonic) async throws -> Int {
        guard let authenticatedAPI else { throw RemoteRecoveryError.authorizationUnavailable }
        guard let generation = try await authenticatedAPI.registerRecoveryCredential(secret: mnemonic.recoverySecret).generation else {
            throw RemoteRecoveryError.invalidResponse
        }
        return generation
    }

    func credentialGeneration() async throws -> Int? {
        guard let authenticatedAPI else { throw RemoteRecoveryError.authorizationUnavailable }
        return try await authenticatedAPI.recoveryCredentialState().generation
    }

    func forgotPassword(memberID: String, mnemonic: BIP39Mnemonic, newPassword: String) async throws {
        let authorization = try await publicAPI.begin(memberID: memberID, secret: mnemonic.recoverySecret, purpose: .forgotPassword)
        try await publicAPI.resetPassword(session: authorization, newPassword: newPassword)
    }

    func recoverNewDevice(memberID: String, mnemonic: BIP39Mnemonic) async throws {
        let authorization = try await publicAPI.begin(memberID: memberID, secret: mnemonic.recoverySecret, purpose: .newDevice)
        let tokens = try await publicAPI.issueDeviceSession(
            session: authorization, installationID: installationID, deviceName: UIDevice.current.name,
        )
        guard let credentials else { throw RemoteRecoveryError.authorizationUnavailable }
        try await credentials.store(tokens)
        guard let memberUUID = MemberIdentity.remoteUUID(for: memberID) else { throw RemoteRecoveryError.invalidConfiguration }
        try await sessionReadyHandler?(memberUUID)
    }

    func takeOver(memberID: String, oldMnemonic: BIP39Mnemonic, newMnemonic: BIP39Mnemonic, newPassword: String) async throws {
        let authorization = try await publicAPI.begin(memberID: memberID, secret: oldMnemonic.recoverySecret, purpose: .accountTakeover)
        let tokens = try await publicAPI.completeTakeover(
            session: authorization, newPassword: newPassword, installationID: installationID,
            newSecret: newMnemonic.recoverySecret, deviceName: UIDevice.current.name,
        )
        guard let credentials else { throw RemoteRecoveryError.authorizationUnavailable }
        try await credentials.store(tokens)
        guard let memberUUID = MemberIdentity.remoteUUID(for: memberID) else { throw RemoteRecoveryError.invalidConfiguration }
        try await sessionReadyHandler?(memberUUID)
    }
}

/// A disposable share item. It includes no login password, access token,
/// refresh token, chat, position, or other family data.
struct TemporaryRecoveryExport: Identifiable {
    let id = UUID()
    let url: URL

    static func make(memberName: String, generation: Int, mnemonic: BIP39Mnemonic) throws -> TemporaryRecoveryExport {
        let text = """
        FamilyApp 恢复助记词
        成员：\(memberName)
        代数：第 \(generation) 代
        生成时间：\(ISO8601DateFormatter().string(from: .now))

        \(mnemonic.phrase)

        请离线、安全保存这 12 个单词。任何获得它们的人都可能恢复你的账户。
        此文件不包含密码、访问令牌、聊天、位置或其他家庭数据。
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("familyapp-recovery-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url, options: .atomic)
        return TemporaryRecoveryExport(url: url)
    }

    func remove() -> Error? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try FileManager.default.removeItem(at: url)
            return nil
        } catch {
            return error
        }
    }
}

struct RecoveryShareSheet: UIViewControllerRepresentable {
    let item: TemporaryRecoveryExport
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in _ = item.remove() }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

@MainActor
struct RecoverySetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    let flow: RecoveryFlow
    @State private var mnemonic: BIP39Mnemonic?
    @State private var confirmationIndexes: [Int] = []
    @State private var answers: [Int: String] = [:]
    @State private var generation = 0
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var exportItem: TemporaryRecoveryExport?
    @State private var confirmExport = false

    private var memberName: String? { env.session.currentMemberID }
    private var isConfirmed: Bool {
        guard let mnemonic else { return false }
        return confirmationIndexes.allSatisfy { answers[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == mnemonic.words[$0] }
    }

    var body: some View {
        Form {
            Section("恢复助记词") {
                if generation > 0 {
                    Text("已设置 · 第 \(generation) 代")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let mnemonic {
                    Text("请按顺序离线保存以下 12 个单词。服务器无法再次展示它们。")
                        .font(.footnote).foregroundStyle(.orange)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(Array(mnemonic.words.enumerated()), id: \.offset) { index, word in
                            Text("\(index + 1). \(word)").frame(maxWidth: .infinity, alignment: .leading).font(.callout.monospaced())
                        }
                    }
                    Button("复制到本机剪贴板", action: copy)
                    Button("导出恢复助记词") { confirmExport = true }
                } else {
                    Button(generation > 0 ? "更换恢复助记词" : "生成新的 12 词助记词", action: generate)
                }
            }
            if mnemonic != nil {
                Section("随机确认") {
                    Text("请填写以下词，确认你已安全保存。") .font(.footnote).foregroundStyle(.secondary)
                    ForEach(confirmationIndexes, id: \.self) { index in
                        TextField("第 \(index + 1) 个词", text: Binding(get: { answers[index] ?? "" }, set: { answers[index] = $0 }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                Section { Button("我已安全保存", action: save).disabled(!isConfirmed || isSaving) }
            }
        }
        .navigationTitle("恢复助记词")
        .task {
            do { generation = try await flow.credentialGeneration() ?? 0 }
            catch { /* An unavailable remote status must not manufacture local state. */ }
        }
        .alert("恢复助记词", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        .confirmationDialog("导出恢复助记词？", isPresented: $confirmExport, titleVisibility: .visible) {
            Button("导出", action: prepareExport)
        } message: { Text("导出文件含有恢复助记词。请只存放在可信位置，分享完成后从目标位置删除。") }
        .sheet(item: $exportItem, onDismiss: { _ = exportItem?.remove() }) { item in
            RecoveryShareSheet(item: item)
        }
    }

    private func prepareExport() {
        guard let mnemonic, let memberName else {
            errorMessage = "无法确认当前成员身份，请重新登录。"
            return
        }
        do { exportItem = try TemporaryRecoveryExport.make(memberName: memberName, generation: max(1, generation), mnemonic: mnemonic) }
        catch let caughtError { errorMessage = "无法创建临时导出文件：\(caughtError.localizedDescription)" }
    }

    private func generate() {
        do {
            mnemonic = try BIP39Mnemonic.generate()
            confirmationIndexes = Array((0..<12).shuffled().prefix(3)).sorted()
            answers = [:]
        } catch let caughtError { errorMessage = caughtError.localizedDescription }
    }

    private func copy() {
        guard let mnemonic else { return }
        UIPasteboard.general.setItems([[UTType.plainText.identifier: mnemonic.phrase]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
    }

    private func save() {
        guard let mnemonic else { return }
        isSaving = true
        Task { @MainActor [flow, mnemonic] in
            defer { isSaving = false }
            do {
                generation = try await flow.register(mnemonic)
                dismiss()
            } catch let caughtError { errorMessage = caughtError.localizedDescription }
        }
    }
}

@MainActor
struct RecoveryStartView: View {
    @Environment(\.dismiss) private var dismiss
    let flow: RecoveryFlow
    @Environment(AppEnvironment.self) private var env
    @State private var memberID = ""
    @State private var purpose: RecoveryPurpose = .forgotPassword
    @State private var phrase = ""
    @State private var newPassword = ""
    @State private var replacementMnemonic: BIP39Mnemonic?
    @State private var confirmationIndexes: [Int] = []
    @State private var answers: [Int: String] = [:]
    @State private var resultMessage: String?
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var replacementConfirmed: Bool {
        guard let replacementMnemonic else { return purpose != .accountTakeover }
        return confirmationIndexes.allSatisfy {
            answers[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == replacementMnemonic.words[$0]
        }
    }
    var body: some View {
        Form {
            Section("恢复方式") {
                TextField("初始账号或成员 UUID", text: $memberID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("用途", selection: $purpose) { ForEach(RecoveryPurpose.allCases) { Text($0.title).tag($0) } }
                TextEditor(text: $phrase).frame(minHeight: 110)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("输入 12 个英文助记词；它只在本机转换为恢复验证值。") .font(.footnote).foregroundStyle(.secondary)
            }
            if purpose != .newDevice {
                Section("新密码") { SecureField("至少 8 位", text: $newPassword).textContentType(.newPassword) }
            }
            if purpose == .accountTakeover { takeoverReplacementSection }
            Section {
                Button(purpose.title, action: submit)
                    .disabled(isWorking || memberID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phrase.isEmpty || !replacementConfirmed || (purpose != .newDevice && newPassword.count < 8))
            }
            if let resultMessage { Section { Text(resultMessage).foregroundStyle(.green) } }
        }
        .navigationTitle("账户恢复")
        .onAppear { if memberID.isEmpty { memberID = env.session.currentMemberID ?? "" } }
        .alert("账户恢复", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private var takeoverReplacementSection: some View {
        Section("新的恢复助记词") {
            if let replacementMnemonic {
                Text("请安全保存新助记词。接管完成后旧助记词立即失效。") .font(.footnote).foregroundStyle(.orange)
                ForEach(Array(replacementMnemonic.words.enumerated()), id: \.offset) { index, word in
                    Text("\(index + 1). \(word)").font(.callout.monospaced())
                }
                ForEach(confirmationIndexes, id: \.self) { index in
                    TextField("第 \(index + 1) 个词", text: Binding(get: { answers[index] ?? "" }, set: { answers[index] = $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } else {
                Button("生成新的 12 词助记词", action: generateReplacement)
            }
        }
    }

    private func generateReplacement() {
        do {
            replacementMnemonic = try BIP39Mnemonic.generate()
            confirmationIndexes = Array((0..<12).shuffled().prefix(3)).sorted()
            answers = [:]
        } catch let caughtError { errorMessage = caughtError.localizedDescription }
    }

    private func submit() {
        do {
            let oldMnemonic = try BIP39Mnemonic.parse(phrase)
            isWorking = true
            Task { @MainActor [flow, memberID, purpose, oldMnemonic, newPassword, replacementMnemonic] in
                defer { isWorking = false }
                do {
                    switch purpose {
                    case .forgotPassword:
                        try await flow.forgotPassword(memberID: memberID, mnemonic: oldMnemonic, newPassword: newPassword)
                        resultMessage = "密码已重设。请使用新的密码通过正常登录流程登录。"
                    case .newDevice:
                        try await flow.recoverNewDevice(memberID: memberID, mnemonic: oldMnemonic)
                        resultMessage = "新设备会话已恢复，可继续进入正常同步流程。"
                    case .accountTakeover:
                        guard let replacementMnemonic else { return }
                        try await flow.takeOver(memberID: memberID, oldMnemonic: oldMnemonic, newMnemonic: replacementMnemonic, newPassword: newPassword)
                        resultMessage = "账户已接管，其他设备会话已撤销，旧助记词已失效。"
                    }
                } catch let caughtError { errorMessage = caughtError.localizedDescription }
            }
        } catch let caughtError { errorMessage = caughtError.localizedDescription }
    }
}
