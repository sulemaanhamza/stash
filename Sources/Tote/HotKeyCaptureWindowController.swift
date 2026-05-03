import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Small floating panel for rebinding the global hotkey. Shown from the
/// right-click menu's "Set Shortcut…" item. Listens for the next valid
/// combo (must include at least one modifier), asks the host to attempt
/// Carbon registration, and closes on success — or shows the error
/// inline and keeps listening.
@MainActor
final class HotKeyCaptureWindowController: NSObject, NSWindowDelegate {
    /// Returns nil on success or a user-facing error message otherwise.
    private let onTryRegister: (HotKey) -> String?
    private let onClose: () -> Void

    private var panel: NSPanel?

    init(onTryRegister: @escaping (HotKey) -> String?, onClose: @escaping () -> Void) {
        self.onTryRegister = onTryRegister
        self.onClose = onClose
    }

    func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = HotKeyCaptureView(
            onTryRegister: onTryRegister,
            onSuccess: { [weak self] in self?.close() },
            onCancel: { [weak self] in self?.close() }
        )

        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Tote Shortcut"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.contentViewController = host
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        onClose()
    }

    // NSWindowDelegate — close button on the title bar.
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.close() }
    }
}

private struct HotKeyCaptureView: View {
    let onTryRegister: (HotKey) -> String?
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @State private var monitor: Any?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            Text("Press your shortcut")
                .font(.system(size: 18, weight: .medium))
            Text("Must include ⌘, ⌥, ⌃, or ⇧. Esc cancels.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { startListening() }
        .onDisappear { stopListening() }
    }

    private func startListening() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                onCancel()
                return nil
            }

            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let needed: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            guard !mods.intersection(needed).isEmpty else { return nil }

            let hotKey = HotKey(
                keyCode: UInt32(event.keyCode),
                modifiers: HotKey.carbonModifiers(from: mods)
            )

            if let err = onTryRegister(hotKey) {
                errorMessage = err
                // Keep listening so the user can immediately try another.
            } else {
                onSuccess()
            }
            return nil
        }
    }

    private func stopListening() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
