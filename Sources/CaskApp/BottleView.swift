import AppKit
import CaskKit
import SwiftUI

struct BottleView: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    @State private var config: BottleConfig
    @State private var discovered: [PinnedProgram] = []
    @State private var scanning = false
    @State private var envText = ""
    @State private var confirmTrash = false

    init(bottle: Bottle) {
        self.bottle = bottle
        _config = State(initialValue: bottle.config)
        _envText = State(initialValue: bottle.config.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
    }

    private var isSteam: Bool { bottle.name == WindowsSteam.bottleName }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: isSteam ? "gamecontroller.fill" : "shippingbox.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bottle.name).font(.title.bold())
                        Text("\(bottle.runtime.map { "Wine \($0.version)" } ?? "No Wine installed") · \(windowsTitle)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isSteam {
                        if model.steamInstalled {
                            Button("Open Steam") { model.openSteam() }.buttonStyle(.borderedProminent)
                        } else {
                            Button("Install Steam") { model.installSteam() }.buttonStyle(.borderedProminent)
                        }
                    }
                    Button("Run Program…") { model.chooseAndRun(in: bottle) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasWine)
                }
                .padding(.vertical, 4)
            }

            if !config.pinned.isEmpty {
                Section("Pinned") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                        ForEach(config.pinned) { program in
                            ProgramTile(program: program) {
                                model.launch(URL(fileURLWithPath: program.path), arguments: program.arguments, in: bottle)
                            }
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: program.path)]) }
                                Button("Unpin") {
                                    config.pinned.removeAll { $0.path == program.path }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                if scanning {
                    HStack { ProgressView().controlSize(.small); Text("Looking for programs…").foregroundStyle(.secondary) }
                } else if discovered.isEmpty {
                    Text("Nothing installed yet. Use Run Program… to start an installer or a game's .exe.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(discovered) { program in
                        HStack {
                            Image(systemName: "app.dashed").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(program.name)
                                Text(relativePath(program.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if !config.pinned.contains(where: { $0.path == program.path }) {
                                Button { config.pinned.append(program) } label: { Image(systemName: "pin") }
                                    .buttonStyle(.borderless).help("Pin")
                            }
                            Button("Run") { model.launch(URL(fileURLWithPath: program.path), in: bottle) }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Programs")
                    Spacer()
                    Button { scan() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                }
            }

            Section("Settings") {
                Picker("Windows version", selection: $config.windowsVersion) {
                    ForEach(BottleConfig.windowsVersions, id: \.id) { Text($0.title).tag($0.id) }
                }
                Picker("Graphics", selection: $config.graphics) {
                    ForEach(GraphicsBackend.allCases) { Text($0.title).tag($0) }
                }
                if isSteam {
                    Text("Steam starts games itself, so Automatic uses DXMT (or DXVK) for DirectX 10/11 games here. DirectX 9 games always use WineD3D.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Wine", selection: $config.runtime) {
                    Text("Default").tag(String?.none)
                    ForEach(model.runtimes) { Text("\($0.name) · \($0.version)").tag(String?.some($0.name)) }
                }
                Toggle("Retina (high-resolution) mode", isOn: $config.retina)
                Toggle("Faster sync (msync)", isOn: $config.msync)
                Toggle("Metal performance HUD", isOn: $config.metalHUD)
                Toggle("Detailed Wine log", isOn: $config.debugLog)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Environment variables (KEY=value per line)")
                    TextEditor(text: $envText)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 56)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }

            Section("Tools") {
                HStack {
                    Menu("Windows Tools") {
                        ForEach(Wine.Tool.allCases, id: \.self) { tool in
                            Button(tool.title) { model.openTool(tool, in: bottle) }
                        }
                    }
                    .fixedSize()
                    Button("Open C: Drive") { NSWorkspace.shared.open(bottle.driveC) }
                    Button("Show Log") {
                        if FileManager.default.fileExists(atPath: bottle.logURL.path) { NSWorkspace.shared.open(bottle.logURL) }
                    }
                    Spacer()
                    Button("Stop All") { model.killAll(bottle) }
                    Button("Move to Trash…", role: .destructive) { confirmTrash = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(bottle.name)
        .onAppear(perform: scan)
        .onChange(of: config) { _, newValue in model.update(bottle, config: newValue) }
        .onChange(of: envText) { _, text in config.environment = parseEnv(text) }
        .confirmationDialog("Move “\(bottle.name)” to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { model.trash(bottle) }
        } message: {
            Text("Everything installed in this bottle goes with it. You can restore it from the Trash.")
        }
    }

    private var windowsTitle: String {
        BottleConfig.windowsVersions.first { $0.id == config.windowsVersion }?.title ?? config.windowsVersion
    }

    private func relativePath(_ path: String) -> String {
        path.replacingOccurrences(of: bottle.driveC.path, with: "C:")
    }

    private func scan() {
        scanning = true
        let b = bottle
        Task.detached {
            let found = BottleManager.discoverPrograms(in: b)
            await MainActor.run {
                discovered = found
                scanning = false
            }
        }
    }

    private func parseEnv(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { env[parts[0]] = parts[1] }
        }
        return env
    }
}

struct ProgramTile: View {
    let program: PinnedProgram
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "play.square.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text(program.name)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 86)
            .padding(8)
            .background(hovering ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
