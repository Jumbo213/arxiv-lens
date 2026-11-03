import Foundation
import PaperCore
import SwiftUI

private enum LibraryGrouping: String, CaseIterable {
    case recent = "时间"
    case alphabet = "字母"
    case category = "主题"
    case kind = "类型"
}

private enum SearchMode: String, CaseIterable {
    case keyword = "关键词"
    case natural = "自然语言"
}

private struct LibrarySection: Identifiable {
    let id: String
    let entries: [Paper.HistoryEntry]
}

struct LibrarySidebar: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var catalog: CatalogStore
    @AppStorage("libraryGrouping") private var grouping = LibraryGrouping.recent
    @AppStorage("autoClassify") private var autoClassify = true
    @ViewState private var mode = SearchMode.keyword
    @ViewState private var query = ""
    @ViewState private var editTarget: Paper.HistoryEntry?
    @ViewState private var hits: [LibrarySearchHit]?
    @ViewState private var searchStatus: String?
    @ViewState private var searchTask: Task<Void, Never>?
    @ViewState private var searchID: UUID?

    private var history: [Paper.HistoryEntry] { Paper.groupedHistory(store.papers) }
    private var terms: [Substring] { query.split(whereSeparator: \.isWhitespace) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            branding
            searchControls
            libraryControls
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    let sections = sections()
                    ForEach(sections) { section in
                        if !section.id.isEmpty {
                            HStack {
                                Text(section.id).lineLimit(1)
                                Spacer()
                                Text("\(section.entries.count)").monospacedDigit()
                            }
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.soft)
                            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                        }
                        ForEach(section.entries) { entry in row(entry) }
                    }
                    if sections.isEmpty { emptyState }
                }
                .padding(.horizontal, 12)
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
        .environment(\.colorScheme, .dark)
        .background(LinearGradient(colors: [Palette.sidebar, Color(red: 0.074, green: 0.205, blue: 0.213)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .onChange(of: query) { _ in resetSearch() }
        .onChange(of: mode) { _ in resetSearch() }
        .onDisappear { searchTask?.cancel() }
        .sheet(item: $editTarget) { entry in
            ClassificationEditor(entry: entry, catalog: catalog)
                .environment(\.colorScheme, .light)
        }
    }

    private var branding: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Palette.mint).frame(width: 38, height: 38)
                Image(systemName: "book.pages").font(.system(size: 19, weight: .medium)).foregroundStyle(Palette.sidebar)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Arxiv Lens").font(.system(size: 21, weight: .semibold, design: .serif)).foregroundStyle(.white)
                Text("论文翻译与阅读").font(.system(size: 11)).foregroundStyle(Palette.soft)
            }
        }
        .padding(.top, 48)
        .padding(.bottom, 20)
        .padding(.horizontal, 20)
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("检索方式", selection: $mode) {
                ForEach(SearchMode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 7) {
                Image(systemName: mode == .keyword ? "magnifyingglass" : "sparkle")
                    .font(.system(size: 11)).foregroundStyle(Palette.mint)
                TextField(mode == .keyword ? "标题、编号或关键词" : "例：关于推理模型后训练的论文", text: $query)
                    .textFieldStyle(.plain).foregroundStyle(.white)
                    .onSubmit { if mode == .natural { search() } }
                if searchTask != nil {
                    Button { resetSearch() } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.plain).help("停止检索")
                } else if mode == .natural && !terms.isEmpty {
                    Button { search() } label: { Image(systemName: "arrow.up.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Palette.mint)
                        .help("用 API 检索文献库").accessibilityLabel("用 API 检索文献库")
                }
                if !query.isEmpty && searchTask == nil {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .font(.system(size: 12)).foregroundStyle(Palette.soft)
            .padding(9).background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 7))
            if let searchStatus {
                Text(searchStatus).font(.system(size: 10)).foregroundStyle(Palette.soft)
                    .lineLimit(2).help(searchStatus)
            } else if mode == .natural && hits == nil {
                Text("按回车搜索 · 使用当前 API 和库内元数据")
                    .font(.system(size: 10)).foregroundStyle(Palette.soft)
            }
        }
        .padding(.horizontal, 15)
    }

    private var libraryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("文献库").font(.system(size: 11, weight: .semibold))
                Text("\(history.count)").font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(0.09), in: Capsule())
                Spacer()
                Menu {
                    Button("AI 分类未整理文献") { classify(history) }
                        .disabled(catalog.working || catalog.loadError != nil || history.allSatisfy { catalog.entries[$0.id] != nil })
                    if catalog.working { Button("停止整理") { catalog.cancel() } }
                    if let entry = history.first(where: { $0.id == store.selected?.paperID }) {
                        Button("编辑当前文献分类…") { editTarget = entry }
                            .disabled(catalog.loadError != nil)
                    }
                    Divider()
                    Toggle("自动分类新入库文献", isOn: $autoClassify)
                } label: {
                    Label("整理", systemImage: "tag").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if let notice = catalog.loadError ?? catalog.status {
                Text(notice).font(.system(size: 10)).lineLimit(2).help(notice)
            }
            if hits == nil || mode == .keyword {
                Picker("分组方式", selection: $grouping) {
                    ForEach(LibraryGrouping.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
        .foregroundStyle(Palette.soft)
        .padding(.horizontal, 15)
        .padding(.top, 15)
        .padding(.bottom, 7)
    }

    private func sections() -> [LibrarySection] {
        if mode == .natural, let hits {
            let byID = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
            let results = hits.compactMap { byID[$0.id] }
            return results.isEmpty ? [] : [LibrarySection(id: "检索结果", entries: results)]
        }
        let filtered = mode == .natural || terms.isEmpty ? history : history.filter { entry in
            let classification = catalog.entries[entry.id]
            let searchable = entry.translations.flatMap { [$0.title, $0.arxivID] }
                + (classification.map { [$0.category, $0.kind.label] + $0.keywords } ?? [])
            return terms.allSatisfy { term in searchable.contains { $0.localizedCaseInsensitiveContains(term) } }
        }
        guard !filtered.isEmpty else { return [] }
        if grouping == .recent { return [LibrarySection(id: "", entries: filtered)] }
        let grouped = Dictionary(grouping: filtered) { entry -> String in
            let classification = catalog.entries[entry.id]
            switch grouping {
            case .recent: return ""
            case .alphabet: return LibraryCatalog.initial(entry.latest.title)
            case .category:
                return classification.flatMap { $0.category.isEmpty ? nil : $0.category } ?? "未分类"
            case .kind: return classification?.kind.label ?? "未分类"
            }
        }
        let keys = grouped.keys.sorted { a, b in
            if a == "未分类" || a == "#" { return false }
            if b == "未分类" || b == "#" { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return keys.compactMap { name in
            grouped[name].map { records in
                LibrarySection(id: name, entries: grouping == .alphabet ? records.sorted {
                    $0.latest.title.localizedStandardCompare($1.latest.title) == .orderedAscending
                } : records)
            }
        }
    }

    private func row(_ entry: Paper.HistoryEntry) -> some View {
        let paper = entry.latest
        let classification = catalog.entries[entry.id]
        let active = entry.id == store.selected?.paperID
        let count = entry.translations.filter(\.hasTranslation).count
        let reason = mode == .natural ? hits?.first { $0.id == entry.id }?.reason : nil
        return Button { store.select(paper) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "doc.text").font(.system(size: 12))
                    .foregroundStyle(active ? Palette.mint : Palette.soft).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(paper.title).lineLimit(3)
                        .font(.system(size: 12, weight: active ? .semibold : .medium))
                        .foregroundStyle(.white)
                    HStack(spacing: 7) {
                        Text(paper.arxivID).font(.system(size: 10, design: .monospaced))
                        if !paper.hasTranslation {
                            Text("仅原文")
                        } else if count > 1 {
                            Text("\(count) 个译本")
                        }
                    }.font(.system(size: 10)).foregroundStyle(Palette.soft)
                    if let reason, !reason.isEmpty {
                        Text(reason).font(.system(size: 10)).foregroundStyle(Palette.mint).lineLimit(2)
                    } else if let classification {
                        Text([classification.category, classification.kind.label].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(Palette.soft).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(active ? Palette.teal.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(paper.title)
        .contextMenu {
            Button(paper.hasTranslation ? "重新翻译这篇论文" : "翻译这篇论文") {
                store.start(paper: paper)
            }.disabled(store.job != nil)
            Button("编辑分类…") { editTarget = entry }.disabled(catalog.loadError != nil)
            if classification == nil {
                Button("用 API 分类") { classify([entry]) }.disabled(catalog.loadError != nil)
            }
        }
    }

    private var emptyState: some View {
        Text(history.isEmpty ? "下载或译完的论文会显示在这里" : "没有匹配的论文")
            .font(.system(size: 11)).foregroundStyle(Palette.soft).padding(9)
    }

    private func classify(_ entries: [Paper.HistoryEntry]) {
        guard let settings = store.apiSettings() else { return }
        catalog.classify(entries, settings: settings)
    }

    private func resetSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchID = nil
        searchStatus = nil
        hits = nil
    }

    private func search() {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let records = history
        guard searchTask == nil, !input.isEmpty, !records.isEmpty, let settings = store.apiSettings() else { return }
        let request = UUID()
        let classifications = catalog.entries
        searchID = request
        hits = nil
        searchStatus = "正在检索 \(records.count) 篇文献…"
        searchTask = Task { @MainActor in
            defer { if searchID == request { searchTask = nil } }
            do {
                let result = try await LibraryAI.search(input, in: records, classifications: classifications, settings: settings) { done, total in
                    await MainActor.run {
                        if searchID == request { searchStatus = "正在检索 · \(done)/\(total)" }
                    }
                }
                guard searchID == request, !Task.isCancelled else { return }
                hits = result
                searchStatus = "命中 \(result.count) 篇"
            } catch {
                if searchID == request && !Task.isCancelled { searchStatus = error.localizedDescription }
            }
        }
    }
}

private struct ClassificationEditor: View {
    @Environment(\.dismiss) private var dismiss
    let entry: Paper.HistoryEntry
    let catalog: CatalogStore
    @ViewState private var category: String
    @ViewState private var keywords: String
    @ViewState private var kind: PublicationKind
    @ViewState private var failure: String?

    init(entry: Paper.HistoryEntry, catalog: CatalogStore) {
        self.entry = entry
        self.catalog = catalog
        let existing = catalog.entries[entry.id]
        _category = ViewState(initialValue: existing?.category ?? "")
        _keywords = ViewState(initialValue: existing?.keywords.joined(separator: "，") ?? "")
        _kind = ViewState(initialValue: existing?.kind ?? .unknown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("编辑文献分类").font(.system(size: 22, weight: .semibold))
            Text(entry.latest.title).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(3)
            Divider()
            HStack {
                TextField("主题类别", text: $category).textFieldStyle(.roundedBorder)
                if !catalog.categories.isEmpty {
                    Menu("已有主题") {
                        ForEach(catalog.categories, id: \.self) { title in
                            Button(title) { category = title }
                        }
                    }.fixedSize()
                }
            }
            TextField("关键词，用逗号或顿号分隔", text: $keywords).textFieldStyle(.roundedBorder)
            Picker("文献类型", selection: $kind) {
                ForEach(PublicationKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if let failure {
                Text(failure).font(.system(size: 11)).foregroundStyle(.red)
            } else {
                Text(catalog.entries[entry.id]?.manual == true
                     ? "当前使用手动分类。"
                     : "保存后，该分类将用于分组和检索。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        let terms = keywords.components(separatedBy: CharacterSet(charactersIn: ",，、;；"))
                        try catalog.edit(entry.id, category: category, keywords: terms, kind: kind)
                        dismiss()
                    } catch { failure = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).buttonStyle(PrimaryButton())
            }
        }
        .padding(24).frame(width: 470)
        .background(Palette.paper).foregroundStyle(Palette.ink)
    }
}
