import AppKit
import LocalAuthentication
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

struct APIProfile: Codable {
    var model = ""
    var keys: [String] = []

    mutating func normalize() {
        model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        keys = keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.jumbo213.arxiv-lens",
        kSecAttrAccount as String: "translation-api"
    ]

    static func scope(_ endpoint: String) -> String? {
        (try? APIConnection.chatEndpoint(for: endpoint))?.absoluteString
    }

    static func profiles(interactive: Bool = true) throws -> [String: APIProfile] {
        var args = query
        args[kSecReturnData as String] = true
        args[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            args[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(args as CFDictionary, &result)
        if status == errSecItemNotFound { return legacyProfile() }
        guard status == errSecSuccess, let data = result as? Data else {
            throw LensError("无法读取钥匙串中的 API Key（\(status)）。")
        }
        if let profiles = try? JSONDecoder().decode([String: APIProfile].self, from: data) {
            return profiles
        }
        // Old releases stored one raw key, associated with the saved endpoint.
        return legacyProfile(key: String(decoding: data, as: UTF8.self))
    }

    private static func legacyProfile(key: String = "") -> [String: APIProfile] {
        let defaults = UserDefaults.standard
        guard let endpoint = defaults.string(forKey: "endpoint"), let scope = scope(endpoint) else { return [:] }
        var profile = APIProfile(model: defaults.string(forKey: "model") ?? "", keys: [key])
        profile.normalize()
        return [scope: profile]
    }

    static func save(_ profiles: [String: APIProfile]) throws {
        let value = [kSecValueData as String: try JSONEncoder().encode(profiles)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(value, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LensError("无法保存 API Key 到钥匙串（\(status)）。") }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    let catalog = CatalogStore()
    @Published var input = ""
    @Published private(set) var selected: Paper?
    @Published private(set) var originalRequest: UUID?
    @Published var papers = Paper.history()
    @Published var settingsOpen = false
    @Published var job: JobProgress?
    @Published var failure: String?
    @Published var cancelling = false
    private var task: Task<Void, Never>?
    private var jobHasOriginal = false

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
            guard let configured = apiSettings() else { return }
            settings = configured
        }

        job = JobProgress(title: downloadOnly ? "准备下载" : "准备翻译", detail: "正在启动任务", fraction: 0)
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
                self.job = nil
                self.cancelling = false
                self.jobHasOriginal = false
            }
            do {
                let report: @Sendable (JobProgress) async -> Void = { [weak self] status in
                    await self?.update(status)
                }
                let result: Paper
                if let settings {
                    result = try await PaperPipeline.run(input: link, settings: settings, originalReady: { [weak self] original in
                        await self?.showSavedOriginal(original)
                    }, report: report)
                } else {
                    result = try await PaperPipeline.download(input: link, report: report)
                }
                papers = Paper.history()
                select(result, original: downloadOnly)
                if paper == nil, input == link { input = "" }
                autoClassify(result, settings: settings)
            } catch {
                if !Task.isCancelled {
                    let saved = jobHasOriginal ? "原版 PDF 已保存在左侧文献库，可打开原文或再次翻译。\n\n" : ""
                    failure = saved + error.localizedDescription
                }
            }
        }
    }

    private func showSavedOriginal(_ paper: Paper) {
        jobHasOriginal = true
        guard !papers.contains(where: { $0.id == paper.id }) else { return }
        papers = Paper.history()
        select(paper, original: true)
    }

    func apiSettings(interactive: Bool = true) -> TranslationSettings? {
        let defaults = UserDefaults.standard
        let endpoint = defaults.string(forKey: "endpoint") ?? ""
        guard let scope = Keychain.scope(endpoint) else {
            if interactive { settingsOpen = true }
            return nil
        }
        do {
            let profile = try Keychain.profiles(interactive: interactive)[scope] ?? APIProfile()
            return try TranslationSettings(url: endpoint,
                model: profile.model, keys: profile.keys,
                glossary: defaults.string(forKey: "glossary") ?? "", texPath: defaults.string(forKey: "texPath") ?? "",
                lineSpacing: LineSpacing(rawValue: defaults.string(forKey: "lineSpacing") ?? "") ?? .comfortable)
        } catch {
            if interactive { settingsOpen = true }
            return nil
        }
    }

    private func autoClassify(_ paper: Paper, settings: TranslationSettings?) {
        guard UserDefaults.standard.object(forKey: "autoClassify") as? Bool ?? true,
              catalog.entries[paper.paperID] == nil,
              let record = Paper.groupedHistory(papers).first(where: { $0.id == paper.paperID }),
              let settings = settings ?? apiSettings(interactive: false) else { return }
        catalog.classify([record], settings: settings)
    }

    private func update(_ progress: JobProgress) { job = progress }

    func cancel() {
        cancelling = true
        task?.cancel()
    }
}
