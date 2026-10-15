import Foundation

/// Record & Share preferences, computed over the shared defaults store.
extension Preferences {
    private func put(_ value: Any,_ key: String) { objectWillChange.send(); defaults.set(value,forKey: key) }
    /// Copy the share link as soon as the server creates it, while recording starts.
    var shareCopyLinkAtStart: Bool { get { defaults.object(forKey: "shareCopyLinkAtStart") as? Bool ?? true } set { put(newValue,"shareCopyLinkAtStart") } }
    /// Transcribe the microphone on device after a shared recording and upload WebVTT captions.
    var shareTranscribe: Bool { get { defaults.object(forKey: "shareTranscribe") as? Bool ?? true } set { put(newValue,"shareTranscribe") } }
}
