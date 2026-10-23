import SwiftUI
import TorchKit

/// Paired agents, how to add one, and notification settings.
struct ClustersView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    ForEach(model.agents) { agent in
                        NavigationLink(value: agent.id) {
                            AgentRow(agent: agent, state: model.state(agent))
                        }
                    }
                    Button("Add a Cluster", systemImage: "plus.circle.fill") { adding = true }
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Each agent runs on a lab machine on NYU's network, so it reaches Torch without the VPN.")
                }

                Section {
                    Toggle("A Torch job finishes", isOn: $model.settings.notifications.jobFinished)
                    Toggle("A Torch job starts", isOn: $model.settings.notifications.jobStarted)
                    Toggle("My lab GPU work ends", isOn: $model.settings.notifications.gpuProcessEnded)
                    Toggle("A lab GPU frees up", isOn: $model.settings.notifications.gpuFree)
                    Toggle("Torch needs a login", isOn: $model.settings.notifications.torchLogin)
                } header: {
                    Text("Notify Me When")
                } footer: {
                    Text(pushFooter)
                }
                .onChange(of: model.settings.notifications) {
                    Task { await model.registerForPush() }
                }

                Section("Refresh") {
                    Picker("While open, every", selection: $model.settings.refreshInterval) {
                        Text("15 seconds").tag(15.0)
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                        Text("5 minutes").tag(300.0)
                    }
                }
            }
            .navigationTitle("Clusters")
            .navigationDestination(for: UUID.self) { AgentDetailView(agentID: $0) }
            .sheet(isPresented: $adding) { AddClusterSheet() }
        }
    }

    private var pushFooter: String {
        let pushing = model.agents.filter { model.state($0).info?.features.push == true && model.state($0).pushRegistered }
        if !pushing.isEmpty {
            return "Delivered instantly by Apple push from \(pushing.map(\.name).joined(separator: ", "))."
        }
        return "Without an APNs key on the agent, alerts arrive when iOS lets the app refresh in the background, "
            + "which can take a while and stops if you force-quit the app."
    }
}

private struct AgentRow: View {
    let agent: AgentRecord
    let state: AgentState

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(status.color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.headline)
                Text(status.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let features = state.info?.features {
                HStack(spacing: 6) {
                    if features.torch { Image(systemName: "flame.fill") }
                    if features.gpus { Image(systemName: "square.grid.3x3.fill") }
                    if features.push { Image(systemName: "bell.badge.fill") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var status: (text: String, color: Color) {
        if let error = state.error { return (error, .red) }
        if state.loginNeeded { return ("Torch login needed", .orange) }
        if state.info == nil { return ("Connecting…", .secondary) }
        return (agent.url.host() ?? "Online", .green)
    }
}

struct AgentDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let agentID: UUID

    @State private var terminal: TerminalTarget?
    @State private var confirmingRemove = false
    @State private var testResult: String?

    var body: some View {
        if let agent = model.agent(agentID) {
            let state = model.state(agent)
            List {
                Section {
                    LabeledContent("Address", value: agent.url.host() ?? agent.url.absoluteString)
                    if let info = state.info {
                        LabeledContent("Machine", value: info.host)
                        LabeledContent("Account", value: info.user)
                        LabeledContent("Agent", value: "v\(info.version)")
                    }
                    if let error = state.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }

                if state.info?.features.torch == true {
                    Section {
                        LabeledContent("Status") {
                            Text(state.loginNeeded ? "Login needed" : torchState(state))
                                .foregroundStyle(state.loginNeeded ? .orange : .secondary)
                        }
                        Button(state.loginNeeded ? "Log In to Torch" : "Open Torch Terminal", systemImage: "apple.terminal") {
                            terminal = .torch
                        }
                    } header: {
                        Text("Torch")
                    } footer: {
                        Text("The terminal runs `ssh \(state.info?.torch?.sshHost ?? "torch")` on \(agent.name). If its login has lapsed, enter your NYU password and approve Duo there; the login is then shared with the agent.")
                    }
                }

                if let gpus = state.gpus {
                    Section("Lab GPUs") {
                        LabeledContent("Your account", value: gpus.user)
                        LabeledContent("Hosts", value: "\(gpus.hosts.count)")
                    }
                }

                Section {
                    LabeledContent("Apple push") {
                        Text(state.info?.features.push == true
                             ? (state.pushRegistered ? "On" : "Waiting for this device")
                             : "No APNs key")
                    }
                    Button("Send Test Notification", systemImage: "bell") {
                        Task {
                            do {
                                try await model.client(agent)?.testPush()
                                testResult = state.info?.features.push == true ? "Sent by Apple push." : "Sent; it appears on the next refresh."
                                await model.refresh()
                            } catch {
                                testResult = error.localizedDescription
                            }
                        }
                    }
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Notifications")
                }

                if state.info?.features.terminal == true {
                    Section {
                        Button("Shell on \(agent.name)", systemImage: "terminal") { terminal = .local }
                    }
                }

                Section {
                    Button("Remove Agent", role: .destructive) { confirmingRemove = true }
                }
            }
            .navigationTitle(agent.name)
            .refreshable { await model.refresh() }
            .fullScreenCover(item: $terminal) { target in
                TerminalSheet(agentID: agentID, target: target)
            }
            .confirmationDialog("Remove \(agent.name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    model.remove(agent)
                    dismiss()
                }
            } message: {
                Text("The agent keeps running; pair it again with its link from `liltorch_agent.py pair`.")
            }
        }
    }

    private func torchState(_ state: AgentState) -> String {
        switch state.info?.torch?.state {
        case .ok: "Connected"
        case .error: state.info?.torch?.message ?? "Error"
        default: "Checking…"
        }
    }
}

/// How to install an agent, and a place to paste its pairing link.
struct AddClusterSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var linkText = ""
    @State private var adding = false
    @State private var error: String?
    @State private var copied = false

    /// Update when the installer is hosted somewhere else.
    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/szcharlesji/lil-torch/main/install.sh | sh"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("On a lab machine you can SSH into (orion, hestia, your own box), run:")
                        .font(.subheadline)
                    Text(Self.installCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy Command", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = Self.installCommand
                        copied = true
                    }
                } header: {
                    Text("1. Install the Agent")
                } footer: {
                    Text("It asks for your NetID, sets up a shared Torch login, and installs a service that keeps running. It needs no root.")
                }

                Section {
                    TextField("liltorch://add?…", text: $linkText, axis: .vertical)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste", systemImage: "doc.on.clipboard") {
                        linkText = UIPasteboard.general.string ?? ""
                    }
                } header: {
                    Text("2. Paste Its Link")
                } footer: {
                    Text(error ?? "The installer prints this link at the end. Opening it on your phone also works.")
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Add a Cluster")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(adding ? "Adding…" : "Add") { add() }
                        .disabled(linkText.isEmpty || adding)
                }
            }
        }
    }

    private func add() {
        guard let link = PairingLink(linkText) else {
            error = "That isn't a Lil Torch link. It starts with liltorch://add."
            return
        }
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
    }
}
