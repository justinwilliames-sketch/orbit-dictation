import AppKit

extension NSSound {
    /// Custom "dictation chime" — plays when recording starts AND when the
    /// transcript has been pasted into the focused text field. Same sound
    /// for both events so the user gets a consistent before/after pair.
    /// Asset is bundled at Resources/dictation-chime.mp3 (sourced from the
    /// Orion Desktop Companion ping set).
    static let dictationChime: NSSound? = {
        guard let url = Bundle.main.url(forResource: "dictation-chime", withExtension: "mp3"),
              let sound = NSSound(contentsOf: url, byReference: false) else {
            return nil
        }
        return sound
    }()

    /// System "Pop" sound — used when recording stops (after the audio is
    /// captured but before transcription completes).
    static let pop = NSSound(named: "Pop")

    /// System "Bottle" sound — soft no-op chime played when a recording
    /// contained no speech, so the user knows the trigger registered.
    static let bottle = NSSound(named: "Bottle")
}
