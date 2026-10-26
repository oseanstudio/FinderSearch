import SwiftUI
import AppKit
import Combine

// HOMY: Natural-language search. "pdfs from last week over 5 mb from github"
// becomes engine filters shown as editable chips, exactly like Homy's ⌘F.

/// Parsed interpretation of a plain-English search query.
struct HomyParsedQuery: Equatable {
    var text: String?
    var type: String?
    var kind: String?
    var mtime: String?
    var size: String?
    var source: String?
    var grep: String?

    var isEmpty: Bool {
        self == HomyParsedQuery()
    }

    /// The fsearch query the parse compiles to.
    var engineQuery: String {
        var parts: [String] = []
        if let text, !text.isEmpty { parts.append(text) }
        if let type { parts.append("type:" + type) }
        if let kind { parts.append("kind:" + kind) }
        if let mtime { parts.append("mtime:" + mtime) }
        if let size { parts.append("size:" + size) }
        if let grep { parts.append("grep:" + grep) }
        return parts.joined(separator: " ")
    }

    var chipLabels: [(field: String, value: String)] {
        var chips: [(String, String)] = []
        if let type { chips.append(("Type", type)) }
        if let kind { chips.append(("Kind", kind)) }
        if let mtime { chips.append(("Date", mtime)) }
        if let size { chips.append(("Size", size)) }
        if let source { chips.append(("From", source)) }
        if let grep { chips.append(("Contents", grep)) }
        if let text, !text.isEmpty { chips.append(("Name", text)) }
        return chips
    }
}

enum HomyQuery {
    /// Extra runtime options the chips bar toggles; persisted so it survives
    /// relaunches. HOMY
    static var includeContents: Bool {
        get { UserDefaults.standard.bool(forKey: "homy.includeContents") }
        set { UserDefaults.standard.set(newValue, forKey: "homy.includeContents") }
    }

    private static let typeWords: [String: String] = [
        "pdf": "pdf", "pdfs": "pdf",
        "image": "image", "images": "image", "photo": "image", "photos": "image",
        "picture": "image", "pictures": "image",
        "video": "video", "videos": "video", "movie": "video", "movies": "video",
        "music": "audio", "song": "audio", "songs": "audio", "audio": "audio",
        "document": "doc", "documents": "doc", "doc": "doc", "docs": "doc",
        "archive": "zip", "archives": "zip", "zip": "zip", "zips": "zip",
        "spreadsheet": "xlsx", "spreadsheets": "xlsx", "excel": "xlsx",
        "presentation": "ppt", "presentations": "ppt", "keynote": "key",
        "screenshot": "png", "screenshots": "png",
    ]

    private static let stopWords: Set<String> = [
        "from", "with", "that", "which", "have", "has", "than", "over", "under",
        "more", "less", "bigger", "larger", "smaller", "older", "newer", "the",
        "a", "an", "my", "me", "find", "show", "search", "containing", "mention",
        "mentions", "about", "past", "last", "this", "ago", "in", "on", "at",
        "is", "are", "files", "file",
    ]

    /// Parse plain English into filters. Returns the empty parse when the
    /// query already looks like fsearch syntax or has nothing recognizable.
    static func parse(_ raw: String) -> HomyParsedQuery {
        var result = HomyParsedQuery()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return result }
        // Raw fsearch syntax passes through untouched.
        if trimmed.contains(where: { $0 == ":" }) { return result }

        let words = trimmed.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var leftover: [String] = []

        var index = 0
        while index < words.count {
            let word = words[index]

            // "pdf(s)", "images", "videos" …
            if result.type == nil, let type = typeWords[word] {
                result.type = type
                if type == "png" && word.hasPrefix("screenshot") { result.text = "screenshot" }
                index += 1
                continue
            }
            if word == "folder" || word == "folders" || word == "directory" {
                result.kind = "dir"
                index += 1
                continue
            }

            // Size: "over 5 mb", "less than 200kb", "bigger than 1 gb"
            if let size = parseSize(words, from: index, matchedLength: &index) {
                result.size = size
                continue
            }
            // Dates: "today", "last week", "past 3 months", "3 weeks ago"
            if let date = parseDate(words, from: index, matchedLength: &index) {
                result.mtime = date
                continue
            }
            // Source: "from gmail" / "from github" — not a date phrase.
            if word == "from", index + 1 < words.count,
                !isDateStart(words[index + 1])
            {
                result.source = words[index + 1]
                index += 2
                continue
            }
            // Contents: "containing invoice" / "that mention invoice"
            if word == "containing" || word == "mention" || word == "mentions",
                index + 1 < words.count
            {
                result.grep = words[(index + 1)...].joined(separator: " ")
                index = words.count
                continue
            }
            if !stopWords.contains(word) { leftover.append(word) }
            index += 1
        }
        if !leftover.isEmpty {
            let joined = leftover.joined(separator: " ")
            result.text = result.text.map { $0 + " " + joined } ?? joined
        }
        if includeContents, let text = result.text, result.grep == nil {
            result.grep = text
            result.text = nil
        }
        // A bare text query needs no chips; keep the raw fuzzy search.
        if result.type == nil, result.kind == nil, result.mtime == nil, result.size == nil,
            result.source == nil, result.grep == nil
        {
            return HomyParsedQuery()
        }
        return result
    }

    /// Translate a raw query for the engine; untouched when nothing parses.
    static func translate(_ raw: String) -> String {
        let parsed = parse(raw)
        guard !parsed.isEmpty else { return raw }
        return parsed.engineQuery
    }

    /// Queries with a source filter match locally via where-from metadata.
    static func hasSourceFilter(_ raw: String) -> Bool {
        parse(raw).source != nil
    }

    static func filterBySource(_ hits: [Hit], rawQuery: String) -> [Hit] {
        guard let source = parse(rawQuery).source else { return hits }
        return hits.filter { matchesSource($0, source: source) }
    }

    static func matchesSource(_ hit: Hit, source: String) -> Bool {
        guard let origin = WhereFroms.from(hit.url).first else { return false }
        let label = WhereFroms.label(for: origin).lowercased()
        let host = (origin.host ?? "").lowercased()
        let needle = source.lowercased()
        if label.contains(needle) || host.contains(needle) { return true }
        // Bare "gmail" should match mail.google.com-style hosts only when it
        // looks like a real domain piece, not every substring hit.
        return needle.contains(".") && host.hasSuffix(needle)
    }

    // MARK: phrase parsers

    private static func normalizeUnit(_ word: String) -> String? {
        var unit = word
        if unit.hasPrefix("k") { unit = "kb" }
        if unit.hasPrefix("m") { unit = "mb" }
        if unit.hasPrefix("g") { unit = "gb" }
        return ["kb", "mb", "gb"].contains(unit) ? unit : nil
    }

    /// "2mb" and "500kb" arrive as one token.
    private static func numberAndUnit(_ word: String) -> (Int, String)? {
        let digits = word.prefix { $0.isNumber }
        guard !digits.isEmpty, let amount = Int(digits) else { return nil }
        guard let unit = normalizeUnit(String(word.dropFirst(digits.count))) else { return nil }
        return (amount, unit)
    }

    private static func parseSize(_ words: [String], from start: Int, matchedLength: inout Int)
        -> String?
    {
        var index = start
        var direction: String?
        if ["over", "bigger", "larger", "more"].contains(words[index]) {
            direction = ">"
        } else if ["under", "smaller", "less"].contains(words[index]) {
            direction = "<"
        }
        if direction != nil { index += 1 }
        if index < words.count, words[index] == "than" { index += 1 }
        guard index < words.count else { return nil }
        if let amount = Int(words[index]), index + 1 < words.count,
            let unit = normalizeUnit(words[index + 1])
        {
            matchedLength = index + 2
            return (direction ?? ">") + "\(amount)\(unit)"
        }
        if let (amount, unit) = numberAndUnit(words[index]) {
            matchedLength = index + 1
            return (direction ?? ">") + "\(amount)\(unit)"
        }
        return nil
    }

    private static func isDateStart(_ word: String) -> Bool {
        ["today", "yesterday", "week", "weeks", "month", "months", "year", "years",
         "day", "days", "this", "last", "past"].contains(word)
    }

    private static func unitDays(_ word: String) -> Int? {
        ["day": 1, "days": 1, "week": 7, "weeks": 7, "month": 30, "months": 30,
         "year": 365, "years": 365][word]
    }

    private static func parseDate(_ words: [String], from start: Int, matchedLength: inout Int)
        -> String?
    {
        let first = words[start]
        if first == "today" {
            matchedLength = start + 1
            return "<1d"
        }
        if first == "yesterday" {
            matchedLength = start + 1
            return "<2d"
        }
        var index = start
        let modified = ["this", "last", "past"].contains(first)
        if modified { index += 1 }

        // "past 3 months" / "last 2 weeks"
        if index < words.count, let count = Int(words[index]), index + 1 < words.count,
            let unit = unitDays(words[index + 1])
        {
            matchedLength = index + 2
            return "<\(max(1, count) * unit)d"
        }
        // "this week" / "last month" / "this year"
        if modified, index < words.count, let unit = unitDays(words[index]) {
            matchedLength = index + 1
            return "<\(unit)d"
        }
        // "3 days ago" / "2 weeks ago"
        if let count = Int(first), start + 2 < words.count,
            let unit = unitDays(words[start + 1]), words[start + 2] == "ago"
        {
            matchedLength = start + 3
            return "<\(max(1, count) * unit)d"
        }
        return nil
    }
}

// MARK: - Saved searches

struct SavedSearch: Identifiable, Equatable, Codable {
    var id = UUID()
    let name: String
    let query: String
}

@MainActor final class SavedSearches: ObservableObject {
    static let shared = SavedSearches()
    static let key = "homy.savedSearches"

    @Published var entries: [SavedSearch] {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
            let stored = try? JSONDecoder().decode([SavedSearch].self, from: data)
        {
            entries = stored
        } else {
            entries = []
        }
    }

    func add(_ name: String, query: String) {
        entries.append(SavedSearch(name: name, query: query))
    }

    func remove(_ entry: SavedSearch) {
        entries.removeAll { $0.id == entry.id }
    }

    /// Runs a saved search: switch to a Home scope and type the query, which
    /// reuses upstream's whole search pipeline (translation included).
    func run(_ entry: SavedSearch, select: (String) -> Void) {
        select("home")
        NotificationCenter.default.post(
            name: .homyRunSavedSearch, object: nil, userInfo: ["query": entry.query])
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

extension Notification.Name {
    static let homyRunSavedSearch = Notification.Name("homy.runSavedSearch")
}

// MARK: - Chips bar

/// Shown under the toolbar while searching: how the query was parsed, each
/// filter as a removable chip, a contents toggle, and Save.
struct HomySearchChipsBar: View {
    @ObservedObject var model: SearchModel
    @ObservedObject private var saved = SavedSearches.shared
    @State private var savePrompt: SavePrompt?

    private var parsed: HomyParsedQuery {
        HomyQuery.parse(model.query)
    }

    var body: some View {
        let parse = parsed
        return HStack(spacing: 8) {
            if parse.isEmpty {
                Text("Tip: try “pdfs from last week over 5 mb”")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                Text("Filters:").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(parse.chipLabels, id: \.field) { chip in
                    HStack(spacing: 4) {
                        Text(chip.field).foregroundStyle(.secondary)
                        Text(chip.value).fontWeight(.medium)
                    }.font(.system(size: 11))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.14)))
                }
            }
            Spacer()
            Toggle("Contents", isOn: Binding(
                get: { HomyQuery.includeContents },
                set: {
                    HomyQuery.includeContents = $0
                    if model.isSearch { model.schedule(immediate: true) }
                }))
                .controlSize(.small)
            Button {
                savePrompt = SavePrompt(suggestion: defaultName(parse))
            } label: {
                Image(systemName: "bookmark")
            }.buttonStyle(.borderless).help("Save Search")
                .popover(item: $savePrompt) { prompt in
                    HomySaveSearchField(initial: prompt.suggestion) { name in
                        saved.add(name, query: model.query)
                        savePrompt = nil
                    } cancel: { savePrompt = nil }
                }
        }.padding(.horizontal, 16).padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    private func defaultName(_ parse: HomyParsedQuery) -> String {
        let chips = parse.chipLabels.map { "\($0.field) \($0.value)" }
        return chips.isEmpty ? model.query : chips.joined(separator: ", ")
    }
}

/// Identifiable wrapper so the save popover can present from state.
struct SavePrompt: Identifiable {
    let suggestion: String
    var id: String { suggestion }
}

struct HomySaveSearchField: View {
    let initial: String
    let save: (String) -> Void
    let cancel: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save Search").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveNonEmpty() }
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                Spacer()
                Button("Save", action: saveNonEmpty)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(12).frame(width: 280)
            .onAppear { name = initial }
    }

    private func saveNonEmpty() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        save(trimmed)
    }
}
