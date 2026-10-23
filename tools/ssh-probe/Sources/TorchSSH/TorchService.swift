import Foundation

/// Slurm operations over a `TorchConnection`.
public struct TorchService: Sendable {
    public let connection: TorchConnection

    public init(connection: TorchConnection) {
        self.connection = connection
    }

    public func snapshot(historyDays: Int = 7) async throws -> JobSnapshot {
        let result = try await connection.run(Slurm.snapshotCommand(historyDays: historyDays))
        guard result.stdout.contains("@@SQUEUE") else {
            throw TorchError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        var snapshot = Slurm.parseSnapshot(result.stdout)
        for index in snapshot.jobs.indices {
            let job = snapshot.jobs[index]
            snapshot.jobs[index].stdoutPath = Slurm.expandLogPath(job.stdoutPath, for: job, user: snapshot.user)
            // Without --error, Slurm writes stderr to the stdout file.
            snapshot.jobs[index].stderrPath = job.stderrPath.flatMap {
                Slurm.expandLogPath($0, for: job, user: snapshot.user)
            } ?? snapshot.jobs[index].stdoutPath
        }
        return snapshot
    }

    public func tail(path: String, lines: Int = 200) async throws -> LogTail {
        let result = try await connection.run(Slurm.tailCommand(path: path, lines: lines))
        guard result.exitCode == 0 else {
            throw TorchError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return Slurm.parseTail(result.stdout, path: path)
    }

    public func cancel(jobID: String) async throws {
        let result = try await connection.run(try Slurm.cancelCommand(jobID: jobID))
        guard result.exitCode == 0 else {
            throw TorchError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }
}
