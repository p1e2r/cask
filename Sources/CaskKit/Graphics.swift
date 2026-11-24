import Foundation

public enum GraphicsBackend: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Pick per program: DX9 and older → WineD3D, DX10/11 → DXMT (or DXVK), DX12 → D3DMetal.
    case auto
    /// Wine's built-in D3D → OpenGL. Handles DirectX 1–9 games like Portal and Half-Life 2.
    case wined3d
    /// DXMT: open-source D3D10/11 → Metal.
    case dxmt
    /// DXVK-macOS: D3D10/11 → Vulkan → MoltenVK → Metal.
    case dxvk
    /// Apple's D3DMetal (from your own Game Porting Toolkit download): D3D11/12 → Metal.
    case d3dmetal
    /// Proton's stack, free: vkd3d-proton (D3D12) + upstream DXVK (D3D10/11) on the KosmicKrisp
    /// Vulkan driver. Needs macOS 26+ on Apple Silicon.
    case vkd3d

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "Automatic"
        case .wined3d: "WineD3D (DirectX 1–9)"
        case .dxmt: "DXMT (DirectX 10/11 → Metal)"
        case .dxvk: "DXVK (DirectX 10/11 → Vulkan)"
        case .d3dmetal: "D3DMetal (DirectX 11/12, GPTK)"
        case .vkd3d: "VKD3D-Proton (DirectX 12, free · macOS 26+)"
        }
    }

    /// Backends that can be picked on this Mac (VKD3D is hidden below macOS 26).
    public static var available: [GraphicsBackend] {
        allCases.filter { $0 != .vkd3d || Components.kosmicKrispUnavailableReason == nil }
    }
}

public enum DirectXAPI: String, Sendable {
    case d3d12, d3d11, d3d10, d3d9, older
}

/// Downloadable translation layers (stored in components/).
public enum Components {
    public static var dxmtDir: URL { CaskPaths.components.appendingPathComponent("dxmt") }
    public static var dxvkDir: URL { CaskPaths.components.appendingPathComponent("dxvk") }

    public static var kosmicDir: URL { CaskPaths.components.appendingPathComponent("kosmickrisp") }
    public static var dxvkUpstreamDir: URL { CaskPaths.components.appendingPathComponent("dxvk-upstream") }
    public static var vkd3dDir: URL { CaskPaths.components.appendingPathComponent("vkd3d-proton") }
    static var kosmicICD: URL { kosmicDir.appendingPathComponent("kosmickrisp_icd.json") }

    public static var hasDXMT: Bool { dxmtWin64 != nil }
    public static var hasDXVK: Bool { dxvkWin64 != nil }

    static var dxmtWin64: URL? { FS.findDirectory(named: "x86_64-windows", under: dxmtDir) }
    static var dxmtWin32: URL? { FS.findDirectory(named: "i386-windows", under: dxmtDir) }
    static var dxmtUnix: URL? { FS.findDirectory(named: "x86_64-unix", under: dxmtDir) }
    static var dxvkWin64: URL? { FS.findDirectory(named: "x64", under: dxvkDir) }
    static var dxvkWin32: URL? { FS.findDirectory(named: "x32", under: dxvkDir) }
    static var dxvkUpWin64: URL? { FS.findDirectory(named: "x64", under: dxvkUpstreamDir) }
    static var dxvkUpWin32: URL? { FS.findDirectory(named: "x32", under: dxvkUpstreamDir) }
    static var vkd3dWin64: URL? { FS.findDirectory(named: "x64", under: vkd3dDir) }
    static var vkd3dWin32: URL? { FS.findDirectory(named: "x86", under: vkd3dDir) }

    /// nil when KosmicKrisp can run here; otherwise why not. KosmicKrisp is built on Metal 4.
    public static var kosmicKrispUnavailableReason: String? {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion < 26 {
            return "Needs macOS 26 or newer (this Mac has macOS \(v.majorVersion).\(v.minorVersion))"
        }
        if !isAppleSilicon { return "Needs an Apple Silicon Mac" }
        return nil
    }

    static var isAppleSilicon: Bool {
        #if os(macOS)
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        #else
        return false
        #endif
    }

    public static var hasKosmicKrisp: Bool {
        kosmicKrispUnavailableReason == nil && FS.exists(kosmicICD)
            && FS.exists(kosmicDir.appendingPathComponent("libvulkan.1.dylib"))
    }

    /// The whole free DX12 stack is ready.
    public static var hasVKD3D: Bool { hasKosmicKrisp && vkd3dWin64 != nil && dxvkUpWin64 != nil }

    public static func version(of dir: URL) -> String? {
        (try? String(contentsOf: dir.appendingPathComponent(".cask-version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func installDXMT(progress: ProgressHandler? = nil) async throws {
        try await Downloader.installLatest(
            repo: "3Shain/dxmt",
            preferences: [{ $0.name.hasSuffix(".tar.gz") && !$0.name.contains("debug") }, { $0.name.hasSuffix(".tar.gz") }, { $0.name.hasSuffix(".zip") }],
            into: dxmtDir, progress: progress)
        guard hasDXMT else { throw CaskError("DXMT download didn't contain x86_64-windows DLLs") }
        progress?("DXMT installed")
    }

    public static func installDXVK(progress: ProgressHandler? = nil) async throws {
        try await Downloader.installLatest(
            repo: "Gcenx/DXVK-macOS",
            preferences: [{ $0.name.hasSuffix(".tar.gz") && $0.name.contains("async") }, { $0.name.hasSuffix(".tar.gz") }],
            into: dxvkDir, progress: progress)
        guard hasDXVK else { throw CaskError("DXVK download didn't contain x64 DLLs") }
        progress?("DXVK installed")
    }

    static let vulkanSDKURL = URL(string: "https://sdk.lunarg.com/sdk/download/latest/mac/vulkan_sdk.zip")!

    /// Installs the free DirectX 12 stack: KosmicKrisp (taken from LunarG's open-source Vulkan SDK),
    /// upstream DXVK and vkd3d-proton.
    public static func installKosmicKrisp(progress: ProgressHandler? = nil) async throws {
        if let reason = kosmicKrispUnavailableReason { throw CaskError("KosmicKrisp: \(reason).") }
        try CaskPaths.ensure()
        if !FS.exists(kosmicICD) { try await installKosmicDriver(progress: progress) }

        try await Downloader.installLatest(
            repo: "doitsujin/dxvk",
            preferences: [{ $0.name.hasSuffix(".tar.gz") && !$0.name.contains("native") }],
            into: dxvkUpstreamDir, progress: progress)

        // vkd3d-proton ships .tar.zst; older macOS tar can't read zstd, so fall back to Cask's .tar.gz mirror.
        do {
            try await Downloader.installLatest(
                repo: "HansKristian-Work/vkd3d-proton",
                preferences: [{ $0.name.hasSuffix(".tar.zst") }, { $0.name.hasSuffix(".tar.gz") }],
                into: vkd3dDir, progress: progress)
        } catch {
            progress?("Using the vkd3d-proton mirror…")
            let mirror = URL(string: "https://github.com/p1e2r/cask/releases/download/components/vkd3d-proton.tar.gz")!
            let archive = CaskPaths.cache.appendingPathComponent("vkd3d-proton.tar.gz")
            try await Downloader.download(mirror, to: archive, progress: progress)
            if FS.exists(vkd3dDir) { try FileManager.default.removeItem(at: vkd3dDir) }
            try Downloader.extract(archive, into: vkd3dDir, progress: progress)
            try? FileManager.default.removeItem(at: archive)
        }
        guard hasVKD3D else { throw CaskError("The DirectX 12 stack downloaded but is incomplete. Try again from Setup.") }
        progress?("Free DirectX 12 (VKD3D-Proton + KosmicKrisp) installed")
    }

    private static func installKosmicDriver(progress: ProgressHandler?) async throws {
        let zip = CaskPaths.cache.appendingPathComponent("vulkan_sdk.zip")
        progress?("Downloading LunarG Vulkan SDK (for KosmicKrisp, a few hundred MB)…")
        try await Downloader.download(vulkanSDKURL, to: zip, progress: nil)
        let staging = CaskPaths.cache.appendingPathComponent("vulkan-sdk-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: zip)
        }
        progress?("Unpacking the Vulkan SDK…")
        try Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        FS.stripQuarantine(staging)

        // The SDK is a Qt installer app; run it headless into a private folder (copy_only=1 = no /usr/local changes).
        guard let installerApp = (FileManager.default.enumerator(at: staging, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .first(where: { $0.pathExtension == "app" }) else {
            throw CaskError("Vulkan SDK download didn't contain its installer")
        }
        let macOSDir = installerApp.appendingPathComponent("Contents/MacOS")
        guard let exe = (try? FileManager.default.contentsOfDirectory(at: macOSDir, includingPropertiesForKeys: nil))?.first else {
            throw CaskError("Vulkan SDK installer is missing its executable")
        }
        let root = staging.appendingPathComponent("sdk")
        progress?("Extracting KosmicKrisp from the Vulkan SDK…")
        try Shell.run(exe.path, ["--root", root.path, "--accept-licenses", "--default-answer",
                                 "--confirm-command", "install", "copy_only=1"])

        func find(_ name: String) -> URL? {
            (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .first { $0.lastPathComponent == name && !$0.path.contains("/iOS/") }
        }
        guard let driver = find("libvulkan_kosmickrisp.dylib") else {
            throw CaskError("This Vulkan SDK doesn't include KosmicKrisp")
        }
        guard let loader = find("libvulkan.1.dylib") else { throw CaskError("Vulkan loader not found in the SDK") }

        // Wine runs as Intel code under Rosetta, so the driver must contain x86_64.
        let archs = (try? Shell.run("/usr/bin/lipo", ["-archs", driver.path]).output) ?? ""
        guard archs.contains("x86_64") else {
            throw CaskError("LunarG's KosmicKrisp build is Apple-Silicon-only (\(archs.trimmingCharacters(in: .whitespacesAndNewlines))), but Wine runs as Intel code under Rosetta, so it can't load it yet. Use D3DMetal for DirectX 12 for now.")
        }

        if FS.exists(kosmicDir) { try FileManager.default.removeItem(at: kosmicDir) }
        try FileManager.default.createDirectory(at: kosmicDir, withIntermediateDirectories: true)
        let dylib = kosmicDir.appendingPathComponent("libvulkan_kosmickrisp.dylib")
        try FileManager.default.copyItem(at: driver.resolvingSymlinksInPath(), to: dylib)
        let loaderCopy = kosmicDir.appendingPathComponent("libvulkan.1.dylib")
        try FileManager.default.copyItem(at: loader.resolvingSymlinksInPath(), to: loaderCopy)
        // Wine may dlopen MoltenVK by name; point that name at the Vulkan loader so KosmicKrisp is used.
        try FileManager.default.createSymbolicLink(at: kosmicDir.appendingPathComponent("libMoltenVK.dylib"),
                                                   withDestinationURL: loaderCopy)
        let icd: [String: Any] = [
            "file_format_version": "1.0.1",
            "ICD": ["library_path": dylib.path, "api_version": "1.4.0", "is_portability_driver": false],
        ]
        try JSONSerialization.data(withJSONObject: icd, options: [.prettyPrinted]).write(to: kosmicICD)
        FS.stripQuarantine(kosmicDir)
    }

    /// Guesses which DirectX a program uses from the DLL names in its import table
    /// (and D3D12 runtime DLLs shipped next to it).
    public static func detectAPI(_ exe: URL) -> DirectXAPI {
        let dir = exe.deletingLastPathComponent()
        if FS.exists(dir.appendingPathComponent("D3D12/D3D12Core.dll")) { return .d3d12 }
        guard let data = try? Data(contentsOf: exe, options: .alwaysMapped) else { return .older }
        func has(_ name: String) -> Bool {
            [name, name.uppercased(), name.prefix(1).uppercased() + name.dropFirst(), name.replacingOccurrences(of: ".dll", with: ".DLL")]
                .contains { data.range(of: Data($0.utf8)) != nil }
        }
        if has("d3d12.dll") { return .d3d12 }
        if has("d3d11.dll") || has("dxgi.dll") { return .d3d11 }
        if has("d3d10.dll") || has("d3d10_1.dll") || has("d3d10core.dll") { return .d3d10 }
        if has("d3d9.dll") { return .d3d9 }
        return .older
    }

    /// Turns `.auto` into a concrete backend for `exe`, honoring what's installed.
    public static func resolve(_ backend: GraphicsBackend, for exe: URL?, runtime: WineRuntime?) -> GraphicsBackend {
        let d3dMetalReady = RuntimeManager.find(RuntimeManager.d3dMetalName)?.hasD3DMetal == true || runtime?.hasD3DMetal == true
        func modernFallback() -> GraphicsBackend { hasDXMT ? .dxmt : hasDXVK ? .dxvk : .wined3d }
        switch backend {
        case .auto:
            guard let exe else { return .wined3d }
            switch detectAPI(exe) {
            case .d3d12: return hasVKD3D ? .vkd3d : d3dMetalReady ? .d3dmetal : .wined3d
            case .d3d11, .d3d10: return modernFallback()
            case .d3d9, .older: return .wined3d
            }
        case .dxmt: return hasDXMT ? .dxmt : .wined3d
        case .dxvk: return hasDXVK ? .dxvk : .wined3d
        case .d3dmetal: return d3dMetalReady ? .d3dmetal : hasVKD3D ? .vkd3d : modernFallback()
        case .vkd3d: return hasVKD3D ? .vkd3d : d3dMetalReady ? .d3dmetal : modernFallback()
        case .wined3d: return .wined3d
        }
    }

    public struct Setup: Sendable {
        public var runtime: WineRuntime
        public var dllOverrides: [String]
        public var environment: [String: String]
        public var backend: GraphicsBackend
    }

    /// Copies the backend's DLLs into the bottle and returns the overrides/env needed to use it.
    public static func prepare(_ backend: GraphicsBackend, bottle: Bottle, runtime: WineRuntime) throws -> Setup {
        switch backend {
        case .auto, .wined3d:
            return Setup(runtime: runtime, dllOverrides: ["dxgi,d3d10core,d3d11,d3d12,d3d12core=b"], environment: [:], backend: .wined3d)

        case .dxmt:
            guard let win64 = dxmtWin64 else { throw CaskError("DXMT isn't installed") }
            try installDLLs(from: win64, into: bottle.system32)
            if let win32 = dxmtWin32 { try installDLLs(from: win32, into: bottle.syswow64) }
            // winemetal is DXMT's bridge into Metal; it lives next to Wine's own unix libraries.
            if let unix = dxmtUnix {
                for so in FS.files(in: unix, withExtension: "so") {
                    try FS.replace(runtime.libWine.appendingPathComponent("x86_64-unix/\(so.lastPathComponent)"), with: so)
                }
                let winemetal = win64.appendingPathComponent("winemetal.dll")
                if FS.exists(winemetal) {
                    try FS.replace(runtime.libWine.appendingPathComponent("x86_64-windows/winemetal.dll"), with: winemetal)
                }
            }
            return Setup(runtime: runtime, dllOverrides: ["dxgi,d3d10core,d3d11=n,b", "d3d12,d3d12core=b"], environment: [:], backend: .dxmt)

        case .dxvk:
            guard let win64 = dxvkWin64 else { throw CaskError("DXVK isn't installed") }
            try installDLLs(from: win64, into: bottle.system32)
            if let win32 = dxvkWin32 { try installDLLs(from: win32, into: bottle.syswow64) }
            return Setup(runtime: runtime, dllOverrides: ["d3d10core,d3d11=n,b", "dxgi,d3d12,d3d12core=b"],
                         environment: ["MVK_CONFIG_RESUME_LOST_DEVICE": "1", "DXVK_ASYNC": "1"], backend: .dxvk)

        case .vkd3d:
            guard hasVKD3D, let dxvk64 = dxvkUpWin64, let vk64 = vkd3dWin64 else {
                throw CaskError(kosmicKrispUnavailableReason.map { "VKD3D-Proton: \($0)." } ?? "Install free DirectX 12 in Cask → Setup first.")
            }
            // DXVK's dxgi/d3d11 and vkd3d-proton's d3d12 are designed to work together (Proton's stack).
            let dxvkDLLs = ["dxgi.dll", "d3d11.dll", "d3d10core.dll"]
            try installDLLs(from: dxvk64, into: bottle.system32, only: dxvkDLLs)
            if let dxvk32 = dxvkUpWin32 { try installDLLs(from: dxvk32, into: bottle.syswow64, only: dxvkDLLs) }
            try installDLLs(from: vk64, into: bottle.system32)
            if let vk32 = vkd3dWin32 { try installDLLs(from: vk32, into: bottle.syswow64) }
            return Setup(runtime: runtime, dllOverrides: ["dxgi,d3d10core,d3d11,d3d12,d3d12core=n,b"],
                         environment: [
                             "VK_DRIVER_FILES": kosmicICD.path,
                             "VK_ICD_FILENAMES": kosmicICD.path,
                             "DYLD_LIBRARY_PATH": kosmicDir.path,
                         ], backend: .vkd3d)

        case .d3dmetal:
            let metalRuntime = runtime.hasD3DMetal ? runtime : RuntimeManager.find(RuntimeManager.d3dMetalName)
            guard let metalRuntime, metalRuntime.hasD3DMetal else {
                throw CaskError("D3DMetal isn't imported. In Cask → Setup, import your Game Porting Toolkit .dmg.")
            }
            return Setup(runtime: metalRuntime, dllOverrides: ["dxgi,d3d10core,d3d11,d3d12,d3d12core=b"],
                         environment: ["D3DM_SUPPORT_DXR": "1"], backend: .d3dmetal)
        }
    }

    private static func installDLLs(from dir: URL, into dest: URL, only: [String]? = nil) throws {
        guard FS.exists(dest) else { return } // 64-bit-only prefix has no syswow64
        for dll in FS.files(in: dir, withExtension: "dll") where only?.contains(dll.lastPathComponent.lowercased()) ?? true {
            try FS.replace(dest.appendingPathComponent(dll.lastPathComponent), with: dll)
        }
    }
}
