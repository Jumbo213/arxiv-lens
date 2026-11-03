import AppKit
import Foundation
import PDFKit

public enum PaperPipeline {
    public static func run(
        input: String, settings: TranslationSettings, report: @Sendable (JobProgress) async -> Void
    ) async throws -> Paper {
        try await run(input: input, settings: settings, support: Paper.support, report: report)
    }

    static func run(
        input: String, settings: TranslationSettings, support: URL, report: @Sendable (JobProgress) async -> Void
    ) async throws -> Paper {
        let requested = try ArxivID(input)
        await report(JobProgress("检查本机 TeX", "确认 XeLaTeX、latexmk 和中文排版组件", 0.03))
        let bin = URL(fileURLWithPath: try await LocalTeX.check(settings.texPath), isDirectory: true)
        let fm = FileManager.default
        let id = UUID()
        let jobs = support.appendingPathComponent("Jobs", isDirectory: true)
        let workspace = jobs.appendingPathComponent(id.uuidString, isDirectory: true)
        let result = workspace.appendingPathComponent("result", isDirectory: true)
        let archive = workspace.appendingPathComponent("arxiv-source")
        let source = result.appendingPathComponent("source", isDirectory: true)
        let original = result.appendingPathComponent("original.pdf")
        try fm.createDirectory(at: result, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }

        await report(JobProgress("连接 arXiv", "识别论文标题与版本", 0.08))
        let metadata = await ArxivDownload.metadata(requested)
        let arxiv = metadata.id
        try Task.checkCancellation()
        await report(JobProgress("下载 TeX 源码", arxiv.value, 0.13))
        try await ArxivDownload.fetch(arxiv.url("src"), to: archive)
        try await SourceArchive.extract(archive, to: source, workspace: workspace)
        let project = try TeXProject.read(from: source)
        await report(JobProgress("下载原版 PDF", metadata.title ?? project.title ?? arxiv.value, 0.23))
        try await ArxivDownload.fetch(arxiv.url("pdf"), to: original)
        guard let originalPDF = PDFDocument(url: original), originalPDF.pageCount > 0 else {
            throw LensError("arXiv 返回的文件无法作为 PDF 打开。")
        }
        let pdfTitle = (originalPDF.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = metadata.title ?? project.title ?? pdfTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "arXiv \(arxiv.value)"

        let count = project.drafts.reduce(0) { $0 + $1.units.count }
        guard count > 0 else { throw LensError("没有找到可以翻译的 LaTeX 正文。") }
        let api = TranslationAPI(settings: settings)
        var completed = 0
        var untranslated = 0
        var context = ""
        var cache: [String: String] = [:]
        for draft in project.drafts {
            var start = 0
            var translations: [String?] = []
            while start < draft.units.count {
                try Task.checkCancellation()
                var end = start
                var budget = 0
                while end < draft.units.count && end - start < 12 {
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
                    if replies.contains(nil) {
                        // Retry only the affected excerpts. Keep a failed unit in
                        // its original language rather than applying broken TeX.
                        let failed = replies.indices.filter { replies[$0] == nil }
                        for start in stride(from: 0, to: failed.count, by: 3) {
                            let chunk = failed[start..<min(start + 3, failed.count)]
                            let recovered = try await api.translate(chunk.map { missing[$0] }[...],
                                                                    title: title, context: context, retry: true)
                            for (index, value) in zip(chunk, recovered) { replies[index] = value }
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
                    } else {
                        untranslated += 1
                    }
                }
                translations += batch
                context = String((context + "\n" + batch.compactMap { $0 }.joined(separator: "\n")).suffix(1400))
                completed += units.count
                start = end
            }
            let font = NSFont(name: "Songti SC", size: 12) != nil ? "Songti SC" : "Heiti SC"
            try draft.write(translations, font: font)
        }
        guard untranslated < count else { throw LensError("模型未返回可用的中文译文。请检查模型和接口。") }

        await report(JobProgress("本机编译中文版", "保留论文模板、图表、公式和交叉引用", 0.88))
        let log = result.appendingPathComponent("compile.log")
        let compiled: URL
        do {
            compiled = try await LocalTeX.compile(root: project.root, workspace: workspace, bin: bin, log: log)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Keep the last failure log after the temporary job directory goes away.
            let failure = support.appendingPathComponent("LastCompile.log")
            try? fm.removeItem(at: failure)
            try? fm.copyItem(at: log, to: failure)
            throw error
        }
        guard let translatedPDF = PDFDocument(url: compiled), translatedPDF.pageCount > 0 else {
            throw LensError("XeLaTeX 没有生成可读的 PDF。")
        }
        try fm.copyItem(at: compiled, to: result.appendingPathComponent("chinese.pdf"))
        let paper = Paper(id: id, arxivID: arxiv.value, title: title, completedAt: .now, untranslated: untranslated)
        try JSONEncoder().encode(paper).write(to: result.appendingPathComponent("paper.json"), options: .atomic)
        let library = support.appendingPathComponent("Papers", isDirectory: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        try Task.checkCancellation()
        try fm.moveItem(at: result, to: library.appendingPathComponent(id.uuidString, isDirectory: true))
        await report(JobProgress("已加入文献库", title, 1))
        return paper
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

    static func metadata(_ requested: ArxivID) async -> (id: ArxivID, title: String?) {
        let request = URLRequest(url: requested.abstractURL, timeoutInterval: 15)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return (requested, nil) }
        let pattern = #"(?i)<meta\s+name=["']citation_title["']\s+content="([^"]+)""#
        let title = html.range(of: pattern, options: .regularExpression).flatMap { range -> String? in
            let tag = html[range]
            guard let prefix = tag.range(of: #"content=""#) else { return nil }
            return decodeEntities(String(tag[prefix.upperBound...].dropLast()))
        }
        if requested.value.range(of: #"v[0-9]+$"#, options: .regularExpression) != nil { return (requested, title) }
        let regex = try! NSRegularExpression(pattern: #"/abs/"# + NSRegularExpression.escapedPattern(for: requested.value) + #"v([0-9]+)(?=["'?#<\s])"#)
        let ns = html as NSString
        let versions = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) }
        let version = versions.max().flatMap { try? ArxivID("\(requested.value)v\($0)") }
        return (version ?? requested, title)
    }

    static func fetch(_ url: URL, to destination: URL) async throws {
        let request = URLRequest(url: url, timeoutInterval: 120)
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let label = url.path.hasPrefix("/src/") ? "TeX 源码" : "PDF"
            throw LensError("arXiv \(label)下载失败（HTTP \(status)）。请确认论文版本可访问并提供源码。")
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
