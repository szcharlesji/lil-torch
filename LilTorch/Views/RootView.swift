import SwiftUI
import TorchKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = AppTab.jobs

    var body: some View {
        @Bindable var model = model
        TabView(selection: $tab) {
            Tab("Jobs", systemImage: "list.bullet.rectangle.portrait", value: .jobs) {
                JobsView()
            }
            Tab("GPUs", systemImage: "square.grid.3x3.fill", value: .gpus) {
                GPUsView()
            }
            Tab("Clusters", systemImage: "server.rack", value: .clusters) {
                ClustersView()
            }
        }
        .sheet(item: $model.pendingPairing) { link in
            PairingSheet(link: link)
        }
        .task(id: model.settings.refreshInterval) {
            // Foreground polling; scene activation covers launch and resume.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(model.settings.refreshInterval))
                await model.refresh()
            }
        }
    }
}

enum AppTab: Hashable {
    case jobs, gpus, clusters
}

/// Shown when a `liltorch://add` link is opened from outside the app.
struct PairingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let link: PairingLink
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "server.rack")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .padding(.top, 24)
                Text("Add \(link.name)?").font(.title2.bold())
                Text(link.url.host() ?? link.url.absoluteString)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Spacer()
                Button {
                    Task {
                        adding = true
                        defer { adding = false }
                        do {
                            try await model.pair(link)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                } label: {
                    Text(adding ? "Connecting…" : "Add Cluster").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(adding)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
