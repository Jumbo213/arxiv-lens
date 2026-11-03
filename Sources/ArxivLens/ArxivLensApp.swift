import AppKit
import PaperCore
import Security
import SwiftUI

// Use the property wrapper on SDKs that also declare State as a macro.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct ArxivLensApp: App {
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        WindowGroup("Arxiv Lens") {
            WorkspaceView(store: store)
                .frame(minWidth: 960, minHeight: 610)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 830)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("翻译设置…") { store.settingsOpen = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("翻译 arXiv 论文") { store.start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.job != nil || store.input.isEmpty)
            }
        }
    }
}

enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.jumbo213.arxiv-lens",
        kSecAttrAccount as String: "translation-api"
    ]

    static func read() -> String {
        var args = query
        args[kSecReturnData as String] = true
        args[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(args as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ key: String) throws {
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw LensError("无法移除钥匙串中的 API Key（\(status)）。")
            }
            return
        }
        let value = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(value, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LensError("无法保存 API Key 到钥匙串（\(status)）。") }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var input = ""
    @Published var selected: Paper?
    @Published var papers = Paper.history()
    @Published var settingsOpen = false
    @Published var job: JobProgress?
    @Published var failure: String?
    @Published var cancelling = false
    private var task: Task<Void, Never>?

    init() { selected = papers.first }

    func start() {
        guard task == nil else { return }
        do { _ = try ArxivID(input) }
        catch { failure = error.localizedDescription; return }

        let defaults = UserDefaults.standard
        let endpoint = defaults.string(forKey: "endpoint") ?? ""
        let model = defaults.string(forKey: "model") ?? ""
        let settings: TranslationSettings
        do {
            settings = try TranslationSettings(url: endpoint, model: model, key: Keychain.read(),
                glossary: defaults.string(forKey: "glossary") ?? "", texPath: defaults.string(forKey: "texPath") ?? "")
        } catch {
            settingsOpen = true
            return
        }

        let link = input
        job = JobProgress.starting
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil; self.job = nil; self.cancelling = false }
            do {
                let paper = try await PaperPipeline.run(input: link, settings: settings) { [weak self] status in
                    await self?.update(status)
                }
                papers = Paper.history()
                selected = paper
                if input == link { input = "" }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }

    private func update(_ progress: JobProgress) { job = progress }

    func cancel() {
        cancelling = true
        task?.cancel()
    }
}

private extension JobProgress {
    static var starting: Self { .init(title: "准备翻译", detail: "正在启动任务", fraction: 0) }
}
