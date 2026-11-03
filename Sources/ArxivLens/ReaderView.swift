import AppKit
import PaperCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private enum Side {
    case original, chinese
    var name: String { self == .original ? "英文原版" : "中文译文" }
}

private enum ReadingMode: String, CaseIterable {
    case compare = "对照阅读"
    case original = "英文原版"
    case chinese = "中文译文"
}

private final class ReaderState: ObservableObject {
    let original: PDFDocument?
    let chinese: PDFDocument?
    @Published var mode: ReadingMode = .compare
    @Published var sync = true
    @Published var originalPage = 0
    @Published var chinesePage = 0
    private var anchors: [(Int, Int)] = []

    init(_ paper: Paper) {
        original = PDFDocument(url: paper.originalURL)
        chinese = PDFDocument(url: paper.translationURL)
        if let original, let chinese, let left = original.outlineRoot, let right = chinese.outlineRoot {
            let leftPages = Self.outlinePages(left, document: original)
            let rightPages = Self.outlinePages(right, document: chinese)
            if leftPages.count == rightPages.count && leftPages.map(\.0) == rightPages.map(\.0) {
                for ((_, a), (_, b)) in zip(leftPages, rightPages) {
                    if let last = anchors.last, (a <= last.0 || b <= last.1) { continue }
                    if a > 0 && b > 0 && a < original.pageCount - 1 && b < chinese.pageCount - 1 {
                        anchors.append((a, b))
                    }
                }
            }
        }
    }

    private static func outlinePages(_ outline: PDFOutline, document: PDFDocument,
                                     level: Int = 0) -> [(Int, Int)] {
        guard level < 3 else { return [] }
        return (0..<outline.numberOfChildren).flatMap { index -> [(Int, Int)] in
            guard let child = outline.child(at: index) else { return [] }
            let branch = outlinePages(child, document: document, level: level + 1)
            if let page = child.destination?.page {
                let number = document.index(for: page)
                if number < document.pageCount { return [(level, number)] + branch }
            }
            return branch
        }
    }

    func document(_ side: Side) -> PDFDocument? { side == .original ? original : chinese }
    func page(_ side: Side) -> Int { side == .original ? originalPage : chinesePage }

    func show(_ index: Int, on side: Side) {
        guard let doc = document(side), (0..<doc.pageCount).contains(index), index != page(side) else { return }
        if side == .original { originalPage = index } else { chinesePage = index }
        if mode == .compare && sync { align(from: side) }
    }

    func align(from side: Side = .original) {
        let other: Side = side == .original ? .chinese : .original
        guard let source = document(side), let target = document(other), source.pageCount > 0, target.pageCount > 0 else { return }
        let index = page(side)
        let end = (source.pageCount - 1, target.pageCount - 1)
        var points = [(0, 0)] + anchors.map { side == .original ? $0 : ($0.1, $0.0) }
        points.append(end)
        let upper = points.firstIndex(where: { $0.0 >= index }) ?? points.count - 1
        let a = points[max(upper - 1, 0)], b = points[upper]
        let fraction = Double(index - a.0) / Double(max(1, b.0 - a.0))
        let aligned = min(target.pageCount - 1, a.1 + Int((fraction * Double(b.1 - a.1)).rounded()))
        if side == .original { chinesePage = aligned } else { originalPage = aligned }
    }
}

struct ReaderView: View {
    let paper: Paper
    @StateObject private var reader: ReaderState
    @ViewState private var zoom: CGFloat = 1
    @ViewState private var exportError: String?

    init(paper: Paper) {
        self.paper = paper
        _reader = StateObject(wrappedValue: ReaderState(paper))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if reader.mode == .compare {
                HStack(spacing: 1) {
                    pane(.original)
                    pane(.chinese)
                }
                .background(Palette.line)
            } else {
                pane(reader.mode == .original ? .original : .chinese)
            }
        }
        .onChange(of: reader.sync) { enabled in if enabled { reader.align() } }
        .onChange(of: reader.mode) { mode in if mode == .compare && reader.sync { reader.align() } }
        .alert("无法导出 PDF", isPresented: Binding(get: { exportError != nil },
                                                 set: { if !$0 { exportError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("ARXIV \(paper.arxivID)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.2).foregroundStyle(Palette.teal)
                Circle().fill(Palette.line).frame(width: 4, height: 4)
                Text(paper.completedAt, format: .dateTime.year().month().day())
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Menu {
                    Button("导出英文 PDF…") { export(.original) }
                    Button("导出中文 PDF…") { export(.chinese) }
                    Divider()
                    Button("在访达中显示译后 TeX") {
                        NSWorkspace.shared.open(paper.sourceURL)
                    }
                    if let id = try? ArxivID(paper.arxivID) {
                        Button("在 arXiv 打开") { NSWorkspace.shared.open(id.abstractURL) }
                    }
                } label: {
                    Label("文件", systemImage: "square.and.arrow.up")
                }.fixedSize()
            }
            Text(paper.title)
                .font(.system(size: 24, weight: .semibold, design: .serif))
                .lineLimit(2)
                .help(paper.title)
            HStack(spacing: 12) {
                Picker("阅读模式", selection: $reader.mode) {
                    ForEach(ReadingMode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 275)
                if reader.mode == .compare {
                    Toggle("联动翻页", isOn: $reader.sync)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .help("优先根据 PDF 书签匹配章节，缺少对应书签时按页数比例定位。")
                }
                Spacer()
                Button { zoom = max(0.75, zoom - 0.25) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("缩小").accessibilityLabel("缩小")
                Button("适宽") { zoom = 1 }.help("恢复适合窗口宽度")
                Button { zoom = min(3, zoom + 0.25) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("放大").accessibilityLabel("放大")
            }
            .padding(.top, 3)
            if paper.untranslated > 0 {
                Label("\(paper.untranslated) 段保留原文。模型的译文未通过结构校验。", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .background(Palette.paper)
    }

    private func pane(_ side: Side) -> some View {
        VStack(spacing: 0) {
            let page = reader.page(side)
            let count = reader.document(side)?.pageCount ?? 0
            HStack(spacing: 8) {
                Circle().fill(side == .chinese ? Palette.teal : Palette.muted).frame(width: 6, height: 6)
                Text(side.name).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button { reader.show(page - 1, on: side) } label: { Image(systemName: "chevron.left") }
                    .disabled(page == 0).accessibilityLabel("上一页")
                Text("\(count > 0 ? page + 1 : 0) / \(count)")
                    .monospacedDigit().foregroundStyle(Palette.muted)
                Button { reader.show(page + 1, on: side) } label: { Image(systemName: "chevron.right") }
                    .disabled(page + 1 >= count).accessibilityLabel("下一页")
            }
            .font(.system(size: 11))
            .buttonStyle(.borderless)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(Color(red: 0.92, green: 0.94, blue: 0.91))
            if let document = reader.document(side) {
                PDFCanvas(document: document, page: page, zoom: zoom) {
                    reader.show($0, on: side)
                }
            } else {
                Text("本机 PDF 文件无法打开")
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func export(_ side: Side) {
        let url = side == .original ? paper.originalURL : paper.translationURL
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let name = String(paper.title.prefix(100)).replacingOccurrences(of: "/", with: " ")
        panel.nameFieldStringValue = "\(name) - \(side.name).pdf"
        if panel.runModal() == .OK, let destination = panel.url {
            do { try Data(contentsOf: url).write(to: destination, options: .atomic) }
            catch { exportError = error.localizedDescription }
        }
    }
}

private struct PDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    let page: Int
    let zoom: CGFloat
    let moved: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor(red: 0.87, green: 0.89, blue: 0.87, alpha: 1)
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 8, left: 9, bottom: 8, right: 9)
        view.document = document
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: ReaderPDFView, context: Context) {
        context.coordinator.moved = moved
        if view.document !== document { view.document = document }
        view.zoom = zoom
        view.needsLayout = true
        if let destination = document.page(at: page), view.currentPage !== destination { view.go(to: destination) }
    }

    final class Coordinator {
        var moved: ((Int) -> Void)?
        private var observer: NSObjectProtocol?

        func observe(_ view: PDFView) {
            observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) {
                [weak self, weak view] _ in
                DispatchQueue.main.async {
                    guard let view, let document = view.document, let page = view.currentPage else { return }
                    self?.moved?(document.index(for: page))
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

private final class ReaderPDFView: PDFView {
    var zoom: CGFloat = 1
    private var lastWidth: CGFloat = 0
    private var lastZoom: CGFloat = 0

    override func layout() {
        super.layout()
        guard bounds.width > 10, abs(lastWidth - bounds.width) > 1 || lastZoom != zoom,
              let page = document?.page(at: 0) else { return }
        lastWidth = bounds.width
        lastZoom = zoom
        let pageBounds = page.bounds(for: displayBox)
        let width = page.rotation % 180 == 0 ? pageBounds.width : pageBounds.height
        guard width > 0 else { return }
        let fitted = (bounds.width - 32) / width
        minScaleFactor = min(fitted * 0.5, 0.5)
        maxScaleFactor = max(fitted * 4, 4)
        scaleFactor = fitted * zoom
    }
}
