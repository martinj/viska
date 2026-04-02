import Foundation
import XCTest
@testable import VoiceCompanion

final class TranscriptionClientTests: XCTestCase {
    override class func tearDown() {
        super.tearDown()
        MockURLProtocol.requestHandler = nil
    }

    func testUnauthorizedResponseRefreshesTokenOnceAndRetries() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data("audio".utf8).write(to: audioURL)

        let authProvider = FakeCodexAuthProvider(
            responses: [
                CodexAuthStatus(authMethod: "chatgpt", authToken: Self.makeJWT(accountID: "acct-1"), requiresOpenAIAuth: true),
                CodexAuthStatus(authMethod: "chatgpt", authToken: Self.makeJWT(accountID: "acct-2"), requiresOpenAIAuth: true),
            ]
        )

        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1

            if requestCount == 1 {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }

            let body = #"{"text":"hello world"}"#.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                body
            )
        }

        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            return configuration
        }())

        let client = TranscriptionClient(
            authProvider: authProvider,
            session: session,
            baseURL: URL(string: "https://chatgpt.com/backend-api/")!,
            userAgent: "VoiceCompanionTests/1.0"
        )

        let result = try await client.transcribe(
            audio: RecordedAudio(fileURL: audioURL, sampleRate: 16_000, sampleCount: 2_000)
        )

        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(authProvider.calls, [false, true])
        XCTAssertEqual(requestCount, 2)
    }

    func testMissingAuthTokenThrowsUnavailableError() async {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try? Data("audio".utf8).write(to: audioURL)

        let authProvider = FakeCodexAuthProvider(
            responses: [
                CodexAuthStatus(authMethod: "chatgpt", authToken: nil, requiresOpenAIAuth: true),
            ]
        )

        let session = URLSession(configuration: .ephemeral)
        let client = TranscriptionClient(
            authProvider: authProvider,
            session: session,
            baseURL: URL(string: "https://chatgpt.com/backend-api/")!,
            userAgent: "VoiceCompanionTests/1.0"
        )

        await XCTAssertThrowsErrorAsync(
            try await client.transcribe(
                audio: RecordedAudio(fileURL: audioURL, sampleRate: 16_000, sampleCount: 2_000)
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptionClient.Error, .missingAuthToken)
        }
    }

    private static func makeJWT(accountID: String) -> String {
        let header = Data(#"{"alg":"none"}"#.utf8).base64EncodedString()
        let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"\#(accountID)"}}"#.utf8)
            .base64EncodedString()
        return "\(header).\(payload)."
    }
}

private final class FakeCodexAuthProvider: CodexAuthProviding, @unchecked Sendable {
    private let responses: [CodexAuthStatus]
    private(set) var calls: [Bool] = []

    init(responses: [CodexAuthStatus]) {
        self.responses = responses
    }

    func getAuthStatus(includeToken: Bool, refreshToken: Bool) async throws -> CodexAuthStatus {
        calls.append(refreshToken)
        return responses[calls.count - 1]
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
