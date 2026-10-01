import AVKit
import AppKit
import SwiftUI

struct PlayerView: View {
    let player: AVPlayer
    var resumeAt: Double = 0
    var nextEpisode: PlaybackContext? = nil
    var onNextEpisode: (PlaybackContext) -> Void = { _ in }
    var onLoadingState: (PlaybackLoadingState?) -> Void = { _ in }
    var onEnded: () -> Void = {}
    var onProgress: (Double, Double) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("KINO STREAM", systemImage: "play.fill")
                    .font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(KinoPalette.accent)
                Spacer()
                if let nextEpisode {
                    Button("Следующая серия") { onNextEpisode(nextEpisode) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(KinoPalette.accent)
                }
                Button("Готово") { dismiss() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(KinoPalette.muted)
            }
            .padding(.horizontal, 17).frame(height: 42)
            NativePlayerView(player: player, onProgress: onProgress, onLoadingState: onLoadingState, onEnded: {
                savePlaybackPosition()
                onEnded()
            })
                .background(.black)
                .onAppear {
                    guard resumeAt > 0 else { player.play(); return }
                    player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                        if finished { player.play() }
                    }
                }
                .onDisappear {
                    player.pause()
                    savePlaybackPosition()
                }
        }
        .background(.black)
    }

    private func savePlaybackPosition() {
        let position = player.currentTime().seconds
        guard let duration = player.currentItem?.duration.seconds,
              position.isFinite, duration.isFinite, duration > 0 else { return }
        onProgress(position, duration)
    }
}

private struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    let onProgress: (Double, Double) -> Void
    let onLoadingState: (PlaybackLoadingState?) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onLoadingState: onLoadingState, onEnded: onEnded)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        context.coordinator.observe(player)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
        context.coordinator.onLoadingState = onLoadingState
        context.coordinator.onEnded = onEnded
        context.coordinator.onProgress = onProgress
        context.coordinator.observe(player)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator: NSObject {
        var onProgress: (Double, Double) -> Void
        private weak var observedPlayer: AVPlayer?
        var onLoadingState: (PlaybackLoadingState?) -> Void
        private var itemObservation: NSKeyValueObservation?
        private var controlObservation: NSKeyValueObservation?
        var onEnded: () -> Void
        private var endObserver: NSObjectProtocol?
        private var observer: Any?

        init(onProgress: @escaping (Double, Double) -> Void, onLoadingState: @escaping (PlaybackLoadingState?) -> Void, onEnded: @escaping () -> Void) {
            self.onLoadingState = onLoadingState
            self.onEnded = onEnded
            self.onProgress = onProgress
        }

        func observe(_ player: AVPlayer) {
            guard observedPlayer !== player else { return }
            stopObserving()
            observedPlayer = player
            itemObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.reportState() }
            }
            controlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.reportState() }
            }
            if let item = player.currentItem {
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    self?.onEnded()
                }
            }
            observer = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 5, preferredTimescale: 600),
                queue: .main
            ) { [weak self, weak player] time in
                guard let self, let duration = player?.currentItem?.duration.seconds,
                      time.seconds.isFinite, duration.isFinite, duration > 0 else { return }
                self.onProgress(time.seconds, duration)
            }
        }

        private func reportState() {
            guard let player = observedPlayer else { return }
            if player.currentItem?.status == .failed {
                onLoadingState(.failed("Не удалось воспроизвести файл. Возможно, раздача недоступна или формат не поддерживается встроенным плеером. Повторите запуск, выберите другую раздачу или VLC в настройках."))
            } else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                onLoadingState(.buffering)
            } else if player.timeControlStatus == .playing || player.currentItem?.status == .readyToPlay {
                onLoadingState(nil)
            }
        }

        func stopObserving() {
            itemObservation?.invalidate()
            controlObservation?.invalidate()
            itemObservation = nil
            controlObservation = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
            if let observer, let observedPlayer {
                observedPlayer.removeTimeObserver(observer)
            }
            observer = nil
            observedPlayer = nil
        }
    }
}
