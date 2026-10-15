import Foundation

public enum CaptureKeyAction: Equatable {
    case mode(CaptureMode), drawNew, resetArea, upload, library, settings
    /// Keys with a fixed meaning. The configurable upload key may not shadow them.
    public static let reservedKeys: Set<String> = ["1","2","3","4","5","a","f","s","w","v","r","d","n","x"]
    public static let defaultUploadKey = "u"
    /// Returns a usable single-character upload key, or the default when `key` is empty or reserved.
    public static func sanitizedUploadKey(_ key: String) -> String {
        guard let first = key.lowercased().first, first.isLetter || first.isNumber, !reservedKeys.contains(String(first)) else { return defaultUploadKey }
        return String(first)
    }
    /// Only the focused capture UI handles these keys. No system-wide registration.
    public static func resolve(_ key: String,command: Bool = false,otherModifier: Bool = false,uploadKey: String = defaultUploadKey) -> Self? {
        guard !otherModifier else { return nil }
        if command {
            switch key.lowercased() { case "l": return .library; case ",": return .settings; default: return nil }
        }
        if let mode = CaptureMode.toolbarOrder.first(where: { $0.key == key }) { return .mode(mode) }
        switch key.lowercased() {
        case "a": return .mode(.area)
        case "f", "s": return .mode(.fullscreen)
        case "w": return .mode(.window)
        case "v": return .mode(.activeWindow)
        case "r": return .mode(.lastRegion)
        case "d", "n": return .drawNew
        case "x": return .resetArea
        case sanitizedUploadKey(uploadKey): return .upload
        default: return nil
        }
    }
}

/// Persist the selected mode independently of the process lifetime and region geometry.
public struct CaptureSelection: Codable, Equatable {
    public var mode: CaptureMode
    public var drawNew: Bool
    public init(mode: CaptureMode = .area,drawNew: Bool = false) {
        self.mode = mode; self.drawNew = mode == .area && drawNew
    }
}

public struct SessionActivity: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let selection = Self(rawValue: 1 << 0)
    public static let processing = Self(rawValue: 1 << 1)
    public static let recording = Self(rawValue: 1 << 2)
    public static let scrolling = Self(rawValue: 1 << 3)
    public static let preview = Self(rawValue: 1 << 4)
    public static let toolWindow = Self(rawValue: 1 << 5)
    public var shouldExit: Bool { isEmpty }
}

/// Each replacement invalidates earlier dismissal timers and animation completions.
public struct QuickPreviewLifetime {
    public static let visibleSeconds: Double = 3
    public static let slideInSeconds: Double = 0.18
    public static let slideOutSeconds: Double = 0.14
    public private(set) var generation: UInt64 = 0
    public private(set) var isActive = false
    public init() {}
    @discardableResult public mutating func replace() -> UInt64 {
        generation &+= 1; isActive = true; return generation
    }
    public func isCurrent(_ token: UInt64) -> Bool { isActive && token == generation }
    @discardableResult public mutating func dismiss(_ token: UInt64) -> Bool {
        guard isCurrent(token) else { return false }
        isActive = false; return true
    }
    public mutating func invalidate() { generation &+= 1; isActive = false }
}
