import Foundation

/// Auto-detects the gerber/drill files in a project folder.
///
/// Two naming schemes are understood:
/// - EasyEDA (and Protel-style extensions in general): Gerber_TopLayer.GTL,
///   Gerber_BottomLayer.GBL, Gerber_BoardOutlineLayer.GKO, solder masks
///   .GTS/.GBS, silkscreens .GTO/.GBO, and every .DRL file.
/// - KiCad: `<board>-<layer>.gbr` where the layer id is KiCad's own —
///   F_Cu / B_Cu, Edge_Cuts, F_Mask / B_Mask, F_Silkscreen (F_SilkS before
///   KiCad 6), drills `<board>.drl` or `<board>-PTH.drl` + `<board>-NPTH.drl`.
///   The layer id decides the role on its own, so the board's name can contain
///   words like "top" without confusing the generic rules, and plots the app
///   has no use for (paste, fab, courtyard, drill maps, the .gbrjob) are left
///   out. KiCad exports made with "Use Protel filename extensions" fall under
///   the first scheme.
nonisolated enum GerberDetector {

    static func detect(in folder: URL) -> DetectedFiles {
        detect(files: folderContents(folder))
    }

    /// Things worth telling the user about a folder that detection cannot fix
    /// by itself (currently: KiCad drill files exported as Gerber X2 instead of
    /// Excellon, which pcb2gcode cannot read).
    static func warnings(in folder: URL) -> [String] {
        warnings(files: folderContents(folder))
    }

    private static func folderContents(_ folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// Best guess at what a single imported file is: by name first (the same
    /// rules as folder detection), then by content — Excellon drill files
    /// start with an M48 header whatever they are called.
    static func guessSlot(for url: URL) -> LayerSlot? {
        let detected = detect(files: [url])
        if !detected.drills.isEmpty || isExcellon(url) { return .drill }
        return LayerSlot.allCases.first { $0 != .drill && detected[$0] != nil }
    }

    static func isExcellon(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 512)) ?? Data(), as: UTF8.self)
        return head.split(whereSeparator: \.isNewline).prefix(5)
            .contains { $0.trimmingCharacters(in: .whitespaces).uppercased() == "M48" }
    }

    // MARK: - KiCad layer ids

    /// KiCad's layer id in a plot's name: the part of the stem after the last
    /// "-", lowercased, dots folded to underscores ("F.Cu" in old exports,
    /// "F_Cu" today). A name without "-" yields the whole stem, which never
    /// collides with a KiCad id in practice (EasyEDA: "gerber_toplayer").
    static func kicadLayerID(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let token = stem.split(separator: "-").last.map(String.init) ?? stem
        return token.replacingOccurrences(of: ".", with: "_")
    }

    private static let kicadSlots: [String: LayerSlot] = [
        "f_cu": .front, "b_cu": .back,
        "edge_cuts": .outline,
        "f_mask": .topMask, "b_mask": .bottomMask,
        "f_silks": .topSilk, "f_silkscreen": .topSilk,
        "b_silks": .bottomSilk, "b_silkscreen": .bottomSilk,
    ]

    /// KiCad plots the app has no role for. A file with one of these ids is
    /// kept out of every slot so e.g. "F_Paste" is never taken for a mask.
    private static func isIgnoredKicadLayer(_ id: String) -> Bool {
        let fixed: Set<String> = [
            "f_paste", "b_paste", "f_adhes", "b_adhes", "f_adhesive", "b_adhesive",
            "f_fab", "b_fab", "f_crtyd", "b_crtyd", "f_courtyard", "b_courtyard",
            "dwgs_user", "cmts_user", "eco1_user", "eco2_user", "margin",
            "user_drawings", "user_comments", "user_eco1", "user_eco2",
            "drl_map", "job", "pth", "npth",   // Gerber X2 drill plots (warned about)
        ]
        if fixed.contains(id) { return true }
        if id.hasPrefix("in") && id.hasSuffix("_cu") { return true }   // inner copper
        if id.hasPrefix("user_") { return true }
        if id.hasSuffix("_drl_map") { return true }                     // "<board>-PTH-drl_map"
        return false
    }

    private enum KicadRole: Equatable {
        case slot(LayerSlot)
        case ignored
    }

    /// The role KiCad's layer id gives a file; `nil` when the name is not a
    /// KiCad layer at all.
    private static func kicadRole(_ url: URL) -> KicadRole? {
        if url.pathExtension.lowercased() == "gbrjob" { return .ignored }
        let id = kicadLayerID(url)
        if let slot = kicadSlots[id] { return .slot(slot) }
        if isIgnoredKicadLayer(id) { return .ignored }
        return nil
    }

    // MARK: - Detection

    static func detect(files: [URL]) -> DetectedFiles {
        var detected = DetectedFiles()

        func score(_ name: String, preferred: [String]) -> Int {
            let lower = name.lowercased()
            for (index, token) in preferred.enumerated() where lower.contains(token.lowercased()) {
                return 100 - index
            }
            return 0
        }

        func best(_ candidates: [URL], preferred: [String]) -> URL? {
            candidates.max {
                score($0.lastPathComponent, preferred: preferred) <
                score($1.lastPathComponent, preferred: preferred)
            }
        }

        let all = files.filter { !$0.hasDirectoryPath }
        let roles: [URL: KicadRole] = Dictionary(uniqueKeysWithValues: all.compactMap { url in
            kicadRole(url).map { (url, $0) }
        })
        // Files whose name is not a KiCad layer id: the generic rules apply.
        let gerbers = all.filter { roles[$0] == nil }

        func kicad(_ slot: LayerSlot) -> URL? {
            all.filter { roles[$0] == .slot(slot) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .first
        }

        let frontCandidates = gerbers.filter {
            let ext = $0.pathExtension.lowercased()
            let name = $0.lastPathComponent.lowercased()
            return ext == "gtl" || (ext == "gbr" && (name.contains("top") || name.contains("front")))
        }
        let backCandidates = gerbers.filter {
            let ext = $0.pathExtension.lowercased()
            let name = $0.lastPathComponent.lowercased()
            return ext == "gbl" || (ext == "gbr" && (name.contains("bottom") || name.contains("back")))
        }
        let outlineCandidates = gerbers.filter {
            let ext = $0.pathExtension.lowercased()
            let name = $0.lastPathComponent.lowercased()
            return ext == "gko" || ext == "gml" || name.contains("outline") || name.contains("edge")
        }
        let topMaskCandidates = gerbers.filter {
            let ext = $0.pathExtension.lowercased()
            let name = $0.lastPathComponent.lowercased()
            return ext == "gts" || (name.contains("top") && name.contains("soldermask"))
        }
        let bottomMaskCandidates = gerbers.filter {
            let ext = $0.pathExtension.lowercased()
            let name = $0.lastPathComponent.lowercased()
            return ext == "gbs" || (name.contains("bottom") && name.contains("soldermask"))
        }

        // EasyEDA writes .GTO/.GBO; other tools spell it "silkscreen", "silk"
        // or "legend" in the filename.
        func silkCandidates(_ ext: String, _ side: String) -> [URL] {
            gerbers.filter {
                let e = $0.pathExtension.lowercased()
                let name = $0.lastPathComponent.lowercased()
                let isSilk = name.contains("silk") || name.contains("legend") || name.contains("overlay")
                return e == ext || (isSilk && name.contains(side))
            }
        }
        let topSilkCandidates = silkCandidates("gto", "top")
        let bottomSilkCandidates = silkCandidates("gbo", "bottom")

        detected.front = kicad(.front)
            ?? best(frontCandidates, preferred: ["gerber_toplayer", "toplayer", "top", "front"])
        detected.back = kicad(.back)
            ?? best(backCandidates, preferred: ["gerber_bottomlayer", "bottomlayer", "bottom", "back"])
        detected.outline = kicad(.outline)
            ?? best(outlineCandidates, preferred: ["boardoutlinelayer", "outline", "edge"])
        detected.topMask = kicad(.topMask)
            ?? best(topMaskCandidates, preferred: ["gerber_topsoldermasklayer", "topsoldermask", "gts"])
        detected.bottomMask = kicad(.bottomMask)
            ?? best(bottomMaskCandidates, preferred: ["gerber_bottomsoldermasklayer", "bottomsoldermask", "gbs"])

        detected.topSilk = kicad(.topSilk)
            ?? best(topSilkCandidates, preferred: ["gerber_topsilkscreenlayer", "topsilkscreen", "topsilk", "gto"])
        detected.bottomSilk = kicad(.bottomSilk)
            ?? best(bottomSilkCandidates, preferred: ["gerber_bottomsilkscreenlayer", "bottomsilkscreen", "bottomsilk", "gbo"])

        detected.drills = all
            .filter { ["drl", "xln", "exc", "drd"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        return detected
    }

    static func warnings(files: [URL]) -> [String] {
        let hasExcellon = files.contains { ["drl", "xln", "exc", "drd"].contains($0.pathExtension.lowercased()) }
        guard !hasExcellon else { return [] }
        let x2Drills = files.filter {
            $0.pathExtension.lowercased() == "gbr" && ["pth", "npth"].contains(kicadLayerID($0))
        }
        guard !x2Drills.isEmpty else { return [] }
        let names = x2Drills.map(\.lastPathComponent).sorted().joined(separator: ", ")
        return ["\(names): Gerber X2 drill files are not supported — in KiCad's drill dialog choose the Excellon format (the .drl files) and export again."]
    }
}
