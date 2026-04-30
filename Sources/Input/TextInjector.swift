import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "team.yourorbit.OrbitDictation", category: "TextInjector")

/// Pastes text into the active application while preserving the previous clipboard contents when possible.
enum TextInjector {
    static func paste(_ text: String, preserveClipboard: Bool = true) async {
        let pasteboard = NSPasteboard.general

        // Snapshot the current clipboard in parallel with the key-release
        // wait. The two are independent, and snapshotting takes ~1–5 ms, so
        // running them concurrently shaves measurable paste latency.
        async let snapshot: [NSPasteboardItem]? = preserveClipboard
            ? snapshotPasteboard(pasteboard)
            : nil
        await waitForKeyRelease()
        let savedItems = await snapshot

        guard !Task.isCancelled else {
            logger.info("Paste cancelled before clipboard write")
            return
        }

        // Write text to clipboard. Plain text is the universal fallback;
        // when the cleaned output contains list lines (`• item` or `- item`),
        // we additionally write an RTF representation so rich-text-aware
        // targets (Mail, Notes, Pages, Word, Notion, Slack, etc.) render the
        // bullets as a real list with proper indent. Plain-text-only targets
        // (code editors, Terminal, chat input fields) ignore the RTF and use
        // the `•` symbols verbatim.
        pasteboard.clearContents()
        if let rtfData = makeRTF(from: text) {
            pasteboard.setData(rtfData, forType: .rtf)
        }
        pasteboard.setString(text, forType: .string)
        let pasteChangeCount = pasteboard.changeCount

        // Brief wait for app focus to return. 15ms is enough on modern
        // hardware; the prior 30ms was defensive padding.
        try? await Task.sleep(for: .milliseconds(15))

        // If cancelled after clipboard write but before paste, restore and bail.
        guard !Task.isCancelled else {
            logger.info("Paste cancelled before simulating Cmd+V — restoring clipboard")
            if let savedItems {
                pasteboard.clearContents()
                pasteboard.writeObjects(savedItems)
            }
            return
        }

        // Simulate Cmd+V
        simulatePaste()

        // Restore clipboard after 150ms (only if nothing else modified it)
        if preserveClipboard, let savedItems {
            try? await Task.sleep(for: .milliseconds(150))
            if pasteboard.changeCount == pasteChangeCount {
                pasteboard.clearContents()
                let wrote = pasteboard.writeObjects(savedItems)
                if wrote {
                    logger.debug("Clipboard restored")
                } else {
                    logger.warning("Clipboard restore failed: writeObjects returned false")
                }
            } else {
                // Something else wrote to the clipboard between paste and restore
                // (likely the user or another app). Skip restore to avoid clobbering.
                logger.info("Clipboard changed during paste — skipping restore to preserve new contents")
            }
        }
    }

    /// Builds an RTF representation of `text` with proper list paragraph
    /// styling when list lines are present. Returns `nil` when the text has
    /// no list markers — in that case we want plain-text-only paste so we
    /// don't pollute the destination's font/styling with RTF defaults.
    ///
    /// List detection: any line whose first non-whitespace characters are
    /// `• ` (the symbol we emit) or `- ` (Markdown-style fallback). Each
    /// detected line gets a paragraph style with `firstLineHeadIndent: 0`
    /// (bullet sits at the margin) and `headIndent: 18pt` (wrapped text
    /// aligns under the first character after the bullet). The bullet itself
    /// is rendered as `•\t` so rich-text apps render the indent natively.
    ///
    /// System font at the default body size is used for both list and prose
    /// runs so the destination app's font choice isn't overridden — only
    /// the paragraph-level structure (the indent) gets carried through.
    private static func makeRTF(from text: String) -> Data? {
        let lines = text.components(separatedBy: "\n")

        let hasList = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("• ") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
        }
        guard hasList else { return nil }

        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        let listParagraphStyle = NSMutableParagraphStyle()
        listParagraphStyle.firstLineHeadIndent = 0
        listParagraphStyle.headIndent = 18
        listParagraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: 18, options: [:])]

        let bodyParagraphStyle = NSMutableParagraphStyle()

        let attributed = NSMutableAttributedString()

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isBullet = trimmed.hasPrefix("• ") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")

            if isBullet {
                // Strip the original marker (one of `• `, `- `, `* `) and
                // re-emit a real bullet glyph followed by a tab so the
                // paragraph's tab stop kicks in. Using a tab rather than
                // a space lets receiving apps render proper hanging indent
                // when the line wraps.
                let content = String(trimmed.dropFirst(2))
                attributed.append(NSAttributedString(
                    string: "•\t\(content)",
                    attributes: [
                        .font: bodyFont,
                        .paragraphStyle: listParagraphStyle,
                    ]
                ))
            } else {
                attributed.append(NSAttributedString(
                    string: line,
                    attributes: [
                        .font: bodyFont,
                        .paragraphStyle: bodyParagraphStyle,
                    ]
                ))
            }

            if index < lines.count - 1 {
                attributed.append(NSAttributedString(string: "\n"))
            }
        }

        return try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) async -> [NSPasteboardItem]? {
        pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let newItem = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    newItem.setData(data, forType: type)
                }
            }
            return newItem
        }
    }

    /// Wait up to 500ms for modifier keys to be released. Polls at 8ms so
    /// the average wait after a quick release is ~4ms (previously ~12ms).
    private static func waitForKeyRelease() async {
        let maxAttempts = 62  // 62 × 8ms ≈ 500ms
        for _ in 0..<maxAttempts {
            let flags = CGEventSource.flagsState(.hidSystemState)
            let hasModifiers = flags.contains(.maskSecondaryFn)
                || flags.contains(.maskCommand)
                || flags.contains(.maskAlternate)
                || flags.contains(.maskControl)
            if !hasModifiers { return }
            try? await Task.sleep(for: .milliseconds(8))
        }
        logger.warning("Key release wait timed out after 500ms")
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)

        logger.debug("Simulated Cmd+V paste")
    }
}
