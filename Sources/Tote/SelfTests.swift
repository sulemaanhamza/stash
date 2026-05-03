import AppKit
import Carbon.HIToolbox

/// In-process smoke tests for Tote's pure logic (no NSApplication
/// needed). Run with: `swift run Tote --test`.
enum SelfTests {
    /// Mutable bag the test functions share. A class so the closures
    /// passed to `MainActor.assumeIsolated` can mutate it without
    /// inout dance.
    final class Runner {
        var passed = 0
        var failures: [String] = []

        func check(_ name: String, _ assertion: @autoclosure () -> Bool) {
            if assertion() {
                passed += 1
            } else {
                failures.append(name)
                print("✗ \(name)")
            }
        }
    }

    @MainActor
    static func run() -> Never {
        let r = Runner()

        runMergeTests(r)
        runLaunchAtLoginTests(r)
        runStoreLifecycleTests(r)
        runHotKeyTests(r)

        let total = r.passed + r.failures.count
        print("\n\(r.passed)/\(total) passed")
        if !r.failures.isEmpty {
            print("\(r.failures.count) failure(s):")
            for f in r.failures { print("  · \(f)") }
            exit(1)
        }
        exit(0)
    }

    // MARK: - Merge (pure logic, no actor)

    private static func runMergeTests(_ r: Runner) {
        let cap = 5

        let empty: [ToteEntry] = []
        r.check("merge nothing into nothing → empty",
                ToteStore.merge(adding: [], into: empty, capacity: cap).isEmpty)

        let a = makeSyntheticEntry(name: "a.txt", path: "/tmp")
        let b = makeSyntheticEntry(name: "b.txt", path: "/tmp")
        let c = makeSyntheticEntry(name: "c.txt", path: "/tmp")
        let d = makeSyntheticEntry(name: "d.txt", path: "/tmp")
        let e = makeSyntheticEntry(name: "e.txt", path: "/tmp")
        let f = makeSyntheticEntry(name: "f.txt", path: "/tmp")

        let one = ToteStore.merge(adding: [a], into: [], capacity: cap)
        r.check("single add length", one.count == 1)
        r.check("single add identity", one.first?.displayName == "a.txt")

        let abThenC = ToteStore.merge(adding: [c], into: [b, a], capacity: cap)
        r.check("newest at top: c first", abThenC.first?.displayName == "c.txt")
        r.check("newest at top: b second", abThenC[1].displayName == "b.txt")
        r.check("newest at top: a last", abThenC[2].displayName == "a.txt")

        let overflow = ToteStore.merge(adding: [f], into: [e, d, c, b, a], capacity: cap)
        r.check("overflow length capped", overflow.count == cap)
        r.check("overflow keeps newest", overflow.first?.displayName == "f.txt")
        r.check("overflow drops oldest", !overflow.contains(where: { $0.displayName == "a.txt" }))

        let aDup = makeSyntheticEntry(name: "a.txt", path: "/tmp")
        let bumped = ToteStore.merge(adding: [aDup], into: [c, b, a], capacity: cap)
        r.check("re-add dedupes by path", bumped.count == 3)
        r.check("re-add bumps to top", bumped.first?.displayName == "a.txt")
        r.check("re-add preserves others",
                Set(bumped.map(\.displayName)) == ["a.txt", "b.txt", "c.txt"])

        let multi = ToteStore.merge(adding: [c, b, a], into: [], capacity: cap)
        r.check("multi-add order: first → top",
                multi.map(\.displayName) == ["c.txt", "b.txt", "a.txt"])

        let batchDup = ToteStore.merge(adding: [a, a, a], into: [], capacity: cap)
        r.check("same-batch dedupe", batchDup.count == 1)

        let aOther = makeSyntheticEntry(name: "a.txt", path: "/elsewhere")
        let twoFolders = ToteStore.merge(adding: [aOther], into: [a], capacity: cap)
        r.check("path disambiguates same name", twoFolders.count == 2)

        r.check("capacity == 5", ToteStore.capacity == 5)
        r.check("pathKey joins path + name", a.pathKey == "/tmp/a.txt")
    }

    // MARK: - LaunchAtLogin

    private static func runLaunchAtLoginTests(_ r: Runner) {
        let launchBefore = LaunchAtLogin.isEnabled
        r.check("LaunchAtLogin.isEnabled returns Bool",
                launchBefore == true || launchBefore == false)
        LaunchAtLogin.setEnabled(launchBefore)
        r.check("LaunchAtLogin.setEnabled(current) is no-op",
                LaunchAtLogin.isEnabled == launchBefore)
    }

    // MARK: - ToteStore lifecycle (real bookmarks, real persistence)

    @MainActor
    private static func runStoreLifecycleTests(_ r: Runner) {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("tote-tests-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        // Real files so URL.bookmarkData() succeeds.
        let fileA = tempRoot.appendingPathComponent("alpha.txt")
        let fileB = tempRoot.appendingPathComponent("beta.txt")
        let fileC = tempRoot.appendingPathComponent("gamma.txt")
        try? "alpha".write(to: fileA, atomically: true, encoding: .utf8)
        try? "beta".write(to: fileB, atomically: true, encoding: .utf8)
        try? "gamma".write(to: fileC, atomically: true, encoding: .utf8)

        let storeFile = tempRoot.appendingPathComponent("entries.json")

        // --- add() inserts entries with newest first ---
        let s1 = ToteStore(storeURL: storeFile)
        r.check("fresh store is empty", s1.entries.isEmpty)

        s1.add(urls: [fileA])
        r.check("add(1) → 1 entry", s1.entries.count == 1)
        r.check("add stored display name",
                s1.entries.first?.displayName == "alpha.txt")

        s1.add(urls: [fileB, fileC])
        r.check("add(more) → newest first",
                s1.entries.map(\.displayName) == ["beta.txt", "gamma.txt", "alpha.txt"])

        // --- resolveURL round-trips to the real file ---
        if let entry = s1.entries.first(where: { $0.displayName == "alpha.txt" }),
           let resolved = s1.resolveURL(for: entry) {
            r.check("resolveURL round-trips path",
                    resolved.standardizedFileURL == fileA.standardizedFileURL)
        } else {
            r.check("resolveURL round-trips path", false)
        }

        // --- persistence: a fresh store at the same path sees the same entries ---
        let s2 = ToteStore(storeURL: storeFile)
        r.check("persistence: count survives reload",
                s2.entries.count == 3)
        r.check("persistence: order survives reload",
                s2.entries.map(\.displayName) == ["beta.txt", "gamma.txt", "alpha.txt"])

        // --- remove() drops the row and persists ---
        if let toRemove = s2.entries.first(where: { $0.displayName == "gamma.txt" }) {
            s2.remove(id: toRemove.id)
        }
        r.check("remove drops entry", s2.entries.count == 2)
        r.check("remove keeps the right ones",
                Set(s2.entries.map(\.displayName)) == ["beta.txt", "alpha.txt"])

        let s3 = ToteStore(storeURL: storeFile)
        r.check("remove persists across reload",
                Set(s3.entries.map(\.displayName)) == ["beta.txt", "alpha.txt"])

        // --- resolveURL on a deleted file returns nil (dead-row UX) ---
        try? fm.removeItem(at: fileA)
        if let entry = s3.entries.first(where: { $0.displayName == "alpha.txt" }) {
            r.check("resolveURL nil after source deleted",
                    s3.resolveURL(for: entry) == nil)
        } else {
            r.check("resolveURL nil after source deleted", false)
        }

        // --- clear() empties + persists ---
        s3.clear()
        r.check("clear empties store", s3.entries.isEmpty)
        let s4 = ToteStore(storeURL: storeFile)
        r.check("clear persists across reload", s4.entries.isEmpty)

        // --- add() with no URLs is a no-op (defensive against empty drops) ---
        let beforeNoop = s4.entries
        s4.add(urls: [])
        r.check("add(empty) is no-op", s4.entries == beforeNoop)

        // --- hasEverAdded onboarding flag ---
        // Use a per-test ephemeral defaults suite so we don't pollute the
        // user's real UserDefaults when tests run interactively.
        let suiteName = "tote-tests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let onbStoreFile = tempRoot.appendingPathComponent("onb.json")
        let onb = ToteStore(storeURL: onbStoreFile, defaults: suite)
        r.check("hasEverAdded false on fresh store", onb.hasEverAdded == false)

        onb.add(urls: [fileB])
        r.check("hasEverAdded true after first add", onb.hasEverAdded == true)

        // Persistence + a fresh store at same path/defaults reads true
        let onb2 = ToteStore(storeURL: onbStoreFile, defaults: suite)
        r.check("hasEverAdded persists across reload", onb2.hasEverAdded == true)

        // Sticky: clearing entries doesn't reset the flag
        onb2.clear()
        r.check("hasEverAdded stays true after clear", onb2.hasEverAdded == true)

        // Migration: an upgrading user with entries on disk but no flag
        // gets the flag set silently on init, so we don't show them
        // onboarding for an app they've been using.
        let migSuite = UserDefaults(suiteName: "tote-tests-mig-\(UUID().uuidString)")!
        defer { migSuite.removePersistentDomain(forName: migSuite.dictionaryRepresentation().description) }
        let migStoreFile = tempRoot.appendingPathComponent("mig.json")
        // Seed entries.json directly to simulate "existing user upgrading."
        let seed: [ToteEntry] = [ToteStore.makeEntry(from: fileC)].compactMap { $0 }
        let seedData = try! JSONEncoder().encode(seed)
        try! seedData.write(to: migStoreFile)
        // Pre-condition: flag is not set in this fresh defaults domain.
        r.check("migration: flag not set in seed defaults",
                migSuite.bool(forKey: "HasEverAdded") == false)
        let mig = ToteStore(storeURL: migStoreFile, defaults: migSuite)
        r.check("migration: existing entries flip flag on init",
                mig.hasEverAdded == true)
    }

    // MARK: - HotKey

    private static func runHotKeyTests(_ r: Runner) {
        r.check("default keyCode = T",
                HotKey.default.keyCode == UInt32(kVK_ANSI_T))
        r.check("default modifiers = control + option",
                HotKey.default.modifiers == UInt32(controlKey | optionKey))
        r.check("default display = '⌃⌥T'",
                HotKey.default.displayString == "⌃⌥T")

        let cmdShiftP = HotKey(
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(cmdKey | shiftKey)
        )
        r.check("⇧⌘P display", cmdShiftP.displayString == "⇧⌘P")

        let allMods = HotKey(
            keyCode: UInt32(kVK_ANSI_F),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )
        r.check("⌃⌥⇧⌘F display order", allMods.displayString == "⌃⌥⇧⌘F")

        let optSpace = HotKey(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey)
        )
        r.check("⌥Space display", optSpace.displayString == "⌥Space")

        let unknown = HotKey(keyCode: 9999, modifiers: UInt32(cmdKey))
        r.check("unknown keyCode falls back",
                unknown.displayString == "⌘Key9999")

        r.check("carbonModifiers cmd",
                HotKey.carbonModifiers(from: [.command]) == UInt32(cmdKey))
        r.check("carbonModifiers option+shift",
                HotKey.carbonModifiers(from: [.option, .shift])
                == UInt32(optionKey | shiftKey))
        r.check("carbonModifiers all",
                HotKey.carbonModifiers(from: [.command, .option, .shift, .control])
                == UInt32(cmdKey | optionKey | shiftKey | controlKey))
        r.check("carbonModifiers empty",
                HotKey.carbonModifiers(from: []) == 0)
    }

    // MARK: - helpers

    /// For pure-logic merge tests where the bookmark blob is irrelevant.
    private static func makeSyntheticEntry(name: String, path: String) -> ToteEntry {
        ToteEntry(
            bookmark: Data(),
            displayName: name,
            displayPath: path,
            addedAt: Date()
        )
    }
}
