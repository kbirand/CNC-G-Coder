import Foundation
import CoreGraphics
import CoreText

/// Turns text into outlines the editor can draw and the generator can cut:
/// installed fonts through CoreText (closed glyph contours), or the built-in
/// single-stroke font (open strokes — one line per stroke, the classic way
/// to engrave labels with a fine V-bit).
nonisolated enum TextOutlines {

    /// Outlines of `string` in design millimetres: `height` is the cap
    /// height, `origin` the start of the baseline, `rotation` in degrees
    /// about the origin.
    static func outlines(_ string: String, style: TextStyle, height: Double, origin: CGPoint,
                         rotation: Double) -> [Polyline] {
        guard !string.isEmpty, height > 0 else { return [] }
        let raw = style.isStrokeFont
            ? strokeOutlines(string, height: height, spacing: style.spacing)
            : fontOutlines(string, style: style, height: height)
        let place = CGAffineTransform(translationX: origin.x, y: origin.y)
        let t = place.concatenating(ShapeMath.rotation(rotation, about: origin))
        return raw.map { $0.applying(t) }
    }

    // MARK: - Installed fonts

    static func font(for style: TextStyle) -> CTFont {
        let base = CTFontCreateWithName(style.family as CFString, 100, nil)
        var traits: CTFontSymbolicTraits = []
        if style.bold { traits.insert(.boldTrait) }
        if style.italic { traits.insert(.italicTrait) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, 100, nil, traits, traits) ?? base
    }

    private static func fontOutlines(_ string: String, style: TextStyle, height: Double) -> [Polyline] {
        let font = font(for: style)
        let capHeight = Double(CTFontGetCapHeight(font))
        guard capHeight > 0 else { return [] }
        let scale = height / capHeight
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTKernAttributeName as NSAttributedString.Key: NSNumber(value: style.spacing / scale)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }

        var result: [Polyline] = []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for (glyph, position) in zip(glyphs, positions) {
                guard let path = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
                let t = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: position.x, y: position.y)
                result += flatten(path, transform: t)
            }
        }
        return result
    }

    /// Flattens a glyph path into closed polylines (mm after `transform`).
    private static func flatten(_ path: CGPath, transform: CGAffineTransform) -> [Polyline] {
        var out: [Polyline] = []
        var current: [CGPoint] = []
        func close() {
            if current.count >= 3 { out.append(ShapeMath.cleaned(Polyline(points: current, closed: true))) }
            current = []
        }
        func segments(_ length: Double) -> Int { max(4, min(48, Int(length * 6))) }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                close()
                current.append(e.points[0].applying(transform))
            case .addLineToPoint:
                current.append(e.points[0].applying(transform))
            case .addQuadCurveToPoint:
                guard let p0 = current.last else { break }
                let c = e.points[0].applying(transform), p1 = e.points[1].applying(transform)
                let n = segments(ShapeMath.distance(p0, c) + ShapeMath.distance(c, p1))
                for i in 1...n {
                    let t = Double(i) / Double(n), u = 1 - t
                    current.append(CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
                                           y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y))
                }
            case .addCurveToPoint:
                guard let p0 = current.last else { break }
                let c1 = e.points[0].applying(transform), c2 = e.points[1].applying(transform)
                let p1 = e.points[2].applying(transform)
                let n = segments(ShapeMath.distance(p0, c1) + ShapeMath.distance(c1, c2) + ShapeMath.distance(c2, p1))
                for i in 1...n {
                    let t = Double(i) / Double(n), u = 1 - t
                    current.append(CGPoint(
                        x: u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p1.x,
                        y: u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p1.y))
                }
            case .closeSubpath:
                close()
            @unknown default:
                break
            }
        }
        close()
        return out
    }

    // MARK: - Single-stroke font

    /// Advance per glyph, as a fraction of the height.
    static let strokeAdvance = 0.85

    private static func strokeOutlines(_ string: String, height: Double, spacing: Double) -> [Polyline] {
        var out: [Polyline] = []
        var x = 0.0
        for ch in string.uppercased() {
            if ch == "\n" { continue }
            if let strokes = StrokeFont.extended[ch] {
                for stroke in strokes {
                    let points = stroke.map { CGPoint(x: x + $0.x * height, y: $0.y * height) }
                    out.append(Polyline(points: points, closed: false))
                }
            }
            x += height * strokeAdvance + spacing
        }
        return out
    }

    /// Width of a string in the stroke font, mm.
    static func strokeWidth(of string: String, height: Double, spacing: Double) -> Double {
        let n = Double(string.filter { $0 != "\n" }.count)
        return n > 0 ? n * height * strokeAdvance + (n - 1) * spacing - height * (strokeAdvance - 0.6) : 0
    }
}

extension StrokeFont {
    /// The test-board glyphs plus the rest of the alphabet and punctuation.
    /// Unit box: x 0…0.6, y 0…1 (descenders go slightly below 0).
    nonisolated static let extended: [Character: [[CGPoint]]] = {
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
        let o: [CGPoint] = [p(0.15, 0), p(0.45, 0), p(0.6, 0.2), p(0.6, 0.8), p(0.45, 1), p(0.15, 1), p(0, 0.8), p(0, 0.2), p(0.15, 0)]
        let pTop: [CGPoint] = [p(0, 0), p(0, 1), p(0.5, 1), p(0.6, 0.85), p(0.6, 0.65), p(0.5, 0.5), p(0, 0.5)]
        func dot(_ x: Double, _ y: Double) -> [CGPoint] {
            [p(x, y), p(x + 0.1, y), p(x + 0.1, y + 0.1), p(x, y + 0.1), p(x, y)]
        }
        var g = glyphs
        g["K"] = [[p(0, 0), p(0, 1)], [p(0.6, 1), p(0, 0.4)], [p(0.2, 0.55), p(0.6, 0)]]
        g["L"] = [[p(0, 1), p(0, 0), p(0.6, 0)]]
        g["M"] = [[p(0, 0), p(0, 1), p(0.3, 0.5), p(0.6, 1), p(0.6, 0)]]
        g["N"] = [[p(0, 0), p(0, 1), p(0.6, 0), p(0.6, 1)]]
        g["O"] = [o]
        g["P"] = [pTop]
        g["Q"] = [o, [p(0.35, 0.25), p(0.6, -0.05)]]
        g["R"] = [pTop, [p(0.3, 0.5), p(0.6, 0)]]
        g["S"] = [[p(0.6, 0.85), p(0.45, 1), p(0.15, 1), p(0, 0.85), p(0, 0.65), p(0.15, 0.5), p(0.45, 0.5),
                   p(0.6, 0.35), p(0.6, 0.15), p(0.45, 0), p(0.15, 0), p(0, 0.15)]]
        g["T"] = [[p(0, 1), p(0.6, 1)], [p(0.3, 1), p(0.3, 0)]]
        g["U"] = [[p(0, 1), p(0, 0.15), p(0.15, 0), p(0.45, 0), p(0.6, 0.15), p(0.6, 1)]]
        g["V"] = [[p(0, 1), p(0.3, 0), p(0.6, 1)]]
        g["W"] = [[p(0, 1), p(0.15, 0), p(0.3, 0.6), p(0.45, 0), p(0.6, 1)]]
        g["X"] = [[p(0, 0), p(0.6, 1)], [p(0, 1), p(0.6, 0)]]
        g["Y"] = [[p(0, 1), p(0.3, 0.5), p(0.6, 1)], [p(0.3, 0.5), p(0.3, 0)]]
        g["Z"] = [[p(0, 1), p(0.6, 1), p(0, 0), p(0.6, 0)]]
        g["."] = [dot(0.25, 0)]
        g[","] = [[p(0.35, 0.1), p(0.25, -0.15)]]
        g["-"] = [[p(0.1, 0.5), p(0.5, 0.5)]]
        g["+"] = [[p(0.1, 0.5), p(0.5, 0.5)], [p(0.3, 0.3), p(0.3, 0.7)]]
        g["/"] = [[p(0, 0), p(0.6, 1)]]
        g["\\"] = [[p(0, 1), p(0.6, 0)]]
        g[":"] = [dot(0.25, 0.15), dot(0.25, 0.65)]
        g[";"] = [dot(0.25, 0.65), [p(0.35, 0.2), p(0.25, -0.05)]]
        g["("] = [[p(0.45, 1), p(0.25, 0.75), p(0.25, 0.25), p(0.45, 0)]]
        g[")"] = [[p(0.15, 1), p(0.35, 0.75), p(0.35, 0.25), p(0.15, 0)]]
        g["["] = [[p(0.45, 1), p(0.2, 1), p(0.2, 0), p(0.45, 0)]]
        g["]"] = [[p(0.15, 1), p(0.4, 1), p(0.4, 0), p(0.15, 0)]]
        g["<"] = [[p(0.55, 0.9), p(0.05, 0.5), p(0.55, 0.1)]]
        g[">"] = [[p(0.05, 0.9), p(0.55, 0.5), p(0.05, 0.1)]]
        g["!"] = [[p(0.3, 1), p(0.3, 0.3)], dot(0.25, 0)]
        g["?"] = [[p(0, 0.8), p(0.15, 1), p(0.45, 1), p(0.6, 0.8), p(0.6, 0.6), p(0.3, 0.45), p(0.3, 0.3)], dot(0.25, 0)]
        g["_"] = [[p(0, 0), p(0.6, 0)]]
        g["="] = [[p(0.1, 0.35), p(0.5, 0.35)], [p(0.1, 0.65), p(0.5, 0.65)]]
        g["'"] = [[p(0.3, 1), p(0.3, 0.8)]]
        g["\""] = [[p(0.2, 1), p(0.2, 0.8)], [p(0.4, 1), p(0.4, 0.8)]]
        g["*"] = [[p(0.3, 0.9), p(0.3, 0.4)], [p(0.08, 0.78), p(0.52, 0.52)], [p(0.08, 0.52), p(0.52, 0.78)]]
        g["#"] = [[p(0.2, 0), p(0.2, 1)], [p(0.4, 0), p(0.4, 1)], [p(0, 0.35), p(0.6, 0.35)], [p(0, 0.65), p(0.6, 0.65)]]
        g["%"] = [[p(0, 0), p(0.6, 1)], dot(0.05, 0.8), dot(0.45, 0.1)]
        g["°"] = [[p(0.2, 0.75), p(0.4, 0.75), p(0.4, 0.95), p(0.2, 0.95), p(0.2, 0.75)]]
        g["&"] = [[p(0.6, 0), p(0.15, 0.55), p(0.15, 0.85), p(0.3, 1), p(0.45, 0.85), p(0.45, 0.7), p(0, 0.3), p(0, 0.15),
                   p(0.15, 0), p(0.35, 0), p(0.6, 0.35)]]
        g["@"] = [[p(0.45, 0.3), p(0.45, 0.7), p(0.2, 0.7), p(0.2, 0.3), p(0.45, 0.3), p(0.6, 0.45), p(0.6, 0.8),
                   p(0.45, 1), p(0.15, 1), p(0, 0.8), p(0, 0.2), p(0.15, 0), p(0.5, 0)]]
        return g
    }()
}
