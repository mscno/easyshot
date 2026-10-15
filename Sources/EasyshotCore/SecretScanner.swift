import Foundation

/// Finds credentials and personal data in recognized text so they can be redacted before sharing.
/// Pure string logic: the app supplies OCR lines and maps match ranges back to image boxes.
public struct SecretScanner: Sendable {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case apiKey, jwt, privateKey, highEntropy, email, ipv4, ipv6, creditCard, password, uuid, gitSHA
        public var title: String {
            switch self {
            case .apiKey: "API key"; case .jwt: "JWT"; case .privateKey: "Private key"; case .highEntropy: "Token"
            case .email: "Email"; case .ipv4, .ipv6: "IP address"; case .creditCard: "Card number"
            case .password: "Password"; case .uuid: "UUID"; case .gitSHA: "Git SHA"
            }
        }
    }
    public struct Match: Equatable, Sendable {
        public var kind: Kind
        public var range: Range<String.Index>
        public var text: String
    }
    /// UUIDs and git SHAs are usually harmless identifiers; flag them only on request.
    public var includeUUIDs: Bool
    public var includeGitSHAs: Bool
    public init(includeUUIDs: Bool = false, includeGitSHAs: Bool = false) { self.includeUUIDs = includeUUIDs; self.includeGitSHAs = includeGitSHAs }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    // Ordered by specificity: earlier kinds claim their characters first.
    private static let patterns: [(Kind, NSRegularExpression)] = [
        (.privateKey, regex(#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#)),
        (.jwt, regex(#"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#)),
        (.apiKey, regex(#"\b(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|xox[abposr]-[A-Za-z0-9-]{10,}|A(?:KIA|SIA)[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|[sr]k_(?:live|test)_[0-9A-Za-z]{16,}|whsec_[0-9A-Za-z]{20,}|glpat-[0-9A-Za-z_-]{20}|npm_[A-Za-z0-9]{36}|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,})"#)),
        (.password, regex(#"(?i)(?<![a-z])(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key)(?![a-z])\s*[:=]\s*["']?([^\s"',;]{4,})"#)),
        (.email, regex(#"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#)),
        (.uuid, regex(#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#)),
        (.ipv6, regex(#"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{1,4}:){2,7}(?::|[0-9A-Fa-f]{1,4})(?![0-9A-Fa-f:])|(?<![0-9A-Za-z:])::(?:[0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{1,4}\b"#)),
        (.ipv4, regex(#"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#)),
        (.creditCard, regex(#"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#)),
        (.gitSHA, regex(#"\b[0-9a-f]{40}\b|\b[0-9a-f]{7,12}\b"#)),
        (.highEntropy, regex(#"[A-Za-z0-9+/_-]{24,}={0,2}"#)),
    ]

    public func scan(_ text: String) -> [Match] {
        var matches: [Match] = []
        var claimed = IndexSet()
        let ns = text as NSString
        for (kind, pattern) in Self.patterns {
            for result in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                // A `password=value` match redacts only the value.
                var r = kind == .password && result.range(at: 1).location != NSNotFound ? result.range(at: 1) : result.range
                if kind == .creditCard || kind == .highEntropy { r = trimmed(r, ns) }
                guard r.length > 0, !claimed.intersects(integersIn: r.location..<r.location+r.length) else { continue }
                let value = ns.substring(with: r)
                guard accept(kind, value) else {
                    // Identifiers that are deliberately ignored still shield their characters from the entropy rule.
                    if kind == .uuid || kind == .gitSHA { claimed.insert(integersIn: r.location..<r.location+r.length) }
                    continue
                }
                claimed.insert(integersIn: r.location..<r.location+r.length)
                if let range = Range(r, in: text) { matches.append(Match(kind: kind, range: range, text: value)) }
            }
        }
        return matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
    private func trimmed(_ r: NSRange, _ ns: NSString) -> NSRange {
        var r = r
        while r.length > 0, " -".contains(ns.substring(with: NSRange(location: NSMaxRange(r)-1, length: 1))) { r.length -= 1 }
        return r
    }
    private func accept(_ kind: Kind, _ value: String) -> Bool {
        switch kind {
        case .uuid: return includeUUIDs
        case .gitSHA:
            // Short hex runs are common (colors, hashes in logs); only flag them on request, and only if they contain a letter and a digit.
            return includeGitSHAs && value.contains(where: \.isLetter) && value.contains(where: \.isNumber)
        case .ipv4: return value.split(separator: ".").allSatisfy { Int($0).map { $0 <= 255 } ?? false } && !Self.isVersionLike(value)
        // Clock times like 12:30:45 have three groups; a full address has eight, or `::` compression.
        case .ipv6: return value.contains("::") ? value.count >= 3 : value.split(separator: ":").count >= 6
        case .creditCard: return Self.luhn(value.filter(\.isNumber))
        case .highEntropy: return Self.looksRandom(value)
        default: return true
        }
    }
    /// `1.2.3.4` style version numbers with leading zeros are not addresses.
    static func isVersionLike(_ value: String) -> Bool { value.split(separator: ".").contains { $0.count > 1 && $0.hasPrefix("0") } }
    public static func luhn(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        guard (13...19).contains(values.count) else { return false }
        var sum = 0
        for (i, d) in values.reversed().enumerated() { sum += i % 2 == 1 ? (d*2 > 9 ? d*2-9 : d*2) : d }
        return sum % 10 == 0
    }
    /// Shannon entropy in bits per character.
    public static func entropy(_ value: String) -> Double {
        var counts: [Character: Int] = [:]
        for c in value { counts[c, default: 0] += 1 }
        let n = Double(value.count)
        return counts.values.reduce(0) { $0 - Double($1)/n*log2(Double($1)/n) }
    }
    /// Long, mixed-class, high-entropy runs with digits; plain words, paths and hex identifiers do not qualify.
    static func looksRandom(_ value: String) -> Bool {
        let upper = value.contains(where: \.isUppercase), lower = value.contains(where: \.isLowercase)
        guard value.contains(where: \.isNumber), upper || lower, (upper && lower) || value.count >= 32 else { return false }
        if value.allSatisfy(\.isHexDigit) { return false }
        return entropy(value) >= 4.0
    }
}
