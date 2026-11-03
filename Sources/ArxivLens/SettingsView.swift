import AppKit
import PaperCore
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("endpoint") private var savedEndpoint = ""
    @AppStorage("model") private var savedModel = ""
    @AppStorage("glossary") private var savedGlossary = ""
    @AppStorage("texPath") private var savedTex = ""
    @AppStorage("lineSpacing") private var savedSpacing = LineSpacing.comfortable.rawValue
    @ViewState private var endpoint = ""
    @ViewState private var model = ""
    @ViewState private var glossary = ""
    @ViewState private var tex = ""
    @ViewState private var spacing: LineSpacing = .comfortable
    @ViewState private var key = ""
    @ViewState private var status = ""
    @ViewState private var glossaryOpen = false
    @ViewState private var isError = false
    @ViewState private var checking = false
    @ViewState private var checkTask: Task<Void, Never>?
    @ViewState private var allowedModelURL: URL?
    @ViewState private var modelRefresh = 0
    @ViewState private var models: [AvailableModel] = []
    @ViewState private var modelStatus: String?
    @ViewState private var loadingModels = false
    @ViewState private var modelPickerOpen = false

    private struct ModelRequest: Hashable {
        let connection: APIConnection
        let refresh: Int
    }

    private var modelConnection: APIConnection? { try? APIConnection(url: endpoint, key: key) }

    private var modelRequest: ModelRequest? {
        guard let connection = modelConnection,
              !connection.hasKey || allowedModelURL == connection.modelsURL else { return nil }
        return ModelRequest(connection: connection, refresh: modelRefresh)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("翻译与 TeX 设置").font(.system(size: 24, weight: .semibold, design: .serif))
                Text("正文发送至所选 API，PDF 在本机编译。API Key 存于 macOS 钥匙串。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Divider()
            field("API URL") {
                HStack(spacing: 8) {
                    TextField("https://api.example.com/v1", text: $endpoint)
                    Menu("服务商预设") {
                        ForEach(APIProviderPreset.presets) { preset in
                            Button { apply(preset) } label: {
                                if isCurrent(preset) {
                                    Label(preset.name, systemImage: "checkmark")
                                } else {
                                    Text(preset.name)
                                }
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(checking)
                    .help("填入服务商的 API 地址")
                }
            }
            field("API Key") {
                SecureField("输入服务商的 API Key", text: Binding(
                    get: { key },
                    set: {
                        key = $0
                        allowedModelURL = modelConnection?.modelsURL
                    }
                ))
            }
            field("模型 ID") { modelControls }
            HStack {
                Text("OpenAI 兼容接口，可填写 Base URL 或完整 Chat Completions URL。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Button("测试 API") { check { try await settings().checkAPI(); return "API 连接成功" } }
                    .disabled(checking)
            }

            Divider()
            field("TeX bin") {
                HStack {
                    TextField("留空自动识别 MacTeX 或 TinyTeX", text: $tex)
                    Button("选择…") { chooseTeX() }
                    Button("检测 TeX") { check { "已找到 " + (try await LocalTeX.check(tex)) } }.disabled(checking)
                }
            }
            field("译文行距") {
                VStack(alignment: .leading, spacing: 5) {
                    Picker("译文行距", selection: $spacing) {
                        Text("贴近原稿").tag(LineSpacing.original)
                        Text("舒展").tag(LineSpacing.comfortable)
                        Text("宽松").tag(LineSpacing.spacious)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                    Text("适用于新生成的中文 PDF，行距变化可能影响分页。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
            field("术语表") {
                VStack(alignment: .leading, spacing: 5) {
                    TextEditor(text: $glossary).font(.system(size: 12))
                        .frame(height: 78)
                        .padding(4)
                        .background(.white, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
                    HStack {
                        Text("每行一条，例 attention mechanism = 注意力机制。自定义译名优先。")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button("查看内置术语…") { glossaryOpen = true }
                    }
                }
            }
            if !status.isEmpty {
                Label(status, systemImage: isError ? "exclamationmark.circle" : "info.circle")
                    .font(.system(size: 11)).foregroundStyle(isError ? Color.red : Palette.teal)
                    .textSelection(.enabled)
            }
            HStack {
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 660)
        .background(Palette.paper)
        .foregroundStyle(Palette.ink)
        .onAppear {
            endpoint = savedEndpoint
            model = savedModel
            glossary = savedGlossary
            tex = savedTex
            spacing = LineSpacing(rawValue: savedSpacing) ?? .comfortable
            key = Keychain.read()
            allowedModelURL = modelConnection?.modelsURL
        }
        .task(id: modelRequest) { await fetchModels(modelRequest) }
        .onDisappear { checkTask?.cancel() }
        .sheet(isPresented: $glossaryOpen) { GlossaryView() }
    }

    private func isCurrent(_ preset: APIProviderPreset) -> Bool {
        guard let current = try? APIConnection.chatEndpoint(for: endpoint) else { return false }
        return current == (try? APIConnection.chatEndpoint(for: preset.url))
    }

    private func apply(_ preset: APIProviderPreset) {
        if !isCurrent(preset) {
            key = ""
            model = ""
            allowedModelURL = nil
            status = ""
        }
        endpoint = preset.url
    }

    private var modelControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                TextField("选择模型或直接填写模型 ID", text: $model)
                Button("选择模型") { modelPickerOpen = true }
                    .disabled(models.isEmpty || loadingModels)
                    .popover(isPresented: $modelPickerOpen, arrowEdge: .bottom) {
                        ModelPicker(models: models, selectedID: model) { selected in
                            model = selected
                            modelPickerOpen = false
                        }
                    }
                Button {
                    allowedModelURL = modelConnection?.modelsURL
                    modelRefresh += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("获取模型列表").accessibilityLabel("获取模型列表")
                .disabled(modelConnection == nil || loadingModels)
            }
            HStack(spacing: 6) {
                if loadingModels { ProgressView().controlSize(.small) }
                Text(modelHint).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelHint: String {
        if loadingModels { return "正在获取模型列表…" }
        if let modelStatus { return modelStatus }
        if modelConnection != nil && modelRequest == nil {
            return "API 地址已更换。填写该服务的 Key，或点击刷新使用当前 Key。"
        }
        return "填写 API 地址和 Key 后自动获取模型，也可以手动输入。"
    }

    private func fetchModels(_ request: ModelRequest?) async {
        guard !Task.isCancelled else { return }
        modelPickerOpen = false
        models = []
        modelStatus = nil
        loadingModels = request != nil
        guard let request else { return }
        defer { if !Task.isCancelled { loadingModels = false } }
        do {
            try await Task.sleep(nanoseconds: 650_000_000)
            let result = try await request.connection.listModels()
            guard !Task.isCancelled else { return }
            models = result
            modelStatus = result.isEmpty ? "接口返回的模型列表为空。可以手动填写模型 ID。"
                : "已获取 \(result.count) 个模型。"
        } catch {
            if !Task.isCancelled { modelStatus = error.localizedDescription }
        }
    }

    private func field<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(name).font(.system(size: 12, weight: .medium))
                .frame(width: 61, alignment: .leading)
                .padding(.top, 4)
            content().textFieldStyle(.roundedBorder)
        }
    }

    private func settings() throws -> TranslationSettings {
        try TranslationSettings(url: endpoint, model: model, key: key, glossary: glossary, texPath: tex, lineSpacing: spacing)
    }

    private func save() {
        do {
            if !endpoint.isEmpty || !model.isEmpty || !key.isEmpty { _ = try settings() }
            try Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
            savedEndpoint = endpoint
            savedModel = model
            savedGlossary = glossary
            savedTex = tex
            savedSpacing = spacing.rawValue
            dismiss()
        } catch {
            isError = true
            status = error.localizedDescription
        }
    }

    private func check(_ work: @escaping @MainActor () async throws -> String) {
        checking = true
        isError = false
        status = "正在检测…"
        checkTask = Task {
            defer { checking = false }
            do {
                let result = try await work()
                if !Task.isCancelled { status = result }
            } catch {
                if !Task.isCancelled { isError = true; status = error.localizedDescription }
            }
        }
    }

    private func chooseTeX() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = "选择 TeX bin"
        if panel.runModal() == .OK, let url = panel.url { tex = url.path }
    }
}


private struct ModelPicker: View {
    let models: [AvailableModel]
    let selectedID: String
    let select: (String) -> Void
    @ViewState private var query = ""

    private var filtered: [AvailableModel] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if search.isEmpty { return models }
        return models.filter { $0.id.localizedCaseInsensitiveContains(search) ||
            $0.name?.localizedCaseInsensitiveContains(search) == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索模型名称或 ID", text: $query).textFieldStyle(.roundedBorder)
            if filtered.isEmpty {
                Text("没有匹配的模型").font(.system(size: 12)).foregroundStyle(Palette.muted)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { model in
                            Button { select(model.id) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        if let name = model.name, !name.isEmpty, name != model.id {
                                            Text(name).font(.system(size: 12, weight: .semibold))
                                        }
                                        Text(model.id).font(.system(size: 11, design: .monospaced)).lineLimit(2)
                                    }
                                    Spacer()
                                    if selectedID == model.id {
                                        Image(systemName: "checkmark").foregroundStyle(Palette.teal)
                                    }
                                }
                                .padding(7)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 200)
            }
        }
        .padding(12).frame(width: 340)
    }
}

private struct GlossaryView: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var category = 0
    @ViewState private var query = ""
    private let sections = GlossaryCatalog.sections

    private var results: [GlossaryCatalog.Term] {
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = sections[category].terms
        guard !filter.isEmpty else { return terms }
        return terms.filter { $0.english.localizedCaseInsensitiveContains(filter) || $0.chinese.contains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("内置术语").font(.system(size: 24, weight: .semibold, design: .serif))
            Text("翻译时按段落匹配词条。需要其他译法时，可以在设置中添加同名自定义词条。")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            Picker("领域", selection: $category) {
                ForEach(sections.indices, id: \.self) { index in
                    Text(sections[index].title).tag(index)
                }
            }.pickerStyle(.segmented).labelsHidden()
            TextField("搜索当前领域的英中术语", text: $query).textFieldStyle(.roundedBorder)
            List(results) { term in
                HStack(alignment: .firstTextBaseline) {
                    Text(term.english).frame(maxWidth: .infinity, alignment: .leading)
                    Text(term.chinese).foregroundStyle(Palette.teal)
                }
                .textSelection(.enabled)
                .font(.system(size: 12))
            }
            .frame(height: 292)
            HStack {
                Text("\(results.count) 条").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 660)
        .background(Palette.paper)
    }
}
