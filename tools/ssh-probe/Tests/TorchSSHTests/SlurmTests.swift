import Foundation
import Testing
@testable import TorchSSH

struct SlurmTests {
    let us = "\u{1F}"

    @Test func durations() {
        #expect(Slurm.parseDuration("1-23:20:09") == 170_409) // 1 day + 23:20:09
        #expect(Slurm.parseDuration("05:37:08") == 20_228)
        #expect(Slurm.parseDuration("5:02") == 302)
        #expect(Slurm.parseDuration("UNLIMITED") == nil)
        #expect(Slurm.parseDuration("INVALID") == nil)
    }

    @Test func states() {
        #expect(JobState(slurm: "CANCELLED by 3618864") == .cancelled)
        #expect(JobState(slurm: "RUNNING") == .running)
        #expect(JobState(slurm: "OUT_OF_MEMORY") == .outOfMemory)
        #expect(JobState(slurm: "something new") == .unknown)
    }

    @Test func gpus() {
        #expect(Slurm.gpuCount(inTRES: "billing=32,cpu=32,gres/gpu=4,mem=256G,node=1") == 4)
        #expect(Slurm.gpuCount(inTRES: "cpu=8,gres/gpu:h200=2,gres/gpu=2") == 2)
        #expect(Slurm.gpuCount(inTRES: "gres/gpu:4") == 4)
        #expect(Slurm.gpuCount(inTRES: "billing=4,cpu=4,mem=24G,node=1") == nil)
    }

    @Test func snapshotMergesQueueIntoHistory() {
        let sacct = ["19683229", "19683229", "RUNNING", "None", "h200_courant", "01:00:00", "2-00:00:00", "0:0",
                     "2026-10-12T23:56:28", "2026-10-18T11:31:40", "Unknown", "1", "gh131",
                     "billing=32,cpu=32,gres/gpu=4,mem=256G,node=1", "", "/scratch/cj2220/X",
                     "/scratch/cj2220/X/sa/logs/shirt_v12_%j.out", "", "shirt|v12"].joined(separator: us)
        let squeue = ["19683229", "19683229", "N/A", "N/A", "RUNNING", "None", "h200_courant", "1:02:03",
                      "2-00:00:00", "1", "gh131", "gres/gpu:4", "2026-10-12T23:56:28", "2026-10-18T11:31:40",
                      "2026-10-20T11:31:40", "/scratch/cj2220/X", "shirt|v12"].joined(separator: us)
        let pending = ["19700000_[1-4]", "19700000", "19700000", "N/A", "PENDING", "Priority", "b200", "0:00",
                       "1:00:00", "1", "", "gres/gpu:1", "2026-10-21T10:00:00", "2026-10-23T00:00:00", "N/A",
                       "/scratch/cj2220/X", "sweep"].joined(separator: us)
        let output = "@@USER\ncj2220\n@@SQUEUE\n\(squeue)\n\(pending)\n@@SACCT\n\(sacct)\n"

        let snapshot = Slurm.parseSnapshot(output)
        #expect(snapshot.user == "cj2220")
        #expect(snapshot.jobs.count == 2)
        let running = snapshot.jobs.first { $0.id == "19683229" }!
        #expect(running.name == "shirt|v12")
        #expect(running.elapsed == 3723)
        #expect(running.gpuCount == 4)
        #expect(running.stdoutPath == "/scratch/cj2220/X/sa/logs/shirt_v12_%j.out")
        let queued = snapshot.jobs.first { $0.id == "19700000_[1-4]" }!
        #expect(queued.state == .pending)
        #expect(queued.reason == "Priority")
        #expect(queued.startTime == Slurm.parseTime("2026-10-23T00:00:00"))
    }

    @Test func logPaths() {
        var job = SlurmJob(id: "19508274_3", rawID: "19508290", name: "pr-S4", state: .running, stateDetail: "RUNNING",
                           partition: "b200", nodeList: "gh[118-120]", workDir: "/scratch/cj2220/X")
        #expect(Slurm.expandLogPath("logs/%x_%A_%a.out", for: job, user: "cj2220") == "/scratch/cj2220/X/logs/pr-S4_19508274_3.out")
        #expect(Slurm.expandLogPath("/s/%u/%N-%j-%4a.err", for: job, user: "cj2220") == "/s/cj2220/gh118-19508290-0003.err")
        #expect(Slurm.expandLogPath("100%%.log", for: job, user: "u") == "/scratch/cj2220/X/100%.log")
        #expect(Slurm.expandLogPath(nil, for: job, user: "u") == "/scratch/cj2220/X/slurm-19508274_3.out")
        job.id = "123"
        job.rawID = "123"
        #expect(Slurm.expandLogPath(nil, for: job, user: "u") == "/scratch/cj2220/X/slurm-123.out")
    }

    @Test func cancelOnlyAcceptsJobIDs() throws {
        #expect(try Slurm.cancelCommand(jobID: "123_4") == "scancel 123_4")
        #expect(throws: TorchError.self) { try Slurm.cancelCommand(jobID: "123; rm -rf ~") }
    }

    @Test func tailParsing() {
        let tail = Slurm.parseTail("@@STAT 2048 1792692135\nepoch 3 loss 0.12\n", path: "/x")
        #expect(tail.size == 2048)
        #expect(tail.text == "epoch 3 loss 0.12\n")
        #expect(Slurm.parseTail("@@MISSING\n", path: "/x").size == nil)
    }

    @Test func publicKeyLine() {
        let key = SSHKeys.generate()
        let line = SSHKeys.authorizedKeyLine(for: key, comment: "lil-torch")
        #expect(line.hasPrefix("ssh-ed25519 AAAA"))
        #expect(line.hasSuffix(" lil-torch"))
        #expect(SSHKeys.fingerprint(ofPublicKeyLine: line)?.hasPrefix("SHA256:") == true)
    }
}
