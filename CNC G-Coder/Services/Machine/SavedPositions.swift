import Foundation
import Observation

// Named machine positions (tool-change spot, park, probe clip…), ported from
// the iOS pendant. Stored app-wide in Application Support: they belong to the
// machine, like backlash play, not to a project.

/// A named machine-coordinate position the user wants to return to later.
nonisolated struct SavedPosition: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var position: MachinePosition
    var createdAt: Date

    init(id: UUID = UUID(), name: String, position: MachinePosition, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.position = position
        self.createdAt = createdAt
    }
}

/// Named machine positions, written to disk as JSON on every change.
@MainActor
@Observable
final class SavedPositionsStore {
    private(set) var positions: [SavedPosition] = []
    private(set) var lastSaveError: String?

    private let fileURL: URL

    /// `fileURL` is injectable so the standalone checks can use a temp file.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    // MARK: Mutations

    func add(name: String, position: MachinePosition) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmed.isEmpty ? "Position \(positions.count + 1)" : trimmed
        positions.append(SavedPosition(name: finalName, position: position))
        save()
    }

    func rename(_ id: SavedPosition.ID, to name: String) {
        guard let index = positions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        positions[index].name = trimmed
        save()
    }

    func overwrite(_ id: SavedPosition.ID, with position: MachinePosition) {
        guard let index = positions.firstIndex(where: { $0.id == id }) else { return }
        positions[index].position = position
        save()
    }

    func delete(at offsets: IndexSet) {
        // SwiftUI's `remove(atOffsets:)` is not available with Foundation alone.
        positions = positions.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        save()
    }

    func delete(_ id: SavedPosition.ID) {
        positions.removeAll { $0.id == id }
        save()
    }

    /// Same semantics as SwiftUI's `move(fromOffsets:toOffset:)`: `destination`
    /// is an index into the array *before* removal, as `onMove` supplies it.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = positions.enumerated().filter { source.contains($0.offset) }.map(\.element)
        guard !moving.isEmpty else { return }
        var remaining = positions.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let removedBefore = source.filter { $0 < destination }.count
        let insertAt = min(max(destination - removedBefore, 0), remaining.count)
        remaining.insert(contentsOf: moving, at: insertAt)
        positions = remaining
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        positions = (try? decoder.decode([SavedPosition].self, from: data)) ?? []
    }

    /// Writes synchronously so a position saved just before a crash or app kill is not lost.
    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(positions)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }

    /// `~/Library/Application Support/CNC G-Coder/savedPositions.json`.
    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CNC G-Coder", isDirectory: true)
            .appendingPathComponent("savedPositions.json")
    }
}
