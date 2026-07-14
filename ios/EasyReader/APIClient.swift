import Foundation

struct APIClient {
    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let base = URL(string: Settings.serverURL),
              let url = URL(string: path, relativeTo: base) else { throw APIError.invalidServer }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if !Settings.apiToken.isEmpty { request.setValue("Bearer \(Settings.apiToken)", forHTTPHeaderField: "authorization") }
        return request
    }

    func articles() async throws -> [Article] {
        let (data, response) = try await URLSession.shared.data(for: request(path: "/v1/articles"))
        try validate(response)
        return try decoder.decode([Article].self, from: data)
    }

    func add(source: ArticleInput, cleanup: Bool) async throws -> Article {
        let body = try JSONEncoder().encode(AddArticleRequest(source: source, cleanup: cleanup))
        let (data, response) = try await URLSession.shared.data(for: request(path: "/v1/articles", method: "POST", body: body))
        try validate(response)
        return try decoder.decode(Article.self, from: data)
    }

    func audioURL(for article: Article) throws -> URL {
        guard let path = article.audioURL,
              let base = URL(string: Settings.serverURL),
              let url = URL(string: path, relativeTo: base) else { throw APIError.invalidServer }
        return url
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw APIError.server }
    }
}

enum ArticleInput: Encodable {
    case url(URL)
    case text(String, title: String?)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .url(let url):
            try container.encode("url", forKey: .type)
            try container.encode(url, forKey: .url)
        case .text(let text, let title):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(title, forKey: .title)
        }
    }

    private enum CodingKeys: String, CodingKey { case type, url, text, title }
}

private struct AddArticleRequest: Encodable {
    let source: ArticleInput
    let cleanup: Bool
}

enum APIError: LocalizedError {
    case invalidServer, server
    var errorDescription: String? {
        switch self {
        case .invalidServer: "Check the server address in Settings."
        case .server: "The server couldn't complete that request."
        }
    }
}

enum Settings {
    private static let defaults = UserDefaults(suiteName: "group.com.larryhudson.EasyReader")!
    static var serverURL: String {
        get { defaults.string(forKey: "serverURL") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: "serverURL") }
    }
    static var apiToken: String {
        get { defaults.string(forKey: "apiToken") ?? "" }
        set { defaults.set(newValue, forKey: "apiToken") }
    }
}
