import Foundation
import PaperCore
import SwiftUI

@MainActor
final class CatalogStore: ObservableObject {
    @Published private(set) var entries: [String: PaperClassification] = [:]
    @Published private(set) var working = false
    @Published private(set) var status: String?
    @Published private(set) var loadError: String?
    private var task: Task<Void, Never>?
    private var pending: [([Paper.HistoryEntry], TranslationSettings)] = []

    init() {
        do { entries = try LibraryCatalog.load() }
        catch { loadError = "本机分类文件无法读取。请检查文献库中的 catalog.json。" }
    }

    var categories: [String] {
        Array(Set(entries.values.map(\.category).filter { !$0.isEmpty })).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    func edit(_ id: String, category: String, keywords: [String], kind: PublicationKind) throws {
        var updated = entries
        updated[id] = PaperClassification(category: category, keywords: keywords, kind: kind, manual: true)
        try persist(updated)
    }

    func classify(_ records: [Paper.HistoryEntry], settings: TranslationSettings) {
        let missing = records.filter { entries[$0.id] == nil }
        guard !missing.isEmpty, loadError == nil else { return }
        pending.append((missing, settings))
        guard task == nil else { return }
        working = true
        status = "正在整理文献…"
        task = Task { [weak self] in
            guard let self else { return }
            await drain()
        }
    }

    func cancel() {
        pending.removeAll()
        task?.cancel()
    }

    private func drain() async {
        var count = 0
        var missed = 0
        defer { task = nil; working = false }
        do {
            while !pending.isEmpty {
                try Task.checkCancellation()
                let (records, settings) = pending.removeFirst()
                let missing = records.filter { entries[$0.id] == nil }
                for start in stride(from: 0, to: missing.count, by: 8) {
                    try Task.checkCancellation()
                    let batch = Array(missing[start..<min(start + 8, missing.count)]).filter { entries[$0.id] == nil }
                    guard !batch.isEmpty else { continue }
                    status = "正在整理 · 已完成 \(count) 篇"
                    let classifications = try await LibraryAI.classify(batch, categories: categories, settings: settings)
                    try Task.checkCancellation()
                    var updated = entries
                    for (id, value) in classifications where updated[id] == nil {
                        updated[id] = value
                        count += 1
                    }
                    missed += batch.count - classifications.count
                    if updated != entries { try persist(updated) }
                }
            }
            status = missed > 0 ? "已整理 \(count) 篇，\(missed) 篇待重试" : "已整理 \(count) 篇"
        } catch {
            pending.removeAll()
            status = Task.isCancelled ? "已停止整理" : error.localizedDescription
        }
    }

    private func persist(_ updated: [String: PaperClassification]) throws {
        if let loadError { throw LensError(loadError) }
        try LibraryCatalog.save(updated)
        entries = updated
    }
}
