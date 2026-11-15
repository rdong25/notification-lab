import AppKit
import Foundation

/// Answers requests from the `notiflab` command-line tool.
///
/// Transport: distributed notifications (local, per-user). The CLI posts
/// `com.notificationlab.cli.request` with `userInfo = ["id": <uuid>, "json": <request JSON>]`;
/// the app answers with one or more `com.notificationlab.cli.response` posts carrying
/// `["id": <same uuid>, "json": <payload JSON>, "final": "1" | "0"]`.
///
/// Notifications have to be posted by the app (macOS only lets app bundles post them, and
/// routes clicks back to the app), so the CLI is a thin client and the app does the work.
@MainActor
final class CLIServer: NSObject {
    static let shared = CLIServer()

    static let requestName = Notification.Name("com.notificationlab.cli.request")
    static let responseName = Notification.Name("com.notificationlab.cli.response")

    /// notification identifier → request id waiting for an interaction
    private var waiters: [String: String] = [:]
    /// request ids following the activity log
    private var followers: [String] = []

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: Self.requestName, object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    @objc private func received(_ n: Notification) {
        guard let id = n.userInfo?["id"] as? String,
              let json = n.userInfo?["json"] as? String,
              let req = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let command = req["command"] as? String else { return }
        Task { await handle(command, req, id: id) }
    }

    // MARK: Dispatch

    private func handle(_ command: String, _ req: [String: Any], id: String) async {
        let svc = NotificationService.shared
        let state = AppState.shared
        let opts = req["options"] as? [String: Any] ?? [:]

        switch command {
        case "ping":
            reply(id, ["version": Self.version, "pid": Int(ProcessInfo.processInfo.processIdentifier)])

        case "status":
            await svc.refreshSettings()
            reply(id, statusPayload())

        case "send":
            guard let t = buildTemplate(opts, id: id) else { return }
            let ids = await svc.send(t, source: "via notiflab")
            let wait = opts["wait"] as? Bool ?? false
            var payload: [String: Any] = [
                "ids": ids,
                "scheduled": t.delay > 0,
                "warnings": Diagnostics.shared.blockers.map { "\($0.title): \($0.summary)" },
            ]
            if ids.isEmpty { payload["error"] = "macOS rejected the notification request. See `notiflab log`." }
            if wait && !ids.isEmpty {
                ids.forEach { waiters[$0] = id }
                reply(id, payload, final: false)
            } else {
                reply(id, payload)
            }

        case "snippet":
            guard let t = buildTemplate(opts, id: id) else { return }
            reply(id, ["snippet": t.swiftSnippet])

        case "templates":
            reply(id, ["templates": state.templates.map {
                ["name": $0.name, "title": $0.title, "traits": $0.traits.joined(separator: " ")]
            }])

        case "template":
            guard let name = opts["name"] as? String, let t = template(named: name) else {
                return reply(id, ["error": "No template named “\(opts["name"] as? String ?? "")”. Run `notiflab templates`."])
            }
            let data = (try? JSONEncoder().encode(t)) ?? Data()
            reply(id, ["template": (try? JSONSerialization.jsonObject(with: data)) ?? [:]])

        case "delivered":
            await svc.refreshDelivered()
            reply(id, ["delivered": svc.delivered.map {
                ["id": $0.id, "title": $0.title, "subtitle": $0.subtitle, "body": $0.body,
                 "thread": $0.thread, "date": iso($0.date)]
            }])

        case "pending":
            await svc.refreshDelivered()
            reply(id, ["pending": svc.pending.map {
                ["id": $0.id, "title": $0.title, "fires": iso($0.fireDate),
                 "remaining": max(0, $0.fireDate.timeIntervalSinceNow)]
            }])

        case "remove":
            if opts["all"] as? Bool == true { await svc.removeAllDelivered() }
            else { await svc.remove(Set(opts["ids"] as? [String] ?? [])) }
            reply(id, ["ok": true])

        case "cancel":
            if opts["all"] as? Bool == true { await svc.cancelAllPending() }
            else { await svc.cancel(Set(opts["ids"] as? [String] ?? [])) }
            reply(id, ["ok": true])

        case "badge":
            await svc.setBadge(opts["count"] as? Int ?? 0)
            reply(id, ["ok": true])

        case "diagnose":
            await Diagnostics.shared.run()
            let diag = Diagnostics.shared
            reply(id, [
                "checks": diag.checks.map { checkPayload($0, acknowledged: diag.isAcknowledged($0.id)) },
                "blockers": diag.blockers.map(\.id),
                "guide": diag.guideSteps.map { checkPayload($0, acknowledged: false) },
            ])

        case "test":
            Diagnostics.shared.sendTest()
            reply(id, ["ok": true, "display": NSScreen.screens.first?.localizedName ?? "main display"])

        case "restart-nc":
            Diagnostics.shared.perform(.restartNotificationCenter)
            reply(id, ["ok": true])

        case "log":
            let limit = opts["limit"] as? Int ?? 50
            let recent = svc.events.prefix(limit).reversed().map(eventPayload)
            if opts["follow"] as? Bool == true {
                followers.append(id)
                if followers.count > 16 { followers.removeFirst() }
                reply(id, ["events": Array(recent)], final: false)
            } else {
                reply(id, ["events": Array(recent)])
            }

        case "unfollow":
            followers.removeAll { $0 == (opts["request"] as? String) }

        case "open":
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            if let name = opts["template"] as? String, let t = template(named: name) { state.selection = .template(t.id) }
            if let view = opts["view"] as? String {
                switch view {
                case "activity": state.selection = .activity
                case "delivered": state.selection = .delivered
                case "scheduled": state.selection = .scheduled
                case "diagnostics": state.selection = .diagnostics
                default: break
                }
            }
            reply(id, ["ok": true])

        default:
            reply(id, ["error": "Unknown command “\(command)”. This app is \(Self.version); update the CLI or the app."])
        }
    }

    // MARK: Events pushed to clients

    func didRespond(notificationID: String, _ payload: [String: Any]) {
        guard let req = waiters.removeValue(forKey: notificationID) else { return }
        // A burst shares one waiter; the first interaction answers it.
        waiters = waiters.filter { $0.value != req }
        var p = payload
        p["id"] = notificationID
        reply(req, p)
    }

    func didLog(_ e: LogEvent) {
        guard !followers.isEmpty else { return }
        let p = ["events": [eventPayload(e)]]
        followers.forEach { reply($0, p, final: false) }
    }

    // MARK: Building templates from CLI options

    private func template(named name: String) -> Template? {
        let n = name.lowercased()
        return AppState.shared.templates.first { $0.name.lowercased() == n }
            ?? AppState.shared.templates.first { $0.name.lowercased().hasPrefix(n) }
    }

    private func buildTemplate(_ o: [String: Any], id: String) -> Template? {
        var t: Template
        if let name = o["template"] as? String {
            guard let base = template(named: name) else {
                reply(id, ["error": "No template named “\(name)”. Run `notiflab templates` to list them."])
                return nil
            }
            t = base
        } else {
            t = Template()
            t.name = "notiflab"
            t.symbol = "terminal"
            t.title = ""; t.subtitle = ""; t.message = ""
            t.actionsEnabled = false; t.actions = []
            t.reportDismiss = o["wait"] as? Bool ?? false
        }

        if let v = o["title"] as? String { t.title = v }
        if let v = o["subtitle"] as? String { t.subtitle = v }
        if let v = o["message"] as? String { t.message = v }
        if let v = o["sound"] as? String {
            let match = SoundChoice.system.first { $0.lowercased() == v.lowercased() }
            t.sound = ["none", "default"].contains(v.lowercased()) ? v.lowercased() : (match ?? v)
        }
        if let v = o["level"] as? String {
            let key = v.lowercased().replacingOccurrences(of: "-", with: "")
            guard let level = Level.allCases.first(where: { $0.rawValue.lowercased() == key }) else {
                reply(id, ["error": "Unknown level “\(v)”. Use passive, active, time-sensitive or critical."])
                return nil
            }
            t.level = level
        }
        if let v = o["group"] as? String { t.groupID = v }
        if let v = o["thread"] as? String { t.threadID = v }
        if let v = o["delay"] as? Double { t.delay = max(0, v) }
        if let v = o["repeat"] as? Int { t.repeatCount = min(max(1, v), 50) }
        if let v = o["badge"] as? Int { t.badgeEnabled = true; t.badge = v }
        if let v = o["open"] as? String { t.clickAction = .openURL; t.url = v }
        if let v = o["activate"] as? String { t.clickAction = .activateApp; t.bundleID = v }
        if let v = o["exec"] as? String { t.clickAction = .runCommand; t.command = v }
        if let list = o["actions"] as? [[String: Any]] {
            t.actions = list.prefix(ActionButton.maxCount).map {
                ActionButton(title: $0["title"] as? String ?? "", destructive: $0["destructive"] as? Bool ?? false,
                             symbol: $0["symbol"] as? String ?? "")
            }
            t.actionsEnabled = !t.actions.isEmpty
        }
        if let v = o["reply"] as? String {
            t.replyEnabled = true
            if !v.isEmpty { t.replyPlaceholder = v }
        }
        if let v = o["replyButton"] as? String { t.replyEnabled = true; t.replyButtonTitle = v }
        if let v = o["dismissReport"] as? Bool { t.reportDismiss = v }
        if let v = o["image"] as? String {
            let path = (v as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                reply(id, ["error": "Image not found: \(path)"]); return nil
            }
            t.imagePath = path
        }
        if t.title.isEmpty && t.subtitle.isEmpty && t.message.isEmpty && o["template"] == nil {
            reply(id, ["error": "Nothing to send. Give at least --title or --message (or --template NAME)."])
            return nil
        }
        return t
    }

    // MARK: Payloads

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private func statusPayload() -> [String: Any] {
        let s = NotificationService.shared
        let auth: String = switch s.authStatus {
        case .authorized: "authorized"
        case .denied: "denied"
        case .provisional: "provisional"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
        let style: String = switch s.alertStyle {
        case .banner: "banner"
        case .alert: "alert"
        default: "none"
        }
        return [
            "version": Self.version,
            "bundle": Bundle.main.bundleIdentifier ?? "",
            "app": Bundle.main.bundlePath,
            "authorization": auth, "alertStyle": style,
            "alerts": s.alertEnabled, "notificationCenter": s.centerEnabled, "lockScreen": s.lockScreenEnabled,
            "sound": s.soundEnabled, "badge": s.badgeEnabled, "timeSensitive": s.timeSensitiveEnabled,
            "delivered": s.delivered.count, "pending": s.pending.count,
            "blockers": Diagnostics.shared.blockers.map(\.title),
        ]
    }

    private func checkPayload(_ c: DiagnosticCheck, acknowledged: Bool) -> [String: Any] {
        ["id": c.id, "title": c.title, "status": c.status.label, "summary": c.summary, "why": c.why,
         "steps": c.steps, "evidence": c.evidence, "affectsBanners": c.affectsBanners, "acknowledged": acknowledged,
         "actions": c.actions.compactMap { a -> String? in
             if case .openSettings(let title, let url) = a { return "\(title): open \"\(url)\"" }
             if case .restartNotificationCenter = a { return "notiflab restart-nc" }
             return nil
         }]
    }

    private func eventPayload(_ e: LogEvent) -> [String: Any] {
        ["time": iso(e.date), "kind": e.kind.rawValue, "title": e.title, "detail": e.detail,
         "template": e.templateName, "id": e.notificationID]
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    private func iso(_ d: Date) -> String { Self.isoFormatter.string(from: d) }

    private func reply(_ id: String, _ payload: [String: Any], final: Bool = true) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Self.responseName, object: nil,
            userInfo: ["id": id, "json": json, "final": final ? "1" : "0"], deliverImmediately: true)
    }
}
