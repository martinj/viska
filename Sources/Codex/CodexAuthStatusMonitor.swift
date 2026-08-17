import Foundation

enum CodexAvailability: Equatable {
    case ready(email: String, planType: String)
    case binaryMissing
    case processLaunchFailed(String)
    case serverUnavailable(String)
    case signedOut
    case unsupportedAuthMode

    var message: String {
        switch self {
        case .ready(let email, let planType):
            "Signed in as \(email) (\(planType))."
        case .binaryMissing:
            "Codex binary not found. Install `codex` and relaunch."
        case .processLaunchFailed(let detail):
            "Codex app-server failed to launch: \(detail)"
        case .serverUnavailable(let detail):
            "Codex app-server is unavailable: \(detail)"
        case .signedOut:
            "Codex is signed out. Sign in with ChatGPT to enable transcription."
        case .unsupportedAuthMode:
            "Codex is using an unsupported auth mode for transcription."
        }
    }

    var title: String {
        switch self {
        case .ready:
            "Ready"
        case .binaryMissing:
            "Codex Missing"
        case .processLaunchFailed, .serverUnavailable:
            "Server Unavailable"
        case .signedOut:
            "Signed Out"
        case .unsupportedAuthMode:
            "Unsupported Auth"
        }
    }

    var isReady: Bool {
        if case .ready = self {
            return true
        }

        return false
    }
}

@MainActor
final class CodexAuthStatusMonitor {
    private let client: any CodexAccountReading

    init(client: any CodexAccountReading) {
        self.client = client
    }

    convenience init(processManager: CodexProcessManager = CodexProcessManager()) {
        self.init(client: CodexAppServerClient(processManager: processManager))
    }

    func refresh() async -> CodexAvailability {
        do {
            let response = try await client.getAccount(refreshToken: false)

            if !response.requiresOpenAIAuth {
                return .unsupportedAuthMode
            }

            switch response.account {
            case .none:
                return .signedOut
            case .apiKey:
                return .unsupportedAuthMode
            case .chatgpt(let email, let planType):
                return .ready(email: email, planType: planType)
            }
        } catch let error as CodexAppServerClient.Error {
            switch error {
            case .binaryMissing:
                return .binaryMissing
            case .processLaunchFailed(let message):
                return .processLaunchFailed(message)
            case .transportFailure(let message):
                return .serverUnavailable(message)
            case .rpcFailure(_, let message):
                return .serverUnavailable(message)
            case .invalidResponse:
                return .serverUnavailable("Received an invalid response from Codex.")
            case .unavailableModel(let model):
                return .serverUnavailable("Codex model \(model) is unavailable.")
            case .unsupportedReasoningEffort(let model, let effort):
                return .serverUnavailable("Codex model \(model) does not support \(effort) reasoning.")
            case .invalidOutput:
                return .serverUnavailable("Codex returned invalid output.")
            case .turnFailed(let message):
                return .serverUnavailable(message)
            case .interrupted:
                return .serverUnavailable("Codex request was interrupted.")
            case .timedOut:
                return .serverUnavailable("Codex request timed out.")
            }
        } catch {
            return .serverUnavailable(error.localizedDescription)
        }
    }
}
