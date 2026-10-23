import SwiftUI
import TorchKit

enum Format {
    /// `1d 23h`, `5h 37m`, `6m 2s`, `45s`.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let days = total / 86_400, hours = total % 86_400 / 3600, minutes = total % 3600 / 60, secs = total % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// Megabytes as `9.4 GB` / `512 MB`.
    static func memory(_ megabytes: Int) -> String {
        let gigabytes = Double(megabytes) / 1024
        if gigabytes < 1 { return "\(megabytes) MB" }
        return String(format: gigabytes >= 10 ? "%.0f GB" : "%.1f GB", gigabytes)
    }

    /// `NVIDIA GeForce RTX 5090` → `RTX 5090`.
    static func model(_ model: String) -> String {
        model.replacingOccurrences(of: "NVIDIA ", with: "").replacingOccurrences(of: "GeForce ", with: "")
    }

    /// Lab accounts are `grail_<name>`; the prefix is noise on a phone.
    static func user(_ name: String) -> String {
        name.hasPrefix("grail_") ? String(name.dropFirst(6)) : name
    }

    /// `python train.py --lr 3e-4` → `train.py --lr 3e-4` (drops the interpreter path).
    static func command(_ command: String) -> String {
        var words = command.split(separator: " ").map(String.init)
        if let first = words.first, first.hasPrefix("/") || first.hasPrefix("python") {
            words[0] = (first as NSString).lastPathComponent
            if words.count > 1, words[0].hasPrefix("python") { words.removeFirst() }
        }
        return words.joined(separator: " ")
    }
}

extension JobState {
    var label: String {
        switch self {
        case .outOfMemory: "Out of memory"
        case .nodeFail: "Node failure"
        case .bootFail: "Boot failure"
        default: rawValue.capitalized
        }
    }

    var color: Color {
        switch self {
        case .running, .configuring, .completing: .blue
        case .pending, .requeued, .suspended: .orange
        case .completed: .green
        case .cancelled, .preempted, .unknown: .secondary
        case .failed, .timeout, .outOfMemory, .nodeFail, .bootFail, .deadline: .red
        }
    }

    var symbol: String {
        switch self {
        case .running, .configuring, .completing: "play.circle.fill"
        case .pending, .requeued: "clock.fill"
        case .suspended: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .cancelled, .preempted: "xmark.circle.fill"
        case .timeout, .deadline: "timer"
        case .outOfMemory: "memorychip.fill"
        case .failed, .nodeFail, .bootFail: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

extension GPU.Availability {
    var color: Color {
        switch self {
        case .free: .green
        case .mine: .accentColor
        case .busy: .secondary
        }
    }
}

extension SlurmJob {
    /// Elapsed time extrapolated from the snapshot for running jobs.
    func elapsed(at date: Date, fetchedAt: Date) -> TimeInterval? {
        guard let elapsed else { return nil }
        return state == .running ? elapsed + max(date.timeIntervalSince(fetchedAt), 0) : elapsed
    }

    var resourceSummary: String {
        var parts: [String] = []
        if let gpus = gpuCount { parts.append("\(gpus) GPU") }
        if let nodes = nodeCount, nodes > 1 { parts.append("\(nodes) nodes") }
        parts.append(partition)
        return parts.joined(separator: " · ")
    }
}

struct StateBadge: View {
    let state: JobState

    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(state.color.opacity(0.14), in: Capsule())
    }
}

/// A thin capsule bar for utilization and memory.
struct Meter: View {
    let value: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: max(proxy.size.width * min(max(value, 0), 1), value > 0 ? 3 : 0))
            }
        }
        .frame(height: 5)
    }
}

/// Where a row's data came from, shown when it helps: `Torch` or a lab host.
struct SourceTag: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).imageScale(.small)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
}
