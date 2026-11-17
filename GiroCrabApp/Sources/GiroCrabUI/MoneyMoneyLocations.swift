import Foundation

#if os(macOS)
/// Where MoneyMoney keeps its database on disk (#779). Normal users do not find the sandbox container
/// by browsing, so the import panel opens there directly.
enum MoneyMoneyLocations {
    /// Data folder of the sandboxed App Store build, relative to the home directory. It holds the
    /// database and the statement PDFs, so one pick brings both along.
    static let relativeDataFolder =
        "Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney"

    /// MoneyMoney's data folder if it exists, otherwise the home directory.
    static func importDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL {
        let url = home.appendingPathComponent(relativeDataFolder, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        return home
    }
}
#endif
