import SwiftUI
import TorchKit

struct JobDetailView: View {
    @Environment(AppModel.self) private var model
    let jobID: SlurmJob.ID

    @State private var confirmingCancel = false
    @State private var cancelError: String?

    var body: some View {
        if let (agent, job) = model.torchJob(jobID) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        StateBadge(state: job.state)
                        Text(job.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                        if job.stateDetail != job.state.rawValue {
                            Text(job.stateDetail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    if job.state.isActive {
                        TorchJobRow(job: job, fetchedAt: model.torchFetchedAt ?? .now)
                    }
                }

                Section("Logs") {
                    if let out = job.stdoutPath {
                        NavigationLink {
                            LogView(agentID: agent.id, title: "Output", path: out, follow: job.state.isActive)
                        } label: {
                            LogLink(label: "Output", path: out)
                        }
                    }
                    if let err = job.stderrPath, err != job.stdoutPath {
                        NavigationLink {
                            LogView(agentID: agent.id, title: "Errors", path: err, follow: job.state.isActive)
                        } label: {
                            LogLink(label: "Errors", path: err)
                        }
                    }
                    if job.stdoutPath == nil {
                        Text("No log file (interactive job).").foregroundStyle(.secondary)
                    }
                }

                Section("Job") {
                    Field("ID", job.id)
                    if job.rawID != job.id { Field("Raw ID", job.rawID) }
                    Field("Partition", job.partition)
                    if let reason = job.reason { Field("Reason", reason) }
                    if let exit = job.exitCode, !job.state.isActive { Field("Exit code", exit) }
                    Field("Via", agent.name)
                }

                Section("Resources") {
                    if let gpus = job.gpuCount { Field("GPUs", "\(gpus)") }
                    if let nodes = job.nodeCount { Field("Nodes", "\(nodes)") }
                    if let list = job.nodeList { Field("Node list", list) }
                    if let tres = job.tres { Field("TRES", tres.replacingOccurrences(of: ",", with: "\n")) }
                }

                Section("Time") {
                    if let date = job.submitTime { DateField("Submitted", date) }
                    if let date = job.startTime { DateField(job.state == .pending ? "Estimated start" : "Started", date) }
                    if let date = job.endTime, !job.state.isActive { DateField("Ended", date) }
                    if let elapsed = job.elapsed { Field("Elapsed", Format.duration(elapsed)) }
                    if let limit = job.timeLimit { Field("Time limit", Format.duration(limit)) }
                }

                if let dir = job.workDir {
                    Section("Working directory") {
                        Text(dir).font(.footnote.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(job.id)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.refresh() }
            .toolbar {
                if job.state.isActive {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel Job", systemImage: "stop.circle", role: .destructive) { confirmingCancel = true }
                            .tint(.red)
                    }
                }
            }
            .confirmationDialog("Cancel \(job.name)?", isPresented: $confirmingCancel, titleVisibility: .visible) {
                Button("Cancel job \(job.id)", role: .destructive) {
                    Task {
                        do { try await model.cancel(job, on: agent.id) } catch { cancelError = error.localizedDescription }
                    }
                }
            } message: {
                Text("Runs scancel \(job.id) on Torch. This can't be undone.")
            }
            .alert("Couldn't cancel", isPresented: .constant(cancelError != nil)) {
                Button("OK") { cancelError = nil }
            } message: {
                Text(cancelError ?? "")
            }
        } else {
            ContentUnavailableView("Job no longer listed", systemImage: "questionmark.folder",
                                   description: Text("It may be older than the agent's history window."))
        }
    }
}

private struct LogLink: View {
    let label: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
        }
    }
}

private struct Field: View {
    let name: String
    let value: String
    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }

    var body: some View {
        LabeledContent(name) {
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}

private struct DateField: View {
    let name: String
    let date: Date
    init(_ name: String, _ date: Date) {
        self.name = name
        self.date = date
    }

    var body: some View {
        LabeledContent(name) {
            VStack(alignment: .trailing) {
                Text(date, format: .dateTime.month().day().hour().minute())
                Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
