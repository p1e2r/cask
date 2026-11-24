import CaskKit
import Foundation

@main
@MainActor
enum CaskCLI {
    static let version = "0.1.0"
    static let env = ProcessInfo.processInfo.environment
    static var args = Array(CommandLine.arguments.dropFirst())
    nonisolated static let cliLog = Log.file(for: "cli")

    nonisolated static func say(_ line: String) {
        print(line)
        Log.append(line, to: cliLog)
    }

    nonisolated static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("cask: \(message)\n".utf8))
        Log.append("error: \(message)", to: cliLog)
        exit(1)
    }

    /// macOS notification; used in Steam mode where there is no terminal to print to.
    nonisolated static func notify(_ text: String) {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = try? Shell.run("/usr/bin/osascript", ["-e", "display notification \"\(escaped)\" with title \"Cask\""], check: false)
    }

    nonisolated static let progress: Progress = { line in CaskCLI.say(line) }

    static func takeOption(_ names: [String]) -> String? {
        guard let i = args.firstIndex(where: { names.contains($0) }), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return value
    }

    static func bottle(named name: String?) -> Bottle {
        if let name {
            guard let b = BottleManager.get(name) else { fail("no bottle named “\(name)”. See `cask bottles`.") }
            return b
        }
        if let b = BottleManager.get("Default") { return b }
        do { return try BottleManager.create("Default", progress: progress) } catch { fail("\(error)") }
    }

    static func ensureRuntime(quietNotify: Bool) async {
        guard RuntimeManager.primary == nil else { return }
        if quietNotify { notify("First run: downloading Wine…") }
        do { try await RuntimeManager.installWine(progress: progress) } catch { fail("couldn't install Wine: \(error)") }
    }

    static let usage = """
    cask \(version) — run Windows games and apps on macOS (free, MIT)

    STEAM (Mac Steam → Properties → Launch Options):
      "/Applications/Cask.app/Contents/Helpers/cask" %command%
          Mac Steam hands Cask the game; Cask starts the *Windows* build through
          Windows Steam in the "Steam" bottle (downloading it there the first time).
          If %command% is already a .exe it is run directly.

    COMMANDS:
      cask setup                       Install Wine, DXMT and DXVK (checks Rosetta)
      cask run [-b BOTTLE] [-g GFX] PROGRAM [ARGS…]
                                       Run a .exe/.msi/.bat/.lnk (GFX: auto, wined3d, dxmt, dxvk, d3dmetal)
      cask bottles                     List bottles
      cask create NAME                 Create a bottle
      cask steam install               Install Windows Steam into the "Steam" bottle
      cask steam [ARGS…]               Open Windows Steam
      cask tool TOOL [-b BOTTLE]       winecfg, regedit, taskmgr, explorer, wineconsole, control
      cask kill [-b BOTTLE]            Stop everything running in a bottle
      cask import-d3dmetal [PATH]      Import D3DMetal from your GPTK .dmg (finds it in Downloads)
      cask status                      Show what's installed

    ENVIRONMENT:
      CASK_BOTTLE   bottle for %command% .exe launches     CASK_GRAPHICS  force a backend
      CASK_HOME     data folder (default ~/Library/Application Support/Cask)
    """

    static func printStatus() {
        let runtimes = RuntimeManager.installed()
        say("Rosetta 2:  \(RuntimeManager.rosettaInstalled() ? "installed" : "MISSING (softwareupdate --install-rosetta)")")
        say("Wine:       \(runtimes.isEmpty ? "not installed (cask setup)" : runtimes.map { "\($0.name) \($0.version)" }.joined(separator: ", "))")
        say("DXMT:       \(Components.hasDXMT ? (Components.version(of: Components.dxmtDir) ?? "installed") : "not installed")")
        say("DXVK:       \(Components.hasDXVK ? (Components.version(of: Components.dxvkDir) ?? "installed") : "not installed")")
        say("D3DMetal:   \(RuntimeManager.find(RuntimeManager.d3dMetalName)?.hasD3DMetal == true ? "imported" : "not imported")")
        say("Win Steam:  \(WindowsSteam.isInstalled ? "installed" : "not installed")")
        say("Bottles:    \(BottleManager.list().map(\.name).joined(separator: ", "))")
    }

    static let windowsExtensions: Set<String> = ["exe", "msi", "bat", "cmd", "lnk", "com"]

    /// Steam `%command%` mode.
    static func steamMode() async {
        let appID = [env["SteamAppId"], env["SteamGameId"]].compactMap { $0 }.first { !$0.isEmpty && $0 != "0" }
        let program = URL(fileURLWithPath: args[0])
        Log.append("steam mode app=\(appID ?? "?") argv=\(args.joined(separator: " "))", to: cliLog)
        await ensureRuntime(quietNotify: true)

        // Already a Windows program (e.g. a non-Steam shortcut to a .exe): run it directly.
        if windowsExtensions.contains(program.pathExtension.lowercased()) {
            let b = bottle(named: env["CASK_BOTTLE"] ?? (WindowsSteam.isInstalled ? WindowsSteam.bottleName : nil))
            let gfx = env["CASK_GRAPHICS"].flatMap(GraphicsBackend.init(rawValue:))
            do {
                let result = try Wine.launch(program, arguments: Array(args.dropFirst()), in: b, backend: gfx, wait: true)
                exit(result.status)
            } catch { notify("\(error)"); fail("\(error)") }
        }

        // A Mac build (often a dead 32-bit one, like Portal's): hand the app ID to Windows Steam,
        // which runs — and on first launch downloads — the Windows version.
        guard let appID else {
            fail("Steam didn't pass an app ID (SteamAppId). Use `cask %command%` in Mac Steam's launch options.")
        }
        do {
            if !WindowsSteam.isInstalled {
                notify("First run: installing Windows Steam (a few minutes). Sign in when it opens.")
                try await WindowsSteam.install(progress: progress)
            }
            if !WindowsSteam.isGameInstalled(appID) {
                notify("Windows Steam will ask to install this game — click Install, it starts when done.")
            }
            try WindowsSteam.launchGame(appID, detach: true)
            say("Handed app \(appID) to Windows Steam")
        } catch {
            notify("\(error)")
            fail("\(error)")
        }
    }


    static func main() async {
        guard let command = args.first else {
            print(usage)
            exit(0)
        }

        switch command {
        case "-h", "--help", "help":
            print(usage)

        case "-v", "--version", "version":
            print("cask \(version)")

        case "status":
            printStatus()

        case "setup":
            if !RuntimeManager.rosettaInstalled() {
                say("Rosetta 2 is required for Wine. Install it with:\n  softwareupdate --install-rosetta")
            }
            do {
                try await RuntimeManager.installWine(progress: progress)
                try await Components.installDXMT(progress: progress)
                try await Components.installDXVK(progress: progress)
                say("Done. Optional: `cask import-d3dmetal <GPTK.dmg>` for DirectX 12, `cask steam install` for Windows Steam.")
            } catch { fail("\(error)") }

        case "bottles":
            let bottles = BottleManager.list()
            if bottles.isEmpty { say("No bottles yet. `cask create NAME`") }
            for b in bottles { say("\(b.name)\t\(b.config.windowsVersion)\t\(b.config.graphics.rawValue)\t\(b.url.path)") }

        case "create":
            guard args.count >= 2 else { fail("usage: cask create NAME") }
            await ensureRuntime(quietNotify: false)
            do {
                let b = try BottleManager.create(args.dropFirst().joined(separator: " "), progress: progress)
                say("Created bottle “\(b.name)”")
            } catch { fail("\(error)") }

        case "run":
            args.removeFirst()
            let name = takeOption(["-b", "--bottle"])
            let gfx = takeOption(["-g", "--graphics"]).map { raw -> GraphicsBackend in
                guard let g = GraphicsBackend(rawValue: raw) else { fail("unknown graphics backend \(raw)") }
                return g
            }
            guard let path = args.first else { fail("usage: cask run [-b BOTTLE] PROGRAM [ARGS…]") }
            await ensureRuntime(quietNotify: false)
            let b = bottle(named: name)
            let program = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: program.path) else { fail("\(program.path) doesn't exist") }
            do {
                let result = try Wine.launch(program, arguments: Array(args.dropFirst()), in: b, backend: gfx, wait: true)
                exit(result.status)
            } catch { fail("\(error)") }

        case "steam":
            args.removeFirst()
            await ensureRuntime(quietNotify: false)
            do {
                if args.first == "install" {
                    try await WindowsSteam.install(progress: progress)
                    say("Windows Steam is installed. Open it with `cask steam`.")
                } else {
                    if !WindowsSteam.isInstalled { try await WindowsSteam.install(progress: progress) }
                    try WindowsSteam.launch(arguments: args, detach: true)
                    say("Windows Steam is starting…")
                }
            } catch { fail("\(error)") }

        case "tool":
            args.removeFirst()
            let name = takeOption(["-b", "--bottle"])
            guard let raw = args.first, let tool = Wine.Tool(rawValue: raw == "cmd" ? "wineconsole" : raw) else {
                fail("usage: cask tool winecfg|regedit|taskmgr|explorer|wineconsole|control [-b BOTTLE]")
            }
            do { try Wine.open(tool, in: bottle(named: name)) } catch { fail("\(error)") }

        case "kill":
            args.removeFirst()
            let name = takeOption(["-b", "--bottle"])
            let targets = name == nil ? BottleManager.list() : [bottle(named: name)]
            for b in targets { try? Wine.killAll(b) }
            say("Stopped \(targets.map(\.name).joined(separator: ", "))")

        case "import-d3dmetal":
            let source: URL
            if args.count >= 2 {
                source = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
            } else if let found = RuntimeManager.findGPTKDownload() {
                say("Using \(found.lastPathComponent) from Downloads")
                source = found
            } else {
                _ = try? Shell.run("/usr/bin/open", [RuntimeManager.gptkPage.absoluteString], check: false)
                fail("download the Game Porting Toolkit (opened in your browser, needs an Apple ID), then run this again")
            }
            do { try RuntimeManager.importD3DMetal(from: source, progress: progress) } catch { fail("\(error)") }

        default:
            // Anything that's a path is treated as Steam's %command%.
            if command.hasPrefix("/") || command.contains(".") {
                await steamMode()
            } else {
                fail("unknown command “\(command)”. Try `cask --help`.")
            }
        }

    }
}
