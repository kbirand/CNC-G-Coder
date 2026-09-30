import Foundation

/// Auto-detects EasyEDA gerber/drill files in a project folder
/// (Gerber_TopLayer.GTL, Gerber_BottomLayer.GBL, Gerber_BoardOutlineLayer.GKO,
/// solder masks .GTS/.GBS, silkscreens .GTO/.GBO, and every .DRL file).
nonisolated enum GerberDetector {

    static func detect(in folder: URL) -> DetectedFiles {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return DetectedFiles()
        }
        return detect(files: files)
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

        let gerbers = files.filter { !$0.hasDirectoryPath }

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

        detected.front = best(frontCandidates, preferred: ["gerber_toplayer", "toplayer", "top", "front"])
        detected.back = best(backCandidates, preferred: ["gerber_bottomlayer", "bottomlayer", "bottom", "back"])
        detected.outline = best(outlineCandidates, preferred: ["boardoutlinelayer", "outline", "edge"])
        detected.topMask = best(topMaskCandidates, preferred: ["gerber_topsoldermasklayer", "topsoldermask", "gts"])
        detected.bottomMask = best(bottomMaskCandidates, preferred: ["gerber_bottomsoldermasklayer", "bottomsoldermask", "gbs"])

        detected.topSilk = best(topSilkCandidates, preferred: ["gerber_topsilkscreenlayer", "topsilkscreen", "topsilk", "gto"])
        detected.bottomSilk = best(bottomSilkCandidates, preferred: ["gerber_bottomsilkscreenlayer", "bottomsilkscreen", "bottomsilk", "gbo"])

        detected.drills = gerbers
            .filter { ["drl", "xln", "exc", "drd"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        return detected
    }
}
