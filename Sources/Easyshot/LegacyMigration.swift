import Foundation

/// One-time carry-over from the app's former name, Shotglass: settings and the capture history folder.
/// Runs before anything reads preferences; afterwards it costs one defaults lookup per launch.
enum LegacyMigration {
    static let doneKey = "migratedFromShotglass"
    static func run() {
        #if !APP_STORE
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey),let id = Bundle.main.bundleIdentifier else { return }
        defaults.set(true,forKey: doneKey)
        if let old = defaults.persistentDomain(forName: id.replacingOccurrences(of: "easyshot",with: "shotglass")) {
            for (key,value) in old where defaults.object(forKey: key) == nil { defaults.set(value,forKey: key) }
        }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0]
        let old = base.appendingPathComponent("Shotglass",isDirectory: true),new = base.appendingPathComponent("Easyshot",isDirectory: true)
        guard fm.fileExists(atPath: old.path),!fm.fileExists(atPath: new.path),(try? fm.moveItem(at: old,to: new)) != nil else { return }
        // History stores absolute paths; captures kept inside the moved folder need the new prefix.
        let history = new.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: history),var clips = try? JSONDecoder().decode([Clip].self,from: data) else { return }
        let prefix = old.path.hasSuffix("/") ? old.path : old.path+"/"
        for i in clips.indices where clips[i].path.hasPrefix(prefix) { clips[i].path = new.path+"/"+clips[i].path.dropFirst(prefix.count) }
        try? JSONEncoder().encode(clips).write(to: history,options: .atomic)
        #endif
    }
}
