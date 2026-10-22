import AppKit

/// Carries a name you typed in TermTint over into the Claude session itself,
/// as if you had run /rename there.
///
/// There is no API for this: the only way in is to type the command into the
/// window, which Terminal allows through Apple Events. That needs the
/// Automation permission, asked for once on first use.
enum SessionRenamer {

    /// - Parameters:
    ///   - windowTitle: full title of the Terminal window to type into.
    ///   - name: the new session name.
    static func rename(inWindowTitled windowTitle: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        // Typing a command means the text must survive AppleScript's own
        // quoting, and must not be able to end the string early.
        let script = """
        tell application "Terminal"
            repeat with w in windows
                if name of w is "\(escaped(windowTitle))" then
                    do script "/rename \(escaped(clean))" in (selected tab of w)
                    return "ok"
                end if
            end repeat
            return "kein Fenster"
        end tell
        """

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                Log.write("Umbenennen fehlgeschlagen: \(error[NSAppleScript.errorMessage] ?? error)")
            } else {
                Log.write("Umbenannt in »\(clean)«: \(result?.stringValue ?? "?")")
            }
        }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
