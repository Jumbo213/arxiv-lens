import Foundation
import PDFKit

public struct PDFTextSpan: Codable, Equatable, Sendable {
    public let page: Int
    public let range: NSRange
}

struct ReadingPair: Codable, Sendable {
    let original: [String]
    let chinese: [String]
}

public struct PDFTextAlignment: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let original: [PDFTextSpan]
        let chinese: [PDFTextSpan]
    }

    let entries: [Entry]

    public static func load(for paper: Paper) -> Self? {
        try? JSONDecoder().decode(Self.self, from: Data(contentsOf: paper.directory.appendingPathComponent("alignment.json")))
    }

    public func corresponding(to selection: [PDFTextSpan], fromOriginal: Bool) -> [PDFTextSpan] {
        entries.flatMap { entry in
            let source = fromOriginal ? entry.original : entry.chinese
            let overlaps = source.contains { part in
                selection.contains { $0.page == part.page && NSIntersectionRange($0.range, part.range).length > 0 }
            }
            return overlaps ? (fromOriginal ? entry.chinese : entry.original) : []
        }.sorted {
            if $0.page == $1.page { return $0.range.location < $1.range.location }
            return $0.page < $1.page
        }
    }

    public static func spans(in selection: PDFSelection, document: PDFDocument) -> [PDFTextSpan] {
        selection.pages.flatMap { page -> [PDFTextSpan] in
            let index = document.index(for: page)
            guard (0..<document.pageCount).contains(index) else { return [] }
            return (0..<selection.numberOfTextRanges(on: page)).compactMap { number in
                let range = selection.range(at: number, on: page)
                guard range.location != NSNotFound, range.length > 0 else { return nil }
                return PDFTextSpan(page: index, range: range)
            }
        }
    }

    static func build(_ pairs: [ReadingPair], original: PDFDocument, chinese: PDFDocument) throws -> Self {
        let left = try TextIndex(original)
        let right = try TextIndex(chinese)
        var entries: [Entry] = []
        for pair in pairs {
            try Task.checkCancellation()
            let a = left.locate(pair.original)
            guard !a.isEmpty else { continue }
            let b = right.locate(pair.chinese)
            if !b.isEmpty { entries.append(Entry(original: a, chinese: b)) }
        }
        return Self(entries: entries)
    }
}

private struct TextIndex {
    private struct PageText {
        let page: Int
        let start: Int
        let positions: [NSRange]
    }

    private let text: NSString
    private let pages: [PageText]

    init(_ document: PDFDocument) throws {
        var combined = ""
        var offset = 0
        var pages: [PageText] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let string = page.string,
                  page.numberOfCharacters == string.utf16.count else { continue }
            var normalized = ""
            var positions: [NSRange] = []
            var rawOffset = 0
            for scalar in string.unicodeScalars {
                let length = scalar.value > 0xFFFF ? 2 : 1
                let folded = Self.fold(scalar)
                normalized += folded
                positions += repeatElement(NSRange(location: rawOffset, length: length), count: folded.utf16.count)
                rawOffset += length
            }
            // Keep page boundaries so a missing page cannot create a match.
            guard offset + positions.count <= 2_000_000 else { break }
            pages.append(PageText(page: index, start: offset, positions: positions))
            combined += normalized + "\n"
            offset += positions.count + 1
        }
        self.pages = pages
        self.text = combined as NSString
    }

    private static func fold(_ scalar: Unicode.Scalar) -> String {
        let folded = String(scalar).decomposedStringWithCompatibilityMapping.lowercased()
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    func locate(_ fragments: [String]) -> [PDFTextSpan] {
        let needles = fragments.map { $0.unicodeScalars.map(Self.fold).joined() }
        let whole = NSRange(location: 0, length: text.length)
        // Require a distinctive, unique anchor before matching short pieces
        // separated by a formula, citation or formatting command.
        let anchors = needles.indices.sorted { needles[$0].utf16.count > needles[$1].utf16.count }
        for index in anchors {
            let needle = needles[index]
            let hasHan = needle.range(of: #"\p{Script=Han}"#, options: .regularExpression) != nil
            guard needle.utf16.count >= (hasHan ? 6 : 14),
                  let anchor = unique(needle, in: whole),
                  let page = pages.last(where: { $0.start <= anchor.location }) else { continue }
            let lower = max(page.start, anchor.location - 400)
            let upper = min(page.start + page.positions.count, NSMaxRange(anchor) + 400)
            var ranges = [anchor]
            var start = anchor.location
            for before in needles[..<index].reversed() where before.utf16.count >= 4 {
                guard let hit = unique(before, in: NSRange(location: lower, length: start - lower)),
                      start - NSMaxRange(hit) <= 80 else { break }
                ranges.insert(hit, at: 0)
                start = hit.location
            }
            var end = NSMaxRange(anchor)
            for after in needles[(index + 1)...] where after.utf16.count >= 4 {
                guard let hit = unique(after, in: NSRange(location: end, length: upper - end)),
                      hit.location - end <= 80 else { break }
                ranges.append(hit)
                end = NSMaxRange(hit)
            }
            return ranges.compactMap { range in
                let first = range.location - page.start
                let last = NSMaxRange(range) - page.start - 1
                guard page.positions.indices.contains(first), page.positions.indices.contains(last) else { return nil }
                let start = page.positions[first].location
                return PDFTextSpan(page: page.page,
                                   range: NSRange(location: start, length: NSMaxRange(page.positions[last]) - start))
            }
        }
        return []
    }

    private func unique(_ needle: String, in bounds: NSRange) -> NSRange? {
        guard bounds.length >= needle.utf16.count else { return nil }
        let match = text.range(of: needle, options: .literal, range: bounds)
        guard match.location != NSNotFound else { return nil }
        let next = NSRange(location: match.location + 1, length: NSMaxRange(bounds) - match.location - 1)
        return text.range(of: needle, options: .literal, range: next).location == NSNotFound ? match : nil
    }
}
