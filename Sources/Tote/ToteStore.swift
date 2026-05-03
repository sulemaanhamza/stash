import AppKit
import Combine

/// One row in the tray. The bookmark is the source of truth; the display
/// fields are denormalized so we can paint the row without resolving the
/// bookmark on every redraw.
struct ToteEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let bookmark: Data
    let displayName: String
    let displayPath: String
    let addedAt: Date

    init(id: UUID = UUID(), bookmark: Data, displayName: String, displayPath: String, addedAt: Date = Date()) {
        self.id = id
        self.bookmark = bookmark
        self.displayName = displayName
        self.displayPath = displayPath
        self.addedAt = addedAt
    }

    /// Used only for dedupe — two entries are "the same file" if their
    /// path matches. We don't compare bookmarks because re-adding the
    /// same file produces a fresh bookmark blob each time.
    var pathKey: String { (displayPath as NSString).appendingPathComponent(displayName) }
}

@MainActor
final class ToteStore: ObservableObject {
    /// Tight on purpose. The whole identity of Tote is "recent", not
    /// "archive". If the user wants more, they want a folder.
    nonisolated static let capacity = 5

    private static let hasEverAddedKey = "HasEverAdded"

    @Published private(set) var entries: [ToteEntry] = []

    /// True once the user has added at least one file via any path
    /// (drag, hotkey, future). Drives onboarding: when false AND
    /// `entries` is empty, the popover shows verbose how-to copy and
    /// auto-opens at launch. Sticky — once true, never resets.
    @Published private(set) var hasEverAdded: Bool = false

    private let storeURL: URL
    private let defaults: UserDefaults

    init(storeURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.storeURL = storeURL ?? Self.defaultStoreURL()
        self.defaults = defaults
        load()
        // Migration: an upgrading user already has entries on disk; we
        // never set HasEverAdded for them, so set it now to skip
        // showing onboarding to people who clearly don't need it.
        if !entries.isEmpty && !defaults.bool(forKey: Self.hasEverAddedKey) {
            defaults.set(true, forKey: Self.hasEverAddedKey)
        }
        hasEverAdded = defaults.bool(forKey: Self.hasEverAddedKey)
    }

    /// Drop new files at the top of the tray. Re-adding a file that's
    /// already there bumps it up (no duplicates). Capacity overflow
    /// silently drops the bottom — no animation, no toast; the icon
    /// pulse is the entire confirmation.
    func add(urls: [URL]) {
        let incoming = urls.compactMap(Self.makeEntry(from:))
        guard !incoming.isEmpty else { return }
        entries = Self.merge(adding: incoming, into: entries, capacity: Self.capacity)
        if !hasEverAdded {
            hasEverAdded = true
            defaults.set(true, forKey: Self.hasEverAddedKey)
        }
        save()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    /// Resolve the bookmark to a live URL. Returns nil if the file has
    /// been moved/deleted — caller paints the row dim and disables drag.
    func resolveURL(for entry: ToteEntry) -> URL? {
        var stale = false
        return try? URL(
            resolvingBookmarkData: entry.bookmark,
            options: [],
            bookmarkDataIsStale: &stale
        )
    }

    // MARK: - Pure logic (test seam)

    /// Prepend `adding` to `existing`, dedupe by path keeping the newer
    /// occurrence on top, then truncate to `capacity`. Pure function so
    /// SelfTests can hit it without the filesystem.
    nonisolated static func merge(adding: [ToteEntry], into existing: [ToteEntry], capacity: Int) -> [ToteEntry] {
        var combined = adding + existing
        var seen = Set<String>()
        combined = combined.filter { seen.insert($0.pathKey).inserted }
        return Array(combined.prefix(capacity))
    }

    nonisolated static func makeEntry(from url: URL) -> ToteEntry? {
        let resolved = url.resolvingSymlinksInPath()
        guard let bookmark = try? resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return nil
        }
        return ToteEntry(
            bookmark: bookmark,
            displayName: resolved.lastPathComponent,
            displayPath: resolved.deletingLastPathComponent().path
        )
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let decoded = try? JSONDecoder().decode([ToteEntry].self, from: data) {
            entries = decoded
        }
    }

    private func save() {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private static func defaultStoreURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return support
            .appendingPathComponent("Tote", isDirectory: true)
            .appendingPathComponent("entries.json")
    }
}
