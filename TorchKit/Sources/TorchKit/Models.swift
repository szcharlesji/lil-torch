import Foundation

// MARK: - Agent

public struct AgentInfo: Codable, Hashable, Sendable {
    public struct Features: Codable, Hashable, Sendable {
        public var torch: Bool
        public var gpus: Bool
        public var terminal: Bool
        public var push: Bool
    }

    public var name: String
    public var version: String
    public var host: String
    public var user: String
    public var features: Features
    public var torch: TorchStatus?
    /// The account name on the lab GPU machines; GPUs it uses count as "mine".
    public var gpuUser: String?
    public var latestEvent: Int
}

public struct TorchStatus: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        case ok, loginRequired = "login_required", error, unknown
    }

    public var state: State
    public var message: String?
    public var sshHost: String?
}

// MARK: - Torch (Slurm)

public enum JobState: String, Codable, Sendable, CaseIterable {
    case pending = "PENDING"
    case running = "RUNNING"
    case configuring = "CONFIGURING"
    case completing = "COMPLETING"
    case suspended = "SUSPENDED"
    case requeued = "REQUEUED"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
    case timeout = "TIMEOUT"
    case outOfMemory = "OUT_OF_MEMORY"
    case nodeFail = "NODE_FAIL"
    case preempted = "PREEMPTED"
    case bootFail = "BOOT_FAIL"
    case deadline = "DEADLINE"
    case unknown = "UNKNOWN"

    public init(from decoder: Decoder) throws {
        self = JobState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    public var isActive: Bool {
        switch self {
        case .pending, .running, .configuring, .completing, .suspended, .requeued: true
        default: false
        }
    }

    public var isFailure: Bool {
        switch self {
        case .failed, .timeout, .outOfMemory, .nodeFail, .bootFail, .deadline: true
        default: false
        }
    }
}

public struct SlurmJob: Identifiable, Codable, Hashable, Sendable {
    /// Display ID, e.g. `19683229` or `19508274_3`.
    public var id: String
    public var rawID: String
    public var name: String
    public var state: JobState
    /// Slurm's own wording, e.g. `CANCELLED by 3618864`.
    public var stateDetail: String
    /// Pending reason; only set while pending.
    public var reason: String?
    public var partition: String
    public var elapsed: TimeInterval?
    public var timeLimit: TimeInterval?
    public var exitCode: String?
    public var submitTime: Date?
    /// Actual start, or Slurm's estimate while pending.
    public var startTime: Date?
    public var endTime: Date?
    public var nodeCount: Int?
    public var nodeList: String?
    public var tres: String?
    public var workDir: String?
    public var stdoutPath: String?
    public var stderrPath: String?

    public var gpuCount: Int? { Self.gpuCount(inTRES: tres) }

    /// `gres/gpu=4`, `gres/gpu:h200=4`, or squeue's per-node `gres/gpu:4`.
    public static func gpuCount(inTRES tres: String?) -> Int? {
        guard let tres else { return nil }
        var best: Int?
        for item in tres.split(separator: ",") where item.hasPrefix("gres/gpu") || item.hasPrefix("gres:gpu") {
            if let value = item.split(whereSeparator: { $0 == "=" || $0 == ":" }).last.flatMap({ Int($0) }) {
                best = max(best ?? 0, value)
            }
        }
        return best
    }
}

public struct JobSnapshot: Codable, Sendable {
    public var user: String
    public var jobs: [SlurmJob]
    public var warnings: [String]
    public var fetchedAt: Date
    public var status: TorchStatus?
}

public struct LogTail: Codable, Sendable {
    public var path: String
    public var text: String
    public var size: Int?
    public var modified: Date?
}

// MARK: - Lab GPUs

public struct GPUSnapshot: Codable, Sendable {
    public var fetchedAt: Date
    public var user: String
    public var hosts: [GPUHost]
    public var unreachable: [UnreachableHost]
    public var error: String?
}

public struct UnreachableHost: Codable, Hashable, Sendable {
    public var host: String
    public var message: String
}

public struct GPUHost: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var reportedAt: String
    public var driver: String
    public var gpus: [GPU]
    public var detailError: String?

    public var id: String { name }
}

public struct GPU: Codable, Hashable, Identifiable, Sendable {
    public var index: Int
    public var model: String
    public var temperature: Int?
    public var utilization: Int?
    public var memoryUsed: Int?
    public var memoryTotal: Int?
    /// People holding memory on this GPU (system accounts already left out).
    public var users: [GPUUser]
    /// Your processes, with detail, when the agent could ask the host.
    public var processes: [GPUProcess]
    public var error: Bool

    public var id: Int { index }

    public enum Availability: String, Sendable, CaseIterable {
        case mine = "Mine", free = "Free", busy = "Busy"
    }

    public func availability(for user: String) -> Availability {
        if users.contains(where: { $0.name == user }) { return .mine }
        if error { return .busy }
        return users.isEmpty ? .free : .busy
    }
}

public struct GPUUser: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    /// MB across this user's processes on the GPU.
    public var memory: Int
    public var processes: Int

    public var id: String { name }
}

public struct GPUProcess: Codable, Hashable, Identifiable, Sendable {
    public var pid: Int
    public var command: String
    public var elapsed: Int?
    public var memory: Int?
    public var smUtilization: Int?

    public var id: Int { pid }
}

// MARK: - Events

public struct AgentEvent: Codable, Hashable, Identifiable, Sendable {
    public var seq: Int
    public var kind: String
    public var title: String
    public var body: String
    public var time: Date

    public var id: Int { seq }
}

public struct EventPage: Codable, Sendable {
    public var events: [AgentEvent]
    public var latest: Int
}

/// Which events notify you. Keys match the agent's event kinds.
public struct NotificationPrefs: Codable, Hashable, Sendable {
    public var jobFinished = true
    public var jobStarted = false
    public var gpuProcessEnded = true
    public var gpuFree = false
    public var torchLogin = true

    public init() {}

    public var agentPrefs: [String: Bool] {
        ["job_finished": jobFinished, "job_started": jobStarted, "gpu_process_ended": gpuProcessEnded,
         "gpu_free": gpuFree, "torch_login": torchLogin, "test": true]
    }

    public func allows(_ kind: String) -> Bool {
        agentPrefs[kind] ?? false
    }
}
