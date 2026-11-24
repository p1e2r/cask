import AppKit
import CaskKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case setup
    case bottle(String)
}

@Observable
@MainActor
final class AppModel {
    var bottles: [Bottle] = []
    var runtimes: [WineRuntime] = []
    var rosetta = true
    var hasDXMT = false
    var hasDXVK = false
    var hasD3DMetal = false
    var hasVKD3D = false
    /// nil when the free DirectX 12 stack can run on this Mac.
    var kosmicUnavailable: String?
    var steamInstalled = false
    var dxmtVersion: String?
    var dxvkVersion: String?

    var selection: SidebarItem? = .setup
    /// Status line of the background job in progress (nil = idle).
    var busy: String?
    private var jobID = 0
    var lastError: String?
    /// Windows files opened in Finder ("Open With → Cask"), waiting for a bottle choice.
    var pendingOpen: [URL] = []

    var hasWine: Bool { !runtimes.isEmpty }
    var isReady: Bool { hasWine && rosetta }

    init() {
        try? CaskPaths.ensure()
        refresh()
        if hasWine { selection = bottles.first.map { .bottle($0.name) } ?? .setup }
    }

    func refresh() {
        bottles = BottleManager.list()
        runtimes = RuntimeManager.installed()
        rosetta = RuntimeManager.rosettaInstalled()
        hasDXMT = Components.hasDXMT
        hasDXVK = Components.hasDXVK
        dxmtVersion = Components.version(of: Components.dxmtDir)
        dxvkVersion = Components.version(of: Components.dxvkDir)
        hasD3DMetal = RuntimeManager.find(RuntimeManager.d3dMetalName)?.hasD3DMetal == true
        steamInstalled = WindowsSteam.isInstalled
        hasVKD3D = Components.hasVKD3D
        kosmicUnavailable = Components.kosmicKrispUnavailableReason
    }

    func bottle(named name: String) -> Bottle? { bottles.first { $0.name == name } }

    /// Runs blocking/async engine work off the main thread with a status line.
    func perform(_ title: String, _ work: @escaping @Sendable (_ progress: @escaping ProgressHandler) async throws -> Void) {
        guard busy == nil else {
            lastError = "Wait for “\(busy ?? "")” to finish first."
            return
        }
        busy = title
        jobID += 1
        let id = jobID
        let report: ProgressHandler = { line in
            Task { @MainActor in if self.jobID == id && self.busy != nil { self.busy = line } }
        }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try await work(report) }.value
            } catch {
                self.lastError = error.localizedDescription
            }
            self.busy = nil
            self.jobID += 1
            self.refresh()
        }
    }

    // MARK: Setup

    func setUpEverything() {
        perform("Setting up…") { p in
            if RuntimeManager.primary == nil { try await RuntimeManager.installWine(progress: p) }
            if !Components.hasDXMT { try? await Components.installDXMT(progress: p) }
            if !Components.hasDXVK { try? await Components.installDXVK(progress: p) }
            if Components.kosmicKrispUnavailableReason == nil && !Components.hasVKD3D {
                try await Components.installKosmicKrisp(progress: p)
            }
        }
    }

    func installWine() { perform("Installing Wine…") { p in try await RuntimeManager.installWine(progress: p) } }
    func installDXMT() { perform("Installing DXMT…") { p in try await Components.installDXMT(progress: p) } }
    func installDXVK() { perform("Installing DXVK…") { p in try await Components.installDXVK(progress: p) } }
    func installVKD3D() { perform("Installing free DirectX 12…") { p in try await Components.installKosmicKrisp(progress: p) } }
    func installRosetta() { perform("Installing Rosetta 2…") { _ in try RuntimeManager.installRosetta() } }

    func importD3DMetal() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Game Porting Toolkit .dmg (or its mounted volume) from developer.apple.com"
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.diskImage, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importGPTK(url)
    }

    /// Opens Apple's GPTK page and imports the .dmg as soon as it lands in ~/Downloads.
    var waitingForGPTK = false

    func getGPTK() {
        if let found = RuntimeManager.findGPTKDownload() {
            importGPTK(found)
            return
        }
        NSWorkspace.shared.open(RuntimeManager.gptkPage)
        guard !waitingForGPTK else { return }
        waitingForGPTK = true
        Task {
            // Poll for up to 45 minutes; import once the file size stops changing.
            var lastSize: Int64 = -1
            for _ in 0..<900 {
                try? await Task.sleep(for: .seconds(3))
                guard waitingForGPTK else { return }
                guard let url = RuntimeManager.findGPTKDownload() else { continue }
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
                if size > 0 && size == lastSize {
                    waitingForGPTK = false
                    importGPTK(url)
                    return
                }
                lastSize = size
            }
            waitingForGPTK = false
        }
    }

    func cancelGPTKWait() { waitingForGPTK = false }

    private func importGPTK(_ url: URL) {
        perform("Importing D3DMetal from \(url.lastPathComponent)…") { p in
            try RuntimeManager.importD3DMetal(from: url, progress: p)
        }
    }

    func installSteam() {
        perform("Installing Windows Steam…") { p in try await WindowsSteam.install(progress: p) }
        selection = .bottle(WindowsSteam.bottleName)
    }

    func openSteam() {
        perform("Starting Windows Steam…") { _ in try WindowsSteam.launch() }
    }

    // MARK: Bottles

    func createBottle(_ name: String, windowsVersion: String, graphics: GraphicsBackend) {
        var config = BottleConfig()
        config.windowsVersion = windowsVersion
        config.graphics = graphics
        let clean = BottleManager.sanitize(name)
        perform("Creating “\(clean)”…") { p in try BottleManager.create(clean, config: config, progress: p) }
        selection = .bottle(clean)
    }

    func update(_ bottle: Bottle, config: BottleConfig) {
        var updated = bottle
        let needsRegistry = bottle.config.windowsVersion != config.windowsVersion || bottle.config.retina != config.retina
        updated.config = config
        do { try updated.save() } catch { lastError = error.localizedDescription }
        if let i = bottles.firstIndex(where: { $0.name == bottle.name }) { bottles[i] = updated }
        if needsRegistry {
            perform("Applying settings to “\(bottle.name)”…") { p in try BottleManager.applySettings(updated, progress: p) }
        }
    }

    func trash(_ bottle: Bottle) {
        do {
            try BottleManager.trash(bottle)
            selection = .setup
        } catch { lastError = error.localizedDescription }
        refresh()
    }

    func launch(_ program: URL, arguments: [String] = [], in bottle: Bottle) {
        let b = bottle
        Task.detached {
            do { try Wine.launch(program, arguments: arguments, in: b) } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    func chooseAndRun(in bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.message = "Choose a Windows program or installer"
        panel.directoryURL = bottle.driveC
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        launch(url, in: bottle)
    }

    func pin(_ program: PinnedProgram, in bottle: Bottle) {
        var config = bottle.config
        guard !config.pinned.contains(where: { $0.path == program.path }) else { return }
        config.pinned.append(program)
        update(bottle, config: config)
    }

    func unpin(_ program: PinnedProgram, in bottle: Bottle) {
        var config = bottle.config
        config.pinned.removeAll { $0.path == program.path }
        update(bottle, config: config)
    }

    func openTool(_ tool: Wine.Tool, in bottle: Bottle) {
        let b = bottle
        Task.detached {
            do { try Wine.open(tool, in: b) } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    func killAll(_ bottle: Bottle) {
        let b = bottle
        Task.detached { try? Wine.killAll(b) }
    }

    // MARK: Helpers

    /// The CLI inside the app bundle, for Steam's launch options.
    var cliPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cask").path }
    var steamLaunchOption: String { "\"\(cliPath)\" %command%" }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Symlinks the CLI to /usr/local/bin/cask (asks for an admin password via macOS).
    func installCommandLineTool() {
        let script = "do shell script \"mkdir -p /usr/local/bin && ln -sf '\(cliPath)' /usr/local/bin/cask\" with administrator privileges"
        perform("Installing the cask command…") { _ in
            try Shell.run("/usr/bin/osascript", ["-e", script])
        }
    }
}
