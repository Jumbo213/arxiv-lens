import Foundation
import NaturalLanguage
import PDFKit

public struct PDFTextSpan: Codable, Equatable, Sendable {
    public let page: Int
    public let range: NSRange
}

struct ReadingPair: Codable, Sendable {
    let original: [String]
    let chinese: [String]

    private struct Sentence {
        let fragments: [String]
        let anchors: Set<String>
    }

    private static let markers = try! NSRegularExpression(pattern: #"ZXQ([0-9]{4})QXZ"#)
    private static let technicalTerms = try! NSRegularExpression(pattern: #"\b[A-Z][A-Z0-9]{2,}\b"#)

    static func sentences(original: String, chinese: String, originalTokens: [String], chineseTokens: [String]) -> [Self] {
        let left = split(original, tokens: originalTokens, language: .english)
        let right = split(chinese, tokens: chineseTokens, language: .simplifiedChinese)
        guard !left.isEmpty, !right.isEmpty else { return [] }

        // Unique shared notation can pin down a sentence even when a nearby
        // translation merged or split sentences in a legacy paragraph.
        func locations(_ sentences: [Sentence]) -> [String: [Int]] {
            var locations: [String: [Int]] = [:]
            for (index, sentence) in sentences.enumerated() {
                for anchor in sentence.anchors { locations[anchor, default: []].append(index) }
            }
            return locations
        }
        let a = locations(left)
        let b = locations(right)
        var matches: [Int: Set<Int>] = [:]
        for (anchor, indexes) in a where indexes.count == 1 {
            if let other = b[anchor], other.count == 1 { matches[indexes[0], default: []].insert(other[0]) }
        }
        guard matches.values.allSatisfy({ $0.count == 1 }) else { return [] }
        let anchors = matches.keys.sorted().compactMap { index in matches[index]?.first.map { (index, $0) } }
        var leftStart = 0
        var rightStart = 0
        var result: [Self] = []
        func append(_ i: Int, _ j: Int) {
            result.append(Self(original: left[i].fragments, chinese: right[j].fragments))
        }
        for (i, j) in anchors + [(left.count, right.count)] {
            guard i >= leftStart, j >= rightStart else { return [] }
            if i - leftStart == j - rightStart {
                for (from, to) in zip(leftStart..<i, rightStart..<j) { append(from, to) }
            }
            if i < left.count {
                append(i, j)
                leftStart = i + 1
                rightStart = j + 1
            }
        }
        return result
    }

    private static func split(_ source: String, tokens: [String], language: NLLanguage) -> [Sentence] {
        let text = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Parenthetical questions can contain punctuation without ending the
        // enclosing sentence. Mask those marks only for boundary detection.
        var closers: [Character] = []
        let masked = String(text.map { character -> Character in
            switch character {
            case "(": closers.append(")")
            case "（": closers.append("）")
            case "[": closers.append("]")
            case "【": closers.append("】")
            case ")", "）", "]", "】":
                if closers.last == character { closers.removeLast() }
            case ".", "!", "?", "。", "！", "？":
                if !closers.isEmpty { return "," }
            default: break
            }
            return character
        })
        let boundaries = closers.isEmpty ? masked : text
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(language)
        tokenizer.string = boundaries
        let original = text as NSString
        return tokenizer.tokens(for: boundaries.startIndex..<boundaries.endIndex).compactMap { range in
            let sentence = original.substring(with: NSRange(range, in: boundaries))
            let fragments = TranslationUnit.readingFragments(sentence)
            guard !fragments.isEmpty else { return nil }
            let raw = sentence as NSString
            let whole = NSRange(location: 0, length: raw.length)
            let notation = markers.matches(in: sentence, range: whole).compactMap { match -> String? in
                guard let index = Int(raw.substring(with: match.range(at: 1))), tokens.indices.contains(index) else { return nil }
                let token = tokens[index].filter { !$0.isWhitespace }
                guard token.contains("\\cite") || token.contains("\\ref") || token.contains("\\eqref")
                        || (token.hasPrefix("$") && token.count >= 8) else { return nil }
                return token
            }
            let prose = fragments.joined(separator: " ")
            let terms = technicalTerms.matches(in: prose, range: NSRange(location: 0, length: prose.utf16.count))
                .map { (prose as NSString).substring(with: $0.range) }
            return Sentence(fragments: fragments, anchors: Set(notation + terms))
        }
    }
}

public struct PDFTextAlignment: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let original: [PDFTextSpan]
        let chinese: [PDFTextSpan]
    }

    let entries: [Entry]
    let version: Int
    private static let currentVersion = 2

    public static func load(for paper: Paper) -> Self? {
        load(for: paper, in: Paper.support)
    }

    private static func load(for paper: Paper, in support: URL) -> Self? {
        guard let data = try? Data(contentsOf: paper.directory(in: support).appendingPathComponent("alignment.json")),
              let index = try? JSONDecoder().decode(Self.self, from: data),
              index.version == currentVersion, !index.entries.isEmpty else { return nil }
        return index
    }

    public static func recover(for paper: Paper) async throws -> Self? {
        try recover(for: paper, in: Paper.support)
    }

    static func recover(for paper: Paper, in support: URL) throws -> Self? {
        if let existing = load(for: paper, in: support) { return existing }
        let fm = FileManager.default
        guard paper.hasTranslation, let id = try? ArxivID(paper.arxivID) else { return nil }
        let directory = paper.directory(in: support)
        let translated = directory.appendingPathComponent("source", isDirectory: true)
        let candidates = id.isVersioned ? [paper] + Paper.history(in: support).filter { $0.arxivID == paper.arxivID } : [paper]
        guard fm.fileExists(atPath: translated.path),
              let originalSource = candidates.lazy.map({ $0.originalSource(in: support) })
                .first(where: { fm.fileExists(atPath: $0.path) }),
              let originalPDF = PDFDocument(url: directory.appendingPathComponent("original.pdf")),
              let chinesePDF = PDFDocument(url: directory.appendingPathComponent("chinese.pdf")) else { return nil }
        let project = try TeXProject.read(from: originalSource)
        let pairs = try project.recoverReadingPairs(originalSource: originalSource, translatedSource: translated)
        let alignment = try build(pairs, original: originalPDF, chinese: chinesePDF)
        guard !alignment.entries.isEmpty else { return nil }
        try Task.checkCancellation()
        if let existing = load(for: paper, in: support) { return existing }
        try? JSONEncoder().encode(alignment).write(to: directory.appendingPathComponent("alignment.json"), options: .atomic)
        return alignment
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
        return Self(entries: entries, version: currentVersion)
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
