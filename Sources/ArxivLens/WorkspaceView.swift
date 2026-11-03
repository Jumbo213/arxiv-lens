import AppKit
import PaperCore
import SwiftUI

enum Palette {
    static let ink = Color(red: 0.105, green: 0.157, blue: 0.192)
    static let muted = Color(red: 0.325, green: 0.376, blue: 0.397)
    static let paper = Color(red: 0.973, green: 0.970, blue: 0.946)
    static let line = Color(red: 0.87, green: 0.88, blue: 0.84)
    static let teal = Color(red: 0.066, green: 0.376, blue: 0.333)
    static let mint = Color(red: 0.64, green: 0.90, blue: 0.77)
    static let sidebar = Color(red: 0.078, green: 0.145, blue: 0.164)
    static let soft = Color(red: 0.66, green: 0.74, blue: 0.74)
}

struct WorkspaceView: View {
    @ObservedObject var store: LibraryStore
    @AppStorage("compactReader") private var compactReader = true
    @ViewState private var search = ""
    @FocusState private var linkFocused: Bool

    private var filtered: [Paper] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return store.papers }
        return store.papers.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.arxivID.contains(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 254)
            VStack(spacing: 0) {
                if store.selected == nil || !compactReader {
                    toolbar
                    Rectangle().fill(Palette.line).frame(height: 1)
                }
                if let job = store.job { progress(job) }
                if let paper = store.selected {
                    ReaderView(paper: paper, compact: $compactReader).id(paper.id)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.paper)
        }
        .background(Palette.sidebar)
        .ignoresSafeArea(.container, edges: .top)
        .tint(Palette.teal)
        .foregroundStyle(Palette.ink)
        .sheet(isPresented: $store.settingsOpen) { SettingsView() }
        .sheet(item: Binding(
            get: { store.failure.map(Failure.init) },
            set: { if $0 == nil { store.failure = nil } }
        )) { issue in
            ErrorSheet(message: issue.message)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Palette.mint).frame(width: 38, height: 38)
                    Image(systemName: "book.pages").font(.system(size: 19, weight: .medium)).foregroundStyle(Palette.sidebar)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Arxiv Lens").font(.system(size: 21, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                    Text("论文翻译与阅读").font(.system(size: 11)).foregroundStyle(Palette.soft)
                }
            }
            .padding(.top, 48)
            .padding(.bottom, 28)
            .padding(.horizontal, 20)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                ZStack(alignment: .leading) {
                    if search.isEmpty {
                        Text("搜索标题或编号").foregroundStyle(Palette.soft).allowsHitTesting(false)
                    }
                    TextField("", text: $search)
                        .textFieldStyle(.plain).foregroundStyle(.white)
                        .accessibilityLabel("搜索标题或编号")
                }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.soft)
            .padding(9)
            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 15)

            HStack {
                Text("翻译历史").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(store.papers.count)").font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(0.09), in: Capsule())
            }
            .foregroundStyle(Palette.soft)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 9)

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(filtered) { paper in
                        let active = paper == store.selected
                        Button { store.selected = paper } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: "doc.text").font(.system(size: 12))
                                    .foregroundStyle(active ? Palette.mint : Palette.soft).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(paper.title).lineLimit(3)
                                        .font(.system(size: 12, weight: active ? .semibold : .medium))
                                        .foregroundStyle(.white)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(paper.arxivID)
                                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.soft)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(active ? Palette.teal.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(paper.title)
                    }
                    if filtered.isEmpty {
                        Text(search.isEmpty ? "译完的论文会按标题显示在这里" : "没有匹配的论文")
                            .font(.system(size: 11)).foregroundStyle(Palette.soft)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                    }
                }.padding(.horizontal, 12)
            }

            Button { store.settingsOpen = true } label: {
                Label("翻译与 TeX 设置", systemImage: "gearshape")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.soft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        .background(
            LinearGradient(colors: [Palette.sidebar, Color(red: 0.074, green: 0.205, blue: 0.213)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "link").foregroundStyle(Palette.teal)
                TextField("粘贴 arXiv 链接或论文编号", text: $store.input)
                    .textFieldStyle(.plain)
                    .focused($linkFocused)
                    .onSubmit { store.start() }
            }
            .font(.system(size: 13))
            .padding(11)
            .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(linkFocused ? Palette.teal.opacity(0.6) : Palette.line))
            Button { store.start() } label: {
                Label("开始翻译", systemImage: "sparkle")
            }
            .buttonStyle(PrimaryButton())
            .disabled(store.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.job != nil)
            .help("开始翻译  ⌘↩")
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)
        .padding(.bottom, 12)
    }

    private func progress(_ job: JobProgress) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.path").foregroundStyle(Palette.teal)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.cancelling ? "正在取消…" : job.title).font(.system(size: 12, weight: .semibold))
                Text(job.detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            ProgressView(value: job.fraction).frame(width: 115)
            Text("\(Int(job.fraction * 100))%")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
            Button("取消") { store.cancel() }.disabled(store.cancelling)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.mint.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 22)
        .padding(.top, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Palette.mint.opacity(0.42))
                    .rotationEffect(.degrees(-9)).frame(width: 85, height: 85)
                RoundedRectangle(cornerRadius: 18)
                    .fill(Palette.teal).frame(width: 76, height: 76)
                Image(systemName: "book.pages")
                    .font(.system(size: 34, weight: .light)).foregroundStyle(Palette.mint)
            }
            .padding(.bottom, 26)
            Text("读懂下一篇论文")
                .font(.system(size: 32, weight: .semibold, design: .serif))
            Text("从 arXiv 源码生成中文版 PDF，在同一个窗口对照阅读。")
                .font(.system(size: 14)).foregroundStyle(Palette.muted)
                .padding(.top, 12)
            HStack(spacing: 7) {
                ForEach([("arrow.down.doc", "获取源码"), ("character.book.closed", "学术翻译"), ("book", "本机编译")],
                        id: \.1) { symbol, title in
                    Label(title, systemImage: symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.teal)
                        .padding(.vertical, 7).padding(.horizontal, 10)
                        .background(.white, in: Capsule())
                        .overlay(Capsule().stroke(Palette.line))
                }
            }.padding(.top, 24)
            Button {
                store.input = "https://arxiv.org/abs/1706.03762v7"
                linkFocused = true
            } label: {
                Label("填入示例论文", systemImage: "arrow.up.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.teal)
            }
            .buttonStyle(.plain)
            .padding(.top, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 30)
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(Palette.teal.opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.42),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct Failure: Identifiable {
    let message: String
    var id: String { message }
}

private struct ErrorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("翻译任务未完成", systemImage: "exclamationmark.circle")
                .font(.title2.weight(.semibold))
            ScrollView {
                Text(message).font(.system(size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            HStack {
                Button("复制详情") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                if message.contains("编译") {
                    Button("打开编译日志") {
                        NSWorkspace.shared.open(Paper.support.appendingPathComponent("LastCompile.log"))
                    }
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
