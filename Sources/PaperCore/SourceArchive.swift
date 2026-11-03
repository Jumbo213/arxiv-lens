import Foundation

enum SourceArchive {
    static func extract(_ archive: URL, to destination: URL, workspace: URL) async throws {
        let fm = FileManager.default
        let log = workspace.appendingPathComponent("archive.log")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let listing = try await LocalTool.run("/usr/bin/tar", ["-tvf", archive.path], in: destination,
                                              log: log, writable: workspace, limitKB: 8192)
        if listing.status == 0 {
            let manifest = try String(contentsOf: log, encoding: .utf8)
            var bytes: Int64 = 0
            var count = 0
            for line in manifest.split(separator: "\n") {
                count += 1
                let columns = line.split(maxSplits: 8, whereSeparator: \.isWhitespace)
                guard columns.count == 9, ["-", "d"].contains(columns[0].first),
                      let size = Int64(columns[4]), size >= 0, size <= 256 * 1024 * 1024 else {
                    throw LensError("源码压缩包含有链接、特殊文件或过大的成员。")
                }
                let path = columns[8]
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                    throw LensError("源码压缩包含有不安全的路径。")
                }
                bytes += size
                guard count < 20_000, bytes < 512 * 1024 * 1024 else {
                    throw LensError("源码压缩包超过展开大小或文件数量限制。")
                }
            }
            guard count > 0 else { throw LensError("arXiv 返回了空源码包。") }
            let result = try await LocalTool.run(
                "/usr/bin/tar", ["--no-same-permissions", "--no-same-owner", "-xf", archive.path],
                in: destination, log: log, writable: workspace
            )
            guard result.status == 0 else { throw LensError("源码解包失败。\n\(result.tail())") }
            return
        }

        let file = destination.appendingPathComponent("paper.tex")
        let header = try FileHandle(forReadingFrom: archive)
        defer { try? header.close() }
        let signature = try header.read(upToCount: 2)
        if signature == Data([0x1f, 0x8b]) {
            let result = try await LocalTool.run("/usr/bin/gzip", ["-dc", archive.path], in: destination,
                                                 log: file, writable: workspace, limitKB: 8192)
            guard result.status == 0 else { throw LensError("无法读取压缩后的单文件 TeX 源码。") }
        } else {
            let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8 * 1024 * 1024 else { throw LensError("单文件 TeX 源码超过大小限制。") }
            try fm.copyItem(at: archive, to: file)
        }
        guard let content = try? String(contentsOf: file, encoding: .utf8),
              content.contains("\\documentclass") || content.contains("\\documentstyle") else {
            throw LensError("这篇论文没有可识别的 LaTeX 源码，可能只提交了 PDF。")
        }
    }
}
