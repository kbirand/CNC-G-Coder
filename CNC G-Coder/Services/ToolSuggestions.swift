import Foundation

/// Which library bits suit a settings group, from what the group is for and
/// what the project needs: fine V-bits for isolation, the drills that cover
/// a file's hole sizes, a corn bit for the cutout, the mask-removal tool for
/// the mask. Pure scoring over the library, so the menus can show the top
/// picks live with a one-line reason each.
nonisolated enum ToolSuggestions {

    struct Suggestion: Identifiable, Sendable {
        let tool: MachineTool
        /// Why it fits: "V 30° · 0.1 mm tip · PCB feeds".
        let reason: String
        var id: UUID { tool.id }
    }

    /// What the project tells about the job.
    struct Context: Sendable {
        /// The job's material — bits with a preset for it rank higher.
        var material: String = "PCB"
        /// Designed hole sizes of the drill file (drilling groups), mm.
        var holeSizes: [Double] = []
        /// Holes from this size up are milled, not drilled (hole milling).
        var millFrom: Double? = nil
        /// The drilling group's bit tolerance, mm.
        var tolerance: Double = 0.1
    }

    /// What a drawn layer is for, mapped onto the settings groups.
    static func section(for type: CustomLayer.LayerType) -> SettingsSection {
        switch type {
        case .milling: .cutout
        case .engraving: .silk
        case .silkscreen: .silk
        case .drill: .drilling
        }
    }

    /// The best bits for `section`, best first, at most `limit`.
    static func suggest(for section: SettingsSection, tools: [MachineTool], context: Context, limit: Int = 3) -> [Suggestion] {
        let candidates = tools.filter { $0.use.fits(section) }
        var scored: [(MachineTool, Double, [String])] = []
        for tool in candidates {
            guard let (score, why) = score(tool, for: section, context: context) else { continue }
            var reasons = why
            if tool.preset(for: context.material) != nil {
                reasons.append(String(localized: "\(context.material) feeds"))
            }
            let bonus = tool.preset(for: context.material) != nil ? 2.0 : 0
            scored.append((tool, score + bonus, reasons))
        }
        return scored.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.0.name < b.0.name }
            .prefix(limit)
            .map { Suggestion(tool: $0.0, reason: $0.2.joined(separator: " · ")) }
    }

    /// A milling direction for Machine setup, from what is known about the
    /// machine: climb on a rigid machine with closed-loop axes (the Carvera),
    /// conventional on a machine whose measured backlash is large enough to
    /// let a climbing cutter pull the axis into the cut; nothing otherwise.
    static func direction(profile: MachineProfile, backlash: BacklashCompensation.Settings) -> (value: String, reason: String)? {
        if profile.isCarvera {
            return ("climb", String(localized: "The \(profile.name) is rigid with closed-loop axes: climb milling leaves cleaner isolation edges and less burr. Switch to conventional only if you see chatter."))
        }
        let play = max(backlash.x, backlash.y)
        if play >= 0.03 {
            return ("conventional", String(localized: "With \(ParametersStore.format(play)) mm of backlash measured, a climbing cutter can pull the axis into the cut; conventional milling pushes against the play and keeps the width true."))
        }
        return nil
    }

    /// The library drills that cover the file's hole sizes, one per size
    /// (the closest bit within the tolerance; a larger bit before a smaller
    /// one). Sizes no drill covers are returned too.
    static func drills(covering holeSizes: [Double], tools: [MachineTool], context: Context) -> (bits: [MachineTool], uncovered: [Double]) {
        let drills = tools.filter { $0.use == .drilling }
        let sizes = holeSizes.filter { size in context.millFrom.map { size < $0 - 1e-6 } ?? true }
        var chosen: [MachineTool] = []
        var uncovered: [Double] = []
        for size in Set(sizes.map { ($0 * 1000).rounded() / 1000 }).sorted() {
            if let best = bestDrill(for: size, among: drills, tolerance: context.tolerance) {
                if !chosen.contains(where: { $0.id == best.id }) { chosen.append(best) }
            } else {
                uncovered.append(size)
            }
        }
        return (chosen, uncovered)
    }

    /// The drills whose range covers `size`, the one to prefer first: at or
    /// above the designed size, then the closest.
    static func drillsCovering(_ size: Double, among tools: [MachineTool], tolerance: Double) -> [MachineTool] {
        tools.filter { $0.use == .drilling && $0.drillRange(defaultTolerance: tolerance).contains(size) }
            .sorted { a, b in
                let da = a.diameter - size, db = b.diameter - size
                if (da >= 0) != (db >= 0) { return da >= 0 }
                return abs(da) < abs(db)
            }
    }

    /// The drill that takes a hole of `size` among `tools` (the engines'
    /// rule: covering range, closest at or above), nil when none covers it.
    static func bestDrill(for size: Double, among tools: [MachineTool], tolerance: Double) -> MachineTool? {
        drillsCovering(size, among: tools, tolerance: tolerance).first
    }

    // MARK: - Scoring

    private static func score(_ tool: MachineTool, for section: SettingsSection, context: Context) -> (Double, [String])? {
        var score = 0.0
        var why: [String] = []
        let f = ParametersStore.format
        switch section {
        case .isolation, .silk:
            guard tool.shape == .vBit else { return nil }
            if tool.tipDiameter <= 0.1 + 1e-9 { score += 3 } else if tool.tipDiameter <= 0.2 + 1e-9 { score += 1.5 }
            if tool.tipAngle <= 30 + 1e-9 { score += 2 } else if tool.tipAngle <= 45 { score += 0.5 }
            if tool.use == section.ownUse { score += 1 }
            if tool.name.localizedCaseInsensitiveContains("metal") { score += 0.5 }
            why.append(String(localized: "V \(f(tool.tipAngle))° · \(f(tool.tipDiameter)) mm tip"))
            why.append(section == .isolation ? String(localized: "fine isolation") : String(localized: "fine engraving"))

        case .drilling:
            guard tool.use == .drilling else { return nil }
            let sizes = context.holeSizes.filter { size in context.millFrom.map { size < $0 - 1e-6 } ?? true }
            guard !sizes.isEmpty else {
                score = -abs(tool.diameter - 0.8)
                why.append(String(localized: "Ø \(f(tool.diameter)) mm"))
                return (score, why)
            }
            let covered = sizes.filter { tool.drillRange(defaultTolerance: context.tolerance).contains($0) }
            guard !covered.isEmpty else { return nil }
            score = Double(covered.count) * 2 - abs(tool.diameter - (covered.first ?? tool.diameter))
            let distinct = Set(covered.map { f($0) }).sorted()
            why.append(String(localized: "drills the \(distinct.joined(separator: ", ")) mm holes"))
            why.append(String(localized: "\(covered.count) of \(sizes.count) holes"))

        case .holeMill:
            guard tool.shape == .flat, tool.use != .drilling else { return nil }
            let milled = context.holeSizes.filter { size in context.millFrom.map { size >= $0 - 1e-6 } ?? false }
            let smallest = milled.min()
            if let smallest, tool.diameter > smallest - 0.2 { return nil }   // must fit inside the hole
            score += tool.diameter >= 0.8 && tool.diameter <= 2 ? 2 : 0
            score -= abs(tool.diameter - 1.0)
            if tool.name.localizedCaseInsensitiveContains("corn") { score += 1 }
            why.append(String(localized: "Ø \(f(tool.diameter)) mm end mill"))
            if let smallest { why.append(String(localized: "fits the \(f(smallest)) mm holes")) }

        case .cutout:
            guard tool.shape == .flat, tool.use != .drilling else { return nil }
            // 2 mm is the sweet spot for FR4 cutouts: strong, still fine tabs.
            score += tool.diameter >= 0.8 && tool.diameter <= 3.2 ? max(0, 3 - abs(tool.diameter - 2.0) * 3) : -1
            if tool.name.localizedCaseInsensitiveContains("corn") { score += 1 }
            why.append(String(localized: "Ø \(f(tool.diameter)) mm end mill"))
            why.append(String(localized: "board cutout"))

        case .mask:
            if tool.use == .mask { score += 5; why.append(String(localized: "made for mask removal")) }
            else if tool.shape == .flat, tool.diameter <= 1 + 1e-9 { score += 1; why.append(String(localized: "Ø \(f(tool.diameter)) mm end mill")) }
            else if tool.shape == .vBit { score += 0.5; why.append(String(localized: "V \(f(tool.tipAngle))° · \(f(tool.tipDiameter)) mm tip")) }
            else { return nil }

        case .custom, .setup:
            return nil
        }
        return (score, why)
    }
}

extension SettingsSection {
    /// The tool use a group is primarily made for.
    var ownUse: MachineTool.Use? {
        switch self {
        case .isolation: .isolation
        case .drilling: .drilling
        case .holeMill, .cutout: .cutout
        case .mask: .mask
        case .silk: .silk
        case .custom, .setup: nil
        }
    }
}
