import Foundation

/// Server timestamps are RFC 3339 with up to nanosecond fractions; Foundation parses at most milliseconds.
public enum RFC3339 {
    public static func parse(_ text: String) -> Date? {
        let normalized = text.replacingOccurrences(of: #"\.(\d{3})\d+"#,with: ".$1",options: .regularExpression)
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        if let date = fractional.date(from: normalized) { return date }
        let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: normalized)
    }
}

public enum CloudLibrary {
    /// Newest-first items grouped under "Today", "Yesterday", a weekday for the last week, then a full date.
    public static func sections<T>(_ items: [T],date: (T) -> Date,now: Date = Date(),calendar: Calendar = .current) -> [(title: String,items: [T])] {
        var result: [(title: String,items: [T])] = []
        let today = calendar.startOfDay(for: now)
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            let title = dayTitle(day,today: today,calendar: calendar)
            if let last = result.indices.last,result[last].title == title { result[last].items.append(item) }
            else { result.append((title,[item])) }
        }
        return result
    }
    static func dayTitle(_ day: Date,today: Date,calendar: Calendar) -> String {
        let delta = calendar.dateComponents([.day],from: day,to: today).day ?? 0
        if delta == 0 { return "Today" }
        if delta == 1 { return "Yesterday" }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate(delta > 1 && delta < 7 ? "EEEE" : calendar.isDate(day,equalTo: today,toGranularity: .year) ? "EEEEMMMMd" : "yMMMMd")
        return formatter.string(from: day)
    }
    /// "Expires in 12 days", "Expires today", or "Expired".
    public static func expiryText(_ expires: Date,now: Date = Date()) -> String {
        let remaining = expires.timeIntervalSince(now)
        if remaining <= 0 { return "Expired" }
        let days = Int(remaining / 86_400)
        if days >= 1 { return "Expires in \(days) day\(days == 1 ? "" : "s")" }
        let hours = max(1,Int(remaining / 3_600))
        return hours >= 2 ? "Expires in \(hours) hours" : "Expires within the hour"
    }
}

/// Where a link is shown to the user, kept free of AppKit so it can be tested.
public enum ShareLink {
    /// Only http(s) links the server returned are ever placed on the clipboard.
    public static func validated(_ text: String) -> URL? {
        guard let url = URL(string: text),let scheme = url.scheme?.lowercased(),scheme == "https" || scheme == "http",url.host != nil else { return nil }
        return url
    }
}

/// Screenshot uploads are labelled by their decoded bytes, never by the filename: a PNG renamed
/// `.gif` is still a PNG to the secret scan and to the server.
public enum UploadImageType {
    /// The MIME type Easyshot Cloud stores for an ImageIO type identifier, or nil when the image must be re-encoded.
    public static func mime(forTypeIdentifier identifier: String) -> String? {
        ["public.png": "image/png","public.jpeg": "image/jpeg","com.compuserve.gif": "image/gif","org.webmproject.webp": "image/webp"][identifier]
    }
    /// Animations longer than this are not OCR'd frame by frame; they count as unscanned rather than clean.
    public static let maxScannedFrames = 120
}
