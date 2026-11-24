import Foundation

/// Errors surfaced to the user (CLI prints them, the app shows them in an alert).
public struct CaskError: LocalizedError, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// ProgressHandler callback: a short human-readable status line.
public typealias ProgressHandler = @Sendable (String) -> Void

public enum CaskPaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Root of everything Cask stores. Override with CASK_HOME.
    public static var support: URL {
        if let custom = ProcessInfo.processInfo.environment["CASK_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/Cask", isDirectory: true)
    }

    public static var runtimes: URL { support.appendingPathComponent("runtimes", isDirectory: true) }
    public static var bottles: URL { support.appendingPathComponent("bottles", isDirectory: true) }
    public static var components: URL { support.appendingPathComponent("components", isDirectory: true) }
    public static var cache: URL { support.appendingPathComponent("cache", isDirectory: true) }
    public static var logs: URL { home.appendingPathComponent("Library/Logs/Cask", isDirectory: true) }

    public static func ensure() throws {
        for dir in [support, runtimes, bottles, components, cache, logs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
    }

    /// Runs a program to completion. If `log` is given, output is appended there instead of captured.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        cwd: URL? = nil,
        log: URL? = nil,
        check: Bool = true
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = FileHandle.nullDevice

        var output = ""
        if let log {
            let handle = try Log.handle(for: log)
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            try? handle.close()
        } else {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            output = String(decoding: data, as: UTF8.self)
        }

        let status = process.terminationStatus
        if check && status != 0 {
            let name = (executable as NSString).lastPathComponent
            let tail = output.split(separator: "\n").suffix(8).joined(separator: "\n")
            throw CaskError("\(name) \(arguments.prefix(3).joined(separator: " ")) failed (exit \(status))\(tail.isEmpty ? "" : ":\n" + tail)")
        }
        return Result(status: status, output: output)
    }

    /// Starts a program without waiting for it. Output goes to `log`.
    @discardableResult
    public static func spawn(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        cwd: URL? = nil,
        log: URL
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = FileHandle.nullDevice
        let handle = try Log.handle(for: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return process
    }
}

public enum Log {
    public static func file(for name: String) -> URL {
        CaskPaths.logs.appendingPathComponent("\(name).log")
    }

    static func handle(for url: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        return handle
    }

    public static func append(_ line: String, to url: URL) {
        guard let handle = try? handle(for: url) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        handle.write(Data("[cask \(stamp)] \(line)\n".utf8))
        try? handle.close()
    }
}

enum FS {
    static let fm = FileManager.default

    static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Replace `dest` with a copy of `src`.
    static func replace(_ dest: URL, with src: URL) throws {
        if exists(dest) { try fm.removeItem(at: dest) }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: src, to: dest)
    }

    /// First directory (breadth-first, bounded depth) whose last path component equals `name`.
    static func findDirectory(named name: String, under root: URL, maxDepth: Int = 6) -> URL? {
        var queue: [(URL, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for child in children where isDirectory(child) {
                if child.lastPathComponent == name { return child }
                if depth < maxDepth { queue.append((child, depth + 1)) }
            }
        }
        return nil
    }

    static func files(in dir: URL, withExtension ext: String) -> [URL] {
        ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == ext }
    }

    static func stripQuarantine(_ url: URL) {
        _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path], check: false)
    }
}
