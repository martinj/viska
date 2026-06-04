import Foundation

struct TranscriptionHistoryItem: Codable, Equatable, Identifiable {
    let id: UUID
    let text: String
    let createdAt: Date
}
