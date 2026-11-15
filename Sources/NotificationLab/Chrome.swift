import AppKit
import SwiftUI
import UserNotifications

// MARK: - Inspector

struct InspectorView: View {
    @Environment(AppState.self) private var state
    @Environment(NotificationService.self) private var service

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch state.selection {
                case .template:
                    if let t = state.currentTemplate { templateInspector(t) }
                case .activity:
                    if let id = state.selectedEvent, let e = service.events.first(where: { $0.id == id }) {
                        eventInspector(e)
                    } else {
                        placeholder("Select an event to see its details.")
                    }
                case .delivered:
                    if state.selectedDelivered.count == 1, let id = state.selectedDelivered.first,
                       let d = service.delivered.first(where: { $0.id == id }) {
                        section("Notification") {
                            MetaRow(key: "identifier", value: d.id)
                            MetaRow(key: "delivered", value: d.date.logTime)
                            MetaRow(key: "title", value: d.title)
                            MetaRow(key: "subtitle", value: d.subtitle)
                            MetaRow(key: "body", value: d.body)
                            MetaRow(key: "thread", value: d.thread)
                            MetaRow(key: "category", value: d.category)
                        }
                    } else {
                        placeholder(state.selectedDelivered.isEmpty ? "Select a notification." : "\(state.selectedDelivered.count) selected")
                    }
                case .scheduled:
                    placeholder("Select a scheduled notification and press ⌫ to cancel it.")
                case .diagnostics:
                    placeholder("Checks re-run every few seconds. Click a check to see how to fix it.")
                case nil:
                    placeholder("Nothing selected.")
                }
                environment
            }
            .padding(14)
            .padding(.top, 52) // toolbar height; the inspector column otherwise double-counts the top inset
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.surface)
    }

    @ViewBuilder private func templateInspector(_ t: Template) -> some View {
        section("Preview", trailing: "hover") {
            NotificationCard(template: t, forceHover: ScreenshotMode.forceHover)
                .padding(.horizontal, 10)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                .background(Theme.mutedSurface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 0.5))
        }
        section("Swift", trailing: "⇧⌘C") {
            CodeBlock(text: t.swiftSnippet)
        }
        section("Request") {
            MetaRow(key: "identifier", value: t.groupID.isEmpty ? "uuid (per send)" : t.groupID)
            MetaRow(key: "thread", value: t.threadID)
            MetaRow(key: "interruption", value: t.level.rawValue)
            MetaRow(key: "sound", value: t.soundFile)
            MetaRow(key: "trigger", value: t.delay > 0 ? "timeInterval(\(Int(t.delay)))" : "nil (immediate)")
            MetaRow(key: "badge", value: t.badgeEnabled ? "\(t.badge)" : "")
            MetaRow(key: "attachment", value: t.imagePath.map { ($0 as NSString).lastPathComponent } ?? "")
            MetaRow(key: "category", value: categoryDescription(t))
        }
        section("userInfo") {
            CodeBlock(text: t.userInfoJSON)
        }
    }

    @ViewBuilder private func eventInspector(_ e: LogEvent) -> some View {
        section("Event") {
            MetaRow(key: "kind", value: e.kind.rawValue)
            MetaRow(key: "time", value: e.date.logTime)
            MetaRow(key: "template", value: e.templateName)
            MetaRow(key: "notification", value: e.notificationID)
        }
        section("Summary") {
            Text(e.title).font(.system(size: 12)).textSelection(.enabled)
        }
        if !e.detail.isEmpty {
            section(e.kind == .command ? "Output" : "Detail") { CodeBlock(text: e.detail) }
        }
    }

    private var environment: some View {
        section("Environment") {
            MetaRow(key: "auth", value: authText)
            MetaRow(key: "style", value: styleText)
            MetaRow(key: "alerts", value: onOff(service.alertEnabled))
            MetaRow(key: "center", value: onOff(service.centerEnabled))
            MetaRow(key: "lock screen", value: onOff(service.lockScreenEnabled))
            MetaRow(key: "sound", value: onOff(service.soundEnabled))
            MetaRow(key: "badge", value: onOff(service.badgeEnabled))
            MetaRow(key: "time-sens.", value: onOff(service.timeSensitiveEnabled))
            MetaRow(key: "bundle", value: Bundle.main.bundleIdentifier ?? "")
        }
    }

    private func onOff(_ b: Bool) -> String { b ? "enabled" : "disabled" }

    private func categoryDescription(_ t: Template) -> String {
        var parts: [String] = []
        if t.actionsEnabled { parts.append("\(t.actions.count) action\(t.actions.count == 1 ? "" : "s")") }
        if t.replyEnabled { parts.append("text input") }
        if t.reportDismiss { parts.append("customDismiss") }
        return parts.joined(separator: ", ")
    }

    private var authText: String {
        switch service.authStatus {
        case .authorized: "authorized"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        case .provisional: "provisional"
        @unknown default: "unknown"
        }
    }

    private var styleText: String {
        switch service.alertStyle {
        case .banner: "banner"
        case .alert: "alert"
        default: "none"
        }
    }

    private func section<C: View>(_ title: String, trailing: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(Theme.header).foregroundStyle(.secondary)
                Spacer()
                if let trailing { KeyHint(trailing) }
            }
            content()
        }
    }

    private func placeholder(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Environment(AppState.self) private var state
    @Environment(NotificationService.self) private var service

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if service.authStatus == .notDetermined { Task { await service.requestAuthorization() } }
                else { service.openSystemSettings() }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(permissionColor).frame(width: 6, height: 6)
                    Text(permissionText)
                }
            }
            .buttonStyle(.plain)
            .help("Notification permission — click to open System Settings")

            if let blocker = Diagnostics.shared.blockers.first {
                divider
                Button { state.selection = .diagnostics } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5))
                        Text(blocker.title).lineLimit(1)
                    }
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help(blocker.summary)
            }
            divider
            activity
            Spacer(minLength: 12)

            if let next = service.pending.first {
                Button { state.selection = .scheduled } label: {
                    TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                        let remaining = max(0, next.fireDate.timeIntervalSince(ctx.date))
                        HStack(spacing: 5) {
                            CountdownRing(fraction: 1 - remaining / max(next.interval, 0.1))
                            Text("next \(String(format: "%.1f", remaining))s").font(Theme.mono)
                            if service.pending.count > 1 {
                                Text("+\(service.pending.count - 1)").font(Theme.mono).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                divider
            }

            Button { state.selection = .delivered } label: {
                Text("\(service.delivered.count) in Notification Center").font(Theme.mono)
            }
            .buttonStyle(.plain)
            divider
            Button { state.showPalette = true } label: { KeyHint("⌘K") }
                .buttonStyle(.plain)
                .help("Command Palette")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var activity: some View {
        if let job = service.jobs.first {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("$ \(job.command)").font(Theme.mono).lineLimit(1)
                if !job.lastLine.isEmpty {
                    Text(job.lastLine).font(Theme.mono).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        } else if let p = service.sendProgress {
            HStack(spacing: 6) {
                ProgressView(value: Double(p.done), total: Double(p.total))
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .frame(width: 70)
                Text("Sending \(p.done)/\(p.total)").font(Theme.mono)
            }
        } else if let e = service.events.first {
            Button { state.selection = .activity; state.selectedEvent = e.id } label: {
                HStack(spacing: 5) {
                    Image(systemName: e.kind.symbol).font(.system(size: 9.5)).foregroundStyle(e.kind.tint)
                    Text(e.title).lineLimit(1)
                    Text(e.date, style: .relative).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .buttonStyle(.plain)
        } else {
            Text("Ready").foregroundStyle(.tertiary)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(width: 1, height: 12).padding(.horizontal, 10)
    }

    private var permissionColor: Color {
        switch service.authStatus {
        case .authorized, .provisional: service.alertStyle == .none ? .orange : .green
        case .denied: .red
        default: .gray
        }
    }

    private var permissionText: String {
        switch service.authStatus {
        case .authorized:
            switch service.alertStyle {
            case .alert: "Allowed · Alerts"
            case .banner: "Allowed · Banners"
            default: "Allowed · No banners"
            }
        case .provisional: "Provisional"
        case .denied: "Notifications off"
        case .notDetermined: "Permission not requested"
        @unknown default: "Unknown"
        }
    }
}

// MARK: - Command palette

struct CommandPalette: View {
    @Environment(AppState.self) private var state
    @State private var query = ""
    @State private var index = 0
    @State private var monitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        let results = self.results

        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "command").font(.system(size: 13)).foregroundStyle(.tertiary)
                    TextField("Run a command or jump to a template…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($focused)
                        .onSubmit { run(results) }
                        .onChange(of: query) { index = 0 }
                        .onAppear { query = state.paletteSeed; state.paletteSeed = "" }
                    KeyHint("esc")
                }
                .padding(.horizontal, 14)
                .frame(height: 44)

                Divider()

                if results.isEmpty {
                    Text("No commands match “\(query)”")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            // Plain VStack: the list is short, and lazy row reuse mixed up section headers.
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(groups(results), id: \.section) { group in
                                    Text(group.section.rawValue)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 14)
                                        .padding(.top, group.start == 0 ? 6 : 10)
                                        .padding(.bottom, 3)
                                    ForEach(Array(group.items.enumerated()), id: \.element.id) { offset, cmd in
                                        let i = group.start + offset
                                        row(cmd, selected: i == index)
                                            .id(i)
                                            .onTapGesture { index = i; run(results) }
                                            .onHover { if $0 { index = i } }
                                    }
                                }
                            }
                            .padding(.bottom, 6)
                        }
                        .frame(maxHeight: 380)
                        .onChange(of: index) { _, i in proxy.scrollTo(i) }
                    }
                }

                Divider()
                HStack(spacing: 12) {
                    Label { Text("navigate") } icon: { KeyHint("↑↓") }
                    Label { Text("run") } icon: { KeyHint("↩") }
                    Spacer()
                    Text("\(results.count) commands").font(Theme.mono)
                }
                .labelStyle(PaletteHintLabelStyle())
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .frame(height: 26)
            }
            .frame(width: 600)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(.top, 70)
        }
        .onAppear {
            focused = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 126: index = max(0, index - 1); return nil                      // ↑
                case 125: index = min(max(0, self.results.count - 1), index + 1); return nil  // ↓
                case 53: close(); return nil                                         // esc
                default: return event
                }
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    private func row(_ cmd: AppState.PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: cmd.symbol)
                .font(.system(size: 12))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 18)
            Text(cmd.title).font(.system(size: 12.5)).lineLimit(1)
            if !cmd.detail.isEmpty {
                Text(cmd.detail).font(Theme.mono).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if !cmd.shortcut.isEmpty { KeyHint(cmd.shortcut) }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private var results: [AppState.PaletteCommand] {
        let all = state.paletteCommands
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            // Keep the default view short: hide the per-template "Send X" duplicates.
            return all.filter { !$0.id.hasPrefix("ts.") }.sorted { order($0) < order($1) }
        }
        let scored = all.compactMap { cmd -> (cmd: AppState.PaletteCommand, score: Int)? in
            guard let s = score(cmd.title.lowercased(), q) else { return nil }
            return (cmd, s)
        }
        // Keep each section contiguous: sections ordered by their best match, items by score.
        let best = Dictionary(grouping: scored, by: { $0.cmd.section }).mapValues { $0.map(\.score).max() ?? 0 }
        return scored.sorted { a, b in
            if a.cmd.section != b.cmd.section {
                let (sa, sb) = (best[a.cmd.section] ?? 0, best[b.cmd.section] ?? 0)
                return sa != sb ? sa > sb : order(a.cmd) < order(b.cmd)
            }
            return a.score > b.score
        }
        .map(\.cmd)
    }

    private struct Group { let section: AppState.PaletteCommand.Section; let start: Int; var items: [AppState.PaletteCommand] }

    /// Splits the (section-contiguous) results into header groups, remembering each group's flat start index.
    private func groups(_ results: [AppState.PaletteCommand]) -> [Group] {
        var out: [Group] = []
        for (i, cmd) in results.enumerated() {
            if out.last?.section == cmd.section { out[out.count - 1].items.append(cmd) }
            else { out.append(Group(section: cmd.section, start: i, items: [cmd])) }
        }
        return out
    }

    private func order(_ c: AppState.PaletteCommand) -> Int {
        switch c.section { case .actions: 0; case .navigate: 1; case .templates: 2 }
    }

    /// Prefix > word-prefix > substring > subsequence.
    private func score(_ text: String, _ q: String) -> Int? {
        if text.hasPrefix(q) { return 400 }
        if text.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 300 }
        if text.contains(q) { return 200 }
        guard q.count >= 3 else { return nil } // subsequence matching is too loose for 1–2 letters
        var it = text.makeIterator()
        for ch in q {
            var found = false
            while let c = it.next() { if c == ch { found = true; break } }
            if !found { return nil }
        }
        return 100
    }

    private func run(_ results: [AppState.PaletteCommand]) {
        guard results.indices.contains(index) else { return }
        let cmd = results[index]
        close()
        cmd.run()
    }

    private func close() {
        state.showPalette = false
    }
}

private struct PaletteHintLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}
