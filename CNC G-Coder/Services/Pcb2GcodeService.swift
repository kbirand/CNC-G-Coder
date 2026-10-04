import Foundation
import CoreGraphics
import CryptoKit

/// Builds pcb2gcode/gerbv command lines and runs generation batches.
/// The same batch serves both the live preview (temp dir) and the final
/// Generate (Generated_GCode in the project folder).
nonisolated enum Pcb2GcodeService {

    struct BatchResult: Sendable {
        var outputs: [GeneratedOutput] = []
        var log = ""
        var succeeded = true
        /// Where X0/Y0 was put when origins were normalized.
        var frame: ProjectFrame?
    }

    // MARK: - Argument building (ported from the reference app)

    /// Where a layer's program is written. One naming rule for every layer,
    /// matching the laser artwork's filenames.
    static func outputURL(for layer: LayerKind, in directory: URL) -> URL {
        directory.appendingPathComponent(layer.fileSlug + ".ngc")
    }

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
            "--milling-overlap", "\(p.millOverlap)%",
            "--zwork", "\(p.zWork)mm",
            "--mill-feed", "\(p.millFeed)mm/minute",
            "--mill-vertfeed", "\(p.millVertFeed)mm/minute",
            "--mill-speed", p.millSpeed,
            "--zsafe", "\(p.zSafe(.iso))mm",
            "--zchange", "\(p.zChange(.iso))mm",
            "--mirror-axis", "\(p.mirrorAxis)mm"
        ]
        a += infeedArgs(depthPerPass: p.millInfeed, depth: p.zWork)
        a += commonMillingArgs(p, .iso)

        // Never pcb2gcode's --zero-start: it zeroes each INVOCATION on its own
        // extents, so copper, drills and masks would get origins differing by
        // millimeters (mutual misregistration on the machine). All invocations
        // run in the shared Gerber frame; zeroing is done afterwards by
        // normalizeOrigins() with one common shift per board side.
        // Must carry its value: unlike --metric/--nog81, pcb2gcode declares
        // --mirror-yaxis with no implicit value, so a bare flag eats the next
        // argument ("the argument ('--front-output') ... is invalid").
        if p.mirrorYAxis { a.append("--mirror-yaxis=1") }

        if let front = files.front {
            a += ["--front", front.path,
                  "--front-output", outputURL(for: .front, in: outputDir).path]
        }
        if let back = files.back {
            a += ["--back", back.path,
                  "--back-output", outputURL(for: .back, in: outputDir).path]
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
                "--outline-output", outputURL(for: .outline, in: outputDir).path
            ]
        }

        return a
    }

    /// The outline on its own: none of the isolation settings, which do not
    /// affect it (verified identical to the combined run) — so editing copper
    /// settings never re-runs the cutout.
    static func outlineArgs(_ p: ParameterSnapshot, outline: URL, outputDir: URL) -> [String] {
        var a: [String] = [
            "--metric",
            "--metricoutput",
            "--path-finding-limit", "0",
            "--zsafe", "\(p.zSafe(.cut))mm",
            "--zchange", "\(p.zChange(.cut))mm",
            "--mirror-axis", "\(p.mirrorAxis)mm",
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
            "--outline-output", outputURL(for: .outline, in: outputDir).path
        ]
        a += commonMillingArgs(p, .cut)
        if p.mirrorYAxis { a.append("--mirror-yaxis=1") }   // needs its value; zeroing: see normalizeOrigins()
        return a
    }

    static func drillArgs(_ p: ParameterSnapshot, drill: URL, output: URL, millOutput: URL) -> [String] {
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
            "--zsafe", "\(p.zSafe(.drill))mm",
            "--zchange", "\(p.zChange(.drill))mm",
            "--mirror-axis", "\(p.mirrorAxis)mm",
            "--spinup-time", spinupPlaceholder
        ]
        if !p.drillBits.isEmpty {
            a += ["--drills-available", p.drillBits.joined(separator: ",")]
        }
        if p.drillMillLarge {
            // Holes from this size up are milled as helices with the hole-
            // milling end mill. pcb2gcode reads the milling feeds, speed and
            // pass depth from the --cut-* options (which it insists on even
            // without --outline); this invocation has no outline, so they
            // carry the hole mill's own values.
            a += [
                "--min-milldrill-hole-diameter", "\(p.drillMillFrom)mm",
                "--milldrill-diameter", "\(p.holeMillDiameter)mm",
                "--zmilldrill", "\(p.holeMillDepth)mm",
                "--milldrill-output", millOutput.path,
                "--cutter-diameter", "\(p.holeMillDiameter)mm",
                "--zcut", "\(p.holeMillDepth)mm",
                "--cut-feed", "\(p.holeMillFeed)mm/minute",
                "--cut-vertfeed", "\(p.holeMillVertFeed)mm/minute",
                "--cut-speed", p.holeMillSpeed,
                "--cut-infeed", "\(p.holeMillInfeed)mm"
            ]
        }
        if p.mirrorYAxis { a.append("--mirror-yaxis=1") }   // needs its value; zeroing: see normalizeOrigins()
        return a
    }

    /// Options every milling invocation shares: feed direction and spin-up.
    private static func commonMillingArgs(_ p: ParameterSnapshot, _ group: ParametersStore.MotionGroup) -> [String] {
        var a = ["--spinup-time", spinupPlaceholder]
        let direction = p.millDirection(group)
        if direction == "climb" || direction == "conventional" {
            // pcb2gcode refuses a fixed direction while its 2-opt path
            // shortening may reverse paths.
            a += ["--mill-feed-direction", direction, "--tsp-2opt=0"]
        }
        return a
    }

    /// --mill-infeed only when it really splits the cut into several passes.
    private static func infeedArgs(depthPerPass: String, depth: String) -> [String] {
        guard let step = Double(depthPerPass), step > 0,
              let total = Double(depth), step < abs(total) else { return [] }
        return ["--mill-infeed", "\(depthPerPass)mm"]
    }

    /// pcb2gcode's spin-up time is per invocation (isolation and outline
    /// share one), so it only marks where the dwells go; setDwells() writes
    /// each program's own value there.
    private static let spinupPlaceholder = "1s"

    /// pcb2gcode reads hole sizes from the file itself, so with a hole
    /// tolerance it gets a copy whose tool table is enlarged by it. The copy
    /// lives at a path named after the source contents and the tolerance:
    /// the same input always maps to the same path, so job caching holds.
    static func allowedDrillInput(_ drill: URL, _ p: ParameterSnapshot) -> URL {
        guard let allowance = Double(p.drillHoleAllowance), abs(allowance) > 1e-9,
              let data = FileManager.default.contents(atPath: drill.path),
              var image = try? ExcellonFile.read(drill) else { return drill }
        for (tool, size) in image.tools where size >= 0.01 {
            image.tools[tool] = max(0.01, size + allowance)
        }
        let digest = SHA256.hash(data: data + Data(p.drillHoleAllowance.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let dir = PreviewPaths.root.appendingPathComponent("drill-tolerance/\(digest)", isDirectory: true)
        let copy = dir.appendingPathComponent(drill.lastPathComponent)
        if !FileManager.default.fileExists(atPath: copy.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard (try? ExcellonFile.write(image).write(to: copy, atomically: true, encoding: .utf8)) != nil else { return drill }
        }
        return copy
    }

    static func drillOutputURL(for drill: URL, index: Int, outputDir: URL) -> URL {
        let stem = drill.deletingPathExtension().lastPathComponent
        return outputURL(for: .drill(index: index, name: stem), in: outputDir)
    }

    static func millDrillOutputURL(for drill: URL, index: Int, outputDir: URL) -> URL {
        let stem = drill.deletingPathExtension().lastPathComponent
        return outputURL(for: .millDrill(index: index, name: stem), in: outputDir)
    }

    /// Solder-mask etch: the mask Gerbers describe the OPENINGS (pads/vias to
    /// stay exposed). With --invert-gerbers, isolation milling clears the
    /// inside of each opening — engraving the cured mask off the pads.
    static func maskArgs(_ p: ParameterSnapshot, files: DetectedFiles, outputDir: URL) -> [String] {
        var a: [String] = ["--metric", "--metricoutput"]

        if let topMask = files.topMask {
            a += ["--front", topMask.path,
                  "--front-output", outputURL(for: .maskTop, in: outputDir).path]
        }
        if let bottomMask = files.bottomMask {
            a += ["--back", bottomMask.path,
                  "--back-output", outputURL(for: .maskBottom, in: outputDir).path]
        }

        a += [
            "--invert-gerbers",
            "--path-finding-limit", "0",   // never drag the tool through cured mask between openings
            "--mill-diameters", "\(p.maskTool)mm",
            "--milling-overlap", "\(p.maskOverlap)%",
            // Clearing is bounded by each opening's own geometry, but pcb2gcode's
            // generation time explodes with this width — keep it just above half
            // the widest opening (user-tunable), never a blanket large value.
            "--isolation-width", "\(p.maskClearWidth)mm",
            "--zwork", "\(p.maskDepth)mm",
            "--mill-feed", "\(p.maskFeed)mm/minute",
            "--mill-vertfeed", "\(p.maskVertFeed)mm/minute",
            "--mill-speed", p.maskSpeed,
            "--zsafe", "\(p.zSafe(.mask))mm",
            "--zchange", "\(p.zChange(.mask))mm",
            "--mirror-axis", "\(p.mirrorAxis)mm"
        ]
        a += commonMillingArgs(p, .mask)

        if p.mirrorYAxis { a.append("--mirror-yaxis=1") }   // needs its value; zeroing: see normalizeOrigins()
        return a
    }

    /// Silkscreen legend engraving: the silk Gerbers describe the printed
    /// legend itself. With --invert-gerbers the tool clears the INSIDE of each
    /// shape, so the strokes are engraved rather than outlined — the same trick
    /// the mask etch uses, at a much shallower depth.
    static func silkArgs(_ p: ParameterSnapshot, files: DetectedFiles, outputDir: URL) -> [String] {
        var a: [String] = ["--metric", "--metricoutput"]

        if let topSilk = files.topSilk {
            a += ["--front", topSilk.path,
                  "--front-output", outputURL(for: .silkTop, in: outputDir).path]
        }
        if let bottomSilk = files.bottomSilk {
            a += ["--back", bottomSilk.path,
                  "--back-output", outputURL(for: .silkBottom, in: outputDir).path]
        }

        a += [
            "--invert-gerbers",
            "--path-finding-limit", "0",   // never drag the tool between glyphs
            "--mill-diameters", "\(p.silkTool)mm",
            "--milling-overlap", "\(p.silkOverlap)%",
            // Legend strokes are thin, so this stays small — generation time
            // climbs steeply with it, exactly as for the mask.
            "--isolation-width", "\(p.silkClearWidth)mm",
            "--zwork", "\(p.silkDepth)mm",
            "--mill-feed", "\(p.silkFeed)mm/minute",
            "--mill-vertfeed", "\(p.silkVertFeed)mm/minute",
            "--mill-speed", p.silkSpeed,
            "--zsafe", "\(p.zSafe(.silk))mm",
            "--zchange", "\(p.zChange(.silk))mm",
            "--mirror-axis", "\(p.mirrorAxis)mm"
        ]
        a += commonMillingArgs(p, .silk)

        if p.mirrorYAxis { a.append("--mirror-yaxis=1") }   // needs its value; zeroing: see normalizeOrigins()
        return a
    }

    /// The isolation command line, for the "Copy Command" button.
    static func previewCommand(pcb2gcode: URL?, params p: ParameterSnapshot, files: DetectedFiles, outputDir: URL) -> String {
        guard let pcb2gcode else { return "pcb2gcode not found" }
        let args = isolationArgs(p, files: files, outputDir: outputDir)
        return ([pcb2gcode.path] + args).map(ProcessRunner.shellQuote).joined(separator: " ")
    }

    // MARK: - Batch execution

    /// Progress of a batch: every unit of work reports when it starts and
    /// when it finishes. Jobs run in parallel, so several can be in flight.
    enum StepEvent: Sendable {
        case started(id: Int, label: String)
        case finished(id: Int)
    }
    typealias StepReporter = @Sendable (_ event: StepEvent, _ total: Int) -> Void

    /// One program's worth of pcb2gcode: a single invocation and the files
    /// it produces. Jobs are independent, so they run in parallel and each is
    /// cached on its own — editing one layer's settings only re-runs the jobs
    /// whose command line (or input file) actually changed.
    struct Job: Sendable {
        struct Product: Sendable {
            let layer: LayerKind
            let url: URL
            let tool: String?
        }
        let label: String
        let args: [String]
        let products: [Product]
        /// Drill programs: the file to check against the bits on hand.
        var bitCheck: URL?
    }

    /// Replaces the value following `flag` (used to send a by-product to scratch).
    private static func replacing(_ flag: String, with value: String, in args: [String]) -> [String] {
        var args = args
        if let i = args.firstIndex(of: flag), i + 1 < args.count { args[i + 1] = value }
        return args
    }

    static func jobs(_ p: ParameterSnapshot, files: DetectedFiles, outputDir: URL) -> [Job] {
        var jobs: [Job] = []
        func product(_ layer: LayerKind, _ tool: String?) -> Job.Product {
            Job.Product(layer: layer, url: outputURL(for: layer, in: outputDir), tool: tool)
        }

        // Copper: one job per side. The outline goes along as INPUT — with an
        // outline present pcb2gcode clips the isolation to the board, and the
        // output must match what one combined run produced — but its program
        // is discarded (relative path: lands in the job's scratch folder).
        for (slot, layer) in [(LayerSlot.front, LayerKind.front), (.back, .back)] {
            guard let file = files[slot] else { continue }
            var only = DetectedFiles()
            only[slot] = file
            only.outline = files.outline
            let args = replacing("--outline-output", with: "unused-outline.ngc",
                                 in: isolationArgs(p, files: only, outputDir: outputDir))
            jobs.append(Job(label: layer.displayName, args: args, products: [product(layer, p.millDiameter)]))
        }
        if let outline = files.outline {
            jobs.append(Job(label: "Board outline", args: outlineArgs(p, outline: outline, outputDir: outputDir),
                            products: [product(.outline, p.cutterDiameter)]))
        }

        for (index, drill) in files.drills.enumerated() {
            let stem = drill.deletingPathExtension().lastPathComponent
            let out = drillOutputURL(for: drill, index: index, outputDir: outputDir)
            let milled = millDrillOutputURL(for: drill, index: index, outputDir: outputDir)
            var products = [Job.Product(layer: .drill(index: index, name: stem), url: out, tool: nil)]
            if p.drillMillLarge {
                products.append(Job.Product(layer: .millDrill(index: index, name: stem), url: milled, tool: p.holeMillDiameter))
            }
            jobs.append(Job(label: "Drilling — \(stem)",
                            args: drillArgs(p, drill: allowedDrillInput(drill, p), output: out, millOutput: milled),
                            products: products,
                            bitCheck: p.drillBits.isEmpty ? nil : out))
        }

        // Mask and legend keep top and bottom in ONE run each: pcb2gcode
        // rasterises all layers of a run on a shared grid, and splitting the
        // sides moved some legend points by ~0.005 mm. (Copper can split
        // because the outline, passed to every copper run, sets the grid.)
        if p.maskMode == "gcode", files.topMask != nil || files.bottomMask != nil {
            var products: [Job.Product] = []
            if files.topMask != nil { products.append(product(.maskTop, p.maskTool)) }
            if files.bottomMask != nil { products.append(product(.maskBottom, p.maskTool)) }
            jobs.append(Job(label: "Solder-mask etch", args: maskArgs(p, files: files, outputDir: outputDir),
                            products: products))
        }
        if p.silkMode == "gcode", files.topSilk != nil || files.bottomSilk != nil {
            var products: [Job.Product] = []
            if files.topSilk != nil { products.append(product(.silkTop, p.silkTool)) }
            if files.bottomSilk != nil { products.append(product(.silkBottom, p.silkTool)) }
            jobs.append(Job(label: "Silkscreen engraving", args: silkArgs(p, files: files, outputDir: outputDir),
                            products: products))
        }
        return jobs
    }

    /// How many progress steps `runBatch` reports with these inputs.
    static func stepCount(_ p: ParameterSnapshot, files: DetectedFiles, pcb2gcode: URL?) -> Int {
        var steps = usesNativeEngine(p, pcb2gcode: pcb2gcode) ? 1 : jobs(p, files: files, outputDir: URL(fileURLWithPath: "/")).count
        if let clearance = Double(p.plungeClearance), clearance > 0 { steps += 1 }
        if p.zeroStart { steps += 1 }
        return steps
    }

    /// Where the preview keeps pcb2gcode results between runs.
    static var previewCache: URL { PreviewPaths.root.appendingPathComponent("cache", isDirectory: true) }

    /// Identity of a job's result: its command line with the run folder
    /// masked out, plus the contents of every input file it names. Same key,
    /// same pcb2gcode output.
    private static func cacheKey(_ job: Job, outputDir: URL, pcb2gcode: URL) -> String {
        var hasher = SHA256()
        let prefix = outputDir.path
        hasher.update(data: Data(pcb2gcode.path.utf8))
        for arg in job.args {
            hasher.update(data: Data((arg.hasPrefix(prefix) ? "<OUT>" + arg.dropFirst(prefix.count) : arg).utf8))
            hasher.update(data: Data([0]))
            if arg.hasPrefix("/"), !arg.hasPrefix(prefix), let data = FileManager.default.contents(atPath: arg) {
                hasher.update(data: SHA256.hash(data: data).withUnsafeBytes { Data($0) })
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs (or, from the cache, re-uses) one job. Returns its log text and
    /// whether it succeeded.
    private static func runJob(_ job: Job, pcb2gcode: URL, outputDir: URL, scratchRoot: URL,
                               cache: URL?) async -> (log: String, succeeded: Bool) {
        let fm = FileManager.default
        let key = cache.map { _ in cacheKey(job, outputDir: outputDir, pcb2gcode: pcb2gcode) }
        if let cache, let key {
            let entry = cache.appendingPathComponent(key, isDirectory: true)
            if fm.fileExists(atPath: entry.path) {
                for product in job.products {
                    let cached = entry.appendingPathComponent(product.url.lastPathComponent)
                    try? fm.removeItem(at: product.url)
                    if fm.fileExists(atPath: cached.path) { try? fm.copyItem(at: cached, to: product.url) }
                }
                // Touch it so pruning keeps recently used results.
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: entry.path)
                return ("\(job.label): unchanged — reused the previous result\n", true)
            }
        }

        // pcb2gcode dumps debug renders into its working directory; each job
        // gets its own, so parallel runs never write over each other.
        let scratch = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        var log = ""
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let r = try await ProcessRunner.run(executable: pcb2gcode, arguments: job.args, currentDirectory: scratch)
            log += "$ \(r.commandLine)\n\(r.output)\n"
            log += String(format: "%@ finished in %.1fs\n", job.label, start.duration(to: clock.now).seconds)
            guard r.exitCode == 0 else {
                log += "\(job.label) failed with exit code \(r.exitCode)\n"
                return (log, false)
            }
        } catch {
            return (log + "ERROR launching pcb2gcode: \(error.localizedDescription)\n", false)
        }

        // Store the raw result (before any post-processing). Written under a
        // temporary name and renamed, so a half-written entry is never a hit.
        if let cache, let key, !Task.isCancelled {
            let staging = cache.appendingPathComponent(".\(key)-\(UUID().uuidString)", isDirectory: true)
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                for product in job.products where fm.fileExists(atPath: product.url.path) {
                    try fm.copyItem(at: product.url, to: staging.appendingPathComponent(product.url.lastPathComponent))
                }
                try fm.moveItem(at: staging, to: cache.appendingPathComponent(key, isDirectory: true))
            } catch {
                try? fm.removeItem(at: staging)
            }
        }
        return (log, true)
    }

    /// Keeps the most recently used cache entries only.
    private static func pruneCache(_ cache: URL, keep: Int = 80) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles]),
              entries.count > keep else { return }
        let sorted = entries.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for entry in sorted.dropFirst(keep) { try? fm.removeItem(at: entry) }
    }

    /// Runs every job — in parallel, re-using cached results when `cache` is
    /// given (the live preview; Generate always runs fresh) — then the local
    /// post-processing passes over all programs together.
    static func runBatch(pcb2gcode: URL?, params p: ParameterSnapshot, files: DetectedFiles, outputDir: URL,
                         cache: URL? = nil, onStep: StepReporter? = nil) async -> BatchResult {
        var result = BatchResult()
        let fm = FileManager.default
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let total = stepCount(p, files: files, pcb2gcode: pcb2gcode)
        var step = 0

        if let pcb2gcode, !usesNativeEngine(p, pcb2gcode: pcb2gcode) {
            // pcb2gcode inherits only the app's static sandbox: it reads copies.
            step = await runJobs(pcb2gcode: pcb2gcode, params: p, files: FileAccess.helperReadable(files), outputDir: outputDir,
                                 cache: cache, total: total, onStep: onStep, result: &result)
        } else {
            // The native engine: in-process, no pcb2gcode.
            onStep?(.started(id: 0, label: "Native toolpaths"), total)
            let native = await Task.detached(priority: .userInitiated) {
                NativeToolpathEngine.run(p, files: files, outputDir: outputDir)
            }.value
            result.outputs = native.outputs
            result.log += native.log
            if !native.succeeded { result.succeeded = false }
            for output in native.outputs where output.layer.isDrill {
                warnAboutMissingBits(in: output.url, bits: p.drillBits, log: &result.log)
            }
            onStep?(.finished(id: 0), total)
            step = 1
            if Task.isCancelled { result.succeeded = false }
        }

        func post(_ label: String, _ work: () -> Void) {
            let id = step
            step += 1
            onStep?(.started(id: id, label: label), total)
            work()
            onStep?(.finished(id: id), total)
        }

        // Local rewrites, before the plunge pass (pecks produce plunges it splits).
        setDwells(p, outputs: result.outputs, log: &result.log)
        setSpindleDirections(p, outputs: result.outputs, log: &result.log)
        addExtraCuts(p, outputs: result.outputs, log: &result.log)
        if let peck = Double(p.drillPeck), peck > 0 {
            peckDrill(peck: peck, clearance: Double(p.plungeClearance) ?? 0,
                      outputs: result.outputs.filter { $0.layer.isDrill }, log: &result.log)
        }

        if let clearance = Double(p.plungeClearance), clearance > 0,
           result.succeeded, !result.outputs.isEmpty {
            post("Optimizing plunges") {
                optimizePlunges(clearance: clearance, outputs: result.outputs, log: &result.log)
            }
        }

        if p.zeroStart, result.succeeded, !result.outputs.isEmpty {
            post("Normalizing origins") {
                result.frame = normalizeOrigins(p, outputs: result.outputs, log: &result.log)
            }
        }

        return result
    }

    /// Native when chosen, or when there is no pcb2gcode to run.
    static func usesNativeEngine(_ p: ParameterSnapshot, pcb2gcode: URL?) -> Bool {
        p.engine == "native" || pcb2gcode == nil
    }

    /// pcb2gcode's part of a batch: every job in parallel, cached results
    /// re-used. Returns how many progress steps it reported.
    private static func runJobs(pcb2gcode: URL, params p: ParameterSnapshot, files: DetectedFiles, outputDir: URL,
                                cache: URL?, total: Int, onStep: StepReporter?,
                                result: inout BatchResult) async -> Int {
        let fm = FileManager.default
        if let cache { try? fm.createDirectory(at: cache, withIntermediateDirectories: true) }
        let scratchRoot = outputDir.appendingPathComponent(".pcb2gcode-scratch-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratchRoot) }

        let jobs = jobs(p, files: files, outputDir: outputDir)
        // pcb2gcode is partly multi-threaded itself; half the cores each is plenty.
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

        var logs = [String](repeating: "", count: jobs.count)
        var succeeded = true
        await withTaskGroup(of: (Int, String, Bool).self) { group in
            var next = 0
            func launch() {
                guard next < jobs.count else { return }
                let index = next
                next += 1
                let job = jobs[index]
                onStep?(.started(id: index, label: job.label), total)
                group.addTask {
                    let r = await runJob(job, pcb2gcode: pcb2gcode, outputDir: outputDir,
                                         scratchRoot: scratchRoot, cache: cache)
                    return (index, r.log, r.succeeded)
                }
            }
            for _ in 0..<min(width, jobs.count) { launch() }
            for await (index, log, ok) in group {
                logs[index] = log
                if !ok { succeeded = false }
                onStep?(.finished(id: index), total)
                if !Task.isCancelled { launch() }
            }
        }
        result.log += logs.joined()
        if !succeeded || Task.isCancelled { result.succeeded = false }
        if let cache { pruneCache(cache) }

        for job in jobs {
            if let check = job.bitCheck { warnAboutMissingBits(in: check, bits: p.drillBits, log: &result.log) }
            for product in job.products where fm.fileExists(atPath: product.url.path) {
                result.outputs.append(GeneratedOutput(layer: product.layer, url: product.url,
                                                      toolDiameter: product.tool.flatMap(Double.init)))
            }
        }
        return jobs.count
    }

    // MARK: - Drill bit check

    /// pcb2gcode lists the bits a drill program needs in a header comment
    /// ("( Bit sizes: [1mm] [3.032mm] )"). Holes no bit on hand covers keep
    /// their designed size, so flag every listed size that is not on hand.
    private static func warnAboutMissingBits(in file: URL, bits: [String], log: inout String) {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let header = text.split(separator: "\n").first(where: { $0.contains("Bit sizes:") }) else { return }
        let onHand = bits.compactMap { Double($0.prefix { $0 != "m" }) }
        let needed = header.split(separator: "[").dropFirst().compactMap { Double($0.prefix { $0 != "m" }) }
        let missing = needed.filter { size in !onHand.contains { abs($0 - size) < 1e-6 } }
        guard !missing.isEmpty else { return }
        let list = missing.map { ParametersStore.format($0) + " mm" }.joined(separator: ", ")
        log += "WARNING: \(file.lastPathComponent) needs bit\(missing.count == 1 ? "" : "s") not on hand: \(list). "
            + "No bit's range covers these holes — add a bit, widen a range, or mill large holes.\n"
    }

    // MARK: - Dwells

    /// Seconds a program waits after starting (and stopping) the spindle.
    static func dwellSeconds(for kind: LayerKind, _ p: ParameterSnapshot) -> Double? {
        let value: String? = switch kind {
        case .front, .back: p.millDwell
        case .outline: p.cutDwell
        case .drill: p.drillDwell
        case .millDrill: p.holeMillDwell
        case .maskTop, .maskBottom: p.maskDwell
        case .silkTop, .silkBottom: p.silkDwell
        case .custom, .test: nil   // drawn layers carry their own dwell
        }
        return value.flatMap(Double.init)
    }

    /// pcb2gcode writes one spindle dwell per invocation, and in
    /// MILLISECONDS ("G04 P2000") whatever --software says — GRBL and LinuxCNC
    /// read G4 P as SECONDS, so that would pause for 33 minutes. Each program
    /// gets its own layer's dwell instead: the G4 right after every M3
    /// (spin-up) and M5 (spin-down) is rewritten in seconds, or dropped for 0.
    /// Any other non-zero dwell is converted from milliseconds.
    private static func setDwells(_ p: ParameterSnapshot, outputs: [GeneratedOutput], log: inout String) {
        var summary: [String] = []
        for output in outputs {
            guard let text = try? String(contentsOf: output.url, encoding: .utf8) else { continue }
            let seconds = dwellSeconds(for: output.layer, p)
            var out: [String] = []
            // Code lines since the last M3/M5: pcb2gcode's drill programs put a
            // move between M3 and its dwell, so "right after" allows a little gap.
            var sinceSpindle = Int.max
            var changed = false
            for lineSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(lineSub)
                let code = strippedOfComments(line).uppercased().trimmingCharacters(in: .whitespaces)
                if ["M3", "M03", "M5", "M05"].contains(where: { code.hasPrefix($0) }) {
                    sinceSpindle = 0
                    out.append(line)
                    continue
                }
                if !code.isEmpty, sinceSpindle < Int.max { sinceSpindle += 1 }
                guard code.hasPrefix("G04") || code.hasPrefix("G4 ") || code.hasPrefix("G4P"),
                      let pRange = line.range(of: "P", options: .caseInsensitive) else {
                    out.append(line)
                    continue
                }
                let digits = line[pRange.upperBound...].prefix { $0.isNumber || $0 == "." }
                guard let ms = Double(digits), ms > 0 else {
                    out.append(line)   // "G04 P0" path markers stay as they are
                    continue
                }
                changed = true
                let spindle = sinceSpindle <= 2
                if spindle, let seconds {
                    if seconds > 0 {
                        out.append(line.replacingCharacters(in: pRange.upperBound..<digits.endIndex,
                                                            with: String(format: "%.3f", seconds)))
                    }
                } else {
                    out.append(line.replacingCharacters(in: pRange.upperBound..<digits.endIndex,
                                                        with: String(format: "%.3f", ms / 1000)))
                }
            }
            if changed {
                try? out.joined(separator: "\n").write(to: output.url, atomically: true, encoding: .utf8)
            }
            if let seconds { summary.append("\(output.layer.displayName) \(ParametersStore.format(seconds)) s") }
        }
        if !summary.isEmpty {
            log += "Spindle dwell (G4 P, seconds): " + summary.joined(separator: ", ") + ".\n"
        }
    }

    // MARK: - Spindle direction

    /// pcb2gcode always starts the spindle clockwise (M3). Groups set to
    /// counter-clockwise get M4 instead.
    private static func setSpindleDirections(_ p: ParameterSnapshot, outputs: [GeneratedOutput], log: inout String) {
        var reversed: [String] = []
        for output in outputs {
            guard let group = ParametersStore.MotionGroup(output.layer), p.spindleCCW(group),
                  let text = try? String(contentsOf: output.url, encoding: .utf8) else { continue }
            var changed = false
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                let code = strippedOfComments(String(line)).uppercased().trimmingCharacters(in: .whitespaces)
                guard code == "M3" || code == "M03" else { return String(line) }
                changed = true
                return "M4 ( Spindle on counter-clockwise. )"
            }
            if changed {
                try? lines.joined(separator: "\n").write(to: output.url, atomically: true, encoding: .utf8)
                reversed.append(output.layer.displayName)
            }
        }
        if !reversed.isEmpty {
            log += "Spindle counter-clockwise (M4): " + reversed.joined(separator: ", ") + ".\n"
        }
    }

    // MARK: - Extra cut

    /// FlatCAM's "extra cut": every closed contour runs on past its start
    /// along its own first segments for the group's extra-cut length, so the
    /// spot where the loop closes — where a sliver of copper tends to stay
    /// — is cut twice.
    private static func addExtraCuts(_ p: ParameterSnapshot, outputs: [GeneratedOutput], log: inout String) {
        var loops = 0
        var names: [String] = []
        for output in outputs {
            guard let group = ParametersStore.MotionGroup(output.layer), group.hasExtraCut else { continue }
            let length = p.extraCutLength(group)
            guard length > 0, let text = try? String(contentsOf: output.url, encoding: .utf8) else { continue }
            let (rewritten, count) = extendClosedLoops(text, length: length)
            if count > 0 {
                try? rewritten.write(to: output.url, atomically: true, encoding: .utf8)
                loops += count
                names.append(output.layer.displayName)
            }
        }
        if loops > 0 {
            log += "Extra cut: \(loops) closed contour\(loops == 1 ? "" : "s") overrun past their start (\(names.joined(separator: ", "))).\n"
        }
    }

    /// Finds runs of G1 XY moves below the surface and every point where
    /// such a run closes a loop (comes back to where the loop began), and
    /// continues along the loop's first segments for `length` mm there.
    /// pcb2gcode chains the passes around a trace into one run, so a loop
    /// can close mid-run: the tool then retraces the extra cut back to the
    /// closing point, and the move on to the next pass is left as planned —
    /// only groove that is already cut is cut again.
    static func extendClosedLoops(_ text: String, length: Double) -> (String, Int) {
        var out: [String] = []
        var modalG: Int?
        var x: Double?, y: Double?, z: Double?
        var run: [CGPoint] = []
        var runLines: [Int] = []   // index in `out` of the move ending at run[k]; -1 for the start
        var count = 0

        func line(_ p: CGPoint) -> String { String(format: "G01 X%.5f Y%.5f ( extra cut )", p.x, p.y) }

        func finishRun() {
            defer { run = []; runLines = [] }
            func key(_ p: CGPoint) -> String { String(format: "%.3f,%.3f", p.x, p.y) }
            var seen: [String: Int] = [:]
            var closures: [(start: Int, end: Int)] = []
            for (k, p) in run.enumerated() {
                if let i = seen[key(p)], k - i >= 3 {
                    closures.append((i, k))
                    seen = [key(p): k]
                } else if seen[key(p)] == nil {
                    seen[key(p)] = k
                }
            }
            // Back to front, so earlier insertion points stay valid.
            for (i, k) in closures.reversed() {
                var remaining = length
                var extra: [CGPoint] = []
                var cursor = run[i]
                for next in run[(i + 1)...k] {
                    let d = hypot(next.x - cursor.x, next.y - cursor.y)
                    guard d > 1e-9 else { continue }
                    if d >= remaining {
                        let t = remaining / d
                        extra.append(CGPoint(x: cursor.x + (next.x - cursor.x) * t, y: cursor.y + (next.y - cursor.y) * t))
                        remaining = 0
                        break
                    }
                    extra.append(next)
                    remaining -= d
                    cursor = next
                }
                guard !extra.isEmpty else { continue }
                var moves = extra
                if k < run.count - 1 {
                    moves += extra.dropLast().reversed()   // back along the same groove
                    moves.append(run[k])
                }
                out.insert(contentsOf: moves.map(line), at: runLines[k] + 1)
                count += 1
            }
        }

        for lineSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSub)
            let code = strippedOfComments(line).uppercased()
            let words = motionWords(code)
            if let g = words.g { modalG = g }
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            // Blank lines, comments and feed-only words neither extend nor end a run.
            let neutral = trimmed.isEmpty || (!words.hasAny && words.g.map { $0 == 1 } != false
                                               && trimmed.allSatisfy { "GF0123456789. ".contains($0) })
            let isCutXY = (words.g ?? modalG) == 1 && words.hasXY && words.z == nil && (z ?? 0) < 0
            let nx = xyValue(code, "X") ?? x, ny = xyValue(code, "Y") ?? y
            if isCutXY, let nx, let ny {
                if run.isEmpty, let x, let y {
                    run.append(CGPoint(x: x, y: y))
                    runLines.append(-1)
                }
                out.append(line)
                run.append(CGPoint(x: nx, y: ny))
                runLines.append(out.count - 1)
            } else if neutral {
                out.append(line)
            } else {
                if !run.isEmpty { finishRun() }
                out.append(line)
            }
            x = nx; y = ny
            if let wz = words.z { z = wz }
        }
        if !run.isEmpty { finishRun() }
        return (out.joined(separator: "\n"), count)
    }

    private static func xyValue(_ code: String, _ axis: Character) -> Double? {
        guard let i = code.firstIndex(of: axis) else { return nil }
        let number = code[code.index(after: i)...].prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        return Double(number)
    }

    // MARK: - Peck drilling

    /// pcb2gcode drills each hole in one stroke (G1 down, G1 up). Split every
    /// stroke that enters the board into pecks of `peck` depth: after each
    /// peck the bit rapids up out of the hole to clear chips, rapids back to
    /// just above the previous bottom, and feeds on. The final stroke and the
    /// retract are pcb2gcode's own.
    private static func peckDrill(peck: Double, clearance: Double, outputs: [GeneratedOutput], log: inout String) {
        let retract = max(clearance, 0.2)
        let reentry = 0.1   // stop this far above the previous bottom before feeding again
        var holes = 0
        for output in outputs {
            guard let text = try? String(contentsOf: output.url, encoding: .utf8) else { continue }
            var out: [String] = []
            var modalG: Int?
            var currentZ: Double?
            var changed = false
            for lineSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(lineSub)
                let words = motionWords(strippedOfComments(line))
                if let g = words.g { modalG = g }
                let g = words.g ?? modalG
                if g == 1, let z = words.z, !words.hasXY, let startZ = currentZ,
                   startZ >= 0, z < -peck - 1e-6 {
                    var depth = -peck
                    var previous = 0.0
                    while depth > z + 1e-6 {
                        if previous < 0 {
                            out.append(String(format: "G00 Z%.5f ( back into the hole )", previous + reentry))
                        }
                        out.append(String(format: "G01 Z%.5f ( peck )", depth))
                        out.append(String(format: "G00 Z%.5f ( clear chips )", retract))
                        previous = depth
                        depth -= peck
                    }
                    out.append(String(format: "G00 Z%.5f ( back into the hole )", previous + reentry))
                    out.append(words.g == nil ? "G01 " + line : line)
                    holes += 1
                    changed = true
                    currentZ = z
                    continue
                }
                if let z = words.z { currentZ = z }
                out.append(line)
            }
            if changed {
                try? out.joined(separator: "\n").write(to: output.url, atomically: true, encoding: .utf8)
            }
        }
        if holes > 0 {
            log += String(format: "Peck drilling: %d holes drilled in %.2f mm pecks.\n", holes, peck)
        }
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
    /// "Un-mirror Back Side" uses to overlay them).
    private static func isBackSide(_ kind: LayerKind) -> Bool { kind.isBackSide }

    /// X0/Y0 for each side, from the lower-left corner of the project as the
    /// machine sees that side. Corners and centre are the same corner on both
    /// sides — the one you touch off at after flipping; a custom point is the
    /// same physical spot on the board, e.g. a registration hole.
    static func origins(_ p: ParameterSnapshot, rect: CGRect) -> (front: CGPoint, back: CGPoint) {
        let w = rect.width, h = rect.height
        let corner: CGPoint
        switch p.originMode {
        case "custom":
            let x = (Double(p.originX) ?? 0) - rect.minX
            let y = (Double(p.originY) ?? 0) - rect.minY
            let front = CGPoint(x: x, y: y)
            return (front, p.mirrorYAxis ? CGPoint(x: x, y: h - y) : CGPoint(x: w - x, y: y))
        case "bottomRight": corner = CGPoint(x: w, y: 0)
        case "topLeft": corner = CGPoint(x: 0, y: h)
        case "topRight": corner = CGPoint(x: w, y: h)
        case "center": corner = CGPoint(x: w / 2, y: h / 2)
        default: corner = .zero
        }
        return (corner, corner)
    }

    private static func normalizeOrigins(_ p: ParameterSnapshot, outputs: [GeneratedOutput], log: inout String) -> ProjectFrame? {
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

        let origin = origins(p, rect: union)
        // The back programs' lower-left corner, in their mirrored frame.
        let backMin = p.mirrorYAxis
            ? CGPoint(x: union.minX, y: 2 * axis - union.maxY)
            : CGPoint(x: 2 * axis - union.maxX, y: union.minY)
        let frontShift: (dx: Double, dy: Double) = (-(union.minX + origin.front.x), -(union.minY + origin.front.y))
        let backShift: (dx: Double, dy: Double) = (-(backMin.x + origin.back.x), -(backMin.y + origin.back.y))

        for (index, output) in outputs.enumerated() where measured.contains(index) {
            let shift = isBackSide(output.layer) ? backShift : frontShift
            do {
                try shiftFile(output.url, dx: shift.dx, dy: shift.dy)
            } catch {
                log += "WARNING: could not normalize \(output.url.lastPathComponent): \(error.localizedDescription)\n"
            }
        }

        log += String(format: "Origins normalized: project %.2f × %.2f mm, X0 Y0 at %@ — all programs share one origin per side (zero the machine once per side).\n",
                      union.width, union.height, originDescription(p, front: origin.front))
        return ProjectFrame(rect: union, frontOrigin: origin.front, backOrigin: origin.back,
                            mirrorYAxis: p.mirrorYAxis)
    }

    private static func originDescription(_ p: ParameterSnapshot, front: CGPoint) -> String {
        switch p.originMode {
        case "custom": String(format: "design point X%@ Y%@ (%.2f, %.2f mm from the project's lower-left corner)",
                              p.originX, p.originY, front.x, front.y)
        case "bottomRight": "the lower-right corner"
        case "topLeft": "the upper-left corner"
        case "topRight": "the upper-right corner"
        case "center": "the centre"
        default: "the lower-left corner"
        }
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

    /// Exports solder-mask openings (and the board outline for reference) as
    /// 1:1 SVGs into <outputDir>/Laser_SolderMask, drawn from the Gerbers by
    /// the app itself (GerberSVG). Final Generate only.
    static func exportMaskSVGs(files: DetectedFiles, outputDir: URL) -> BatchResult {
        var result = BatchResult()
        let laserDir = outputDir.appendingPathComponent("Laser_SolderMask", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: laserDir, withIntermediateDirectories: true)
        } catch {
            result.log += "ERROR creating Laser_SolderMask folder: \(error.localizedDescription)\n"
            result.succeeded = false
            return result
        }

        func export(_ input: URL, to name: String, label: String) {
            let out = laserDir.appendingPathComponent(name)
            do {
                try GerberSVG.write(GerberFile.read(input)).write(to: out, atomically: true, encoding: .utf8)
                result.log += "\(label) → \(out.lastPathComponent)\n"
            } catch {
                result.log += "ERROR: \(label) SVG export failed: \(error.localizedDescription)\n"
                result.succeeded = false
            }
        }

        if let topMask = files.topMask {
            export(topMask, to: "soldermask_top_openings.svg", label: "Top solder-mask")
        }
        if let bottomMask = files.bottomMask {
            export(bottomMask, to: "soldermask_bottom_openings.svg", label: "Bottom solder-mask")
        }
        // Reference geometry only; never laser/cut the outline SVG.
        if let outline = files.outline {
            export(outline, to: "REFERENCE_board_outline.svg", label: "Board outline reference")
        }

        result.log += "Solder-mask laser SVGs written to: \(laserDir.path)\n"
        return result
    }
}
