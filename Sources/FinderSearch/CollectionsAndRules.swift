import SwiftUI
import AppKit

// HOME: user-defined sidebar content — Collections (named groups of folders,
// e.g. "Work" = ~/Projects + ~/Documents/Invoices) and Smart Folders (rule
// builder: kind, size, age, name pattern, download source). Both persist in
// defaults, appear as reorderable sidebar sections, and are searchable just
// like the built-in categories.

// MARK: - Collections

struct HomeCollection: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var folders: [String]
}

@MainActor final class HomeCollections: ObservableObject {
    static let shared = HomeCollections()
    static let key = "home.collections"

    @Published private(set) var items: [HomeCollection]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
            let stored = try? JSONDecoder().decode([HomeCollection].self, from: data)
        {
            items = stored
        } else {
            items = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    @discardableResult
    func add(name: String) -> HomeCollection {
        let collection = HomeCollection(id: UUID(), name: name, folders: [])
        items.append(collection)
        save()
        return collection
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].name = name
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func addFolders(_ urls: [URL], to id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        for url in urls {
            let path = url.standardizedFileURL.path
            if !items[index].folders.contains(path) {
                items[index].folders.append(path)
            }
        }
        save()
    }

    func removeFolder(_ path: String, from id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].folders.removeAll { $0 == path }
        save()
    }

    func collection(_ id: UUID) -> HomeCollection? {
        items.first { $0.id == id }
    }

    /// Every file under the collection's folders, merged and newest first.
    /// HOME: one engine query per folder, concurrently, deduplicated.
    static func files(in folders: [String], limit: Int) async -> [Hit] {
        let existing = folders.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return [] }
        var merged: [Hit] = await withTaskGroup(of: [Hit].self) { group in
            for folder in existing {
                group.addTask {
                    let reply = try? await HomeServices.shared.engine.request([
                        "q": "kind:file in:" + folder, "limit": limit,
                    ])
                    return (reply?.ok == true) ? (reply?.hits ?? []) : []
                }
            }
            var all: [Hit] = []
            for await hits in group { all += hits }
            return all
        }
        var seen = Set<String>()
        merged = merged.filter { seen.insert($0.path).inserted }
        merged.sort { $0.mtime > $1.mtime }
        return merged
    }

    /// Ask for a name with a modal sheet (sidebar creates and renames here).
    static func promptName(title: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

// MARK: - Smart rules

struct HomeSmartRule: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// Engine type filter: "", "image", "video", "audio", "doc", "zip", or
    /// the special "screenshot".
    var kind: String
    var minSizeMB: Int?
    var days: Int?
    var olderNotNewer: Bool
    var namePattern: String
    var source: String?
}

@MainActor final class HomeSmartRules: ObservableObject {
    static let shared = HomeSmartRules()
    static let key = "home.smartRules"

    @Published private(set) var items: [HomeSmartRule]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
            let stored = try? JSONDecoder().decode([HomeSmartRule].self, from: data)
        {
            items = stored
        } else {
            items = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    @discardableResult
    func add(_ rule: HomeSmartRule) {
        items.append(rule)
        save()
    }

    func update(_ rule: HomeSmartRule) {
        guard let index = items.firstIndex(where: { $0.id == rule.id }) else { return }
        items[index] = rule
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func rule(_ id: UUID) -> HomeSmartRule? {
        items.first { $0.id == id }
    }

    /// The fsearch query a rule compiles to.
    static func query(for rule: HomeSmartRule) -> String {
        var parts: [String] = []
        if rule.kind == "screenshot" {
            if !rule.namePattern.isEmpty {
                parts.append(rule.namePattern + " Screenshot kind:file")
            } else {
                parts.append("Screenshot kind:file")
            }
        } else {
            if !rule.namePattern.isEmpty { parts.append(rule.namePattern) }
            parts.append(rule.kind.isEmpty ? "kind:file" : "type:\(rule.kind) kind:file")
        }
        if let minSizeMB = rule.minSizeMB, minSizeMB > 0 {
            parts.append("size:>\(minSizeMB)mb")
        }
        if let days = rule.days, days > 0 {
            parts.append(rule.olderNotNewer ? "mtime:>\(days)d" : "mtime:<\(days)d")
        }
        return parts.joined(separator: " ")
    }

    func query(for id: UUID) -> String? {
        rule(id).map(Self.query(for:))
    }
}

// MARK: - Sidebar sections

struct HomeCollectionSection: View {
    let select: (String) -> Void
    let selection: String?
    @ObservedObject private var collections = HomeCollections.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader(title: "Collections", section: .collections)
            ForEach(collections.items) { collection in
                SidebarItemRow(
                    route: "col:" + collection.id.uuidString, selection: selection,
                    title: collection.name, symbol: "square.stack.3d.up", onSelect: select,
                    menu: {
                        collectionActions(collection)
                    }
                )
            }
            newCollectionRow
        }
    }

    private var newCollectionRow: some View {
        Button {
            if let name = HomeCollections.promptName(title: "New Collection") {
                let collection = HomeCollections.shared.add(name: name)
                addFolders(to: collection.id)
            }
        } label: {
            HStack {
                Label("New Collection…", systemImage: "plus")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 4)
    }

    @ViewBuilder private func collectionActions(_ collection: HomeCollection) -> some View {
        Button("Add Folder…") { addFolders(to: collection.id) }
        Button("Rename…") {
            if let name = HomeCollections.promptName(
                title: "Rename Collection", initial: collection.name)
            {
                HomeCollections.shared.rename(collection.id, to: name)
            }
        }
        Divider()
        ForEach(collection.folders, id: \.self) { path in
            Button("Remove \(URL(fileURLWithPath: path).lastPathComponent)") {
                HomeCollections.shared.removeFolder(path, from: collection.id)
            }.disabled(collection.folders.count <= 1)
        }
        if !collection.folders.isEmpty {
            Divider()
        }
        Button("Delete Collection", role: .destructive) {
            HomeCollections.shared.remove(collection.id)
        }
    }

    private func addFolders(to id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        HomeCollections.shared.addFolders(panel.urls, to: id)
    }
}

/// HOME: user rules render under the built-in Smart Folders, plus the row
/// that opens the rule builder.
struct HomeUserRulesSection: View {
    let selection: String?
    let onSelect: (String) -> Void
    @ObservedObject private var rules = HomeSmartRules.shared
    @State private var editingRule: HomeSmartRule?
    @State private var showBuilder = false

    var body: some View {
        ForEach(rules.items) { rule in
            SidebarItemRow(
                route: "rule:" + rule.id.uuidString, selection: selection,
                title: rule.name, symbol: "slider.horizontal.3", onSelect: onSelect,
                menu: {
                    Button("Edit…") {
                        editingRule = rule
                        showBuilder = true
                    }
                    Divider()
                    Button("Delete", role: .destructive) { rules.remove(rule.id) }
                }
            )
        }
        Button {
            editingRule = nil
            showBuilder = true
        } label: {
            HStack {
                Label("New Smart Folder…", systemImage: "plus").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .sheet(isPresented: $showBuilder) {
                SmartRuleSheet(rule: editingRule)
            }
    }
}

// MARK: - Rule builder

struct SmartRuleSheet: View {
    /// nil builds a new rule; otherwise the rule is edited in place.
    let rule: HomeSmartRule?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind = ""
    @State private var useSize = false
    @State private var minSizeMB = 100
    @State private var useAge = false
    @State private var days = 30
    @State private var olderNotNewer = true
    @State private var namePattern = ""
    @State private var source = ""

    private let kinds: [(String, String)] = [
        ("", "Any file"), ("image", "Images"), ("video", "Videos"), ("audio", "Audio"),
        ("doc", "Documents"), ("zip", "Archives"), ("screenshot", "Screenshots"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(rule == nil ? "New Smart Folder" : "Edit Smart Folder")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("Kind", selection: $kind) {
                ForEach(kinds, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }.pickerStyle(.menu)
            HStack {
                Toggle("Bigger than", isOn: $useSize)
                Stepper("\(minSizeMB) MB", value: $minSizeMB, in: 1...100_000, step: 10)
                    .disabled(!useSize)
            }
            HStack {
                Toggle("Date", isOn: $useAge)
                Picker("", selection: $olderNotNewer) {
                    Text("older than").tag(true)
                    Text("newer than").tag(false)
                }.pickerStyle(.menu).labelsHidden().frame(width: 110)
                Stepper("\(days) days", value: $days, in: 1...3650)
                    .disabled(!useAge)
            }
            TextField("Name contains (optional)", text: $namePattern)
                .textFieldStyle(.roundedBorder)
            TextField("Downloaded from, e.g. github (optional)", text: $source)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(16)
            .frame(width: 400)
            .onAppear { if let rule { load(rule) } }
    }

    private func load(_ rule: HomeSmartRule) {
        name = rule.name
        kind = rule.kind
        useSize = rule.minSizeMB != nil
        minSizeMB = rule.minSizeMB ?? 100
        useAge = rule.days != nil
        days = rule.days ?? 30
        olderNotNewer = rule.olderNotNewer
        namePattern = rule.namePattern
        source = rule.source ?? ""
    }

    private func save() {
        let built = HomeSmartRule(
            id: rule?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            kind: kind,
            minSizeMB: useSize ? minSizeMB : nil,
            days: useAge ? days : nil,
            olderNotNewer: olderNotNewer,
            namePattern: namePattern.trimmingCharacters(in: .whitespaces),
            source: source.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : source.trimmingCharacters(in: .whitespaces))
        if rule == nil {
            HomeSmartRules.shared.add(built)
        } else {
            HomeSmartRules.shared.update(built)
        }
        dismiss()
    }
}
