import AppKit

/// What a Terminal window is being used for. Drives the colour family,
/// the background emblem and the caption.
enum Role: String {
    case claude
    case codex
    case shell
    case other

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .shell: return "Shell"
        case .other: return "Prozess"
        }
    }

    /// A tool role is worth re-colouring a window for; a plain shell is not.
    var isTool: Bool { self == .claude || self == .codex }

    /// Narrow hue band, so every window in a family reads as the same family
    /// while staying individually distinguishable.
    var hues: ClosedRange<CGFloat> {
        switch self {
        case .claude: return 0.015...0.135   // amber → coral
        case .codex:  return 0.480...0.620   // cyan → blue
        case .shell:  return 0.550...0.640   // desaturated to near-neutral
        case .other:  return 0.720...0.880   // violet → magenta
        }
    }

    var saturation: CGFloat {
        self == .shell ? 0.10 : 0.74
    }

    /// First symbol that exists on this system wins.
    var symbolCandidates: [String] {
        switch self {
        case .claude: return ["asterisk", "sparkle", "staroflife.fill"]
        case .codex:  return ["chevron.left.forwardslash.chevron.right", "curlybraces"]
        case .shell:  return ["apple.terminal", "terminal"]
        case .other:  return ["gearshape", "gear"]
        }
    }

    func symbol(pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        for name in symbolCandidates {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: label) else { continue }
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            return image.withSymbolConfiguration(config) ?? image
        }
        return nil
    }
}

/// Terminal.app writes the active process — and whatever title a program sets
/// itself — straight into the window title, e.g.
///
///     max — ✳ autopilot-passive-income — claude --chrome — 98×28
///     max — caffeinate ◂ claude --chrome — 80×24
///     max — -zsh — 80×24
///
/// We already receive that string through Accessibility, so reading it costs
/// nothing. If the format ever changes, detection degrades to `.other` and the
/// window simply keeps a neutral colour — nothing breaks.
enum TerminalTitle {

    struct Parsed {
        /// Title a running program set for itself (Claude Code writes its
        /// session topic here).
        let sessionTitle: String?
        /// Foreground process chain, innermost first, e.g. "caffeinate ◂ claude".
        let command: String

        var commandName: String {
            let root = command.components(separatedBy: "◂").last ?? command
            return TerminalTitle.executable(of: root)
        }
    }

    private static let separator = " — "
    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "nu", "csh", "tcsh",
                                              "login", "tmux", "screen"]

    static func parse(_ title: String) -> Parsed? {
        var parts = title.components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        if let last = parts.last, isDimensions(last) { parts.removeLast() }
        guard parts.count >= 2 else {
            return parts.first.map { Parsed(sessionTitle: nil, command: $0) }
        }

        let command = parts.removeLast()
        // parts[0] is the working directory / user; anything after it is a
        // title the program set for itself.
        let session = parts.count >= 2 ? parts[1...].joined(separator: " ") : nil
        return Parsed(sessionTitle: session, command: command)
    }

    /// The glyph a tool puts in front of its own title. Claude Code rotates it
    /// while it works and leaves it still while it waits — which is what tells
    /// the two apart, without depending on knowing the specific characters.
    static func marker(of parsed: Parsed) -> String? {
        guard let session = parsed.sessionTitle?.trimmingCharacters(in: .whitespaces),
              let first = session.first, isDecoration(first)
        else { return nil }
        return String(first)
    }

    /// A glyph a tool put there, not one a person did. An emoji at the front
    /// of a name belongs to the name: it never changes, so reading it as a
    /// spinner would make the session look permanently finished — and
    /// stripping it would quietly eat it out of the name.
    private static func isDecoration(_ character: Character) -> Bool {
        guard !character.isLetter, !character.isNumber, !character.isWhitespace else { return false }
        return !character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
    }

    static func role(for parsed: Parsed) -> Role {
        let executables = parsed.command
            .components(separatedBy: "◂")
            .map(executable(of:))

        if executables.contains("claude") { return .claude }
        if executables.contains("codex") { return .codex }
        if executables.allSatisfy({ shells.contains($0) }) { return .shell }
        return .other
    }

    /// Label to pre-fill: the session topic if a program set one, otherwise
    /// the process name.
    static func autoName(for parsed: Parsed) -> String {
        if let session = parsed.sessionTitle {
            let cleaned = stripLeadingGlyphs(session)
            if !cleaned.isEmpty { return cleaned }
        }
        return parsed.commandName
    }

    /// First word, without path and without the login shell's leading dash.
    /// Falls back to the raw segment when the "executable" turns out to be a
    /// decorative glyph — that happens when a program sets its own title and
    /// the profile does not show the process name.
    private static func executable(of segment: String) -> String {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        let first = trimmed.components(separatedBy: .whitespaces).first ?? ""
        let name = first.components(separatedBy: "/").last ?? first
        let cleaned = name.hasPrefix("-") ? String(name.dropFirst()) : name
        guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else {
            return stripLeadingGlyphs(trimmed)
        }
        return cleaned
    }

    /// Claude Code prefixes its title with a spinner glyph that changes while
    /// it works (✳ ◑ ✻ …). Only a short symbol run followed by a space counts
    /// as decoration — a title like "~/Projekte/app" must survive intact.
    private static func stripLeadingGlyphs(_ text: String) -> String {
        let prefix = text.prefix(while: isDecoration)
        guard !prefix.isEmpty, prefix.count <= 2 else {
            return text.trimmingCharacters(in: .whitespaces)
        }
        let rest = text.dropFirst(prefix.count)
        guard rest.first?.isWhitespace == true else {
            return text.trimmingCharacters(in: .whitespaces)
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// Terminal ends the title with "80×24", sometimes with a marker appended
    /// ("80×24 (2)"), so match the leading dimensions rather than the whole
    /// component.
    private static func isDimensions(_ text: String) -> Bool {
        var digits = 0
        var index = text.startIndex
        while index < text.endIndex, text[index].isNumber {
            digits += 1
            index = text.index(after: index)
        }
        guard digits > 0, index < text.endIndex, text[index] == "×" || text[index] == "x" else { return false }
        index = text.index(after: index)
        var trailing = 0
        while index < text.endIndex, text[index].isNumber {
            trailing += 1
            index = text.index(after: index)
        }
        return trailing > 0
    }
}
