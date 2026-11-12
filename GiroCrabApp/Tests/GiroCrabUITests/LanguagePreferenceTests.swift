import XCTest
@testable import GiroCrabUI

/// App language choice and when to ask about it (GitHub #93).
final class LanguagePreferenceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var system: [String] = ["de-DE"]

    override func setUp() {
        suiteName = "LanguagePreferenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        system = ["de-DE"]
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var pref: LanguagePreference {
        LanguagePreference(defaults: defaults, domain: suiteName, systemLanguages: { [unowned self] in self.system })
    }

    /// Only the app's own domain; plain `stringArray(forKey:)` falls back to the global one.
    private var ownAppleLanguages: [String]? {
        defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String]
    }

    // MARK: First start

    func testFirstStartInSupportedLanguageAsksNothing() {
        XCTAssertEqual(pref.choice, .system)
        XCTAssertEqual(pref.startupQuestion(), .none)
        XCTAssertEqual(pref.startupQuestion(), .none)
    }

    func testFirstStartInUnsupportedLanguageAsksUntilAnswered() {
        system = ["fr-FR"]
        XCTAssertEqual(pref.startupQuestion(), .chooseLanguage)
        XCTAssertEqual(pref.startupQuestion(), .chooseLanguage, "quit without answering: ask again")
        pref.apply(.en)
        XCTAssertEqual(pref.startupQuestion(), .none)
    }

    // MARK: Storage

    func testChoiceIsTheAppsOwnAppleLanguages() {
        pref.apply(.en)
        XCTAssertEqual(ownAppleLanguages, ["en"])
        XCTAssertEqual(pref.choice, .en)
        pref.apply(.system)
        XCTAssertNil(ownAppleLanguages)
        XCTAssertEqual(pref.choice, .system)
    }

    func testChoiceMadeInSystemSettingsIsRecognised() {
        defaults.set(["en-GB"], forKey: "AppleLanguages")
        XCTAssertEqual(pref.choice, .en)
    }

    // MARK: System language changes

    func testAsksOnceWhenSystemLanguageChangesAwayFromChoice() {
        pref.apply(.de)
        system = ["en-US", "de-DE"]
        XCTAssertEqual(pref.startupQuestion(), .systemChanged(to: "en"))
        pref.acknowledgeSystemLanguage()          // "Deutsch beibehalten"
        XCTAssertEqual(pref.startupQuestion(), .none)
    }

    func testFollowingSystemNeverAsks() {
        _ = pref.startupQuestion()
        system = ["en-GB"]
        XCTAssertEqual(pref.startupQuestion(), .none)
    }

    func testSystemChangeToTheChosenLanguageIsNoConflict() {
        pref.apply(.en)
        system = ["en-US"]
        XCTAssertEqual(pref.startupQuestion(), .none)
        system = ["de-AT"]
        XCTAssertEqual(pref.startupQuestion(), .systemChanged(to: "de"))
    }

    func testSystemChangeToUnsupportedLanguageKeepsExplicitChoice() {
        pref.apply(.en)
        system = ["fr-FR"]
        XCTAssertEqual(pref.startupQuestion(), .none)
    }

    func testSystemChangeToUnsupportedLanguageAsksWhenFollowingSystem() {
        _ = pref.startupQuestion()
        system = ["it-IT"]
        XCTAssertEqual(pref.startupQuestion(), .chooseLanguage)
    }

    // MARK: Resolution

    func testUnsupportedSystemLanguageFallsBackToFirstSupportedEntry() {
        system = ["fr-FR", "en-US"]
        XCTAssertTrue(pref.systemIsSupported)
        XCTAssertEqual(pref.systemLanguage, "en")
        system = ["fr-FR"]
        XCTAssertFalse(pref.systemIsSupported)
        XCTAssertEqual(pref.systemLanguage, "de")
    }

    func testEffectiveLanguage() {
        system = ["en-US"]
        XCTAssertEqual(pref.effectiveLanguage(for: .system), "en")
        XCTAssertEqual(pref.effectiveLanguage(for: .de), "de")
    }
}
