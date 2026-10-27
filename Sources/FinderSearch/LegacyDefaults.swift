import Foundation

// HOME: the fork's identifiers were renamed from "homy" to "home"; settings
// live in defaults keyed by the old names. One-time migration copies any
// legacy values so nothing (sidebar layout, saved searches, collections,
// smart rules, theme, content toggle, DigUp folders) is lost.

enum LegacyDefaults {
    static let pairs: [(old: String, new: String)] = [
        ("homy.sidebarLayout", "home.sidebarLayout"),
        ("homy.sidebarSections", "home.sidebarSections"),
        ("homy.collections", "home.collections"),
        ("homy.smartRules", "home.smartRules"),
        ("homy.savedSearches", "home.savedSearches"),
        ("homy.theme", "home.theme"),
        ("homy.includeContents", "home.includeContents"),
        ("homy.digup.roots", "home.digup.roots"),
    ]

    static func migrate(_ defaults: UserDefaults = .standard) {
        for pair in pairs {
            guard defaults.object(forKey: pair.old) != nil,
                defaults.object(forKey: pair.new) == nil
            else { continue }
            defaults.set(defaults.object(forKey: pair.old), forKey: pair.new)
        }
    }
}
