import Foundation

private let documentStart = try! NSRegularExpression(pattern: #"\\begin\s*\{\s*document\s*\}"#)
private let documentEnd = try! NSRegularExpression(pattern: #"\\end\s*\{\s*document\s*\}"#)
private let documentClass = try! NSRegularExpression(pattern: #"\\documentclass\s*(?:\[[^\]]*\]\s*)?\{([^{}]+)\}"#)
private let titleCommand = try! NSRegularExpression(pattern: #"\\(?:title|subtitle|shorttitle)\s*(?:\[[^\]]*\]\s*)?\{"#)
private let include = try! NSRegularExpression(pattern: #"\\(?:input|include|subfile|subfileinclude)\s*\{\s*([^{}\s]+)\s*\}|\\input[ \t]+([\w./-]+)"#)
private let imports = try! NSRegularExpression(pattern: #"\\(?:subimport|import|inputfrom|includefrom|subinputfrom|subincludefrom)\s*\{([^{}]*)\}\s*\{([^{}]+)\}"#)
private let comments = try! NSRegularExpression(pattern: #"(?<!\\)(?:\\\\)*(%[^\r\n]*)"#)

private func uncomment(_ source: String) -> String {
    let result = NSMutableString(string: source)
    for match in comments.matches(source).reversed() {
        let comment = match.range(at: 1)
        result.replaceCharacters(in: comment, with: String(repeating: " ", count: comment.length))
    }
    return result as String
}

private extension NSRegularExpression {
    func matches(_ source: String) -> [NSTextCheckingResult] {
        matches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
    }
}

struct TranslationUnit: Sendable {
    let range: NSRange
    let prompt: String
    let tokens: [String]
    private static let marker = try! NSRegularExpression(pattern: #"ZXQ[0-9]{4}QXZ"#)

    static func marker(_ index: Int) -> String { String(format: "ZXQ%04dQXZ", index) }

    func restore(_ translated: String) -> String? {
        let translated = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty, translated.utf16.count < max(350, prompt.utf16.count * 4),
              !translated.hasPrefix("\u{60}") else { return nil }
        let hasChinese = translated.range(of: #"\p{Script=Han}"#, options: .regularExpression) != nil
        let unchangedName = tokens.isEmpty && translated == prompt && prompt.utf16.count <= 40
            && prompt.split(whereSeparator: \.isWhitespace).count <= 4
        guard hasChinese || unchangedName else { return nil }
        let input = translated as NSString
        let markers = Self.marker.matches(translated)
        guard markers.map({ input.substring(with: $0.range) }) == tokens.indices.map(Self.marker) else { return nil }
        let escapes: [Character: String] = [
            "\\": "\\textbackslash{}", "{": "\\{", "}": "\\}", "%": "\\%", "&": "\\&",
            "#": "\\#", "_": "\\_", "$": "\\$", "~": "\\textasciitilde{}", "^": "\\textasciicircum{}"
        ]
        func prose(_ range: NSRange) -> String {
            input.substring(with: range)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .map { escapes[$0] ?? String($0) }.joined()
        }
        var cursor = 0
        var result = ""
        for (index, marker) in markers.enumerated() {
            result += prose(NSRange(location: cursor, length: marker.range.location - cursor))
            result += tokens[index]
            cursor = NSMaxRange(marker.range)
        }
        return result + prose(NSRange(location: cursor, length: input.length - cursor))
    }
}

struct TeXDraft {
    let url: URL
    let content: String
    let units: [TranslationUnit]
    let documentOffset: Int?

    func write(_ translations: [String?], font: String) throws {
        let output = NSMutableString(string: content)
        let alreadySupportsChinese = uncomment(content).range(
            of: #"\\(?:usepackage\s*(?:\[[^\]]*\])?\s*\{[^}]*\b(?:xeCJK|ctex)\b|documentclass\s*(?:\[[^\]]*\])?\s*\{ctex\w+)"#,
            options: .regularExpression
        ) != nil
        var offset = documentOffset
        for (unit, translated) in zip(units, translations).reversed() {
            if let translated {
                output.replaceCharacters(in: unit.range, with: translated)
                if let current = offset, NSMaxRange(unit.range) <= current {
                    offset = current + translated.utf16.count - unit.range.length
                }
            }
        }
        if let offset, !alreadySupportsChinese {
            output.insert("""

            % Arxiv Lens: Chinese font support.
            \\usepackage{xeCJK}
            \\setCJKmainfont[AutoFakeBold=2,AutoFakeSlant=.2]{\(font)}
            \\setCJKsansfont[AutoFakeBold=2]{\(font)}
            \\setCJKmonofont{\(font)}
            \\AtBeginDocument{\\ifdefined\\abstractname\\renewcommand{\\abstractname}{摘要}\\fi}
            \\AtBeginDocument{\\ifdefined\\refname\\renewcommand{\\refname}{参考文献}\\fi}
            \\AtBeginDocument{\\ifdefined\\bibname\\renewcommand{\\bibname}{参考文献}\\fi}

            """, at: offset)
        }
        try (output as String).write(to: url, atomically: true, encoding: .utf8)
    }
}

struct TeXProject {
    let root: URL
    let title: String?
    let drafts: [TeXDraft]

    static func read(from directory: URL) throws -> Self {
        let directory = directory.resolvingSymlinksInPath()
        let fm = FileManager.default
        let all = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? []
        let candidates = all.map(\.standardizedFileURL).filter { $0.pathExtension.lowercased() == "tex" }.compactMap { url -> (URL, Int)? in
            guard let source = try? readFile(url) else { return nil }
            let clean = uncomment(source)
            guard let start = documentStart.matches(clean).first,
                  let cls = documentClass.matches(clean).first, cls.range.location < start.range.location else { return nil }
            let name = (clean as NSString).substring(with: cls.range(at: 1))
            guard name != "subfiles" else { return nil }
            let level = url.pathComponents.count - directory.pathComponents.count
            let score = (50 - level * 10) + (clean.contains("\\maketitle") ? 25 : 0)
                + (clean.contains("\\title") ? 20 : 0) + min(source.count / 1500, 15)
                + (["main", "paper", "ms", "manuscript"].contains(url.deletingPathExtension().lastPathComponent) ? 12 : 0)
            return (url, score)
        }.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
        guard let root = candidates.first?.0 else {
            throw LensError("找不到含有 \\documentclass 和 \\begin{document} 的主 TeX 文件。")
        }
        let entry = root.deletingLastPathComponent()
        var visited = Set<String>()
        var drafts: [TeXDraft] = []
        var title: String?
        func visit(_ url: URL) throws {
            guard visited.insert(url.path).inserted else { return }
            let content = try readFile(url)
            let clean = uncomment(content)
            let ns = clean as NSString
            let start = documentStart.matches(clean).first?.range
            let end = documentEnd.matches(clean).last?.range.location ?? ns.length
            var scanner = Scanner(content)
            if let start {
                for match in titleCommand.matches(clean) where NSMaxRange(match.range) < start.location {
                    if let group = scanner.group(at: NSMaxRange(match.range) - 1) {
                        let body = NSRange(location: group.location + 1, length: group.length - 2)
                        if url == root && title == nil {
                            title = ns.substring(with: body)
                                .replacingOccurrences(of: #"\\[a-zA-Z]+\*?|[{}$]"#, with: "", options: .regularExpression)
                                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        }
                        scanner.scan(from: body.location, to: NSMaxRange(body))
                    }
                }
            }
            let bodyStart = start.map(NSMaxRange) ?? 0
            scanner.scan(from: bodyStart, to: max(bodyStart, end))
            drafts.append(TeXDraft(url: url, content: content, units: scanner.units,
                                   documentOffset: url == root ? start?.location : nil))

            var names: [(String, Int)] = include.matches(clean).map {
                let arg = $0.range(at: 1).location == NSNotFound ? $0.range(at: 2) : $0.range(at: 1)
                return (ns.substring(with: arg), $0.range.location)
            }
            names += imports.matches(clean).map {
                let folder = ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let name = ns.substring(with: $0.range(at: 2)).trimmingCharacters(in: .whitespaces)
                return ((folder as NSString).appendingPathComponent(name), $0.range.location)
            }
            for (name, position) in names.sorted(by: { $0.1 < $1.1 }) {
                guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains("#"),
                      start == nil || position >= bodyStart else { continue }
                let paths = [url.deletingLastPathComponent(), entry].flatMap { base in
                    let location = base.appendingPathComponent(name)
                    return [location, location.appendingPathExtension("tex")]
                }
                if let child = paths.map({ $0.standardizedFileURL }).first(where: {
                    guard $0.path.hasPrefix(directory.path + "/"),
                          ["tex", ""].contains($0.pathExtension.lowercased()) else { return false }
                    return (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }) {
                    try visit(child)
                }
            }
        }
        try visit(root)
        return Self(root: root, title: title?.isEmpty == false ? title : nil, drafts: drafts)
    }

    private static func readFile(_ url: URL) throws -> String {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8 * 1024 * 1024 else {
            throw LensError("TeX 文件过大：\(url.lastPathComponent)")
        }
        let data = try Data(contentsOf: url)
        if let value = String(data: data, encoding: .utf8) { return value }
        throw LensError("TeX 文件不是 UTF-8 编码：\(url.lastPathComponent)")
    }
}

private struct Scanner {
    private let text: NSString
    private let source: String
    private(set) var units: [TranslationUnit] = []
    private var parts: [(NSRange, Bool)] = []
    private var limit: Int

    private static let word = try! NSRegularExpression(pattern: #"[a-z]{2,}"#, options: .caseInsensitive)
    private static let command = try! NSRegularExpression(pattern: #"\\(?:[a-zA-Z@]+\*?|[^\r\n])"#)
    private static let identifier = try! NSRegularExpression(pattern: #"https?://[^\s{}\\]+|(?<![\w.])[+-]?\d+(?:[.,]\d+)*(?:[eE][+-]?\d+)?(?![\w]|\.\d)"#)
    private static let blank = try! NSRegularExpression(pattern: #"\r?\n[ \t]*\r?\n"#)
    private static let opaqueEnvironment = try! NSRegularExpression(
        pattern: #"^(?:equation|align|alignat|gather|flalign|multline|eqnarray|split|aligned|cases|matrix|pmatrix|bmatrix|math|displaymath|IEEEeqnarray|thebibliography|filecontents|verbatim|Verbatim|lstlisting|minted|tikzpicture|pgfpicture|comment)\*?$"#
    )
    private static let inlineText: Set<String> = [
        "textbf", "textit", "textsl", "textsc", "textup", "textnormal", "textrm", "textsf", "emph",
        "underline", "footnote", "footnotetext", "textsuperscript", "textsubscript", "mbox"
    ]
    private static let headings: Set<String> = [
        "title", "subtitle", "chapter", "part", "section", "subsection", "subsubsection",
        "paragraph", "subparagraph", "caption", "captionof", "abstract", "keywords"
    ]
    private static let boundaries: Set<String> = [
        "begin", "end", "item", "input", "include", "subfile", "bibliography", "printbibliography",
        "bibliographystyle", "hline", "midrule", "toprule", "bottomrule", "cmidrule", "\\", "par",
        "newcommand", "renewcommand", "providecommand", "def", "maketitle", "appendix"
    ]

    init(_ source: String) { self.source = source; text = source as NSString; limit = text.length }

    func group(at start: Int) -> NSRange? {
        guard start < limit else { return nil }
        let open = text.character(at: start)
        let close: unichar = open == 123 ? 125 : 93
        guard open == 123 || open == 91 else { return nil }
        var stack = [close]
        var index = start + 1
        while index < limit {
            let c = text.character(at: index)
            if c == 92 { index += 2; continue }
            if c == 37 { index = newline(after: index); continue }
            if c == stack.last {
                stack.removeLast()
                if stack.isEmpty { return NSRange(location: start, length: index - start + 1) }
            } else if c == 123 || (c == 91 && stack.last == 93) {
                stack.append(c == 123 ? 125 : 93)
            }
            index += 1
        }
        return nil
    }

    mutating func scan(from: Int, to: Int) {
        walk(from: from, to: to)
        flush()
    }

    private func match(_ pattern: NSRegularExpression, at index: Int, to: Int) -> NSRange? {
        pattern.firstMatch(in: source, options: [.anchored, .withTransparentBounds],
                           range: NSRange(location: index, length: to - index))?.range
    }

    private func slice(_ start: Int, _ end: Int) -> String {
        text.substring(with: NSRange(location: start, length: end - start))
    }

    private func newline(after index: Int) -> Int {
        let found = text.rangeOfCharacter(from: .newlines, options: [],
                                          range: NSRange(location: index, length: limit - index))
        return found.location == NSNotFound ? limit : NSMaxRange(found)
    }

    private func groups(after index: Int) -> [NSRange] {
        var groups: [NSRange] = []
        var cursor = index
        while groups.count < 8 {
            var start = cursor
            while start < limit, [9, 10, 13, 32].contains(text.character(at: start)) { start += 1 }
            guard !slice(cursor, start).contains("\n\n"), let argument = group(at: start) else { break }
            groups.append(argument)
            cursor = NSMaxRange(argument)
        }
        return groups
    }

    private mutating func walk(from: Int, to: Int) {
        let oldLimit = limit
        limit = to
        defer { limit = oldLimit }
        var i = from
        while i < to {
            let c = text.character(at: i)
            if c == 37 {
                flush()
                i = newline(after: i)
            } else if c == 10 || c == 13, let blank = match(Self.blank, at: i, to: to) {
                flush()
                i = NSMaxRange(blank)
            } else if c == 36 {
                let delimiter = i + 1 < to && text.character(at: i + 1) == 36 ? "$$" : "$"
                let end = close(delimiter, after: i + delimiter.count, to: to) ?? to
                append(i, end, protected: true)
                i = end
            } else if c == 92, let token = match(Self.command, at: i, to: to) {
                i = handle(token, to: to)
            } else if c == 38 {
                flush()
                i += 1
            } else if [35, 92, 94, 95, 123, 125, 126].contains(c) {
                append(i, i + 1, protected: true)
                i += 1
            } else if (c == 104 || c == 43 || c == 45 || (48...57).contains(c)),
                      let id = match(Self.identifier, at: i, to: to) {
                append(i, NSMaxRange(id), protected: true)
                i = NSMaxRange(id)
            } else {
                if parts.first.map({ i - $0.0.location > 2200 }) == true, [9, 10, 32].contains(c) { flush() }
                append(i, i + 1, protected: false)
                i += 1
            }
        }
    }

    private func close(_ delimiter: String, after start: Int, to: Int) -> Int? {
        var i = start
        while i < to {
            if i + delimiter.utf16.count <= to, slice(i, i + delimiter.utf16.count) == delimiter {
                return i + delimiter.utf16.count
            }
            let c = text.character(at: i)
            if c == 92 { i += 2 }
            else if c == 37 { i = newline(after: i) }
            else { i += 1 }
        }
        return nil
    }

    private mutating func handle(_ token: NSRange, to: Int) -> Int {
        let start = token.location, end = NSMaxRange(token)
        let name = slice(start + 1, end).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        if name == "(" || name == "[" {
            let endMath = close(name == "(" ? "\\)" : "\\]", after: end, to: to) ?? to
            append(start, endMath, protected: true)
            return endMath
        }
        if name == "verb", end < to {
            let delimiter = slice(end, end + 1)
            let final = close(delimiter, after: end + 1, to: newline(after: end)) ?? end
            append(start, final, protected: true)
            return final
        }
        let args = groups(after: end)
        let last = args.last.map(NSMaxRange) ?? end
        let required = args.filter { text.character(at: $0.location) == 123 }
        if name == "begin", let environment = required.first {
            let env = slice(environment.location + 1, NSMaxRange(environment) - 1)
            if Self.opaqueEnvironment.matches(env).first != nil {
                let tail = text.range(of: "\\end{\(env)}", options: [],
                                      range: NSRange(location: NSMaxRange(environment), length: to - NSMaxRange(environment)))
                flush()
                return tail.location == NSNotFound ? to : NSMaxRange(tail)
            }
        }
        if Self.headings.contains(name) {
            flush()
            for argument in args.dropFirst(name == "captionof" ? 1 : 0).prefix(2) {
                walk(from: argument.location + 1, to: NSMaxRange(argument) - 1)
                flush()
            }
            return last
        }
        if Self.inlineText.contains(name), let argument = required.first {
            append(start, argument.location + 1, protected: true)
            walk(from: argument.location + 1, to: NSMaxRange(argument) - 1)
            append(NSMaxRange(argument) - 1, NSMaxRange(argument), protected: true)
            return NSMaxRange(argument)
        }
        if ["href", "textcolor", "multicolumn", "multirow"].contains(name), required.count >= 2,
           let argument = required.last {
            append(start, argument.location + 1, protected: true)
            walk(from: argument.location + 1, to: NSMaxRange(argument) - 1)
            append(NSMaxRange(argument) - 1, NSMaxRange(argument), protected: true)
            return NSMaxRange(argument)
        }
        if Self.boundaries.contains(name) {
            flush()
            return last
        }
        let terminated = last == end && end < to && [9, 32].contains(text.character(at: end)) ? end + 1 : last
        append(start, terminated, protected: true)
        return terminated
    }

    private mutating func append(_ start: Int, _ end: Int, protected: Bool) {
        guard start < end else { return }
        if let last = parts.last, last.1 == protected, NSMaxRange(last.0) == start {
            parts[parts.count - 1].0.length += end - start
        } else {
            parts.append((NSRange(location: start, length: end - start), protected))
        }
    }

    private mutating func flush() {
        defer { parts.removeAll(keepingCapacity: true) }
        guard let first = parts.firstIndex(where: { !$0.1 && Self.word.matches(text.substring(with: $0.0)).first != nil }),
              let last = parts.lastIndex(where: { !$0.1 && !text.substring(with: $0.0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              last >= first else { return }
        var relevant = Array(parts[first...last])
        while relevant[0].0.length > 0, [9, 10, 13, 32].contains(text.character(at: relevant[0].0.location)) {
            relevant[0].0.location += 1
            relevant[0].0.length -= 1
        }
        let lastIndex = relevant.count - 1
        while relevant[lastIndex].0.length > 0,
              [9, 10, 13, 32].contains(text.character(at: NSMaxRange(relevant[lastIndex].0) - 1)) {
            relevant[lastIndex].0.length -= 1
        }
        let start = relevant[0].0.location
        let end = NSMaxRange(relevant[lastIndex].0)
        var tokens: [String] = []
        var prompt = ""
        for (range, protected) in relevant {
            let value = text.substring(with: range)
            if !protected && value.range(of: #"ZXQ[0-9]{4}QXZ"#, options: .regularExpression) != nil { return }
            if protected {
                prompt += TranslationUnit.marker(tokens.count)
                tokens.append(value)
            } else {
                prompt += value
            }
        }
        guard prompt.utf16.count <= 12_000 else { return }
        units.append(TranslationUnit(range: NSRange(location: start, length: end - start), prompt: prompt, tokens: tokens))
    }
}
