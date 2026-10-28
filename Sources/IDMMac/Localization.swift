import AppKit
import Foundation

/// UI language. The Turkish text in the code is the key; English comes from en.lproj/Localizable.strings
/// (a missing key shows the Turkish text). "auto" follows the macOS language: Turkish gives Turkish, anything else English.
enum AppLanguage {
    static let key = "appLanguage"

    static var setting: String { UserDefaults.standard.string(forKey: key) ?? "auto" }

    /// The language the app starts in for a setting ("auto", "tr" or "en").
    static func resolved(_ setting: String) -> String {
        if setting == "tr" || setting == "en" { return setting }
        let first = Locale.preferredLanguages.first ?? "en"
        return first.hasPrefix("tr") ? "tr" : "en"
    }

    /// Called at launch, before any window: the bundle picks its language from AppleLanguages.
    static func apply() {
        UserDefaults.standard.set([resolved(setting)], forKey: "AppleLanguages")
    }

    /// Saves a new choice and starts MDM again, because windows and menus read their text once.
    static func change(to new: String) {
        UserDefaults.standard.set(new, forKey: key)
        apply()
    }

    @MainActor static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// The text in the chosen language; the Turkish original when there is no translation.
func L(_ turkish: String) -> String {
    NSLocalizedString(turkish, comment: "")
}

/// L() for text with values: the key uses %@ (text) and %lld (whole numbers).
func L(_ turkish: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(turkish, comment: ""), arguments: args)
}
