import Foundation

/// Shared display helpers for EQ frequency / gain readouts.
enum EQFormat {
    static func frequency(_ hz: Double) -> String {
        if hz >= 1_000 {
            let k = hz / 1_000
            if abs(k - k.rounded()) < 0.05 {
                return String(format: "%.0f kHz", k.rounded())
            }
            return String(format: "%.2f kHz", k)
        }
        if hz >= 100 {
            return String(format: "%.0f Hz", hz)
        }
        return String(format: "%.1f Hz", hz)
    }

    /// Formats a gain in dB. Values that round to 0.0 at `fractionDigits` render as
    /// `0.0` / `0` with no sign (never `+0.0` or `-0.0`). Non-zero keeps an explicit sign.
    static func gainDB(
        _ value: Double,
        fractionDigits: Int = 1,
        includeUnit: Bool = true
    ) -> String {
        let digits = max(0, fractionDigits)
        let factor = pow(10.0, Double(digits))
        let scaled = (value * factor).rounded()
        let number: String
        if scaled == 0 {
            number = String(format: "%.\(digits)f", 0.0)
        } else {
            number = String(format: "%+.\(digits)f", scaled / factor)
        }
        return includeUnit ? "\(number) dB" : number
    }
}
