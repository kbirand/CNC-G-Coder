import Foundation
import CoreGraphics

/// Builds pcb2gcode/gerbv command lines and runs generation batches.
/// The same batch serves both the live preview (temp dir) and the final
/// Generate (Generated_GCode in the project folder).
nonisolated enum Pcb2GcodeService {

    struct BatchResult: Sendable {
        var outputs: [GeneratedOutput] = []
        var log = ""
        var succeeded = true
        /// Project extent (mm) when origins were normalized; the back-side
        /// frame is the mirror image of the front frame across this rectangle.
        var projectSize: CGSize?
    }

    // MARK: - Argument building (ported from the reference app)

    static func isolationArgs(_ p: ParameterSnapshot, files: DetectedFiles, outputDir: URL) -> [String] {
        var a: [String] = [
            "--metric",
            "--metricoutput",
            // Without this, pcb2gcode keeps the tool at cutting depth and drives
            // straight through waste-copper areas between contours ("path
            // finding") — scratching the board and making travel unreadable in
            // the preview. Disabled: it retracts and rapids instead.
            "--path-finding-limit", "0",
            "--mill-diameters", "\(p.millDiameter)mm",
            "--isolation-width", "\(p.isolationWidth)mm",
            "--zwork", "\(p.zWork)mm",
            "--mill-feed", "\(p.millFeed)mm/minute",
            "--mill-vertfeed", "\(p.millVertFeed)mm/minute",
            "--mill-speed", p.millSpeed,
            "--zsafe", "\(p.zSafe)mm",
            "--zchange", "\(p.zChange)mm",
            "--mirror-axis", "\(p.mirrorAxis)mm"
        ]

        // Never pcb2gcode's --zero-start: it zeroes each INVOCATION on its own
        // extents, so copper, drills and masks would get origins differing by
        // millimeters (mutual misregistration on the machine). All invocations
        // run in the shared Gerber frame; zeroing is done afterwards by
        // normalizeOrigins() with one common shift per board side.
        if p.mirrorYAxis { a.append("--mirror-yaxis") }

        if let front = files.front {
            a += ["--front", front.path,
                  "--front-output", outputDir.appendingPathComponent("front.ngc").path]
        }
        if let back = files.back {
            a += ["--back", back.path,
                  "--back-output", outputDir.appendingPathComponent("back.ngc").path]
        }
        if let outline = files.outline {
            a += [
                "--outline", outline.path,
                "--cutter-diameter", "\(p.cutterDiameter)mm",
                "--zcut", "\(p.zCut)mm",
                "--cut-feed", "\(p.cutFeed)mm/minute",
                "--cut-vertfeed", "\(p.cutVertFeed)mm/minute",
                "--cut-speed", p.cutSpeed,
                "--cut-infeed", "\(p.cutInfeed)mm",
                "--bridges", "\(p.bridgeWidth)mm",
                "--bridgesnum", p.bridgeCount,
                "--zbridges", "\(p.zBridge)mm",
                "--outline-output", outputDir.appendingPathComponent("outline.ngc").path
            ]
        }

        return a
    }

    static func drillArgs(_ p: ParameterSnapshot, drill: URL, output: URL) -> [String] {
        var a: [String] = [
            "--metric",
            "--metricoutput",
            "--drill", drill.path,
            "--zdrill", "\(p.zDrill)mm",
            "--drill-feed", "\(p.drillFeed)mm/minute",
            "--drill-speed", p.drillSpeed,
            "--drill-side", "front",
            "--nog81",
            "--drill-output", output.path,
            "--zsafe", "\(p.zSafe)mm",
            "--zchange", "\(p.zChange)mm",
            "--mirror-axis", "\(p.mirrorAxis)mm"
        ]
        if p.mirrorYAxis { a.append("--mirror-yaxis") }   // zeroing: see normalizeOrigins()
        return a
    }

    static func drillOutputURL(for drill: URL, index: Int, outputDir: URL) -> URL {
        let stem = drill.deletingPathExtension().lastPathComponent
        return outputDir.appendingPathComponent("drill_\(index + 1)_\(stem).ngc")
    }

    /// Solder-mask etch: the mask Gerbers describe the OPENINGS (pads/vias to
    /// stay exposed). With --invert-gerbers, isolation milling clears the
    /// inside of each opening — engraving the cured mask off the pads.
    static func maskArgs(_ p: ParameterSnapshot, files: DetectedFiles, outputDir: URL) -> [String] {
        var a: [String] = ["--metric", "--metricoutput"]

        if let topMask = files.topMask {
            a += ["--front", topMask.path,
                  "--front-output", outputDir.appendingPathComponent("mask_top.ngc").path]
        }
        if let bottomMask = files.bottomMask {
            a += ["--back", bottomMask.path,
                  "--back-output", outputDir.appendingPathComponent("mask_bottom.ngc").path]
        }

        a += [
            "--invert-gerbers",
            "--path-finding-limit", "0",   // never drag the tool through cured mask between openings
            "--mill-diameters", "\(p.maskTool)mm",
            "--milling-overlap", "40%",
            // Clearing is bounded by each opening's own geometry, but pcb2gcode's
            // generation time explodes with this width — keep it just above half
            // the widest opening (user-tunable), never a blanket large value.
            "--isolation-width", "\(p.maskClearWidth)mm",
            "--zwork", "\(p.maskDepth)mm",
            "--mill-feed", "\(p.maskFeed)mm/minute",
            "--mill-vertfeed", "\(p.maskVertFeed)mm/minute",
            "--mill-speed", p.maskSpeed,
            "--zsafe", "\(p.zSafe)mm",
            "--zchange", "\(p.zChange)mm",
            "--mirror-axis", "\(p.mirrorAxis)mm"
        ]

        if p.mirrorYAxis { a.append("--mirror-yaxis") }   // zeroing: see normalizeOrigins()
        return a
    }

    /// The isolation command line, for the "Copy Command" button.
    static func previewCommand(pcb2gcode: URL?, params p: ParameterSnapshot, files: DetectedFiles, outputDir: URL) -> String {
        guard let pcb2gcode else { return "pcb2gcode not found" }
        let args = isolationArgs(p, files: files, outputDir: outputDir)
        return ([pcb2gcode.path] + args).map(ProcessRunner.shellQuote).joined(separator: " ")
    }

    // MARK: - Batch execution

    /// Runs one pcb2gcode invocation, timing it and appending output to the log.
    private static func runStep(_ label: String, pcb2gcode: URL, args: [String],
                                outputDir: URL, result: inout BatchResult) async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let r = try await ProcessRunner.run(executable: pcb2gcode, arguments: args, currentDirectory: outputDir)
            let elapsed = start.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
            result.log += "$ \(r.commandLine)\n\(r.output)\n"
            result.log += String(format: "%@ finished in %.1fs\n", label, seconds)
            if r.exitCode != 0 {
                result.log += "\(label) failed with exit code \(r.exitCode)\n"
                result.succeeded = false
            }
        } catch {
            result.log += "ERROR launching pcb2gcode: \(error.localizedDescription)\n"
            result.succeeded = false
        }
    }

    /// Runs one full pcb2gcode batch: copper + outline first (one invocation),
    /// then one invocation per drill file (pcb2gcode accepts a single --drill each),
    /// then the solder-mask etch (separate invocation: inversion must not apply
    /// to the copper layers).
    static func runBatch(pcb2gcode: URL, params p: ParameterSnapshot, files: DetectedFiles, outputDir: URL) async -> BatchResult {
        var result = BatchResult()
        let fm = FileManager.default
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        if files.front != nil || files.back != nil || files.outline != nil {
            await runStep("Isolation/outline generation", pcb2gcode: pcb2gcode,
                          args: isolationArgs(p, files: files, outputDir: outputDir),
                          outputDir: outputDir, result: &result)
        }

        for (index, drill) in files.drills.enumerated() {
            if Task.isCancelled {
                result.succeeded = false
                return result
            }
            let out = drillOutputURL(for: drill, index: index, outputDir: outputDir)
            await runStep("Drill generation (\(drill.lastPathComponent))", pcb2gcode: pcb2gcode,
                          args: drillArgs(p, drill: drill, output: out),
                          outputDir: outputDir, result: &result)
        }

        if p.maskMode == "gcode", files.topMask != nil || files.bottomMask != nil, !Task.isCancelled {
            await runStep("Solder-mask etch generation", pcb2gcode: pcb2gcode,
                          args: maskArgs(p, files: files, outputDir: outputDir),
                          outputDir: outputDir, result: &result)
        }

        // Collect the outputs that actually exist.
        func addIfExists(_ layer: LayerKind, _ url: URL, tool: String?) {
            if fm.fileExists(atPath: url.path) {
                result.outputs.append(GeneratedOutput(layer: layer, url: url,
                                                      toolDiameter: tool.flatMap(Double.init)))
            }
        }
        if files.front != nil { addIfExists(.front, outputDir.appendingPathComponent("front.ngc"), tool: p.millDiameter) }
        if files.back != nil { addIfExists(.back, outputDir.appendingPathComponent("back.ngc"), tool: p.millDiameter) }
        if files.outline != nil { addIfExists(.outline, outputDir.appendingPathComponent("outline.ngc"), tool: p.cutterDiameter) }
        for (index, drill) in files.drills.enumerated() {
            let stem = drill.deletingPathExtension().lastPathComponent
            addIfExists(.drill(index: index, name: stem),
                        drillOutputURL(for: drill, index: index, outputDir: outputDir),
                        tool: nil)   // bit sizes vary per hole; not modeled
        }
        if p.maskMode == "gcode" {
            if files.topMask != nil { addIfExists(.maskTop, outputDir.appendingPathComponent("mask_top.ngc"), tool: p.maskTool) }
            if files.bottomMask != nil { addIfExists(.maskBottom, outputDir.appendingPathComponent("mask_bottom.ngc"), tool: p.maskTool) }
        }

        if let clearance = Double(p.plungeClearance), clearance > 0,
           result.succeeded, !result.outputs.isEmpty {
            optimizePlunges(clearance: clearance, outputs: result.outputs, log: &result.log)
        }

        if p.zeroStart, result.succeeded, !result.outputs.isEmpty {
            result.projectSize = normalizeOrigins(p, outputs: result.outputs, log: &result.log)
        }

        return result
    }

    // MARK: - Plunge optimization

    /// pcb2gcode feeds vertical moves over their whole length — a plunge from
    /// Safe Z descends the air gap at the plunge feed, and drill retracts come
    /// back up at feed too. This pass splits every feed move that crosses the
    /// clearance plane: descents rapid down to `clearance` above the board and
    /// feed only the rest; ascents feed up to `clearance` (pulling out of the
    /// material) and rapid the remainder. The bit still enters and leaves the
    /// work at the programmed feed — only air travel becomes rapid.
    private static func optimizePlunges(clearance: Double, outputs: [GeneratedOutput], log: inout String) {
        var splits = 0
        for output in outputs {
            do {
                splits += try optimizePlunges(clearance: clearance, file: output.url)
            } catch {
                log += "WARNING: could not optimize plunges in \(output.url.lastPathComponent): \(error.localizedDescription)\n"
            }
        }
        if splits > 0 {
            log += String(format: "Plunge optimization: %d vertical moves split at %.2f mm clearance (air travel now rapid).\n",
                          splits, clearance)
        }
    }

    private static func optimizePlunges(clearance: Double, file: URL) throws -> Int {
        let text = try String(contentsOf: file, encoding: .utf8)
        let eps = 1e-6
        var out: [String] = []
        var modalG: Int?
        var currentZ: Double?
        var splits = 0

        for lineSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSub)
            let code = strippedOfComments(line)
            let words = motionWords(code)

            if let g = words.g { modalG = g }
            let isMotion = words.g.map { $0 <= 3 } ?? (modalG.map { $0 <= 3 } ?? false) && words.hasAny
            guard isMotion, let z = words.z else {
                out.append(line)
                if let z = words.z { currentZ = z }
                continue
            }

            let effectiveG = words.g ?? modalG ?? 0
            let zOnly = !words.hasXY
            defer { currentZ = z }

            if effectiveG == 1, zOnly, let startZ = currentZ {
                if startZ > clearance + eps, z < clearance - eps {
                    // Descent: rapid through the air, feed from the clearance down.
                    out.append(String(format: "G00 Z%.5f ( rapid to plunge clearance )", clearance))
                    out.append(words.g == nil ? "G01 " + line : line)
                    splits += 1
                    continue
                }
                if startZ < clearance - eps, z > clearance + eps {
                    // Ascent: feed out of the material, rapid the rest of the way up.
                    out.append(replacingZ(in: words.g == nil ? "G01 " + line : line, with: clearance))
                    out.append(String(format: "G00 Z%.5f ( rapid retract )", z))
                    splits += 1
                    continue
                }
            }
            out.append(line)
        }

        if splits > 0 {
            try out.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        return splits
    }

    private static func strippedOfComments(_ line: String) -> String {
        var out = ""
        var inComment = false
        for c in line {
            if c == "(" { inComment = true; continue }
            if c == ")" { inComment = false; continue }
            if c == ";" { break }
            if !inComment { out.append(c) }
        }
        return out
    }

    /// G number, Z value, and X/Y presence of one comment-free G-code line.
    private static func motionWords(_ code: String) -> (g: Int?, z: Double?, hasXY: Bool, hasAny: Bool) {
        var g: Int?
        var z: Double?
        var hasXY = false
        var hasAny = false
        let chars = Array(code.uppercased())
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "G" || c == "X" || c == "Y" || c == "Z" {
                var j = i + 1
                var number = ""
                if j < chars.count, chars[j] == "-" || chars[j] == "+" { number.append(chars[j]); j += 1 }
                var digits = false
                while j < chars.count, chars[j].isNumber || chars[j] == "." {
                    if chars[j].isNumber { digits = true }
                    number.append(chars[j]); j += 1
                }
                if digits, let value = Double(number) {
                    switch c {
                    case "G": g = Int(value)
                    case "Z": z = value; hasAny = true
                    default: hasXY = true; hasAny = true
                    }
                    i = j
                    continue
                }
            }
            i += 1
        }
        return (g, z, hasXY, hasAny)
    }

    /// Replaces the number of the (single) Z word outside comments.
    private static func replacingZ(in line: String, with value: Double) -> String {
        var out = ""
        var inComment = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "(" { inComment = true }
            if c == ")" { inComment = false }
            if !inComment, c == "Z" || c == "z" {
                var j = i + 1
                if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
                var digits = false
                while j < chars.count, chars[j].isNumber || chars[j] == "." {
                    if chars[j].isNumber { digits = true }
                    j += 1
                }
                if digits {
                    out.append(c)
                    out.append(String(format: "%.5f", value))
                    i = j
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    // MARK: - Origin normalization

    /// pcb2gcode's own --zero-start zeroes each invocation on its own extents,
    /// so copper, drills and masks end up with origins that differ by
    /// millimeters — mutually misregistered even when the machine is zeroed at
    /// the same corner for every program. Instead, all invocations run in the
    /// shared Gerber frame and this pass applies ONE shift to every front-side
    /// program (project min corner → X0/Y0) and the mirrored shift to every
    /// back-side program. Result: zero the machine once per side and every
    /// program lines up; the back frame is the exact mirror image of the front
    /// frame across the project rectangle (which is what the preview's
    /// "Flip Back View" uses to overlay them).
    private static func isBackSide(_ kind: LayerKind) -> Bool {
        kind == .back || kind == .maskBottom
    }

    private static func normalizeOrigins(_ p: ParameterSnapshot, outputs: [GeneratedOutput], log: inout String) -> CGSize? {
        let axis = Double(p.mirrorAxis) ?? 0

        // Union of all program extents, unmirrored into the Gerber frame.
        var union = CGRect.null
        var measured = Set<Int>()
        for (index, output) in outputs.enumerated() {
            guard let extent = fileExtent(output.url) else { continue }
            measured.insert(index)
            union = union.union(isBackSide(output.layer)
                                ? mirrored(extent, axis: axis, yAxis: p.mirrorYAxis)
                                : extent)
        }
        guard !union.isNull, union.width > 0 || union.height > 0 else { return nil }

        let frontShift: (dx: Double, dy: Double) = (-union.minX, -union.minY)
        let backShift: (dx: Double, dy: Double) = p.mirrorYAxis
            ? (-union.minX, -(2 * axis - union.maxY))
            : (-(2 * axis - union.maxX), -union.minY)

        for (index, output) in outputs.enumerated() where measured.contains(index) {
            let shift = isBackSide(output.layer) ? backShift : frontShift
            do {
                try shiftFile(output.url, dx: shift.dx, dy: shift.dy)
            } catch {
                log += "WARNING: could not normalize \(output.url.lastPathComponent): \(error.localizedDescription)\n"
            }
        }

        log += String(format: "Origins normalized: project %.2f × %.2f mm — all programs share one origin per side (zero the machine once per side).\n",
                      union.width, union.height)
        return CGSize(width: union.width, height: union.height)
    }

    private static func mirrored(_ rect: CGRect, axis: Double, yAxis: Bool) -> CGRect {
        if yAxis {
            return CGRect(x: rect.minX, y: 2 * axis - rect.maxY, width: rect.width, height: rect.height)
        }
        return CGRect(x: 2 * axis - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
    }

    /// X/Y extent of the motion words in a G-code file (comments excluded).
    private static func fileExtent(_ url: URL) -> CGRect? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            scanCoordinateWords(in: line) { letter, value in
                if letter == "X" {
                    minX = min(minX, value); maxX = max(maxX, value)
                } else {
                    minY = min(minY, value); maxY = max(maxY, value)
                }
                return nil
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Rewrites a G-code file with every X/Y word (outside comments) translated.
    /// I/J arc offsets are relative and stay untouched; Z/F words untouched.
    private static func shiftFile(_ url: URL, dx: Double, dy: Double) throws {
        guard dx != 0 || dy != 0 else { return }
        let text = try String(contentsOf: url, encoding: .utf8)
        let shifted = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            scanCoordinateWords(in: line) { letter, value in
                let v = value + (letter == "X" ? dx : dy)
                return String(format: "%.5f", abs(v) < 5e-6 ? 0 : v)
            }
        }.joined(separator: "\n")
        try shifted.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Walks one line, invoking `handle` for each X/Y coordinate word outside
    /// parenthesis comments. If `handle` returns a replacement string, it is
    /// substituted; the (possibly rewritten) line is returned.
    @discardableResult
    private static func scanCoordinateWords(
        in line: Substring,
        handle: (_ letter: Character, _ value: Double) -> String?
    ) -> String {
        var out = String()
        out.reserveCapacity(line.count + 16)
        let chars = Array(line)
        var inComment = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "(" { inComment = true }
            if c == ")" { inComment = false }
            if !inComment, c == "X" || c == "Y" {
                var j = i + 1
                var number = ""
                if j < chars.count, chars[j] == "-" || chars[j] == "+" {
                    number.append(chars[j]); j += 1
                }
                var hasDigits = false
                while j < chars.count, chars[j].isNumber || chars[j] == "." {
                    if chars[j].isNumber { hasDigits = true }
                    number.append(chars[j]); j += 1
                }
                if hasDigits, let value = Double(number) {
                    out.append(c)
                    out.append(handle(c, value) ?? number)
                    i = j
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Exports solder-mask openings (and the board outline for reference) as SVGs
    /// via gerbv, into <outputDir>/Laser_SolderMask. Final Generate only.
    static func exportMaskSVGs(gerbv: URL, files: DetectedFiles, outputDir: URL) async -> BatchResult {
        var result = BatchResult()
        let laserDir = outputDir.appendingPathComponent("Laser_SolderMask", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: laserDir, withIntermediateDirectories: true)
        } catch {
            result.log += "ERROR creating Laser_SolderMask folder: \(error.localizedDescription)\n"
            result.succeeded = false
            return result
        }

        func export(_ input: URL, to name: String, label: String) async {
            let out = laserDir.appendingPathComponent(name)
            do {
                let r = try await ProcessRunner.run(executable: gerbv, arguments: ["-x", "svg", "-o", out.path, input.path], currentDirectory: laserDir)
                result.log += "$ \(r.commandLine)\n\(r.output)\n"
                if r.exitCode != 0 {
                    result.log += "\(label) SVG export failed with exit code \(r.exitCode)\n"
                    result.succeeded = false
                }
            } catch {
                result.log += "ERROR launching gerbv: \(error.localizedDescription)\n"
                result.succeeded = false
            }
        }

        if let topMask = files.topMask {
            await export(topMask, to: "soldermask_top_openings.svg", label: "Top solder-mask")
        }
        if let bottomMask = files.bottomMask {
            await export(bottomMask, to: "soldermask_bottom_openings.svg", label: "Bottom solder-mask")
        }
        // Reference geometry only; never laser/cut the outline SVG.
        if let outline = files.outline {
            await export(outline, to: "REFERENCE_board_outline.svg", label: "Board outline reference")
        }

        result.log += "Solder-mask laser SVGs written to: \(laserDir.path)\n"
        return result
    }
}
