import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ToteStore()
    private let updater = Updater()
    private let hotKey = HotKeyMonitor()
    private var currentHotKey: HotKey = HotKey.loadFromDefaults() ?? .default
    private var menuBar: MenuBarController?
    private var popover: PopoverController?
    private var captureWindow: HotKeyCaptureWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let pop = PopoverController(store: store)
        popover = pop

        menuBar = MenuBarController(
            store: store,
            updater: updater,
            onClick: { [weak self] in
                guard let anchor = self?.menuBar?.anchorView else { return }
                pop.toggle(relativeTo: anchor)
            },
            currentLaunchAtLogin: { LaunchAtLogin.isEnabled },
            onToggleLaunchAtLogin: { LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled) },
            onShowAbout: { [weak self] in
                pop.dismiss()
                self?.showStandardAboutPanel()
            },
            currentHotKey: { [weak self] in self?.currentHotKey ?? .default },
            onSetHotKey: { [weak self] in self?.openHotKeyCapture() }
        )

        // Best-effort: if Carbon refuses our saved hotkey (e.g. another
        // app now owns it), fall back to the default and try that.
        if !registerHotKey(currentHotKey) {
            _ = registerHotKey(.default)
            currentHotKey = .default
        }

        Task { await updater.check() }

        // First-launch onboarding: auto-open the popover so the user
        // sees where the icon is *and* the how-to copy in the empty
        // state. Skipped if they've ever added a file (sticky), so
        // upgrading users with existing entries don't get a popover
        // out of nowhere.
        if !store.hasEverAdded {
            // Delay so the status item has rendered — without it, the
            // anchor rect is degenerate and the popover floats mid-screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self,
                      let anchor = self.menuBar?.anchorView,
                      !self.store.hasEverAdded else { return }
                pop.toggle(relativeTo: anchor)
            }
        }
    }

    @discardableResult
    private func registerHotKey(_ hk: HotKey) -> Bool {
        hotKey.register(keyCode: hk.keyCode, modifiers: hk.modifiers) { [weak self] in
            self?.handleHotKey()
        }
    }

    /// Fired by the global hotkey. Reads the current Finder selection and
    /// totes any files. Silent — feedback is the icon pulse, nothing else.
    private func handleHotKey() {
        let urls = FinderSelection.current()
        guard !urls.isEmpty else { return }
        store.add(urls: urls)
        menuBar?.pulse()
    }

    private func openHotKeyCapture() {
        if captureWindow == nil {
            captureWindow = HotKeyCaptureWindowController(
                onTryRegister: { [weak self] hk -> String? in
                    guard let self else { return "Internal error" }
                    if self.registerHotKey(hk) {
                        self.currentHotKey = hk
                        hk.saveToDefaults()
                        return nil
                    }
                    // Re-register the previous one so the user isn't left
                    // without any hotkey.
                    _ = self.registerHotKey(self.currentHotKey)
                    return "\(hk.displayString) is already used by another app or macOS. Try another combo."
                },
                onClose: { [weak self] in self?.captureWindow = nil }
            )
        }
        captureWindow?.show()
    }

    /// Re-launching while running (Spotlight, Finder double-click) hits
    /// this. Open the popover so the user sees what their click did.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard let anchor = menuBar?.anchorView else { return true }
        popover?.toggle(relativeTo: anchor)
        return true
    }

    private func showStandardAboutPanel() {
        let credits = NSAttributedString(
            string: """
            A file clipboard for the macOS menu bar — drag in, drag out.

            MIT licensed. Source at github.com/sulemaanhamza/tote.
            """,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Tote",
            .applicationVersion: version,
            .credits: credits,
            .init(rawValue: "Copyright"): "© 2026 Suleman Hamza",
        ])
    }
}
