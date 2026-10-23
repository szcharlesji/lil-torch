import SwiftUI
import TorchKit

/// Everything of yours that's running or ran recently: Torch jobs and lab GPU work.
struct JobsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var loginAgent: AgentRecord?
    @State private var addingCluster = false

    enum Route: Hashable {
        case torch(String)
        case lab(LabWork)
    }

    var body: some View {
        NavigationStack {
            List {
                banners
                content
            }
            .navigationTitle("Jobs")
            .searchable(text: $search, prompt: "Name, ID or host")
            .refreshable { await model.refresh() }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .torch(let id): JobDetailView(jobID: id)
                case .lab(let work): LabWorkView(work: work)
                }
            }
            .overlay { emptyState }
            .sheet(item: $loginAgent) { agent in
                TerminalSheet(agentID: agent.id, target: .torch)
            }
            .sheet(isPresented: $addingCluster) {
                AddClusterSheet()
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var banners: some View {
        ForEach(model.agentsNeedingLogin) { agent in
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Torch login needed").font(.headline)
                        Text("\(agent.name) lost its NYU login.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Log In") { loginAgent = agent }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        let torch = model.torchJobs.filter { matches($0.job) }
        let running = torch.filter { $0.job.state.isActive && $0.job.state != .pending }
        let queued = torch.filter { $0.job.state == .pending }
        let recent = torch.filter { !$0.job.state.isActive }
        let lab = model.labWork.filter(matches)
        let fetchedAt = model.torchFetchedAt ?? .now

        if !running.isEmpty || !lab.isEmpty {
            Section("Running") {
                ForEach(running, id: \.job.id) { item in
                    NavigationLink(value: Route.torch(item.job.id)) {
                        TorchJobRow(job: item.job, fetchedAt: fetchedAt)
                    }
                }
                ForEach(lab) { work in
                    NavigationLink(value: Route.lab(work)) {
                        LabWorkRow(work: work)
                    }
                }
            }
        }
        if !queued.isEmpty {
            Section("Queued") {
                ForEach(queued, id: \.job.id) { item in
                    NavigationLink(value: Route.torch(item.job.id)) {
                        TorchJobRow(job: item.job, fetchedAt: fetchedAt)
                    }
                }
            }
        }
        if !recent.isEmpty {
            Section {
                ForEach(recent, id: \.job.id) { item in
                    NavigationLink(value: Route.torch(item.job.id)) {
                        TorchJobRow(job: item.job, fetchedAt: fetchedAt)
                    }
                }
            } header: {
                Text("Recent")
            } footer: {
                UpdatedFooter(date: model.torchFetchedAt, refreshing: model.isRefreshing)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.agents.isEmpty {
            ContentUnavailableView {
                Label("No Clusters Yet", systemImage: "server.rack")
            } description: {
                Text("Install the Lil Torch agent on a lab machine, then add it here.")
            } actions: {
                Button("Add a Cluster") { addingCluster = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.torchJobs.isEmpty && model.labWork.isEmpty && model.agentsNeedingLogin.isEmpty {
            ContentUnavailableView(
                model.isRefreshing ? "Loading…" : "Nothing Running",
                systemImage: model.isRefreshing ? "hourglass" : "moon.zzz",
                description: Text("Torch jobs and your lab GPU work show up here.")
            )
        }
    }

    private func matches(_ job: SlurmJob) -> Bool {
        search.isEmpty || job.name.localizedCaseInsensitiveContains(search) || job.id.contains(search)
    }

    private func matches(_ work: LabWork) -> Bool {
        search.isEmpty || work.host.localizedCaseInsensitiveContains(search)
            || (work.process?.command.localizedCaseInsensitiveContains(search) ?? false)
    }
}

struct UpdatedFooter: View {
    let date: Date?
    let refreshing: Bool

    var body: some View {
        HStack(spacing: 4) {
            if refreshing {
                ProgressView().controlSize(.mini)
                Text("Refreshing…")
            } else if let date {
                Text("Updated \(date, style: .relative) ago")
            }
        }
        .font(.footnote)
    }
}

// MARK: - Rows

struct TorchJobRow: View {
    let job: SlurmJob
    let fetchedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                StateBadge(state: job.state)
            }
            HStack(spacing: 6) {
                SourceTag(text: "Torch", symbol: "flame.fill")
                Text(job.id).monospacedDigit()
                Text(job.resourceSummary).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            detail
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var detail: some View {
        switch job.state {
        case .running, .completing, .configuring:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = job.elapsed(at: context.date, fetchedAt: fetchedAt) ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    if let limit = job.timeLimit, limit > 0 {
                        Meter(value: elapsed / limit, tint: elapsed / limit > 0.9 ? .orange : .blue)
                    }
                    HStack {
                        Text(Format.duration(elapsed))
                        Spacer()
                        if let limit = job.timeLimit {
                            Text("\(Format.duration(max(limit - elapsed, 0))) left")
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        case .pending:
            HStack {
                if let reason = job.reason { Text(reason) }
                Spacer()
                if let start = job.startTime, start > .now {
                    Text("est. \(start, format: .relative(presentation: .named))")
                }
            }
            .font(.caption)
            .foregroundStyle(.orange)
        default:
            HStack {
                if let elapsed = job.elapsed { Text("ran \(Format.duration(elapsed))") }
                if job.state.isFailure, let exit = job.exitCode { Text("exit \(exit)") }
                Spacer()
                if let end = job.endTime { Text(end, format: .relative(presentation: .named)) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct LabWorkRow: View {
    let work: LabWork

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(work.process.map { Format.command($0.command) } ?? "GPU memory in use")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let util = work.process?.smUtilization ?? work.gpu.utilization {
                    Text("\(util)%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.blue)
                }
            }
            HStack(spacing: 6) {
                SourceTag(text: work.host, symbol: "cpu")
                Text("GPU \(work.gpu.index)")
                Text(Format.model(work.gpu.model)).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Text(Format.memory(work.memory))
                if let pid = work.process?.pid { Text("PID \(pid)") }
                Spacer()
                if let elapsed = work.process?.elapsed { Text(Format.duration(TimeInterval(elapsed))) }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// One of your processes on a lab GPU.
struct LabWorkView: View {
    let work: LabWork

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    SourceTag(text: "\(work.host) · GPU \(work.gpu.index)", symbol: "cpu")
                    Text(work.process.map { Format.command($0.command) } ?? "GPU memory in use")
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
            if let process = work.process {
                Section("Process") {
                    LabeledContent("PID", value: "\(process.pid)")
                    if let elapsed = process.elapsed { LabeledContent("Running for", value: Format.duration(TimeInterval(elapsed))) }
                    if let sm = process.smUtilization { LabeledContent("GPU compute", value: "\(sm)%") }
                    LabeledContent("Memory", value: Format.memory(work.memory))
                    Text(process.command).font(.footnote.monospaced()).textSelection(.enabled)
                }
            }
            Section("GPU") {
                LabeledContent("Model", value: Format.model(work.gpu.model))
                if let util = work.gpu.utilization { LabeledContent("Utilization", value: "\(util)%") }
                if let used = work.gpu.memoryUsed, let total = work.gpu.memoryTotal {
                    LabeledContent("Memory", value: "\(Format.memory(used)) of \(Format.memory(total))")
                }
                if let temperature = work.gpu.temperature { LabeledContent("Temperature", value: "\(temperature)°C") }
                ForEach(work.gpu.users) { user in
                    LabeledContent(Format.user(user.name), value: Format.memory(user.memory))
                }
            }
        }
        .navigationTitle(work.host)
        .navigationBarTitleDisplayMode(.inline)
    }
}
