import SwiftUI

// HOME: Playful / Minimal themes (⌃⌘T), applied to the fork's surfaces while
// upstream views keep the platform voice.

@MainActor final class HomeTheme: ObservableObject {
    static let shared = HomeTheme()
    static let key = "home.theme"

    enum Style: String, CaseIterable {
        case playful, minimal
        var title: String {
            switch self {
            case .playful: return "Playful"
            case .minimal: return "Minimal"
            }
        }
    }

    @Published var style: Style {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Self.key) }
    }

    private init() {
        style = Style(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .minimal
    }

    func toggle() {
        style = style == .playful ? .minimal : .playful
    }

    var cardRadius: CGFloat { style == .playful ? 14 : 8 }

    var cardFill: Color {
        style == .playful
            ? Color.accentColor.opacity(0.07) : Color(nsColor: .controlBackgroundColor)
    }

    var accent: Color { .accentColor }
}
