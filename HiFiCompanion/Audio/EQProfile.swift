import Foundation

/// Named snapshot of EQ band curve + related output preferences.
struct EQProfile: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var bands: [EQBand]
    var outputGainDB: Double
    var autoOutputGain: Bool
    var bypassGainMatch: Bool
    var toneLevelDB: Double
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        bands: [EQBand],
        outputGainDB: Double,
        autoOutputGain: Bool,
        bypassGainMatch: Bool,
        toneLevelDB: Double,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bands = bands
        self.outputGainDB = outputGainDB
        self.autoOutputGain = autoOutputGain
        self.bypassGainMatch = bypassGainMatch
        self.toneLevelDB = toneLevelDB
        self.updatedAt = updatedAt
    }
}

/// Persists named EQ profiles under Application Support.
final class EQProfileStore: @unchecked Sendable {
    static let shared = EQProfileStore()

    private let lock = NSLock()
    private var profiles: [EQProfile] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let dir = base.appendingPathComponent("HiFiCompanion", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("eq-profiles.json")
        }
        loadFromDisk()
    }

    func allProfiles() -> [EQProfile] {
        lock.lock(); defer { lock.unlock() }
        return profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func exists(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        return profiles.contains { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Saves a new profile, or overwrites an existing name when `overwrite` is true.
    /// Returns nil when the name collides and `overwrite` is false.
    @discardableResult
    func save(name: String, profile: EQProfile, overwrite: Bool) -> EQProfile? {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Untitled" : trimmed
        var stored = profile
        stored.name = finalName
        stored.updatedAt = Date()
        if let index = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(finalName) == .orderedSame }) {
            guard overwrite else { return nil }
            stored.id = profiles[index].id
            profiles[index] = stored
        } else {
            profiles.append(stored)
        }
        writeLocked()
        return stored
    }

    func profile(id: UUID) -> EQProfile? {
        lock.lock(); defer { lock.unlock() }
        return profiles.first { $0.id == id }
    }

    func delete(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        profiles.removeAll { $0.id == id }
        writeLocked()
    }

    private func loadFromDisk() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else {
            profiles = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        profiles = (try? decoder.decode([EQProfile].self, from: data)) ?? []
    }

    private func writeLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(profiles) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
