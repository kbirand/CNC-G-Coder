import Foundation

/// Reads the hole sizes an Excellon drill file declares in its header
/// ("T01C3.000"), so the sidebar can say which holes get milled and which
/// drilled before anything is generated.
nonisolated enum ExcellonReader {

    /// Distinct hole diameters in millimetres, smallest first. EasyEDA writes
    /// a 0.001 mm placeholder tool into drill files with no holes; anything
    /// that small is ignored.
    static func holeSizes(in url: URL) -> [Double] {
        guard let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return [] }
        var inch = false
        var sizes = Set<Double>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces).uppercased()
            if line.hasPrefix("INCH") || line == "M72" { inch = true }
            if line.hasPrefix("METRIC") || line == "M71" { inch = false }
            // Tool definitions: T<n>C<diameter>, possibly with more words after.
            guard line.hasPrefix("T"), let c = line.firstIndex(of: "C"),
                  line[line.index(after: line.startIndex)..<c].allSatisfy(\.isNumber) else { continue }
            let number = line[line.index(after: c)...].prefix { $0.isNumber || $0 == "." }
            guard var diameter = Double(number) else { continue }
            if inch { diameter *= 25.4 }
            if diameter >= 0.01 { sizes.insert((diameter * 1000).rounded() / 1000) }
        }
        return sizes.sorted()
    }
}
