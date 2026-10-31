import AppKit
import SwiftUI

/// Menu bar panel (docs/redesign-0.3.md → Menu bar). Developer lines live in
/// Settings → Diagnostics.
struct StatusMenuView: View {
    @EnvironmentObject private var model: AppModel
    @State private var panelWindow: NSWindow?

    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PanelDivider()

            PanelToggleRow(
                title: "Parametric Equalizer",
                subtitle: equalizerSubtitle,
                isOn: Binding(
                    get: { model.isPassThroughEnabled },
                    // Defer past the click: synchronous MainActor work in a menu callback
                    // once caused SIGBUS.
                    set: { on in DispatchQueue.main.async { model.setEqualizerEnabled(on) } }
                )
            )
            .disabled(model.outputDevice == nil && !model.isPassThroughEnabled)
            .help(AppModel.passThroughMenuNote)

            PanelMenuRow(title: "Profile", value: model.peq.profileDisplayName) {
                if model.peq.profileNames.isEmpty {
                    Text("No saved profiles")
                } else {
                    ForEach(model.peq.profileNames, id: \.id) { profile in
                        Toggle(profile.name, isOn: Binding(
                            get: { model.peq.activeProfileName == profile.name },
                            set: { _ in DispatchQueue.main.async { _ = model.peq.loadProfile(id: profile.id) } }
                        ))
                    }
                }
            }

            PanelActionRow(title: "Open Equalizer…", shortcut: "⌘E") {
                dismiss()
                // A floating NSPanel; `openWindow` is unreliable from an LSUIElement menu bar app.
                DispatchQueue.main.async { model.showPEQPanel() }
            }
            .keyboardShortcut("e")
            .disabled(!model.eqControlsAvailable)
            .help(model.eqControlsAvailable ? "" : "Turn on Parametric Equalizer first")

            PanelDivider()

            PanelToggleRow(
                title: "Apple Music Mode",
                subtitle: nil,
                isOn: Binding(
                    get: { model.isAppleMusicModeEnabled },
                    set: { on in DispatchQueue.main.async { model.setAppleMusicModeEnabled(on) } }
                )
            )
            .help(AppModel.appleMusicModeMenuNote)

            PanelDivider()

            PanelMenuRow(title: "Output", value: outputValue) {
                Toggle("System Default", isOn: Binding(
                    get: { model.preferredOutputUID == nil },
                    set: { _ in DispatchQueue.main.async { model.selectOutput(nil) } }
                ))
                if !model.devices.isEmpty {
                    Divider()
                }
                ForEach(model.devices) { device in
                    Toggle(device.name, isOn: Binding(
                        get: { model.isPreferredOutput(device) },
                        set: { _ in DispatchQueue.main.async { model.selectOutput(device) } }
                    ))
                }
            }

            PanelActionRow(title: "Settings…", shortcut: "⌘,") {
                dismiss()
                DispatchQueue.main.async { AuxWindows.shared.showSettings() }
            }
            .keyboardShortcut(",")

            PanelActionRow(title: "Quit HiFi Companion", shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .font(.system(size: 13))
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .frame(width: Self.width)
        .background(WindowReader(window: $panelWindow))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.outputDevice?.name ?? "No hardware output")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(model.deviceFormat?.shortDescription ?? "—")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            SignalPathLine(path: model.signalPath)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var equalizerSubtitle: String? {
        if let owner = model.exclusiveOutputOwner {
            return "Unavailable — \(owner) exclusive"
        }
        if model.outputDevice == nil {
            return "No hardware output"
        }
        guard model.isPassThroughEnabled, !model.isBridgeRunning else { return nil }
        return model.lastError ?? "Reconnecting…"
    }

    private var outputValue: String {
        guard let uid = model.preferredOutputUID else { return "System Default" }
        if let device = model.devices.first(where: { $0.uid == uid }) {
            return device.name
        }
        let name = model.peq.storedDeviceCurves.first(where: { $0.uid == uid })?.curve.deviceName
        return "\(name.flatMap { $0.isEmpty ? nil : $0 } ?? "Preferred device") (not connected)"
    }

    private func dismiss() {
        panelWindow?.close()
    }
}

// MARK: - Signal path

struct SignalPathLine: View {
    let path: SignalPath

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Self.color(for: path.state))
                .frame(width: 8, height: 8)
            Text(path.summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .help("\(path.state.label): \(path.detail)")
    }

    static func color(for state: SignalPath.State) -> Color {
        switch state {
        case .idle: return .gray
        case .direct: return .green
        case .equalizer: return .blue
        case .resampled, .mixed: return .yellow
        }
    }
}

// MARK: - Rows

private struct PanelDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 10).padding(.vertical, 4)
    }
}

/// Menu-like row: highlights on hover, like an NSMenu item.
private struct PanelRowBackground: ViewModifier {
    let enabled: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .frame(minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && enabled ? Color.primary.opacity(0.1) : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

private struct PanelActionRow: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut)
                    .foregroundStyle(.tertiary)
            }
            .modifier(PanelRowBackground(enabled: isEnabled))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
    }
}

private struct PanelToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(isEnabled ? .primary : .tertiary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 3)
        .modifier(PanelRowBackground(enabled: false))
    }
}

private struct PanelMenuRow<Items: View>: View {
    let title: String
    let value: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 12)
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .modifier(PanelRowBackground(enabled: true))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// Captures the hosting window so actions can close the panel.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window !== nsView.window {
            DispatchQueue.main.async { window = nsView.window }
        }
    }
}
