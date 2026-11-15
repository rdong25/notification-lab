import AppKit
import Foundation
import Observation
import SwiftUI

enum SidebarItem: Hashable {
    case activity, delivered, scheduled, diagnostics
    case template(UUID)
}

/// UI state + template library (persisted to Application Support).
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var templates: [Template] = [] {
        didSet { if persistenceEnabled { scheduleSave() } }
    }
    /// Screenshot mode swaps in demo templates and must never overwrite the user's library.
    var persistenceEnabled = true
    /// Text the command palette opens with.
    var paletteSeed = ""
    /// Set by the root view (SwiftUI only exposes openSettings through the environment).
    var openSettingsAction: (() -> Void)?

    func revealTemplatesFile() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
    var selection: SidebarItem? = nil {
        didSet { if case .template(let id) = selection { lastTemplateID = id } }
    }
    private(set) var lastTemplateID: UUID?
    var lastTemplate: Template? { lastTemplateID.flatMap { id in templates.first { $0.id == id } } }
    var showInspector = true
    var showHistory = true
    var showPalette = false
    var renamingID: UUID?
    var sidebarFilter = ""

    var selectedEvent: LogEvent.ID?
    var selectedDelivered: Set<DeliveredItem.ID> = []
    var selectedPending: Set<PendingItem.ID> = []

    private var saveTask: Task<Void, Never>?

    private init() {
        templates = load() ?? Template.defaults
        selection = templates.first.map { .template($0.id) }
        lastTemplateID = templates.first?.id // didSet doesn't run inside init
    }

    // MARK: Template access

    var currentTemplateID: UUID? {
        if case .template(let id) = selection { return id }
        return nil
    }

    var currentTemplate: Template? {
        currentTemplateID.flatMap { id in templates.first { $0.id == id } }
    }

    func index(of id: UUID) -> Int? { templates.firstIndex { $0.id == id } }

    func binding(for id: UUID) -> Binding<Template>? {
        guard index(of: id) != nil else { return nil }
        return Binding(
            get: { self.templates.first { $0.id == id } ?? Template() },
            set: { new in if let i = self.index(of: id) { self.templates[i] = new } }
        )
    }

    // MARK: Template commands

    func newTemplate() {
        var t = Template()
        t.name = uniqueName("New Template")
        templates.append(t)
        selection = .template(t.id)
        renamingID = t.id
    }

    func duplicate(_ id: UUID? = nil) {
        guard let id = id ?? currentTemplateID, let i = index(of: id) else { return }
        var copy = templates[i]
        copy.id = UUID()
        copy.name = uniqueName(copy.name + " copy")
        templates.insert(copy, at: i + 1)
        selection = .template(copy.id)
    }

    func delete(_ id: UUID) {
        guard let i = index(of: id) else { return }
        templates.remove(at: i)
        if currentTemplateID == id {
            let next = templates.indices.contains(i) ? templates[i] : templates.last
            selection = next.map { .template($0.id) } ?? .activity
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        templates.move(fromOffsets: source, toOffset: destination)
    }

    func restoreDefaults() {
        templates.append(contentsOf: Template.defaults.map { t in
            var t = t; t.id = UUID(); t.name = uniqueName(t.name); return t
        })
    }

    func send(_ id: UUID? = nil) {
        guard let id = id ?? currentTemplateID, let t = templates.first(where: { $0.id == id }) else {
            NotificationService.shared.log(.info, "Select a template to send")
            return
        }
        Task { await NotificationService.shared.send(t) }
    }

    func copySnippet() {
        guard let t = currentTemplate else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t.swiftSnippet, forType: .string)
        NotificationService.shared.log(.info, "Copied Swift snippet", t.name)
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(templates.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Persistence

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotificationLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("templates.json")
    }

    private func load() -> [Template]? {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Template].self, from: data), !list.isEmpty else { return nil }
        return list
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = templates
        let url = fileURL
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(snapshot).write(to: url, options: .atomic)
        }
    }

    // MARK: Command palette

    struct PaletteCommand: Identifiable {
        enum Section: String { case actions = "Actions", templates = "Templates", navigate = "Go to" }
        let id: String
        let section: Section
        let title: String
        let symbol: String
        var shortcut: String = ""
        var detail: String = ""
        let run: @MainActor () -> Void
    }

    var paletteCommands: [PaletteCommand] {
        let svc = NotificationService.shared
        var list: [PaletteCommand] = []

        if let t = currentTemplate {
            list.append(.init(id: "send", section: .actions, title: "Send “\(t.name)”", symbol: "paperplane",
                              shortcut: "⌘↩") { self.send() })
            list.append(.init(id: "copy", section: .actions, title: "Copy Swift Snippet", symbol: "chevron.left.forwardslash.chevron.right",
                              shortcut: "⇧⌘C") { self.copySnippet() })
            list.append(.init(id: "dup", section: .actions, title: "Duplicate Template", symbol: "plus.square.on.square",
                              shortcut: "⌘D") { self.duplicate() })
            list.append(.init(id: "rename", section: .actions, title: "Rename Template", symbol: "pencil") {
                self.renamingID = t.id
            })
        }
        list.append(.init(id: "new", section: .actions, title: "New Template", symbol: "plus", shortcut: "⌘N") { self.newTemplate() })
        list.append(.init(id: "removeAll", section: .actions, title: "Remove All Delivered", symbol: "trash",
                          shortcut: "⇧⌘⌫") { Task { await svc.removeAllDelivered() } })
        list.append(.init(id: "cancelAll", section: .actions, title: "Cancel All Scheduled", symbol: "clock.badge.xmark") {
            Task { await svc.cancelAllPending() }
        })
        list.append(.init(id: "badge", section: .actions, title: "Clear Dock Badge", symbol: "app.badge") {
            Task { await svc.clearBadge() }
        })
        list.append(.init(id: "clearLog", section: .actions, title: "Clear Activity Log", symbol: "eraser", shortcut: "⌥⌘K") {
            svc.clearLog()
        })
        list.append(.init(id: "inspector", section: .actions, title: showInspector ? "Hide Inspector" : "Show Inspector",
                          symbol: "sidebar.right", shortcut: "⌥⌘I") { self.showInspector.toggle() })
        list.append(.init(id: "history", section: .actions, title: showHistory ? "Hide History Pane" : "Show History Pane",
                          symbol: "rectangle.bottomthird.inset.filled", shortcut: "⇧⌘Y") { self.showHistory.toggle() })
        list.append(.init(id: "perm", section: .actions, title: "Request Notification Permission", symbol: "lock.open") {
            Task { await svc.requestAuthorization() }
        })
        list.append(.init(id: "settings", section: .actions, title: "Open Notification Settings", symbol: "gearshape") {
            svc.openSystemSettings()
        })
        list.append(.init(id: "defaults", section: .actions, title: "Add Default Templates", symbol: "square.grid.2x2") {
            self.restoreDefaults()
        })

        list.append(.init(id: "diag.run", section: .actions, title: "Run Diagnostics", symbol: "stethoscope",
                          shortcut: "⌘R") { self.selection = .diagnostics; Task { await Diagnostics.shared.run() } })
        list.append(.init(id: "diag.test", section: .actions, title: "Send Test Banner", symbol: "rectangle.badge.checkmark") {
            self.selection = .diagnostics; Diagnostics.shared.sendTest()
        })
        list.append(.init(id: "diag.restart", section: .actions, title: "Restart Notification Center", symbol: "arrow.clockwise") {
            Diagnostics.shared.perform(.restartNotificationCenter)
        })
        list.append(.init(id: "cli.install", section: .actions,
                          title: CLIInstaller.shared.isInstalled ? "Reinstall Command Line Tool" : "Install Command Line Tool",
                          symbol: "terminal") { Task { await CLIInstaller.shared.install() } })
        list.append(.init(id: "settings.open", section: .actions, title: "Settings…", symbol: "gearshape",
                          shortcut: "⌘,") { self.openSettingsAction?() })
        list.append(.init(id: "go.diagnostics", section: .navigate, title: "Diagnostics", symbol: "stethoscope",
                          shortcut: "⌘4", detail: Diagnostics.shared.issueCount > 0 ? "\(Diagnostics.shared.issueCount) issues" : "") {
            self.selection = .diagnostics
        })
        list.append(.init(id: "go.activity", section: .navigate, title: "Activity", symbol: "list.bullet.rectangle",
                          shortcut: "⌘1") { self.selection = .activity })
        list.append(.init(id: "go.delivered", section: .navigate, title: "Notification Center", symbol: "tray.full",
                          shortcut: "⌘2", detail: "\(svc.delivered.count)") { self.selection = .delivered })
        list.append(.init(id: "go.scheduled", section: .navigate, title: "Scheduled", symbol: "clock",
                          shortcut: "⌘3", detail: "\(svc.pending.count)") { self.selection = .scheduled })

        for t in templates {
            list.append(.init(id: "t.\(t.id)", section: .templates, title: t.name, symbol: t.symbol,
                              detail: t.traits.joined(separator: " ")) { self.selection = .template(t.id) })
            list.append(.init(id: "ts.\(t.id)", section: .templates, title: "Send \(t.name)", symbol: "paperplane",
                              detail: t.title) { self.send(t.id) })
        }
        return list
    }
}
