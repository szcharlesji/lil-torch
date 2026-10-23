import Foundation
import Observation
import OSLog
import TorchKit
import UIKit

/// One of your processes on a lab GPU.
struct LabWork: Identifiable, Hashable {
    var host: String
    var gpu: GPU
    var process: GPUProcess?
    /// MB you hold on this GPU, when per-process detail isn't available.
    var memory: Int

    var id: String { "\(host):\(gpu.index):\(process?.pid ?? -1)" }
}

private let log = Logger(subsystem: "GRAIL.LilTorch", category: "refresh")

@Observable
@MainActor
final class AppModel {
    var settings: AppSettings {
        didSet { settings.save() }
    }

    private(set) var states: [UUID: AgentState]
    private(set) var isRefreshing = false
    @ObservationIgnored private var refreshQueued = false
    /// A pairing link opened from outside the app, waiting for confirmation.
    var pendingPairing: PairingLink?

    init() {
        settings = AppSettings.load()
        states = StateCache.load()
    }

    // MARK: - Derived

    var agents: [AgentRecord] { settings.agents }

    func state(_ agent: AgentRecord) -> AgentState {
        states[agent.id] ?? AgentState()
    }

    func agent(_ id: UUID) -> AgentRecord? {
        agents.first { $0.id == id }
    }

    /// Torch jobs across agents; if two agents watch the same account, the fresher one wins.
    var torchJobs: [(agent: AgentRecord, job: SlurmJob)] {
        var byID: [String: (agent: AgentRecord, job: SlurmJob, fetched: Date)] = [:]
        for agent in agents {
            guard let snapshot = state(agent).jobs else { continue }
            for job in snapshot.jobs where (byID[job.id]?.fetched ?? .distantPast) < snapshot.fetchedAt {
                byID[job.id] = (agent, job, snapshot.fetchedAt)
            }
        }
        return byID.values
            .sorted { ($0.job.submitTime ?? .distantPast, $0.job.id) > ($1.job.submitTime ?? .distantPast, $1.job.id) }
            .map { ($0.agent, $0.job) }
    }

    var torchFetchedAt: Date? {
        agents.compactMap { state($0).jobs?.fetchedAt }.max()
    }

    func torchJob(_ id: String) -> (agent: AgentRecord, job: SlurmJob)? {
        torchJobs.first { $0.job.id == id }
    }

    /// Lab GPUs merged across agents (newest report per host).
    var lab: GPUSnapshot? {
        let snapshots = agents.compactMap { state($0).gpus }.sorted { $0.fetchedAt > $1.fetchedAt }
        guard var merged = snapshots.first else { return nil }
        var seen = Set(merged.hosts.map(\.name))
        for snapshot in snapshots.dropFirst() {
            merged.hosts += snapshot.hosts.filter { seen.insert($0.name).inserted }
        }
        merged.hosts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return merged
    }

    var labWork: [LabWork] {
        guard let lab else { return [] }
        var work: [LabWork] = []
        for host in lab.hosts {
            for gpu in host.gpus {
                guard let mine = gpu.users.first(where: { $0.name == lab.user }) else { continue }
                if gpu.processes.isEmpty {
                    work.append(LabWork(host: host.name, gpu: gpu, process: nil, memory: mine.memory))
                } else {
                    work += gpu.processes.map { LabWork(host: host.name, gpu: gpu, process: $0, memory: $0.memory ?? 0) }
                }
            }
        }
        return work
    }

    /// Agents whose Torch login has lapsed.
    var agentsNeedingLogin: [AgentRecord] {
        agents.filter { state($0).loginNeeded }
    }

    // MARK: - Refresh

    func refresh() async {
        guard !agents.isEmpty else { return }
        // Asked again mid-refresh (e.g. right after an action): run once more afterwards.
        guard !isRefreshing else {
            refreshQueued = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshQueued = false
            await withTaskGroup(of: Void.self) { group in
                for agent in agents {
                    group.addTask { await self.refresh(agent) }
                }
            }
        } while refreshQueued
        StateCache.save(states)
    }

    private func refresh(_ agent: AgentRecord) async {
        guard let client = client(agent) else {
            states[agent.id, default: AgentState()].error = "This agent's token is missing. Pair it again."
            return
        }
        var state = states[agent.id] ?? AgentState()
        do {
            let info = try await client.info()
            state.info = info
            state.error = nil
            state.loginNeeded = info.torch?.state == .loginRequired
            if info.features.torch {
                do {
                    state.jobs = try await client.jobs()
                    state.loginNeeded = false
                } catch AgentError.loginRequired {
                    state.loginNeeded = true
                }
            }
            if info.features.gpus {
                state.gpus = try await client.gpus()
            }
            await deliverEvents(from: agent, client: client, pushHandled: info.features.push && state.pushRegistered)
        } catch {
            log.error("\(agent.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            state.error = error.localizedDescription
        }
        states[agent.id] = state
    }

    /// Shows new agent events as local notifications, unless the agent pushes them itself.
    private func deliverEvents(from agent: AgentRecord, client: AgentClient, pushHandled: Bool) async {
        let last = settings.lastEventSeq[agent.id]
        guard let page = try? await client.events(since: last ?? 0) else { return }
        log.info("\(agent.name, privacy: .public): events since \(last ?? -1) → \(page.events.count) new, latest \(page.latest), push \(pushHandled)")
        settings.lastEventSeq[agent.id] = page.latest
        // On first contact, or if the agent's history was reset, start from now.
        guard let last, last <= page.latest, !pushHandled else { return }
        for event in page.events where settings.notifications.allows(event.kind) {
            Notifier.post(event, from: agent)
        }
    }

    // MARK: - Actions

    func client(_ agent: AgentRecord) -> AgentClient? {
        TokenStore.load(agent.id).map { AgentClient(baseURL: agent.url, token: $0) }
    }

    func client(for agentID: UUID) -> AgentClient? {
        agent(agentID).flatMap(client)
    }

    /// Checks the link against the agent, then saves it.
    func pair(_ link: PairingLink) async throws {
        let info = try await AgentClient(baseURL: link.url, token: link.token).info()
        if let existing = agents.first(where: { $0.url == link.url }) {
            TokenStore.save(link.token, for: existing.id)
        } else {
            let record = AgentRecord(name: info.name.isEmpty ? link.name : info.name, url: link.url)
            TokenStore.save(link.token, for: record.id)
            settings.agents.append(record)
        }
        // Don't hold pairing hostage to the permission prompt.
        Task { await Notifier.requestAuthorization() }
        await registerForPush()
        await refresh()
    }

    func remove(_ agent: AgentRecord) {
        if let token = settings.deviceToken, let client = client(agent) {
            Task { try? await client.unregisterDevice(token: token) }
        }
        TokenStore.delete(agent.id)
        settings.agents.removeAll { $0.id == agent.id }
        settings.lastEventSeq[agent.id] = nil
        states[agent.id] = nil
        StateCache.save(states)
    }

    func cancel(_ job: SlurmJob, on agentID: UUID) async throws {
        guard let client = client(for: agentID) else { return }
        try await client.cancel(jobID: job.id)
        try? await Task.sleep(for: .seconds(2))
        await refresh()
    }

    // MARK: - Push

    func didReceiveDeviceToken(_ token: Data) {
        settings.deviceToken = token.map { String(format: "%02x", $0) }.joined()
        Task { await registerForPush() }
    }

    /// Tells every agent where to push; agents without an APNs key just remember it.
    func registerForPush() async {
        guard let token = settings.deviceToken else { return }
        #if DEBUG
        let sandbox = true  // Xcode builds get development push tokens
        #else
        let sandbox = false
        #endif
        for agent in agents {
            guard let client = client(agent) else { continue }
            let pushes = (try? await client.registerDevice(
                token: token, sandbox: sandbox, name: UIDevice.current.name, prefs: settings.notifications)) ?? false
            states[agent.id, default: AgentState()].pushRegistered = pushes
        }
    }
}
