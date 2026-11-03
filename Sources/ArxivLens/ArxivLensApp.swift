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
                Button("仅下载 arXiv 原文") { store.start(downloadOnly: true) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(store.job != nil || store.input.isEmpty)
                Button("下载并翻译 arXiv 论文") { store.start() }
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
    @Published private(set) var selected: Paper?
    @Published private(set) var originalRequest: UUID?
    @Published var papers = Paper.history()
    @Published var settingsOpen = false
    @Published var job: JobProgress?
    @Published var failure: String?
    @Published var cancelling = false
    private var task: Task<Void, Never>?

    init() { selected = papers.first }

    func select(_ paper: Paper, original: Bool = false) {
        originalRequest = original ? UUID() : nil
        selected = paper
    }

    func start(downloadOnly: Bool = false, paper: Paper? = nil) {
        guard task == nil else { return }
        let link = paper?.arxivID ?? input
        do { _ = try ArxivID(link) }
        catch { failure = error.localizedDescription; return }

        let settings: TranslationSettings?
        if downloadOnly {
            settings = nil
        } else {
            let defaults = UserDefaults.standard
            do {
                settings = try TranslationSettings(url: defaults.string(forKey: "endpoint") ?? "",
                    model: defaults.string(forKey: "model") ?? "", key: Keychain.read(),
                    glossary: defaults.string(forKey: "glossary") ?? "", texPath: defaults.string(forKey: "texPath") ?? "",
                    lineSpacing: LineSpacing(rawValue: defaults.string(forKey: "lineSpacing") ?? "") ?? .comfortable)
            } catch {
                settingsOpen = true
                return
            }
        }

        job = JobProgress(title: downloadOnly ? "准备下载" : "准备翻译", detail: "正在启动任务", fraction: 0)
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil; self.job = nil; self.cancelling = false }
            do {
                let report: @Sendable (JobProgress) async -> Void = { [weak self] status in
                    await self?.update(status)
                }
                let result: Paper
                if let settings {
                    result = try await PaperPipeline.run(input: link, settings: settings, report: report)
                } else {
                    result = try await PaperPipeline.download(input: link, report: report)
                }
                papers = Paper.history()
                select(result, original: downloadOnly)
                if paper == nil, input == link { input = "" }
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
