import AppKit
import SwiftUI

// MARK: - Activity

struct ActivityView: View {
    enum Scope: String, CaseIterable { case all = "All", interactions = "Interactions", errors = "Errors" }

    @Environment(AppState.self) private var state
    @Environment(NotificationService.self) private var service
    @State private var query = ""
    @State private var scope: Scope = .all

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            PaneHeader(title: "Activity", count: rows.count) {
                FilterField(text: $query)
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button("Clear") { service.clearLog() }.disabled(service.events.isEmpty)
            }
            Divider()

            if service.events.isEmpty {
                EmptyState(symbol: "list.bullet.rectangle", title: "No activity yet",
                           message: "Pick a template and press ⌘↩. Everything that happens to a notification is logged here.")
            } else if rows.isEmpty {
                EmptyState(symbol: "line.3.horizontal.decrease", title: "No matching events",
                           actionTitle: "Reset Filters") { query = ""; scope = .all }
            } else {
                Table(rows, selection: $state.selectedEvent) {
                    TableColumn("Time") { e in
                        Text(e.date.logTime).font(Theme.mono).foregroundStyle(.secondary)
                    }
                    .width(min: 86, ideal: 90, max: 110)
                    TableColumn("") { e in
                        Image(systemName: e.kind.symbol)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(e.kind.tint)
                    }
                    .width(16)
                    TableColumn("Event") { e in Text(e.title).lineLimit(1) }
                        .width(min: 140, ideal: 210)
                    TableColumn("Template") { e in
                        Text(e.templateName).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .width(min: 70, ideal: 100)
                    TableColumn("ID") { e in
                        Text(e.notificationID.prefix(8)).font(Theme.mono).foregroundStyle(.tertiary)
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("Detail") { e in
                        Text(e.detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                            .font(Theme.mono)
                            .foregroundStyle(e.kind == .error ? .red : .secondary)
                            .lineLimit(1)
                    }
                    .width(min: 120)
                }
                .font(.system(size: 12))
                .contextMenu(forSelectionType: LogEvent.ID.self) { ids in
                    if let id = ids.first, let e = service.events.first(where: { $0.id == id }) {
                        EventMenu(event: e)
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let t = service.events.first(where: { $0.id == id })?.templateID,
                       state.index(of: t) != nil {
                        state.selection = .template(t)
                    }
                }
            }
        }
    }

    private var rows: [LogEvent] {
        let q = query.lowercased()
        return service.events.filter { e in
            switch scope {
            case .all: break
            case .interactions: guard e.kind.isInteraction else { return false }
            case .errors: guard e.kind == .error else { return false }
            }
            guard !q.isEmpty else { return true }
            return e.title.lowercased().contains(q) || e.detail.lowercased().contains(q)
                || e.templateName.lowercased().contains(q) || e.notificationID.lowercased().contains(q)
        }
    }
}

// MARK: - Notification Center

struct DeliveredView: View {
    @Environment(AppState.self) private var state
    @Environment(NotificationService.self) private var service

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            PaneHeader(title: "Notification Center", count: service.delivered.count) {
                Button("Clear Badge") { Task { await service.clearBadge() } }
                Button("Remove Selected") { Task { await service.remove(state.selectedDelivered) } }
                    .disabled(state.selectedDelivered.isEmpty)
                Button("Remove All") { Task { await service.removeAllDelivered() } }
                    .disabled(service.delivered.isEmpty)
            }
            Divider()

            if !service.isLoaded {
                EmptyState(symbol: "", title: "Loading Notification Center…", loading: true)
            } else if service.delivered.isEmpty {
                EmptyState(symbol: "tray", title: "Nothing in Notification Center",
                           message: "Delivered notifications from this app stay here until dismissed or removed.")
            } else {
                Table(service.delivered, selection: $state.selectedDelivered) {
                    TableColumn("Delivered") { d in
                        Text(d.date.logTime).font(Theme.mono).foregroundStyle(.secondary)
                    }
                    .width(min: 86, ideal: 92, max: 110)
                    TableColumn("Title") { d in Text(d.title).lineLimit(1) }
                        .width(min: 120, ideal: 160)
                    TableColumn("Thread") { d in Text(d.thread).font(Theme.mono).foregroundStyle(.secondary) }
                        .width(min: 50, ideal: 80)
                    TableColumn("Identifier") { d in
                        Text(d.id).font(Theme.mono).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    .width(min: 80, ideal: 110)
                    TableColumn("Body") { d in Text(d.body).foregroundStyle(.secondary).lineLimit(1) }
                        .width(min: 120)
                }
                .font(.system(size: 12))
                .onDeleteCommand { Task { await service.remove(state.selectedDelivered) } }
                .contextMenu(forSelectionType: DeliveredItem.ID.self) { ids in
                    Button(ids.count > 1 ? "Remove \(ids.count) Notifications" : "Remove") {
                        Task { await service.remove(ids) }
                    }
                    Button("Copy Identifier") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ids.joined(separator: "\n"), forType: .string)
                    }
                }
            }
        }
    }
}

// MARK: - Scheduled

struct ScheduledView: View {
    @Environment(AppState.self) private var state
    @Environment(NotificationService.self) private var service

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            PaneHeader(title: "Scheduled", count: service.pending.count) {
                Button("Cancel Selected") { Task { await service.cancel(state.selectedPending) } }
                    .disabled(state.selectedPending.isEmpty)
                Button("Cancel All") { Task { await service.cancelAllPending() } }
                    .disabled(service.pending.isEmpty)
            }
            Divider()

            if !service.isLoaded {
                EmptyState(symbol: "", title: "Loading…", loading: true)
            } else if service.pending.isEmpty {
                EmptyState(symbol: "clock", title: "Nothing scheduled",
                           message: "Give a template a delay to schedule it. It counts down here until delivery.")
            } else {
                TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                    Table(service.pending, selection: $state.selectedPending) {
                        TableColumn("Fires in") { p in
                            let remaining = max(0, p.fireDate.timeIntervalSince(ctx.date))
                            HStack(spacing: 6) {
                                CountdownRing(fraction: 1 - remaining / max(p.interval, 0.1))
                                Text(String(format: "%.1fs", remaining)).font(Theme.mono)
                            }
                        }
                        .width(min: 80, ideal: 90, max: 120)
                        TableColumn("Title") { p in Text(p.title).lineLimit(1) }
                            .width(min: 120, ideal: 220)
                        TableColumn("Fire time") { p in
                            Text(p.fireDate.logTime).font(Theme.mono).foregroundStyle(.secondary)
                        }
                        .width(min: 86, ideal: 92)
                        TableColumn("Identifier") { p in
                            Text(p.id).font(Theme.mono).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .font(.system(size: 12))
                }
                .onDeleteCommand { Task { await service.cancel(state.selectedPending) } }
                .contextMenu(forSelectionType: PendingItem.ID.self) { ids in
                    Button(ids.count > 1 ? "Cancel \(ids.count)" : "Cancel") { Task { await service.cancel(ids) } }
                }
            }
        }
    }
}

// MARK: - Shared

struct FilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.tertiary)
            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .onExitCommand { text = "" }
        }
        .padding(.horizontal, 6)
        .frame(width: 180, height: 20)
        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
    }
}
