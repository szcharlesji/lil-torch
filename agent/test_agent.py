"""Tests for the Lil Torch agent. Run: python3 -m unittest -v (from this directory)."""

import base64
import json
import os
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.request

import liltorch_agent as agent

US = "\x1f"

GPUSTAT = """\x1b[1m\x1b[37morion                       \x1b[0;10m  Thu Oct 22 21:06:47 2026  \x1b[1m\x1b[30m570.211.01\x1b[0;10m
[0] NVIDIA GeForce RTX 5090   | 68°C,  93 % | 23944 / 32607 MB | grail_alice(9616M) grail_bob(1422M) grail_bob(1422M) gdm(4M)
[1] NVIDIA GeForce RTX 5090   | 31°C,   0 % |    40 / 32607 MB | gdm(10M) gdm(10M)
(10.33.63.3) [Errno 111] Connect call failed ('10.33.63.3', 22)
hestia                        Thu Oct 22 21:06:47 2026  570.153.02
[2] NVIDIA RTX A6000          | 85°C, 100 % | 13595 / 49140 MB | grail_charles(4846M) grail(250M)
lambda-minerva                Thu Oct 22 21:06:41 2026  580.126.20
[2] ((Unknown Error))         |  ?°C,   ? % |     ? /     ? MB | (Not Supported)
"""


def sacct_line(state="RUNNING", job_id="19683229", end="Unknown"):
    return US.join([job_id, job_id, state, "QOSGrpGRES", "h200_courant", "01:00:00", "2-00:00:00", "0:0",
                    "2026-10-12T23:56:28", "2026-10-18T11:31:40", end, "1", "gh131",
                    "billing=32,cpu=32,gres/gpu=4,mem=256G,node=1", "", "/scratch/cj2220/X",
                    "sa/logs/shirt_v12_%j.out", "", "shirt|v12"])


SQUEUE = US.join(["19683229", "19683229", "N/A", "N/A", "RUNNING", "None", "h200_courant", "1:02:03",
                  "2-00:00:00", "1", "gh131", "gres/gpu:4", "2026-10-12T23:56:28", "2026-10-18T11:31:40",
                  "2026-10-20T11:31:40", "/scratch/cj2220/X", "shirt|v12"])
PENDING = US.join(["19700000_[1-4]", "19700000", "19700000", "N/A", "PENDING", "Priority", "b200", "0:00",
                   "1:00:00", "1", "", "gres/gpu:1", "2026-10-21T10:00:00", "2026-10-23T00:00:00", "N/A",
                   "/scratch/cj2220/X", "sweep"])


class SlurmTests(unittest.TestCase):
    def test_durations(self):
        self.assertEqual(agent.parse_duration("1-23:20:09"), 170409)
        self.assertEqual(agent.parse_duration("05:37:08"), 20228)
        self.assertEqual(agent.parse_duration("5:02"), 302)
        self.assertIsNone(agent.parse_duration("UNLIMITED"))

    def test_states(self):
        self.assertEqual(agent.slurm_state("CANCELLED by 3618864"), "CANCELLED")
        self.assertEqual(agent.slurm_state("something new"), "UNKNOWN")

    def test_snapshot_merges_queue_into_history(self):
        output = "@@USER\ncj2220\n@@SQUEUE\n%s\n%s\n@@SACCT\n%s\n" % (SQUEUE, PENDING, sacct_line())
        snapshot = agent.parse_snapshot(output)
        self.assertEqual(snapshot["user"], "cj2220")
        jobs = {job["id"]: job for job in snapshot["jobs"]}
        running = jobs["19683229"]
        self.assertEqual(running["name"], "shirt|v12")
        self.assertEqual(running["elapsed"], 3723)
        self.assertEqual(running["startTime"], "2026-10-18T11:31:40Z")
        self.assertIsNone(running["reason"])  # stale sacct reason dropped once running
        self.assertEqual(running["stdoutPath"], "/scratch/cj2220/X/sa/logs/shirt_v12_19683229.out")
        self.assertEqual(running["stderrPath"], running["stdoutPath"])
        queued = jobs["19700000_[1-4]"]
        self.assertEqual(queued["state"], "PENDING")
        self.assertEqual(queued["reason"], "Priority")

    def test_log_paths(self):
        job = {"id": "19508274_3", "rawID": "19508290", "name": "pr-S4", "workDir": "/w", "nodeList": "gh[118-120]"}
        self.assertEqual(agent.expand_log_path("logs/%x_%A_%a.out", job, "u"), "/w/logs/pr-S4_19508274_3.out")
        self.assertEqual(agent.expand_log_path("/s/%u/%N-%j-%4a.err", job, "u"), "/s/u/gh118-19508290-0003.err")
        self.assertEqual(agent.expand_log_path("100%%.log", job, "u"), "/w/100%.log")
        self.assertEqual(agent.expand_log_path(None, job, "u"), "/w/slurm-19508274_3.out")

    def test_job_events(self):
        before = agent.parse_snapshot("@@SQUEUE\n%s\n@@SACCT\n%s\n" % (SQUEUE, sacct_line()))["jobs"]
        after = agent.parse_snapshot("@@SQUEUE\n@@SACCT\n%s\n" % sacct_line("FAILED", end="2026-10-20T10:51:49"))["jobs"]
        events = agent.job_events(before, after)
        self.assertEqual(len(events), 1)
        kind, title, body, extra = events[0]
        self.assertEqual(kind, "job_finished")
        self.assertEqual(title, "shirt|v12 failed")
        self.assertIn("exit 0:0", body)
        self.assertTrue(extra["failed"])


class GPUTests(unittest.TestCase):
    def test_parse_gpustat(self):
        hosts, unreachable = agent.parse_gpustat(GPUSTAT)
        self.assertEqual([h["name"] for h in hosts], ["orion", "hestia", "lambda-minerva"])
        first = hosts[0]["gpus"][0]
        self.assertEqual((first["temperature"], first["utilization"], first["memoryUsed"]), (68, 93, 23944))
        self.assertEqual([(u["name"], u["memory"], u["processes"]) for u in first["users"]],
                         [("grail_alice", 9616, 1), ("grail_bob", 2844, 2)])
        self.assertEqual(hosts[0]["gpus"][1]["users"], [])  # gdm only: free
        self.assertTrue(hosts[2]["gpus"][0]["error"])
        self.assertEqual(unreachable[0]["host"], "10.33.63.3")

    def test_gpu_events(self):
        hosts, _ = agent.parse_gpustat(GPUSTAT)
        before = {"hosts": hosts}
        after_hosts, _ = agent.parse_gpustat(GPUSTAT.replace("grail_charles(4846M) grail(250M)", "")
                                             .replace("grail_alice(9616M) grail_bob(1422M) grail_bob(1422M)", ""))
        kinds = sorted(kind for kind, *_ in agent.gpu_events(before, {"hosts": after_hosts}, "grail_charles"))
        self.assertEqual(kinds, ["gpu_free", "gpu_free", "gpu_process_ended"])

    def test_parse_detail(self):
        text = "\n".join([
            "__GPUS__", "0, GPU-aaa", "1, GPU-bbb",
            "__PROCESSES__", "GPU-bbb, 4242, /usr/bin/python3, 4846", "GPU-aaa, 99, python, 10",
            "__PMON__", "# gpu pid type sm", "    1   4242     C    87",
            "__PS__", "4242 grail_charles 3600 python train.py --lr 3e-4", "99 someone 5 python",
        ])
        processes = agent.parse_detail(text, "grail_charles")
        self.assertEqual(list(processes), [1])
        self.assertEqual(processes[1][0], {"pid": 4242, "command": "python train.py --lr 3e-4", "elapsed": 3600,
                                           "memory": 4846, "smUtilization": 87})


class PushTests(unittest.TestCase):
    def test_es256_jwt_verifies_with_openssl(self):
        with tempfile.TemporaryDirectory() as directory:
            key = os.path.join(directory, "AuthKey_TEST.p8")
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                            "-out", key], check=True, capture_output=True)
            token = agent.es256_jwt(key, "KEYID12345", "TEAMID1234", issued_at=1792700000)
            header, claims, signature = token.split(".")
            pad = lambda s: s + "=" * (-len(s) % 4)
            self.assertEqual(json.loads(base64.urlsafe_b64decode(pad(header))), {"alg": "ES256", "kid": "KEYID12345"})
            self.assertEqual(json.loads(base64.urlsafe_b64decode(pad(claims)))["iss"], "TEAMID1234")
            raw = base64.urlsafe_b64decode(pad(signature))
            self.assertEqual(len(raw), 64)

            def integer(value):
                value = value.lstrip(b"\x00")
                if not value or value[0] & 0x80:
                    value = b"\x00" + value
                return b"\x02" + bytes([len(value)]) + value

            body = integer(raw[:32]) + integer(raw[32:])
            der = b"\x30" + bytes([len(body)]) + body
            public = os.path.join(directory, "public.pem")
            subprocess.run(["openssl", "pkey", "-in", key, "-pubout", "-out", public], check=True, capture_output=True)
            signature_file = os.path.join(directory, "sig.der")
            with open(signature_file, "wb") as handle:
                handle.write(der)
            verified = subprocess.run(["openssl", "dgst", "-sha256", "-verify", public, "-signature", signature_file],
                                      input=("%s.%s" % (header, claims)).encode(), capture_output=True)
            self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)

    def test_device_registration_rejects_junk(self):
        with tempfile.TemporaryDirectory() as directory:
            push = agent.Push(agent.default_config(), os.path.join(directory, "devices.json"), "test")
            with self.assertRaises(ValueError):
                push.register("not-a-token", "sandbox", "phone", {})
            push.register("ab" * 32, "production", "phone", {"gpu_free": True})
            device = push.devices()[0]
            self.assertEqual(device["environment"], "production")
            self.assertTrue(device["prefs"]["gpu_free"])
            self.assertTrue(device["prefs"]["job_finished"])
            self.assertFalse(push.configured)


class WebSocketTests(unittest.TestCase):
    def test_accept_key(self):
        self.assertEqual(agent.ws_accept("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")

    def test_frame_reader_unmasks_and_reassembles(self):
        def masked(opcode, payload, final=True):
            mask = b"\x01\x02\x03\x04"
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            return bytes([(0x80 if final else 0) | opcode, 0x80 | len(payload)]) + mask + data

        reader = agent.FrameReader()
        stream = masked(0x2, b"he", final=False) + masked(0x0, b"llo") + masked(0x1, b'{"type":"resize"}')
        self.assertEqual(reader.feed(stream[:5]), [])
        self.assertEqual(reader.feed(stream[5:]), [(0x2, b"hello"), (0x1, b'{"type":"resize"}')])


class ServerTests(unittest.TestCase):
    """A real agent on 127.0.0.1 with GPUs from a fixed text and Torch off."""

    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        agent.STATE_DIR = cls.directory.name
        sample = os.path.join(cls.directory.name, "gpustat.txt")
        with open(sample, "w") as handle:
            handle.write(GPUSTAT)
        config = agent.default_config()
        config.update(name="test", token="secret-token", port=0, bind=["127.0.0.1"])
        config["gpus"].update(enabled=True, source="command", command="cat %s" % sample, user="grail_charles", detail=False)
        cls.agent = agent.Agent(config)
        agent.Handler.agent = cls.agent
        cls.server = agent.Server(("127.0.0.1", 0), agent.Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.directory.cleanup()

    def get(self, path, token="secret-token"):
        request = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path),
                                         headers={"Authorization": "Bearer " + token})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def test_auth(self):
        self.assertEqual(self.get("/v1/info", token="wrong")[0], 401)
        self.assertEqual(self.get("/healthz", token="")[0], 200)

    def test_info_and_gpus(self):
        status, info = self.get("/v1/info")
        self.assertEqual(status, 200)
        self.assertEqual(info["features"], {"torch": False, "gpus": True, "terminal": True, "push": False})
        status, gpus = self.get("/v1/gpus")
        self.assertEqual(status, 200)
        self.assertEqual(len(gpus["hosts"]), 3)
        self.assertEqual(self.get("/v1/torch/jobs")[0], 400)

    def test_events(self):
        self.agent.monitor.events.add("test", "hello", "world")
        status, body = self.get("/v1/events?since=0")
        self.assertEqual(status, 200)
        self.assertEqual(body["events"][-1]["title"], "hello")
        self.assertEqual(self.get("/v1/events?since=%d" % body["latest"])[1]["events"], [])

    def test_local_terminal(self):
        os.environ["SHELL"] = "/bin/sh"
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        sock.sendall(("GET /v1/terminal?target=local&cols=100&rows=30 HTTP/1.1\r\nHost: x\r\n"
                      "Authorization: Bearer secret-token\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        response = b""
        while b"\r\n\r\n" not in response:
            response += sock.recv(4096)
        head, _, rest = response.partition(b"\r\n\r\n")
        self.assertIn(b"101", head.split(b"\r\n")[0])
        self.assertIn(b"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", head)

        def send(opcode, payload):
            mask = b"\x00\x00\x00\x00"
            sock.sendall(bytes([0x80 | opcode, 0x80 | len(payload)]) + mask + payload)

        send(0x2, b"echo SIZE=$(stty size); exit\n")
        output = rest
        deadline = time.time() + 10
        while time.time() < deadline and b"SIZE=30 100" not in output:
            chunk = sock.recv(65536)
            if not chunk:
                break
            output += chunk
        sock.close()
        self.assertIn(b"SIZE=30 100", output)



class InstallerTests(unittest.TestCase):
    def test_install_sh_is_up_to_date(self):
        import build_installer
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "..", "install.sh")) as handle:
            self.assertEqual(handle.read(), build_installer.build(),
                             "install.sh is stale: run python3 agent/build_installer.py")


if __name__ == "__main__":
    unittest.main()
