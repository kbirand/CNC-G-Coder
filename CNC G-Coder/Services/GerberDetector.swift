import Foundation

/// Auto-detects EasyEDA gerber/drill files in a project folder
/// (Gerber_TopLayer.GTL, Gerber_BottomLayer.GBL, Gerber_BoardOutlineLayer.GKO,
/// solder masks .GTS/.GBS, and every .DRL file).
nonisolated enum GerberDetector {

    static func detect(in folder: URL) -> DetectedFiles {
        var detected = DetectedFiles()

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return detected
        }

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

        detected.front = best(frontCandidates, preferred: ["gerber_toplayer", "toplayer", "top", "front"])
        detected.back = best(backCandidates, preferred: ["gerber_bottomlayer", "bottomlayer", "bottom", "back"])
        detected.outline = best(outlineCandidates, preferred: ["boardoutlinelayer", "outline", "edge"])
        detected.topMask = best(topMaskCandidates, preferred: ["gerber_topsoldermasklayer", "topsoldermask", "gts"])
        detected.bottomMask = best(bottomMaskCandidates, preferred: ["gerber_bottomsoldermasklayer", "bottomsoldermask", "gbs"])

        detected.drills = gerbers
            .filter { $0.pathExtension.lowercased() == "drl" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        return detected
    }
}
