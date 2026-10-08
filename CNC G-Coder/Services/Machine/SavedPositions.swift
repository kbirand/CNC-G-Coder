import Foundation
import Observation

// Named machine positions (tool-change spot, park, probe clip…), ported from
// the iOS pendant. Stored app-wide in Application Support: they belong to the
// machine, like backlash play, not to a project.

/// A named machine-coordinate position the user wants to return to later.
/// Two kinds share the list: a `machine` spot the spindle goes back to
/// (park, tool change, probe clip) and a `workZero` — where work X0 Y0 Z0
/// was in machine coordinates, kept so the same origin can be re-established
/// after a reset or re-homing.
nonisolated struct SavedPosition: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case machine
        case workZero
    }

    var id: UUID
    var name: String
    var position: MachinePosition
    var createdAt: Date
    var kind: Kind
    /// Recorded by the app when a program was sent (Settings → Machine), not by hand.
    var automatic: Bool

    init(id: UUID = UUID(), name: String, position: MachinePosition, createdAt: Date = .now,
         kind: Kind = .machine, automatic: Bool = false) {
        self.id = id
        self.name = name
        self.position = position
        self.createdAt = createdAt
        self.kind = kind
        self.automatic = automatic
    }

    private enum CodingKeys: String, CodingKey { case id, name, position, createdAt, kind, automatic }

    /// Files from before `kind` existed: an entry saved by "Save work zero"
    /// was named "Work zero …", everything else is a machine spot.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        position = try c.decode(MachinePosition.self, forKey: .position)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind)
            ?? (name.lowercased().hasPrefix("work zero") ? .workZero : .machine)
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
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

    /// How many app-recorded work zeros are kept; the oldest go when a new one arrives.
    static let automaticLimit = 20

    func positions(of kind: SavedPosition.Kind) -> [SavedPosition] {
        positions.filter { $0.kind == kind }
    }

    func add(name: String, position: MachinePosition, kind: SavedPosition.Kind = .machine) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmed.isEmpty ? "Position \(positions.count + 1)" : trimmed
        positions.append(SavedPosition(name: finalName, position: position, kind: kind))
        save()
    }

    /// The work zero a program was sent with, recorded by the app. Automatic
    /// entries are capped at `automaticLimit` (oldest first); hand-saved ones
    /// are never touched. Returns the entry added.
    @discardableResult
    func recordAutomaticWorkZero(name: String, position: MachinePosition) -> SavedPosition {
        let entry = SavedPosition(name: name, position: position, kind: .workZero, automatic: true)
        positions.append(entry)
        let automatic = positions.filter(\.automatic).sorted { $0.createdAt < $1.createdAt }
        if automatic.count > Self.automaticLimit {
            let drop = Set(automatic.prefix(automatic.count - Self.automaticLimit).map(\.id))
            positions.removeAll { drop.contains($0.id) }
        }
        save()
        return entry
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
        positions = Self.reordered(positions, fromOffsets: source, toOffset: destination)
        save()
    }

    /// Reorders within one kind's filtered list (the offsets are indexes into
    /// `positions(of:)`); entries of the other kind keep their slots.
    func move(fromOffsets source: IndexSet, toOffset destination: Int, in kind: SavedPosition.Kind) {
        let filtered = Self.reordered(positions(of: kind), fromOffsets: source, toOffset: destination)
        var iterator = filtered.makeIterator()
        positions = positions.map { $0.kind == kind ? (iterator.next() ?? $0) : $0 }
        save()
    }

    /// Deletes the entries at these offsets of one kind's filtered list.
    func delete(at offsets: IndexSet, in kind: SavedPosition.Kind) {
        let ids = Set(positions(of: kind).enumerated().filter { offsets.contains($0.offset) }.map(\.element.id))
        positions.removeAll { ids.contains($0.id) }
        save()
    }

    private static func reordered(_ list: [SavedPosition], fromOffsets source: IndexSet, toOffset destination: Int) -> [SavedPosition] {
        let moving = list.enumerated().filter { source.contains($0.offset) }.map(\.element)
        guard !moving.isEmpty else { return list }
        var remaining = list.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let removedBefore = source.filter { $0 < destination }.count
        let insertAt = min(max(destination - removedBefore, 0), remaining.count)
        remaining.insert(contentsOf: moving, at: insertAt)
        return remaining
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
