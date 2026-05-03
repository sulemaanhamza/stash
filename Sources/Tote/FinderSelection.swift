import AppKit

/// Reads the current Finder selection via AppleScript. Used by the
/// global hotkey path to "tote whatever's selected right now."
///
/// macOS will show a one-time TCC prompt the first time we send Apple
/// Events to Finder ("Tote wants to control Finder. Allow?"). After
/// that, the call returns silently. If the user denies, every call
/// returns an empty array — which we treat as "nothing selected."
enum FinderSelection {
    /// Returns file URLs for whatever is selected in the frontmost
    /// Finder window. Empty if Finder isn't running, isn't frontmost,
    /// or has no selection.
    static func current() -> [URL] {
        let source = """
        tell application "Finder"
            if not running then return ""
            try
                set sel to selection
            on error
                return ""
            end try
            set output to ""
            repeat with i from 1 to count of sel
                try
                    set p to POSIX path of (item i of sel as alias)
                    set output to output & p & linefeed
                end try
            end repeat
            return output
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        // `error` is non-nil if Apple Events permission was denied or
        // Finder isn't responding. Either way, treat as no-op.
        guard error == nil else { return [] }
        guard let raw = result.stringValue else { return [] }
        return raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)) }
    }
}
