import Foundation

// Kept free of other imports: scripts/banking-policy.sh compiles this file
// together with scripts/banking-policy-tool/main.swift, so the release tooling
// compares versions exactly like the app.

/// Sparkle's `SUStandardVersionComparator`, rebuilt because GiroCrabUI does not
/// link Sparkle (App Store / iOS). Test vectors come from Sparkle itself
/// (BankingPolicyTests). `0.7.2b1` < `0.7.2` < `0.7.2.20261112`.
public enum BankingVersion {
    private enum Kind { case number, string, period, separator }
    private typealias Part = (kind: Kind, text: String)

    private static func kind(_ c: Character) -> Kind {
        if c == "." { return .period }
        if c.isASCII && c.isNumber { return .number }
        if c.isWhitespace || c.isPunctuation { return .separator }
        return .string // letters, but also symbols like "+"
    }

    private static func split(_ s: String) -> [Part] {
        // Sparkle ignores everything from the first "-" on ("0.7.2-beta.1" == "0.7.2").
        let s = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var parts: [Part] = []
        for c in s {
            let k = kind(c)
            if let last = parts.last, last.kind == k, k == .number || k == .string {
                parts[parts.count - 1].text.append(c)
            } else {
                parts.append((k, String(c)))
            }
        }
        return parts
    }

    /// Number of leading `N(.N)*` parts, or nil if ".." follows them
    /// ("1..0" – Sparkle does not pad then).
    private static func numericPrefix(_ p: [Part]) -> Int? {
        var i = 0
        guard i < p.count, p[i].kind == .number else { return nil }
        i += 1
        while i + 1 < p.count, p[i].kind == .period, p[i + 1].kind == .number { i += 2 }
        if i + 1 < p.count, p[i].kind == .period, p[i + 1].kind == .period { return nil }
        return i
    }

    /// Pads the shorter numeric prefix with ".0" so that 1.0 == 1.0.0 and 1.0b1 == 1.0.0b1.
    private static func pad(_ a: inout [Part], _ b: inout [Part]) {
        guard let na = numericPrefix(a), let nb = numericPrefix(b), na != nb else { return }
        let zeros = { (n: Int) in (0..<(n / 2)).flatMap { _ in [Part(.period, "."), Part(.number, "0")] } }
        if na < nb { a.insert(contentsOf: zeros(nb - na), at: na) } else { b.insert(contentsOf: zeros(na - nb), at: nb) }
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        var pa = split(a), pb = split(b)
        pad(&pa, &pb)
        for i in 0..<min(pa.count, pb.count) {
            let (ka, sa) = pa[i], (kb, sb) = pb[i]
            if ka == kb {
                switch ka {
                case .number:
                    let na = Decimal(string: sa) ?? 0, nb = Decimal(string: sb) ?? 0
                    if na != nb { return na < nb ? .orderedAscending : .orderedDescending }
                case .string:
                    let r = sa.compare(sb)
                    if r != .orderedSame { return r }
                default:
                    continue
                }
            } else if kb == .string {
                return .orderedDescending
            } else if ka == .string {
                return .orderedAscending
            } else {
                return ka == .number ? .orderedDescending : .orderedAscending
            }
        }
        guard pa.count != pb.count else { return .orderedSame }
        // The rest of the longer one decides: its first part that is not a
        // "." – a string makes it older (1.0 > 1.0b1), anything else newer.
        let aLonger = pa.count > pb.count
        let rest = aLonger ? pa[pb.count...] : pb[pa.count...]
        guard let decisive = rest.first(where: { $0.kind != .period }) else { return .orderedSame }
        let longerIsNewer = decisive.kind != .string
        return (aLonger == longerIsNewer) ? .orderedDescending : .orderedAscending
    }
}

/// Version line for Settings and bug reports. TestFlight pins
/// `CFBundleShortVersionString` to an already reviewed version (a changed
/// marketing version triggers a new beta review, a new build number does not),
/// so the true core version and the bundle/build numbers are shown together.
public enum AppVersionDisplay {
    /// - Parameters:
    ///   - core: version of the Rust core (`coreVersion()`).
    ///   - bundleVersion: `CFBundleShortVersionString`.
    ///   - build: `CFBundleVersion`. Only a plain number counts as a build number;
    ///     macOS builds carry a version string there, which is not repeated.
    public static func text(core: String, bundleVersion: String?, build: String?) -> String {
        let bundle = bundleVersion?.trimmingCharacters(in: .whitespaces) ?? ""
        let build = build?.trimmingCharacters(in: .whitespaces) ?? ""
        let hasBuild = !build.isEmpty && build.allSatisfy { $0.isASCII && $0.isNumber }
        if bundle.isEmpty || bundle == core {
            return hasBuild ? "\(core) (Build \(build))" : core
        }
        return hasBuild ? "\(core) (TestFlight \(bundle) · Build \(build))" : "\(core) (App \(bundle))"
    }

    public static func current(core: String) -> String {
        let info = Bundle.main
        return text(
            core: core,
            bundleVersion: info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: info.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }
}
