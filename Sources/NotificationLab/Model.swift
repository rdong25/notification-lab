import AppKit
import Foundation
import SwiftUI
import UserNotifications

// MARK: - Enums

enum ClickAction: String, CaseIterable, Identifiable, Codable {
    case none, openURL, activateApp, runCommand

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .openURL: "URL"
        case .activateApp: "App"
        case .runCommand: "Shell"
        }
    }
}

enum Level: String, CaseIterable, Identifiable, Codable {
    case passive, active, timeSensitive, critical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .passive: "Passive"
        case .active: "Active"
        case .timeSensitive: "Time-sens."
        case .critical: "Critical"
        }
    }

    var un: UNNotificationInterruptionLevel {
        switch self {
        case .passive: .passive
        case .active: .active
        case .timeSensitive: .timeSensitive
        case .critical: .critical
        }
    }
}

struct ActionButton: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var destructive = false
    /// Optional SF Symbol; macOS draws it on the trailing side of the action title.
    var symbol = ""

    /// Apple HIG: a notification offers at most four actions.
    static let maxCount = 4

    static let symbols = ["checkmark", "xmark", "clock", "bell.slash", "arrowshape.turn.up.left", "star",
                          "trash", "archivebox", "eye", "video", "phone", "calendar", "flag", "hand.thumbsup"]

    init(title: String, destructive: Bool = false, symbol: String = "") {
        self.title = title; self.destructive = destructive; self.symbol = symbol
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        destructive = try c.decodeIfPresent(Bool.self, forKey: .destructive) ?? false
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? ""
    }
}

enum SoundChoice {
    static let none = "none"
    static let standard = "default"

    static let system: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return names.map { ($0 as NSString).deletingPathExtension }.sorted()
    }()

    static func preview(_ name: String) {
        switch name {
        case none: return
        case standard: NSSound.beep()
        default: NSSound(named: NSSound.Name(name))?.play()
        }
    }
}

// MARK: - Template

struct Template: Identifiable, Hashable, Codable {
    var id = UUID()
    var name = "Untitled"
    var symbol = "bell"

    var title = "Build finished"
    var subtitle = "notification-lab · main"
    var message = "All 128 tests passed in 14.2s."

    var sound = SoundChoice.standard
    var level: Level = .active

    var groupID = ""
    var threadID = ""
    var delay: Double = 0
    var repeatCount = 1
    var badgeEnabled = false
    var badge = 1

    var clickAction: ClickAction = .none
    var url = "https://example.com"
    var bundleID = "com.apple.Terminal"
    var command = "say \"notification clicked\""

    var actionsEnabled = false
    var actions: [ActionButton] = [ActionButton(title: "View"), ActionButton(title: "Snooze")]
    var replyEnabled = false
    var replyButtonTitle = "Reply"
    var replyPlaceholder = "Type a reply…"
    var reportDismiss = true

    var imagePath: String?

    var imageURL: URL? { imagePath.map { URL(fileURLWithPath: $0) } }
    var image: NSImage? { imagePath.flatMap { NSImage(contentsOfFile: $0) } }

    static let symbols = ["bell", "bell.badge", "link", "rectangle.split.2x1", "text.bubble", "arrow.triangle.2.circlepath",
                          "timer", "square.stack.3d.up", "speaker.slash", "hammer", "exclamationmark.triangle",
                          "envelope", "calendar", "checkmark.seal", "terminal", "photo"]

    /// Short descriptor shown in the sidebar and header.
    var traits: [String] {
        var t: [String] = []
        if delay > 0 { t.append("\(Int(delay))s") }
        if repeatCount > 1 { t.append("×\(repeatCount)") }
        if !groupID.isEmpty { t.append("grp") }
        if actionsEnabled || replyEnabled { t.append("btn") }
        if clickAction != .none { t.append(clickAction.label.lowercased()) }
        return t
    }

    // MARK: Defaults

    static var defaults: [Template] {
        var basic = Template(name: "Basic", symbol: "bell")

        var url = Template(name: "Open URL on click", symbol: "link")
        url.title = "Pull request approved"
        url.subtitle = "#482 · Add notification tester"
        url.message = "Click to open it in your browser."
        url.clickAction = .openURL

        var actions = Template(name: "Action buttons", symbol: "rectangle.split.2x1")
        actions.title = "Meeting in 5 minutes"
        actions.subtitle = "Design review"
        actions.message = "Zoom link is in the invite."
        actions.actionsEnabled = true
        actions.actions = [ActionButton(title: "Join", symbol: "video"), ActionButton(title: "Snooze", symbol: "clock"),
                           ActionButton(title: "Decline", destructive: true, symbol: "xmark")]

        var reply = Template(name: "Inline reply", symbol: "text.bubble")
        reply.title = "Alex"
        reply.subtitle = ""
        reply.message = "Are we still on for lunch?"
        reply.replyEnabled = true
        reply.sound = "Glass"

        var replace = Template(name: "Replace by group", symbol: "arrow.triangle.2.circlepath")
        replace.title = "Uploading…"
        replace.subtitle = "video-final.mov"
        replace.message = "Send repeatedly — each one replaces the last."
        replace.groupID = "upload-progress"
        replace.sound = SoundChoice.none

        var delayed = Template(name: "Delayed 5 s", symbol: "timer")
        delayed.title = "Reminder"
        delayed.subtitle = ""
        delayed.message = "Switch apps — this arrives in 5 seconds."
        delayed.delay = 5

        var burst = Template(name: "Burst of 5", symbol: "square.stack.3d.up")
        burst.title = "New message"
        burst.subtitle = ""
        burst.message = "Testing how notifications stack."
        burst.repeatCount = 5
        burst.threadID = "burst"

        var silent = Template(name: "Passive, silent", symbol: "speaker.slash")
        silent.title = "Background sync complete"
        silent.subtitle = ""
        silent.message = "Delivered quietly to Notification Center."
        silent.level = .passive
        silent.sound = SoundChoice.none

        basic.name = "Basic"
        return [basic, url, actions, reply, replace, delayed, burst, silent]
    }

    // MARK: Derived request description

    var categorySignature: String {
        var parts: [String] = []
        if actionsEnabled { parts += actions.prefix(ActionButton.maxCount).map { "\($0.title)\($0.destructive ? "!" : "")@\($0.symbol)" } }
        if replyEnabled { parts.append("reply:\(replyButtonTitle):\(replyPlaceholder)") }
        parts.append(reportDismiss ? "dismiss" : "nodismiss")
        return parts.joined(separator: "|")
    }

    var soundFile: String {
        switch sound {
        case SoundChoice.none: "—"
        case SoundChoice.standard: "default"
        default: "\(sound).aiff"
        }
    }

    var userInfo: [String: Any] {
        var info: [String: Any] = ["click": clickAction.rawValue, "template": id.uuidString]
        switch clickAction {
        case .none: break
        case .openURL: info["url"] = url
        case .activateApp: info["bundleID"] = bundleID
        case .runCommand: info["command"] = command
        }
        info["actions"] = actionsEnabled ? actions.map(\.title) : [String]()
        return info
    }

    var userInfoJSON: String {
        guard let data = try? JSONSerialization.data(withJSONObject: userInfo, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// The Swift code that produces this exact notification with UserNotifications.
    var swiftSnippet: String {
        func lit(_ v: String) -> String {
            "\"" + v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n") + "\""
        }

        var out: [String] = ["import UserNotifications", ""]
        let center = "UNUserNotificationCenter.current()"
        let hasCategory = actionsEnabled || replyEnabled || reportDismiss

        if hasCategory {
            var acts: [String] = []
            if actionsEnabled {
                for (i, a) in actions.prefix(ActionButton.maxCount).enumerated() where !a.title.isEmpty {
                    let icon = a.symbol.isEmpty ? "" : ",\n                          icon: UNNotificationActionIcon(systemImageName: \(lit(a.symbol)))"
                    acts.append("    UNNotificationAction(identifier: \"action.\(i)\", title: \(lit(a.title)), options: \(a.destructive ? "[.destructive]" : "[]")\(icon)),")
                }
            }
            if replyEnabled {
                acts.append("    UNTextInputNotificationAction(identifier: \"reply\", title: \(lit(replyButtonTitle)), options: [],")
                acts.append("                                  textInputButtonTitle: \"Send\", textInputPlaceholder: \(lit(replyPlaceholder))),")
            }
            out.append("let category = UNNotificationCategory(")
            out.append("  identifier: \"lab.category\",")
            if acts.isEmpty {
                out.append("  actions: [],")
            } else {
                out.append("  actions: [")
                out += acts.map { "  " + $0 }
                out.append("  ],")
            }
            out.append("  intentIdentifiers: [],")
            out.append("  options: \(reportDismiss ? "[.customDismissAction]" : "[]"))")
            out.append("\(center).setNotificationCategories([category])")
            out.append("")
        }

        out.append("let content = UNMutableNotificationContent()")
        if !title.isEmpty { out.append("content.title = \(lit(title))") }
        if !subtitle.isEmpty { out.append("content.subtitle = \(lit(subtitle))") }
        out.append("content.body = \(lit(message))")
        switch sound {
        case SoundChoice.none: break
        case SoundChoice.standard: out.append("content.sound = .default")
        default: out.append("content.sound = UNNotificationSound(named: .init(\"\(sound).aiff\"))")
        }
        if level != .active { out.append("content.interruptionLevel = .\(level.rawValue)") }
        if !threadID.isEmpty { out.append("content.threadIdentifier = \(lit(threadID))") }
        if badgeEnabled { out.append("content.badge = \(badge)") }
        if hasCategory { out.append("content.categoryIdentifier = \"lab.category\"") }
        switch clickAction {
        case .none: break
        case .openURL: out.append("content.userInfo = [\"url\": \(lit(url))]")
        case .activateApp: out.append("content.userInfo = [\"bundleID\": \(lit(bundleID))]")
        case .runCommand: out.append("content.userInfo = [\"command\": \(lit(command))]")
        }
        if let imagePath {
            out.append("content.attachments = [try UNNotificationAttachment(")
            out.append("  identifier: \"image\", url: URL(fileURLWithPath: \(lit(imagePath))))]")
        }
        out.append("")

        let trigger = delay > 0 ? "UNTimeIntervalNotificationTrigger(timeInterval: \(Int(delay)), repeats: false)" : "nil"
        let ident = groupID.isEmpty ? "UUID().uuidString" : lit(groupID)
        if repeatCount > 1 {
            out.append("for _ in 0..<\(repeatCount) {")
            out.append("  let request = UNNotificationRequest(identifier: \(ident), content: content, trigger: \(trigger))")
            out.append("  try await \(center).add(request)")
            out.append("}")
        } else {
            out.append("let request = UNNotificationRequest(identifier: \(ident), content: content, trigger: \(trigger))")
            out.append("try await \(center).add(request)")
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Log / state records

struct LogEvent: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case sent, scheduled, delivered, presented, clicked, action, reply, dismissed, removed, command, info, warning, error

        var symbol: String {
            switch self {
            case .sent: "arrow.up.right"
            case .scheduled: "clock"
            case .delivered: "tray.and.arrow.down"
            case .presented: "macwindow"
            case .clicked: "cursorarrow.click"
            case .action: "hand.point.up.left"
            case .reply: "text.bubble"
            case .dismissed: "xmark"
            case .removed: "trash"
            case .command: "terminal"
            case .info: "info.circle"
            case .warning: "exclamationmark.triangle"
            case .error: "exclamationmark.triangle"
            }
        }

        var tint: Color {
            switch self {
            case .sent, .delivered, .presented: .secondary
            case .scheduled, .warning: .orange
            case .clicked, .action, .reply: .accentColor
            case .command: .secondary
            case .dismissed, .removed, .info: .secondary
            case .error: .red
            }
        }

        var isInteraction: Bool { [.clicked, .action, .reply, .dismissed].contains(self) }
    }

    let id = UUID()
    var date = Date()
    let kind: Kind
    var title: String
    var detail: String = ""
    var templateID: UUID?
    var templateName: String = ""
    var notificationID: String = ""
}

struct DeliveredItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let body: String
    let thread: String
    let category: String
    let date: Date
}

struct PendingItem: Identifiable, Hashable {
    let id: String
    let title: String
    let fireDate: Date
    let interval: TimeInterval
}

struct Job: Identifiable {
    let id: UUID          // matches the LogEvent it streams into
    let command: String
    var lastLine = ""
    let started = Date()
}

// MARK: - Theme

enum Theme {
    static let mono = Font.system(size: 11, design: .monospaced)
    static let monoBody = Font.system(size: 12, design: .monospaced)
    static let label = Font.system(size: 12)
    static let header = Font.system(size: 11, weight: .semibold)

    static let surface = Color(nsColor: .controlBackgroundColor)
    static let mutedSurface = Color.primary.opacity(0.045)
    static let border = Color(nsColor: .separatorColor)
}
