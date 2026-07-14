import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let message = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        message.text = "Adding to Easy Reader…"
        message.font = .preferredFont(forTextStyle: .headline)
        message.textAlignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)
        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        Task { await addSharedURL() }
    }

    @MainActor
    private func addSharedURL() async {
        do {
            guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
                  let provider = item.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
                  let url = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL else {
                throw ShareError.missingURL
            }
            let defaults = UserDefaults(suiteName: "group.com.larryhudson.EasyReader") ?? .standard
            let configuredServer = defaults.string(forKey: "serverURL")
            guard let configuredServer, !configuredServer.isEmpty,
                  let base = URL(string: configuredServer) else { throw ShareError.missingServer }
            var request = URLRequest(url: URL(string: "/v1/articles", relativeTo: base)!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "source": ["type": "url", "url": url.absoluteString],
                "cleanup": false,
            ])
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            if let token = defaults.string(forKey: "apiToken"), !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            }
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw ShareError.server }
            message.text = "Added"
            try? await Task.sleep(for: .milliseconds(500))
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            message.text = error.localizedDescription
        }
    }
}

private enum ShareError: LocalizedError {
    case missingURL, missingServer, server
    var errorDescription: String? {
        switch self {
        case .missingURL: "This item doesn’t contain a web address."
        case .missingServer: "Open Easy Reader and set its server first."
        case .server: "The Easy Reader server couldn’t add this page."
        }
    }
}
