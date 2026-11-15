import SwiftUI

struct DiagnosticsView: View {
    @State private var diag = Diagnostics.shared

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Diagnostics", count: diag.issueCount) {
                if diag.isRunning {
                    ProgressView().controlSize(.mini)
                } else if let last = diag.lastRun {
                    Text("checked \(last, style: .relative) ago")
                        .font(Theme.mono)
                        .foregroundStyle(.tertiary)
                }
                Button("Re-run") { Task { await diag.run() } }
                    .help("Run all checks (⌘R)")
                Button("Send Test Banner") { diag.sendTest() }
            }
            Divider()

            if diag.checks.isEmpty {
                EmptyState(symbol: "", title: "Running checks…", loading: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        TestPanel()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Checks")
                                .font(Theme.header)
                                .foregroundStyle(.secondary)
                            VStack(spacing: 0) {
                                ForEach(Array(diag.checks.enumerated()), id: \.element.id) { i, check in
                                    if i > 0 { Divider() }
                                    CheckRow(check: check)
                                }
                            }
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 0.5))
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Guided test

private struct TestPanel: View {
    @State private var diag = Diagnostics.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch diag.testState {
            case .idle:
                summaryLine
                HStack(spacing: 8) {
                    Button { diag.sendTest() } label: { Label("Send Test Banner", systemImage: "paperplane") }
                        .buttonStyle(.borderedProminent)
                    Text("Sends a banner, then asks whether you saw it and walks you through the likely causes.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

            case .waiting:
                HStack(spacing: 8) {
                    Image(systemName: "eye").foregroundStyle(.secondary)
                    Text("Did a banner slide in at the top right of “\(NSScreen.screens.first?.localizedName ?? "your main display")”?")
                        .font(.system(size: 12.5, weight: .medium))
                }
                HStack(spacing: 8) {
                    Button("Yes, I saw it") { diag.testState = .confirmed }
                        .keyboardShortcut("y", modifiers: [])
                    Button("No, nothing appeared") { diag.testState = .guiding(step: 0) }
                        .keyboardShortcut("n", modifiers: [])
                    Button("Send Again") { diag.sendTest() }
                    Spacer()
                    KeyHint("Y"); KeyHint("N")
                }

            case .confirmed:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Banners are working.").font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Button("Done") { diag.testState = .idle }
                }

            case .guiding(let step):
                guide(step)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 0.5))
    }

    @ViewBuilder private var summaryLine: some View {
        let blockers = diag.blockers
        HStack(spacing: 8) {
            Image(systemName: blockers.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(blockers.isEmpty ? .green : .orange)
            if blockers.isEmpty {
                Text("Nothing detected that would hide banners.")
                    .font(.system(size: 12.5, weight: .medium))
            } else {
                Text("\(blockers.count == 1 ? "1 thing is" : "\(blockers.count) things are") likely hiding banners: \(blockers.map(\.title).joined(separator: ", "))")
                    .font(.system(size: 12.5, weight: .medium))
            }
        }
    }

    @ViewBuilder private func guide(_ step: Int) -> some View {
        let steps = diag.guideSteps
        if steps.indices.contains(step) {
            let c = steps[step]
            HStack(spacing: 8) {
                Text("Step \(step + 1) of \(steps.count)")
                    .font(Theme.mono)
                    .foregroundStyle(.tertiary)
                Image(systemName: c.status.symbol).foregroundStyle(c.status.tint).font(.system(size: 11))
                Text(c.title).font(.system(size: 12.5, weight: .semibold))
                if c.status == .problem || c.status == .warning {
                    Text("detected").font(Theme.mono).foregroundStyle(c.status.tint)
                } else if c.status == .unknown {
                    Text("can't detect, check manually").font(Theme.mono).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Cancel") { diag.testState = .idle }.buttonStyle(.borderless)
            }
            CheckBody(check: c)
            Divider()
            HStack(spacing: 8) {
                Button { diag.sendTest() } label: { Label("Fixed it, send again", systemImage: "paperplane") }
                    .buttonStyle(.borderedProminent)
                Button {
                    diag.testState = .guiding(step: step + 1)
                } label: {
                    Label("Not this, next cause", systemImage: "arrow.right")
                }
                .disabled(step + 1 >= steps.count)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                Text("Out of known causes. Try logging out and back in, or restarting the Mac.")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Button("Start Over") { diag.testState = .guiding(step: 0) }
                Button("Done") { diag.testState = .idle }
            }
        }
    }
}

// MARK: - Rows

private struct CheckRow: View {
    @State private var diag = Diagnostics.shared
    let check: DiagnosticCheck

    var body: some View {
        let open = diag.expanded.contains(check.id)
        let muted = diag.isAcknowledged(check.id)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if open { diag.expanded.remove(check.id) } else { diag.expanded.insert(check.id) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: check.status.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(muted ? Color.secondary : check.status.tint)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title).font(.system(size: 12.5, weight: .medium))
                        Text(check.summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(open ? nil : 1)
                    }
                    Spacer(minLength: 8)
                    if muted {
                        Text("ignored").font(Theme.mono).foregroundStyle(.tertiary)
                    }
                    Text(check.status.label)
                        .font(Theme.mono)
                        .foregroundStyle(check.status == .ok ? Color.secondary.opacity(0.6) : (muted ? .secondary : check.status.tint))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(muted ? 0.6 : 1)

            if open {
                CheckBody(check: check)
                    .padding(.leading, 36)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
            }
        }
        .contextMenu {
            if check.acknowledgeable {
                Button(muted ? "Stop Ignoring" : "Not an Issue (Ignore)") { diag.toggleAcknowledged(check.id) }
            }
            Button("Copy Summary") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(check.title): \(check.summary)", forType: .string)
            }
        }
    }
}

/// Explanation, evidence, numbered steps and fix buttons for one check.
struct CheckBody: View {
    @State private var diag = Diagnostics.shared
    let check: DiagnosticCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !check.why.isEmpty {
                Text(check.why)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !check.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(check.evidence, id: \.self) { line in
                        Text(line).font(Theme.mono).lineLimit(1).truncationMode(.middle)
                    }
                }
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.mutedSurface, in: RoundedRectangle(cornerRadius: 5))
            }
            if !check.steps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(check.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1)").font(Theme.mono).foregroundStyle(.tertiary).frame(width: 12, alignment: .trailing)
                            Text(step).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !check.actions.isEmpty || check.acknowledgeable {
                HStack(spacing: 6) {
                    ForEach(check.actions, id: \.self) { action in
                        Button { diag.perform(action) } label: { Label(action.title, systemImage: action.symbol) }
                    }
                    if check.acknowledgeable && check.status != .ok {
                        Spacer()
                        Button(diag.isAcknowledged(check.id) ? "Stop Ignoring" : "Not an Issue") {
                            diag.toggleAcknowledged(check.id)
                        }
                        .buttonStyle(.borderless)
                        .help("Hide this warning if you've already allowed notifications while sharing")
                    }
                }
                .controlSize(.small)
            }
        }
    }
}
