import AppKit

final class SoundPlayer {
    private var layoutSwitchSound: NSSound?
    private var possibleTypoSound: NSSound?
    private let playbackQueue = DispatchQueue(label: "com.local.KeyboardSwitcher.soundPlayback", qos: .utility)

    init() {
        if let url = Bundle.main.url(forResource: "switch_typewriter_shift", withExtension: "wav") {
            layoutSwitchSound = NSSound(contentsOf: url, byReference: false)
        }
        if let url = Bundle.main.url(forResource: "switch_smart_flip", withExtension: "wav") {
            possibleTypoSound = NSSound(contentsOf: url, byReference: false)
        }
    }

    func playLayoutSwitch(volume: Double = 0.75) {
        play(layoutSwitchSound, volume: volume)
    }

    func playPossibleTypo(volume: Double = 0.45) {
        play(possibleTypoSound, volume: volume)
    }

    private func play(_ sound: NSSound?, volume: Double) {
        guard let sound else { return }
        let clampedVolume = Float(max(0, min(volume, 1)))

        playbackQueue.async {
            if sound.isPlaying {
                sound.stop()
            }
            sound.volume = clampedVolume
            sound.currentTime = 0
            sound.play()
        }
    }
}
