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
    private struct Work {
        let records: [Paper.HistoryEntry]
        let settings: TranslationSettings
        let refresh: Bool
    }
    private var pending: [Work] = []

    init() {
        do { entries = try LibraryCatalog.load() }
        catch { loadError = "本机分类文件无法读取。请检查文献库中的 catalog.json。" }
    }

    var categories: [String] {
        Array(Set(entries.values.map(\.category).filter { !$0.isEmpty })).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    func canRefresh(_ id: String) -> Bool { entries[id]?.venue == nil }

    func edit(_ id: String, category: String, keywords: [String], kind: PublicationKind,
              venue: String?, publicationYear: Int?) throws {
        var updated = entries
        updated[id] = PaperClassification(category: category, keywords: keywords, kind: kind, manual: true,
                                          venue: venue, publicationYear: publicationYear)
        try persist(updated)
    }

    func classify(_ records: [Paper.HistoryEntry], settings: TranslationSettings) {
        enqueue(records, settings: settings, refresh: false)
    }

    func refreshPublications(_ records: [Paper.HistoryEntry], settings: TranslationSettings) {
        enqueue(records, settings: settings, refresh: true)
    }

    private func enqueue(_ records: [Paper.HistoryEntry], settings: TranslationSettings, refresh: Bool) {
        let eligible = records.filter { refresh ? canRefresh($0.id) : entries[$0.id] == nil }
        guard !eligible.isEmpty, loadError == nil else { return }
        pending.append(Work(records: eligible, settings: settings, refresh: refresh))
        guard task == nil else { return }
        working = true
        status = refresh ? "正在刷新发表信息…" : "正在整理文献…"
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
        defer { task = nil; working = false }
        do {
            while !pending.isEmpty {
                try Task.checkCancellation()
                let request = pending.removeFirst()
                let missing = request.records.filter { request.refresh ? canRefresh($0.id) : entries[$0.id] == nil }
                var count = 0
                var checked = 0
                var missed = 0
                for start in stride(from: 0, to: missing.count, by: 8) {
                    try Task.checkCancellation()
                    let batch = Array(missing[start..<min(start + 8, missing.count)]).filter {
                        request.refresh ? canRefresh($0.id) : entries[$0.id] == nil
                    }
                    guard !batch.isEmpty else { continue }
                    status = request.refresh ? "正在刷新 · 已检查 \(checked) 篇" : "正在整理 · 已完成 \(count) 篇"
                    let suggestions = try await LibraryAI.classify(batch, categories: categories, settings: request.settings,
                                                                   refreshPublication: request.refresh)
                    try Task.checkCancellation()
                    var updated = entries
                    for (id, value) in suggestions {
                        if let current = updated[id] {
                            if request.refresh { updated[id] = current.fillingPublication(from: value) }
                        } else {
                            updated[id] = value
                        }
                        if updated[id] != entries[id] && (!request.refresh || updated[id]?.venue != nil) {
                            count += 1
                        }
                    }
                    checked += suggestions.count
                    missed += batch.count - suggestions.count
                    if updated != entries { try persist(updated) }
                }
                let result = request.refresh ? "已检查 \(checked) 篇，补全 \(count) 篇" : "已整理 \(count) 篇"
                status = missed > 0 ? "\(result)，\(missed) 篇待重试" : result
            }
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
