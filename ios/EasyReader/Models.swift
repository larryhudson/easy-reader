import Foundation

struct Article: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        case queued, rendering, extracting, cleaning, speaking, ready, failed

        var label: String {
            switch self {
            case .queued: "Waiting"
            case .rendering: "Opening page"
            case .extracting: "Extracting article"
            case .cleaning: "Preparing for listening"
            case .speaking: "Creating audio"
            case .ready: "Ready"
            case .failed: "Failed"
            }
        }
    }

    let id: String
    var sourceType: String?
    let url: URL?
    var title: String?
    var author: String?
    var site: String?
    var imageURL: URL?
    var wordCount: Int?
    var audioChunksCompleted: Int?
    var audioChunksTotal: Int?
    var status: Status
    var error: String?
    let createdAt: Date
    var updatedAt: Date
    var audioURL: String?
    var cleanupRequested: Bool?
    var cleanupCompleted: Bool?

    var displayTitle: String { title ?? url?.host() ?? "Pasted text" }
    var duration: String? {
        guard let wordCount else { return nil }
        let minutes = max(1, Int((Double(wordCount) / 190).rounded()))
        return "\(minutes) min"
    }

    var statusLabel: String {
        if status == .speaking, let completed = audioChunksCompleted, let total = audioChunksTotal {
            return "Creating audio · \(completed) of \(total)"
        }
        return status.label
    }
}
