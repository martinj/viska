import Foundation
import XCTest
@testable import Viska

final class CodexAppServerClientTests: XCTestCase {
    func testGetAccountInitializesConnectionBeforeAccountRead() async throws {
        let transport = MockCodexLineTransport()
        let client = CodexAppServerClient(transportFactory: { transport })

        transport.onWrite = { line in
            let payload = try XCTUnwrap(Self.parse(line: line))
            let method = payload["method"] as? String
            let id = payload["id"] as? Int

            switch method {
            case "initialize":
                transport.onLine?(
                    """
                    {"id":\(id!),"result":{"userAgent":"Viska/0.1","codexHome":"/tmp/codex-home","platformFamily":"unix","platformOs":"macos"}}
                    """
                )
            case "account/read":
                transport.onLine?(
                    """
                    {"id":\(id!),"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"pro"},"requiresOpenaiAuth":true}}
                    """
                )
            default:
                break
            }
        }

        let response = try await client.getAccount(refreshToken: false)

        XCTAssertEqual(response.account, .chatgpt(email: "user@example.com", planType: "pro"))
        XCTAssertEqual(transport.writtenMethods, ["initialize", "initialized", "account/read"])
    }

    func testPendingRequestFailsWhenTransportTerminates() async {
        let transport = MockCodexLineTransport()
        let client = CodexAppServerClient(transportFactory: { transport })

        transport.onWrite = { line in
            let payload = try XCTUnwrap(Self.parse(line: line))
            let method = payload["method"] as? String
            let id = payload["id"] as? Int

            switch method {
            case "initialize":
                transport.onLine?(
                    """
                    {"id":\(id!),"result":{"userAgent":"Viska/0.1","codexHome":"/tmp/codex-home","platformFamily":"unix","platformOs":"macos"}}
                    """
                )
            case "account/read":
                transport.terminate(message: "Codex app-server exited before responding.")
            default:
                break
            }
        }

        await XCTAssertThrowsErrorAsync(
            try await client.getAccount(refreshToken: false)
        ) { error in
            XCTAssertEqual(
                error as? CodexAppServerClient.Error,
                .transportFailure("Codex app-server exited before responding.")
            )
        }
    }

    private static func parse(line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return object
    }
}

private final class MockCodexLineTransport: CodexLineTransport, @unchecked Sendable {
    var onLine: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (String?) -> Void)?
    var onWrite: ((String) throws -> Void)?
    private(set) var writtenLines: [String] = []

    var writtenMethods: [String] {
        writtenLines.compactMap {
            guard let data = $0.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            return object["method"] as? String
        }
    }

    func start() throws {}

    func write(line: String) throws {
        writtenLines.append(line)
        try onWrite?(line)
    }

    func terminate(message: String? = nil) {
        onTermination?(message)
    }
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
