import AppKit

final class SoundPlayer {
    private var layoutSwitchSound: NSSound?

    init() {
        guard let url = Bundle.main.url(forResource: "switch_typewriter_shift", withExtension: "wav") else {
            return
        }
        layoutSwitchSound = NSSound(contentsOf: url, byReference: false)
    }

    func playLayoutSwitch() {
        guard let sound = layoutSwitchSound else { return }

        if sound.isPlaying {
            sound.stop()
        }
        sound.currentTime = 0
        sound.play()
    }
}
