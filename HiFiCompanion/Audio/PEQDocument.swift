import Combine
import Foundation

/// The EQ "document": used bands, output gain / Auto headroom, bypass, sweep tone level and
/// needle, named profiles, undo / redo, and persistence. Pure model — no Core Audio, no UI.
///
/// The owner applies side effects through `onChange` (push DSP state to the audio path,
/// refresh status text, set the sweep tone level). `sampleRateProvider` supplies the live
/// rate for headroom math.
/// One output device's working curve (docs/redesign-0.3.md → per-device profiles).
struct DeviceCurve: Codable, Equatable {
    var deviceName: String
    var bands: [EQBand]
    var outputGainDB: Double
    var autoOutputGain: Bool
    var bypassGainMatch: Bool
    var toneLevelDB: Double
    var activeProfileName: String?
    var profileDirty: Bool

    /// A device seen for the first time starts flat.
    static func flat(deviceName: String) -> DeviceCurve {
        DeviceCurve(
            deviceName: deviceName, bands: [], outputGainDB: 0, autoOutputGain: true,
            bypassGainMatch: true, toneLevelDB: SweepOscillator.defaultLevelDB,
            activeProfileName: nil, profileDirty: false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case deviceName, bands, outputGainDB, autoOutputGain, bypassGainMatch, toneLevelDB, activeProfileName, profileDirty
    }

    init(
        deviceName: String, bands: [EQBand], outputGainDB: Double, autoOutputGain: Bool,
        bypassGainMatch: Bool, toneLevelDB: Double, activeProfileName: String?, profileDirty: Bool
    ) {
        self.deviceName = deviceName
        self.bands = bands
        self.outputGainDB = outputGainDB
        self.autoOutputGain = autoOutputGain
        self.bypassGainMatch = bypassGainMatch
        self.toneLevelDB = toneLevelDB
        self.activeProfileName = activeProfileName
        self.profileDirty = profileDirty
    }

    /// Tolerant: missing fields take the flat defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let flat = DeviceCurve.flat(deviceName: "")
        deviceName = (try? c.decodeIfPresent(String.self, forKey: .deviceName)) ?? ""
        bands = (try? c.decodeIfPresent([EQBand].self, forKey: .bands)) ?? flat.bands
        outputGainDB = (try? c.decodeIfPresent(Double.self, forKey: .outputGainDB)) ?? flat.outputGainDB
        autoOutputGain = (try? c.decodeIfPresent(Bool.self, forKey: .autoOutputGain)) ?? flat.autoOutputGain
        bypassGainMatch = (try? c.decodeIfPresent(Bool.self, forKey: .bypassGainMatch)) ?? flat.bypassGainMatch
        toneLevelDB = (try? c.decodeIfPresent(Double.self, forKey: .toneLevelDB)) ?? flat.toneLevelDB
        activeProfileName = try? c.decodeIfPresent(String.self, forKey: .activeProfileName)
        profileDirty = (try? c.decodeIfPresent(Bool.self, forKey: .profileDirty)) ?? false
    }
}

/// Versioned container persisted in UserDefaults (`peqDeviceCurves`).
struct DeviceCurveStore: Codable, Equatable {
    static let currentVersion = 1
    var version = DeviceCurveStore.currentVersion
    /// Keyed by Core Audio device UID.
    var devices: [String: DeviceCurve] = [:]
}

@MainActor
final class PEQDocument: ObservableObject {
    /// What an edit touched, so the owner can apply only the needed side effects.
    struct Change: OptionSet {
        let rawValue: Int
        /// Bands / output gain / bypass changed — push to the DSP.
        static let dsp = Change(rawValue: 1 << 0)
        /// Anything shown in menu / status text changed.
        static let status = Change(rawValue: 1 << 1)
        /// Sweep tone level changed.
        static let toneLevel = Change(rawValue: 1 << 2)
    }

    /// |gain| FIX PEAK / FIX DIP apply at the parked needle (Peak = cut, Dip = boost — named for what you hear).
    static let sweepMarkGainDB: Double = 3
    /// Q for bands created / updated via FIX PEAK / FIX DIP.
    static let sweepMarkQ: Double = 3.0
    /// Treat an existing peaking band as "at" the needle within this frequency ratio.
    static let sweepNeedleMatchRatio: Double = 1.04
    /// Knob drag / scroll ticks on one control within this window share one undo step.
    static let continuousEditWindow: TimeInterval = 0.8

    /// Used bands only (0…10).
    @Published private(set) var bands: [EQBand] = []
    @Published private(set) var outputGainDB: Double = 0
    @Published private(set) var bypass = false
    /// Auto-lower output gain to the safe ceiling after band edits (raises ramp).
    @Published private(set) var autoOutputGain = true
    /// When bypassing bands, still apply output gain for loudness-matched A/B.
    @Published private(set) var bypassGainMatch = true
    @Published private(set) var peakBoostDB: Double = 0
    @Published private(set) var clippingWarning = false
    /// Sweep tone level (dBFS into the pre-PEQ mix). Default −12, range −20…0.
    @Published private(set) var toneLevelDB: Double = SweepOscillator.defaultLevelDB
    /// Parked sweep needle frequency (nil until the first press).
    @Published private(set) var sweepNeedleHz: Double?
    @Published private(set) var profileNames: [(id: UUID, name: String)] = []
    /// Loaded / saved profile name; nil shows as Untitled.
    @Published private(set) var activeProfileName: String?
    /// True when the curve changed after the last load / save of `activeProfileName`.
    @Published private(set) var profileDirty = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// Output device whose curve is being edited (nil until the owner reports one).
    @Published private(set) var deviceUID: String?
    @Published private(set) var deviceName: String?

    var onChange: (Change) -> Void = { _ in }
    var sampleRateProvider: () -> Double = { 48_000 }

    private let defaults: UserDefaults
    private let profileStore: EQProfileStore
    private let history = PEQHistory()
    private var suppressingProfileDirty = false
    private var restoringHistory = false
    /// Graph-handle drag: one undo checkpoint for the whole gesture.
    private var dragUndoCaptured = false
    private var continuousEditKey: String?
    private var continuousEditDeadline = Date.distantPast
    /// Smooth Auto / Set-safe / Reset raise of output gain (~2 s).
    private var outputGainRampTask: Task<Void, Never>?
    private let now: () -> Date
    private var deviceCurves = DeviceCurveStore()
    /// A pre-0.3 single curve is still in the legacy keys; the first device adopts it.
    private var legacyCurvePending = false

    private enum Key {
        static let bands = "peqBandsJSON"
        static let outputGain = "peqOutputGainDB"
        static let bypass = "peqBypass"
        static let autoOutputGain = "peqAutoOutputGain"
        static let bypassGainMatch = "peqBypassGainMatch"
        static let clippingWarning = "peqClippingWarning"
        static let toneLevel = "peqToneLevelDB"
        static let sweepNeedle = "peqSweepNeedleHz"
        static let deviceCurves = "peqDeviceCurves"
        /// Pre-0.3 single-curve keys (migrated to the first device, then removed).
        static let legacyCurveKeys = [bands, outputGain, autoOutputGain, bypassGainMatch, toneLevel]
    }

    init(
        defaults: UserDefaults = .standard,
        profileStore: EQProfileStore = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.profileStore = profileStore
        self.now = now
        load()
        refreshProfileList()
    }

    /// Label in the profile menu (e.g. `Moondrop Chu*`).
    var profileDisplayName: String {
        guard let name = activeProfileName, !name.isEmpty else { return "Untitled" }
        return profileDirty ? "\(name)*" : name
    }

    var safeCeilingDB: Double {
        PEQHeadroom.safeCeilingOutputGainDB(peakBoostDB: peakBoostDB)
    }

    // MARK: - Output device

    /// Make `uid` the device being edited: store the current device's curve, load this
    /// one's (or adopt the pre-0.3 curve, or start flat). Undo history does not cross devices.
    func switchDevice(uid: String, name: String) {
        guard uid != deviceUID else {
            if name != deviceName { deviceName = name }
            return
        }
        cancelOutputGainRamp()
        if let current = deviceUID {
            deviceCurves.devices[current] = currentCurve
        }
        let curve: DeviceCurve
        if let stored = deviceCurves.devices[uid] {
            curve = stored
        } else if legacyCurvePending {
            curve = currentCurve
        } else {
            curve = .flat(deviceName: name)
        }
        legacyCurvePending = false
        deviceUID = uid
        deviceName = name
        apply(curve)
        history.clear()
        refreshHistoryButtons()
        continuousEditKey = nil
        dragUndoCaptured = false
        persist()
        Key.legacyCurveKeys.forEach(defaults.removeObject(forKey:))
        onChange([.toneLevel, .dsp, .status])
    }

    private var currentCurve: DeviceCurve {
        DeviceCurve(
            deviceName: deviceName ?? "",
            bands: bands,
            outputGainDB: outputGainDB,
            autoOutputGain: autoOutputGain,
            bypassGainMatch: bypassGainMatch,
            toneLevelDB: toneLevelDB,
            activeProfileName: activeProfileName,
            profileDirty: profileDirty
        )
    }

    private func apply(_ curve: DeviceCurve) {
        suppressingProfileDirty = true
        defer { suppressingProfileDirty = false }
        bands = curve.bands.prefix(EQBand.maxBandCount).map { band in
            var b = band
            b.clamp()
            return b
        }
        autoOutputGain = curve.autoOutputGain
        bypassGainMatch = curve.bypassGainMatch
        toneLevelDB = SweepOscillator.clampLevelDB(curve.toneLevelDB)
        activeProfileName = curve.activeProfileName
        profileDirty = curve.profileDirty
        applyManualOutputGain(curve.outputGainDB)
        if autoOutputGain {
            applyBandChangeHeadroom()
        }
    }

    // MARK: - Bands

    /// Append a peaking band (max 10). Returns the new band id when added.
    @discardableResult
    func addBand() -> UUID? {
        guard bands.count < EQBand.maxBandCount else { return nil }
        captureUndoCheckpoint()
        let band = EQBand.makeBand(frequencyHz: EQBand.nextAddFrequency(existing: bands))
        bands.append(band)
        noteProfileEdited()
        applyBandChangeHeadroom()
        persist()
        onChange([.dsp, .status])
        return band.id
    }

    func removeBand(id: UUID) {
        guard bands.contains(where: { $0.id == id }) else { return }
        captureUndoCheckpoint()
        bands.removeAll { $0.id == id }
        noteProfileEdited()
        applyBandChangeHeadroom()
        persist()
        onChange([.dsp, .status])
    }

    /// Move one band up (−1) or down (+1). Returns false if already at the edge.
    @discardableResult
    func moveBand(id: UUID, by offset: Int) -> Bool {
        guard let index = bands.firstIndex(where: { $0.id == id }) else { return false }
        let target = index + offset
        guard bands.indices.contains(target) else { return false }
        captureUndoCheckpoint()
        bands.swapAt(index, target)
        noteProfileEdited()
        persist()
        onChange([.dsp, .status])
        return true
    }

    func updateBand(id: UUID, mutate: (inout EQBand) -> Void) {
        guard let index = bands.firstIndex(where: { $0.id == id }) else { return }
        captureUndoCheckpoint()
        var band = bands[index]
        mutate(&band)
        band.clamp()
        bands[index] = band
        noteProfileEdited()
        applyBandChangeHeadroom()
        persist()
        onChange([.dsp, .status])
    }

    /// Live graph-handle drag: push coefficients immediately; headroom / persist / status
    /// wait for `commitBandDrag` on mouse-up.
    func previewBandDrag(id: UUID, frequencyHz: Double, gainDB: Double) {
        guard let index = bands.firstIndex(where: { $0.id == id }) else { return }
        if !dragUndoCaptured {
            captureUndoCheckpoint()
            dragUndoCaptured = true
        }
        var band = bands[index]
        band.frequencyHz = frequencyHz
        band.gainDB = gainDB
        band.clamp()
        bands[index] = band
        onChange(.dsp)
    }

    func commitBandDrag() {
        dragUndoCaptured = false
        noteProfileEdited()
        applyBandChangeHeadroom()
        persist()
        onChange([.dsp, .status])
    }

    /// Clear used bands and restore output gain to 0 dB (ramp up if below, immediate if above).
    func resetFlat() {
        cancelOutputGainRamp()
        captureUndoCheckpoint()
        let result = PEQHeadroom.applyResetBands(
            outputGainDB: outputGainDB,
            sampleRate: sampleRateProvider()
        )
        bands = result.bands
        clearActiveProfile()
        peakBoostDB = result.peakBoostDB
        clippingWarning = result.clippingWarning
        switch result.autoAdjustment {
        case .leave:
            outputGainDB = result.outputGainDB
        case .lowerImmediate(let target):
            outputGainDB = target
            clippingWarning = PEQHeadroom.isClippingRisk(outputGainDB: target, peakBoostDB: result.peakBoostDB)
        case .raiseRamp(let target):
            outputGainDB = result.outputGainDB
            startOutputGainRamp(to: target)
        }
        persist()
        onChange([.dsp, .status])
    }

    // MARK: - Output / bypass

    func setBypass(_ bypass: Bool) {
        self.bypass = bypass
        // Bypass is a live A/B, not a profile edit.
        persist()
        onChange([.dsp, .status])
    }

    func setBypassGainMatch(_ match: Bool) {
        guard match != bypassGainMatch else { return }
        captureUndoCheckpoint()
        bypassGainMatch = match
        noteProfileEdited()
        persist()
        onChange([.dsp, .status])
    }

    func setAutoOutputGain(_ auto: Bool) {
        guard auto != autoOutputGain else { return }
        captureUndoCheckpoint()
        autoOutputGain = auto
        noteProfileEdited()
        if auto {
            applyBandChangeHeadroom()
        } else {
            cancelOutputGainRamp()
        }
        persist()
        onChange([.dsp, .status])
    }

    /// `continuous`: knob drag / scroll tick — coalesced into one undo step per run.
    func setOutputGainDB(_ gainDB: Double, continuous: Bool = false) {
        cancelOutputGainRamp()
        if continuous {
            captureContinuousUndoCheckpoint(key: "outputGain")
        } else {
            captureUndoCheckpoint()
        }
        let result = PEQHeadroom.applyManualOutputGain(
            requested: gainDB,
            bands: bands,
            sampleRate: sampleRateProvider()
        )
        outputGainDB = result.outputGainDB
        peakBoostDB = result.peakBoostDB
        clippingWarning = result.clippingWarning
        noteProfileEdited()
        persist()
        onChange([.dsp, .status])
    }

    /// Move output gain to the safe ceiling without turning Auto on.
    /// Raise uses the same ~2 s ramp as Auto; lower is immediate.
    func setOutputGainToSafe() {
        cancelOutputGainRamp()
        captureUndoCheckpoint()
        let result = PEQHeadroom.applySetSafe(
            bands: bands,
            outputGainDB: outputGainDB,
            sampleRate: sampleRateProvider()
        )
        peakBoostDB = result.peakBoostDB
        clippingWarning = result.clippingWarning
        switch result.autoAdjustment {
        case .leave:
            outputGainDB = result.outputGainDB
            persist()
        case .lowerImmediate(let target):
            outputGainDB = target
            clippingWarning = PEQHeadroom.isClippingRisk(outputGainDB: target, peakBoostDB: result.peakBoostDB)
            persist()
        case .raiseRamp(let target):
            outputGainDB = result.outputGainDB
            startOutputGainRamp(to: target)
        }
        onChange([.dsp, .status])
    }

    // MARK: - Sweep

    /// `continuous`: knob drag / scroll tick — coalesced into one undo step per run.
    func setToneLevelDB(_ db: Double, continuous: Bool = false) {
        let clamped = SweepOscillator.clampLevelDB(db)
        guard abs(clamped - toneLevelDB) > 1e-9 else { return }
        if continuous {
            captureContinuousUndoCheckpoint(key: "toneLevel")
        } else {
            captureUndoCheckpoint()
        }
        toneLevelDB = clamped
        noteProfileEdited()
        persist()
        onChange(.toneLevel)
    }

    /// Move the needle (live sweep). Not persisted until `persist()` (sweep release).
    func setSweepNeedle(hz: Double) {
        sweepNeedleHz = min(EQBand.maxFrequencyHz, max(EQBand.minFrequencyHz, hz))
    }

    /// FIX PEAK: you heard a peak → peaking **cut** at the needle.
    @discardableResult
    func applySweepPeak() -> UUID? {
        applySweepMark(gainDB: -Self.sweepMarkGainDB)
    }

    /// FIX DIP: you heard a dip → peaking **boost** at the needle.
    @discardableResult
    func applySweepDip() -> UUID? {
        applySweepMark(gainDB: Self.sweepMarkGainDB)
    }

    /// True when a peaking band already sits at the needle (FIX PEAK / DIP would update it).
    var hasPeakingBandNearNeedle: Bool {
        guard let hz = sweepNeedleHz else { return false }
        return bands.contains { $0.filterType == .peaking && Self.frequenciesMatch($0.frequencyHz, hz) }
    }

    private func applySweepMark(gainDB: Double) -> UUID? {
        guard let hz = sweepNeedleHz else { return nil }
        let q = Self.sweepMarkQ
        if let existing = bands.first(where: { $0.filterType == .peaking && Self.frequenciesMatch($0.frequencyHz, hz) }) {
            // updateBand captures undo.
            updateBand(id: existing.id) {
                $0.enabled = true
                $0.frequencyHz = hz
                $0.gainDB = gainDB
                $0.q = q
                $0.filterType = .peaking
            }
            return existing.id
        }
        guard bands.count < EQBand.maxBandCount else { return nil }
        captureUndoCheckpoint()
        var band = EQBand.makeBand(frequencyHz: hz, filterType: .peaking, gainDB: gainDB, q: q)
        band.enabled = true
        bands.append(band)
        noteProfileEdited()
        applyBandChangeHeadroom()
        persist()
        onChange([.dsp, .status])
        return band.id
    }

    static func frequenciesMatch(_ a: Double, _ b: Double) -> Bool {
        let lo = min(a, b)
        let hi = max(a, b)
        guard lo > 0 else { return abs(a - b) < 1 }
        return hi / lo <= sweepNeedleMatchRatio
    }

    // MARK: - Undo / redo

    func undo() {
        guard let previous = history.popUndo(current: makeSnapshot()) else { return }
        applySnapshot(previous)
        refreshHistoryButtons()
    }

    func redo() {
        guard let next = history.popRedo(current: makeSnapshot()) else { return }
        applySnapshot(next)
        refreshHistoryButtons()
    }

    private func makeSnapshot() -> PEQDocumentSnapshot {
        PEQDocumentSnapshot(
            bands: bands,
            outputGainDB: outputGainDB,
            autoOutputGain: autoOutputGain,
            bypassGainMatch: bypassGainMatch,
            toneLevelDB: toneLevelDB,
            activeProfileName: activeProfileName,
            profileDirty: profileDirty
        )
    }

    private func captureUndoCheckpoint() {
        guard !restoringHistory else { return }
        // Any discrete edit ends a run of continuous knob ticks.
        continuousEditKey = nil
        history.push(makeSnapshot())
        refreshHistoryButtons()
    }

    /// One checkpoint per continuous run on `key`; each tick extends the run.
    private func captureContinuousUndoCheckpoint(key: String) {
        let time = now()
        if continuousEditKey == key, time < continuousEditDeadline {
            continuousEditDeadline = time.addingTimeInterval(Self.continuousEditWindow)
            return
        }
        captureUndoCheckpoint()
        continuousEditKey = key
        continuousEditDeadline = time.addingTimeInterval(Self.continuousEditWindow)
    }

    private func refreshHistoryButtons() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    private func applySnapshot(_ snapshot: PEQDocumentSnapshot) {
        restoringHistory = true
        suppressingProfileDirty = true
        continuousEditKey = nil
        defer {
            restoringHistory = false
            suppressingProfileDirty = false
        }
        cancelOutputGainRamp()
        bands = snapshot.bands
        autoOutputGain = snapshot.autoOutputGain
        bypassGainMatch = snapshot.bypassGainMatch
        toneLevelDB = SweepOscillator.clampLevelDB(snapshot.toneLevelDB)
        activeProfileName = snapshot.activeProfileName
        profileDirty = snapshot.profileDirty
        applyManualOutputGain(snapshot.outputGainDB)
        if autoOutputGain {
            applyBandChangeHeadroom()
        }
        persist()
        onChange([.toneLevel, .dsp, .status])
    }

    // MARK: - Profiles

    func refreshProfileList() {
        profileNames = profileStore.allProfiles().map { ($0.id, $0.name) }
    }

    func profileExists(named name: String) -> Bool {
        profileStore.exists(named: name)
    }

    /// Save a profile. Pass `overwrite: true` only after the user confirms a name collision.
    @discardableResult
    func saveProfile(named name: String, overwrite: Bool = false) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if profileStore.exists(named: trimmed), !overwrite {
            return false
        }
        let snapshot = EQProfile(
            name: trimmed,
            bands: bands,
            outputGainDB: outputGainDB,
            autoOutputGain: autoOutputGain,
            bypassGainMatch: bypassGainMatch,
            toneLevelDB: toneLevelDB
        )
        guard profileStore.save(name: trimmed, profile: snapshot, overwrite: overwrite) != nil else {
            return false
        }
        activeProfileName = trimmed
        profileDirty = false
        refreshProfileList()
        return true
    }

    @discardableResult
    func loadProfile(id: UUID) -> Bool {
        guard let profile = profileStore.profile(id: id) else { return false }
        captureUndoCheckpoint()
        suppressingProfileDirty = true
        defer { suppressingProfileDirty = false }
        cancelOutputGainRamp()
        bands = profile.bands.prefix(EQBand.maxBandCount).map { band in
            var b = band
            b.clamp()
            return b
        }
        autoOutputGain = profile.autoOutputGain
        bypassGainMatch = profile.bypassGainMatch
        toneLevelDB = SweepOscillator.clampLevelDB(profile.toneLevelDB)
        applyManualOutputGain(profile.outputGainDB)
        if autoOutputGain {
            applyBandChangeHeadroom()
        }
        activeProfileName = profile.name
        profileDirty = false
        persist()
        onChange([.toneLevel, .dsp, .status])
        return true
    }

    func deleteProfile(id: UUID) {
        if let profile = profileStore.profile(id: id),
           activeProfileName?.caseInsensitiveCompare(profile.name) == .orderedSame {
            activeProfileName = nil
            profileDirty = false
        }
        profileStore.delete(id: id)
        refreshProfileList()
    }

    private func noteProfileEdited() {
        guard !suppressingProfileDirty, !restoringHistory else { return }
        if activeProfileName != nil {
            profileDirty = true
        }
    }

    private func clearActiveProfile() {
        activeProfileName = nil
        profileDirty = false
    }

    // MARK: - Headroom

    private func applyManualOutputGain(_ requested: Double) {
        let result = PEQHeadroom.applyManualOutputGain(
            requested: requested,
            bands: bands,
            sampleRate: sampleRateProvider()
        )
        outputGainDB = result.outputGainDB
        peakBoostDB = result.peakBoostDB
        clippingWarning = result.clippingWarning
    }

    private func applyBandChangeHeadroom() {
        cancelOutputGainRamp()
        let result = PEQHeadroom.applyBandChange(
            bands: bands,
            outputGainDB: outputGainDB,
            sampleRate: sampleRateProvider(),
            autoOutputGain: autoOutputGain
        )
        peakBoostDB = result.peakBoostDB
        clippingWarning = result.clippingWarning
        switch result.autoAdjustment {
        case .leave:
            outputGainDB = result.outputGainDB
        case .lowerImmediate(let target):
            outputGainDB = target
            clippingWarning = PEQHeadroom.isClippingRisk(outputGainDB: target, peakBoostDB: result.peakBoostDB)
        case .raiseRamp(let target):
            outputGainDB = result.outputGainDB
            startOutputGainRamp(to: target)
        }
    }

    private func cancelOutputGainRamp() {
        outputGainRampTask?.cancel()
        outputGainRampTask = nil
    }

    private func startOutputGainRamp(to target: Double) {
        let start = outputGainDB
        if abs(start - target) < 1e-9 { return }
        let duration = PEQHeadroom.autoRaiseDurationSeconds
        let steps = 40
        outputGainRampTask = Task { @MainActor [weak self] in
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                let gain = PEQHeadroom.rampOutputGainDB(from: start, to: target, progress: Double(i) / Double(steps))
                self.outputGainDB = gain
                self.clippingWarning = PEQHeadroom.isClippingRisk(outputGainDB: gain, peakBoostDB: self.peakBoostDB)
                self.onChange([.dsp, .status])
            }
            guard let self, !Task.isCancelled else { return }
            self.outputGainDB = target
            self.clippingWarning = PEQHeadroom.isClippingRisk(outputGainDB: target, peakBoostDB: self.peakBoostDB)
            self.persist()
            self.onChange([.dsp, .status])
            self.outputGainRampTask = nil
        }
    }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: Key.deviceCurves),
           let store = try? JSONDecoder().decode(DeviceCurveStore.self, from: data) {
            deviceCurves = store
        }
        legacyCurvePending = defaults.object(forKey: Key.bands) != nil
        if let data = defaults.data(forKey: Key.bands),
           let decoded = try? JSONDecoder().decode([EQBand].self, from: data),
           decoded.count <= EQBand.maxBandCount {
            let clamped = decoded.map { band -> EQBand in
                var b = band
                b.clamp()
                return b
            }
            // Migrate legacy "always 10 flat peaking" storage to an empty used-band list.
            if clamped.count == EQBand.maxBandCount,
               clamped.allSatisfy({ $0.isAudiblyFlat && $0.filterType == .peaking }) {
                bands = []
            } else {
                bands = clamped
            }
        } else {
            bands = []
        }
        outputGainDB = defaults.object(forKey: Key.outputGain) as? Double ?? 0
        bypass = defaults.bool(forKey: Key.bypass)
        autoOutputGain = defaults.object(forKey: Key.autoOutputGain) as? Bool ?? true
        bypassGainMatch = defaults.object(forKey: Key.bypassGainMatch) as? Bool ?? true
        if let storedTone = defaults.object(forKey: Key.toneLevel) as? Double {
            toneLevelDB = SweepOscillator.clampLevelDB(storedTone)
        } else {
            toneLevelDB = SweepOscillator.defaultLevelDB
        }
        if let storedNeedle = defaults.object(forKey: Key.sweepNeedle) as? Double,
           storedNeedle >= EQBand.minFrequencyHz, storedNeedle <= EQBand.maxFrequencyHz {
            sweepNeedleHz = storedNeedle
        }
        peakBoostDB = PEQHeadroom.peakBoostDB(bands: bands, sampleRate: 48_000)
        // A persisted warning only matters while still at risk; recompute instead of trusting it.
        clippingWarning = PEQHeadroom.isClippingRisk(outputGainDB: outputGainDB, peakBoostDB: peakBoostDB)
    }

    func persist() {
        if let deviceUID {
            deviceCurves.devices[deviceUID] = currentCurve
            if let data = try? JSONEncoder().encode(deviceCurves) {
                defaults.set(data, forKey: Key.deviceCurves)
            }
        } else {
            // No output known yet: keep the single-curve keys (adopted by the first device).
            if let data = try? JSONEncoder().encode(bands) {
                defaults.set(data, forKey: Key.bands)
            }
            defaults.set(outputGainDB, forKey: Key.outputGain)
            defaults.set(autoOutputGain, forKey: Key.autoOutputGain)
            defaults.set(bypassGainMatch, forKey: Key.bypassGainMatch)
            defaults.set(toneLevelDB, forKey: Key.toneLevel)
            legacyCurvePending = true
        }
        defaults.set(bypass, forKey: Key.bypass)
        defaults.set(clippingWarning, forKey: Key.clippingWarning)
        if let sweepNeedleHz {
            defaults.set(sweepNeedleHz, forKey: Key.sweepNeedle)
        } else {
            defaults.removeObject(forKey: Key.sweepNeedle)
        }
    }
}
