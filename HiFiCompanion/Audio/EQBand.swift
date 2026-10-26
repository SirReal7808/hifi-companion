import Foundation

/// Filter family for a PEQ band.
enum EQFilterType: String, Codable, CaseIterable, Sendable {
    case peaking
    case lowShelf
    case highShelf

    /// Short UI label (PK / LS / HS).
    var shortLabel: String {
        switch self {
        case .peaking: return "PK"
        case .lowShelf: return "LS"
        case .highShelf: return "HS"
        }
    }

    var displayName: String {
        switch self {
        case .peaking: return "Peak"
        case .lowShelf: return "Low-shelf"
        case .highShelf: return "High-shelf"
        }
    }
}

struct EQBand: Equatable, Codable, Identifiable, Sendable {
    var id: UUID
    var enabled: Bool
    var filterType: EQFilterType
    var frequencyHz: Double
    var gainDB: Double
    var q: Double

    static let bypassThresholdDB: Double = 0.05
    static let minFrequencyHz: Double = 20
    static let maxFrequencyHz: Double = 20_000
    /// UI allows 0; DSP clamps to a tiny positive Q.
    static let minQ: Double = 0
    static let maxQ: Double = 10
    static let minGainDB: Double = -14
    static let maxGainDB: Double = 14
    static let maxBandCount = 10

    /// Suggested ISO-ish centers when adding bands.
    static let defaultFrequenciesHz: [Double] = [
        31.5, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
    ]

    /// Legacy flat 10-band template (still used by older tests / migration checks).
    static func defaultTenBands() -> [EQBand] {
        defaultFrequenciesHz.map { hz in
            makeBand(frequencyHz: hz, filterType: .peaking)
        }
    }

    /// Fresh band for the “Add Band” control.
    static func makeBand(
        frequencyHz: Double = 1_000,
        filterType: EQFilterType = .peaking,
        gainDB: Double = 0,
        q: Double = 1.41
    ) -> EQBand {
        var band = EQBand(
            id: UUID(),
            enabled: true,
            filterType: filterType,
            frequencyHz: frequencyHz,
            gainDB: gainDB,
            q: q
        )
        band.clamp()
        return band
    }

    /// Next unused default center, or 1 kHz if all are taken.
    static func nextAddFrequency(existing: [EQBand]) -> Double {
        let used = Set(existing.map { ($0.frequencyHz * 10).rounded() / 10 })
        for hz in defaultFrequenciesHz {
            let key = (hz * 10).rounded() / 10
            if !used.contains(key) { return hz }
        }
        return 1_000
    }

    var isAudiblyFlat: Bool {
        !enabled || abs(gainDB) < Self.bypassThresholdDB
    }

    mutating func clamp() {
        frequencyHz = min(Self.maxFrequencyHz, max(Self.minFrequencyHz, frequencyHz))
        gainDB = min(Self.maxGainDB, max(Self.minGainDB, gainDB))
        q = min(Self.maxQ, max(Self.minQ, q))
        // Quantize Q to 0.1 steps for consistent slider/numeric editing.
        q = (q * 10).rounded() / 10
    }
}
