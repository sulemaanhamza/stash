import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let store: ToteStore
    private let updater: Updater
    private let onClick: () -> Void
    private let currentLaunchAtLogin: () -> Bool
    private let onToggleLaunchAtLogin: () -> Void
    private let onShowAbout: () -> Void
    private let currentHotKey: () -> HotKey
    private let onSetHotKey: () -> Void

    private var iconView: MenuBarIconView?
    private var cancellables: Set<AnyCancellable> = []

    init(
        store: ToteStore,
        updater: Updater,
        onClick: @escaping () -> Void,
        currentLaunchAtLogin: @escaping () -> Bool,
        onToggleLaunchAtLogin: @escaping () -> Void,
        onShowAbout: @escaping () -> Void,
        currentHotKey: @escaping () -> HotKey,
        onSetHotKey: @escaping () -> Void
    ) {
        self.store = store
        self.updater = updater
        self.onClick = onClick
        self.currentLaunchAtLogin = currentLaunchAtLogin
        self.onToggleLaunchAtLogin = onToggleLaunchAtLogin
        self.onShowAbout = onShowAbout
        self.currentHotKey = currentHotKey
        self.onSetHotKey = onSetHotKey
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        installIconView()

        // Reflect store changes in the visible glyph (empty vs filled tray).
        store.$entries
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)
    }

    /// Used by AppDelegate to position the popover under the icon.
    var anchorView: NSView? { statusItem.button }

    /// Two-layer setup:
    ///
    /// - The **button's own image** is what the system reads to size the
    ///   status item. If we set it to nil, the item collapses to ~0pt
    ///   wide — invisible, no hit area, popovers anchor to garbage.
    /// - A **transparent overlay subview** sits on top, fills the
    ///   button, and intercepts mouse and drag events. It's the only
    ///   way to hook drop handling onto a status item (you can't
    ///   subclass NSStatusBarButton).
    private func installIconView() {
        guard let button = statusItem.button else { return }
        refreshIcon()

        let view = MenuBarIconView(
            frame: button.bounds,
            topURLForDrag: { [weak self] in self?.topURLForDrag() },
            onDropFiles: { [weak self] urls in self?.handleDrop(urls: urls) },
            onDragEnter: { [weak self] in self?.setDragOver(true) },
            onDragExit: { [weak self] in self?.setDragOver(false) },
            onClick: { [weak self] in self?.onClick() },
            onRightClick: { [weak self] in self?.showContextMenu() }
        )
        view.autoresizingMask = [.width, .height]
        button.addSubview(view)
        iconView = view
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let name = store.entries.isEmpty ? "tray" : "tray.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Tote")
        image?.isTemplate = true
        button.image = image
    }

    private func setDragOver(_ over: Bool) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = over ? .controlAccentColor : nil
        // Swap to filled glyph during drag-over so the target feels real.
        let name = (over || !store.entries.isEmpty) ? "tray.fill" : "tray"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Tote")
        image?.isTemplate = true
        button.image = image
    }

    private func handleDrop(urls: [URL]) {
        store.add(urls: urls)
        // Restore tint after a successful drop.
        statusItem.button?.contentTintColor = nil
        pulse()
    }

    /// Brief scale-pulse on the menu bar icon. Used as silent feedback
    /// for actions that complete without opening any UI — drag-drop and
    /// the global hotkey.
    func pulse() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        let anim = CAKeyframeAnimation(keyPath: "transform.scale")
        anim.values = [1.0, 1.18, 1.0]
        anim.keyTimes = [0, 0.5, 1]
        anim.duration = 0.22
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "totePulse")
    }

    private func topURLForDrag() -> URL? {
        guard let entry = store.entries.first else { return nil }
        return store.resolveURL(for: entry)
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open", action: #selector(handleOpen), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        // Updater item shows up only when there's something for the user
        // to act on. Hidden in the .idle case so the menu stays quiet.
        if let updaterItem = makeUpdaterMenuItem() {
            menu.addItem(updaterItem)
            menu.addItem(NSMenuItem.separator())
        }

        let hotKeyItem = NSMenuItem(
            title: "Set Shortcut…  (\(currentHotKey().displayString))",
            action: #selector(handleSetHotKey),
            keyEquivalent: ""
        )
        hotKeyItem.target = self
        menu.addItem(hotKeyItem)

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(handleToggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = currentLaunchAtLogin() ? .on : .off
        menu.addItem(launchItem)

        let aboutItem = NSMenuItem(
            title: "About Tote",
            action: #selector(handleShowAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Quit Tote",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func makeUpdaterMenuItem() -> NSMenuItem? {
        switch updater.state {
        case .idle:
            return nil
        case .available(let version, _):
            let item = NSMenuItem(
                title: "Update to \(version) — install",
                action: #selector(handleUpdaterClick),
                keyEquivalent: ""
            )
            item.target = self
            return item
        case .downloading(let version):
            let item = NSMenuItem(title: "Downloading \(version)…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .pending(let version):
            let item = NSMenuItem(
                title: "Restart to apply \(version)",
                action: #selector(handleUpdaterClick),
                keyEquivalent: ""
            )
            item.target = self
            return item
        }
    }

    @objc private func handleOpen() { onClick() }
    @objc private func handleToggleLaunchAtLogin() { onToggleLaunchAtLogin() }
    @objc private func handleShowAbout() { onShowAbout() }
    @objc private func handleUpdaterClick() { updater.handleClick() }
    @objc private func handleSetHotKey() { onSetHotKey() }
}
