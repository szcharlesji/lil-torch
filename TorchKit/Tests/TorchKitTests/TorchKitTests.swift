import Foundation
import Testing
@testable import TorchKit

struct TorchKitTests {
    @Test func decodesAgentJobs() throws {
        // Shape copied from a live agent's /v1/torch/jobs.
        let json = """
        {"user":"cj2220","warnings":[],"fetchedAt":"2026-10-23T01:33:40Z","status":{"state":"ok","message":null},
         "jobs":[{"id":"19722779","rawID":"19722779","name":"shirt-v6-e300-full-interactive","state":"CANCELLED",
         "stateDetail":"CANCELLED by 3618864","reason":null,"partition":"h200_courant,h200_cds,h200_public",
         "elapsed":0.0,"timeLimit":1500.0,"exitCode":"0:0","submitTime":"2026-10-13T16:36:39Z","startTime":null,
         "endTime":"2026-10-13T16:37:39Z","nodeCount":1,"nodeList":null,
         "tres":"billing=4,cpu=4,gres/gpu=1,mem=32G,node=1","workDir":"/scratch/cj2220/X",
         "stdoutPath":"/scratch/cj2220/X/slurm-19722779.out","stderrPath":"/scratch/cj2220/X/slurm-19722779.out"},
         {"id":"1","rawID":"1","name":"x","state":"SOMETHING_NEW","stateDetail":"SOMETHING_NEW","reason":null,
         "partition":"p","elapsed":null,"timeLimit":null,"exitCode":null,"submitTime":null,"startTime":null,
         "endTime":null,"nodeCount":null,"nodeList":null,"tres":null,"workDir":null,"stdoutPath":null,"stderrPath":null}]}
        """
        let snapshot = try AgentClient.decoder.decode(JobSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.status?.state == .ok)
        #expect(snapshot.jobs[0].state == .cancelled)
        #expect(snapshot.jobs[0].gpuCount == 1)
        #expect(snapshot.jobs[0].endTime == ISO8601DateFormatter().date(from: "2026-10-13T16:37:39Z"))
        #expect(snapshot.jobs[1].state == .unknown)
    }

    @Test func decodesGPUsAndAvailability() throws {
        let json = """
        {"fetchedAt":"2026-10-23T01:33:40Z","user":"grail_charles","error":null,
         "unreachable":[{"host":"10.33.63.3","message":"[Errno 111] Connect call failed"}],
         "hosts":[{"name":"hestia","reportedAt":"Thu Oct 22 21:06:47 2026","driver":"570.153.02","gpus":[
           {"index":0,"model":"NVIDIA RTX A6000","temperature":81,"utilization":100,"memoryUsed":10947,"memoryTotal":49140,
            "users":[{"name":"grail_charles","memory":4846,"processes":1}],
            "processes":[{"pid":4242,"command":"python train.py","elapsed":3600,"memory":4846,"smUtilization":87}],"error":false},
           {"index":1,"model":"NVIDIA RTX A6000","temperature":30,"utilization":0,"memoryUsed":10,"memoryTotal":49140,
            "users":[],"processes":[],"error":false},
           {"index":2,"model":"((Unknown Error))","temperature":null,"utilization":null,"memoryUsed":null,
            "memoryTotal":null,"users":[],"processes":[],"error":true}]}]}
        """
        let snapshot = try AgentClient.decoder.decode(GPUSnapshot.self, from: Data(json.utf8))
        let gpus = snapshot.hosts[0].gpus
        #expect(gpus.map { $0.availability(for: "grail_charles") } == [.mine, .free, .busy])
        #expect(gpus[0].processes[0].smUtilization == 87)
    }

    @Test func pairingLinks() {
        let link = PairingLink("liltorch://add?url=http%3A%2F%2Forin-nano.example-tailnet.ts.net%3A8765&token=abc&name=orin")
        #expect(link?.url.absoluteString == "http://orin-nano.example-tailnet.ts.net:8765")
        #expect(link?.token == "abc")
        #expect(link?.name == "orin")
        #expect(PairingLink("  liltorch://add?url=http://h:1&token=t  ")?.name == "h")
        #expect(PairingLink("liltorch://add?url=http://h:1") == nil)
        #expect(PairingLink("https://example.com") == nil)
    }

    @Test func notificationPrefsMatchAgentKinds() {
        var prefs = NotificationPrefs()
        prefs.gpuFree = true
        #expect(prefs.allows("gpu_free"))
        #expect(prefs.allows("job_finished"))
        #expect(!prefs.allows("job_started"))
        #expect(!prefs.allows("made_up"))
    }
}
