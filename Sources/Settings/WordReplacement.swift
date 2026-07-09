import Foundation

struct WordReplacement: Codable, Equatable, Identifiable {
    var id: UUID
    var trigger: String
    var replacement: String
}
