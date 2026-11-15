import AppKit
import SwiftUI

/// Label column + control, the basic unit of the dense editor.
struct FieldRow<Content: View>: View {
    let label: String
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: Content

    init(_ label: String, alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) {
        self.label = label
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(label)
                .font(Theme.label)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
                .padding(.top, alignment == .top ? 4 : 0)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A titled group in the editor, separated from the next by a hairline.
struct EditorSection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    init(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(Theme.header)
                    .foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            content
        }
        .padding(.vertical, 14)
    }
}

/// Small "header bar" used at the top of panes.
struct PaneHeader<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if let count {
                Text("\(count)")
                    .font(Theme.mono)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}

/// Quiet empty / loading / error placeholder.
struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String = ""
    var loading = false
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Keyboard shortcut hint, e.g. ⌘↩.
struct KeyHint: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(0.6)))
    }
}

/// Monospaced key/value row for technical metadata.
struct MetaRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(Theme.mono)
                .foregroundStyle(.tertiary)
                .frame(width: 84, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(Theme.mono)
                .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

/// Monospaced code block with a copy button.
struct CodeBlock: View {
    let text: String
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(Theme.mono)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(10)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .frame(width: 22, height: 22)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .padding(4)
        }
        .background(Theme.mutedSurface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

/// Rendering of the banner as current macOS draws it (Big Sur+ layout: no timestamp,
/// bold subtitle, actions behind an “Options” pill, × on hover). Real banners are ~344pt wide.
/// Resting state shows content only; hovering reveals the × close button and, when the
/// notification has a category, the “Options” pill whose menu holds the actions.
struct NotificationCard: View {
    let template: Template
    /// Force the hover state (used where there's no pointer, e.g. snapshots).
    var forceHover = false
    @State private var hovering = false

    private var showChrome: Bool { hovering || forceHover }

    private var actions: [ActionButton] {
        template.actionsEnabled
            ? Array(template.actions.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(ActionButton.maxCount))
            : []
    }

    /// macOS offers “Options” whenever the notification carries a category.
    private var hasOptions: Bool { !actions.isEmpty || template.replyEnabled || template.reportDismiss }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 0) {
                Text(template.title.isEmpty ? "Notification Lab" : template.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !template.subtitle.isEmpty {
                    Text(template.subtitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                if !template.message.isEmpty {
                    Text(template.message)
                        .font(.system(size: 13))
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let image = template.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            if hasOptions && showChrome {
                trailingControl
                    .transition(.opacity)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 13)
        .frame(maxWidth: 344, minHeight: 66)
        .bannerSurface()
        .overlay(alignment: .topLeading) {
            if showChrome {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.5))
                    .offset(x: -7, y: -7)
                    .transition(.opacity)
                    .help("Clear")
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help("Hover to see the close button and Options menu")
    }

    /// Mac User Guide: “Click the action or click Options.” A lone action (or a lone Reply)
    /// is shown as its own button; several actions go behind an Options menu.
    @ViewBuilder private var trailingControl: some View {
        if actions.count == 1 && !template.replyEnabled {
            pill(actions[0].title, symbol: actions[0].symbol, destructive: actions[0].destructive)
        } else if actions.isEmpty && template.replyEnabled {
            pill(template.replyButtonTitle, symbol: "", destructive: false)
        } else {
            optionsMenu
        }
    }

    private func pill(_ title: String, symbol: String, destructive: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            if !symbol.isEmpty { Image(systemName: symbol).font(.system(size: 11, weight: .medium)) }
        }
        .foregroundStyle(destructive ? Color.red : Color.primary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.primary.opacity(0.10), in: Capsule())
        .fixedSize()
    }

    private var optionsMenu: some View {
        Menu {
            ForEach(actions) { a in
                Button(role: a.destructive ? .destructive : nil) {} label: {
                    if a.symbol.isEmpty { Text(a.title) } else { Label(a.title, systemImage: a.symbol) }
                }
            }
            if template.replyEnabled {
                if !actions.isEmpty { Divider() }
                Button(template.replyButtonTitle + "…") {}
            }
            if actions.isEmpty && !template.replyEnabled {
                Text("No actions")
            }
        } label: {
            HStack(spacing: 4) {
                Text("Options").font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(.primary.opacity(0.10), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private extension View {
    @ViewBuilder func bannerSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        self.background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
    }
}

/// Mini circular countdown.
struct CountdownRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
    }
}

extension Date {
    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var logTime: String { Date.logFormatter.string(from: self) }
}
