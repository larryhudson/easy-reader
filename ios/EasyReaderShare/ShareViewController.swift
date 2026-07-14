import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private var sharedURL: URL?
    private let message = UILabel()
    private let cleanupSwitch = UISwitch()
    private let addButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "Add to Easy Reader"
        title.font = .preferredFont(forTextStyle: .title2)

        message.text = "Loading shared link…"
        message.font = .preferredFont(forTextStyle: .subheadline)
        message.textColor = .secondaryLabel
        message.numberOfLines = 2

        let cleanupLabel = UILabel()
        cleanupLabel.text = "Clean up for listening with AI"
        cleanupLabel.font = .preferredFont(forTextStyle: .body)
        cleanupLabel.numberOfLines = 2
        cleanupLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cleanupSwitch.isOn = false
        cleanupSwitch.accessibilityLabel = cleanupLabel.text

        let cleanupRow = UIStackView(arrangedSubviews: [cleanupLabel, cleanupSwitch])
        cleanupRow.axis = .horizontal
        cleanupRow.alignment = .center
        cleanupRow.spacing = 16

        let explanation = UILabel()
        explanation.text = "Makes conservative edits while preserving the author’s voice and wording."
        explanation.font = .preferredFont(forTextStyle: .footnote)
        explanation.textColor = .secondaryLabel
        explanation.numberOfLines = 0

        var addConfiguration = UIButton.Configuration.filled()
        addConfiguration.title = "Add"
        addButton.configuration = addConfiguration
        addButton.isEnabled = false
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [cancelButton, addButton])
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 12

        let stack = UIStackView(arrangedSubviews: [title, message, cleanupRow, explanation, buttons])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])
        Task { await loadSharedURL() }
    }

    @MainActor
    private func loadSharedURL() async {
        do {
            guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
                  let provider = item.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
                  let url = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL else {
                throw ShareError.missingURL
            }
            sharedURL = url
            message.text = url.host() ?? url.absoluteString
            addButton.isEnabled = true
        } catch {
            message.text = error.localizedDescription
        }
    }

    @objc private func addTapped() {
        Task { await addSharedURL() }
    }

    @objc private func cancelTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    @MainActor
    private func addSharedURL() async {
        guard let url = sharedURL else { return }
        addButton.isEnabled = false
        cancelButton.isEnabled = false
        cleanupSwitch.isEnabled = false
        message.text = "Adding…"
        do {
            let defaults = UserDefaults(suiteName: "group.com.larryhudson.EasyReader")!
            let configuredServer = defaults.string(forKey: "serverURL")
            guard let configuredServer, !configuredServer.isEmpty,
                  let base = URL(string: configuredServer) else { throw ShareError.missingServer }
            var request = URLRequest(url: URL(string: "/v1/articles", relativeTo: base)!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "source": ["type": "url", "url": url.absoluteString],
                "cleanup": cleanupSwitch.isOn,
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
            addButton.isEnabled = true
            cancelButton.isEnabled = true
            cleanupSwitch.isEnabled = true
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
