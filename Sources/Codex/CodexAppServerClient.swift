import Foundation

enum CodexAccount: Equatable {
    case apiKey
    case chatgpt(email: String, planType: String)
}

struct CodexAccountResponse: Equatable {
    let account: CodexAccount?
    let requiresOpenAIAuth: Bool
}

struct CodexAuthStatus: Equatable {
    let authMethod: String?
    let authToken: String?
    let requiresOpenAIAuth: Bool?
}

protocol CodexAccountReading: AnyObject, Sendable {
    func getAccount(refreshToken: Bool) async throws -> CodexAccountResponse
}

protocol CodexAuthProviding: AnyObject, Sendable {
    func getAuthStatus(includeToken: Bool, refreshToken: Bool) async throws -> CodexAuthStatus
}

actor CodexAppServerClient: CodexAccountReading, CodexAuthProviding {
    enum Error: Swift.Error, Equatable {
        case binaryMissing
        case processLaunchFailed(String)
        case transportFailure(String)
        case rpcFailure(code: Int, message: String)
        case invalidResponse
    }

    private let transportFactory: () throws -> any CodexLineTransport
    private var transport: (any CodexLineTransport)?
    private var initialized = false
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, Swift.Error>] = [:]

    init(processManager: CodexProcessManager = CodexProcessManager()) {
        self.transportFactory = {
            try processManager.makeTransport()
        }
    }

    init(transportFactory: @escaping () throws -> any CodexLineTransport) {
        self.transportFactory = transportFactory
    }

    func getAccount(refreshToken: Bool) async throws -> CodexAccountResponse {
        try await initializeIfNeeded()

        let params = ["refreshToken": refreshToken]
        let responseData = try await request(method: "account/read", params: params)
        let envelope = try JSONDecoder().decode(GetAccountEnvelope.self, from: responseData)

        let account: CodexAccount? = envelope.account.map { account -> CodexAccount in
            switch account {
            case .apiKey:
                return .apiKey
            case .chatgpt(let payload):
                return .chatgpt(email: payload.email, planType: payload.planType)
            }
        }

        return CodexAccountResponse(
            account: account,
            requiresOpenAIAuth: envelope.requiresOpenAIAuth
        )
    }

    func getAuthStatus(includeToken: Bool, refreshToken: Bool) async throws -> CodexAuthStatus {
        try await initializeIfNeeded()

        let params: [String: Any] = [
            "includeToken": includeToken,
            "refreshToken": refreshToken,
        ]
        let responseData = try await request(method: "getAuthStatus", params: params)
        let envelope = try JSONDecoder().decode(GetAuthStatusEnvelope.self, from: responseData)

        return CodexAuthStatus(
            authMethod: envelope.authMethod,
            authToken: envelope.authToken,
            requiresOpenAIAuth: envelope.requiresOpenAIAuth
        )
    }

    private func initializeIfNeeded() async throws {
        guard !initialized else { return }

        try ensureTransport()

        let params: [String: Any] = [
            "clientInfo": [
                "name": "voice_companion",
                "title": "VoiceCompanion",
                "version": "0.1.0",
            ],
            "capabilities": [
                "experimentalApi": true,
            ],
        ]

        _ = try await request(method: "initialize", params: params)
        try sendNotification(method: "initialized", params: nil)
        initialized = true
    }

    private func ensureTransport() throws {
        guard transport == nil else { return }

        do {
            let createdTransport = try transportFactory()
            createdTransport.onLine = { [weak self] line in
                Task {
                    await self?.handle(line: line)
                }
            }
            try createdTransport.start()
            transport = createdTransport
        } catch let error as CodexProcessManager.Error {
            switch error {
            case .binaryMissing:
                throw Error.binaryMissing
            case .launchFailed(let message):
                throw Error.processLaunchFailed(message)
            }
        } catch {
            throw Error.transportFailure(error.localizedDescription)
        }
    }

    private func request(method: String, params: Any?) async throws -> Data {
        let requestID = nextRequestID
        nextRequestID += 1

        let payload = try makePayload(id: requestID, method: method, params: params)
        let requestData = try JSONSerialization.data(withJSONObject: payload, options: [])
        let line = String(decoding: requestData, as: UTF8.self)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation

            do {
                try transport?.write(line: line)
            } catch {
                pendingRequests.removeValue(forKey: requestID)
                continuation.resume(throwing: Error.transportFailure(error.localizedDescription))
            }
        }
    }

    private func sendNotification(method: String, params: Any?) throws {
        let payload = try makePayload(id: nil, method: method, params: params)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        let line = String(decoding: data, as: UTF8.self)

        do {
            try transport?.write(line: line)
        } catch {
            throw Error.transportFailure(error.localizedDescription)
        }
    }

    private func makePayload(id: Int?, method: String, params: Any?) throws -> [String: Any] {
        var payload: [String: Any] = ["method": method]

        if let id {
            payload["id"] = id
        }

        if let params {
            payload["params"] = params
        }

        return payload
    }

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int,
              let continuation = pendingRequests.removeValue(forKey: id) else {
            return
        }

        if let error = object["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "Unknown Codex error"
            continuation.resume(throwing: Error.rpcFailure(code: code, message: message))
            return
        }

        let result = object["result"] ?? NSNull()

        do {
            let resultData = try JSONSerialization.data(withJSONObject: result, options: [])
            continuation.resume(returning: resultData)
        } catch {
            continuation.resume(throwing: Error.invalidResponse)
        }
    }
}

private struct GetAccountEnvelope: Decodable {
    let account: GetAccountPayload?
    let requiresOpenAIAuth: Bool

    private enum CodingKeys: String, CodingKey {
        case account
        case requiresOpenAIAuth = "requiresOpenaiAuth"
    }
}

private enum GetAccountPayload: Decodable {
    case apiKey
    case chatgpt(ChatgptPayload)

    struct ChatgptPayload: Decodable {
        let email: String
        let planType: String
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "apiKey":
            self = .apiKey
        case "chatgpt":
            self = .chatgpt(try ChatgptPayload(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported account type")
        }
    }
}

private struct GetAuthStatusEnvelope: Decodable {
    let authMethod: String?
    let authToken: String?
    let requiresOpenAIAuth: Bool?

    private enum CodingKeys: String, CodingKey {
        case authMethod
        case authToken
        case requiresOpenAIAuth = "requiresOpenaiAuth"
    }
}
