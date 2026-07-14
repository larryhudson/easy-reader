import Foundation
import Observation

@MainActor @Observable
final class LibraryModel {
    var articles: [Article]
    var isAdding = false
    var errorMessage: String?
    private let api = APIClient()

    init() {
        articles = Self.loadCachedArticles()
    }

    func addURL(_ text: String, cleanup: Bool) async -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            errorMessage = "Paste a complete web address."
            return false
        }
        return await add(.url(url), cleanup: cleanup)
    }

    func addText(_ text: String, title: String, cleanup: Bool) async -> Bool {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count >= 100 else {
            errorMessage = "Paste at least 100 characters of text."
            return false
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return await add(.text(content, title: trimmedTitle.isEmpty ? nil : trimmedTitle), cleanup: cleanup)
    }

    private func add(_ source: ArticleInput, cleanup: Bool) async -> Bool {
        isAdding = true
        defer { isAdding = false }
        do {
            let article = try await api.add(source: source, cleanup: cleanup)
            articles.removeAll { $0.id == article.id }
            articles.insert(article, at: 0)
            cacheArticles()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refresh(reportErrors: Bool = false) async {
        do {
            articles = try await api.articles()
            cacheArticles()
        }
        catch { if reportErrors { errorMessage = error.localizedDescription } }
    }

    func refreshContinuously() async {
        while !Task.isCancelled {
            await refresh()
            let processing = articles.contains { $0.status != .ready && $0.status != .failed }
            try? await Task.sleep(for: .seconds(processing ? 2 : 15))
        }
    }

    private static var cacheURL: URL? {
        guard let root = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let directory = root.appendingPathComponent("EasyReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("articles.json")
    }

    private static func loadCachedArticles() -> [Article] {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Article].self, from: data)) ?? []
    }

    private func cacheArticles() {
        guard let cacheURL = Self.cacheURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(articles) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
