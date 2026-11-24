import Foundation

/// Low-level Wine invocation for a bottle.
public enum Wine {
    /// Clean environment for Wine. Strips DYLD_* (Mac Steam injects its overlay dylib, which crashes Wine)
    /// and any inherited WINE* settings.
    public static func environment(
        for bottle: Bottle,
        runtime: WineRuntime,
        dllOverrides: [String] = [],
        extra: [String: String] = [:]
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("DYLD_") && !key.hasPrefix("WINE") && key != "LD_PRELOAD"
        }
        env["PATH"] = "\(runtime.bin.path):/usr/bin:/bin:/usr/sbin:/sbin"
        env["WINEPREFIX"] = bottle.url.path
        env["WINEDEBUG"] = bottle.config.debugLog ? "warn+all,fixme-all" : "-all"
        if bottle.config.msync {
            env["WINEMSYNC"] = "1"
            env["WINEESYNC"] = "1"
        }
        if bottle.config.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if !dllOverrides.isEmpty { env["WINEDLLOVERRIDES"] = dllOverrides.joined(separator: ";") }
        for (k, v) in extra { env[k] = v }
        for (k, v) in bottle.config.environment { env[k] = v }
        return env
    }

    static func requireRuntime(_ bottle: Bottle) throws -> WineRuntime {
        guard let runtime = bottle.runtime else {
            throw CaskError("Wine isn't installed yet. Run `cask setup` or open Cask → Setup.")
        }
        if !RuntimeManager.rosettaInstalled() {
            throw CaskError("Rosetta 2 is required. Install it from Cask → Setup, or run: softwareupdate --install-rosetta")
        }
        return runtime
    }

    /// Runs `wine <args>` in the bottle with no graphics setup (tools, wineboot, reg…).
    @discardableResult
    public static func run(_ bottle: Bottle, _ args: [String], cwd: URL? = nil, wait: Bool) throws -> Int32 {
        let runtime = try requireRuntime(bottle)
        let env = environment(for: bottle, runtime: runtime)
        Log.append("wine \(args.joined(separator: " "))", to: bottle.logURL)
        if wait {
            return try Shell.run(runtime.wine.path, args, environment: env, cwd: cwd, log: bottle.logURL, check: false).status
        }
        try Shell.spawn(runtime.wine.path, args, environment: env, cwd: cwd, log: bottle.logURL)
        return 0
    }

    public static func regAdd(_ bottle: Bottle, key: String, value: String?, data: String, type: String = "REG_SZ") throws {
        var args = ["reg", "add", key]
        if let value { args += ["/v", value] } else { args += ["/ve"] }
        args += ["/t", type, "/d", data, "/f"]
        try run(bottle, args, wait: true)
    }

    public static func waitForServer(_ bottle: Bottle) throws {
        let runtime = try requireRuntime(bottle)
        try Shell.run(runtime.wineserver.path, ["-w"], environment: environment(for: bottle, runtime: runtime), check: false)
    }

    /// Kills every Windows process in the bottle.
    public static func killAll(_ bottle: Bottle) throws {
        let runtime = try requireRuntime(bottle)
        try Shell.run(runtime.wineserver.path, ["-k"], environment: environment(for: bottle, runtime: runtime), check: false)
    }

    /// wine command line for a program file, by extension.
    static func command(for program: URL, arguments: [String]) -> [String] {
        switch program.pathExtension.lowercased() {
        case "msi": return ["msiexec", "/i", program.path] + arguments
        case "bat", "cmd": return ["cmd", "/c", program.path] + arguments
        case "lnk": return ["start", "/unix", program.path] + arguments
        default: return [program.path] + arguments
        }
    }

    /// Launches a Windows program with the bottle's graphics backend. Returns the backend used and,
    /// when waiting, the exit code.
    @discardableResult
    public static func launch(
        _ program: URL,
        arguments: [String] = [],
        in bottle: Bottle,
        backend override: GraphicsBackend? = nil,
        wait: Bool = false,
        extraEnvironment: [String: String] = [:]
    ) throws -> (backend: GraphicsBackend, status: Int32) {
        let runtime = try requireRuntime(bottle)
        let wanted = override ?? bottle.config.graphics
        let backend = Components.resolve(wanted, for: program, runtime: runtime)
        let setup = try Components.prepare(backend, bottle: bottle, runtime: runtime)
        var extra = setup.environment
        for (k, v) in extraEnvironment { extra[k] = v }
        let env = environment(for: bottle, runtime: setup.runtime, dllOverrides: setup.dllOverrides, extra: extra)
        let args = command(for: program, arguments: arguments)
        // Many games (Source engine included) expect to start in their own folder.
        let cwd = program.deletingLastPathComponent()
        Log.append("launch \(program.lastPathComponent) via \(setup.backend.rawValue) [\(setup.runtime.name)] \(arguments.joined(separator: " "))", to: bottle.logURL)
        if wait {
            let status = try Shell.run(setup.runtime.wine.path, args, environment: env, cwd: cwd, log: bottle.logURL, check: false).status
            return (setup.backend, status)
        }
        try Shell.spawn(setup.runtime.wine.path, args, environment: env, cwd: cwd, log: bottle.logURL)
        return (setup.backend, 0)
    }

    public enum Tool: String, CaseIterable, Sendable {
        case winecfg, regedit, taskmgr, explorer, cmd = "wineconsole", control

        public var title: String {
            switch self {
            case .winecfg: "Wine Configuration"
            case .regedit: "Registry Editor"
            case .taskmgr: "Task Manager"
            case .explorer: "File Explorer"
            case .cmd: "Command Prompt"
            case .control: "Control Panel"
            }
        }
        var args: [String] { self == .cmd ? ["wineconsole", "cmd"] : [rawValue] }
    }

    public static func open(_ tool: Tool, in bottle: Bottle) throws {
        try run(bottle, tool.args, wait: false)
    }
}
