import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Per-layer artwork export for laser engravers.
///
/// This exports the TOOLPATH — the same geometry the preview canvas draws for
/// the selected layer: every cutting move, swept at the cutter diameter, which
/// is exactly the copper the mill would clear. It is not the source Gerber:
/// isolation paths, bridges and the pcb2gcode-computed offsets are what the
/// laser has to reproduce, so they are what gets exported.
///
/// Everything is rendered from the parsed .ngc in millimetres, at 1:1.
nonisolated enum ArtworkExport {

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case svg, png, pdf
        var id: String { rawValue }
        var title: String {
            switch self {
            case .svg: "SVG"
            case .png: "PNG"
            case .pdf: "PDF"
            }
        }
        var fileExtension: String { rawValue }
        var contentType: UTType {
            switch self {
            case .svg: .svg
            case .png: .png
            case .pdf: .pdf
            }
        }
    }

    enum Polarity: String, CaseIterable, Identifiable, Sendable {
        case whiteOnBlack, blackOnWhite
        var id: String { rawValue }
        var title: String {
            switch self {
            case .whiteOnBlack: "White on black"
            case .blackOnWhite: "Black on white"
            }
        }
        /// The toolpath colour, and the field behind it.
        var foregroundHex: String { self == .whiteOnBlack ? "#FFFFFF" : "#000000" }
        var backgroundHex: String { self == .whiteOnBlack ? "#000000" : "#FFFFFF" }
        var foregroundLevel: CGFloat { self == .whiteOnBlack ? 1 : 0 }
        var backgroundLevel: CGFloat { self == .whiteOnBlack ? 0 : 1 }
    }

    /// What the exported page spans.
    enum FrameMode: String, CaseIterable, Identifiable, Sendable {
        /// The finished board: the cutout path pulled back in by half the
        /// cutter diameter, which is the designed outline — a 70 × 30 mm board
        /// gives a 70 × 30 mm page, with the artwork where it sits on the copper.
        case board
        /// From the machine origin out to the far corner of every program:
        /// the artwork keeps its offset from X0/Y0, so dropping the file at
        /// 0,0 in laser software puts it exactly where the mill would cut.
        case origin
        /// The union of every program, cropped — identical page for each
        /// layer (they still register), but the origin offset is gone.
        case project
        /// This program's own extent only.
        case layer

        var id: String { rawValue }
        var title: String {
            switch self {
            case .board: "Board"
            case .origin: "Origin"
            case .project: "Project"
            case .layer: "Layer"
            }
        }
    }

    struct Options: Sendable {
        var format: Format = .svg
        var polarity: Polarity = .whiteOnBlack
        /// PNG only. The pixel grid is `size × dpi`, and the DPI is written into
        /// the file, so laser software places it at its true physical size.
        var dpi: Int = 1000
        var frameMode: FrameMode = .board
        /// Sweep the path at the cutter diameter (the copper actually cleared),
        /// mirroring the canvas's Tool Width option. Off: bare centrelines.
        var toolWidth = true
    }

    /// Keys the sidebar's export controls are stored under, so the batch
    /// export and the per-layer button always agree.
    enum Keys {
        static let format = "export.format"
        static let polarity = "export.polarity"
        static let dpi = "export.dpi"
        static let frame = "export.frame"
        static let toolWidth = "previewShowToolWidth"
    }

    struct Result: Sendable {
        var url: URL?
        var log = ""
        var succeeded = true
    }

    /// Centreline width used when a program has no known cutter diameter
    /// (drill programs), and the dot diameter drawn at each drill hit.
    static let hairline: Double = 0.1
    static let drillDotDiameter: Double = 0.5

    // MARK: - Geometry

    /// The cutting moves of a layer, joined into polylines. Matches what the
    /// canvas strokes: `.cut` and `.plunge`, never rapids (head travel is not
    /// material, and a laser must not fire along it).
    static func polylines(of layer: ParsedLayer) -> [[CGPoint]] {
        var lines: [[CGPoint]] = []
        var current: [CGPoint] = []
        for move in layer.moves {
            guard move.kind != .rapid else { continue }
            guard move.start != move.end else { continue }   // pure Z moves have no footprint
            if let last = current.last, last == move.start {
                current.append(move.end)
            } else {
                if current.count > 1 { lines.append(current) }
                current = [move.start, move.end]
            }
        }
        if current.count > 1 { lines.append(current) }
        return lines
    }

    /// Stroke width for a layer: the real cutter diameter when known.
    static func strokeWidth(for layer: ParsedLayer, options: Options) -> Double {
        guard options.toolWidth, let diameter = layer.toolDiameter, diameter > 0 else { return hairline }
        return diameter
    }

    /// The page a layer is drawn into.
    struct Page: Sendable {
        var rect: CGRect
        /// This layer's own extent. Anything of it outside `rect` is not in
        /// the file, and the caller says so.
        var content: CGRect
        /// Set when the requested frame could not be built and another was used.
        var note: String?
    }

    /// The finished board: the cutout centreline pulled in by half the cutter,
    /// which is exactly the outline as drawn in the Gerber. nil when the
    /// project has no cutout program (or no known cutter diameter) to measure.
    static func boardRect(in document: PreviewDocument) -> CGRect? {
        guard let outline = document.layers.first(where: { $0.id == .outline }),
              let path = outline.cutBounds ?? outline.allBounds,
              let cutter = outline.toolDiameter, cutter > 0 else { return nil }
        let board = path.insetBy(dx: cutter / 2, dy: cutter / 2)
        return board.width > 0 && board.height > 0 ? board : nil
    }

    /// The page a layer is drawn into, in millimetres: the cut extent grown by
    /// half a stroke so the swept edge is never clipped, framed as the mode asks.
    static func frame(for layer: ParsedLayer, in document: PreviewDocument, options: Options) -> Page? {
        // This layer's own footprint — what could be clipped by the page.
        guard let own = layer.cutBounds ?? layer.allBounds else { return nil }
        let m = margin(of: layer, options: options)
        let content = own.insetBy(dx: -m, dy: -m)

        func union() -> CGRect {
            var union = CGRect.null
            for other in document.layers {
                guard let bounds = other.cutBounds ?? other.allBounds else { continue }
                let m = margin(of: other, options: options)
                union = union.union(bounds.insetBy(dx: -m, dy: -m))
            }
            return union
        }

        var note: String?
        var page: CGRect
        switch options.frameMode {
        case .board:
            if let board = boardRect(in: document) {
                page = board
            } else {
                note = "no cutout program with a known cutter diameter to measure the board from — framed from the origin instead."
                page = union().union(CGRect.zero)
            }
        case .origin:
            // Pinned to the machine origin: cropping to the toolpath throws
            // away its offset from X0/Y0 (5 mm of it on a typical board), and
            // the laser would burn the artwork in the wrong place. The page
            // spans X0/Y0 and every program; with the origin at the lower-left
            // corner (the default) the page corner IS X0/Y0.
            page = union().union(CGRect.zero)
        case .project:
            page = union()
        case .layer:
            page = content
        }
        guard !page.isNull, page.width > 0, page.height > 0 else { return nil }
        return Page(rect: page, content: content, note: note)
    }

    private static func margin(of layer: ParsedLayer, options: Options) -> CGFloat {
        let stroke = strokeWidth(for: layer, options: options)
        let dot = layer.drillHits.isEmpty ? 0 : drillDotDiameter
        return CGFloat(max(stroke, dot) / 2)
    }

    // MARK: - Export

    static func export(layer: ParsedLayer, document: PreviewDocument,
                       options: Options, output: URL) -> Result {
        var result = Result()
        guard let framing = frame(for: layer, in: document, options: options) else {
            result.succeeded = false
            result.log = "\(layer.displayName) has no cutting moves to export.\n"
            return result
        }
        let page = framing.rect

        let lines = polylines(of: layer)
        guard !lines.isEmpty || !layer.drillHits.isEmpty else {
            result.succeeded = false
            result.log = "\(layer.displayName) has no cutting moves to export.\n"
            return result
        }

        let width = strokeWidth(for: layer, options: options)
        do {
            switch options.format {
            case .svg:
                try writeSVG(lines: lines, hits: layer.drillHits, page: page,
                             strokeWidth: width, options: options, to: output)
            case .pdf:
                try writePDF(lines: lines, hits: layer.drillHits, page: page,
                             strokeWidth: width, options: options, to: output)
            case .png:
                try writePNG(lines: lines, hits: layer.drillHits, page: page,
                             strokeWidth: width, options: options, to: output)
            }
        } catch {
            result.succeeded = false
            result.log = "Export failed: \(error.localizedDescription)\n"
            return result
        }

        result.url = output
        result.log = String(
            format: "Exported %@ — %.2f × %.2f mm at 1:1, origin corner at X%.3f Y%.3f, %d path%@%@, %@.\n",
            layer.displayName, page.width, page.height, page.minX, page.minY,
            lines.count, lines.count == 1 ? "" : "s",
            options.toolWidth && layer.toolDiameter != nil
                ? String(format: " swept at %.3f mm", width) : " as centrelines",
            options.polarity == .whiteOnBlack ? "white on black" : "black on white")
        if let note = framing.note { result.log += "NOTE: \(note)\n" }
        switch options.frameMode {
        case .board:
            result.log += String(format: "Page is the finished board, %.2f × %.2f mm — align it to the board edges.\n",
                                 page.width, page.height)
        case .origin:
            result.log += page.minX == 0 && page.minY == 0
                ? "Page corner is X0 Y0 — place the file at 0,0 and it sits where the mill would cut.\n"
                : String(format: "Page corner is X%.3f Y%.3f — place the file there and it sits where the mill would cut.\n",
                         page.minX, page.minY)
        case .project, .layer:
            break
        }
        result.log += clippingWarning(page: page, content: framing.content, options: options)
        if !layer.drillHits.isEmpty {
            result.log += String(format: "%d drill hits drawn at %.1f mm — per-hole bit sizes are not modelled.\n",
                                 layer.drillHits.count, drillDotDiameter)
        }
        result.log += "Wrote \(output.path)\n"
        return result
    }

    /// Says what of this program falls outside the page, in the terms of the
    /// frame that put it there. Silence means everything is in the file.
    private static func clippingWarning(page: CGRect, content: CGRect, options: Options) -> String {
        guard !page.contains(content) else { return "" }
        let alternative = options.frameMode == .layer ? "" :
            " Frame \"Layer\" keeps the whole program."
        guard page.intersects(content) else {
            return "WARNING: this program lies entirely outside the page, so the file is blank."
                + (options.frameMode == .board
                   ? " The cutout runs around the OUTSIDE of the board, so it cannot fit a board-sized page."
                   : "")
                + alternative + "\n"
        }
        var sides: [String] = []
        if content.minX < page.minX { sides.append(String(format: "%.3f mm left", page.minX - content.minX)) }
        if content.minY < page.minY { sides.append(String(format: "%.3f mm below", page.minY - content.minY)) }
        if content.maxX > page.maxX { sides.append(String(format: "%.3f mm right", content.maxX - page.maxX)) }
        if content.maxY > page.maxY { sides.append(String(format: "%.3f mm above", content.maxY - page.maxY)) }
        return "WARNING: this program runs past the page (\(sides.joined(separator: ", "))); "
            + "that part is not in the file." + alternative + "\n"
    }

    // MARK: - SVG

    /// Real-world units: `width`/`height` in mm with a 1 mm user unit, so the
    /// file opens at true size everywhere. The group flips Y — G-code counts up,
    /// SVG counts down.
    private static func writeSVG(lines: [[CGPoint]], hits: [CGPoint], page: CGRect,
                                 strokeWidth: Double, options: Options, to url: URL) throws {
        func mm(_ value: CGFloat) -> String { String(format: "%.4f", value) }

        var svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" version="1.1" \
        width="\(mm(page.width))mm" height="\(mm(page.height))mm" \
        viewBox="0 0 \(mm(page.width)) \(mm(page.height))">
        <rect x="0" y="0" width="\(mm(page.width))" height="\(mm(page.height))" fill="\(options.polarity.backgroundHex)"/>
        <g transform="matrix(1,0,0,-1,\(mm(-page.minX)),\(mm(page.maxY)))">

        """

        if !lines.isEmpty {
            var d = ""
            for line in lines {
                guard let first = line.first else { continue }
                d += "M \(mm(first.x)) \(mm(first.y))"
                for point in line.dropFirst() { d += " L \(mm(point.x)) \(mm(point.y))" }
                d += " "
            }
            svg += """
            <path d="\(d.trimmingCharacters(in: .whitespaces))" fill="none" \
            stroke="\(options.polarity.foregroundHex)" stroke-width="\(mm(CGFloat(strokeWidth)))" \
            stroke-linecap="round" stroke-linejoin="round"/>

            """
        }
        for hit in hits {
            svg += "<circle cx=\"\(mm(hit.x))\" cy=\"\(mm(hit.y))\" r=\"\(mm(CGFloat(drillDotDiameter / 2)))\""
                + " fill=\"\(options.polarity.foregroundHex)\"/>\n"
        }
        svg += "</g>\n</svg>\n"
        try svg.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Raster / PDF

    private enum ExportError: LocalizedError {
        case context, write
        var errorDescription: String? {
            switch self {
            case .context: "could not create the drawing context"
            case .write: "could not write the file"
            }
        }
    }

    /// Draws the toolpath into a context whose user space is already
    /// millimetres with the page's lower-left corner at the origin.
    private static func draw(lines: [[CGPoint]], hits: [CGPoint], page: CGRect,
                             strokeWidth: Double, options: Options, in context: CGContext) {
        let level = options.polarity.backgroundLevel
        context.setFillColor(red: level, green: level, blue: level, alpha: 1)
        context.fill(CGRect(origin: .zero, size: page.size))

        context.translateBy(x: -page.minX, y: -page.minY)
        let ink = options.polarity.foregroundLevel
        context.setStrokeColor(red: ink, green: ink, blue: ink, alpha: 1)
        context.setFillColor(red: ink, green: ink, blue: ink, alpha: 1)
        context.setLineWidth(strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for line in lines {
            guard let first = line.first else { continue }
            context.beginPath()
            context.move(to: first)
            for point in line.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        }
        for hit in hits {
            let r = CGFloat(drillDotDiameter / 2)
            context.fillEllipse(in: CGRect(x: hit.x - r, y: hit.y - r, width: r * 2, height: r * 2))
        }
    }

    private static func writePDF(lines: [[CGPoint]], hits: [CGPoint], page: CGRect,
                                 strokeWidth: Double, options: Options, to url: URL) throws {
        // PDF user space is 1/72 inch; scaling by mm→points keeps 1:1 physical size.
        let scale = 72.0 / 25.4
        var box = CGRect(x: 0, y: 0, width: page.width * scale, height: page.height * scale)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ExportError.context }
        context.beginPage(mediaBox: &box)
        context.scaleBy(x: scale, y: scale)
        draw(lines: lines, hits: hits, page: page, strokeWidth: strokeWidth, options: options, in: context)
        context.endPage()
        context.closePDF()
    }

    private static func writePNG(lines: [[CGPoint]], hits: [CGPoint], page: CGRect,
                                 strokeWidth: Double, options: Options, to url: URL) throws {
        let scale = Double(options.dpi) / 25.4
        let pixelWidth = max(1, Int((page.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((page.height * scale).rounded(.up)))
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ExportError.context }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.scaleBy(x: scale, y: scale)
        draw(lines: lines, hits: hits, page: page, strokeWidth: strokeWidth, options: options, in: context)

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ExportError.write }
        // PNG carries resolution as pixels per metre (pHYs); without it laser
        // software assumes 72 dpi and places the artwork at ~14× its real size.
        let perMetre = Int((Double(options.dpi) / 0.0254).rounded())
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: options.dpi,
            kCGImagePropertyDPIHeight: options.dpi,
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGXPixelsPerMeter: perMetre,
                kCGImagePropertyPNGYPixelsPerMeter: perMetre
            ] as [CFString: Any]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.write }
    }

    /// True when nothing of this program would land on the page — a board-sized
    /// frame cannot hold the cutout path, for instance. The batch skips these
    /// instead of writing empty files.
    static func wouldBeBlank(layer: ParsedLayer, document: PreviewDocument, options: Options) -> Bool {
        guard let framing = frame(for: layer, in: document, options: options) else { return true }
        return !framing.rect.intersects(framing.content)
    }

    // MARK: - Naming

    /// `front-copper_white-on-black.svg` — the layer and its polarity, so a
    /// folder of exports stays readable.
    static func suggestedFilename(layer: LayerKind, options: Options) -> String {
        let polarity = options.polarity == .whiteOnBlack ? "white-on-black" : "black-on-white"
        return "\(layer.fileSlug)_\(polarity).\(options.format.fileExtension)"
    }
}


extension ArtworkExport.Options {
    /// The options the sidebar's Laser export controls are currently set to.
    static var current: Self {
        let defaults = UserDefaults.standard
        var options = Self()
        if let raw = defaults.string(forKey: ArtworkExport.Keys.format),
           let format = ArtworkExport.Format(rawValue: raw) { options.format = format }
        if let raw = defaults.string(forKey: ArtworkExport.Keys.polarity),
           let polarity = ArtworkExport.Polarity(rawValue: raw) { options.polarity = polarity }
        let dpi = defaults.integer(forKey: ArtworkExport.Keys.dpi)
        if dpi > 0 { options.dpi = dpi }
        if let raw = defaults.string(forKey: ArtworkExport.Keys.frame),
           let mode = ArtworkExport.FrameMode(rawValue: raw) { options.frameMode = mode }
        // Absent means the canvas default, which is on.
        options.toolWidth = defaults.object(forKey: ArtworkExport.Keys.toolWidth) as? Bool ?? true
        return options
    }
}
