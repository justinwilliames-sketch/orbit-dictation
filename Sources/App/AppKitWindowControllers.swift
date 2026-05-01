import AppKit
import SwiftUI

/// AppKit-managed Settings window.
///
/// Replaces the SwiftUI `Window(id: "settings")` scene because that scene
/// goes into a stale state after first close — `openWindow(id: "settings")`
/// stops working, and the `comet://settings` URL fallback isn't reliable
/// in NSPopover-hosted contexts. Direct AppKit ownership keeps the open/
/// reopen path bulletproof, the same approach `OnboardingWindowController`
/// already uses.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(appState: AppState) {
        let host = NSHostingController(
            rootView: SettingsView(appState: appState)
                .frame(minWidth: 860, minHeight: 620)
        )
        let window = NSWindow(contentViewController: host)
        window.title = "Comet Settings"
        window.identifier = NSUserInterfaceItemIdentifier("comet.settings")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 980, height: 680))
        window.minSize = NSSize(width: 860, height: 620)
        window.center()
        // Keep the NSWindow alive after close so re-opening just shows it
        // again rather than instantiating a new one. Without this the
        // window is released on close and the next showWindow call
        // either crashes or silently fails.
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// AppKit-managed About window. Same reasoning as `SettingsWindowController`.
@MainActor
final class AboutWindowController: NSWindowController {
    init() {
        let host = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: host)
        window.title = "About Comet"
        window.identifier = NSUserInterfaceItemIdentifier("comet.about")
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 360, height: 360))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
