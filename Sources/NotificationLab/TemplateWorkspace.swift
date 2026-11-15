import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TemplateWorkspace: View {
    @Environment(AppState.self) private var state
    @Binding var template: Template

    var body: some View {
        if state.showHistory {
            VSplitView {
                TemplateEditor(template: $template)
                    .frame(minHeight: 220, maxHeight: .infinity)
                TemplateHistory(templateID: template.id)
                    .frame(minHeight: 96, idealHeight: 210, maxHeight: .infinity)
            }
        } else {
            TemplateEditor(template: $template)
        }
    }
}

// MARK: - Editor

private struct TemplateEditor: View {
    @Environment(NotificationService.self) private var service
    @Binding var template: Template
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let blocker = Diagnostics.shared.blockers.first { blockerBanner(blocker).padding(.bottom, 10) }
                Divider()
                content
                Divider()
                presentation
                Divider()
                delivery
                Divider()
                clickAction
                Divider()
                buttons
                Divider()
                attachment
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(Color.accentColor.opacity(0.04))
                    .overlay(Text("Drop image to attach").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, NSImage(contentsOf: url) != nil else { return false }
            template.imagePath = url.path
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Menu {
                ForEach(Template.symbols, id: \.self) { s in
                    Button { template.symbol = s } label: { Label(s, systemImage: s) }
                }
            } label: {
                Image(systemName: template.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 0.5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change icon")

            VStack(alignment: .leading, spacing: 2) {
                TextField("Template name", text: $template.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                Text(meta)
                    .font(Theme.mono)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 12)
    }

    /// Apple HIG content guidance for titles.
    private var titleIssue: String? {
        let t = template.title.trimmingCharacters(in: .whitespaces)
        if let last = t.last, ".!?:;,".contains(last) { return "Apple HIG: titles use title case and no ending punctuation." }
        if t.localizedCaseInsensitiveContains("Notification Lab") {
            return "Apple HIG: don't include the app name. macOS already shows the app icon."
        }
        return nil
    }

    private var meta: String {
        let events = service.events.filter { $0.templateID == template.id }
        let sent = events.filter { $0.kind == .sent || $0.kind == .scheduled }.count
        let inter = events.filter { $0.kind.isInteraction }.count
        return "\(template.id.uuidString.prefix(8).lowercased()) · \(sent) sent · \(inter) interactions"
    }

    private func blockerBanner(_ c: DiagnosticCheck) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Banners will probably be hidden: \(c.title)").font(.system(size: 11.5, weight: .medium))
                Text(c.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Diagnose") { AppState.shared.selection = .diagnostics }
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5))
    }

    // MARK: Sections

    private var content: some View {
        EditorSection("Content") {
            FieldRow("Title") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: $template.title, prompt: Text("Title (app name is shown if empty)"))
                        .textFieldStyle(.roundedBorder)
                    if let issue = titleIssue { hint(issue) }
                }
            }
            FieldRow("Subtitle") {
                TextField("", text: $template.subtitle, prompt: Text("Optional"))
                    .textFieldStyle(.roundedBorder)
            }
            FieldRow("Message", alignment: .top) {
                TextField("", text: $template.message, prompt: Text("Body"), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
            }
        }
    }

    private var presentation: some View {
        EditorSection("Presentation") {
            FieldRow("Sound") {
                HStack(spacing: 6) {
                    Picker("", selection: $template.sound) {
                        Text("None").tag(SoundChoice.none)
                        Text("Default").tag(SoundChoice.standard)
                        Divider()
                        ForEach(SoundChoice.system, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Button {
                        SoundChoice.preview(template.sound)
                    } label: {
                        Image(systemName: "play.fill").font(.system(size: 9))
                    }
                    .disabled(template.sound == SoundChoice.none)
                    .help("Preview sound")
                }
            }
            FieldRow("Interruption") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $template.level) {
                        ForEach(Level.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if template.level == .timeSensitive || template.level == .critical {
                        hint("Needs an Apple-granted entitlement; this ad-hoc build is delivered as Active.")
                    }
                }
            }
            FieldRow("Badge") {
                HStack(spacing: 8) {
                    Toggle("", isOn: $template.badgeEnabled).labelsHidden().toggleStyle(.checkbox)
                    if template.badgeEnabled {
                        TextField("", value: $template.badge, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.monoBody)
                            .frame(width: 56)
                        Stepper("", value: $template.badge, in: 0...999).labelsHidden()
                    } else {
                        Text("Off").font(Theme.label).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var delivery: some View {
        EditorSection("Delivery") {
            FieldRow("Group ID") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: $template.groupID, prompt: Text("auto (unique per send)"))
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.monoBody)
                    hint("Sending again with the same ID replaces the previous notification instead of stacking.")
                }
            }
            FieldRow("Thread") {
                TextField("", text: $template.threadID, prompt: Text("none"))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.monoBody)
            }
            FieldRow("Delay") {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { template.delay }, set: { template.delay = $0.rounded() }), in: 0...60)
                        .frame(maxWidth: 220)
                    Text(template.delay == 0 ? "immediate" : "\(Int(template.delay))s")
                        .font(Theme.mono)
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                }
            }
            FieldRow("Repeat") {
                HStack(spacing: 8) {
                    Stepper("", value: $template.repeatCount, in: 1...20).labelsHidden()
                    Text("×\(template.repeatCount)")
                        .font(Theme.mono)
                        .foregroundStyle(.secondary)
                    if template.repeatCount > 1 {
                        hint(template.groupID.isEmpty ? "Sent 0.4s apart." : "Same group ID — each replaces the last.")
                    }
                }
            }
        }
    }

    private var clickAction: some View {
        EditorSection("On click") {
            FieldRow("Action") {
                Picker("", selection: $template.clickAction) {
                    ForEach(ClickAction.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            switch template.clickAction {
            case .none:
                EmptyView()
            case .openURL:
                FieldRow("URL") {
                    TextField("", text: $template.url, prompt: Text("https://"))
                        .textFieldStyle(.roundedBorder).font(Theme.monoBody)
                }
            case .activateApp:
                FieldRow("Bundle ID") {
                    TextField("", text: $template.bundleID, prompt: Text("com.apple.Safari"))
                        .textFieldStyle(.roundedBorder).font(Theme.monoBody)
                }
            case .runCommand:
                FieldRow("Command") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $template.command, prompt: Text("zsh -lc …"))
                            .textFieldStyle(.roundedBorder).font(Theme.monoBody)
                        hint("Output streams into the history below.")
                    }
                }
            }
        }
    }

    private var buttons: some View {
        EditorSection("Buttons") {
            FieldRow("Actions", alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Show action buttons", isOn: $template.actionsEnabled).toggleStyle(.checkbox)
                    if template.actionsEnabled {
                        ForEach($template.actions) { $a in
                            HStack(spacing: 6) {
                                Menu {
                                    Button("No Icon") { a.symbol = "" }
                                    Divider()
                                    ForEach(ActionButton.symbols, id: \.self) { s in
                                        Button { a.symbol = s } label: { Label(s, systemImage: s) }
                                    }
                                } label: {
                                    Image(systemName: a.symbol.isEmpty ? "circle.dashed" : a.symbol)
                                        .foregroundStyle(a.symbol.isEmpty ? .tertiary : .secondary)
                                        .frame(width: 16)
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("Action icon (SF Symbol, shown after the title)")
                                TextField("", text: $a.title, prompt: Text("Title"))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 200)
                                Toggle("Destructive", isOn: $a.destructive).toggleStyle(.checkbox)
                                Button {
                                    template.actions.removeAll { $0.id == a.id }
                                } label: {
                                    Image(systemName: "minus")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove button")
                            }
                        }
                        Button {
                            template.actions.append(ActionButton(title: "Button \(template.actions.count + 1)"))
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .disabled(template.actions.count >= ActionButton.maxCount)
                        if template.actions.count >= ActionButton.maxCount {
                            hint("Apple allows up to \(ActionButton.maxCount) actions per notification.")
                        }
                    }
                }
            }
            FieldRow("Reply", alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Inline text reply", isOn: $template.replyEnabled).toggleStyle(.checkbox)
                    if template.replyEnabled {
                        HStack(spacing: 6) {
                            TextField("", text: $template.replyButtonTitle, prompt: Text("Button"))
                                .textFieldStyle(.roundedBorder).frame(width: 100)
                            TextField("", text: $template.replyPlaceholder, prompt: Text("Placeholder"))
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                        }
                    }
                }
            }
            FieldRow("Dismiss") {
                Toggle("Report dismissals", isOn: $template.reportDismiss).toggleStyle(.checkbox)
            }
            hint("Buttons appear under Options on banners. Set the alert style to Alerts to keep them on screen.")
                .padding(.leading, 104)
        }
    }

    private var attachment: some View {
        EditorSection("Attachment") {
            FieldRow("Image") {
                HStack(spacing: 8) {
                    if let image = template.image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 0.5))
                        Text(template.imagePath ?? "")
                            .font(Theme.mono)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Remove") { template.imagePath = nil }
                    } else {
                        Text("None — drop an image anywhere here")
                            .font(Theme.label)
                            .foregroundStyle(.tertiary)
                    }
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        if panel.runModal() == .OK, let url = panel.url { template.imagePath = url.path }
                    }
                }
            }
        }
    }

    private func hint(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Per-template history

struct TemplateHistory: View {
    enum Filter: String, CaseIterable { case all = "All", interactions = "Interactions", errors = "Errors" }

    @Environment(NotificationService.self) private var service
    let templateID: UUID
    @State private var filter: Filter = .all
    @State private var selected: LogEvent.ID?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "History", count: events.count) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button("Clear") { service.clearLog(template: templateID) }
                    .disabled(events.isEmpty)
            }
            .background(Theme.surface)
            Divider()

            if events.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath",
                           title: filter == .all ? "No history" : "Nothing matches",
                           message: filter == .all ? "Send with ⌘↩. Deliveries, clicks, button presses, replies and command output appear here." : "")
            } else {
                List(events, selection: $selected) { e in
                    EventRow(event: e, expanded: selected == e.id)
                        .tag(e.id)
                        .contextMenu { EventMenu(event: e) }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 22)
            }
        }
        .background(Theme.surface)
    }

    private var events: [LogEvent] {
        service.events.filter { e in
            guard e.templateID == templateID else { return false }
            switch filter {
            case .all: return true
            case .interactions: return e.kind.isInteraction
            case .errors: return e.kind == .error
            }
        }
    }
}

struct EventRow: View {
    let event: LogEvent
    var expanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.date.logTime)
                .font(Theme.mono)
                .foregroundStyle(.tertiary)
            Image(systemName: event.kind.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(event.kind.tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title).font(.system(size: 12)).lineLimit(1)
                    if !event.notificationID.isEmpty {
                        Text(event.notificationID.prefix(8))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                if !event.detail.isEmpty {
                    Text(expanded ? event.detail : (event.detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""))
                        .font(Theme.mono)
                        .foregroundStyle(event.kind == .error ? .red : .secondary)
                        .lineLimit(expanded ? nil : 1)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}

struct EventMenu: View {
    @Environment(AppState.self) private var state
    let event: LogEvent

    var body: some View {
        Button("Copy Event") { copy("\(event.date.logTime)  \(event.title)\n\(event.detail)") }
        if !event.detail.isEmpty { Button("Copy Detail") { copy(event.detail) } }
        if !event.notificationID.isEmpty { Button("Copy Notification ID") { copy(event.notificationID) } }
        if let id = event.templateID, state.index(of: id) != nil {
            Divider()
            Button("Reveal Template") { state.selection = .template(id) }
            Button("Send Template Again") { state.send(id) }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
