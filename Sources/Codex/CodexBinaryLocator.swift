import Foundation

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

    func locate() -> URL? {
        let candidatePaths = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
            "\(NSHomeDirectory())/bin/codex",
        ]

        for path in candidatePaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        if let pathValue = processInfo.environment["PATH"] {
            for directory in pathValue.split(separator: ":") {
                let path = String(directory) + "/codex"
                if fileManager.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }

        return nil
    }
}
