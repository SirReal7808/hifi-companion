import Foundation

/// Reassembles newline-delimited text from arbitrary byte chunks (pipe reads can split a
/// line — or a multi-byte UTF-8 character — anywhere).
struct LineSplitter {
    /// Drop a partial line that never ends (protects against unbounded growth).
    static let maxPendingBytes = 1 << 20

    private var pending = Data()

    /// Appends `chunk` and returns every complete, non-empty line it finished.
    mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        if pending.count > Self.maxPendingBytes {
            pending.removeAll()
        }
        return lines
    }

    mutating func reset() {
        pending.removeAll()
    }
}
