import AppKit
import SwiftUI

@main
struct NotificationLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let state = AppState.shared
    private let service = NotificationService.shared

    var body: some Scene {
        Window("Notification Lab", id: "main") {
            RootView()
                .environment(state)
                .environment(service)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 840)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            SidebarCommands()

            CommandGroup(replacing: .newItem) {
                Button("New Template") { state.newTemplate() }
                    .keyboardShortcut("n")
                Button("Duplicate Template") { state.duplicate() }
                    .keyboardShortcut("d")
                    .disabled(state.currentTemplateID == nil)
            }

            CommandMenu("Notification") {
                Button("Send") { state.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(state.currentTemplateID == nil)
                Button("Copy Swift Snippet") { state.copySnippet() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(state.currentTemplateID == nil)
                Divider()
                Button("Remove All Delivered") { Task { await service.removeAllDelivered() } }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                Button("Cancel All Scheduled") { Task { await service.cancelAllPending() } }
                Button("Clear Dock Badge") { Task { await service.clearBadge() } }
                Divider()
                Button("Clear Activity Log") { service.clearLog() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                Divider()
                Button("Run Diagnostics") {
                    state.selection = .diagnostics
                    Task { await Diagnostics.shared.run() }
                }
                .keyboardShortcut("r")
                Button("Send Test Banner") { state.selection = .diagnostics; Diagnostics.shared.sendTest() }
                Button("Restart Notification Center") { Diagnostics.shared.perform(.restartNotificationCenter) }
                Divider()
                Button("Request Permission") { Task { await service.requestAuthorization() } }
                Button("Notification Settings…") { service.openSystemSettings() }
            }

            CommandGroup(after: .sidebar) {
                Button("Command Palette…") { state.showPalette.toggle() }
                    .keyboardShortcut("k")
                Button(state.showInspector ? "Hide Inspector" : "Show Inspector") { state.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button(state.showHistory ? "Hide History Pane" : "Show History Pane") { state.showHistory.toggle() }
                    .keyboardShortcut("y", modifiers: [.command, .shift])
                Divider()
                Button("Activity") { state.selection = .activity }.keyboardShortcut("1")
                Button("Notification Center") { state.selection = .delivered }.keyboardShortcut("2")
                Button("Scheduled") { state.selection = .scheduled }.keyboardShortcut("3")
                Button("Diagnostics") { state.selection = .diagnostics }.keyboardShortcut("4")
                Divider()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { NotificationService.shared.install() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { ScreenshotMode.runIfRequested() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(NotificationService.self) private var service
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var state = state

        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            // Status bar is a real row (not a safe-area inset): split views and tables
            // don't honour insets, which hid their last row under the bar.
            VStack(spacing: 0) {
                center
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                StatusBar()
            }
                .inspector(isPresented: $state.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 380, ideal: 400, max: 520)
                }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    state.send()
                } label: {
                    Label("Send", systemImage: "paperplane")
                }
                .help("Send (⌘↩)")
                .disabled(state.currentTemplateID == nil)

                Button {
                    state.showPalette.toggle()
                } label: {
                    Label("Command Palette", systemImage: "command")
                }
                .help("Command Palette (⌘K)")

                Button {
                    state.showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Toggle Inspector (⌥⌘I)")
            }
        }
        .overlay {
            if state.showPalette {
                CommandPalette()
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        .task {
            await service.start()
            Diagnostics.shared.startMonitoring()
        }
    }

    @ViewBuilder private var center: some View {
        switch state.selection {
        case .activity: ActivityView()
        case .delivered: DeliveredView()
        case .scheduled: ScheduledView()
        case .diagnostics: DiagnosticsView()
        case .template(let id):
            if let binding = state.binding(for: id) {
                TemplateWorkspace(template: binding).id(id)
            } else {
                EmptyState(symbol: "questionmark.square.dashed", title: "Template not found")
            }
        case nil:
            EmptyState(symbol: "sidebar.left", title: "Nothing selected",
                       message: "Pick a template in the sidebar or press ⌘K.",
                       actionTitle: "New Template") { state.newTemplate() }
        }
    }

    private var title: String {
        switch state.selection {
        case .activity: "Activity"
        case .delivered: "Notification Center"
        case .scheduled: "Scheduled"
        case .diagnostics: "Diagnostics"
        case .template: state.currentTemplate?.name ?? "Template"
        case nil: "Notification Lab"
        }
    }

    private var subtitle: String {
        switch state.selection {
        case .activity: "\(service.events.count) events"
        case .delivered: "\(service.delivered.count) delivered"
        case .scheduled: "\(service.pending.count) pending"
        case .diagnostics:
            Diagnostics.shared.blockers.isEmpty ? "no banner blockers found" : "\(Diagnostics.shared.blockers.count) possible banner blocker(s)"
        case .template: state.currentTemplate?.traits.joined(separator: " · ") ?? ""
        case nil: ""
        }
    }
}
