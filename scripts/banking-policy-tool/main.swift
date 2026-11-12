// Ed25519 + version helper for scripts/banking-policy.sh (CryptoKit, no
// dependencies). Built by banking-policy.sh together with
// GiroCrabApp/Sources/GiroCrabUI/BankingVersion.swift:
//
//   banking-policy-tool keygen  <account>
//   banking-policy-tool pubkey  <account>
//   banking-policy-tool sign    <account> <file.json> <file.json.sig>
//   banking-policy-tool verify  <base64-key[,key…]> <file.json> <file.json.sig>
//   banking-policy-tool validkeys <base64-key> …     (prints the ones that are Ed25519 keys)
//   banking-policy-tool compare <a> <b>               (-1, 0, 1 like Sparkle)
//
// The private key lives in the login keychain of the release Mac (generic
// password, service "GiroCrab Banking Policy", the given account) – never in
// the repo, CI or GitHub secrets. For tests, BANKING_POLICY_KEY_FILE=<path>
// stores a throwaway key in that file instead of the keychain, or
// BANKING_POLICY_KEY_DIR=<dir> one file per account (<dir>/<account>.key).
import CryptoKit
import Foundation
import Security

let service = "GiroCrab Banking Policy"

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("banking-policy-tool: " + message + "\n").utf8))
    exit(code)
}

func keyFile(_ account: String) -> String? {
    let env = ProcessInfo.processInfo.environment
    if let dir = env["BANKING_POLICY_KEY_DIR"], !dir.isEmpty { return dir + "/" + account + ".key" }
    return env["BANKING_POLICY_KEY_FILE"].flatMap { $0.isEmpty ? nil : $0 }
}

func loadPrivateKey(_ account: String) -> Curve25519.Signing.PrivateKey {
    let keyFile = keyFile(account)
    var raw: Data?
    if let keyFile {
        raw = (try? String(contentsOfFile: keyFile, encoding: .utf8)).flatMap {
            Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    } else {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            raw = Data(base64Encoded: String(decoding: d, as: UTF8.self))
        }
    }
    guard let raw, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("no policy key for account '\(account)'" + (keyFile.map { " in \($0)" } ?? " in the keychain"))
    }
    return key
}

func storePrivateKey(_ key: Curve25519.Signing.PrivateKey, account: String) {
    let b64 = key.rawRepresentation.base64EncodedString()
    let keyFile = keyFile(account)
    if let keyFile {
        guard !FileManager.default.fileExists(atPath: keyFile) else { fail("\(keyFile) exists – not overwriting a key") }
        FileManager.default.createFile(atPath: keyFile, contents: Data(b64.utf8), attributes: [.posixPermissions: 0o600])
        return
    }
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    guard SecItemCopyMatching(q as CFDictionary, nil) == errSecItemNotFound else {
        fail("account '\(account)' already has a key – choose a new account name (never overwrite a key)")
    }
    var add = q
    add[kSecValueData as String] = Data(b64.utf8)
    add[kSecAttrLabel as String] = "GiroCrab Banking Policy (\(account))"
    add[kSecAttrSynchronizable as String] = false
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { fail("keychain error \(status)") }
}

func read(_ path: String) -> Data {
    guard let d = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return d
}

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first, args.count) {
case ("keygen", 2):
    let key = Curve25519.Signing.PrivateKey()
    storePrivateKey(key, account: args[1])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("pubkey", 2):
    print(loadPrivateKey(args[1]).publicKey.rawRepresentation.base64EncodedString())
case ("sign", 4):
    let key = loadPrivateKey(args[1])
    let json = read(args[2])
    let sig = try key.signature(for: json)
    // Self-check before anything is published.
    guard key.publicKey.isValidSignature(sig, for: json) else { fail("signature self-check failed") }
    guard FileManager.default.createFile(atPath: args[3], contents: sig) else { fail("cannot write \(args[3])") }
case ("verify", 4):
    let keys = args[1].split(separator: ",").compactMap { Data(base64Encoded: String($0)) }
        .compactMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    guard !keys.isEmpty else { fail("no valid public key given", code: 2) }
    let json = read(args[2]), sig = read(args[3])
    guard keys.contains(where: { $0.isValidSignature(sig, for: json) }) else { fail("INVALID signature for \(args[2])") }
    print("ok")
case ("validkeys", _):
    for k in args.dropFirst() {
        if let d = Data(base64Encoded: k), (try? Curve25519.Signing.PublicKey(rawRepresentation: d)) != nil { print(k) }
    }
case ("compare", 3):
    switch BankingVersion.compare(args[1], args[2]) {
    case .orderedAscending: print("-1")
    case .orderedSame: print("0")
    case .orderedDescending: print("1")
    }
default:
    fail("usage: keygen <account> | pubkey <account> | sign <account> <json> <sig> | verify <keys> <json> <sig> | validkeys <key…> | compare <a> <b>", code: 2)
}
