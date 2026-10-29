import Foundation

struct CodexExecutable {
    let url: URL
    let environment: [String: String]
}

final class CodexBinaryLocator {
    private let fileManager: FileManager
    private let processInfo: ProcessInfo

    init(
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo
    ) {
        self.fileManager = fileManager
        self.processInfo = processInfo
    }

    func locate() -> CodexExecutable? {
        // Apps launched from Finder get a minimal PATH, so npm-installed codex
        // (`#!/usr/bin/env node`) can't find node. Use the login shell's PATH.
        let searchPath = LoginShellPath.value ?? processInfo.environment["PATH"] ?? ""
        let candidatePaths = searchPath.split(separator: ":").map { "\($0)/codex" } + [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
            "\(NSHomeDirectory())/bin/codex",
        ]

        guard let path = candidatePaths.first(where: fileManager.isExecutableFile(atPath:)) else {
            return nil
        }

        var environment = processInfo.environment
        environment["PATH"] = searchPath
        return CodexExecutable(url: URL(fileURLWithPath: path), environment: environment)
    }
}

private enum LoginShellPath {
    static let value: String? = resolve()

    private static let marker = "__VISKA_PATH__"

    private static func resolve() -> String? {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        guard exited.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return nil
        }

        let output = String(decoding: stdoutPipe.fileHandleForReading.availableData, as: UTF8.self)
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return parts[1]
    }
}
