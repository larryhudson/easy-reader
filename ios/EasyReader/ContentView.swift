import SwiftUI

struct ContentView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerModel.self) private var player
    @State private var showingAdd = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if library.articles.isEmpty {
                    ContentUnavailableView("Your listening list is empty", systemImage: "waveform", description: Text("Add an article and it’ll appear here when it’s ready."))
                } else {
                    List(library.articles) { article in
                        ArticleRow(article: article)
                            .contentShape(Rectangle())
                            .onTapGesture { if article.status == .ready { player.load(article) } }
                    }
                    .listStyle(.plain)
                    .refreshable { await library.refresh(reportErrors: true) }
                }
            }
            .navigationTitle("Easy Reader")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Settings", systemImage: "gearshape") { showingSettings = true }.labelStyle(.iconOnly) }
                ToolbarItem(placement: .topBarTrailing) { Button("Add", systemImage: "plus") { showingAdd = true } }
            }
            .safeAreaInset(edge: .bottom) { if player.article != nil { MiniPlayer() } }
            .sheet(isPresented: $showingAdd) { AddArticleView() }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .alert("Something went wrong", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
                Button("OK") { library.errorMessage = nil }
            } message: { Text(library.errorMessage ?? "") }
            .alert("Playback failed", isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })) {
                Button("OK") { player.errorMessage = nil }
            } message: { Text(player.errorMessage ?? "") }
        }
    }
}

private struct ArticleRow: View {
    @Environment(PlayerModel.self) private var player
    let article: Article
    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: article.imageURL) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.12).overlay { Image(systemName: "text.page") } }
                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(article.displayTitle).font(.headline).lineLimit(2)
                Text([article.site, article.duration].compactMap { $0 }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                if article.status != .ready {
                    Label(article.error ?? article.statusLabel, systemImage: article.status == .failed ? "exclamationmark.circle" : "sparkles")
                        .font(.caption).foregroundStyle(article.status == .failed ? Color.red : Color.accentColor)
                } else if player.isDownloaded(article) {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Label("Tap to download", systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 5)
    }
}

private struct AddArticleView: View {
    private enum InputMode: String, CaseIterable, Identifiable {
        case link = "Link"
        case text = "Text"
        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryModel.self) private var library
    @State private var inputMode = InputMode.link
    @State private var url = ""
    @State private var pastedText = ""
    @State private var title = ""
    @State private var cleanup = false

    private var canAdd: Bool {
        switch inputMode {
        case .link: !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .text: pastedText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 100
        }
    }

    private func add() async -> Bool {
        switch inputMode {
        case .link: await library.addURL(url, cleanup: cleanup)
        case .text: await library.addText(pastedText, title: title, cleanup: cleanup)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Input", selection: $inputMode) {
                    ForEach(InputMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if inputMode == .link {
                    TextField("https://…", text: $url)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                } else {
                    Section("Optional title") {
                        TextField("Pasted text", text: $title)
                    }
                    Section("Content") {
                        TextEditor(text: $pastedText)
                            .frame(minHeight: 220)
                    }
                }

                Section {
                    Toggle("Clean up for listening with AI", isOn: $cleanup)
                } footer: {
                    Text("Makes conservative edits while preserving the author’s voice and wording.")
                }
            }
                .navigationTitle("Add article").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(library.isAdding ? "Adding…" : "Add") { Task { if await add() { dismiss() } } }.disabled(!canAdd || library.isAdding) }
                }
        }
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL = Settings.serverURL
    @State private var token = Settings.apiToken
    var body: some View {
        NavigationStack {
            Form {
                Section("Server") { TextField("https://machine.tailnet.ts.net", text: $serverURL).textInputAutocapitalization(.never).keyboardType(.URL); SecureField("API token (optional)", text: $token) }
                Section { Text("Enter the private HTTPS address exposed by Tailscale Serve on your server.") }.foregroundStyle(.secondary)
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { Settings.serverURL = serverURL; Settings.apiToken = token; dismiss() } }
        }
    }
}

private struct MiniPlayer: View {
    @Environment(PlayerModel.self) private var player
    var body: some View {
        HStack {
            VStack(alignment: .leading) { Text(player.article?.displayTitle ?? "").font(.subheadline.weight(.semibold)).lineLimit(1); Text(player.article?.author ?? player.article?.site ?? "").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }.labelStyle(.iconOnly).font(.title2)
        }.padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 18)).padding(.horizontal)
    }
}
