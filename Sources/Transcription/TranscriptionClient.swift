import Foundation

protocol AudioTranscribing: AnyObject, Sendable {
    func transcribe(audio: RecordedAudio) async throws -> TranscriptionResult
}

final class TranscriptionClient: AudioTranscribing, @unchecked Sendable {
    enum Error: Swift.Error, Equatable {
        case missingAuthToken
        case unsupportedAuthMethod
        case httpStatus(Int)
        case invalidResponse
        case requestFailed(String)
    }

    private let authProvider: any CodexAuthProviding
    private let session: URLSession
    private let baseURL: URL
    private let userAgent: String

    init(
        authProvider: any CodexAuthProviding,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api/")!,
        userAgent: String = "VoiceCompanion/0.1"
    ) {
        self.authProvider = authProvider
        self.session = session
        self.baseURL = baseURL
        self.userAgent = userAgent
    }

    func transcribe(audio: RecordedAudio) async throws -> TranscriptionResult {
        let firstAuth = try await resolveAuth(refreshToken: false)

        do {
            return try await sendRequest(audio: audio, auth: firstAuth)
        } catch let error as Error where error == .httpStatus(401) {
            let refreshedAuth = try await resolveAuth(refreshToken: true)
            return try await sendRequest(audio: audio, auth: refreshedAuth)
        }
    }

    private func resolveAuth(refreshToken: Bool) async throws -> ResolvedAuth {
        let status = try await authProvider.getAuthStatus(includeToken: true, refreshToken: refreshToken)

        guard status.authMethod == "chatgpt" else {
            throw Error.unsupportedAuthMethod
        }

        guard let authToken = status.authToken, !authToken.isEmpty else {
            throw Error.missingAuthToken
        }

        return ResolvedAuth(
            token: authToken,
            accountID: Self.extractAccountID(fromJWT: authToken)
        )
    }

    private func sendRequest(audio: RecordedAudio, auth: ResolvedAuth) async throws -> TranscriptionResult {
        let request = try TranscriptionRequest(
            audio: audio,
            authToken: auth.token,
            accountID: auth.accountID,
            baseURL: baseURL,
            userAgent: userAgent
        ).makeURLRequest()

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw Error.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw Error.httpStatus(httpResponse.statusCode)
            }

            return try JSONDecoder().decode(TranscriptionResult.self, from: data)
        } catch let error as Error {
            throw error
        } catch let error as DecodingError {
            throw Error.requestFailed(error.localizedDescription)
        } catch {
            throw Error.requestFailed(error.localizedDescription)
        }
    }

    private static func extractAccountID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        let payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let paddedPayload = payload.padding(
            toLength: ((payload.count + 3) / 4) * 4,
            withPad: "=",
            startingAt: 0
        )

        guard let data = Data(base64Encoded: paddedPayload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = object["https://api.openai.com/auth"] as? [String: Any] else {
            return nil
        }

        return auth["chatgpt_account_id"] as? String
    }
}

private struct ResolvedAuth {
    let token: String
    let accountID: String?
}
