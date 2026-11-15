import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import UserNotifications

// MARK: - Model

enum CheckStatus: Int, Comparable {
    case problem, warning, unknown, info, ok

    static func < (a: CheckStatus, b: CheckStatus) -> Bool { a.rawValue < b.rawValue }

    var symbol: String {
        switch self {
        case .problem: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        case .info: "info.circle"
        case .ok: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .problem: .red
        case .warning: .orange
        case .unknown: .secondary
        case .info: .secondary
        case .ok: .green
        }
    }

    var label: String {
        switch self {
        case .problem: "problem"
        case .warning: "warning"
        case .unknown: "can't check"
        case .info: "note"
        case .ok: "ok"
        }
    }
}

enum FixAction: Hashable {
    case openSettings(title: String, url: String)
    case requestPermission
    case sendTest
    case restartNotificationCenter
    case reveal(title: String, paths: [String])

    var title: String {
        switch self {
        case .openSettings(let t, _): t
        case .requestPermission: "Request Permission"
        case .sendTest: "Send Test Banner"
        case .restartNotificationCenter: "Restart Notification Center"
        case .reveal(let t, _): t
        }
    }

    var symbol: String {
        switch self {
        case .openSettings: "gearshape"
        case .requestPermission: "lock.open"
        case .sendTest: "paperplane"
        case .restartNotificationCenter: "arrow.clockwise"
        case .reveal: "folder"
        }
    }
}

struct DiagnosticCheck: Identifiable, Hashable {
    let id: String
    var title: String
    var status: CheckStatus
    var summary: String
    var why: String = ""
    var steps: [String] = []
    var actions: [FixAction] = []
    var evidence: [String] = []
    /// Whether this can stop a banner from sliding in (vs. sound/badge/listing issues).
    var affectsBanners = false
    /// Heuristic checks can be marked "not an issue" by the user.
    var acknowledgeable = false
}

enum SettingsURL {
    static var app: String {
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")"
    }
    static let notifications = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    static let focus = "x-apple.systempreferences:com.apple.Focus-Settings.extension"
    static let fullDiskAccess = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    static let screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    static let displays = "x-apple.systempreferences:com.apple.Displays-Settings.extension"
    static let sound = "x-apple.systempreferences:com.apple.Sound-Settings.extension"
}

// MARK: - Engine

@MainActor
@Observable
final class Diagnostics {
    static let shared = Diagnostics()

    enum TestState: Equatable { case idle, waiting, confirmed, guiding(step: Int) }

    private(set) var checks: [DiagnosticCheck] = []
    private(set) var isRunning = false
    private(set) var lastRun: Date?
    var testState: TestState = .idle
    var expanded: Set<String> = []

    private var storedAcknowledged: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "diag.acknowledged") ?? [])
    /// Checks the person marked "Not an Issue" (ignored in screenshot mode so captures show real states).
    var acknowledged: Set<String> { ScreenshotMode.isActive ? [] : storedAcknowledged }

    private init() {}

    /// Unacknowledged problems/warnings that can hide a banner.
    var blockers: [DiagnosticCheck] {
        checks.filter { $0.affectsBanners && ($0.status == .problem || $0.status == .warning) && !acknowledged.contains($0.id) }
    }

    var issueCount: Int {
        checks.filter { ($0.status == .problem || $0.status == .warning) && !acknowledged.contains($0.id) }.count
    }

    func isAcknowledged(_ id: String) -> Bool { acknowledged.contains(id) }

    var ignoredCount: Int { storedAcknowledged.count }

    func resetAcknowledged() {
        storedAcknowledged.removeAll()
        UserDefaults.standard.removeObject(forKey: "diag.acknowledged")
    }

    func toggleAcknowledged(_ id: String) {
        if storedAcknowledged.contains(id) { storedAcknowledged.remove(id) } else { storedAcknowledged.insert(id) }
        UserDefaults.standard.set(Array(storedAcknowledged), forKey: "diag.acknowledged")
    }

    func startMonitoring() {
        Task { await run() }
        Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { _ in
            Task { @MainActor in await Diagnostics.shared.run() }
        }
    }

    // MARK: Guided flow

    /// Ordered causes to walk through when the person says they didn't see the banner.
    var guideSteps: [DiagnosticCheck] {
        let detected = checks.filter { $0.affectsBanners && $0.status <= .warning }
            .sorted { $0.status < $1.status }
        let undetectable = checks.filter { $0.affectsBanners && ($0.status == .unknown || $0.status == .info) }
        return detected + undetectable + [Self.restartCheck]
    }

    func sendTest() {
        var t = Template()
        t.name = "Diagnostics"
        t.title = "Test banner"
        t.subtitle = "Notification Lab"
        t.message = "If you can see this slide in, banners are working."
        t.reportDismiss = false
        testState = .waiting
        Task { await NotificationService.shared.send(t, quiet: true) }
    }

    func perform(_ action: FixAction) {
        switch action {
        case .openSettings(_, let url):
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        case .requestPermission:
            Task { await NotificationService.shared.requestAuthorization(); await run() }
        case .sendTest:
            sendTest()
        case .restartNotificationCenter:
            // The agent relaunches itself immediately; this clears a stuck banner queue.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["NotificationCenter"]
            try? p.run()
            NotificationService.shared.log(.info, "Restarted Notification Center", "killall NotificationCenter")
        case .reveal(_, let paths):
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
        }
    }

    // MARK: Running checks

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; lastRun = .now }

        let svc = NotificationService.shared
        await svc.refreshSettings()

        async let processes = Self.processList()
        async let volume = Self.volumeSettings()
        let procs = await processes
        let vol = await volume

        var out: [DiagnosticCheck] = []
        out.append(permissionCheck(svc))
        out.append(alertStyleCheck(svc))
        out.append(captureCheck(procs))
        out.append(focusCheck())
        out.append(displaysCheck())
        out.append(templateLevelCheck())
        out.append(soundCheck(svc, vol))
        out.append(centerCheck(svc))
        out.append(duplicateCopiesCheck())
        out.append(foregroundCheck())
        out.append(summariesCheck())
        out.append(signingCheck())
        checks = out.sorted { $0.status < $1.status }
    }

    private func permissionCheck(_ s: NotificationService) -> DiagnosticCheck {
        var c = DiagnosticCheck(id: "permission", title: "Permission", status: .ok,
                                summary: "Notification Lab is allowed to post notifications", affectsBanners: true)
        switch s.authStatus {
        case .notDetermined:
            c.status = .problem
            c.summary = "Permission hasn't been requested yet"
            c.why = "macOS shows nothing until the app asks and you click Allow."
            c.steps = ["Click Request Permission.", "Choose Allow on the prompt (it appears as a notification at the top right)."]
            c.actions = [.requestPermission]
        case .denied:
            c.status = .problem
            c.summary = "Notifications are turned off for Notification Lab"
            c.why = "Requests are accepted but macOS silently drops them."
            c.steps = ["Open Notification Lab’s notification settings.", "Turn on Allow notifications."]
            c.actions = [.openSettings(title: "Open App Settings", url: SettingsURL.app)]
        case .provisional:
            c.status = .warning
            c.summary = "Provisional: delivered quietly to Notification Center only"
            c.why = "Provisional authorization never shows banners."
            c.steps = ["Open Notification Lab’s notification settings.", "Set the alert style to Banners or Alerts."]
            c.actions = [.openSettings(title: "Open App Settings", url: SettingsURL.app)]
        default: break
        }
        return c
    }

    private func alertStyleCheck(_ s: NotificationService) -> DiagnosticCheck {
        var c = DiagnosticCheck(id: "style", title: "Alert style", status: .ok, summary: "", affectsBanners: true)
        guard s.isAuthorized else { c.status = .info; c.summary = "Depends on permission"; return c }
        switch s.alertStyle {
        case .none:
            c.status = .problem
            c.summary = "Alert style is None, so notifications go straight to Notification Center"
            c.why = "With style None, macOS lists the notification but never slides it in."
            c.steps = ["Open Notification Lab’s notification settings.", "Choose Banners (auto-dismiss) or Alerts (stay until dismissed)."]
            c.actions = [.openSettings(title: "Open App Settings", url: SettingsURL.app)]
        case .banner:
            c.summary = "Banners: slide in, then dismiss after about 5 seconds"
            c.why = "To keep a notification on screen, which you need to try action buttons comfortably, switch to Alerts."
            c.actions = [.openSettings(title: "Change Style", url: SettingsURL.app)]
        case .alert:
            c.summary = "Alerts: stay on screen until dismissed"
        @unknown default:
            c.status = .unknown
            c.summary = "Unknown alert style"
        }
        if !s.alertEnabled && s.alertStyle != .none {
            c.status = .problem
            c.summary = "Alerts are disabled for Notification Lab"
            c.actions = [.openSettings(title: "Open App Settings", url: SettingsURL.app)]
        }
        return c
    }

    private func captureCheck(_ procs: [(pid: Int32, args: String)]) -> DiagnosticCheck {
        var c = DiagnosticCheck(id: "capture", title: "Screen sharing / capture", status: .ok,
                                summary: "No screen sharing, recording or mirroring detected",
                                affectsBanners: true, acknowledgeable: true)
        c.why = "While the screen is shared, mirrored or captured, macOS can hide banners so they don't leak into the stream. They still go to Notification Center. This is controlled by “Allow notifications when mirroring or sharing the display”."

        // (pattern in command line, friendly name, definitely capturing?)
        let known: [(String, String, Bool)] = [
            ("CptHost", "Zoom screen share", true),
            ("screensharingd", "Screen Sharing / Remote Management session", true),
            ("Rewind.app", "Rewind (continuous screen capture)", true),
            ("Tuple.app", "Tuple pair-programming share", false),
            ("obs.app/", "OBS Studio", false),
            ("OBS.app/", "OBS Studio", false),
            ("Loom.app", "Loom", false),
            ("CleanShot X.app", "CleanShot X", false),
            ("Screen Studio.app", "Screen Studio", false),
            ("Kap.app", "Kap", false),
            ("Microsoft Teams", "Microsoft Teams", false),
            ("Webex", "Webex", false),
        ]

        // Local additions: defaults write com.notificationlab.app diag.captureProcesses -array "my-recorder"
        let extra = (UserDefaults.standard.stringArray(forKey: "diag.captureProcesses") ?? []).map { ($0, $0, true) }
        let patterns = known + extra

        var definite: [String] = []
        var possible: [String] = []
        for p in procs {
            for (pattern, name, sure) in patterns where p.args.contains(pattern) {
                let line = "pid \(p.pid)  \(Self.shortCommand(p.args))"
                c.evidence.append(line)
                if sure { if !definite.contains(name) { definite.append(name) } }
                else if !possible.contains(name) { possible.append(name) }
                break
            }
        }

        // Hardware / AirPlay mirroring.
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        if ids.contains(where: { CGDisplayIsInMirrorSet($0) != 0 }) {
            definite.append("Display mirroring")
            c.evidence.append("CGDisplayIsInMirrorSet = true")
        }

        if ScreenshotMode.isActive {
            definite = ["Zoom screen share"]; possible = []
            c.evidence = ["pid 4821  CptHost -key 81f2… -share"]
        }

        let fixSteps = [
            "Open System Settings → Notifications.",
            "Turn on “Allow notifications when mirroring or sharing the display”.",
            "Or stop the share / recording, then send again.",
        ]
        if !definite.isEmpty {
            c.status = .problem
            c.summary = "Banners are likely hidden because of: " + definite.joined(separator: ", ")
            c.steps = fixSteps
            c.actions = [.openSettings(title: "Open Notification Settings", url: SettingsURL.notifications), .sendTest]
        } else if !possible.isEmpty {
            c.status = .warning
            c.summary = "Running: \(possible.joined(separator: ", ")). Banners hide if it's sharing or recording."
            c.steps = fixSteps
            c.actions = [.openSettings(title: "Open Notification Settings", url: SettingsURL.notifications),
                         .openSettings(title: "Screen Recording Apps", url: SettingsURL.screenRecording)]
        }
        return c
    }

    private func focusCheck() -> DiagnosticCheck {
        var c = DiagnosticCheck(id: "focus", title: "Focus / Do Not Disturb", status: .unknown,
                                summary: "macOS doesn't let apps read Focus state without Full Disk Access",
                                affectsBanners: true)
        c.why = "When a Focus is on (Do Not Disturb, Sleep, Work, Reduce Interruptions…), banners from apps that aren't allowed in that Focus go silently to Notification Center."
        c.steps = [
            "Look for the Focus icon (moon or person) in the menu bar, or open Control Center → Focus.",
            "Turn the Focus off, or add Notification Lab to its Allowed Apps.",
            "Also check Focus schedules: a Focus can turn on automatically by time or app.",
        ]
        c.actions = [.openSettings(title: "Open Focus Settings", url: SettingsURL.focus),
                     .openSettings(title: "Grant Full Disk Access", url: SettingsURL.fullDiskAccess)]

        let path = NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            c.steps.append("Optional: grant Full Disk Access to Notification Lab so this check runs automatically. You'll need to grant it again after each rebuild.")
            return c
        }
        c.actions.removeLast()
        let records = ((json["data"] as? [[String: Any]])?.first?["storeAssertionRecords"] as? [[String: Any]]) ?? []
        let modes = records.compactMap {
            ($0["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String
        }
        if modes.isEmpty {
            c.status = .ok
            c.summary = "No Focus is active"
            c.steps = []
        } else {
            c.status = .problem
            c.summary = "Focus is on: " + modes.map(Self.focusName).joined(separator: ", ")
            c.evidence = modes
        }
        return c
    }

    private static func focusName(_ id: String) -> String {
        let map = ["donotdisturb.mode.default": "Do Not Disturb", "sleep": "Sleep", "driving": "Driving",
                   "reduce-interruptions": "Reduce Interruptions", "work": "Work", "personal": "Personal",
                   "fitness": "Fitness", "gaming": "Gaming", "mindfulness": "Mindfulness", "reading": "Reading"]
        return map.first { id.contains($0.key) }?.value ?? id
    }

    private func displaysCheck() -> DiagnosticCheck {
        let screens = NSScreen.screens
        var c = DiagnosticCheck(id: "displays", title: "Displays", status: .ok,
                                summary: "One display: banners appear at its top right", affectsBanners: true)
        guard screens.count > 1, let main = screens.first else { return c }
        c.status = .info
        c.summary = "\(screens.count) displays: banners only appear on “\(main.localizedName)”"
        c.why = "Banners appear only on the display that has the menu bar. On other displays you'll only hear the sound."
        c.evidence = screens.map { "\($0.localizedName)  \(Int($0.frame.width))×\(Int($0.frame.height))\($0 == main ? "  ← menu bar" : "")" }
        c.steps = ["Look at the top right of “\(main.localizedName)”.",
                   "To move banners, open Displays → Arrange and drag the white menu bar onto another display."]
        if screens.contains(where: { $0.localizedName.lowercased().contains("hidden") || $0.localizedName.lowercased().contains("virtual") || $0.localizedName.lowercased().contains("dummy") }) {
            c.why += " A virtual display is connected (often from streaming or headless tools). If it becomes the main display, banners go somewhere you can't see."
        }
        c.actions = [.openSettings(title: "Open Displays", url: SettingsURL.displays)]
        return c
    }

    private func templateLevelCheck() -> DiagnosticCheck {
        var c = DiagnosticCheck(id: "level", title: "Template interruption level", status: .ok,
                                summary: "Current template uses a level that shows banners", affectsBanners: true)
        guard let t = AppState.shared.currentTemplate ?? AppState.shared.lastTemplate else {
            c.status = .info; c.summary = "No template selected"; return c
        }
        switch t.level {
        case .passive:
            c.status = .warning
            c.summary = "“\(t.name)” is Passive. Passive notifications never show a banner, by design."
            c.steps = ["Set Interruption to Active in the template editor."]
        case .timeSensitive, .critical:
            c.status = .info
            c.summary = "“\(t.name)” is \(t.level.label). This build delivers it as Active."
            c.why = "Time Sensitive and Critical need Apple-issued entitlements. Without them they won't break through Focus."
        case .active: break
        }
        return c
    }

    private func soundCheck(_ s: NotificationService, _ vol: (muted: Bool, alert: Int)?) -> DiagnosticCheck {
        var c = DiagnosticCheck(id: "sound", title: "Sound", status: .ok, summary: "Notification sounds are enabled")
        if !s.soundEnabled && s.isAuthorized {
            c.status = .warning
            c.summary = "Sounds are turned off for Notification Lab"
            c.steps = ["Open Notification Lab’s notification settings.", "Turn on Play sound for notifications."]
            c.actions = [.openSettings(title: "Open App Settings", url: SettingsURL.app)]
        } else if let vol, vol.muted {
            c.status = .warning
            c.summary = "System output is muted"
            c.steps = ["Unmute with the volume key or Control Center → Sound."]
            c.actions = [.openSettings(title: "Open Sound Settings", url: SettingsURL.sound)]
        } else if let vol, vol.alert == 0 {
            c.status = .warning
            c.summary = "Alert volume is 0. Notification sounds are silent even though media plays."
            c.why = "macOS has a separate alert volume for system and notification sounds."
            c.steps = ["Open Sound settings.", "Raise Alert volume."]
            c.actions = [.openSettings(title: "Open Sound Settings", url: SettingsURL.sound)]
        } else if let vol {
            c.summary = "Sounds enabled · alert volume \(vol.alert)%"
        }
        return c
    }

    private func centerCheck(_ s: NotificationService) -> DiagnosticCheck {
        var c = DiagnosticCheck(id: "center", title: "Notification Center listing", status: .ok,
                                summary: "Notifications are kept in Notification Center")
        if s.isAuthorized && !s.centerEnabled {
            c.status = .warning
            c.summary = "Show in Notification Center is off, so missed banners vanish"
            c.steps = ["Open Notification Lab’s notification settings.", "Turn on Show in Notification Center."]
            c.actions = [.openSettings(title: "Open App Settings", url: SettingsURL.app)]
        }
        return c
    }

    private func duplicateCopiesCheck() -> DiagnosticCheck {
        let id = Bundle.main.bundleIdentifier ?? ""
        let urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
        var c = DiagnosticCheck(id: "copies", title: "App copies", status: .ok,
                                summary: "One copy of Notification Lab is registered")
        guard urls.count > 1 else { return c }
        c.status = .warning
        c.summary = "\(urls.count) copies share the bundle ID \(id)"
        c.why = "macOS keeps notification settings per bundle ID, but each ad-hoc-signed copy is a different app to the privacy system. You may change settings for one copy while running another, and old copies can be launched when you click a notification."
        c.evidence = urls.map(\.path)
        c.steps = ["Delete copies you don't use (old builds, copies in Downloads or temp folders).", "Keep one copy, ideally in /Applications."]
        c.actions = [.reveal(title: "Reveal Copies", paths: urls.map(\.path))]
        c.acknowledgeable = true
        return c
    }

    private func foregroundCheck() -> DiagnosticCheck {
        DiagnosticCheck(id: "foreground", title: "Foreground presentation", status: .ok,
                        summary: "Banners show even while Notification Lab is the active app",
                        why: "By default macOS hides banners from the app you're using. Notification Lab opts in to showing them.")
    }

    private func summariesCheck() -> DiagnosticCheck {
        DiagnosticCheck(id: "summaries", title: "Notification summaries & priority", status: .info,
                        summary: "If summaries or prioritization are on, some banners may be held back",
                        why: "Newer macOS versions can summarize or deprioritize notifications they consider low-priority. Repetitive test notifications are especially likely to be grouped. This isn't readable by apps.",
                        steps: ["Open System Settings → Notifications.", "Check Summarize Notifications / Prioritize Notifications and exclude Notification Lab."],
                        actions: [.openSettings(title: "Open Notification Settings", url: SettingsURL.notifications)],
                        affectsBanners: true)
    }

    private func signingCheck() -> DiagnosticCheck {
        DiagnosticCheck(id: "signing", title: "Code signing", status: .info,
                        summary: "Ad-hoc signed: Time Sensitive and Critical can't break through Focus",
                        why: "Those levels need Apple-issued entitlements. Signing with a Developer ID and provisioning profile enables Time Sensitive.")
    }

    static let restartCheck = DiagnosticCheck(
        id: "restart", title: "Notification Center is stuck", status: .unknown,
        summary: "Sometimes the system notification service stops showing banners until it restarts",
        why: "It's rare, but after sleep/wake or display changes the agent can stop presenting banners while still filing them in Notification Center.",
        steps: ["Click Restart Notification Center. It relaunches instantly and nothing is lost.", "Send the test again.", "If it still fails, log out and back in."],
        actions: [.restartNotificationCenter, .sendTest],
        affectsBanners: true)

    // MARK: System probes (off the main thread)

    /// "/Apps/Foo Bar.app/Contents/MacOS/foo --flag" → "foo --flag"
    private static func shortCommand(_ args: String) -> String {
        let s: String
        if let r = args.range(of: ".app/Contents/MacOS/") { s = String(args[r.upperBound...]) }
        else { s = (args as NSString).lastPathComponent }
        return s.count > 80 ? String(s.prefix(79)) + "…" : s
    }

    nonisolated private static func processList() async -> [(pid: Int32, args: String)] {
        await Task.detached {
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-axo", "pid=,args="]
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]) else { return nil }
                return (pid, String(t[sp...]).trimmingCharacters(in: .whitespaces))
            }
        }.value
    }

    nonisolated private static func volumeSettings() async -> (muted: Bool, alert: Int)? {
        await Task.detached {
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "set v to get volume settings", "-e",
                           "return ((output muted of v) as text) & \",\" & ((alert volume of v) as text)"]
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            p.waitUntilExit()
            let parts = out.split(separator: ",")
            guard parts.count == 2, let alert = Int(parts[1]) else { return nil }
            return (parts[0] == "true", alert)
        }.value
    }
}
