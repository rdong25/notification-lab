import AppKit
import Foundation

/// Renders the main window to a PNG with demo data, for README screenshots.
///
///     NOTIFLAB_SNAPSHOT=out.png NOTIFLAB_SCENE=editor [NOTIFLAB_APPEARANCE=light] open -n "Notification Lab.app"
///
/// Scenes: editor, palette, activity, diagnostics, guide.
/// Uses the built-in templates in memory; the saved template library is never touched.
@MainActor
enum ScreenshotMode {
    private static let env = ProcessInfo.processInfo.environment
    static var isActive: Bool { env["NOTIFLAB_SNAPSHOT"] != nil }
    static var forceHover: Bool { isActive && ["editor", "light"].contains(scene) }
    private static var scene: String { env["NOTIFLAB_SCENE"] ?? "editor" }

    static func runIfRequested() {
        guard let out = env["NOTIFLAB_SNAPSHOT"] else { return }
        if env["NOTIFLAB_APPEARANCE"] == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
        if env["NOTIFLAB_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }

        let state = AppState.shared
        state.persistenceEnabled = false
        state.templates = Template.defaults
        let t = state.templates
        injectDemoEvents(t)

        let actions = t[2]
        switch scene {
        case "palette":
            state.selection = .template(actions.id)
            state.paletteSeed = "send"
            state.showPalette = true
        case "activity":
            state.selection = .activity
        case "diagnostics":
            state.selection = .template(actions.id)
            state.selection = .diagnostics
            Diagnostics.shared.expanded = ["capture"]
        case "guide":
            state.selection = .diagnostics
            Diagnostics.shared.testState = .guiding(step: 0)
        default:
            state.selection = .template(actions.id)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let w = NSApp.windows.filter(\.isVisible).max(by: { $0.frame.width < $1.frame.width }) {
                w.setContentSize(NSSize(width: 1360, height: 860))
                w.center()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            // The largest visible window is the main one (helper windows like text-completion panels can also be visible).
            let main = NSApp.windows.filter(\.isVisible).max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            guard let view = main?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
    }

    private static func injectDemoEvents(_ t: [Template]) {
        let svc = NotificationService.shared
        let now = Date()
        func id() -> String { UUID().uuidString }
        // Oldest first; inject() prepends, so the newest ends up on top.
        let script: [(TimeInterval, LogEvent)] = [
            (-312, LogEvent(kind: .sent, title: "Sent “\(t[0].title)”", templateID: t[0].id, templateName: t[0].name, notificationID: id())),
            (-305, LogEvent(kind: .clicked, title: "Clicked “\(t[0].title)”", detail: "no click action", templateID: t[0].id, templateName: t[0].name, notificationID: id())),
            (-240, LogEvent(kind: .sent, title: "Sent “\(t[1].title)”", templateID: t[1].id, templateName: t[1].name, notificationID: id())),
            (-236, LogEvent(kind: .clicked, title: "Clicked “\(t[1].title)”", detail: "open https://example.com", templateID: t[1].id, templateName: t[1].name, notificationID: id())),
            (-180, LogEvent(kind: .scheduled, title: "Scheduled “\(t[5].title)”", detail: "fires in 5.0s", templateID: t[5].id, templateName: t[5].name, notificationID: id())),
            (-175, LogEvent(kind: .delivered, title: "Delivered scheduled notification", templateID: t[5].id, templateName: t[5].name, notificationID: id())),
            (-120, LogEvent(kind: .sent, title: "Sent “\(t[3].title)”", templateID: t[3].id, templateName: t[3].name, notificationID: id())),
            (-102, LogEvent(kind: .reply, title: "Reply", detail: "Yes! 12:30 at the usual place?", templateID: t[3].id, templateName: t[3].name, notificationID: id())),
            (-64, LogEvent(kind: .sent, title: "Sent “\(t[2].title)”", templateID: t[2].id, templateName: t[2].name, notificationID: id())),
            (-58, LogEvent(kind: .presented, title: "Presented in foreground", detail: "“\(t[2].title)”", templateID: t[2].id, templateName: t[2].name, notificationID: id())),
            (-41, LogEvent(kind: .action, title: "Pressed “Join”", detail: "on “\(t[2].title)”", templateID: t[2].id, templateName: t[2].name, notificationID: id())),
            (-40, LogEvent(kind: .command, title: "$ open -a zoom.us", detail: "[exit 0]", templateID: t[2].id, templateName: t[2].name)),
            (-22, LogEvent(kind: .sent, title: "Sent “\(t[2].title)”", templateID: t[2].id, templateName: t[2].name, notificationID: id())),
            (-15, LogEvent(kind: .dismissed, title: "Dismissed “\(t[2].title)”", templateID: t[2].id, templateName: t[2].name, notificationID: id())),
            (-6, LogEvent(kind: .warning, title: "Banner will probably be hidden: Screen sharing / capture", detail: "Zoom screen share is active", templateID: t[2].id, templateName: t[2].name)),
        ]
        for (offset, var e) in script {
            e.date = now.addingTimeInterval(offset)
            svc.inject(e)
        }
    }
}
