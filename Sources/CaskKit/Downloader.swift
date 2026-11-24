import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let browser_download_url: URL
    }
    public let tag_name: String
    public let assets: [Asset]
}

public enum Downloader {
    public static func latestRelease(_ repo: String) async throws -> GitHubRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cask", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CaskError("GitHub returned HTTP \(http.statusCode) for \(repo) releases")
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// Downloads `url` to `dest`, replacing anything already there.
    public static func download(_ url: URL, to dest: URL, progress: ProgressHandler? = nil) async throws {
        progress?("Downloading \(url.lastPathComponent)…")
        var request = URLRequest(url: url)
        request.setValue("Cask", forHTTPHeaderField: "User-Agent")
        let (tmp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CaskError("Download of \(url.lastPathComponent) failed (HTTP \(http.statusCode))")
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FS.exists(dest) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// Extracts a .tar.xz / .tar.gz / .zip with the system bsdtar.
    public static func extract(_ archive: URL, into dir: URL, progress: ProgressHandler? = nil) throws {
        progress?("Unpacking \(archive.lastPathComponent)…")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", dir.path])
        FS.stripQuarantine(dir)
    }

    /// Downloads the first asset of a repo's latest release matching one of `preferences` (checked in order),
    /// extracts it into a fresh `dest` directory and returns the release tag.
    @discardableResult
    public static func installLatest(
        repo: String,
        preferences: [(GitHubRelease.Asset) -> Bool],
        into dest: URL,
        progress: ProgressHandler? = nil
    ) async throws -> String {
        progress?("Checking \(repo) for the latest release…")
        let release = try await latestRelease(repo)
        guard let asset = preferences.lazy.compactMap({ pick in release.assets.first(where: pick) }).first else {
            throw CaskError("No suitable download found in \(repo) \(release.tag_name)")
        }
        try CaskPaths.ensure()
        let archive = CaskPaths.cache.appendingPathComponent(asset.name)
        try await download(asset.browser_download_url, to: archive, progress: progress)

        let staging = dest.deletingLastPathComponent().appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try extract(archive, into: staging, progress: progress)
        if FS.exists(dest) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: staging, to: dest)
        try? Data(release.tag_name.utf8).write(to: dest.appendingPathComponent(".cask-version"))
        try? FileManager.default.removeItem(at: archive)
        return release.tag_name
    }
}
