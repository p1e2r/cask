import CaskKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showNewBottle = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    Label("Setup", systemImage: model.isReady ? "checkmark.seal" : "wrench.and.screwdriver")
                        .tag(SidebarItem.setup)
                }
                Section("Bottles") {
                    ForEach(model.bottles) { bottle in
                        Label(bottle.name, systemImage: bottle.name == WindowsSteam.bottleName ? "gamecontroller" : "shippingbox")
                            .tag(SidebarItem.bottle(bottle.name))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .toolbar {
                ToolbarItem {
                    Button { showNewBottle = true } label: { Label("New Bottle", systemImage: "plus") }
                        .disabled(!model.hasWine)
                        .help("New bottle")
                }
            }
        } detail: {
            detail
        }
        .safeAreaInset(edge: .bottom) {
            if let busy = model.busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(busy).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.lastError ?? "")
        }
        .sheet(isPresented: $showNewBottle) { NewBottleSheet() }
        .sheet(isPresented: Binding(get: { !model.pendingOpen.isEmpty }, set: { if !$0 { model.pendingOpen = [] } })) {
            OpenWithSheet()
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .bottle(let name):
            if let bottle = model.bottle(named: name) {
                BottleView(bottle: bottle).id(name)
            } else {
                ContentUnavailableView("No bottle selected", systemImage: "shippingbox")
            }
        default:
            SetupView()
        }
    }
}

struct NewBottleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = "My Games"
    @State private var windowsVersion = "win10"
    @State private var graphics: GraphicsBackend = .auto

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Bottle").font(.title2.bold())
            Text("A bottle is a separate Windows install. Keep games that need different settings in different bottles.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                Picker("Windows version", selection: $windowsVersion) {
                    ForEach(BottleConfig.windowsVersions, id: \.id) { Text($0.title).tag($0.id) }
                }
                Picker("Graphics", selection: $graphics) {
                    ForEach(GraphicsBackend.allCases) { Text($0.title).tag($0) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.createBottle(name, windowsVersion: windowsVersion, graphics: graphics)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

struct OpenWithSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var bottleName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run in which bottle?").font(.title2.bold())
            ForEach(model.pendingOpen, id: \.self) { url in
                Label(url.lastPathComponent, systemImage: "app.dashed")
            }
            if model.bottles.isEmpty {
                Text("Create a bottle first (Setup → install Wine, then +).").foregroundStyle(.secondary)
            } else {
                Picker("Bottle", selection: $bottleName) {
                    ForEach(model.bottles) { Text($0.name).tag($0.name) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.pendingOpen = []; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run") {
                    if let bottle = model.bottle(named: bottleName) {
                        for url in model.pendingOpen { model.launch(url, in: bottle) }
                        model.selection = .bottle(bottle.name)
                    }
                    model.pendingOpen = []
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.bottle(named: bottleName) == nil)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { bottleName = model.bottles.first(where: { $0.name != WindowsSteam.bottleName })?.name ?? model.bottles.first?.name ?? "" }
    }
}
