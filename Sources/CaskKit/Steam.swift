import Foundation

/// Windows Steam running inside its own bottle. Windows games need it: their steam_api.dll
/// talks to a *Windows* Steam client, and it's what downloads the Windows build of a game.
public enum WindowsSteam {
    public static let bottleName = "Steam"
    static let setupURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!

    public static var bottle: Bottle? { BottleManager.get(bottleName) }

    public static func steamExe(in bottle: Bottle) -> URL? {
        ["Program Files (x86)/Steam/steam.exe", "Program Files/Steam/steam.exe"]
            .map { bottle.driveC.appendingPathComponent($0) }
            .first { FS.exists($0) }
    }

    public static var isInstalled: Bool {
        guard let bottle else { return false }
        return steamExe(in: bottle) != nil
    }

    public static func steamApps(in bottle: Bottle) -> URL? {
        steamExe(in: bottle)?.deletingLastPathComponent().appendingPathComponent("steamapps")
    }

    public static func isGameInstalled(_ appID: String) -> Bool {
        guard let bottle, let apps = steamApps(in: bottle) else { return false }
        return FS.exists(apps.appendingPathComponent("appmanifest_\(appID).acf"))
    }

    /// Creates the Steam bottle (if needed) and installs Windows Steam silently.
    @discardableResult
    public static func install(progress: ProgressHandler? = nil) async throws -> Bottle {
        let bottle: Bottle
        if let existing = self.bottle {
            bottle = existing
            if !bottle.isInitialized { try BottleManager.initialize(bottle, progress: progress) }
        } else {
            var config = BottleConfig()
            config.windowsVersion = "win10"
            bottle = try BottleManager.create(bottleName, config: config, progress: progress)
        }
        if steamExe(in: bottle) != nil { return bottle }

        let setup = CaskPaths.cache.appendingPathComponent("SteamSetup.exe")
        try await Downloader.download(setupURL, to: setup, progress: progress)
        progress?("Installing Windows Steam…")
        try Wine.run(bottle, [setup.path, "/S"], wait: true)
        try Wine.waitForServer(bottle)
        try? FileManager.default.removeItem(at: setup)
        guard steamExe(in: bottle) != nil else {
            throw CaskError("Steam's installer finished but steam.exe wasn't found. See the log: \(bottle.logURL.path)")
        }
        progress?("Windows Steam installed")
        return bottle
    }

    /// Writes the Steam bottle's graphics choice into the registry so it applies to every game Steam starts,
    /// while keeping Steam's own Chromium UI on Wine's built-in DLLs.
    static func applyGraphics(_ bottle: Bottle, runtime: WineRuntime) throws -> Components.Setup {
        // Steam starts games itself, so per-exe auto-detection can't run; Automatic means "DXMT/DXVK for
        // DX10/11 games if available". DX9 games (Portal, HL2…) never touch these DLLs and stay on WineD3D.
        var wanted = bottle.config.graphics
        if wanted == .auto { wanted = Components.hasDXMT ? .dxmt : Components.hasDXVK ? .dxvk : .wined3d }
        let backend = Components.resolve(wanted, for: nil, runtime: runtime)
        let setup = try Components.prepare(backend, bottle: bottle, runtime: runtime)

        let marker = bottle.url.appendingPathComponent(".cask-steam-graphics")
        let signature = "v2;" + setup.dllOverrides.joined(separator: ";")
        if (try? String(contentsOf: marker, encoding: .utf8)) == signature { return setup }

        let overridesKey = #"HKCU\Software\Wine\DllOverrides"#
        for entry in setup.dllOverrides {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let mode = parts[1] == "n,b" ? "native,builtin" : parts[1] == "b" ? "builtin" : parts[1]
            for dll in parts[0].split(separator: ",") {
                try Wine.regAdd(bottle, key: overridesKey, value: String(dll), data: mode)
            }
        }
        for exe in ["steam.exe", "steamwebhelper.exe", "steamwebhelper.real.exe"] {
            let key = #"HKCU\Software\Wine\AppDefaults\"# + exe + #"\DllOverrides"#
            for dll in ["dxgi", "d3d10core", "d3d11", "d3d12", "d3d12core"] {
                try Wine.regAdd(bottle, key: key, value: dll, data: "builtin")
            }
        }
        try? Data(signature.utf8).write(to: marker)
        return setup
    }

    /// Steam's UI fails under free Wine on macOS unless Chromium's GPU work runs in-process
    /// ("Unexpected Transport Error" 0x3008). Steam can't pass Chromium flags, so swap in Cask's wrapper,
    /// which starts the real helper with `webhelperArguments`. Re-applied on every launch because
    /// Steam updates overwrite steamwebhelper.exe. Empty arguments restore the original helper.
    public static func applyWebhelperFix(_ bottle: Bottle) throws {
        guard let steamDir = steamExe(in: bottle)?.deletingLastPathComponent() else { return }
        let cef = steamDir.appendingPathComponent("bin/cef")
        let helpers = (FileManager.default.enumerator(at: cef, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.lastPathComponent.lowercased() == "steamwebhelper.exe" }
        guard !helpers.isEmpty else { return }
        let enabled = !bottle.config.webhelperArguments.isEmpty

        guard let wrapperURL = CaskPaths.resource("cask-webhelper.exe"),
              let wrapper = try? Data(contentsOf: wrapperURL) else {
            if enabled { Log.append("webhelper fix: cask-webhelper.exe missing from the app bundle", to: bottle.logURL) }
            return
        }
        for helper in helpers {
            let dir = helper.deletingLastPathComponent()
            let real = dir.appendingPathComponent("steamwebhelper.real.exe")
            let isWrapper = (try? Data(contentsOf: helper)) == wrapper
            if enabled {
                if !isWrapper {
                    // Fresh helper (first run or Steam update): it becomes the real one.
                    if FS.exists(real) { try FileManager.default.removeItem(at: real) }
                    try FileManager.default.moveItem(at: helper, to: real)
                    try wrapper.write(to: helper)
                    Log.append("webhelper fix installed in \(dir.lastPathComponent)", to: bottle.logURL)
                }
                let args = bottle.config.webhelperArguments.joined(separator: " ")
                try Data(args.utf8).write(to: dir.appendingPathComponent("steamwebhelper.cask-args"))
            } else if isWrapper, FS.exists(real) {
                try FileManager.default.removeItem(at: helper)
                try FileManager.default.moveItem(at: real, to: helper)
                Log.append("webhelper fix removed in \(dir.lastPathComponent)", to: bottle.logURL)
            }
        }
    }

    /// Starts Windows Steam (optionally with extra arguments such as `-applaunch 400`).
    /// With `detach`, Steam outlives the calling process even if the caller is killed.
    public static func launch(arguments: [String] = [], detach: Bool = false) throws {
        guard let bottle, let exe = steamExe(in: bottle) else { throw CaskError("Windows Steam isn't installed. Run `cask steam install`.") }
        let runtime = try Wine.requireRuntime(bottle)
        let setup = try applyGraphics(bottle, runtime: runtime)
        do { try applyWebhelperFix(bottle) } catch { Log.append("webhelper fix failed: \(error)", to: bottle.logURL) }
        // Overrides live in the registry for this bottle; the env var would override AppDefaults.
        let env = Wine.environment(for: bottle, runtime: setup.runtime, extra: setup.environment)
        let args = [exe.path] + bottle.config.steamArguments + arguments
        Log.append("steam \(args.dropFirst().joined(separator: " "))", to: bottle.logURL)
        if detach {
            // nohup + background so Mac Steam ending our process doesn't take Windows Steam with it.
            let quoted = ([setup.runtime.wine.path] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            try Shell.run("/bin/sh", ["-c", "nohup \(quoted) >>'\(bottle.logURL.path)' 2>&1 &"],
                          environment: env, cwd: exe.deletingLastPathComponent())
        } else {
            try Shell.spawn(setup.runtime.wine.path, args, environment: env, cwd: exe.deletingLastPathComponent(), log: bottle.logURL)
        }
    }

    /// Asks Windows Steam to start (installing first, if needed) the Windows build of `appID`.
    public static func launchGame(_ appID: String, arguments: [String] = [], detach: Bool = true) throws {
        try launch(arguments: ["-applaunch", appID] + arguments, detach: detach)
    }
}
