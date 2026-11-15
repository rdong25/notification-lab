import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Environment(NotificationService.self) private var service
    @FocusState private var filterFocused: Bool

    var body: some View {
        @Bindable var state = state

        List(selection: $state.selection) {
            Section("Workspace") {
                row("Activity", symbol: "list.bullet.rectangle", count: service.events.count, item: .activity)
                row("Notification Center", symbol: "tray.full", count: service.delivered.count, item: .delivered)
                HStack {
                    Label("Scheduled", systemImage: "clock")
                    Spacer()
                    if let next = service.pending.first {
                        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                            CountdownRing(fraction: 1 - next.fireDate.timeIntervalSince(ctx.date) / max(next.interval, 0.1))
                        }
                    }
                    countBadge(service.pending.count)
                }
                .tag(SidebarItem.scheduled)
                HStack {
                    Label("Diagnostics", systemImage: "stethoscope")
                    Spacer()
                    let diag = Diagnostics.shared
                    if !diag.blockers.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help("Something may be hiding banners")
                    }
                    countBadge(diag.issueCount)
                }
                .tag(SidebarItem.diagnostics)
            }

            Section("Templates") {
                ForEach(filteredTemplates) { t in
                    TemplateRow(template: t)
                        .tag(SidebarItem.template(t.id))
                        .contextMenu { contextMenu(for: t) }
                }
                .onMove { from, to in
                    guard state.sidebarFilter.isEmpty else { return }
                    state.move(from: from, to: to)
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, .small)
        .onDeleteCommand {
            if let id = state.currentTemplateID { state.delete(id) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 6) {
                    Button {
                        state.newTemplate()
                    } label: {
                        Image(systemName: "plus").frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help("New Template (⌘N)")

                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        TextField("Filter", text: $state.sidebarFilter)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .focused($filterFocused)
                            .onExitCommand { state.sidebarFilter = ""; filterFocused = false }
                        if !state.sidebarFilter.isEmpty {
                            Button { state.sidebarFilter = "" } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    private var filteredTemplates: [Template] {
        let q = state.sidebarFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.templates }
        return state.templates.filter { $0.name.lowercased().contains(q) || $0.title.lowercased().contains(q) }
    }

    private func row(_ title: String, symbol: String, count: Int, item: SidebarItem) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            countBadge(count)
        }
        .tag(item)
    }

    @ViewBuilder private func countBadge(_ n: Int) -> some View {
        if n > 0 {
            Text("\(n)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func contextMenu(for t: Template) -> some View {
        Button("Send") { state.send(t.id) }
        Divider()
        Button("Rename") { state.selection = .template(t.id); state.renamingID = t.id }
        Button("Duplicate") { state.duplicate(t.id) }
        Menu("Icon") {
            ForEach(Template.symbols, id: \.self) { s in
                Button { if let i = state.index(of: t.id) { state.templates[i].symbol = s } } label: {
                    Label(s, systemImage: s)
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { state.delete(t.id) }
    }
}

private struct TemplateRow: View {
    @Environment(AppState.self) private var state
    let template: Template
    @State private var draftName = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Label {
                if state.renamingID == template.id {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onAppear { draftName = template.name; focused = true }
                        .onSubmit(commit)
                        .onExitCommand { state.renamingID = nil }
                        .onChange(of: focused) { _, f in if !f { commit() } }
                } else {
                    Text(template.name).lineLimit(1)
                }
            } icon: {
                Image(systemName: template.symbol)
            }
            Spacer(minLength: 4)
            if !template.traits.isEmpty && state.renamingID != template.id {
                Text(template.traits.prefix(2).joined(separator: " "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func commit() {
        guard state.renamingID == template.id else { return }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let i = state.index(of: template.id) { state.templates[i].name = name }
        state.renamingID = nil
    }
}
