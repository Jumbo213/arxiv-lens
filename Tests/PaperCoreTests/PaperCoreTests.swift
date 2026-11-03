import Foundation
import PDFKit

@main
struct PaperCoreTests {
    static func main() async {
        let tests = Self()
        do {
            try tests.testArxivLinkAndEndpointNormalization()
            try tests.testProtectedTokensRejectReorderAndEscapeProse()
            try tests.testRewriteMultifilePaper()
            try await tests.testLiveArxivThroughMockTranslationAndXeLaTeX()
            print("All smoke tests passed.")
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    func testArxivLinkAndEndpointNormalization() throws {
        expectEqual(try ArxivID("https://arxiv.org/pdf/hep-th/9901001v2.pdf?x=1").value, "hep-th/9901001v2")
        expectEqual(try ArxivID(" arXiv:1706.03762v7 ").value, "1706.03762v7")
        expectThrowsError(try ArxivID("https://arxiv.org.evil.example/abs/1706.03762"))
        expectThrowsError(try ArxivID("https://arxiv.org/abs/../1706.03762"))
        expectEqual(try TranslationSettings(url: "https://example.com", model: "model", key: "token").endpoint.path,
                       "/v1/chat/completions")
        expectEqual(try TranslationSettings(url: "https://example.com/proxy/v1/chat/completions", model: "m", key: "k").endpoint.path,
                       "/proxy/v1/chat/completions")
        expectThrowsError(try TranslationSettings(url: "http://example.com/v1", model: "m", key: "k"))
    }

    func testProtectedTokensRejectReorderAndEscapeProse() throws {
        let unit = TranslationUnit(range: NSRange(location: 0, length: 2),
                                   prompt: "See ZXQ0000QXZ and ZXQ0001QXZ.", tokens: [#"$x_i$"#, #"\cite{x}"#])
        expectNil(unit.restore("参见 ZXQ0001QXZ 与 ZXQ0000QXZ。"))
        expectNil(unit.restore("参见 ZXQ0000QXZ。"))
        expectNil(unit.restore("See ZXQ0000QXZ and ZXQ0001QXZ."))
        expectEqual(unit.restore("参见 ZXQ0000QXZ 与 ZXQ0001QXZ，%和&。"), #"参见 $x_i$ 与 \cite{x}，\%和\&。"#)
    }

    func testRewriteMultifilePaper() throws {
        let folder = try temp()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("main.tex")
        let body = folder.appendingPathComponent("body.tex")
        try #"""
        % \documentclass{wrong}
        \documentclass{article}
        \title{Important Results}
        \author{Alice Author}
        \begin{document}
        \maketitle
        \section[Short Title]{Full Title}
        \input{body}
        \begin{thebibliography}{9}
        \bibitem{x} Example Work.
        \end{thebibliography}
        \end{document}
        """#.write(to: root, atomically: true, encoding: .utf8)
        try #"""
        The output \(x_i\) and \textbf{confidence level} reached 94.5\% \cite{x}.
        \begin{equation}x = y \label{eq:a}\end{equation}
        \begin{figure}
        \includegraphics[width=0.5\textwidth]{chart}
        \caption{Details for \ref{eq:a}.}
        \end{figure}
        """#.write(to: body, atomically: true, encoding: .utf8)
        let project = try TeXProject.read(from: folder)
        expectEqual(project.root.path, root.resolvingSymlinksInPath().path)
        expectEqual(project.title, "Important Results")
        expectEqual(project.drafts.count, 2)
        expectEqual(project.drafts[0].units.map(\.prompt), ["Important Results", "Short Title", "Full Title"])
        let units = project.drafts[1].units
        expectEqual(units.count, 2)
        expectTrue(units[0].tokens.joined().contains(#"\(x_i\)"#))
        expectTrue(units[0].tokens.joined().contains("94.5"))
        for draft in project.drafts {
            let translated = draft.units.map { $0.restore("示例 " + $0.prompt) }
            try draft.write(translated, font: "Songti SC")
        }
        let output = try String(contentsOf: root, encoding: .utf8)
        expectTrue(output.contains(#"\title{示例 Important Results}"#))
        expectTrue(output.contains(#"\author{Alice Author}"#))
        expectTrue(output.contains(#"\bibitem{x} Example Work."#))
        expectTrue(output.contains(#"\usepackage{xeCJK}"#))
        let translated = try String(contentsOf: body, encoding: .utf8)
        expectTrue(translated.contains(#"\includegraphics[width=0.5\textwidth]{chart}"#))
        expectTrue(translated.contains(#"\begin{equation}x = y \label{eq:a}\end{equation}"#))
    }

    func testLiveArxivThroughMockTranslationAndXeLaTeX() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mock = environment["ARXIV_LENS_TEST_ENDPOINT"] else {
            print("Set ARXIV_LENS_TEST_ENDPOINT to also test real arXiv downloads and local TeX.")
            return
        }
        let settings = try TranslationSettings(url: mock, model: "mock", key: "")
        let support = try temp()
        defer { try? FileManager.default.removeItem(at: support) }
        let ids = environment["ARXIV_LENS_TEST_PAPERS"]?.split(separator: ",").map(String.init) ?? ["1706.03762"]
        for id in ids {
            let paper = try await PaperPipeline.run(input: id, settings: settings, support: support) { progress in
                print("\(progress.title) \(progress.detail)")
            }
            let folder = support.appendingPathComponent("Papers/\(paper.id.uuidString)")
            let original = try unwrap(PDFDocument(url: folder.appendingPathComponent("original.pdf")))
            let chinese = try unwrap(PDFDocument(url: folder.appendingPathComponent("chinese.pdf")))
            expectGreaterThan(original.pageCount, 0)
            expectGreaterThan(chinese.pageCount, 0)
            expectTrue(chinese.string?.contains("译文") == true)
            expectEqual(paper.untranslated, 0)
            let persisted = try JSONDecoder().decode(Paper.self, from: Data(contentsOf: folder.appendingPathComponent("paper.json")))
            expectEqual(persisted, paper)
            print("VERIFIED \(paper.arxivID) \(paper.title) · pages \(original.pageCount) → \(chinese.pageCount)")
            if let output = environment["ARXIV_LENS_TEST_COPY_TO"] {
                let destination = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: folder, to: destination.appendingPathComponent(paper.id.uuidString))
            }
        }
    }

    private func temp() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                                       file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}

private func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, "Expected nil, got \(String(describing: value))", file: file, line: line)
}

private func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "Expected true", file: file, line: line)
}

private func expectGreaterThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    precondition(a > b, "Expected \(a) > \(b)", file: file, line: line)
}

private func expectThrowsError<T>(_ work: @autoclosure () throws -> T,
                                  file: StaticString = #file, line: UInt = #line) {
    do {
        _ = try work()
    } catch {
        return
    }
    preconditionFailure("Expected an error", file: file, line: line)
}

private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw LensError("Missing test value.") }
    return value
}
