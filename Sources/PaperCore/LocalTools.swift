import Darwin
import Foundation

struct ToolResult {
    let status: Int32
    let log: URL
    func tail() -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 16_384 ? end - 16_384 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

enum LocalTool {
    static func run(
        _ command: String, _ arguments: [String], in directory: URL, log: URL,
        writable: URL, tex: URL? = nil, timeout: TimeInterval = 120,
        limitKB: Int = 524_288
    ) async throws -> ToolResult {
        let process = Process()
        let fm = FileManager.default
        let directory = directory.resolvingSymlinksInPath()
        let writable = try writable.path.withCString { path -> URL in
            guard let resolved = realpath(path, nil) else { throw LensError("无法定位 TeX 工作目录。") }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
        let tmp = writable.appendingPathComponent("tmp", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let roots = ["/System", "/usr", "/bin", "/sbin", "/Library/Fonts", writable.path]
            + (tex.map { [$0.path, texTree($0).path] } ?? [])
        func literal(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let reads = Set(roots).sorted().map { "(subpath \(literal($0)))" }.joined(separator: " ")
        let writeRoots = tex == nil ? [writable] : [tmp, writable.appendingPathComponent("build")]
        let writes = writeRoots.map { "(subpath \(literal($0.path)))" }.joined(separator: " ")
        let profile = """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-read-data)
        (allow file-read-data (literal "/") \(reads) (literal "/dev/null") (literal "/dev/urandom"))
        (deny file-write*)
        (allow file-write* \(writes) (literal "/dev/null"))
        """
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, "/bin/sh", "-c",
                             "ulimit -f \"$1\"; shift; exec \"$@\"", "arxiv-lens",
                             String(limitKB * 2), command] + arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "PATH": ([tex?.path].compactMap { $0 } + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":"),
            "HOME": tmp.path, "TMPDIR": tmp.path, "TEXMFHOME": tmp.path,
            "TEXMFVAR": tmp.appendingPathComponent("texmf-var").path,
            "TEXMFCONFIG": tmp.appendingPathComponent("texmf-config").path,
            "openout_any": "p", "shell_escape": "f", "LC_ALL": "en_US.UTF-8"
        ]
        _ = fm.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        let start = Date()
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if Date().timeIntervalSince(start) > timeout {
                    throw LensError("本机工具运行超时：\(URL(fileURLWithPath: command).lastPathComponent)")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            // Foundation launches Process in its own process group on macOS.
            // Verify the group before signaling it so latexmk's child also stops.
            let pid = process.processIdentifier
            let group = getpgid(pid)
            if group == pid { kill(-pid, SIGKILL) }
            else if process.isRunning { kill(pid, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        return ToolResult(status: process.terminationStatus, log: log)
    }

    private static func texTree(_ bin: URL) -> URL {
        // TeX Live installs in <texmf root>/bin/<platform>. Avoid allowing
        // the parent of an arbitrary custom bin directory.
        let parent = bin.deletingLastPathComponent()
        let candidate = parent.deletingLastPathComponent()
        if parent.lastPathComponent == "bin",
           FileManager.default.fileExists(atPath: candidate.appendingPathComponent("texmf-dist").path) {
            return candidate
        }
        return bin
    }
}

public enum LocalTeX {
    public static func locate(_ preference: String) throws -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let custom = preference.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = ["/Library/TeX/texbin", home.appendingPathComponent(".local/bin").path,
                          home.appendingPathComponent("Library/TinyTeX/bin/universal-darwin").path,
                          "/opt/homebrew/bin", "/usr/local/bin"]
        if custom.isEmpty {
            let root = URL(fileURLWithPath: "/usr/local/texlive", isDirectory: true)
            let versions = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            candidates += versions.sorted { $0.path > $1.path }.map { $0.appendingPathComponent("bin/universal-darwin").path }
        } else {
            candidates = [(custom as NSString).expandingTildeInPath]
        }
        for directory in candidates {
            let bin = URL(fileURLWithPath: directory, isDirectory: true).resolvingSymlinksInPath()
            let xe = bin.appendingPathComponent("xelatex")
            if fm.isExecutableFile(atPath: xe.path) && fm.isExecutableFile(atPath: bin.appendingPathComponent("latexmk").path) {
                // TinyTeX shims can live in ~/.local/bin; use the real tools
                // directory while keeping the xelatex executable name.
                let resolved = xe.resolvingSymlinksInPath().deletingLastPathComponent()
                if fm.isExecutableFile(atPath: resolved.appendingPathComponent("latexmk").path) { return resolved }
                return bin
            }
        }
        throw LensError("未找到 latexmk 和 XeLaTeX。请安装 MacTeX 或 TinyTeX，或在设置中填写 TeX bin 目录。")
    }

    public static func check(_ preference: String) async throws -> String {
        let bin = try locate(preference)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await LocalTool.run(bin.appendingPathComponent("kpsewhich").path, ["xeCJK.sty"],
                                            in: folder, log: folder.appendingPathComponent("check.log"),
                                            writable: folder, tex: bin)
        guard result.status == 0, result.tail().contains("xeCJK.sty") else {
            throw LensError("TeX 缺少 xeCJK。TinyTeX 可运行 tlmgr install xecjk。\n\(result.tail())")
        }
        return bin.path
    }

    static func compile(root: URL, workspace: URL, bin: URL, log: URL) async throws -> URL {
        let relative = root.lastPathComponent
        let build = workspace.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let result = try await LocalTool.run(
            bin.appendingPathComponent("latexmk").path,
            ["-norc", "-xelatex", "-interaction=nonstopmode", "-halt-on-error", "-file-line-error",
             "-no-shell-escape", "-outdir=\(build.path)", "./\(relative)"],
            in: root.deletingLastPathComponent(), log: log, writable: workspace, tex: bin, timeout: 600
        )
        let pdf = build.appendingPathComponent(root.deletingPathExtension().lastPathComponent + ".pdf")
        guard result.status == 0, FileManager.default.fileExists(atPath: pdf.path) else {
            throw LensError("XeLaTeX 编译失败。\n\(result.tail())")
        }
        return pdf
    }
}
