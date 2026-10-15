import Foundation
import EasyshotCore

extension ClipStore {
    /// Drops history entries older than the retention setting when history loads. Only copies in the
    /// internal history folder are deleted from disk; files in the user's folder always stay.
    func applyRetention(_ policy: HistoryRetention = Preferences.shared.historyRetention,now: Date = Date()) {
        guard policy != .forever else { return }
        let internalFolder = support.appendingPathComponent("Captures",isDirectory: true).path
        let expired = clips.filter { policy.isExpired($0.date,now: now) }
        guard !expired.isEmpty else { return }
        for clip in expired where HistoryRetention.mayDeleteFile(clip.path,internalFolder: internalFolder) {
            for url in [clip.url,CursorTrack.sidecarURL(for: clip.url),CursorTrack.planURL(for: clip.url)] { try? FileManager.default.removeItem(at: url) }
        }
        let ids = Set(expired.map(\.id))
        clips.removeAll { ids.contains($0.id) }
        persist()
    }
}
