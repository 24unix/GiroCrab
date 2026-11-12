// Release integrity check (docs/release-integrity.md). Needs only PUBLIC keys,
// so it runs in CI without secrets – also in forks, against their own releases.
//
//   release-integrity --repo owner/name [--base URL] [--state FILE] [--report FILE]
//
// Checks
//   * appcast.xml (…/releases/latest/download): Sparkle feed signature against
//     scripts/sparkle-public-ed-key.txt (or, during a key rotation, the previous
//     key in scripts/sparkle-previous-public-ed-key.txt); every item points to a
//     release asset of this repository whose size and EdDSA signature match.
//   * banking-policy.json (+ .sig), published at a fixed address
//     (raw.githubusercontent.com/<repo>/main/policy): reachable, signature
//     against BankingPolicy.publicKeys, `sequence` never lower than the last run's.
// A part is skipped while its key is not configured (placeholder).
// Exit 0 = all fine, 1 = findings (written to --report), 2 = usage.
import CryptoKit
import Foundation

// MARK: - Arguments

var repo = ProcessInfo.processInfo.environment["GITHUB_REPOSITORY"] ?? "GiroCrab/GiroCrab"
var base: String?
var statePath: String?
var reportPath: String?
var root = FileManager.default.currentDirectoryPath
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--repo": repo = it.next() ?? repo
    case "--base": base = it.next()
    case "--state": statePath = it.next()
    case "--report": reportPath = it.next()
    case "--root": root = it.next() ?? root
    default:
        FileHandle.standardError.write(Data("usage: release-integrity --repo owner/name [--base URL] [--state FILE] [--report FILE] [--root DIR]\n".utf8))
        exit(2)
    }
}
let latestBase = base ?? "https://github.com/\(repo)/releases/latest/download"
let policyBase = base ?? "https://raw.githubusercontent.com/\(repo)/main/policy"
let assetPrefix = base.map { $0 + "/" } ?? "https://github.com/\(repo)/releases/download/"

var findings: [String] = []
var notes: [String] = []
func finding(_ s: String) { findings.append(s); print("FINDING: " + s) }
func note(_ s: String) { notes.append(s); print("note: " + s) }

// MARK: - Helpers

func keys(fromBase64 list: [String]) -> [Curve25519.Signing.PublicKey] {
    list.compactMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .compactMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
}

func readText(_ rel: String) -> String? {
    try? String(contentsOfFile: (root as NSString).appendingPathComponent(rel), encoding: .utf8)
}

enum Fetch { case ok(Data), notFound, failed(String) }

func fetch(_ urlString: String) -> Fetch {
    if urlString.hasPrefix("/") || urlString.hasPrefix("file://") {
        let path = urlString.hasPrefix("file://") ? String(urlString.dropFirst(7)) : urlString
        guard FileManager.default.fileExists(atPath: path) else { return .notFound }
        return (try? Data(contentsOf: URL(fileURLWithPath: path))).map(Fetch.ok) ?? .failed("unreadable")
    }
    guard let url = URL(string: urlString) else { return .failed("bad URL") }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
    request.setValue("GiroCrab-release-integrity", forHTTPHeaderField: "User-Agent")
    let sem = DispatchSemaphore(value: 0)
    var result = Fetch.failed("no response")
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error { result = .failed(error.localizedDescription) }
        else if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { result = .notFound }
            else if http.statusCode == 200, let data { result = .ok(data) }
            else { result = .failed("HTTP \(http.statusCode)") }
        }
        sem.signal()
    }.resume()
    sem.wait()
    return result
}

// MARK: - Sparkle appcast

/// Sparkle 2 signs the first `length` bytes of the feed and appends
/// `<!-- sparkle-signatures: edSignature: … length: … -->`.
func verifyFeed(_ data: Data, keys: [Curve25519.Signing.PublicKey]) -> String? {
    let text = String(decoding: data, as: UTF8.self)
    guard let r = text.range(of: "<!-- sparkle-signatures:") else { return "appcast.xml has no embedded signature" }
    let tail = String(text[r.upperBound...])
    func field(_ name: String) -> String? {
        tail.components(separatedBy: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + ":") }
            .map { $0.trimmingCharacters(in: .whitespaces).dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces) }
    }
    guard let sigText = field("edSignature"), let sig = Data(base64Encoded: sigText),
          let len = field("length").flatMap(Int.init), len <= data.count else {
        return "appcast.xml signature block is malformed"
    }
    let signed = data.prefix(len)
    guard keys.contains(where: { $0.isValidSignature(sig, for: signed) }) else {
        return "appcast.xml signature does NOT verify with the Sparkle public key(s) in the repository"
    }
    // Nothing but whitespace may follow the signature block.
    return nil
}

struct Item { var version = ""; var channel = "stable"; var url = ""; var length = 0; var signature = "" }

final class FeedParser: NSObject, XMLParserDelegate {
    var items: [Item] = []
    private var current: Item?
    private var text = ""
    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
        text = ""
        if e == "item" { current = Item() }
        if e == "enclosure", current != nil {
            current?.url = a["url"] ?? ""
            current?.length = Int(a["length"] ?? "") ?? -1
            current?.signature = a["sparkle:edSignature"] ?? ""
            if let v = a["sparkle:version"] { current?.version = v }
        }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch q ?? e {
        case "sparkle:version": current?.version = t
        case "sparkle:channel": current?.channel = t
        case "item": if let c = current { items.append(c) }; current = nil
        default: break
        }
    }
}

/// Remembered between runs (Actions cache). A file that was never published
/// (no Sparkle release yet, policy not activated) is only a note; once seen, a
/// 404 is a finding.
struct State: Codable {
    var policySequence: UInt64?
    var appcastSeen: Bool?
    var policySeen: Bool?
}
var state = State()
if let statePath, let d = FileManager.default.contents(atPath: statePath),
   let s = try? JSONDecoder().decode(State.self, from: d) { state = s }

let sparkleKeys = keys(fromBase64: [readText("scripts/sparkle-public-ed-key.txt"),
                                    readText("scripts/sparkle-previous-public-ed-key.txt")].compactMap { $0 })
if sparkleKeys.isEmpty {
    note("Sparkle: no public key in scripts/sparkle-public-ed-key.txt – appcast check skipped")
} else {
    switch fetch(latestBase + "/appcast.xml") {
    case .notFound:
        if state.appcastSeen == true {
            finding("appcast.xml is not reachable any more at \(latestBase)/appcast.xml (404) – in-app updates stopped")
        } else {
            note("appcast.xml not published yet (no release with in-app updates so far)")
        }
    case .failed(let why): finding("appcast.xml could not be downloaded: \(why)")
    case .ok(let feed):
        state.appcastSeen = true
        if let problem = verifyFeed(feed, keys: sparkleKeys) {
            finding(problem)
        } else {
            print("ok: appcast.xml signature")
        }
        let parser = FeedParser()
        let xml = XMLParser(data: feed)
        xml.delegate = parser
        if !xml.parse() { finding("appcast.xml is not valid XML") }
        if parser.items.isEmpty { finding("appcast.xml has no items") }
        var seenChannels = Set<String>()
        for item in parser.items {
            let label = "\(item.channel) \(item.version)"
            if !seenChannels.insert(item.channel).inserted { finding("\(label): more than one item for channel \(item.channel)") }
            guard item.url.hasPrefix(assetPrefix) else {
                finding("\(label): enclosure points outside this repository's releases: \(item.url)")
                continue
            }
            switch fetch(item.url) {
            case .notFound: finding("\(label): release asset does not exist: \(item.url)")
            case .failed(let why): finding("\(label): release asset could not be downloaded (\(why)): \(item.url)")
            case .ok(let archive):
                if archive.count != item.length {
                    finding("\(label): size \(archive.count) differs from the appcast (\(item.length))")
                }
                if let sig = Data(base64Encoded: item.signature),
                   sparkleKeys.contains(where: { $0.isValidSignature(sig, for: archive) }) {
                    print("ok: \(label) \(item.url)")
                } else {
                    finding("\(label): EdDSA signature of the release asset does NOT verify: \(item.url)")
                }
            }
        }
    }
}

// MARK: - Banking policy

func policyKeys() -> [Curve25519.Signing.PublicKey] {
    guard let swift = readText("GiroCrabApp/Sources/GiroCrabUI/BankingPolicy.swift"),
          let start = swift.range(of: "publicKeys: [String] = [") else { return [] }
    let rest = swift[start.upperBound...]
    let block = rest[..<(rest.range(of: "]")?.lowerBound ?? rest.endIndex)]
    let quoted = block.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
    return keys(fromBase64: quoted)
}

let pKeys = policyKeys()
if pKeys.isEmpty {
    note("Banking policy: no public key in BankingPolicy.publicKeys (placeholder or not present) – check skipped")
} else {
    switch (fetch(policyBase + "/banking-policy.json"), fetch(policyBase + "/banking-policy.json.sig")) {
    case (.ok(let json), .ok(let sig)):
        state.policySeen = true
        if pKeys.contains(where: { $0.isValidSignature(sig, for: json) }) {
            print("ok: banking-policy.json signature")
            struct Doc: Decodable { var schema: Int; var sequence: UInt64 }
            if let doc = try? JSONDecoder().decode(Doc.self, from: json) {
                if let last = state.policySequence, doc.sequence < last {
                    finding("banking-policy.json sequence went DOWN: \(doc.sequence) < \(last) (last run)")
                } else {
                    print("ok: banking-policy.json sequence \(doc.sequence)")
                    state.policySequence = max(doc.sequence, state.policySequence ?? 0)
                }
            } else {
                finding("banking-policy.json is signed but cannot be parsed")
            }
        } else {
            finding("banking-policy.json signature does NOT verify with BankingPolicy.publicKeys")
        }
    case (.notFound, .notFound) where state.policySeen != true:
        note("banking-policy.json not published yet (policy/ not committed to main yet)")
    case (.notFound, _), (_, .notFound):
        finding("banking-policy.json or .sig is not reachable at \(policyBase) (404) – apps cannot update or lift a block")
    case (.failed(let why), _), (_, .failed(let why)):
        finding("banking-policy.json could not be downloaded: \(why)")
    }
}

if let statePath {
    try? FileManager.default.createDirectory(atPath: (statePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? JSONEncoder().encode(state).write(to: URL(fileURLWithPath: statePath))
}

// MARK: - Report

if let reportPath {
    var md = "Die Prüfung der Release-Integrität hat Abweichungen gefunden (\(ISO8601DateFormatter().string(from: Date()))):\n\n"
    md += findings.map { "- \($0)" }.joined(separator: "\n")
    if !notes.isEmpty { md += "\n\nHinweise:\n\n" + notes.map { "- \($0)" }.joined(separator: "\n") }
    md += "\n\nVorgehen: docs/release-integrity.md"
    try? md.write(toFile: reportPath, atomically: true, encoding: .utf8)
}
print(findings.isEmpty ? "==> all checks passed" : "==> \(findings.count) finding(s)")
exit(findings.isEmpty ? 0 : 1)
