import SwiftUI

@main
struct WhispurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No `MenuBarExtra` — Comet manages its menu-bar status item
        // manually via `MenuBarController` (owned by `AppDelegate`).
        // SwiftUI's `MenuBarExtra` was structurally fragile in macOS 14/15:
        // the underlying `NSStatusItem` was repeatedly torn down on label
        // re-evaluation, on `Window` scene activation, and on activation-
        // policy flips. Manual NSStatusItem management is what production
        // menu-bar apps do for exactly this reason.

        Window("Comet Settings", id: "settings") {
            SettingsView(appState: appDelegate.appState)
                .frame(minWidth: 860, minHeight: 620)
                // Routes `comet://settings` URLs to this scene. AppDelegate
                // uses `NSWorkspace.shared.open` (or scene-front lookup) to
                // trigger this on launch and on second-activation.
                .handlesExternalEvents(preferring: ["settings"], allowing: ["*"])
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["settings"])

        Window("About Comet", id: "about") {
            AboutView()
                .handlesExternalEvents(preferring: ["about"], allowing: ["*"])
        }
        .defaultSize(width: 360, height: 360)
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["about"])
    }
}
