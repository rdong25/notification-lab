import AppKit
import SwiftUI

enum Prefs {
    static let cliBannerDismissed = "cli.bannerDismissed"
}

struct SettingsView: View {
    @State private var tab = ScreenshotMode.settingsTab ?? "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            CLISettings()
                .tabItem { Label("Command Line", systemImage: "terminal") }
                .tag("cli")
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.cliBannerDismissed) private var bannerDismissed = false
    @State private var diag = Diagnostics.shared

    var body: some View {
        Form {
            Section("Command-line tool") {
                Toggle("Show the install banner in the main window", isOn: Binding(
                    get: { !bannerDismissed }, set: { bannerDismissed = !$0 }))
                Text("The banner hides itself once notiflab is installed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                LabeledContent("Checks marked “Not an Issue”") {
                    HStack {
                        Text("\(diag.ignoredCount)").monospacedDigit().foregroundStyle(.secondary)
                        Button("Reset") { diag.resetAcknowledged() }.disabled(diag.ignoredCount == 0)
                    }
                }
            }
            Section("Templates") {
                LabeledContent("Library") {
                    HStack {
                        Button("Add Default Templates") { AppState.shared.restoreDefaults() }
                        Button("Reveal File") { AppState.shared.revealTemplatesFile() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct CLISettings: View {
    @State private var installer = CLIInstaller.shared

    var body: some View {
        Form {
            Section("notiflab") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusText).font(Theme.monoBody).textSelection(.enabled)
                    }
                }
                HStack {
                    if installer.isInstalled {
                        Button("Uninstall") { Task { await installer.uninstall() } }
                        Button("Reinstall") { Task { await installer.install() } }
                    } else {
                        Button(installer.state == .notInstalled ? "Install Command Line Tool…" : "Replace with This Version…") {
                            Task { await installer.install() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Show in Finder") { installer.revealHelper() }
                    if installer.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .disabled(installer.isWorking || !installer.helperExists)
                if let m = installer.message { Text(m).font(.caption).foregroundStyle(.secondary) }
                if let e = installer.error { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("Install manually") {
                CodeBlock(text: installer.manualCommand)
                Text("Installing links the tool into /opt/homebrew/bin or /usr/local/bin. macOS asks for your password only if neither is writable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Quick start") {
                CodeBlock(text: CLISettings.examples)
            }
        }
        .formStyle(.grouped)
        .onAppear { installer.refresh() }
    }

    static let examples = """
    notiflab send -t "Build finished" -m "Tests passed" --sound Glass
    notiflab send -t "Deploy?" -a Deploy -a "Cancel!" --wait
    notiflab send -T "Inline reply" --wait
    notiflab diagnose
    notiflab log -f
    notiflab help send
    """

    private var statusColor: Color {
        switch installer.state {
        case .installed: .green
        case .other: .orange
        case .notInstalled: .secondary
        }
    }

    private var statusText: String {
        switch installer.state {
        case .installed(let path): "Installed at \(path)"
        case .other(let path, let target): "\(path) points to \(target)"
        case .notInstalled: "Not installed"
        }
    }
}

/// Dismissible banner at the top of the main window offering to install `notiflab`.
struct CLIBanner: View {
    @AppStorage(Prefs.cliBannerDismissed) private var dismissed = false
    @State private var installer = CLIInstaller.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if installer.justInstalled, case .installed = installer.state {
            bar {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("notiflab is installed. Try it in Terminal:").font(.system(size: 12))
                command("notiflab send -t \"Hello from the terminal\"")
                Spacer()
                Button("Done") { installer.justInstalled = false }
            }
        } else if (ScreenshotMode.isActive || (!dismissed && !installer.isInstalled)) && installer.helperExists {
            bar {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text("Use Notification Lab from the terminal").font(.system(size: 12)).lineLimit(1).layoutPriority(-1)
                command("notiflab send -t \"Done\" --wait")
                Spacer(minLength: 8)
                if let e = installer.error {
                    Text(e).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1).help(e)
                }
                if installer.isWorking { ProgressView().controlSize(.small) }
                Button("Install notiflab") { Task { await installer.install() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(installer.isWorking)
                    .fixedSize()
                    .help("Links the notiflab command into /opt/homebrew/bin or /usr/local/bin")
                Button("Learn More") { openSettings() }
                    .fixedSize()
                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Hide. You can install it later in Settings → Command Line.")
            }
        }
    }

    private func command(_ s: String) -> some View {
        Text(s)
            .font(Theme.mono)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            .lineLimit(1)
            .fixedSize()
            .textSelection(.enabled)
    }

    private func bar<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) { content() }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Color.accentColor.opacity(0.07))
            .overlay(alignment: .bottom) { Divider() }
    }
}
