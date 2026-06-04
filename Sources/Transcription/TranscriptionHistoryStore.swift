import Foundation

protocol TranscriptionHistoryStoring: AnyObject {
    func load() -> [TranscriptionHistoryItem]
    func save(_ items: [TranscriptionHistoryItem])
}

final class TranscriptionHistoryStore: TranscriptionHistoryStoring {
    private let userDefaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "viska.transcriptionHistory"
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func load() -> [TranscriptionHistoryItem] {
        guard let data = userDefaults.data(forKey: key),
              let items = try? decoder.decode([TranscriptionHistoryItem].self, from: data) else {
            return []
        }

        return Array(items.prefix(10))
    }

    func save(_ items: [TranscriptionHistoryItem]) {
        guard let data = try? encoder.encode(Array(items.prefix(10))) else { return }
        userDefaults.set(data, forKey: key)
    }
}
