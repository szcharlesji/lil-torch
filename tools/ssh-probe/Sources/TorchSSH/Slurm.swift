import Foundation

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

    /// Accepts squeue/sacct spellings such as `CANCELLED by 3618864` or `CANCELLED+`.
    public init(slurm text: String) {
        let word = text.split(separator: " ").first.map(String.init) ?? text
        self = JobState(rawValue: word.trimmingCharacters(in: CharacterSet(charactersIn: "+"))) ?? .unknown
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
    /// Numeric job ID that `scancel` and `%j` refer to.
    public var rawID: String
    public var name: String
    public var state: JobState
    /// Slurm's own wording, e.g. `CANCELLED by 3618864`.
    public var stateDetail: String
    public var reason: String?
    public var partition: String
    public var elapsed: TimeInterval?
    public var timeLimit: TimeInterval?
    public var exitCode: String?
    public var submitTime: Date?
    /// Actual start, or Slurm's estimate while the job is pending.
    public var startTime: Date?
    public var endTime: Date?
    public var nodeCount: Int?
    public var nodeList: String?
    public var tres: String?
    public var workDir: String?
    public var stdoutPath: String?
    public var stderrPath: String?

    public init(
        id: String, rawID: String, name: String, state: JobState, stateDetail: String,
        reason: String? = nil, partition: String, elapsed: TimeInterval? = nil, timeLimit: TimeInterval? = nil,
        exitCode: String? = nil, submitTime: Date? = nil, startTime: Date? = nil, endTime: Date? = nil,
        nodeCount: Int? = nil, nodeList: String? = nil, tres: String? = nil, workDir: String? = nil,
        stdoutPath: String? = nil, stderrPath: String? = nil
    ) {
        self.id = id
        self.rawID = rawID
        self.name = name
        self.state = state
        self.stateDetail = stateDetail
        self.reason = reason
        self.partition = partition
        self.elapsed = elapsed
        self.timeLimit = timeLimit
        self.exitCode = exitCode
        self.submitTime = submitTime
        self.startTime = startTime
        self.endTime = endTime
        self.nodeCount = nodeCount
        self.nodeList = nodeList
        self.tres = tres
        self.workDir = workDir
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
    }

    public var gpuCount: Int? { Slurm.gpuCount(inTRES: tres) }

    /// Fraction of the time limit used, for running jobs.
    public var progress: Double? {
        guard let elapsed, let timeLimit, timeLimit > 0 else { return nil }
        return min(elapsed / timeLimit, 1)
    }
}

public struct JobSnapshot: Codable, Sendable {
    public var user: String
    public var jobs: [SlurmJob]
    public var fetchedAt: Date
    public var warnings: [String]

    public var active: [SlurmJob] { jobs.filter(\.state.isActive) }
    public var finished: [SlurmJob] { jobs.filter { !$0.state.isActive } }
}

public struct LogTail: Sendable {
    public var path: String
    public var text: String
    public var size: Int?
    public var modified: Date?
}

/// Building and parsing Slurm commands. Output uses ASCII unit separators so
/// job names and paths with `|` or spaces survive.
public enum Slurm {
    static let separator: Character = "\u{1F}"

    static let squeueFields = ["%i", "%A", "%F", "%K", "%T", "%r", "%P", "%M", "%l", "%D", "%N", "%b", "%V", "%S", "%e", "%Z", "%j"]
    static let sacctFields = [
        "JobID", "JobIDRaw", "State", "Reason", "Partition", "Elapsed", "Timelimit", "ExitCode",
        "Submit", "Start", "End", "NNodes", "NodeList", "AllocTRES", "ReqTRES", "WorkDir",
        "StdOut", "StdErr", "JobName",
    ]

    /// One round trip: who am I, live queue, then accounting history.
    public static func snapshotCommand(historyDays: Int) -> String {
        """
        export TZ=UTC; S=$'\\x1f'
        echo "@@USER"; id -un
        echo "@@SQUEUE"; squeue --me -h -o "\(squeueFields.joined(separator: "${S}"))" || echo "@@WARN squeue failed"
        echo "@@SACCT"; sacct -X -n -P --delimiter="$S" -S now-\(max(historyDays, 1))days -o \(sacctFields.joined(separator: ",")) || echo "@@WARN sacct failed"
        """
    }

    public static func parseSnapshot(_ output: String, now: Date = .now) -> JobSnapshot {
        var section = ""
        var user = ""
        var queue: [SlurmJob] = []
        var history: [SlurmJob] = []
        var warnings: [String] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("@@WARN ") {
                warnings.append(String(line.dropFirst(7)))
                continue
            }
            if line.hasPrefix("@@") {
                section = line
                continue
            }
            switch section {
            case "@@USER": user = line.trimmingCharacters(in: .whitespaces)
            case "@@SQUEUE": if let job = parseSqueueLine(line) { queue.append(job) }
            case "@@SACCT": if let job = parseSacctLine(line) { history.append(job) }
            default: break
            }
        }

        // sacct knows log paths and exit codes; squeue knows live state and pending reasons.
        var merged: [String: SlurmJob] = [:]
        for job in history { merged[job.id] = job }
        for live in queue {
            guard var job = merged[live.id] else {
                merged[live.id] = live
                continue
            }
            job.state = live.state
            job.stateDetail = live.stateDetail
            job.reason = live.reason
            job.elapsed = live.elapsed ?? job.elapsed
            job.timeLimit = live.timeLimit ?? job.timeLimit
            job.startTime = live.startTime ?? job.startTime
            job.endTime = live.endTime ?? job.endTime
            job.nodeList = live.nodeList ?? job.nodeList
            merged[live.id] = job
        }
        // A job sacct still lists as active but squeue no longer shows has just finished;
        // keep sacct's word for it rather than inventing a state.
        let jobs = merged.values.sorted { lhs, rhs in
            if lhs.state.isActive != rhs.state.isActive { return lhs.state.isActive }
            return (lhs.submitTime ?? .distantPast, lhs.id) > (rhs.submitTime ?? .distantPast, rhs.id)
        }
        return JobSnapshot(user: user, jobs: jobs, fetchedAt: now, warnings: warnings)
    }

    static func parseSqueueLine(_ line: String) -> SlurmJob? {
        let f = line.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard f.count >= squeueFields.count else { return nil }
        let state = JobState(slurm: f[4])
        let reason = f[5] == "None" ? nil : f[5]
        return SlurmJob(
            id: f[0],
            rawID: f[1],
            name: f[16...].joined(separator: String(separator)),
            state: state,
            stateDetail: f[4],
            reason: reason,
            partition: f[6],
            elapsed: parseDuration(f[7]),
            timeLimit: parseDuration(f[8]),
            exitCode: nil,
            submitTime: parseTime(f[12]),
            startTime: parseTime(f[13]),
            endTime: parseTime(f[14]),
            nodeCount: Int(f[9]),
            nodeList: nonEmpty(f[10]),
            tres: nonEmpty(f[11]).flatMap { $0 == "N/A" ? nil : $0 },
            workDir: nonEmpty(f[15]),
            stdoutPath: nil,
            stderrPath: nil
        )
    }

    static func parseSacctLine(_ line: String) -> SlurmJob? {
        let f = line.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard f.count >= sacctFields.count else { return nil }
        let state = JobState(slurm: f[2])
        let workDir = nonEmpty(f[15])
        return SlurmJob(
            id: f[0],
            rawID: f[1],
            name: f[18...].joined(separator: String(separator)),
            state: state,
            stateDetail: f[2],
            reason: f[3] == "None" ? nil : nonEmpty(f[3]),
            partition: f[4],
            elapsed: parseDuration(f[5]),
            timeLimit: parseDuration(f[6]),
            exitCode: nonEmpty(f[7]),
            submitTime: parseTime(f[8]),
            startTime: parseTime(f[9]),
            endTime: state.isActive ? nil : parseTime(f[10]),
            nodeCount: Int(f[11]),
            nodeList: f[12] == "None assigned" ? nil : nonEmpty(f[12]),
            tres: nonEmpty(f[13]) ?? nonEmpty(f[14]),
            workDir: workDir,
            stdoutPath: nonEmpty(f[16]),
            stderrPath: nonEmpty(f[17])
        )
    }

    /// `1-23:20:09`, `05:37:08`, `5:02`, `UNLIMITED`.
    public static func parseDuration(_ text: String) -> TimeInterval? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.first?.isNumber == true else { return nil }
        var days = 0.0
        var clock = Substring(text)
        if let dash = text.firstIndex(of: "-") {
            days = Double(text[..<dash]) ?? 0
            clock = text[text.index(after: dash)...]
        }
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        let seconds: Double
        switch parts.count {
        case 3: seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: seconds = parts[0] * 60 + parts[1]
        case 1: seconds = parts[0] * 60 // bare numbers are minutes in Slurm
        default: return nil
        }
        return days * 86_400 + seconds
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    /// Times come back in UTC because the command exports `TZ=UTC`.
    public static func parseTime(_ text: String) -> Date? {
        timeFormatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    /// `gres/gpu=4` or `gres/gpu:h200=4` (and squeue's `gres/gpu:4` per node).
    public static func gpuCount(inTRES tres: String?) -> Int? {
        guard let tres else { return nil }
        var best: Int?
        for item in tres.split(separator: ",") {
            guard item.hasPrefix("gres/gpu") || item.hasPrefix("gres:gpu") else { continue }
            let value = item.split(whereSeparator: { $0 == "=" || $0 == ":" }).last.flatMap { Int($0) }
            if let value { best = max(best ?? 0, value) }
        }
        return best
    }

    /// Expands Slurm filename patterns (`%j`, `%x`, `%A_%a`, …) the way sbatch would.
    public static func expandLogPath(_ template: String?, for job: SlurmJob, user: String) -> String? {
        let arrayParts = job.id.split(separator: "_", maxSplits: 1).map(String.init)
        let isArray = arrayParts.count == 2
        let fallback = isArray ? "slurm-%A_%a.out" : "slurm-%j.out"
        guard let template = template ?? (job.workDir == nil ? nil : fallback) else { return nil }

        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            index = template.index(after: index)
            guard character == "%", index < template.endIndex else {
                output.append(character)
                continue
            }
            var width = ""
            while index < template.endIndex, template[index].isNumber {
                width.append(template[index])
                index = template.index(after: index)
            }
            guard index < template.endIndex else { break }
            let code = template[index]
            index = template.index(after: index)
            let value: String
            switch code {
            case "%": value = "%"
            case "j": value = job.rawID
            case "J": value = job.rawID
            case "A": value = isArray ? arrayParts[0] : job.rawID
            case "a": value = isArray ? arrayParts[1] : "4294967294"
            case "x": value = job.name
            case "u": value = user
            case "N": value = job.nodeList.map(firstNode) ?? ""
            case "n", "t": value = "0"
            case "s": value = "batch"
            default: value = "%" + width + String(code)
            }
            if let padding = Int(width), value.count < padding, value.allSatisfy(\.isNumber) {
                output += String(repeating: "0", count: padding - value.count) + value
            } else {
                output += value
            }
        }
        if !output.hasPrefix("/"), let workDir = job.workDir {
            output = workDir + "/" + output
        }
        return output
    }

    /// `gh[118-120]` → `gh118`.
    static func firstNode(_ list: String) -> String {
        guard let open = list.firstIndex(of: "[") else {
            return String(list.split(separator: ",").first ?? Substring(list))
        }
        let prefix = list[..<open]
        let first = list[list.index(after: open)...].prefix { $0.isNumber }
        return String(prefix + first)
    }

    public static func tailCommand(path: String, lines: Int) -> String {
        let quoted = shellQuote(path)
        return """
        export TZ=UTC
        stat -c '@@STAT %s %Y' -- \(quoted) 2>/dev/null || { echo "@@MISSING"; exit 0; }
        tail -n \(max(lines, 1)) -- \(quoted) | tail -c 262144
        """
    }

    public static func parseTail(_ output: String, path: String) -> LogTail {
        if output.hasPrefix("@@MISSING") {
            return LogTail(path: path, text: "", size: nil, modified: nil)
        }
        guard output.hasPrefix("@@STAT "), let newline = output.firstIndex(of: "\n") else {
            return LogTail(path: path, text: output, size: nil, modified: nil)
        }
        let stat = output[..<newline].split(separator: " ")
        let size = stat.count > 1 ? Int(stat[1]) : nil
        let modified = stat.count > 2 ? Double(stat[2]).map { Date(timeIntervalSince1970: $0) } : nil
        return LogTail(path: path, text: String(output[output.index(after: newline)...]), size: size, modified: modified)
    }

    /// Only plain job IDs (`123`, `123_4`) reach `scancel`.
    public static func cancelCommand(jobID: String) throws -> String {
        guard jobID.range(of: #"^[0-9]+(_[0-9]+)?$"#, options: .regularExpression) != nil else {
            throw TorchError.invalidJobID(jobID)
        }
        return "scancel \(jobID)"
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "Unknown" ? nil : trimmed
    }
}
