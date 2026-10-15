import AppKit

/// Keeps the user's chosen capture directory accessible for the current process.
/// Only the Store edition needs a persistent security-scoped bookmark.
final class CaptureFolderAccess {
    private let defaults: UserDefaults
    private var activeURL: URL?
    private var scopedURLs: [String: URL] = [:]
    private var restoredHistory = false
    init(defaults: UserDefaults) { self.defaults = defaults }
    deinit {
        scopedURLs.values.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    func restore() -> URL? {
        #if APP_STORE
        restoreHistory()
        if let activeURL { return activeURL }
        guard let data = defaults.data(forKey: "captureFolderBookmark") else { return nil }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data,options: [.withSecurityScope,.withoutUI,.withoutMounting],relativeTo: nil,bookmarkDataIsStale: &stale)
            guard acquire(url) else { return nil }
            activeURL = url
            if stale {
                defaults.set(try url.bookmarkData(options: [.withSecurityScope],includingResourceValuesForKeys: nil,relativeTo: nil),forKey: "captureFolderBookmark")
            }
            return url
        } catch {
            activeURL = nil
            return nil
        }
        #else
        return nil
        #endif
    }

    func select(_ url: URL) throws {
        #if APP_STORE
        // The open panel already grants access. Resolve our persistent bookmark
        // to acquire a scope explicitly, rather than assuming the panel URL has one.
        let bookmark = try url.bookmarkData(options: [.withSecurityScope],includingResourceValuesForKeys: nil,relativeTo: nil)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark,options: [.withSecurityScope,.withoutUI,.withoutMounting],relativeTo: nil,bookmarkDataIsStale: &stale)
        guard acquire(resolved) else {
            throw ShotError.message("Could not access this folder. Choose it again in Settings.")
        }
        var history = defaults.dictionary(forKey: "captureFolderBookmarks") as? [String: Data] ?? [:]
        if let current = defaults.data(forKey: "captureFolderBookmark"),let activeURL { history[activeURL.path] = current }
        history[url.path] = bookmark
        defaults.set(history,forKey: "captureFolderBookmarks")
        defaults.set(bookmark,forKey: "captureFolderBookmark")
        activeURL = resolved
        #endif
    }
    func restoreHistory() {
        #if APP_STORE
        guard !restoredHistory else { return }
        restoredHistory = true
        let bookmarks = defaults.dictionary(forKey: "captureFolderBookmarks") as? [String: Data] ?? [:]
        for (path,data) in bookmarks where path != defaults.string(forKey: "folder") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,options: [.withSecurityScope,.withoutUI,.withoutMounting],relativeTo: nil,bookmarkDataIsStale: &stale),acquire(url) {
                if stale,let refreshed = try? url.bookmarkData(options: [.withSecurityScope],includingResourceValuesForKeys: nil,relativeTo: nil) {
                    var updated = defaults.dictionary(forKey: "captureFolderBookmarks") as? [String: Data] ?? [:]
                    updated[path] = refreshed
                    defaults.set(updated,forKey: "captureFolderBookmarks")
                }
            }
        }
        #endif
    }
    private func acquire(_ url: URL) -> Bool {
        if scopedURLs[url.path] != nil { return true }
        if url.startAccessingSecurityScopedResource() {
            scopedURLs[url.path] = url
            return true
        }
        // Files inside the app's own container need no sandbox extension.
        let container = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(container + "/")
    }
}
