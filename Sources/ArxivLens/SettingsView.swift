import AppKit
import PaperCore
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("endpoint") private var savedEndpoint = ""
    @AppStorage("model") private var savedModel = ""
    @AppStorage("glossary") private var savedGlossary = ""
    @AppStorage("texPath") private var savedTex = ""
    @ViewState private var endpoint = ""
    @ViewState private var model = ""
    @ViewState private var glossary = ""
    @ViewState private var tex = ""
    @ViewState private var key = ""
    @ViewState private var status = ""
    @ViewState private var isError = false
    @ViewState private var checking = false
    @ViewState private var checkTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("翻译与 TeX 设置").font(.system(size: 24, weight: .semibold, design: .serif))
                Text("正文发送至所选 API，PDF 在本机编译。API Key 存于 macOS 钥匙串。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Divider()
            field("API URL") {
                TextField("https://api.example.com/v1", text: $endpoint)
            }
            field("模型 ID") {
                TextField("填写服务商提供的模型 ID", text: $model)
            }
            field("API Key") {
                SecureField("输入服务商的 API Key", text: $key)
            }
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
            field("术语表") {
                VStack(alignment: .leading, spacing: 5) {
                    TextEditor(text: $glossary).font(.system(size: 12))
                        .frame(height: 78)
                        .padding(4)
                        .background(.white, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
                    Text("可选，每行一条，例如 attention mechanism = 注意力机制")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
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
            key = Keychain.read()
        }
        .onDisappear { checkTask?.cancel() }
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
        try TranslationSettings(url: endpoint, model: model, key: key, glossary: glossary, texPath: tex)
    }

    private func save() {
        do {
            if !endpoint.isEmpty || !model.isEmpty || !key.isEmpty { _ = try settings() }
            try Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
            savedEndpoint = endpoint
            savedModel = model
            savedGlossary = glossary
            savedTex = tex
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
