import Foundation

public struct PinnedProgram: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    /// Unix path to the .exe/.msi/.bat/.lnk.
    public var path: String
    public var arguments: [String]
    public var id: String { path }

    public init(name: String, path: String, arguments: [String] = []) {
        self.name = name
        self.path = path
        self.arguments = arguments
    }
}

public struct BottleConfig: Codable, Sendable, Equatable {
    public var windowsVersion: String = "win10"
    public var graphics: GraphicsBackend = .auto
    /// Name of a runtime under runtimes/ (nil = primary).
    public var runtime: String? = nil
    public var retina: Bool = false
    public var msync: Bool = true
    public var metalHUD: Bool = false
    public var debugLog: Bool = false
    public var environment: [String: String] = [:]
    public var pinned: [PinnedProgram] = []
    /// Extra arguments for steam.exe (Steam bottle only).
    public var steamArguments: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case windowsVersion, graphics, runtime, retina, msync, metalHUD, debugLog, environment, pinned, steamArguments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BottleConfig()
        windowsVersion = try c.decodeIfPresent(String.self, forKey: .windowsVersion) ?? d.windowsVersion
        graphics = (try? c.decodeIfPresent(GraphicsBackend.self, forKey: .graphics)) ?? d.graphics
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
        retina = try c.decodeIfPresent(Bool.self, forKey: .retina) ?? d.retina
        msync = try c.decodeIfPresent(Bool.self, forKey: .msync) ?? d.msync
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? d.metalHUD
        debugLog = try c.decodeIfPresent(Bool.self, forKey: .debugLog) ?? d.debugLog
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? d.environment
        pinned = try c.decodeIfPresent([PinnedProgram].self, forKey: .pinned) ?? d.pinned
        steamArguments = try c.decodeIfPresent([String].self, forKey: .steamArguments) ?? d.steamArguments
    }

    public static let windowsVersions: [(id: String, title: String)] = [
        ("win11", "Windows 11"), ("win10", "Windows 10"), ("win81", "Windows 8.1"),
        ("win7", "Windows 7"), ("winxp64", "Windows XP"),
    ]
}

public struct Bottle: Identifiable, Hashable, Sendable {
    public let name: String
    public let url: URL
    public var config: BottleConfig
    public var id: String { name }

    public static func == (a: Bottle, b: Bottle) -> Bool { a.name == b.name && a.config == b.config }
    public func hash(into h: inout Hasher) { h.combine(name) }

    public var driveC: URL { url.appendingPathComponent("drive_c", isDirectory: true) }
    public var system32: URL { driveC.appendingPathComponent("windows/system32", isDirectory: true) }
    public var syswow64: URL { driveC.appendingPathComponent("windows/syswow64", isDirectory: true) }
    public var configURL: URL { url.appendingPathComponent("cask-bottle.json") }
    public var logURL: URL { Log.file(for: name) }
    public var isInitialized: Bool { FS.exists(url.appendingPathComponent("system.reg")) }

    public var runtime: WineRuntime? {
        if let name = config.runtime, let r = RuntimeManager.find(name) { return r }
        return RuntimeManager.primary
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    /// Converts a Windows path like `C:\Games\a.exe` to a Unix path inside this bottle.
    public func unixPath(forWindows path: String) -> URL {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        if p.count >= 2, p[p.index(after: p.startIndex)] == ":" {
            let drive = p.prefix(1).lowercased()
            p.removeFirst(2)
            return url.appendingPathComponent("dosdevices/\(drive):").appendingPathComponent(p)
        }
        return URL(fileURLWithPath: p)
    }
}

public enum BottleManager {
    public static func list() -> [Bottle] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: CaskPaths.bottles, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { FS.isDirectory($0) && !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { load($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func get(_ name: String) -> Bottle? {
        load(CaskPaths.bottles.appendingPathComponent(name, isDirectory: true))
    }

    static func load(_ dir: URL) -> Bottle? {
        guard FS.isDirectory(dir) else { return nil }
        var config = BottleConfig()
        if let data = try? Data(contentsOf: dir.appendingPathComponent("cask-bottle.json")),
           let decoded = try? JSONDecoder().decode(BottleConfig.self, from: data) {
            config = decoded
        }
        return Bottle(name: dir.lastPathComponent, url: dir, config: config)
    }

    public static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_.()"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "Bottle" : cleaned
    }

    /// Creates and boots a new Wine prefix.
    @discardableResult
    public static func create(_ rawName: String, config: BottleConfig = BottleConfig(), progress: Progress? = nil) throws -> Bottle {
        try CaskPaths.ensure()
        let name = sanitize(rawName)
        let dir = CaskPaths.bottles.appendingPathComponent(name, isDirectory: true)
        if FS.exists(dir) { throw CaskError("A bottle named “\(name)” already exists") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bottle = Bottle(name: name, url: dir, config: config)
        try bottle.save()
        do {
            try initialize(bottle, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return bottle
    }

    /// Runs wineboot and applies the bottle's registry settings.
    public static func initialize(_ bottle: Bottle, progress: Progress? = nil) throws {
        progress?("Setting up Windows in “\(bottle.name)” (first boot takes a minute)…")
        try Wine.run(bottle, ["wineboot", "--init"], wait: true)
        try Wine.waitForServer(bottle)
        try applySettings(bottle, progress: progress)
    }

    /// Pushes Windows version and Retina mode into the prefix registry.
    public static func applySettings(_ bottle: Bottle, progress: Progress? = nil) throws {
        progress?("Applying settings…")
        try Wine.run(bottle, ["winecfg", "-v", bottle.config.windowsVersion], wait: true)
        try Wine.regAdd(bottle, key: #"HKCU\Software\Wine\Mac Driver"#, value: "RetinaMode", data: bottle.config.retina ? "y" : "n")
        try Wine.waitForServer(bottle)
    }

    /// Moves the bottle to the Trash (recoverable).
    public static func trash(_ bottle: Bottle) throws {
        try? Wine.killAll(bottle)
        try FileManager.default.trashItem(at: bottle.url, resultingItemURL: nil)
    }

    /// Finds Windows programs inside a bottle (Program Files + Desktop), skipping installers and helpers.
    public static func discoverPrograms(in bottle: Bottle, limit: Int = 200) -> [PinnedProgram] {
        let skip = ["unins", "uninstall", "setup", "install", "redist", "vcredist", "dxsetup", "crash", "helper",
                    "update", "report", "launcherpatcher", "steamerrorreporter", "steamservice", "steamwebhelper",
                    "dotnet", "directx", "cefsharp", "createdump", "iexplore", "wordpad", "notepad", "wmplayer"]
        let roots = ["Program Files", "Program Files (x86)", "users"].map { bottle.driveC.appendingPathComponent($0) }
        var found: [PinnedProgram] = []
        for root in roots where FS.exists(root) {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e {
                if e.level > 5 { e.skipDescendants(); continue }
                let ext = url.pathExtension.lowercased()
                guard ext == "exe" || (ext == "lnk" && url.path.contains("/Desktop/")) else { continue }
                let base = url.deletingPathExtension().lastPathComponent
                let lower = base.lowercased()
                if skip.contains(where: { lower.contains($0) }) { continue }
                if url.path.contains("/windows/") || url.path.contains("/Internet Explorer/") || url.path.contains("/Windows NT/") { continue }
                found.append(PinnedProgram(name: base, path: url.path))
                if found.count >= limit { return found }
            }
        }
        return found
    }
}
