import AppKit
import Foundation
import PDFKit

public enum PaperPipeline {
    public struct CompileFailure: LocalizedError, Sendable {
        public let message: String
        public let logURL: URL?
        public var errorDescription: String? { message }
    }

    private struct Draft: Codable, Sendable {
        let paper: Paper
        let originalID: UUID
        let rootPath: String
    }

    public static func pendingSource(for paper: Paper) -> URL? {
        pendingSource(for: paper, in: Paper.support)
    }

    static func pendingSource(for paper: Paper, in support: URL) -> URL? {
        drafts(for: paper, in: support).first?.folder.appendingPathComponent("source", isDirectory: true)
    }

    public static func recompile(
        _ paper: Paper, texPath: String, report: @Sendable (JobProgress) async -> Void
    ) async throws -> Paper {
        try await recompile(paper, texPath: texPath, support: Paper.support, report: report)
    }

    static func recompile(
        _ paper: Paper, texPath: String, support: URL, report: @Sendable (JobProgress) async -> Void
    ) async throws -> Paper {
        guard let saved = drafts(for: paper, in: support).first else {
            throw LensError("找不到这篇论文的待编译译稿。")
        }
        let workspace = support.appendingPathComponent("Jobs/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        await report(JobProgress("检查本机 TeX", "读取已保存的译稿", 0.15))
        let bin = URL(fileURLWithPath: try await LocalTeX.check(texPath), isDirectory: true)
        return try await compile(saved.draft, from: saved.folder, original: paper, support: support,
                                 workspace: workspace, bin: bin, report: report)
    }

    public static func run(
        input: String, settings: TranslationSettings, savedPaper: Paper? = nil,
        originalReady: @Sendable (Paper) async -> Void = { _ in },
        report: @Sendable (JobProgress) async -> Void
    ) async throws -> Paper {
        try await run(input: input, settings: settings, support: Paper.support, savedPaper: savedPaper,
                      originalReady: originalReady, report: report)
    }

    public static func download(
        input: String, originalReady: @Sendable (Paper) async -> Void = { _ in },
        report: @Sendable (JobProgress) async -> Void
    ) async throws -> Paper {
        try await run(input: input, settings: nil, support: Paper.support, originalReady: originalReady, report: report)
    }

    static func run(
        input: String, settings: TranslationSettings?, support: URL, savedPaper: Paper? = nil,
        originalReady: @Sendable (Paper) async -> Void = { _ in },
        report: @Sendable (JobProgress) async -> Void
    ) async throws -> Paper {
        let requested = try ArxivID(input)
        let fm = FileManager.default
        let history = Paper.history(in: support)
        // An explicit version identifies the exact PDF already in the library.
        // For a link without a version, resolve the current version first.
        let pinned = savedPaper.flatMap { paper in
            history.first { $0.id == paper.id && $0.arxivID == requested.value }
        }
        let saved = pinned ?? (requested.isVersioned ? history.first { $0.arxivID == requested.value } : nil)
        await report(JobProgress("连接 arXiv", "识别论文标题与版本", 0.05))
        let metadata = if let saved { (id: requested, title: Optional(saved.title), details: saved.metadata) }
            else { await ArxivDownload.metadata(requested) }
        let arxiv = metadata.id
        try Task.checkCancellation()
        let editions = arxiv.isVersioned || pinned != nil ? history.filter { $0.arxivID == arxiv.value } : []
        let cached = saved ?? editions.first

        let id = UUID()
        let workspace = support.appendingPathComponent("Jobs/\(id.uuidString)", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }

        let originalPaper: Paper
        if let cached {
            originalPaper = cached
        } else {
            let download = workspace.appendingPathComponent("download", isDirectory: true)
            try fm.createDirectory(at: download, withIntermediateDirectories: false)
            let pdf = download.appendingPathComponent("original.pdf")
            await report(JobProgress("下载原版 PDF", metadata.title ?? arxiv.value, 0.13))
            try await ArxivDownload.fetch(arxiv.url("pdf"), to: pdf)
            guard let document = PDFDocument(url: pdf), document.pageCount > 0 else {
                throw LensError("arXiv 返回的文件无法作为 PDF 打开。")
            }
            let pdfTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle = pdfTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "arXiv \(arxiv.value)"
            originalPaper = Paper(id: UUID(), arxivID: arxiv.value, title: metadata.title ?? fallbackTitle,
                                  completedAt: .now, untranslated: 0, downloadOnly: true, metadata: metadata.details)
            try publish(originalPaper, from: download, in: support)
        }
        await originalReady(originalPaper)
        try Task.checkCancellation()

        let storedSource = ([originalPaper] + editions).map { $0.originalSource(in: support) }
            .first { fm.fileExists(atPath: $0.path) }
        let originalSource: URL
        if let storedSource {
            originalSource = storedSource
            await report(JobProgress("复用本机 TeX 源码", arxiv.value, 0.23))
        } else {
            await report(JobProgress("下载 TeX 源码", arxiv.value, 0.2))
            let archive = workspace.appendingPathComponent("arxiv-source")
            let extracted = workspace.appendingPathComponent("original-source", isDirectory: true)
            try await ArxivDownload.fetch(arxiv.url("src"), to: archive)
            try await SourceArchive.extract(archive, to: extracted, workspace: workspace)
            originalSource = originalPaper.originalSource(in: support)
            // Publish only after extraction has completed. Parallel readers see
            // either no source or a complete original source tree.
            do { try fm.moveItem(at: extracted, to: originalSource) }
            catch {
                guard fm.fileExists(atPath: originalSource.path) else { throw error }
            }
        }

        guard let settings else {
            await report(JobProgress("原文与源码已保存", originalPaper.title, 1))
            return originalPaper
        }
        try Task.checkCancellation()

        await report(JobProgress("检查本机 TeX", "确认 XeLaTeX、latexmk 和中文排版组件", 0.25))
        let bin = URL(fileURLWithPath: try await LocalTeX.check(settings.texPath), isDirectory: true)
        let source = workspace.appendingPathComponent("source", isDirectory: true)
        try fm.copyItem(at: originalSource, to: source)
        let project = try TeXProject.read(from: source)
        let title = metadata.title ?? project.title ?? originalPaper.title

        let count = project.drafts.reduce(0) { $0 + $1.units.count }
        guard count > 0 else { throw LensError("没有找到可以翻译的 LaTeX 正文。") }
        let api = TranslationAPI(settings: settings)
        var completed = 0
        var untranslated = 0
        var context = ""
        var cache: [String: TranslationAPI.Excerpt] = [:]
        var readingPairs: [ReadingPair] = []
        let font = NSFont(name: "Songti SC", size: 12) != nil ? "Songti SC" : "Heiti SC"
        for draft in project.drafts {
            var start = 0
            var translations: [String?] = []
            while start < draft.units.count {
                try Task.checkCancellation()
                var end = start
                var budget = 0
                while end < draft.units.count && end - start < 24 {
                    let size = draft.units[end].prompt.utf16.count
                    if end > start && budget + size > 5300 { break }
                    budget += size
                    end += 1
                }
                let units = draft.units[start..<end]
                await report(JobProgress("翻译论文", "\(completed) / \(count) 段 · \(draft.url.lastPathComponent)",
                                         0.28 + 0.57 * Double(completed) / Double(count)))
                var batch = units.map { $0.tokens.isEmpty ? cache[$0.prompt] : nil }
                let missing = zip(units, batch).compactMap { $1 == nil ? $0 : nil }
                if !missing.isEmpty {
                    var replies = try await api.translate(missing[...], title: title, context: context)
                    if replies.contains(where: { $0 == nil }) {
                        // Retry only the affected excerpts. Keep a failed unit in
                        // its original language rather than applying broken TeX.
                        let failed = replies.indices.filter { replies[$0] == nil }
                        for start in stride(from: 0, to: failed.count, by: 3) {
                            let chunk = failed[start..<min(start + 3, failed.count)]
                            let recovered = try await api.translate(chunk.map { missing[$0] }[...],
                                                                    title: title, context: context, retry: true)
                            for (index, value) in zip(chunk, recovered) { replies[index] = value }
                        }
                        for index in failed where replies[index] == nil {
                            replies[index] = try await api.translate([missing[index]][...], title: title,
                                                                     context: "", retry: true).first ?? nil
                        }
                    }
                    var next = 0
                    for i in batch.indices where batch[i] == nil {
                        batch[i] = replies[next]
                        next += 1
                    }
                }
                for (unit, value) in zip(units, batch) {
                    if let value {
                        // Restored output depends on the actual tokens, so only
                        // cache excerpts that do not have placeholders.
                        if unit.tokens.isEmpty { cache[unit.prompt] = value }
                        readingPairs += ReadingPair.sentences(original: unit.prompt, chinese: value.text,
                                                              originalTokens: unit.tokens, chineseTokens: unit.tokens)
                    } else {
                        untranslated += 1
                    }
                }
                let tex = batch.map { $0?.tex }
                translations += tex
                context = String((context + "\n" + tex.compactMap { $0 }.joined(separator: "\n")).suffix(1400))
                completed += units.count
                start = end
            }
            try draft.write(translations, font: font, lineSpacing: settings.lineSpacing)
        }
        guard untranslated < count else { throw LensError("模型未返回可用的中文译文。请检查模型和接口。") }

        let paper = Paper(id: id, arxivID: arxiv.value, title: title, completedAt: .now,
                          untranslated: untranslated, metadata: metadata.details ?? cached?.metadata)
        let sourceRoot = source.resolvingSymlinksInPath().path + "/"
        guard project.root.path.hasPrefix(sourceRoot) else { throw LensError("无法定位译稿中的主 TeX 文件。") }
        let draft = Draft(paper: paper, originalID: originalPaper.id,
                          rootPath: String(project.root.path.dropFirst(sourceRoot.count)))
        let folder = try save(draft, from: source, readingPairs: readingPairs, workspace: workspace, support: support)
        return try await compile(draft, from: folder, original: originalPaper, support: support,
                                 workspace: workspace, bin: bin, report: report)
    }

    private static func draftDirectory(for paper: Paper, in support: URL) -> URL {
        let version = paper.arxivID.lowercased().replacingOccurrences(of: "/", with: "_")
        return support.appendingPathComponent("TranslationDrafts/\(version)", isDirectory: true)
    }

    private static func drafts(for paper: Paper, in support: URL) -> [(draft: Draft, folder: URL)] {
        guard let arxiv = try? ArxivID(paper.arxivID) else { return [] }
        let fm = FileManager.default
        let directories = (try? fm.contentsOfDirectory(at: draftDirectory(for: paper, in: support),
                                                        includingPropertiesForKeys: nil)) ?? []
        return directories.compactMap { folder -> (draft: Draft, folder: URL)? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("draft.json")),
                  let draft = try? JSONDecoder().decode(Draft.self, from: data),
                  draft.paper.id.uuidString == folder.lastPathComponent,
                  draft.paper.arxivID == paper.arxivID,
                  arxiv.isVersioned || draft.originalID == paper.id,
                  !fm.fileExists(atPath: draft.paper.directory(in: support).appendingPathComponent("chinese.pdf").path),
                  fm.fileExists(atPath: folder.appendingPathComponent("source").path) else { return nil }
            return (draft, folder)
        }.sorted { $0.draft.paper.completedAt > $1.draft.paper.completedAt }
    }

    private static func save(_ draft: Draft, from source: URL, readingPairs: [ReadingPair], workspace: URL,
                             support: URL) throws -> URL {
        let fm = FileManager.default
        let staging = workspace.appendingPathComponent("draft", isDirectory: true)
        let parent = draftDirectory(for: draft.paper, in: support)
        let destination = parent.appendingPathComponent(draft.paper.id.uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        try fm.moveItem(at: source, to: staging.appendingPathComponent("source", isDirectory: true))
        try JSONEncoder().encode(draft).write(to: staging.appendingPathComponent("draft.json"), options: .atomic)
        try JSONEncoder().encode(readingPairs).write(to: staging.appendingPathComponent("sentence-pairs.json"), options: .atomic)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.moveItem(at: staging, to: destination)
        return destination
    }

    private static func compile(
        _ draft: Draft, from folder: URL, original: Paper, support: URL, workspace: URL, bin: URL,
        report: @Sendable (JobProgress) async -> Void
    ) async throws -> Paper {
        try Task.checkCancellation()
        let fm = FileManager.default
        let result = workspace.appendingPathComponent("result", isDirectory: true)
        let source = result.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: result, withIntermediateDirectories: true)
        try fm.copyItem(at: folder.appendingPathComponent("source", isDirectory: true), to: source)
        let root = source.appendingPathComponent(draft.rootPath).resolvingSymlinksInPath()
        guard root.path.hasPrefix(source.resolvingSymlinksInPath().path + "/"), fm.fileExists(atPath: root.path) else {
            throw LensError("找不到译稿中的主 TeX 文件 \(draft.rootPath)。")
        }
        try fm.copyItem(at: original.directory(in: support).appendingPathComponent("original.pdf"),
                        to: result.appendingPathComponent("original.pdf"))
        await report(JobProgress("本机编译中文版", "保留论文模板、图表、公式和交叉引用", 0.88))
        let log = result.appendingPathComponent("compile.log")
        let compiled: URL
        let translatedPDF: PDFDocument
        do {
            compiled = try await LocalTeX.compile(root: root, workspace: workspace, bin: bin, log: log)
            guard let document = PDFDocument(url: compiled), document.pageCount > 0 else {
                throw LensError("XeLaTeX 没有生成可读的 PDF。")
            }
            translatedPDF = document
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let logs = support.appendingPathComponent("CompileLogs", isDirectory: true)
            let failure = logs.appendingPathComponent(workspace.lastPathComponent + ".log")
            try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
            try? fm.moveItem(at: log, to: failure)
            throw CompileFailure(message: error.localizedDescription,
                                 logURL: fm.fileExists(atPath: failure.path) ? failure : nil)
        }
        try fm.copyItem(at: compiled, to: result.appendingPathComponent("chinese.pdf"))
        if let originalPDF = PDFDocument(url: result.appendingPathComponent("original.pdf")),
           let data = try? Data(contentsOf: folder.appendingPathComponent("sentence-pairs.json")),
           let pairs = try? JSONDecoder().decode([ReadingPair].self, from: data) {
            await report(JobProgress("建立双语对照索引", draft.paper.title, 0.96))
            let index = try PDFTextAlignment.build(pairs, original: originalPDF, chinese: translatedPDF)
            if !index.entries.isEmpty {
                // Reading aids are optional. Keep a usable PDF if writing the
                // index fails, just as with editions from earlier releases.
                try? JSONEncoder().encode(index).write(to: result.appendingPathComponent("alignment.json"), options: .atomic)
            }
        }
        let paper = Paper(id: draft.paper.id, arxivID: draft.paper.arxivID, title: draft.paper.title, completedAt: .now,
                          untranslated: draft.paper.untranslated, metadata: draft.paper.metadata)
        try Task.checkCancellation()
        try publish(paper, from: result, in: support)
        for previous in drafts(for: original, in: support) where previous.draft.paper.completedAt <= draft.paper.completedAt {
            try? fm.removeItem(at: previous.folder)
        }
        try? fm.removeItem(at: folder)
        await report(JobProgress("已加入文献库", paper.title, 1))
        return paper
    }

    private static func publish(_ paper: Paper, from result: URL, in support: URL) throws {
        try JSONEncoder().encode(paper).write(to: result.appendingPathComponent("paper.json"), options: .atomic)
        try FileManager.default.createDirectory(at: Paper.library(in: support), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: result, to: paper.directory(in: support))
    }
}

private final class ArxivRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        completionHandler(url?.scheme == "https" && ["arxiv.org", "www.arxiv.org", "export.arxiv.org"]
            .contains(url?.host ?? "") ? request : nil)
    }
}

enum ArxivDownload {
    private static let session = URLSession(configuration: .ephemeral, delegate: ArxivRedirects(), delegateQueue: nil)

    static func metadata(_ requested: ArxivID, reload: Bool = false) async -> (id: ArxivID, title: String?, details: PaperMetadata?) {
        let request = URLRequest(url: requested.abstractURL,
                                 cachePolicy: reload ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy,
                                 timeoutInterval: 15)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return (requested, nil, nil) }
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        let details = bibliographicDetails(html)
        let title = details.title
        if requested.isVersioned { return (requested, title, details.metadata) }
        let regex = try! NSRegularExpression(pattern: #"/abs/"# + NSRegularExpression.escapedPattern(for: requested.value) + #"v([0-9]+)(?=["'?#<\s])"#)
        let versions = regex.matches(in: html, range: range)
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) }
        let version = versions.max().flatMap { try? ArxivID("\(requested.value)v\($0)") }
        return (version ?? requested, title, details.metadata)
    }

    static func bibliographicDetails(_ html: String) -> (title: String?, metadata: PaperMetadata?) {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        let citation = try! NSRegularExpression(pattern: #"(?i)<meta\s+name=["']citation_([a-z_]+)["']\s+content="([^"]*)""#)
        let fields = Dictionary(grouping: citation.matches(in: html, range: range), by: {
            ns.substring(with: $0.range(at: 1)).lowercased()
        }).mapValues { $0.map { decodeEntities(ns.substring(with: $0.range(at: 2))) }.filter { !$0.isEmpty } }
        func tableCell(_ name: String) -> String? {
            let pattern = #"(?is)<td\b[^>]*class=["'][^"']*\b"# + name + #"\b[^"']*["'][^>]*>(.*?)</td>"#
            guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: html, range: range) else {
                return nil
            }
            let value = decodeEntities(ns.substring(with: match.range(at: 1))
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
            return value.isEmpty ? nil : value
        }
        let abstract = fields["abstract"]?.first
        let authors = fields["author"] ?? []
        let date = fields["date"]?.first
        let publication = tableCell("jref") ?? fields["journal_title"]?.first ?? fields["conference_title"]?.first
        let comments = tableCell("comments")
        let doi = fields["doi"]?.first
        let metadata = abstract != nil || !authors.isEmpty || date != nil || publication != nil || comments != nil || doi != nil
            ? PaperMetadata(abstract: abstract, authors: authors, arxivDate: date, publication: publication,
                            comments: comments, doi: doi)
            : nil
        return (fields["title"]?.first, metadata)
    }

    static func fetch(_ url: URL, to destination: URL) async throws {
        let request = URLRequest(url: url, timeoutInterval: 120)
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if url.path.hasPrefix("/src/") {
                throw LensError("arXiv TeX 源码下载失败（HTTP \(status)）。请确认该版本提供源码。")
            }
            throw LensError("arXiv PDF 下载失败（HTTP \(status)）。请确认论文版本可访问。")
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 256 * 1024 * 1024 else { throw LensError("arXiv 文件为空或超过 256 MB。") }
        try FileManager.default.moveItem(at: file, to: destination)
    }

    private static func decodeEntities(_ html: String) -> String {
        let basic = html.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
        let result = NSMutableString(string: basic)
        let regex = try! NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#)
        for match in regex.matches(in: basic, range: NSRange(location: 0, length: result.length)).reversed() {
            let raw = result.substring(with: match.range(at: 1))
            let value = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
            if let scalar = value.flatMap(UnicodeScalar.init) {
                result.replaceCharacters(in: match.range, with: String(scalar))
            }
        }
        return (result as String).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
