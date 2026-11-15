import AppKit
import Foundation
import Observation
import UserNotifications

/// Owns the UNUserNotificationCenter, sends notifications built from templates,
/// and records everything that happens to them.
@MainActor
@Observable
final class NotificationService {
    static let shared = NotificationService()

    // Permission
    private(set) var authStatus: UNAuthorizationStatus = .notDetermined
    private(set) var alertStyle: UNAlertStyle = .none
    private(set) var soundEnabled = false
    private(set) var badgeEnabled = false
    private(set) var alertEnabled = false
    private(set) var centerEnabled = false
    private(set) var lockScreenEnabled = false
    private(set) var timeSensitiveEnabled = false

    // State
    private(set) var isLoaded = false
    private(set) var events: [LogEvent] = []
    private(set) var delivered: [DeliveredItem] = []
    private(set) var pending: [PendingItem] = []
    private(set) var jobs: [Job] = []
    private(set) var sendProgress: (done: Int, total: Int)?
    private(set) var lastError: LogEvent?

    private let center = UNUserNotificationCenter.current()
    private let delegate = Delegate()
    private var categories: [String: UNNotificationCategory] = [:]
    private var scheduled: [String: (fire: Date, interval: TimeInterval, template: UUID, name: String)] = [:]
    private var tick = 0

    private init() {}

    /// Must run before the app finishes launching so clicks that cold-launch the app are delivered.
    func install() {
        center.delegate = delegate
    }

    func start() async {
        await refreshSettings()
        if authStatus == .notDetermined { await requestAuthorization() }
        await refreshDelivered()
        isLoaded = true
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in await NotificationService.shared.poll() }
        }
    }

    private func poll() async {
        tick += 1
        if tick % 3 == 0 { await refreshSettings() }
        await refreshDelivered()
    }

    var isAuthorized: Bool { [.authorized, .provisional].contains(authStatus) }

    // MARK: Permission

    func requestAuthorization() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted { log(.info, "Permission granted") }
            else { log(.error, "Permission denied", "Enable Notification Lab in System Settings → Notifications.") }
        } catch {
            log(.error, "Permission request failed", error.localizedDescription)
        }
        await refreshSettings()
    }

    func refreshSettings() async {
        let s = await center.notificationSettings()
        authStatus = s.authorizationStatus
        alertStyle = s.alertStyle
        soundEnabled = s.soundSetting == .enabled
        badgeEnabled = s.badgeSetting == .enabled
        alertEnabled = s.alertSetting == .enabled
        centerEnabled = s.notificationCenterSetting == .enabled
        lockScreenEnabled = s.lockScreenSetting == .enabled
        timeSensitiveEnabled = s.timeSensitiveSetting == .enabled
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Sending

    func send(_ t: Template, quiet: Bool = false) async {
        if !quiet, authStatus != .denied, let blocker = Diagnostics.shared.blockers.first {
            log(.warning, "Banner will probably be hidden: \(blocker.title)", blocker.summary, template: t)
        }
        if authStatus == .denied {
            log(.error, "Notifications are off for this app", "The request is accepted but macOS won't display it.",
                template: t)
        }

        let category = await registerCategory(for: t)
        let count = max(1, t.repeatCount)
        sendProgress = count > 1 ? (0, count) : nil

        for i in 0..<count {
            let content = UNMutableNotificationContent()
            content.title = t.title
            content.subtitle = t.subtitle
            content.body = t.message
            content.interruptionLevel = t.level.un
            content.categoryIdentifier = category
            content.userInfo = t.userInfo
            if !t.threadID.isEmpty { content.threadIdentifier = t.threadID }
            if t.badgeEnabled { content.badge = NSNumber(value: t.badge) }

            switch t.sound {
            case SoundChoice.none: content.sound = nil
            case SoundChoice.standard: content.sound = .default
            default: content.sound = UNNotificationSound(named: UNNotificationSoundName("\(t.sound).aiff"))
            }

            if let src = t.imageURL {
                do {
                    // The system moves attachment files into its own store, so hand it a copy.
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString).appendingPathExtension(src.pathExtension)
                    try FileManager.default.copyItem(at: src, to: tmp)
                    content.attachments = [try UNNotificationAttachment(identifier: "image", url: tmp)]
                } catch {
                    log(.error, "Couldn't attach image", error.localizedDescription, template: t)
                }
            }

            let identifier = t.groupID.isEmpty ? UUID().uuidString : t.groupID
            let interval = t.delay + Double(i) * 0.4
            let trigger = interval > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false) : nil
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

            do {
                try await center.add(request)
                let suffix = count > 1 ? " (\(i + 1)/\(count))" : ""
                if t.delay > 0 {
                    scheduled[identifier] = (Date().addingTimeInterval(interval), interval, t.id, t.name)
                    log(.scheduled, "Scheduled “\(t.title)”\(suffix)", "fires in \(String(format: "%.1f", interval))s",
                        template: t, nid: identifier)
                } else {
                    log(.sent, "Sent “\(t.title)”\(suffix)", "", template: t, nid: identifier)
                }
            } catch {
                log(.error, "Send failed", error.localizedDescription, template: t)
            }
            if count > 1 {
                sendProgress = (i + 1, count)
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        sendProgress = nil
        await refreshDelivered()
    }

    /// Categories carry the action buttons and dismiss option; one per distinct configuration.
    private func registerCategory(for t: Template) async -> String {
        let id = "cat." + String(format: "%08x", UInt32(truncatingIfNeeded: t.categorySignature.hashValue))
        guard categories[id] == nil else { return id }

        var actions: [UNNotificationAction] = []
        if t.actionsEnabled {
            for (i, a) in t.actions.prefix(ActionButton.maxCount).enumerated()
            where !a.title.trimmingCharacters(in: .whitespaces).isEmpty {
                actions.append(UNNotificationAction(identifier: "action.\(i)", title: a.title,
                                                    options: a.destructive ? [.destructive] : [],
                                                    icon: a.symbol.isEmpty ? nil : UNNotificationActionIcon(systemImageName: a.symbol)))
            }
        }
        if t.replyEnabled {
            actions.append(UNTextInputNotificationAction(identifier: "reply", title: t.replyButtonTitle, options: [],
                                                         textInputButtonTitle: "Send",
                                                         textInputPlaceholder: t.replyPlaceholder))
        }
        categories[id] = UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [],
                                                options: t.reportDismiss ? [.customDismissAction] : [])
        center.setNotificationCategories(Set(categories.values))
        _ = await center.notificationCategories() // wait for registration to land
        return id
    }

    // MARK: Delivered / pending

    func refreshDelivered() async {
        let notes = await center.deliveredNotifications()
        delivered = notes.map {
            let c = $0.request.content
            return DeliveredItem(id: $0.request.identifier, title: c.title, subtitle: c.subtitle, body: c.body,
                                 thread: c.threadIdentifier, category: c.categoryIdentifier, date: $0.date)
        }
        .sorted { $0.date > $1.date }

        let requests = await center.pendingNotificationRequests()
        let pendingIDs = Set(requests.map(\.identifier))

        // Anything we scheduled that's no longer pending has fired.
        for (id, info) in scheduled where !pendingIDs.contains(id) {
            scheduled[id] = nil
            if delivered.contains(where: { $0.id == id }) {
                log(.delivered, "Delivered scheduled notification", "", templateID: info.template,
                    templateName: info.name, nid: id)
            }
        }

        pending = requests.map { r in
            let local = scheduled[r.identifier]
            let trigger = r.trigger as? UNTimeIntervalNotificationTrigger
            return PendingItem(id: r.identifier, title: r.content.title,
                               fireDate: local?.fire ?? trigger?.nextTriggerDate() ?? .now,
                               interval: local?.interval ?? trigger?.timeInterval ?? 1)
        }
        .sorted { $0.fireDate < $1.fireDate }
    }

    func remove(_ ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: Array(ids))
        log(.removed, ids.count == 1 ? "Removed notification" : "Removed \(ids.count) notifications", "",
            nid: ids.count == 1 ? ids.first! : "")
        try? await Task.sleep(for: .milliseconds(150))
        await refreshDelivered()
    }

    func cancel(_ ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: Array(ids))
        ids.forEach { scheduled[$0] = nil }
        log(.removed, ids.count == 1 ? "Cancelled scheduled notification" : "Cancelled \(ids.count) scheduled")
        await refreshDelivered()
    }

    func removeAllDelivered() async {
        center.removeAllDeliveredNotifications()
        log(.removed, "Removed all delivered notifications")
        try? await Task.sleep(for: .milliseconds(150))
        await refreshDelivered()
    }

    func cancelAllPending() async {
        center.removeAllPendingNotificationRequests()
        scheduled.removeAll()
        log(.removed, "Cancelled all scheduled notifications")
        await refreshDelivered()
    }

    func clearBadge() async {
        try? await center.setBadgeCount(0)
        log(.info, "Cleared Dock badge")
    }

    func clearLog(template: UUID? = nil) {
        if let template { events.removeAll { $0.templateID == template } } else { events.removeAll() }
        lastError = nil
    }

    // MARK: Delegate callbacks

    fileprivate func didPresent(title: String, id: String, template: UUID?) {
        log(.presented, "Presented in foreground", "“\(title)”", templateID: template, templateName: name(of: template), nid: id)
    }

    fileprivate func didRespond(_ r: Response) {
        let tname = name(of: r.template)
        switch r.action {
        case UNNotificationDefaultActionIdentifier:
            log(.clicked, "Clicked “\(r.title)”", clickDescription(r), templateID: r.template, templateName: tname, nid: r.id)
            performClick(r)
        case UNNotificationDismissActionIdentifier:
            log(.dismissed, "Dismissed “\(r.title)”", "", templateID: r.template, templateName: tname, nid: r.id)
        case "reply":
            log(.reply, "Reply", r.replyText ?? "(empty)", templateID: r.template, templateName: tname, nid: r.id)
        default:
            let index = Int(r.action.split(separator: ".").last ?? "") ?? -1
            let name = r.actionTitles.indices.contains(index) ? r.actionTitles[index] : r.action
            log(.action, "Pressed “\(name)”", "on “\(r.title)”", templateID: r.template, templateName: tname, nid: r.id)
        }
    }

    private func name(of template: UUID?) -> String {
        template.flatMap { id in AppState.shared.templates.first { $0.id == id }?.name } ?? ""
    }

    private func clickDescription(_ r: Response) -> String {
        switch ClickAction(rawValue: r.click) ?? .none {
        case .none: "no click action"
        case .openURL: "open \(r.url ?? "")"
        case .activateApp: "activate \(r.bundleID ?? "")"
        case .runCommand: "$ \(r.command ?? "")"
        }
    }

    private func performClick(_ r: Response) {
        switch ClickAction(rawValue: r.click) ?? .none {
        case .none:
            break
        case .openURL:
            if let s = r.url, let url = URL(string: s), url.scheme != nil { NSWorkspace.shared.open(url) }
            else { log(.error, "Invalid URL", r.url ?? "") }
        case .activateApp:
            guard let id = r.bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                log(.error, "No app with bundle ID", r.bundleID ?? ""); return
            }
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        case .runCommand:
            if let cmd = r.command { run(cmd, template: r.template) }
        }
    }

    // MARK: Shell jobs (streamed)

    func run(_ command: String, template: UUID?) {
        let event = LogEvent(kind: .command, title: "$ \(command)", detail: "", templateID: template,
                             templateName: name(of: template))
        insert(event)
        jobs.append(Job(id: event.id, command: command))

        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.standardOutput = pipe
        p.standardError = pipe
        let eventID = event.id

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in NotificationService.shared.appendOutput(eventID, chunk) }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            Task { @MainActor in NotificationService.shared.finishJob(eventID, status: status) }
        }
        do { try p.run() } catch {
            finishJob(eventID, status: -1)
            log(.error, "Command failed to start", error.localizedDescription)
        }
    }

    private func appendOutput(_ id: UUID, _ chunk: String) {
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        events[i].detail = String((events[i].detail + chunk).suffix(4000))
        if let j = jobs.firstIndex(where: { $0.id == id }) {
            let line = chunk.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            if !line.isEmpty { jobs[j].lastLine = line }
        }
    }

    private func finishJob(_ id: UUID, status: Int32) {
        jobs.removeAll { $0.id == id }
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        events[i].detail = events[i].detail.trimmingCharacters(in: .whitespacesAndNewlines)
        events[i].detail += (events[i].detail.isEmpty ? "" : "\n") + "[exit \(status)]"
        if status != 0 { lastError = events[i] }
    }

    // MARK: Log

    func log(_ kind: LogEvent.Kind, _ title: String, _ detail: String = "", template: Template? = nil, nid: String = "") {
        log(kind, title, detail, templateID: template?.id, templateName: template?.name ?? "", nid: nid)
    }

    func log(_ kind: LogEvent.Kind, _ title: String, _ detail: String = "", templateID: UUID?,
             templateName: String, nid: String = "") {
        insert(LogEvent(kind: kind, title: title, detail: detail, templateID: templateID,
                        templateName: templateName, notificationID: nid))
    }

    /// Screenshot mode: inject a prepared event.
    func inject(_ e: LogEvent) { insert(e) }

    private func insert(_ e: LogEvent) {
        events.insert(e, at: 0)
        if e.kind == .error { lastError = e }
        if events.count > 1000 { events.removeLast(events.count - 1000) }
    }
}

// MARK: - Delegate

/// Plain values pulled out of a UNNotificationResponse so they can cross to the main actor.
fileprivate struct Response: Sendable {
    let id: String
    let action: String
    let title: String
    let template: UUID?
    let click: String
    let url: String?
    let bundleID: String?
    let command: String?
    let actionTitles: [String]
    let replyText: String?
}

private final class Delegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let req = notification.request
        let title = req.content.title
        let id = req.identifier
        let template = (req.content.userInfo["template"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in NotificationService.shared.didPresent(title: title, id: id, template: template) }
        // Show banners even while this app is frontmost — otherwise you'd never see them while testing.
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let req = response.notification.request
        let info = req.content.userInfo
        let r = Response(
            id: req.identifier,
            action: response.actionIdentifier,
            title: req.content.title,
            template: (info["template"] as? String).flatMap(UUID.init(uuidString:)),
            click: info["click"] as? String ?? ClickAction.none.rawValue,
            url: info["url"] as? String,
            bundleID: info["bundleID"] as? String,
            command: info["command"] as? String,
            actionTitles: info["actions"] as? [String] ?? [],
            replyText: (response as? UNTextInputNotificationResponse)?.userText
        )
        Task { @MainActor in NotificationService.shared.didRespond(r) }
        completionHandler()
    }
}
