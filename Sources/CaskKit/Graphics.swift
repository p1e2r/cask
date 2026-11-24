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

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "Automatic"
        case .wined3d: "WineD3D (DirectX 1–9)"
        case .dxmt: "DXMT (DirectX 10/11 → Metal)"
        case .dxvk: "DXVK (DirectX 10/11 → Vulkan)"
        case .d3dmetal: "D3DMetal (DirectX 11/12, GPTK)"
        }
    }
}

public enum DirectXAPI: String, Sendable {
    case d3d12, d3d11, d3d10, d3d9, older
}

/// Downloadable translation layers (stored in components/).
public enum Components {
    public static var dxmtDir: URL { CaskPaths.components.appendingPathComponent("dxmt") }
    public static var dxvkDir: URL { CaskPaths.components.appendingPathComponent("dxvk") }

    public static var hasDXMT: Bool { dxmtWin64 != nil }
    public static var hasDXVK: Bool { dxvkWin64 != nil }

    static var dxmtWin64: URL? { FS.findDirectory(named: "x86_64-windows", under: dxmtDir) }
    static var dxmtWin32: URL? { FS.findDirectory(named: "i386-windows", under: dxmtDir) }
    static var dxmtUnix: URL? { FS.findDirectory(named: "x86_64-unix", under: dxmtDir) }
    static var dxvkWin64: URL? { FS.findDirectory(named: "x64", under: dxvkDir) }
    static var dxvkWin32: URL? { FS.findDirectory(named: "x32", under: dxvkDir) }

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
            case .d3d12: return d3dMetalReady ? .d3dmetal : .wined3d
            case .d3d11, .d3d10: return modernFallback()
            case .d3d9, .older: return .wined3d
            }
        case .dxmt: return hasDXMT ? .dxmt : .wined3d
        case .dxvk: return hasDXVK ? .dxvk : .wined3d
        case .d3dmetal: return d3dMetalReady ? .d3dmetal : modernFallback()
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
            return Setup(runtime: runtime, dllOverrides: ["dxgi,d3d10core,d3d11=b"], environment: [:], backend: .wined3d)

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
            return Setup(runtime: runtime, dllOverrides: ["dxgi,d3d10core,d3d11=n,b"], environment: [:], backend: .dxmt)

        case .dxvk:
            guard let win64 = dxvkWin64 else { throw CaskError("DXVK isn't installed") }
            try installDLLs(from: win64, into: bottle.system32)
            if let win32 = dxvkWin32 { try installDLLs(from: win32, into: bottle.syswow64) }
            return Setup(runtime: runtime, dllOverrides: ["d3d10core,d3d11=n,b", "dxgi=b"],
                         environment: ["MVK_CONFIG_RESUME_LOST_DEVICE": "1", "DXVK_ASYNC": "1"], backend: .dxvk)

        case .d3dmetal:
            let metalRuntime = runtime.hasD3DMetal ? runtime : RuntimeManager.find(RuntimeManager.d3dMetalName)
            guard let metalRuntime, metalRuntime.hasD3DMetal else {
                throw CaskError("D3DMetal isn't imported. In Cask → Setup, import your Game Porting Toolkit .dmg.")
            }
            return Setup(runtime: metalRuntime, dllOverrides: ["dxgi,d3d10core,d3d11,d3d12=b"],
                         environment: ["D3DM_SUPPORT_DXR": "1"], backend: .d3dmetal)
        }
    }

    private static func installDLLs(from dir: URL, into dest: URL) throws {
        guard FS.exists(dest) else { return } // 64-bit-only prefix has no syswow64
        for dll in FS.files(in: dir, withExtension: "dll") {
            try FS.replace(dest.appendingPathComponent(dll.lastPathComponent), with: dll)
        }
    }
}
