import Foundation

public struct LensError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ArxivID: Hashable, Sendable {
    public let value: String

    public init(_ input: String) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var id = input
        if input.contains("://"), let url = URL(string: input), url.scheme != nil {
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  ["arxiv.org", "www.arxiv.org", "export.arxiv.org"].contains(url.host?.lowercased() ?? "") else {
                throw LensError("请输入 arXiv.org 的论文链接或 arXiv 编号。")
            }
            let parts = url.path.split(separator: "/")
            guard let kind = parts.first, ["abs", "pdf", "src", "e-print", "html"].contains(kind) else {
                throw LensError("无法从这个 arXiv 链接识别论文编号。")
            }
            id = parts.dropFirst().joined(separator: "/")
        }
        if id.hasPrefix("arXiv:") { id.removeFirst(6) }
        if id.hasSuffix(".pdf") { id.removeLast(4) }
        let pattern = #"\A(?:[0-9]{4}\.[0-9]{4,5}|[a-zA-Z][a-zA-Z.-]*/[0-9]{7})(?:v[1-9][0-9]*)?\z"#
        guard id.range(of: pattern, options: .regularExpression) != nil else {
            throw LensError("无法识别论文编号。示例：1706.03762v7 或 hep-th/9901001。")
        }
        value = id
    }

    public var paperID: String {
        value.replacingOccurrences(of: #"v[0-9]+$"#, with: "", options: .regularExpression).lowercased()
    }

    var isVersioned: Bool { value.range(of: #"v[0-9]+$"#, options: .regularExpression) != nil }

    public var abstractURL: URL { url("abs") }
    func url(_ type: String) -> URL { URL(string: "https://arxiv.org/\(type)/\(value)")! }
}

public struct Paper: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let arxivID: String
    public let title: String
    public let completedAt: Date
    public let untranslated: Int
    private let downloadOnly: Bool?
    public var hasTranslation: Bool { downloadOnly != true }

    init(id: UUID, arxivID: String, title: String, completedAt: Date, untranslated: Int, downloadOnly: Bool? = nil) {
        self.id = id
        self.arxivID = arxivID
        self.title = title
        self.completedAt = completedAt
        self.untranslated = untranslated
        self.downloadOnly = downloadOnly
    }

    public var paperID: String { (try? ArxivID(arxivID).paperID) ?? arxivID }
    public var originalURL: URL { directory.appendingPathComponent("original.pdf") }
    public var translationURL: URL { directory.appendingPathComponent("chinese.pdf") }
    public var sourceURL: URL { directory.appendingPathComponent("source", isDirectory: true) }
    public var directory: URL { directory(in: Self.support) }

    func directory(in support: URL) -> URL {
        Self.library(in: support).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArxivLens", isDirectory: true)
    }
    public static var library: URL { library(in: support) }

    static func library(in support: URL) -> URL { support.appendingPathComponent("Papers", isDirectory: true) }

    public struct HistoryEntry: Identifiable, Sendable {
        public let id: String
        public let translations: [Paper]
        public var latest: Paper { translations[0] }
    }

    public static func groupedHistory(_ papers: [Paper]) -> [HistoryEntry] {
        let grouped = Dictionary(grouping: papers, by: \.paperID)
        return grouped.map { id, entries in
            HistoryEntry(id: id, translations: entries.sorted { $0.completedAt > $1.completedAt })
        }.sorted {
            if $0.latest.completedAt == $1.latest.completedAt { return $0.id < $1.id }
            return $0.latest.completedAt > $1.latest.completedAt
        }
    }

    public static func history() -> [Paper] { history(in: support) }

    static func history(in support: URL) -> [Paper] {
        let fm = FileManager.default
        let directories = (try? fm.contentsOfDirectory(at: library(in: support), includingPropertiesForKeys: nil)) ?? []
        return directories.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("paper.json")),
                  let paper = try? JSONDecoder().decode(Self.self, from: data),
                  paper.id.uuidString == dir.lastPathComponent,
                  fm.fileExists(atPath: dir.appendingPathComponent("original.pdf").path),
                  !paper.hasTranslation || fm.fileExists(atPath: dir.appendingPathComponent("chinese.pdf").path) else { return nil }
            return paper
        }.sorted { $0.completedAt > $1.completedAt }
    }
}

public struct JobProgress: Sendable {
    public let title: String
    public let detail: String
    public let fraction: Double
    public init(title: String, detail: String, fraction: Double) {
        self.title = title
        self.detail = detail
        self.fraction = fraction
    }

    init(_ title: String, _ detail: String, _ fraction: Double) {
        self.title = title
        self.detail = detail
        self.fraction = fraction
    }
}
