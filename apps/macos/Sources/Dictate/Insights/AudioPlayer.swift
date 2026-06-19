import AVFoundation
import Combine

/// Plays a saved dictation WAV for the History detail. Simple play/pause + progress; one at a time.
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var progress: Double = 0   // 0…1

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ url: URL) {
        if isPlaying { pause(); return }
        if player == nil || player?.url != url {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.delegate = self
        }
        guard player != nil else { return }
        player?.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate(); timer = nil
    }

    func stop() {
        player?.stop(); player = nil
        isPlaying = false; progress = 0
        timer?.invalidate(); timer = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.progress = p.duration > 0 ? p.currentTime / p.duration : 0
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false; progress = 0
        timer?.invalidate(); timer = nil
    }

    deinit { timer?.invalidate() }
}
