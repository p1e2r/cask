import AppKit
import CaskKit
import SwiftUI

struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cask").font(.largeTitle.bold())
                    Text("Run Windows games and apps on your Mac. Free and open source.")
                        .foregroundStyle(.secondary)
                    if !(model.hasWine && model.hasDXMT && model.hasDXVK && (model.hasVKD3D || model.kosmicUnavailable != nil)) {
                        Button("Set Up Everything") { model.setUpEverything() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(model.busy != nil || !model.rosetta)
                            .padding(.top, 6)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Requirements") {
                StatusRow(title: "Rosetta 2", detail: "Translates Wine's Intel code on Apple Silicon",
                          ok: model.rosetta) {
                    if !model.rosetta { Button("Install") { model.installRosetta() } }
                }
                StatusRow(title: "Wine", detail: model.runtimes.map { "\($0.name) · \($0.version)" }.joined(separator: ", ").nonEmpty
                          ?? "WineHQ build by Gcenx (runs 64- and 32-bit Windows programs)",
                          ok: model.hasWine) {
                    Button(model.hasWine ? "Update" : "Install") { model.installWine() }
                }
            }

            Section {
                StatusRow(title: "WineD3D", detail: "DirectX 1–9 → OpenGL. Built in. Used for Portal, Half-Life 2, older games.", ok: true) {}
                StatusRow(title: "DXMT", detail: model.dxmtVersion.map { "DirectX 10/11 → Metal · \($0)" } ?? "DirectX 10/11 → Metal (open source)",
                          ok: model.hasDXMT) {
                    Button(model.hasDXMT ? "Update" : "Install") { model.installDXMT() }
                }
                StatusRow(title: "DXVK", detail: model.dxvkVersion.map { "DirectX 10/11 → Vulkan → Metal · \($0)" } ?? "DirectX 10/11 → Vulkan → Metal (fallback)",
                          ok: model.hasDXVK) {
                    Button(model.hasDXVK ? "Update" : "Install") { model.installDXVK() }
                }
                StatusRow(title: "VKD3D-Proton + KosmicKrisp",
                          detail: model.kosmicUnavailable.map { "DirectX 12, free. Unavailable: \($0)." }
                          ?? (model.hasVKD3D ? "DirectX 12 → Vulkan → Metal 4. Free, no Apple ID (experimental)"
                              : "DirectX 12, free, no Apple ID (experimental). Downloads LunarG's Vulkan SDK once."),
                          ok: model.hasVKD3D) {
                    if model.kosmicUnavailable == nil {
                        Button(model.hasVKD3D ? "Update" : "Install") { model.installVKD3D() }
                    }
                }
                .opacity(model.kosmicUnavailable == nil ? 1 : 0.55)
                StatusRow(title: "D3DMetal", detail: model.hasD3DMetal
                          ? "DirectX 11/12 → Metal, from Apple's Game Porting Toolkit"
                          : model.waitingForGPTK
                          ? "Waiting for the GPTK download in your Downloads folder…"
                          : "DirectX 12 games. Apple requires you to download it yourself (free Apple ID).",
                          ok: model.hasD3DMetal) {
                    if model.waitingForGPTK {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.cancelGPTKWait() }
                    } else {
                        Button(model.hasD3DMetal ? "Re-import" : "Get GPTK") { model.getGPTK() }
                        Button("Choose…") { model.importD3DMetal() }.buttonStyle(.link)
                    }
                }
            } header: {
                Text("Graphics")
            } footer: {
                Text("Automatic picks per game: WineD3D for DirectX 9 and older, DXMT for 10/11, and for 12 the free VKD3D-Proton (macOS 26+) or D3DMetal if imported.")
            }

            Section {
                StatusRow(title: "Windows Steam", detail: model.steamInstalled
                          ? "Installed in the “Steam” bottle"
                          : "Needed for Steam games: it downloads the Windows version and handles Steam DRM",
                          ok: model.steamInstalled) {
                    if model.steamInstalled {
                        Button("Open Steam") { model.openSteam() }
                    } else {
                        Button("Install") { model.installSteam() }.disabled(!model.hasWine)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mac Steam launch option").font(.headline)
                    Text("For games whose Mac version is broken (like 32-bit Portal): Mac Steam → right-click the game → Properties → Launch Options, paste this, then press Play. Cask runs the Windows version instead.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text(model.steamLaunchOption)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        Button("Copy") { model.copyToClipboard(model.steamLaunchOption) }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Steam")
            }

            Section("Command line") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("cask command")
                        Text("Adds /usr/local/bin/cask (asks for your password)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Install") { model.installCommandLineTool() }
                }
                HStack {
                    Button("Open Data Folder") { NSWorkspace.shared.open(CaskPaths.support) }
                    Button("Open Logs") {
                        try? FileManager.default.createDirectory(at: CaskPaths.logs, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(CaskPaths.logs)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
    }
}

struct StatusRow<Actions: View>: View {
    let title: String
    let detail: String
    let ok: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            actions()
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
