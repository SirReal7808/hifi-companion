import Foundation

/// Document snapshot for EQ undo/redo (bands + related output prefs).
struct PEQDocumentSnapshot: Equatable, Sendable {
    var bands: [EQBand]
    var outputGainDB: Double
    var autoOutputGain: Bool
    var bypassGainMatch: Bool
    var toneLevelDB: Double
    var activeProfileName: String?
    var profileDirty: Bool
}

/// Linear undo/redo stacks for the floating EQ document.
final class PEQHistory: @unchecked Sendable {
    static let maxDepth = 64

    private let lock = NSLock()
    private var undoStack: [PEQDocumentSnapshot] = []
    private var redoStack: [PEQDocumentSnapshot] = []

    var canUndo: Bool {
        lock.lock(); defer { lock.unlock() }
        return !undoStack.isEmpty
    }

    var canRedo: Bool {
        lock.lock(); defer { lock.unlock() }
        return !redoStack.isEmpty
    }

    /// Push `current` before applying a user edit. Clears redo.
    func push(_ current: PEQDocumentSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        if let last = undoStack.last, last == current { return }
        undoStack.append(current)
        if undoStack.count > Self.maxDepth {
            undoStack.removeFirst(undoStack.count - Self.maxDepth)
        }
        redoStack.removeAll(keepingCapacity: true)
    }

    /// Pop undo; return snapshot to restore. Caller must push `current` onto redo.
    func popUndo(current: PEQDocumentSnapshot) -> PEQDocumentSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    func popRedo(current: PEQDocumentSnapshot) -> PEQDocumentSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
