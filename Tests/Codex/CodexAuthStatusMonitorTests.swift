import XCTest
@testable import Viska

@MainActor
final class CodexAuthStatusMonitorTests: XCTestCase {
    func testClassifiesSignedOutStatus() async throws {
        let client = FakeCodexStatusClient(
            accountResponse: CodexAccountResponse(account: nil, requiresOpenAIAuth: true)
        )
        let monitor = CodexAuthStatusMonitor(client: client)

        let availability = await monitor.refresh()

        XCTAssertEqual(availability, .signedOut)
    }

    func testClassifiesUnsupportedAuthModeWhenOpenAIAuthNotRequired() async throws {
        let client = FakeCodexStatusClient(
            accountResponse: CodexAccountResponse(account: nil, requiresOpenAIAuth: false)
        )
        let monitor = CodexAuthStatusMonitor(client: client)

        let availability = await monitor.refresh()

        XCTAssertEqual(availability, .unsupportedAuthMode)
    }
}

@MainActor
private final class FakeCodexStatusClient: CodexAccountReading {
    let accountResponse: CodexAccountResponse

    init(accountResponse: CodexAccountResponse) {
        self.accountResponse = accountResponse
    }

    func getAccount(refreshToken: Bool) async throws -> CodexAccountResponse {
        accountResponse
    }
}
