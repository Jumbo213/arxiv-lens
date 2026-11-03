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
                Button("下载 arXiv 原文与源码") { store.start(downloadOnly: true) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!store.canSubmit)
                Button("下载并翻译 arXiv 论文") { store.start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canSubmit)
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

struct JobFailure: Identifiable {
    let id = UUID()
    let message: String
    var logURL: URL?
}

struct LibraryJob: Identifiable {
    enum Phase {
        case queued, running, cancelling, failed(JobFailure)
    }

    let id: UUID
    let arxiv: ArxivID
    let downloadOnly: Bool
    var title: String
    var progress = JobProgress(title: "等待开始", detail: "", fraction: 0)
    var phase = Phase.queued
    var original: Paper?

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var failure: JobFailure? {
        if case .failed(let failure) = phase { return failure }
        return nil
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    private struct Request {
        let id: UUID
        let arxiv: ArxivID
        let paper: Paper?
        let settings: TranslationSettings?
    }

    private struct Running {
        let task: Task<Void, Never>
        let translating: Bool
    }

    let catalog = CatalogStore()
    @Published var input = ""
    @Published private(set) var selected: Paper?
    @Published private(set) var originalRequest: UUID?
    @Published var papers = Paper.history()
    @Published var settingsOpen = false
    @Published private(set) var jobs: [LibraryJob] = []
    @Published var failure: JobFailure?
    private var pending: [Request] = []
    private var running: [UUID: Running] = [:]
    private var readerFollowingJob: UUID?

    init() { selected = papers.first }

    func select(_ paper: Paper, original: Bool = false) {
        readerFollowingJob = nil
        originalRequest = original ? UUID() : nil
        selected = paper
    }

    var canSubmit: Bool {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return (try? ArxivID(input)).map { !isBusy($0.paperID) } ?? true
    }

    func isBusy(_ paperID: String) -> Bool {
        jobs.contains { $0.arxiv.paperID == paperID && $0.failure == nil }
    }

    func start(downloadOnly: Bool = false, paper: Paper? = nil) {
        let link = paper?.arxivID ?? input
        let arxiv: ArxivID
        do { arxiv = try ArxivID(link) }
        catch { failure = JobFailure(message: error.localizedDescription); return }
        guard !isBusy(arxiv.paperID) else { return }

        let settings: TranslationSettings?
        if downloadOnly {
            settings = nil
        } else {
            guard let configured = apiSettings() else { return }
            settings = configured
        }

        let id = UUID()
        jobs.removeAll { $0.arxiv.paperID == arxiv.paperID && $0.failure != nil }
        jobs.append(LibraryJob(id: id, arxiv: arxiv, downloadOnly: downloadOnly, title: paper?.title ?? arxiv.value))
        pending.append(Request(id: id, arxiv: arxiv, paper: paper, settings: settings))
        if let paper, selected?.id == paper.id { readerFollowingJob = id }
        if paper == nil { input = "" }
        startPending()
    }

    private func startPending() {
        while running.count < 3 {
            // Leave a slot available for downloading while two long translations run.
            let canTranslate = running.values.filter(\.translating).count < 2
            guard let index = pending.firstIndex(where: { $0.settings == nil || canTranslate }) else { return }
            let request = pending.remove(at: index)
            editJob(request.id) { $0.phase = .running }
            let task = Task { [weak self] in
                guard let self else { return }
                await perform(request)
            }
            running[request.id] = Running(task: task, translating: request.settings != nil)
        }
    }

    private func perform(_ request: Request) async {
        let id = request.id
        defer {
            running[id] = nil
            if readerFollowingJob == id { readerFollowingJob = nil }
            startPending()
        }
        let report: @Sendable (JobProgress) async -> Void = { [weak self] status in
            await self?.update(status, id: id)
        }
        let originalReady: @Sendable (Paper) async -> Void = { [weak self] paper in
            await self?.showSavedOriginal(paper, id: id)
        }
        do {
            let result: Paper
            if let settings = request.settings {
                result = try await PaperPipeline.run(input: request.arxiv.value, settings: settings,
                                                     savedPaper: request.paper, originalReady: originalReady, report: report)
            } else {
                result = try await PaperPipeline.download(input: request.arxiv.value, originalReady: originalReady,
                                                          report: report)
            }
            papers = Paper.history()
            if selected == nil || readerFollowingJob == id {
                select(result, original: request.settings == nil)
            }
            jobs.removeAll { $0.id == id }
            if !Task.isCancelled { autoClassify(result, settings: request.settings) }
        } catch {
            if Task.isCancelled {
                jobs.removeAll { $0.id == id }
            } else {
                editJob(id) { job in
                    let saved = job.original == nil ? "" : "原版 PDF 已保存在左侧文献库。\n\n"
                    let log = (error as? PaperPipeline.CompileFailure)?.logURL
                    job.phase = .failed(JobFailure(message: "\(job.title)\n\n" + saved + error.localizedDescription,
                                                   logURL: log))
                }
            }
        }
    }

    private func showSavedOriginal(_ paper: Paper, id: UUID) {
        editJob(id) { job in
            job.original = paper
            job.title = paper.title
        }
        if !papers.contains(where: { $0.id == paper.id }) { papers = Paper.history() }
        if selected == nil {
            select(paper, original: true)
            readerFollowingJob = id
        }
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

    private func editJob(_ id: UUID, _ edit: (inout LibraryJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        edit(&jobs[index])
    }

    private func update(_ progress: JobProgress, id: UUID) {
        editJob(id) { $0.progress = progress }
    }

    func cancel(_ id: UUID) {
        if readerFollowingJob == id { readerFollowingJob = nil }
        if let active = running[id] {
            editJob(id) { $0.phase = .cancelling }
            active.task.cancel()
        } else {
            pending.removeAll { $0.id == id }
            jobs.removeAll { $0.id == id }
        }
    }
}
