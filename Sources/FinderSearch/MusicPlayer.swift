import SwiftUI
import AppKit
import AVFoundation
import Combine

// HOMY: Built-in music player. Starts from the selected audio file and plays
// through the surrounding audio files, with ⌘←/⌘→ to skip.

@MainActor final class MusicPlayerModel: ObservableObject {
    @Published var queue: [Hit] = []
    @Published var index = 0
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 0.8 { didSet { applyVolume() } }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    var current: Hit? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    static func isAudio(_ hit: Hit) -> Bool {
        if hit.kind == "file" {
            let ext = hit.url.pathExtension.lowercased()
            return ["mp3", "m4a", "aac", "wav", "aiff", "flac", "alac", "ogg"].contains(ext)
        }
        return false
    }

    func play(_ hits: [Hit], start hit: Hit) {
        let audio = hits.filter(Self.isAudio)
        guard !audio.isEmpty else { return }
        queue = audio
        index = max(0, audio.firstIndex(where: { $0.path == hit.path }) ?? 0)
        startCurrent()
    }

    private func startCurrent() {
        guard let current else { return }
        stopObservers()
        let item = AVPlayerItem(url: current.url)
        let player = self.player ?? AVPlayer()
        player.replaceCurrentItem(with: item)
        player.volume = Float(volume)
        self.player = player
        duration = item.asset.duration.seconds.isFinite ? item.asset.duration.seconds : 0
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.position = time.seconds
            if self.duration <= 0, let itemDuration = player.currentItem?.duration.seconds,
                itemDuration.isFinite
            {
                self.duration = itemDuration
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.next(wrap: true) }
        }
        player.play()
        playing = true
    }

    func toggle() {
        guard let player else { return startCurrent() }
        if player.timeControlStatus == .playing {
            player.pause()
            playing = false
        } else {
            player.play()
            playing = true
        }
    }

    func next(wrap: Bool = false) {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            index += 1
            startCurrent()
        } else if wrap {
            index = 0
            startCurrent()
        } else {
            pause()
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        index = index > 0 ? index - 1 : queue.count - 1
        startCurrent()
    }

    func pause() {
        player?.pause()
        playing = false
    }

    func seek(to seconds: Double) {
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        position = seconds
    }

    private func applyVolume() {
        player?.volume = Float(volume)
    }

    private func stopObservers() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
    }

    func stop() {
        player?.pause()
        stopObservers()
        player = nil
        playing = false
    }
}

struct MusicPlayerView: View {
    @ObservedObject var player: MusicPlayerModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Group {
                    if let current = player.current {
                        FileThumbnail(hit: current, size: 64)
                    } else {
                        Image(systemName: "music.quarternote.3")
                            .font(.system(size: 34)).foregroundStyle(.secondary)
                    }
                }.frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.current?.name ?? "Nothing Playing")
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(player.current?.parent ?? "—")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(player.index + 1) of \(max(1, player.queue.count))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            Slider(
                value: Binding(
                    get: { player.position },
                    set: { player.seek(to: $0) }
                ), in: 0...max(1, player.duration)
            )
            HStack {
                Text(timeString(player.position)).font(.caption.monospacedDigit())
                Spacer()
                Text(timeString(player.duration)).font(.caption.monospacedDigit())
            }
            HStack(spacing: 20) {
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill").font(.system(size: 16))
                }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 22)).frame(width: 28)
                }
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill").font(.system(size: 16))
                }.keyboardShortcut(.rightArrow, modifiers: .command)
            }.buttonStyle(.borderless)
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                Slider(value: $player.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
            }
        }.padding(18).frame(width: 340)
            .onDisappear { player.pause() }
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

@MainActor final class MusicPlayerController: ObservableObject {
    static let shared = MusicPlayerController()
    let model = MusicPlayerModel()
    private var panel: NSPanel?

    func play(_ hits: [Hit], start: Hit? = nil) {
        let startHit = start ?? hits.first(where: MusicPlayerModel.isAudio)
        guard let startHit else { return }
        model.play(hits, start: startHit)
        show()
    }

    func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        panel.title = "Player"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: MusicPlayerView(player: model))
        panel.center()
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }
}
