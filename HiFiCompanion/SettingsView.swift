import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Settings window (docs/redesign-0.3.md → Settings window).
enum SettingsTab: String, CaseIterable {
    case general, output, apps, diagnostics
}

struct SettingsView: View {
    @State private var tab: SettingsTab

    init(tab: SettingsTab = .general) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            OutputSettingsView()
                .tabItem { Label("Output", systemImage: "hifispeaker") }
                .tag(SettingsTab.output)
            AppsSettingsView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                .tag(SettingsTab.apps)
            DiagnosticsSettingsView()
                .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
                .tag(SettingsTab.diagnostics)
        }
        .font(.system(size: 13))
        .frame(width: 520, height: 460)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var loginItem = LaunchAtLogin()

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                if loginItem.needsApproval {
                    HStack {
                        Text("Allow HiFi Companion in System Settings → Login Items.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = loginItem.error {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section {
                ForEach(MenuBarTitleItem.allCases) { item in
                    Toggle(item.settingsLabel, isOn: Binding(
                        get: { model.menuBarTitleItems.contains(item) },
                        set: { model.setMenuBarTitleItem(item, shown: $0) }
                    ))
                }
                LabeledContent("Preview") {
                    Text(model.menuBarTitle)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Menu Bar Title")
            } footer: {
                Text("With nothing selected, the menu bar shows only “\(MenuBarTitle.placeholder)”.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Appearance", selection: Binding(
                    get: { model.appearancePreference },
                    set: { pref in DispatchQueue.main.async { model.setAppearancePreference(pref) } }
                )) {
                    ForEach(AppearancePreference.allCases) { pref in
                        Text(pref.menuLabel).tag(pref)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }
}

/// `SMAppService.mainApp` wrapper for the Launch at login switch.
@MainActor
private final class LaunchAtLogin: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var error: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = "Could not change Launch at login: \(error.localizedDescription)"
        }
        refresh()
    }
}

// MARK: - Output

private struct OutputSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Preferred output", selection: Binding(
                    get: { model.preferredOutputUID ?? "" },
                    // Defer past the pop-up menu's tracking: this switches the macOS output.
                    set: { uid in DispatchQueue.main.async { model.selectOutput(model.devices.first { $0.uid == uid }) } }
                )) {
                    Text("System Default").tag("")
                    if let uid = model.preferredOutputUID, !model.devices.contains(where: { $0.uid == uid }) {
                        Text("\(curveName(uid) ?? "Preferred device") (not connected)").tag(uid)
                    }
                    ForEach(model.devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            } footer: {
                Text("System Default follows the macOS output. A preferred device becomes the macOS output whenever it is connected; while it is away, HiFi Companion follows macOS.")
                    .foregroundStyle(.secondary)
            }

            Section {
                let curves = model.peq.storedDeviceCurves
                if curves.isEmpty {
                    Text("No device curves yet.").foregroundStyle(.secondary)
                }
                ForEach(curves, id: \.uid) { entry in
                    DeviceCurveRow(
                        uid: entry.uid,
                        curve: entry.curve,
                        isCurrent: entry.uid == model.peq.deviceUID,
                        isConnected: model.devices.contains { $0.uid == entry.uid }
                    )
                }
            } header: {
                Text("Equalizer Curves by Device")
            } footer: {
                Text("Each output keeps its own curve. A device seen for the first time starts flat.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func curveName(_ uid: String) -> String? {
        let name = model.peq.storedDeviceCurves.first { $0.uid == uid }?.curve.deviceName
        return (name?.isEmpty ?? true) ? nil : name
    }
}

private struct DeviceCurveRow: View {
    @EnvironmentObject private var model: AppModel
    let uid: String
    let curve: DeviceCurve
    let isCurrent: Bool
    let isConnected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(curve.deviceName.isEmpty ? uid : curve.deviceName)
                    if isCurrent {
                        Text("Current")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isCurrent {
                Button("Forget") { model.peq.forgetDeviceCurve(uid: uid) }
                    .help("Remove this curve; the device starts flat next time.")
            }
        }
    }

    private var summary: String {
        let profile = curve.activeProfileName.map { curve.profileDirty ? "\($0)*" : $0 } ?? "Untitled"
        let bands = curve.bands.isEmpty ? "Flat" : "\(curve.bands.count) band\(curve.bands.count == 1 ? "" : "s")"
        let state = isConnected ? "" : " · Not connected"
        return "\(profile) · \(bands)\(state)"
    }
}

// MARK: - Apps

private struct AppsSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.excludedAppBundleIDs.isEmpty {
                    Text("No apps excluded.").foregroundStyle(.secondary)
                }
                ForEach(model.excludedAppBundleIDs.map(ExcludedApp.init(bundleID:))) { app in
                    HStack(spacing: 8) {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        }
                        Text(app.displayName)
                        Spacer()
                        Button("Remove") { model.removeExcludedApp(app.bundleID) }
                    }
                }
                HStack {
                    Spacer()
                    Button("Add App…", action: chooseApps)
                }
            } header: {
                Text("Excluded from the Equalizer")
            } footer: {
                Text("For apps that should play without EQ, such as video calls. The list is saved now; the equalizer starts honoring it in a later build.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.title = "Exclude Apps from the Equalizer"
        panel.prompt = "Exclude"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        model.addExcludedApps(ids)
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Signal Path") {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(SignalPathLine.color(for: model.signalPath.state))
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.signalPath.state.label)
                        Text(model.signalPath.detail)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                row("Path", model.pathStatusText)
                if model.isBridgeRunning {
                    row("Equalizer", model.eqStatusText)
                    row("Signal", model.signalMeterText.isEmpty ? "…" : model.signalMeterText)
                }
            }

            Section("Apple Music") {
                row("Track", model.detectedFormat?.menuDescription ?? "—")
                row("Output", model.deviceFormat?.menuDescription ?? "—")
                row("Other apps", model.competingClientSummary ?? "None")
            }

            if let error = model.lastError {
                Section("Last Error") {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            Section {
                HStack {
                    Text("Test tone")
                    Spacer()
                    Button("Play") { model.playTestToneToDAC() }
                        .disabled(!model.isBridgeRunning)
                }
            } footer: {
                Text(model.isBridgeRunning
                     ? "Plays a short tone into the output mix. It proves playback only; Signal shows what the tap hears."
                     : "Turn on Parametric Equalizer for the test tone.")
                    .foregroundStyle(.secondary)
            }

            Section {
                row("Version", Self.versionText)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build)) · \(PEQPanelController.buildStamp)"
    }
}
