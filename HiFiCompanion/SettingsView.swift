import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Settings window (docs/redesign-0.3.md → Settings window): a native toolbar-tab
/// preferences window (`NSTabViewController` `.toolbar`) with one SwiftUI page per tab.
enum SettingsTab: String, CaseIterable {
    case general, output, apps, diagnostics

    var title: String {
        switch self {
        case .general: return "General"
        case .output: return "Output"
        case .apps: return "Apps"
        case .diagnostics: return "Diagnostics"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .output: return "hifispeaker"
        case .apps: return "square.grid.2x2"
        case .diagnostics: return "waveform.path.ecg"
        }
    }

    /// Page height; the window resizes per tab like System Settings-era preference windows.
    var height: CGFloat {
        switch self {
        case .general: return 400
        case .output: return 440
        case .apps: return 300
        case .diagnostics: return 600
        }
    }

    static let width: CGFloat = 520

    @MainActor
    static func makeTabViewController(model: AppModel, selected: SettingsTab = .general) -> NSTabViewController {
        let controller = NSTabViewController()
        controller.tabStyle = .toolbar
        // No crossfade: it reads as slow loading (Mert, 2026-10-31).
        controller.transitionOptions = [.allowUserInteraction]
        for tab in allCases {
            let page = SettingsPage(tab: tab).environmentObject(model)
            let host = NSHostingController(rootView: page)
            host.preferredContentSize = NSSize(width: width, height: tab.height)
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
            controller.addTabViewItem(item)
        }
        controller.selectedTabViewItemIndex = allCases.firstIndex(of: selected) ?? 0
        return controller
    }
}

private struct SettingsPage: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettingsView()
            case .output: OutputSettingsView()
            case .apps: AppsSettingsView()
            case .diagnostics: DiagnosticsSettingsView()
            }
        }
        .font(.system(size: 13))
        .frame(width: SettingsTab.width, height: tab.height)
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
    @State private var device: OutputDeviceDetails?

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
            }

            Section {
                row("Status", equalizerStatus)
                LabeledContent("Input level") {
                    LevelMeter(dbfs: model.isBridgeRunning ? model.inputLevelDBFS : nil)
                }
                .help("Loudness of what other apps send into the equalizer, before EQ and output gain. 0 dBFS is digital full scale.")
                if let rate = model.equalizerSampleRate {
                    row("Processing", "\(AudioFormatInfo.formatRate(rate)) · 32-bit float")
                }
                row("Bands", bandsText)
                row("Peak boost", EQFormat.gainDB(model.peq.peakBoostDB, fractionDigits: 1))
                row("Output gain", EQFormat.gainDB(model.peq.outputGainDB, fractionDigits: 1) + (model.peq.autoOutputGain ? " (Auto)" : ""))
                row("Headroom", headroomText)
            } header: {
                Text("Parametric Equalizer")
            }

            Section("Output Device") {
                row("Device", model.outputDevice?.name ?? "No hardware output")
                if let device {
                    row("Connection", device.transportLabel)
                    row("Current format", model.deviceFormat?.menuDescription ?? "—")
                    row("Sample rates", device.sampleRatesLabel)
                    row("Bit depths", device.bitDepthsLabel)
                    row("Buffer", device.bufferLabel)
                    row("Output latency", device.outputLatencyLabel)
                }
                row("Following", model.preferredOutputUID == nil ? "macOS output" : "Preferred device")
            }

            Section("Apple Music") {
                row("Apple Music Mode", appleMusicModeText)
                row("Track", trackText)
                row("Other apps on output", model.competingClientSummary ?? "None")
            }

            if let error = model.lastError {
                Section("Last Error") {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            Section {
                row("Version", Self.versionText)
            }
        }
        .formStyle(.grouped)
        // Device facts are HAL reads: refresh every 2 s only while this page is on screen.
        .task {
            while !Task.isCancelled {
                if AuxWindows.shared.isSettingsVisible {
                    let next = model.outputDeviceDetails()
                    if next != device { device = next }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var equalizerStatus: String {
        if let owner = model.exclusiveOutputOwner { return "Unavailable — \(owner) exclusive" }
        guard model.isPassThroughEnabled else { return "Off (not in the signal path)" }
        if model.isBridgeRunning {
            if model.peq.bypass { return "Bypassed" }
            return model.isEQActive ? "Processing (not bit-perfect)" : "Processing · flat"
        }
        if model.outputDevice == nil { return "No hardware output" }
        return model.lastError == nil ? "Reconnecting…" : "Not running"
    }

    private var bandsText: String {
        let bands = model.peq.bands
        guard !bands.isEmpty else { return "None (flat)" }
        let active = bands.filter { $0.enabled && !$0.isAudiblyFlat }.count
        return "\(active) active of \(bands.count)"
    }

    private var headroomText: String {
        let margin = model.peq.safeCeilingDB - model.peq.outputGainDB
        if model.peq.clippingWarning {
            return "Clipping risk (\(EQFormat.gainDB(-margin, fractionDigits: 1, includeUnit: false)) dB over)"
        }
        return "Safe (\(EQFormat.gainDB(margin, fractionDigits: 1, includeUnit: false)) dB spare)"
    }

    private var appleMusicModeText: String {
        guard model.isAppleMusicModeEnabled else { return "Off" }
        return model.isMatchingLocked ? "Paused — other apps are playing" : "Matching the track"
    }

    private var trackText: String {
        guard let format = model.detectedFormat?.menuDescription else { return "—" }
        if let source = model.detectionSourceLabel { return "\(format) (via \(source))" }
        return format
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
        return "\(version) (\(build))"
    }
}

/// Horizontal level bar, −60…0 dBFS; yellow above −6, red above −1.
private struct LevelMeter: View {
    let dbfs: Double?

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * SignalLevel.fraction(dbfs: dbfs))
                        .animation(.easeOut(duration: 0.25), value: dbfs)
                }
            }
            .frame(width: 140, height: 6)
            Text(dbfs.map { "\(EQFormat.gainDB($0, fractionDigits: 0, includeUnit: false)) dBFS" } ?? "Silence")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private var color: Color {
        guard let dbfs else { return .clear }
        if dbfs > -1 { return .red }
        if dbfs > -6 { return .yellow }
        return .green
    }
}
