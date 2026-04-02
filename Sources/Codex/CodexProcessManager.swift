import Foundation

protocol CodexLineTransport: AnyObject {
    var onLine: (@Sendable (String) -> Void)? { get set }
    func start() throws
    func write(line: String) throws
}

final class CodexProcessManager: @unchecked Sendable {
    enum Error: Swift.Error, Equatable {
        case binaryMissing
        case launchFailed(String)
    }

    private let binaryLocator: CodexBinaryLocator

    init(binaryLocator: CodexBinaryLocator = CodexBinaryLocator()) {
        self.binaryLocator = binaryLocator
    }

    func makeTransport() throws -> any CodexLineTransport {
        guard let executableURL = binaryLocator.locate() else {
            throw Error.binaryMissing
        }

        return CodexProcessTransport(executableURL: executableURL)
    }
}

private final class CodexProcessTransport: CodexLineTransport, @unchecked Sendable {
    var onLine: (@Sendable (String) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let executableURL: URL
    private var readTask: Task<Void, Never>?

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func start() throws {
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CodexProcessManager.Error.launchFailed(error.localizedDescription)
        }

        readTask = Task {
            do {
                for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                    onLine?(line)
                }
            } catch {}
        }
    }

    func write(line: String) throws {
        let lineData = Data((line + "\n").utf8)
        try stdinPipe.fileHandleForWriting.write(contentsOf: lineData)
    }

    deinit {
        readTask?.cancel()

        if process.isRunning {
            process.terminate()
        }
    }
}
