import AppKit
import Combine
import SwiftUI
import os

private let logger = Logger(subsystem: "team.yourorbit.OrbitDictation", category: "MenuBarController")

/// Owns the menu-bar `NSStatusItem` and its popover.
///
/// We previously used SwiftUI's `MenuBarExtra` for this, but on macOS 14/15
/// the underlying `NSStatusItem` is regularly torn down and re-created when
/// any of the following happens:
///   - the label view re-evaluates (phase change, `@AppStorage` change, etc.)
///   - a `Window` scene activates (`NSApp.activate(ignoringOtherApps:)`
///     during a Settings/About open)
///   - the app flips activation policy (which a menu-bar app does often)
/// The result is a vanished menu-bar icon while the process is still
/// running. Multiple defensive patches against the symptoms didn't fix the
/// underlying fragility, so we now manage the status item directly via
/// AppKit, which is what production menu-bar apps do (Bartender, iStat,
/// Rectangle).
@MainActor
final class MenuBarController: NSObject {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hostingController: NSHostingController<MenuBarView>?
    private weak var appState: AppState?
    private var cancellables: Set<AnyCancellable> = []
    private var outsideClickMonitor: Any?

    /// Wire the controller to live `AppState` and install the status item.
    /// Idempotent — calling twice is a no-op.
    func attach(appState: AppState) {
        guard self.statusItem == nil else { return }
        self.appState = appState

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.imagePosition = .imageOnly
            button.toolTip = "Comet"
        }
        self.statusItem = item

        let host = NSHostingController(rootView: MenuBarView(appState: appState))
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = host
        // Initial size — actual size is recalculated each time the popover
        // opens so SwiftUI can size to its current content (the popover
        // body shrinks when setup cards are dismissed, etc.). Width 370
        // matches `MenuBarView`'s fixed content width.
        popover.contentSize = CGSize(width: 370, height: 520)
        self.popover = popover
        self.hostingController = host

        // Subscribe to phase changes for icon updates. `pipeline.$phase` is
        // `@Published` on `DictationPipeline`, which lives for the app's
        // lifetime — no retain-cycle concern for an AppDelegate-owned
        // controller, but we use `[weak self]` defensively.
        appState.pipeline.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.updateIcon(for: phase)
            }
            .store(in: &cancellables)

        updateIcon(for: appState.pipeline.phase)

        logger.info("MenuBarController installed status item")
    }

    /// Allow programmatic open from outside (e.g. AppDelegate or a hotkey).
    func openPopover() {
        guard let popover, let button = statusItem?.button else { return }
        if !popover.isShown {
            showPopover(from: button)
        }
    }

    /// Allow programmatic close (e.g. when AppDelegate is opening Settings
    /// in response to a popover-routed action).
    func closePopover() {
        popover?.performClose(nil)
        teardownOutsideClickMonitor()
    }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            closePopover()
        } else {
            showPopover(from: sender)
        }
    }

    private func showPopover(from button: NSStatusBarButton) {
        guard let popover, let host = hostingController else { return }

        // Resize popover to current SwiftUI content size before showing —
        // the popover content can shrink/grow as the user dismisses cards
        // or grants permissions, and a stale `contentSize` shows empty
        // padding or clips content.
        host.view.layoutSubtreeIfNeeded()
        let fitting = host.view.fittingSize
        if fitting.width > 0 && fitting.height > 0 {
            popover.contentSize = fitting
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // No `NSApp.activate(ignoringOtherApps:)` — this is what made the
        // SwiftUI MenuBarExtra status item disappear, and it's also not
        // necessary for a popover. The popover positions itself against
        // the status bar regardless of app activation state.
        installOutsideClickMonitor()
    }

    /// Close the popover when the user clicks anywhere else. `NSPopover.behavior
    /// = .transient` is supposed to do this, but it doesn't always fire reliably
    /// for status bar popovers when other windows take focus. Adding a global
    /// monitor as a safety net.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }
    }

    private func teardownOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Icon rendering

    /// Update the status item button image based on the pipeline phase.
    /// Keeps a stable single `NSImage` template and tints it via
    /// `contentTintColor` rather than swapping image assets per state —
    /// stable identity preserves the system's caching/redraw assumptions.
    private func updateIcon(for phase: PipelinePhase) {
        guard let button = statusItem?.button else { return }

        let symbolName: String?
        switch phase {
        case .recording: symbolName = "mic.fill"
        case .error: symbolName = "mic.slash"
        default: symbolName = nil
        }

        let image: NSImage?
        if let symbolName,
           let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Comet") {
            image = symbol
        } else if let asset = NSImage(named: "MenuBarIcon") {
            image = asset
        } else {
            image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Comet")
        }

        image?.isTemplate = true
        button.image = image

        switch phase {
        case .recording:
            button.contentTintColor = .systemRed
        case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
            button.contentTintColor = .systemBlue
        case .done:
            button.contentTintColor = .systemGreen
        case .error:
            button.contentTintColor = .systemOrange
        case .requestingMicrophonePermission, .starting:
            button.contentTintColor = .secondaryLabelColor
        case .idle:
            // nil → use the default menu-bar foreground colour, which adapts
            // to light/dark mode. Hardcoding `.labelColor` would still work
            // but defers less to system rendering.
            button.contentTintColor = nil
        }
    }
}
