import AVFoundation
import MediaPlayer
import Observation

@MainActor @Observable
final class PlayerModel {
    private(set) var article: Article?
    private(set) var isPlaying = false
    private(set) var downloadedArticleIDs: Set<String> = []
    var errorMessage: String?

    private var player: AVPlayer?
    private var playerObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?

    init() {
        downloadedArticleIDs = Self.downloadedIDs()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        configureRemoteCommands()
    }

    func load(_ article: Article) {
        loadTask?.cancel()
        self.article = article
        errorMessage = nil
        loadTask = Task {
            do {
                let localURL = try await cachedAudio(for: article)
                guard !Task.isCancelled else { return }
                preparePlayer(url: localURL)
                play()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggle() { isPlaying ? pause() : play() }

    func isDownloaded(_ article: Article) -> Bool {
        downloadedArticleIDs.contains(article.id)
    }

    func play() {
        player?.play()
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func skip(by interval: TimeInterval) {
        guard let player else { return }
        let duration = validSeconds(player.currentItem?.duration) ?? .greatestFiniteMagnitude
        let destination = min(max(0, player.currentTime().seconds + interval), duration)
        seek(to: destination)
    }

    func seek(to seconds: TimeInterval) {
        guard let player, seconds.isFinite else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    private func cachedAudio(for article: Article) async throws -> URL {
        let cache = try Self.audioDirectory()
        for fileExtension in ["m4a", "aiff"] {
            let cached = cache.appendingPathComponent("\(article.id).\(fileExtension)")
            if let size = try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                downloadedArticleIDs.insert(article.id)
                return cached
            }
        }

        if let migrated = try Self.migrateLegacyCache(for: article, to: cache) {
            downloadedArticleIDs.insert(article.id)
            return migrated
        }

        var request = URLRequest(url: try APIClient().audioURL(for: article))
        if !Settings.apiToken.isEmpty {
            request.setValue("Bearer \(Settings.apiToken)", forHTTPHeaderField: "authorization")
        }
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.server
        }
        let fileExtension = response.mimeType == "audio/aiff" ? "aiff" : "m4a"
        let destination = cache.appendingPathComponent("\(article.id).\(fileExtension)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        downloadedArticleIDs.insert(article.id)
        return destination
    }

    private static func audioDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent("EasyReader/ArticleAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return directory
    }

    private static func downloadedIDs() -> Set<String> {
        guard let directory = try? audioDirectory() else { return [] }
        migrateLegacyAudio(to: directory)
        guard
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }
        return Set(files.compactMap { file in
            guard ["m4a", "aiff"].contains(file.pathExtension),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0 else { return nil }
            return file.deletingPathExtension().lastPathComponent
        })
    }

    private static func migrateLegacyAudio(to destinationDirectory: URL) {
        let legacyDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArticleAudio", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: legacyDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        for source in files where ["m4a", "aiff"].contains(source.pathExtension) {
            guard let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { continue }
            let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try? FileManager.default.moveItem(at: source, to: destination)
        }
    }

    private static func migrateLegacyCache(for article: Article, to destinationDirectory: URL) throws -> URL? {
        let legacyDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArticleAudio", isDirectory: true)
        for fileExtension in ["m4a", "aiff"] {
            let legacy = legacyDirectory.appendingPathComponent("\(article.id).\(fileExtension)")
            guard let size = try? legacy.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { continue }
            let destination = destinationDirectory.appendingPathComponent(legacy.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: legacy, to: destination)
            return destination
        }
        return nil
    }

    private func preparePlayer(url: URL) {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer

        playerObservation = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.timeControlStatus == .playing
                self?.updateNowPlaying()
            }
        }
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                if item.status == .failed {
                    self?.isPlaying = false
                    self?.errorMessage = item.error?.localizedDescription ?? "This audio could not be played."
                } else if item.status == .readyToPlay {
                    self?.updateNowPlaying()
                }
            }
        }
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            guard self?.player != nil else { return .noSuchContent }
            Task { @MainActor in self?.play() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            guard self?.player != nil else { return .noSuchContent }
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard self?.player != nil else { return .noSuchContent }
            Task { @MainActor in self?.toggle() }
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            Task { @MainActor in self?.skip(by: -interval) }
            return self?.player == nil ? .noSuchContent : .success
        }
        commands.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            Task { @MainActor in self?.skip(by: interval) }
            return self?.player == nil ? .noSuchContent : .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent, self?.player != nil else {
                return .noSuchContent
            }
            Task { @MainActor in self?.seek(to: position.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let article, let player else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: article.displayTitle,
            MPMediaItemPropertyArtist: article.author ?? article.site ?? "Easy Reader",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let duration = validSeconds(player.currentItem?.duration) {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func validSeconds(_ time: CMTime?) -> TimeInterval? {
        guard let time else { return nil }
        let seconds = time.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
