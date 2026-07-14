import SwiftUI

@main
struct EasyReaderApp: App {
    @State private var library = LibraryModel()
    @State private var player = PlayerModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(player)
                .task { await library.refreshContinuously() }
        }
    }
}

