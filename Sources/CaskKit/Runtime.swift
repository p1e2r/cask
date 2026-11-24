import Foundation

/// A Wine build Cask can run bottles with.
public struct WineRuntime: Hashable, Sendable, Identifiable {
    public let name: String
    public let root: URL
    public let wine: URL
    public var id: String { name }

    public var bin: URL { wine.deletingLastPathComponent() }
    public var wineserver: URL { bin.appendingPathComponent("wineserver") }
    /// `<prefix>/lib` — GPTK's redist/lib layout is merged here.
    public var lib: URL { bin.deletingLastPathComponent().appendingPathComponent("lib") }
    /// `<prefix>/lib/wine` — holds x86_64-windows, x86_64-unix, i386-windows.
    public var libWine: URL { lib.appendingPathComponent("wine") }

    public var hasD3DMetal: Bool {
        FS.exists(lib.appendingPathComponent("external/D3DMetal.framework"))
            || FS.exists(lib.appendingPathComponent("external/libd3dshared.dylib"))
    }

    public var version: String {
        let marker = root.appendingPathComponent(".cask-version")
        if let tag = try? String(contentsOf: marker, encoding: .utf8) { return tag.trimmingCharacters(in: .whitespacesAndNewlines) }
        return name
    }
}

public enum RuntimeManager {
    public static let defaultName = "wine"
    public static let d3dMetalName = "wine-d3dmetal"

    /// Finds the Wine launcher inside an extracted build (Gcenx bundles: `Wine Staging.app/Contents/Resources/wine/bin/wine`).
    public static func locateWine(in root: URL) -> URL? {
        let direct = ["bin/wine", "bin/wine64"].map { root.appendingPathComponent($0) }
        if let hit = direct.first(where: { FS.exists($0) }) { return hit }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        var fallback: URL?
        for case let url as URL in enumerator {
            guard url.deletingLastPathComponent().lastPathComponent == "bin" else { continue }
            if url.lastPathComponent == "wine" { return url }
            if url.lastPathComponent == "wine64" { fallback = url }
        }
        return fallback
    }

    public static func installed() -> [WineRuntime] {
        var result: [WineRuntime] = []
        let dirs = (try? FileManager.default.contentsOfDirectory(at: CaskPaths.runtimes, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where FS.isDirectory(dir) && !dir.lastPathComponent.hasPrefix(".") {
            if let wine = locateWine(in: dir) {
                result.append(WineRuntime(name: dir.lastPathComponent, root: dir, wine: wine))
            }
        }
        // Wine apps the user already installed by hand.
        for app in ["Wine Staging", "Wine Devel", "Wine Stable"] {
            let url = URL(fileURLWithPath: "/Applications/\(app).app")
            if FS.exists(url), let wine = locateWine(in: url.appendingPathComponent("Contents/Resources/wine")) {
                result.append(WineRuntime(name: app, root: url, wine: wine))
            }
        }
        return result
    }

    public static func find(_ name: String) -> WineRuntime? {
        installed().first { $0.name == name }
    }

    /// The runtime used when a bottle doesn't ask for anything special.
    public static var primary: WineRuntime? {
        find(defaultName) ?? installed().first { $0.name != d3dMetalName }
    }

    public static func rosettaInstalled() -> Bool {
        #if arch(arm64)
        let result = try? Shell.run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"], check: false)
        return result?.status == 0
        #else
        return true
        #endif
    }

    /// Installs Rosetta 2. Only call this after the user explicitly asked (it accepts Apple's Rosetta license).
    public static func installRosetta() throws {
        try Shell.run("/usr/sbin/softwareupdate", ["--install-rosetta", "--agree-to-license"])
    }

    /// Downloads the newest Gcenx WineHQ build (Staging preferred: it carries the macOS/Rosetta and Steam fixes).
    @discardableResult
    public static func installWine(progress: Progress? = nil) async throws -> WineRuntime {
        try CaskPaths.ensure()
        let dest = CaskPaths.runtimes.appendingPathComponent(defaultName)
        func archive(_ a: GitHubRelease.Asset) -> Bool { a.name.hasSuffix(".tar.xz") || a.name.hasSuffix(".tar.gz") }
        try await Downloader.installLatest(
            repo: "Gcenx/macOS_Wine_builds",
            preferences: [
                { archive($0) && $0.name.contains("staging") && $0.name.contains("osx64") },
                { archive($0) && $0.name.contains("staging") },
                { archive($0) && $0.name.contains("devel") },
                { archive($0) },
            ],
            into: dest,
            progress: progress
        )
        guard let wine = locateWine(in: dest) else { throw CaskError("Downloaded Wine, but couldn't find its wine binary") }
        progress?("Wine installed")
        // The old D3DMetal variant was cloned from the previous Wine; it must be re-imported.
        let stale = CaskPaths.runtimes.appendingPathComponent(d3dMetalName)
        if FS.exists(stale) { try? FileManager.default.removeItem(at: stale) }
        return WineRuntime(name: defaultName, root: dest, wine: wine)
    }

    /// Builds the `wine-d3dmetal` runtime: a copy of the primary runtime with Apple's Game Porting Toolkit
    /// `redist/lib` merged in. `source` may be the GPTK .dmg, a mounted volume, or any folder containing `redist`.
    /// D3DMetal can't be redistributed, so the user supplies their own download from developer.apple.com.
    @discardableResult
    public static func importD3DMetal(from source: URL, progress: Progress? = nil) throws -> WineRuntime {
        guard let base = find(defaultName) else { throw CaskError("Install Wine first") }
        var mounts: [String] = []
        defer { for m in mounts.reversed() { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", m, "-quiet"], check: false) } }

        func redist(in dir: URL, nesting: Int) throws -> URL? {
            if let redist = FS.findDirectory(named: "redist", under: dir, maxDepth: 3),
               FS.exists(redist.appendingPathComponent("lib")) {
                return redist.appendingPathComponent("lib")
            }
            guard nesting < 2 else { return nil }
            // Apple ships the evaluation environment as a .dmg inside the GPTK .dmg.
            let dmgs = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension.lowercased() == "dmg" }
            for dmg in dmgs {
                let mount = try attach(dmg)
                mounts.append(mount)
                if let hit = try redist(in: URL(fileURLWithPath: mount), nesting: nesting + 1) { return hit }
            }
            return nil
        }

        progress?("Looking for D3DMetal…")
        var root = source
        if source.pathExtension.lowercased() == "dmg" {
            let mount = try attach(source)
            mounts.append(mount)
            root = URL(fileURLWithPath: mount)
        }
        guard let redistLib = try redist(in: root, nesting: 0) else {
            throw CaskError("Couldn't find D3DMetal (redist/lib) in \(source.lastPathComponent). Pick the Game Porting Toolkit .dmg from developer.apple.com/games.")
        }

        progress?("Creating the D3DMetal runtime…")
        let dest = CaskPaths.runtimes.appendingPathComponent(d3dMetalName)
        if FS.exists(dest) { try FileManager.default.removeItem(at: dest) }
        // APFS clone first (instant, no extra disk), plain copy as a fallback.
        if (try? Shell.run("/bin/cp", ["-cR", base.root.path, dest.path])) == nil {
            try Shell.run("/bin/cp", ["-R", base.root.path, dest.path])
        }
        guard let wine = locateWine(in: dest) else { throw CaskError("Copy of Wine is missing its wine binary") }
        let runtime = WineRuntime(name: d3dMetalName, root: dest, wine: wine)
        try Shell.run("/usr/bin/ditto", [redistLib.path, runtime.lib.path])
        FS.stripQuarantine(dest)
        progress?("D3DMetal imported")
        return runtime
    }

    public static let gptkPage = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!

    /// Newest Game Porting Toolkit .dmg in ~/Downloads that has finished downloading.
    public static func findGPTKDownload() -> URL? {
        let downloads = CaskPaths.home.appendingPathComponent("Downloads")
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { url in
                let n = url.lastPathComponent.lowercased().replacingOccurrences(of: "_", with: " ")
                return url.pathExtension.lowercased() == "dmg"
                    && (n.contains("game porting toolkit") || n.contains("evaluation environment for windows games"))
            }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    private static func attach(_ dmg: URL) throws -> String {
        let out = try Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", dmg.path]).output
        for line in out.split(separator: "\n").reversed() {
            if let mount = line.split(separator: "\t").last?.trimmingCharacters(in: .whitespaces), mount.hasPrefix("/") {
                return mount
            }
        }
        throw CaskError("Couldn't mount \(dmg.lastPathComponent)")
    }
}
