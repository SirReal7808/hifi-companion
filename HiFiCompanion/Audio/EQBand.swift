import Foundation

/// Filter family for a PEQ band. Only peaking is implemented in this pass; shelves can be added later.
enum EQFilterType: String, Codable, CaseIterable, Sendable {
    case peaking
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
    static let minQ: Double = 0.1
    static let maxQ: Double = 10
    static let minGainDB: Double = -24
    static let maxGainDB: Double = 24

    /// Default ISO-ish 10-band centers (peaking, 0 dB, Q ≈ 1.41).
    static let defaultFrequenciesHz: [Double] = [
        31.5, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
    ]

    static func defaultTenBands() -> [EQBand] {
        defaultFrequenciesHz.map { hz in
            EQBand(
                id: UUID(),
                enabled: true,
                filterType: .peaking,
                frequencyHz: hz,
                gainDB: 0,
                q: 1.41
            )
        }
    }

    var isAudiblyFlat: Bool {
        !enabled || abs(gainDB) < Self.bypassThresholdDB
    }

    mutating func clamp() {
        frequencyHz = min(Self.maxFrequencyHz, max(Self.minFrequencyHz, frequencyHz))
        gainDB = min(Self.maxGainDB, max(Self.minGainDB, gainDB))
        q = min(Self.maxQ, max(Self.minQ, q))
    }
}
