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
    @FocusState private var linkFocused: Bool
    @ViewState private var jobsOpen = false

    private var history: [Paper.HistoryEntry] { Paper.groupedHistory(store.papers) }

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar(store: store, catalog: store.catalog)
                .frame(width: 260)
            VStack(spacing: 0) {
                if store.selected == nil || !compactReader {
                    toolbar
                    Rectangle().fill(Palette.line).frame(height: 1)
                }
                if !store.jobs.isEmpty { taskBar }
                if let paper = store.selected {
                    ReaderView(paper: paper, compact: $compactReader, originalRequest: store.originalRequest,
                               translations: history.first { $0.id == paper.paperID }?.translations ?? [],
                               busy: store.isBusy(paper.paperID),
                               pendingSource: PaperPipeline.pendingSource(for: paper),
                               selectTranslation: { store.select($0) },
                               translate: { store.start(paper: paper) },
                               recompile: { store.recompile(paper) })
                        .id(paper.id)
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
        .sheet(item: $store.failure) { issue in
            ErrorSheet(issue: issue)
        }
        .onChange(of: store.jobs.isEmpty) { empty in if empty { jobsOpen = false } }
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
            Button { store.start(downloadOnly: true) } label: {
                Label("仅下载", systemImage: "arrow.down")
            }
            .controlSize(.large)
            .disabled(!store.canSubmit)
            .help("保存原版 PDF 和 TeX 源码  ⇧⌘↩")
            Button { store.start() } label: {
                Label("下载并翻译", systemImage: "sparkle")
            }
            .buttonStyle(PrimaryButton())
            .disabled(!store.canSubmit)
            .help("获取 TeX 源码并生成中文版  ⌘↩")
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)
        .padding(.bottom, 12)
    }

    private var taskBar: some View {
        HStack(spacing: 9) {
            Button { jobsOpen.toggle() } label: {
                Label("后台任务 · \(store.jobs.count)", systemImage: "list.bullet.rectangle")
            }
            .popover(isPresented: $jobsOpen, arrowEdge: .bottom) { taskList }
            if let job = store.jobs.first(where: \.isRunning) {
                ProgressView(value: job.progress.fraction).frame(width: 90)
                Text("\(job.progress.title) · \(job.title)").lineLimit(1)
                    .foregroundStyle(Palette.muted)
            }
            let failures = store.jobs.filter { $0.failure != nil }.count
            if failures > 0 {
                Label("\(failures) 项未完成", systemImage: "exclamationmark.circle")
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            if compactReader && store.selected != nil {
                Button {
                    compactReader = false
                    linkFocused = true
                } label: {
                    Label("添加论文", systemImage: "plus")
                }
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Palette.mint.opacity(0.2))
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("后台任务").font(.headline)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.jobs) { job in
                        taskRow(job)
                        if job.id != store.jobs.last?.id { Divider() }
                    }
                }
            }
            .frame(height: min(320, CGFloat(max(1, store.jobs.count) * 84)))
        }
        .padding(14)
        .frame(width: 420)
    }

    private func taskRow(_ job: LibraryJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).help(job.title)
            HStack(spacing: 8) {
                Text(job.kind).foregroundStyle(Palette.teal)
                switch job.phase {
                case .queued:
                    Text("排队中")
                    Spacer()
                    Button("取消") { store.cancel(job.id) }
                case .running:
                    Text(job.progress.title).lineLimit(1)
                    ProgressView(value: job.progress.fraction).frame(width: 64)
                    Spacer(minLength: 4)
                    Button("取消") { store.cancel(job.id) }
                case .cancelling:
                    Text("正在取消…")
                    Spacer()
                case .failed(let issue):
                    Text("未完成")
                    Spacer()
                    if let paper = job.original, PaperPipeline.pendingSource(for: paper) != nil {
                        Button("重新编译") { store.recompile(paper) }
                    }
                    Button("详情") {
                        jobsOpen = false
                        store.failure = issue
                    }
                    Button("清除") { store.cancel(job.id) }
                }
                if let original = job.original {
                    Button("打开原文") {
                        store.select(original, original: true)
                        jobsOpen = false
                    }
                }
            }
            .font(.system(size: 11))
            if case .running = job.phase, !job.progress.detail.isEmpty {
                Text(job.progress.detail).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
            }
        }
        .padding(.vertical, 8)
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
            Text("从 arXiv 保存原文，或生成中文版 PDF 对照阅读。")
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

private struct ErrorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let issue: JobFailure
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("论文任务未完成", systemImage: "exclamationmark.circle")
                .font(.title2.weight(.semibold))
            ScrollView {
                Text(issue.message).font(.system(size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            HStack {
                Button("复制详情") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(issue.message, forType: .string)
                }
                if let log = issue.logURL {
                    Button("打开编译日志") {
                        NSWorkspace.shared.open(log)
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
