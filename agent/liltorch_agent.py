#!/usr/bin/env python3
"""Lil Torch agent.

Runs on a lab machine that can reach NYU Torch without the VPN. It keeps an
eye on your Slurm jobs (through an SSH ControlMaster connection to Torch) and
on the lab's GPUs, remembers what changed, and serves all of it to the Lil
Torch iOS app over HTTP on the machine's Tailscale address.

Standard library only; Python 3.8+.

    liltorch_agent.py setup [--netid NETID] [--gpus auto|none|nvidia-smi|URL]
    liltorch_agent.py serve
    liltorch_agent.py pair
    liltorch_agent.py status
"""

import argparse
import base64
import datetime as dt
import errno
import fcntl
import hashlib
import hmac
import http.server
import json
import os
import pty
import re
import secrets
import select
import shlex
import shutil
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import urllib.parse
import urllib.request
import warnings

# The terminal forks a pseudo-terminal from a threaded server; the child execs at once.
warnings.filterwarnings("ignore", category=DeprecationWarning, message=".*fork.*")

VERSION = "0.1.0"

HOME = os.path.expanduser("~")
CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.join(HOME, ".config")), "lil-torch")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local", "state")), "lil-torch")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")
INSTALL_DIR = os.path.join(HOME, ".local", "share", "lil-torch")
AGENT_PATH = os.path.join(INSTALL_DIR, "liltorch_agent.py")
RELAY_DIR = os.path.join(CONFIG_DIR, "relay")
UNIT_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.join(HOME, ".config")), "systemd", "user")
LAB_GPUSTAT_URL = "http://192.168.100.83:8000/gpustat.ansi"  # GRAIL's gpustat-web on discovery
TORCH_LOGIN_HOST = "login.torch.hpc.nyu.edu"
DEFAULT_TOPIC = "GRAIL.LilTorch"
SEP = "\x1f"


def log(message):
    sys.stderr.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message))
    sys.stderr.flush()


def now_iso():
    return iso(dt.datetime.now(dt.timezone.utc))


def iso(value):
    if value is None:
        return None
    return value.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(argv, stdin=None, timeout=60):
    """Runs a command and returns (exit status, stdout, stderr) as text."""
    try:
        completed = subprocess.run(
            argv, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout, universal_newlines=True, errors="replace",
        )
        return completed.returncode, completed.stdout, completed.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %ds" % timeout
    except OSError as error:
        return 127, "", str(error)


# --------------------------------------------------------------------------
# Configuration and state


def default_config():
    return {
        "name": socket.gethostname().split(".")[0],
        "port": 8765,
        "bind": [],  # empty: this machine's Tailscale addresses
        "token": "",
        "torch": {"enabled": False, "ssh_host": "torch", "history_days": 7, "poll_seconds": 30},
        "gpus": {"enabled": False, "source": "url", "url": LAB_GPUSTAT_URL, "command": "",
                 "user": os.environ.get("USER", ""), "detail": True, "poll_seconds": 30},
        "terminal": {"enabled": True},
        "apns": {"key_path": "", "key_id": "", "team_id": "", "topic": DEFAULT_TOPIC},
        "relay": {"enabled": False, "port": 0},
    }


def merged(base, override):
    result = dict(base)
    for key, value in (override or {}).items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merged(result[key], value)
        else:
            result[key] = value
    return result


def load_config(path=CONFIG_PATH):
    try:
        with open(path) as handle:
            return merged(default_config(), json.load(handle))
    except FileNotFoundError:
        return default_config()


def save_json(path, value, mode=0o600):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w") as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")
    os.chmod(temporary, mode)
    os.replace(temporary, path)


def load_json(path, default):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (FileNotFoundError, ValueError):
        return default


# --------------------------------------------------------------------------
# Slurm (runs on Torch over SSH)

SQUEUE_FIELDS = ["%i", "%A", "%F", "%K", "%T", "%r", "%P", "%M", "%l", "%D", "%N", "%b", "%V", "%S", "%e", "%Z", "%j"]
SACCT_FIELDS = ["JobID", "JobIDRaw", "State", "Reason", "Partition", "Elapsed", "Timelimit", "ExitCode",
                "Submit", "Start", "End", "NNodes", "NodeList", "AllocTRES", "ReqTRES", "WorkDir",
                "StdOut", "StdErr", "JobName"]
ACTIVE_STATES = {"PENDING", "RUNNING", "CONFIGURING", "COMPLETING", "SUSPENDED", "REQUEUED"}
FAILURE_STATES = {"FAILED", "TIMEOUT", "OUT_OF_MEMORY", "NODE_FAIL", "BOOT_FAIL", "DEADLINE"}
KNOWN_STATES = ACTIVE_STATES | FAILURE_STATES | {"COMPLETED", "CANCELLED", "PREEMPTED"}


def snapshot_script(history_days):
    return "\n".join([
        "export TZ=UTC; S=$'\\x1f'",
        'echo "@@USER"; id -un',
        'echo "@@SQUEUE"; squeue --me -h -o "%s" || echo "@@WARN squeue failed"' % "${S}".join(SQUEUE_FIELDS),
        'echo "@@SACCT"; sacct -X -n -P --delimiter="$S" -S now-%ddays -o %s || echo "@@WARN sacct failed"'
        % (max(int(history_days), 1), ",".join(SACCT_FIELDS)),
        "",
    ])


def slurm_state(text):
    word = (text.split() or [text])[0].strip("+") if text else ""
    return word if word in KNOWN_STATES else "UNKNOWN"


def parse_duration(text):
    text = (text or "").strip()
    if not text or not text[0].isdigit():
        return None
    days = 0
    if "-" in text:
        day_text, text = text.split("-", 1)
        days = int(day_text) if day_text.isdigit() else 0
    try:
        parts = [float(part) for part in text.split(":")]
    except ValueError:
        return None
    if len(parts) == 3:
        seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
    elif len(parts) == 2:
        seconds = parts[0] * 60 + parts[1]
    elif len(parts) == 1:
        seconds = parts[0] * 60  # bare numbers are minutes in Slurm
    else:
        return None
    return days * 86400 + seconds


def parse_slurm_time(text):
    """Slurm prints times in TZ=UTC because the script exports it."""
    try:
        return dt.datetime.strptime(text.strip(), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc)
    except (ValueError, AttributeError):
        return None


def non_empty(text):
    text = (text or "").strip()
    return None if text in ("", "Unknown", "None", "N/A", "None assigned") else text


def parse_squeue_line(line):
    f = line.split(SEP)
    if len(f) < len(SQUEUE_FIELDS):
        return None
    return {
        "id": f[0], "rawID": f[1], "name": SEP.join(f[16:]),
        "state": slurm_state(f[4]), "stateDetail": f[4], "reason": non_empty(f[5]),
        "partition": f[6], "elapsed": parse_duration(f[7]), "timeLimit": parse_duration(f[8]),
        "exitCode": None, "submitTime": iso(parse_slurm_time(f[12])),
        # For pending jobs this is Slurm's estimated start.
        "startTime": iso(parse_slurm_time(f[13])), "endTime": iso(parse_slurm_time(f[14])),
        "nodeCount": int(f[9]) if f[9].isdigit() else None, "nodeList": non_empty(f[10]),
        "tres": non_empty(f[11]), "workDir": non_empty(f[15]), "stdoutPath": None, "stderrPath": None,
    }


def parse_sacct_line(line):
    f = line.split(SEP)
    if len(f) < len(SACCT_FIELDS):
        return None
    state = slurm_state(f[2])
    return {
        "id": f[0], "rawID": f[1], "name": SEP.join(f[18:]),
        "state": state, "stateDetail": f[2], "reason": non_empty(f[3]),
        "partition": f[4], "elapsed": parse_duration(f[5]), "timeLimit": parse_duration(f[6]),
        "exitCode": non_empty(f[7]), "submitTime": iso(parse_slurm_time(f[8])),
        "startTime": iso(parse_slurm_time(f[9])),
        "endTime": None if state in ACTIVE_STATES else iso(parse_slurm_time(f[10])),
        "nodeCount": int(f[11]) if f[11].isdigit() else None, "nodeList": non_empty(f[12]),
        "tres": non_empty(f[13]) or non_empty(f[14]), "workDir": non_empty(f[15]),
        "stdoutPath": non_empty(f[16]), "stderrPath": non_empty(f[17]),
    }


def parse_snapshot(output):
    section, user, queue, history, warnings = "", "", [], [], []
    for line in output.split("\n"):
        if not line:
            continue
        if line.startswith("@@WARN "):
            warnings.append(line[7:])
        elif line.startswith("@@"):
            section = line
        elif section == "@@USER":
            user = line.strip()
        elif section == "@@SQUEUE":
            job = parse_squeue_line(line)
            if job:
                queue.append(job)
        elif section == "@@SACCT":
            job = parse_sacct_line(line)
            if job:
                history.append(job)

    # sacct knows log paths and exit codes; squeue knows live state and pending reasons.
    jobs = {job["id"]: job for job in history}
    for live in queue:
        job = jobs.get(live["id"])
        if job is None:
            jobs[live["id"]] = live
            continue
        for key in ("state", "stateDetail", "reason"):
            job[key] = live[key]
        for key in ("elapsed", "timeLimit", "startTime", "endTime", "nodeList"):
            if live[key] is not None:
                job[key] = live[key]

    for job in jobs.values():
        if job["state"] != "PENDING":
            job["reason"] = None  # sacct keeps the last pending reason after a job starts
        job["stdoutPath"] = expand_log_path(job["stdoutPath"], job, user)
        # Without --error, Slurm writes stderr to the stdout file.
        job["stderrPath"] = expand_log_path(job["stderrPath"], job, user) if job["stderrPath"] else job["stdoutPath"]

    ordered = sorted(jobs.values(), key=lambda j: (j["state"] in ACTIVE_STATES, j["submitTime"] or "", j["id"]), reverse=True)
    return {"user": user, "jobs": ordered, "warnings": warnings}


def first_node(node_list):
    match = re.match(r"([^\[,]+)(?:\[(\d+))?", node_list or "")
    if not match:
        return ""
    return match.group(1) + (match.group(2) or "")


def expand_log_path(template, job, user):
    """Expands sbatch filename patterns (%j, %x, %A_%a, ...)."""
    parts = job["id"].split("_", 1)
    is_array = len(parts) == 2
    if template is None:
        if not job.get("workDir"):
            return None
        template = "slurm-%A_%a.out" if is_array else "slurm-%j.out"

    def replace(match):
        width, code = match.group(1), match.group(2)
        values = {
            "%": "%", "j": job["rawID"], "J": job["rawID"],
            "A": parts[0] if is_array else job["rawID"],
            "a": parts[1] if is_array else "4294967294",
            "x": job["name"], "u": user, "N": first_node(job.get("nodeList")),
            "n": "0", "t": "0", "s": "batch",
        }
        value = values.get(code)
        if value is None:
            return match.group(0)
        if width and value.isdigit():
            value = value.zfill(int(width))
        return value

    path = re.sub(r"%(\d*)([%jJAaxuNnts])", replace, template)
    if not path.startswith("/") and job.get("workDir"):
        path = job["workDir"].rstrip("/") + "/" + path
    return path


class Torch:
    """Slurm on Torch through this machine's SSH ControlMaster to it."""

    def __init__(self, config):
        self.host = config["torch"]["ssh_host"]
        self.history_days = config["torch"]["history_days"]
        self.lock = threading.Lock()

    def ssh(self, script, timeout=90):
        return run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", self.host, "bash -s"],
                   stdin=script, timeout=timeout)

    def master_alive(self):
        status, _, err = run(["ssh", "-O", "check", self.host], timeout=10)
        if status == 0:
            return True
        return None if "No ControlPath" in err else False

    def login_problem(self, status, err):
        """Distinguishes "log in again" from other failures."""
        if self.master_alive() is False:
            return True
        return status == 255 and re.search(r"Permission denied|keyboard-interactive|password", err) is not None

    def snapshot(self):
        status, out, err = self.ssh(snapshot_script(self.history_days))
        if "@@SQUEUE" not in out:
            if self.login_problem(status, err):
                raise LoginRequired(err.strip())
            raise RuntimeError(err.strip() or "ssh exited with status %d" % status)
        snapshot = parse_snapshot(out)
        snapshot["fetchedAt"] = now_iso()
        return snapshot

    def tail(self, path, lines):
        quoted = shlex.quote(path)
        script = "stat -c '@@STAT %%s %%Y' -- %s 2>/dev/null || { echo @@MISSING; exit 0; }\n" \
                 "tail -n %d -- %s | tail -c 262144\n" % (quoted, max(int(lines), 1), quoted)
        status, out, err = self.ssh(script, timeout=60)
        if status != 0:
            raise RuntimeError(err.strip() or "tail failed")
        if out.startswith("@@MISSING"):
            return {"path": path, "text": "", "size": None, "modified": None}
        header, _, body = out.partition("\n")
        fields = header.split()
        size = int(fields[1]) if len(fields) > 1 and fields[1].isdigit() else None
        modified = dt.datetime.fromtimestamp(int(fields[2]), dt.timezone.utc) if len(fields) > 2 and fields[2].isdigit() else None
        return {"path": path, "text": body, "size": size, "modified": iso(modified)}

    def cancel(self, job_id):
        if not re.fullmatch(r"\d+(_\d+)?", job_id):
            raise ValueError("%s is not a job ID" % job_id)
        status, _, err = self.ssh("scancel %s\n" % job_id, timeout=30)
        if status != 0:
            raise RuntimeError(err.strip() or "scancel failed")


class LoginRequired(Exception):
    pass


# --------------------------------------------------------------------------
# Lab GPUs (gpustat-web text, or local nvidia-smi)

HOST_HEADER = re.compile(
    r"^(\S+)\s+((?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+[A-Za-z]{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(\S+)$")
GPU_IDENTITY = re.compile(r"^\[(\d+)\]\s+(.+?)\s*$")
ALLOCATION = re.compile(r"([A-Za-z0-9._-]+)\((\d+)M\)")
UNREACHABLE = re.compile(r"^\((.+?)\)\s+(.*)$")
ANSI = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]")
SYSTEM_ACCOUNTS = {"gdm", "root", "xorg", "gnome-shell"}


def maybe_int(text):
    try:
        return int(text)
    except (TypeError, ValueError):
        return None


def parse_gpustat(text):
    hosts, unreachable, current = [], [], None
    for raw in ANSI.sub("", text).splitlines():
        line = raw.strip()
        if not line:
            continue
        header = HOST_HEADER.match(line)
        if header:
            current = {"name": header.group(1), "reportedAt": header.group(2),
                       "driver": header.group(3), "gpus": []}
            hosts.append(current)
            continue
        if line.startswith("[") and current is not None:
            gpu = parse_gpu_line(line)
            if gpu:
                current["gpus"].append(gpu)
            continue
        problem = UNREACHABLE.match(line)
        if problem:
            unreachable.append({"host": problem.group(1), "message": problem.group(2)})
    return hosts, unreachable


def parse_gpu_line(line):
    columns = [part.strip() for part in line.split("|")]
    identity = GPU_IDENTITY.match(columns[0]) if columns else None
    if len(columns) < 4 or not identity:
        return None
    model = identity.group(2)
    temperature = re.search(r"(\d+|\?)°C", columns[1])
    utilization = re.search(r"(\d+|\?)\s*%", columns[1])
    memory = re.search(r"(\d+|\?)\s*/\s*(\d+|\?)\s*MB", columns[2])
    users = {}
    for name, megabytes in ALLOCATION.findall(columns[3]):
        if name.lower() in SYSTEM_ACCOUNTS:
            continue
        entry = users.setdefault(name, {"name": name, "memory": 0, "processes": 0})
        entry["memory"] += int(megabytes)
        entry["processes"] += 1
    memory_total = maybe_int(memory.group(2)) if memory else None
    return {
        "index": int(identity.group(1)), "model": model,
        "temperature": maybe_int(temperature.group(1)) if temperature else None,
        "utilization": maybe_int(utilization.group(1)) if utilization else None,
        "memoryUsed": maybe_int(memory.group(1)) if memory else None,
        "memoryTotal": memory_total,
        "users": sorted(users.values(), key=lambda u: -u["memory"]),
        "processes": [],
        "error": "error" in model.lower() or memory_total is None,
    }


def local_gpustat():
    """Formats local nvidia-smi output like gpustat so one parser handles both."""
    status, out, err = run(["nvidia-smi", "--query-gpu=index,name,temperature.gpu,utilization.gpu,memory.used,memory.total,driver_version",
                            "--format=csv,noheader,nounits"], timeout=20)
    if status != 0:
        raise RuntimeError(err.strip() or "nvidia-smi failed")
    rows = [[c.strip() for c in row.split(",")] for row in out.strip().splitlines() if row.strip()]
    driver = rows[0][6] if rows and len(rows[0]) > 6 else "?"
    lines = ["%s  %s  %s" % (socket.gethostname().split(".")[0], time.strftime("%a %b %d %H:%M:%S %Y"), driver)]
    for row in rows:
        if len(row) >= 6:
            lines.append("[%s] %s | %s°C, %s %% | %s / %s MB | " % tuple(row[:6]))
    return "\n".join(lines)


DETAIL_PROBE = r"""
echo __GPUS__
nvidia-smi --query-gpu=index,uuid --format=csv,noheader,nounits
echo __PROCESSES__
nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true
echo __PMON__
nvidia-smi pmon -c 1 -s u 2>/dev/null || true
echo __PS__
pids=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | tr '\n' ',' | sed 's/,$//')
[ -n "$pids" ] && ps -o pid=,user:64=,etimes=,args= -p "$pids" 2>/dev/null || true
"""


def parse_detail(text, user):
    """Processes per GPU index from DETAIL_PROBE output, for one user."""
    sections, current = {}, None
    for line in text.splitlines():
        if line.startswith("__") and line.endswith("__"):
            current = line.strip("_")
            sections[current] = []
        elif current:
            sections[current].append(line)
    index_of = {}
    for line in sections.get("GPUS", []):
        fields = [part.strip() for part in line.split(",")]
        if len(fields) >= 2 and fields[0].isdigit():
            index_of[fields[1]] = int(fields[0])
    sm = {}
    for line in sections.get("PMON", []):
        fields = line.split()
        if len(fields) >= 4 and not line.lstrip().startswith("#") and fields[1].isdigit():
            sm[int(fields[1])] = maybe_int(fields[3])
    meta = {}
    for line in sections.get("PS", []):
        fields = line.split(None, 3)
        if len(fields) == 4 and fields[0].isdigit():
            meta[int(fields[0])] = {"user": fields[1], "elapsed": maybe_int(fields[2]), "command": fields[3]}
    processes = {}
    for line in sections.get("PROCESSES", []):
        fields = [part.strip() for part in line.split(",")]
        if len(fields) < 4 or fields[0] not in index_of or not fields[1].isdigit():
            continue
        pid = int(fields[1])
        info = meta.get(pid, {})
        if info.get("user") != user:
            continue
        processes.setdefault(index_of[fields[0]], []).append({
            "pid": pid, "command": info.get("command") or os.path.basename(fields[2]),
            "elapsed": info.get("elapsed"), "memory": maybe_int(fields[3]), "smUtilization": sm.get(pid),
        })
    return processes


class LabGPUs:
    def __init__(self, config):
        gpus = config["gpus"]
        self.source = gpus["source"]
        self.url = gpus["url"]
        self.command = gpus["command"]
        self.user = gpus["user"]
        self.detail = gpus["detail"]
        self.local = socket.gethostname().split(".")[0]

    def fetch_text(self):
        if self.source == "nvidia-smi":
            return local_gpustat()
        if self.source == "command":
            status, out, err = run(["/bin/sh", "-c", self.command], timeout=30)
            if status != 0:
                raise RuntimeError(err.strip() or "GPU command failed")
            return out
        with urllib.request.urlopen(self.url, timeout=15) as response:
            return response.read().decode("utf-8", "replace")

    def snapshot(self):
        hosts, unreachable = parse_gpustat(self.fetch_text())
        if self.detail and self.user:
            self.add_my_processes(hosts)
        return {"fetchedAt": now_iso(), "user": self.user, "hosts": hosts, "unreachable": unreachable}

    def add_my_processes(self, hosts):
        """Asks hosts where you hold GPU memory for your processes' PIDs, runtimes and commands."""
        mine = [h for h in hosts if any(u["name"] == self.user for g in h["gpus"] for u in g["users"])]
        results = {}

        def probe(host):
            name = host["name"]
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", name):
                return
            argv = ["/bin/sh", "-c", DETAIL_PROBE] if name == self.local else \
                ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", name, "/bin/sh", "-s"]
            status, out, err = run(argv, stdin=None if name == self.local else DETAIL_PROBE, timeout=20)
            results[name] = parse_detail(out, self.user) if status == 0 else err.strip() or "probe failed"

        threads = [threading.Thread(target=probe, args=(h,)) for h in mine]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        for host in mine:
            result = results.get(host["name"])
            if isinstance(result, str):
                host["detailError"] = result
                continue
            for gpu in host["gpus"]:
                gpu["processes"] = (result or {}).get(gpu["index"], [])


# --------------------------------------------------------------------------
# Events and push


class Events:
    """A short history of things worth telling you about, numbered for polling."""

    def __init__(self, path, limit=300):
        self.path = path
        self.limit = limit
        self.lock = threading.Lock()
        stored = load_json(path, {"seq": 0, "events": []})
        self.seq = stored.get("seq", 0)
        self.events = stored.get("events", [])
        self.listeners = []

    def add(self, kind, title, body, **extra):
        with self.lock:
            self.seq += 1
            event = dict(extra, seq=self.seq, kind=kind, title=title, body=body, time=now_iso())
            self.events = (self.events + [event])[-self.limit:]
            save_json(self.path, {"seq": self.seq, "events": self.events})
        log("event %s: %s" % (kind, title))
        for listener in self.listeners:
            try:
                listener(event)
            except Exception as error:  # a push failure must not stop polling
                log("event listener failed: %s" % error)
        return event

    def since(self, seq):
        with self.lock:
            return [e for e in self.events if e["seq"] > seq], self.seq


def duration_text(seconds):
    if seconds is None:
        return ""
    seconds = int(seconds)
    days, hours, minutes = seconds // 86400, seconds % 86400 // 3600, seconds % 3600 // 60
    if days:
        return "%dd %dh" % (days, hours)
    if hours:
        return "%dh %dm" % (hours, minutes)
    return "%dm %ds" % (minutes, seconds % 60)


def job_events(previous, current):
    """(kind, title, body, extra) for each job that started or finished between two snapshots."""
    before = {job["id"]: job for job in previous}
    changes = []
    for job in current:
        old = before.get(job["id"])
        if old is None or old["state"] == job["state"]:
            continue
        details = [job["id"], job["partition"]]
        if old["state"] in ACTIVE_STATES and job["state"] not in ACTIVE_STATES:
            if job.get("elapsed") is not None:
                details.append("ran " + duration_text(job["elapsed"]))
            if job["state"] in FAILURE_STATES and job.get("exitCode"):
                details.append("exit " + job["exitCode"])
            word = job["state"].replace("_", " ").lower()
            changes.append(("job_finished", "%s %s" % (job["name"], word), " · ".join(details),
                            {"jobID": job["id"], "state": job["state"], "failed": job["state"] in FAILURE_STATES}))
        elif old["state"] == "PENDING" and job["state"] == "RUNNING":
            if job.get("nodeList"):
                details.append(job["nodeList"])
            changes.append(("job_started", "%s started" % job["name"], " · ".join(details),
                            {"jobID": job["id"], "state": job["state"]}))
    return changes


def gpu_events(previous, current, user):
    """Your processes that ended, and GPUs that became free."""
    def index(snapshot):
        return {(h["name"], g["index"]): g for h in snapshot["hosts"] for g in h["gpus"]}

    before, after, changes = index(previous), index(current), []
    for key, gpu in after.items():
        old = before.get(key)
        if old is None or gpu["error"]:
            continue
        had_mine = any(u["name"] == user for u in old["users"])
        has_mine = any(u["name"] == user for u in gpu["users"])
        if had_mine and not has_mine:
            changes.append(("gpu_process_ended", "Your work on %s GPU %d ended" % key, gpu["model"],
                            {"host": key[0], "gpu": key[1]}))
        if old["users"] and not gpu["users"]:
            changes.append(("gpu_free", "%s GPU %d is free" % key,
                            "%s · %s MB" % (gpu["model"], gpu["memoryTotal"] or "?"),
                            {"host": key[0], "gpu": key[1]}))
    return changes


DEFAULT_PREFS = {"job_finished": True, "job_started": False, "gpu_process_ended": True,
                 "gpu_free": False, "torch_login": True}


def der_to_raw_signature(der):
    """ECDSA DER (from openssl) to the 64-byte r||s that ES256 JWTs use."""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("not a DER signature")
    offset = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    values = []
    for _ in range(2):
        if der[offset] != 0x02:
            raise ValueError("bad DER integer")
        length = der[offset + 1]
        value = der[offset + 2:offset + 2 + length].lstrip(b"\x00")
        values.append(value.rjust(32, b"\x00"))
        offset += 2 + length
    return values[0] + values[1]


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def es256_jwt(key_path, key_id, team_id, issued_at=None):
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id}, separators=(",", ":")).encode())
    claims = b64url(json.dumps({"iss": team_id, "iat": int(issued_at or time.time())}, separators=(",", ":")).encode())
    signing_input = ("%s.%s" % (header, claims)).encode()
    completed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path], input=signing_input,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.decode(errors="replace").strip() or "openssl failed")
    return "%s.%s" % (signing_input.decode(), b64url(der_to_raw_signature(completed.stdout)))


class Push:
    """Apple push through `curl --http2`, signed with your APNs key via `openssl`."""

    def __init__(self, config, devices_path, agent_name):
        self.apns = config["apns"]
        self.devices_path = devices_path
        self.agent_name = agent_name
        self.lock = threading.Lock()
        self.jwt, self.jwt_time = None, 0

    @property
    def configured(self):
        return all(self.apns.get(k) for k in ("key_path", "key_id", "team_id", "topic")) and \
            os.path.exists(os.path.expanduser(self.apns["key_path"]))

    def devices(self):
        return load_json(self.devices_path, [])

    def register(self, token, environment, name, prefs):
        if not re.fullmatch(r"[0-9a-fA-F]{32,200}", token or ""):
            raise ValueError("bad device token")
        with self.lock:
            devices = [d for d in self.devices() if d["token"] != token]
            devices.append({"token": token, "environment": "production" if environment == "production" else "sandbox",
                            "name": name or "", "prefs": merged(DEFAULT_PREFS, prefs or {}), "added": now_iso()})
            save_json(self.devices_path, devices)

    def unregister(self, token):
        with self.lock:
            save_json(self.devices_path, [d for d in self.devices() if d["token"] != token])

    def token(self):
        # Apple accepts a provider token for up to an hour; refresh well before that.
        if self.jwt is None or time.time() - self.jwt_time > 40 * 60:
            self.jwt = es256_jwt(os.path.expanduser(self.apns["key_path"]), self.apns["key_id"], self.apns["team_id"])
            self.jwt_time = time.time()
        return self.jwt

    def send_event(self, event):
        if not self.configured:
            return
        payload = {
            "aps": {"alert": {"title": event["title"], "body": event["body"]}, "sound": "default",
                    "thread-id": event["kind"]},
            "agent": self.agent_name, "seq": event["seq"], "kind": event["kind"],
        }
        for device in self.devices():
            if device.get("prefs", DEFAULT_PREFS).get(event["kind"], False):
                self.send(device, payload)

    def send(self, device, payload):
        host = "api.push.apple.com" if device["environment"] == "production" else "api.sandbox.push.apple.com"
        # Headers go through a private file so the token never shows up in `ps`.
        with tempfile.NamedTemporaryFile("w", delete=False) as headers:
            os.chmod(headers.name, 0o600)
            headers.write("authorization: bearer %s\napns-topic: %s\napns-push-type: alert\n"
                          % (self.token(), self.apns["topic"]))
        try:
            status, out, err = run(["curl", "--http2", "-sS", "-H", "@" + headers.name, "-w", "\n%{http_code}",
                                    "--data-binary", "@-", "https://%s/3/device/%s" % (host, device["token"])],
                                   stdin=json.dumps(payload), timeout=20)
        finally:
            os.unlink(headers.name)
        code = out.rsplit("\n", 1)[-1]
        if code == "200":
            return True
        log("push to %s failed: %s %s %s" % (device.get("name") or device["token"][:8], code, out.strip(), err.strip()))
        if code == "410" or "BadDeviceToken" in out or "Unregistered" in out:
            self.unregister(device["token"])
        return False


# --------------------------------------------------------------------------
# Polling


class Monitor:
    def __init__(self, config):
        self.config = config
        self.torch = Torch(config) if config["torch"]["enabled"] else None
        self.gpus = LabGPUs(config) if config["gpus"]["enabled"] else None
        self.events = Events(os.path.join(STATE_DIR, "events.json"))
        self.push = Push(config, os.path.join(STATE_DIR, "devices.json"), config["name"])
        self.events.listeners.append(self.push.send_event)
        self.lock = threading.Lock()
        cache = load_json(os.path.join(STATE_DIR, "cache.json"), {})
        self.jobs = cache.get("jobs")
        self.lab = cache.get("lab")
        self.torch_status = {"state": "unknown", "message": None}
        self.gpu_error = None

    def save_cache(self):
        save_json(os.path.join(STATE_DIR, "cache.json"), {"jobs": self.jobs, "lab": self.lab})

    def refresh_torch(self):
        if not self.torch:
            return
        with self.torch.lock:
            previous_state = self.torch_status["state"]
            try:
                snapshot = self.torch.snapshot()
            except LoginRequired as error:
                self.torch_status = {"state": "login_required", "message": str(error) or None}
                if previous_state != "login_required":
                    self.events.add("torch_login", "Torch login needed",
                                    "%s lost its Torch connection. Log in again from the app." % self.config["name"])
                return
            except Exception as error:
                self.torch_status = {"state": "error", "message": str(error)}
                return
            self.torch_status = {"state": "ok", "message": None}
            if self.jobs:
                for kind, title, body, extra in job_events(self.jobs["jobs"], snapshot["jobs"]):
                    self.events.add(kind, title, body, **extra)
            self.jobs = snapshot
            self.save_cache()

    def refresh_gpus(self):
        if not self.gpus:
            return
        try:
            snapshot = self.gpus.snapshot()
        except Exception as error:
            self.gpu_error = str(error)
            return
        self.gpu_error = None
        if self.lab:
            for kind, title, body, extra in gpu_events(self.lab, snapshot, self.gpus.user):
                self.events.add(kind, title, body, **extra)
        self.lab = snapshot
        self.save_cache()

    def loop(self, refresh, seconds):
        while True:
            try:
                refresh()
            except Exception as error:
                log("refresh failed: %r" % error)
            time.sleep(max(int(seconds), 10))

    def start(self):
        if self.torch:
            threading.Thread(target=self.loop, args=(self.refresh_torch, self.config["torch"]["poll_seconds"]), daemon=True).start()
        if self.gpus:
            threading.Thread(target=self.loop, args=(self.refresh_gpus, self.config["gpus"]["poll_seconds"]), daemon=True).start()


# --------------------------------------------------------------------------
# Terminal over WebSocket

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def ws_accept(key):
    return base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()


def ws_frame(opcode, payload):
    header = bytes([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header += bytes([length])
    elif length < 65536:
        header += bytes([126]) + struct.pack("!H", length)
    else:
        header += bytes([127]) + struct.pack("!Q", length)
    return header + payload


class FrameReader:
    """Parses client WebSocket frames (always masked) from a byte stream."""

    def __init__(self):
        self.buffer = b""
        self.fragments = b""

    def feed(self, data):
        self.buffer += data
        frames = []
        while True:
            if len(self.buffer) < 2:
                return frames
            first, second = self.buffer[0], self.buffer[1]
            length, offset = second & 0x7F, 2
            if length == 126:
                if len(self.buffer) < 4:
                    return frames
                length, offset = struct.unpack("!H", self.buffer[2:4])[0], 4
            elif length == 127:
                if len(self.buffer) < 10:
                    return frames
                length, offset = struct.unpack("!Q", self.buffer[2:10])[0], 10
            masked = second & 0x80
            mask = self.buffer[offset:offset + 4] if masked else b""
            offset += 4 if masked else 0
            if len(self.buffer) < offset + length:
                return frames
            payload = self.buffer[offset:offset + length]
            if masked:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            self.buffer = self.buffer[offset + length:]
            opcode, final = first & 0x0F, first & 0x80
            if opcode == 0:
                self.fragments += payload
                if final:
                    frames.append((self.fragment_opcode, self.fragments))
                    self.fragments = b""
            elif not final and opcode in (1, 2):
                self.fragment_opcode, self.fragments = opcode, payload
            else:
                frames.append((opcode, payload))


def set_window_size(fd, cols, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", max(rows, 1), max(cols, 1), 0, 0))


def terminal_session(sock, argv, cols, rows):
    """Bridges a WebSocket to a program on a pseudo-terminal until either side closes."""
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        try:
            os.execvp(argv[0], argv)
        finally:
            os._exit(127)
    set_window_size(fd, cols, rows)
    reader = FrameReader()
    try:
        while True:
            readable, _, _ = select.select([sock, fd], [], [], 30)
            if not readable:
                sock.sendall(ws_frame(0x9, b""))  # ping keeps NAT and the phone's socket alive
                continue
            if fd in readable:
                try:
                    data = os.read(fd, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    data = b""
                if not data:
                    break
                sock.sendall(ws_frame(0x2, data))
            if sock in readable:
                data = sock.recv(65536)
                if not data:
                    break
                for opcode, payload in reader.feed(data):
                    if opcode == 0x2:
                        os.write(fd, payload)
                    elif opcode == 0x1:
                        message = json.loads(payload.decode() or "{}")
                        if message.get("type") == "resize":
                            set_window_size(fd, int(message["cols"]), int(message["rows"]))
                        elif message.get("type") == "input":
                            os.write(fd, message.get("data", "").encode())
                    elif opcode == 0x9:
                        sock.sendall(ws_frame(0xA, payload))
                    elif opcode == 0x8:
                        raise ConnectionResetError
    except (ConnectionError, OSError, ValueError):
        pass
    finally:
        try:
            os.kill(pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        os.close(fd)
        try:
            sock.sendall(ws_frame(0x8, struct.pack("!H", 1000)))
        except OSError:
            pass


# --------------------------------------------------------------------------
# HTTP API


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "lil-torch/" + VERSION
    protocol_version = "HTTP/1.1"
    agent = None  # set by serve()

    def log_message(self, fmt, *args):
        pass

    def send_json(self, value, status=200):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def fail(self, status, message):
        self.send_json({"error": message}, status)

    def authorized(self):
        expected = "Bearer " + self.agent.config["token"]
        supplied = self.headers.get("Authorization", "")
        return bool(self.agent.config["token"]) and hmac.compare_digest(supplied.encode(), expected.encode())

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}") if length else {}

    def route(self, method):
        url = urllib.parse.urlsplit(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        if url.path == "/healthz":
            return self.send_json({"ok": True, "version": VERSION})
        if not self.authorized():
            return self.fail(401, "missing or wrong token")
        try:
            handler = getattr(self.agent, "api_" + method.lower(), None)
            handled = handler and handler(self, url.path, query)
            if not handled:
                self.fail(404, "no such endpoint")
        except ValueError as error:
            self.fail(400, str(error))
        except LoginRequired as error:
            self.fail(409, str(error) or "Torch login needed")
        except Exception as error:
            log("request %s %s failed: %r" % (method, url.path, error))
            self.fail(502, str(error))

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_DELETE(self):
        self.route("DELETE")


class Agent:
    def __init__(self, config):
        self.config = config
        self.monitor = Monitor(config)

    def info(self):
        monitor = self.monitor
        return {
            "name": self.config["name"], "version": VERSION, "host": socket.gethostname(),
            "user": os.environ.get("USER", ""),
            "features": {"torch": monitor.torch is not None, "gpus": monitor.gpus is not None,
                         "terminal": self.config["terminal"]["enabled"], "push": monitor.push.configured},
            "torch": dict(monitor.torch_status, sshHost=self.config["torch"]["ssh_host"]) if monitor.torch else None,
            "gpuUser": self.config["gpus"]["user"] if monitor.gpus else None,
            "latestEvent": monitor.events.seq,
        }

    def api_get(self, request, path, query):
        monitor = self.monitor
        if path == "/v1/info":
            request.send_json(self.info())
        elif path == "/v1/torch/jobs":
            self.require(monitor.torch, "Torch")
            if query.get("refresh") == "1" or monitor.jobs is None:
                monitor.refresh_torch()
            if monitor.torch_status["state"] == "login_required":
                raise LoginRequired(monitor.torch_status["message"] or "")
            if monitor.jobs is None:
                raise RuntimeError(monitor.torch_status["message"] or "no Torch data yet")
            request.send_json(dict(monitor.jobs, status=monitor.torch_status))
        elif path == "/v1/torch/log":
            self.require(monitor.torch, "Torch")
            request.send_json(monitor.torch.tail(query.get("path", ""), int(query.get("lines", 200))))
        elif path == "/v1/gpus":
            self.require(monitor.gpus, "GPU monitoring")
            if query.get("refresh") == "1" or monitor.lab is None:
                monitor.refresh_gpus()
            if monitor.lab is None:
                raise RuntimeError(monitor.gpu_error or "no GPU data yet")
            request.send_json(dict(monitor.lab, error=monitor.gpu_error))
        elif path == "/v1/events":
            events, latest = monitor.events.since(int(query.get("since", 0)))
            request.send_json({"events": events, "latest": latest})
        elif path == "/v1/terminal":
            self.terminal(request, query)
        else:
            return False
        return True

    def api_post(self, request, path, query):
        match = re.fullmatch(r"/v1/torch/jobs/([0-9_]+)/cancel", path)
        if match:
            self.require(self.monitor.torch, "Torch")
            self.monitor.torch.cancel(match.group(1))
            threading.Thread(target=self.monitor.refresh_torch, daemon=True).start()
            request.send_json({"ok": True})
        elif path == "/v1/devices":
            body = request.body()
            self.monitor.push.register(body.get("token"), body.get("environment"), body.get("name"), body.get("prefs"))
            request.send_json({"ok": True, "push": self.monitor.push.configured})
        elif path == "/v1/test-push":
            event = self.monitor.events.add("test", "Lil Torch", "Test notification from %s" % self.config["name"])
            request.send_json({"ok": True, "seq": event["seq"], "push": self.monitor.push.configured})
        else:
            return False
        return True

    def api_delete(self, request, path, query):
        match = re.fullmatch(r"/v1/devices/([0-9a-fA-F]+)", path)
        if not match:
            return False
        self.monitor.push.unregister(match.group(1))
        request.send_json({"ok": True})
        return True

    @staticmethod
    def require(feature, name):
        if feature is None:
            raise ValueError("%s is not enabled on this agent" % name)

    def terminal(self, request, query):
        if not self.config["terminal"]["enabled"]:
            raise ValueError("the terminal is disabled on this agent")
        if request.headers.get("Upgrade", "").lower() != "websocket":
            raise ValueError("expected a WebSocket upgrade")
        target = query.get("target", "torch")
        if target == "torch":
            self.require(self.monitor.torch, "Torch")
            # With no live master this prompts for NYU login, and the login becomes the
            # shared master (ControlMaster auto + ControlPersist) that polling reuses.
            argv = ["ssh", "-tt", self.config["torch"]["ssh_host"]]
        elif target == "local":
            shell = os.environ.get("SHELL") or "/bin/bash"
            argv = [shell, "-l"]
        else:
            raise ValueError("unknown terminal target")
        request.send_response(101, "Switching Protocols")
        request.send_header("Upgrade", "websocket")
        request.send_header("Connection", "Upgrade")
        request.send_header("Sec-WebSocket-Accept", ws_accept(request.headers["Sec-WebSocket-Key"]))
        request.end_headers()
        request.wfile.flush()
        request.close_connection = True
        terminal_session(request.connection, argv, int(query.get("cols", 80)), int(query.get("rows", 24)))
        if target == "torch":
            threading.Thread(target=self.monitor.refresh_torch, daemon=True).start()


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def tailscale_addresses():
    status, out, _ = run(["tailscale", "ip", "-4"], timeout=10)
    return [line.strip() for line in out.splitlines() if line.strip()] if status == 0 else []


def tailscale_name():
    status, out, _ = run(["tailscale", "status", "--json"], timeout=10)
    if status != 0:
        return None
    try:
        return json.loads(out)["Self"]["DNSName"].rstrip(".") or None
    except (ValueError, KeyError):
        return None


def serve(config):
    if not config["token"]:
        sys.exit("No token configured. Run `liltorch_agent.py setup` first.")
    addresses = config["bind"] or tailscale_addresses()
    if not addresses:
        log("Tailscale address not found; waiting for tailscaled")
        while not addresses:
            time.sleep(15)
            addresses = tailscale_addresses()
    agent = Agent(config)
    Handler.agent = agent
    agent.monitor.start()
    servers = []
    for address in addresses:
        server = Server((address, int(config["port"])), Handler)
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        log("listening on http://%s:%s" % (address, config["port"]))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        while True:
            time.sleep(3600)
    except (KeyboardInterrupt, SystemExit):
        for server in servers:
            server.shutdown()


# --------------------------------------------------------------------------
# Setup


def ask(prompt, default=""):
    try:
        with open("/dev/tty", "r+") as tty:
            tty.write(prompt)
            tty.flush()
            answer = tty.readline().strip()
            return answer or default
    except OSError:
        return default


def ssh_config_has_host(name):
    status, out, _ = run(["ssh", "-G", name], timeout=10)
    if status != 0:
        return False
    hostname = re.search(r"^hostname (.+)$", out, re.M)
    return bool(hostname) and hostname.group(1).strip() != name


def add_torch_ssh_host(netid):
    """Adds `Host torch` with a shared, persistent connection, unless one exists."""
    path = os.path.join(HOME, ".ssh", "config")
    os.makedirs(os.path.join(HOME, ".ssh", "cm"), mode=0o700, exist_ok=True)
    block = (
        "\n# Added by Lil Torch: one NYU login shared by every connection to Torch.\n"
        "Host torch\n"
        "  HostName %s\n"
        "  User %s\n"
        "  ControlMaster auto\n"
        "  ControlPath ~/.ssh/cm/%%C\n"
        "  ControlPersist yes\n"
        "  ServerAliveInterval 30\n"
        "  ServerAliveCountMax 20\n"
        "  StrictHostKeyChecking accept-new\n"
        "  ConnectTimeout 15\n" % (TORCH_LOGIN_HOST, netid)
    )
    with open(path, "a") as handle:
        handle.write(block)
    os.chmod(path, 0o600)


def detect_gpu_source():
    try:
        with urllib.request.urlopen(LAB_GPUSTAT_URL, timeout=4) as response:
            response.read(64)
        return "url"
    except Exception:
        pass
    if shutil.which("nvidia-smi") and run(["nvidia-smi", "-L"], timeout=10)[0] == 0:
        return "nvidia-smi"
    return None


def setup(args):
    config = load_config()
    if args.name:
        config["name"] = args.name
    if args.port:
        config["port"] = args.port
    if not config["token"]:
        config["token"] = secrets.token_urlsafe(32)

    # Torch
    if args.no_torch:
        config["torch"]["enabled"] = False
    elif ssh_config_has_host(config["torch"]["ssh_host"]):
        config["torch"]["enabled"] = True
        print("Torch: using your existing `Host %s` SSH config." % config["torch"]["ssh_host"])
    else:
        netid = args.netid or ask("Your NYU NetID for Torch (leave empty to skip Torch): ")
        if netid:
            if not re.fullmatch(r"[A-Za-z0-9._-]+", netid):
                sys.exit("That doesn't look like a NetID.")
            add_torch_ssh_host(netid)
            config["torch"]["enabled"] = True
            print("Torch: added `Host torch` for %s to ~/.ssh/config." % netid)
        else:
            config["torch"]["enabled"] = False

    # GPUs
    choice = args.gpus or "auto"
    if choice == "none":
        config["gpus"]["enabled"] = False
    else:
        if choice == "auto":
            source = detect_gpu_source()
        elif choice in ("nvidia-smi", "url"):
            source = choice
        else:
            source, config["gpus"]["url"] = "url", choice
        config["gpus"]["enabled"] = source is not None
        if source:
            config["gpus"]["source"] = source
    if args.gpu_user:
        config["gpus"]["user"] = args.gpu_user

    # Push
    if args.apns_key:
        key_dir = os.path.join(CONFIG_DIR, "apns")
        os.makedirs(key_dir, mode=0o700, exist_ok=True)
        destination = os.path.join(key_dir, os.path.basename(args.apns_key))
        shutil.copyfile(os.path.expanduser(args.apns_key), destination)
        os.chmod(destination, 0o600)
        config["apns"]["key_path"] = destination
    for field in ("apns_key_id", "apns_team_id", "apns_topic"):
        value = getattr(args, field)
        if value:
            config["apns"][field[len("apns_"):]] = value

    # SSH relay for laptops (Orin's original relay lives in ~/.config/torch-ssh-relay; leave it be)
    existing_relay = os.path.isdir(os.path.join(HOME, ".config", "torch-ssh-relay"))
    want_relay = config["torch"]["enabled"] and not args.no_ssh_relay and not existing_relay and os.path.exists(SSHD)
    if want_relay:
        install_relay(config)
    config["relay"]["enabled"] = bool(want_relay)

    save_json(CONFIG_PATH, config)
    print("Saved %s" % CONFIG_PATH)
    print("  Torch: %s" % ("on (ssh %s)" % config["torch"]["ssh_host"] if config["torch"]["enabled"] else "off"))
    print("  Lab GPUs: %s" % (("on (%s)" % config["gpus"]["source"]) if config["gpus"]["enabled"] else "off"))
    print("  Push: %s" % ("on" if Push(config, "", "").configured else "off (add an APNs key later with `setup --apns-key`)"))


SSHD = shutil.which("sshd") or "/usr/sbin/sshd"

RELAY_COMMAND = """#!/bin/sh
# Lil Torch SSH relay: every session on this port runs on Torch through this
# machine's shared NYU login (Host torch with ControlMaster).
host=%(host)s
cmd=${SSH_ORIGINAL_COMMAND-}
case "$cmd" in
  sftp|internal-sftp|internal-sftp\\ *|*/sftp-server|*/sftp-server\\ *) exec ssh -o BatchMode=yes -T -s "$host" sftp ;;
esac
if [ -n "${SSH_TTY-}" ]; then
  # Interactive: may prompt for NYU login, which then becomes the shared connection.
  if [ -n "$cmd" ]; then exec ssh -tt "$host" "$cmd"; fi
  exec ssh -tt "$host"
fi
if ! ssh -O check "$host" >/dev/null 2>&1; then
  echo "Torch login needed: sign in from Lil Torch, or connect once interactively (ssh -t)." >&2
  exit 255
fi
if [ -n "$cmd" ]; then exec ssh -o BatchMode=yes -T "$host" "$cmd"; fi
exec ssh -o BatchMode=yes -T "$host"
"""

SSHD_CONFIG = """ListenAddress 127.0.0.1
Port %(port)d
HostKey %(dir)s/host_ed25519
PidFile %(dir)s/sshd.pid
AuthorizedKeysFile %(dir)s/authorized_keys
AllowUsers %(user)s
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes yes
PermitRootLogin no
PermitUserEnvironment no
PermitUserRC no
DisableForwarding yes
PermitTTY yes
PrintMotd no
PrintLastLog no
Subsystem sftp internal-sftp
ForceCommand %(dir)s/relay-command
"""


def free_port(start):
    for port in range(start, start + 200):
        with socket.socket() as probe:
            try:
                probe.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    raise RuntimeError("no free port for the SSH relay")


def install_relay(config):
    """A loopback-only sshd whose every session is forwarded to Torch (as on Orin)."""
    os.makedirs(RELAY_DIR, mode=0o700, exist_ok=True)
    if not config["relay"]["port"]:
        # Lab machines are shared: spread users over ports by UID.
        config["relay"]["port"] = free_port(22422 + os.getuid() % 1000)
    key = os.path.join(RELAY_DIR, "host_ed25519")
    if not os.path.exists(key):
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "lil-torch-relay", "-f", key])
    keys = os.path.join(RELAY_DIR, "authorized_keys")
    if not os.path.exists(keys):
        open(keys, "a").close()
    os.chmod(keys, 0o600)
    command = os.path.join(RELAY_DIR, "relay-command")
    with open(command, "w") as handle:
        handle.write(RELAY_COMMAND % {"host": shlex.quote(config["torch"]["ssh_host"])})
    os.chmod(command, 0o700)
    with open(os.path.join(RELAY_DIR, "sshd_config"), "w") as handle:
        handle.write(SSHD_CONFIG % {"port": config["relay"]["port"], "dir": RELAY_DIR,
                                    "user": os.environ.get("USER") or os.getlogin()})
    status, _, err = run([SSHD, "-t", "-f", os.path.join(RELAY_DIR, "sshd_config")])
    if status != 0:
        raise RuntimeError("sshd rejected the relay config: " + err.strip())


AGENT_UNIT = """[Unit]
Description=Lil Torch agent
After=network-online.target

[Service]
ExecStart=%(python)s %(agent)s serve
Restart=always
RestartSec=10
# Keep the Torch login (an ssh ControlMaster started from the terminal) alive across restarts.
KillMode=process

[Install]
WantedBy=default.target
"""

RELAY_UNIT = """[Unit]
Description=Lil Torch SSH relay to Torch

[Service]
ExecStart=%(sshd)s -D -e -f %(dir)s/sshd_config
Restart=on-failure
RestartSec=10
KillMode=process

[Install]
WantedBy=default.target
"""


def systemd_user_available():
    return shutil.which("systemctl") is not None and run(["systemctl", "--user", "show-environment"], timeout=10)[0] == 0


def install_services(config):
    units = {"lil-torch-agent.service": AGENT_UNIT % {"python": sys.executable, "agent": AGENT_PATH}}
    if config["relay"]["enabled"]:
        units["lil-torch-relay.service"] = RELAY_UNIT % {"sshd": SSHD, "dir": RELAY_DIR}
    if systemd_user_available():
        os.makedirs(UNIT_DIR, exist_ok=True)
        for name, text in units.items():
            with open(os.path.join(UNIT_DIR, name), "w") as handle:
                handle.write(text)
        run(["systemctl", "--user", "daemon-reload"])
        for name in units:
            run(["systemctl", "--user", "enable", name])
            run(["systemctl", "--user", "restart", name])
        # Linger keeps user services running after you log out and starts them at boot.
        if run(["loginctl", "enable-linger", os.environ.get("USER", "")], timeout=15)[0] != 0:
            print("Note: couldn't enable lingering; the agent stops when you log out. "
                  "Ask an admin to run `sudo loginctl enable-linger %s`." % os.environ.get("USER", ""))
        print("Services: %s (systemd --user)" % ", ".join(sorted(units)))
        return
    # No user systemd: cron starts the agent at boot and restarts it if it dies.
    lines = ["@reboot %s %s serve >>%s/agent.log 2>&1" % (sys.executable, AGENT_PATH, STATE_DIR),
             "*/5 * * * * pgrep -u $(id -u) -f 'liltorch_agent.py serve' >/dev/null || %s %s serve >>%s/agent.log 2>&1"
             % (sys.executable, AGENT_PATH, STATE_DIR)]
    if config["relay"]["enabled"]:
        lines.append("*/5 * * * * pgrep -u $(id -u) -f '%s/sshd_config' >/dev/null || %s -f %s/sshd_config"
                     % (RELAY_DIR, SSHD, RELAY_DIR))
    current = run(["crontab", "-l"])[1]
    kept = [line for line in current.splitlines() if "liltorch_agent.py" not in line and RELAY_DIR not in line]
    run(["crontab", "-"], stdin="\n".join(kept + lines) + "\n")
    os.makedirs(STATE_DIR, exist_ok=True)
    subprocess.Popen([sys.executable, AGENT_PATH, "serve"], stdout=open(os.path.join(STATE_DIR, "agent.log"), "a"),
                     stderr=subprocess.STDOUT, start_new_session=True)
    print("Services: cron (systemd --user isn't available here)")


def uninstall():
    if systemd_user_available():
        for name in ("lil-torch-agent.service", "lil-torch-relay.service"):
            run(["systemctl", "--user", "disable", "--now", name])
            try:
                os.remove(os.path.join(UNIT_DIR, name))
            except FileNotFoundError:
                pass
        run(["systemctl", "--user", "daemon-reload"])
    current = run(["crontab", "-l"])[1]
    if "liltorch_agent.py" in current:
        kept = [line for line in current.splitlines() if "liltorch_agent.py" not in line and RELAY_DIR not in line]
        run(["crontab", "-"], stdin="\n".join(kept) + "\n")
    run(["pkill", "-u", str(os.getuid()), "-f", "liltorch_agent.py serve"])
    print("Stopped the Lil Torch agent. Config and history remain in %s and %s; "
          "the `Host torch` SSH block is left in place." % (CONFIG_DIR, STATE_DIR))


def laptop_instructions(config):
    if not config["relay"]["enabled"]:
        return
    host = tailscale_name() or socket.gethostname()
    user = os.environ.get("USER", "")
    with open(os.path.join(RELAY_DIR, "host_ed25519.pub")) as handle:
        host_key = " ".join(handle.read().split()[:2])
    alias = "torch-%s" % config["name"]
    print("SSH into Torch from a laptop without the VPN, through this machine:\n")
    print("  # 1. On the laptop, allow its key on the relay:")
    print("  cat ~/.ssh/id_ed25519.pub | ssh %s@%s 'cat >> %s/authorized_keys'" % (user, host, RELAY_DIR))
    print("  # 2. Pin the relay's host key:")
    print("  echo 'lil-torch-relay-%s %s' >> ~/.ssh/known_hosts" % (config["name"], host_key))
    print("  # 3. Add to ~/.ssh/config, then `ssh %s`:" % alias)
    print("  Host %s\n    HostName 127.0.0.1\n    Port %d\n    User %s\n    ProxyCommand ssh -W %%h:%%p %s@%s\n"
          "    HostKeyAlias lil-torch-relay-%s\n" % (alias, config["relay"]["port"], user, user, host, config["name"]))


def pairing_link(config):
    host = tailscale_name() or (config["bind"] or tailscale_addresses() or ["127.0.0.1"])[0]
    query = urllib.parse.urlencode({"url": "http://%s:%s" % (host, config["port"]), "token": config["token"],
                                    "name": config["name"]})
    return "liltorch://add?" + query


def pair(config):
    link = pairing_link(config)
    print("\nOpen this on your iPhone (AirDrop or paste it into Lil Torch → Clusters → Add):\n")
    print("  " + link + "\n")
    if shutil.which("qrencode"):
        subprocess.run(["qrencode", "-t", "ansiutf8", link])


def status(config):
    print(json.dumps(Agent(config).info(), indent=2))


def main():
    parser = argparse.ArgumentParser(description="Lil Torch agent")
    commands = parser.add_subparsers(dest="command")
    setup_parser = commands.add_parser("setup")
    setup_parser.add_argument("--netid")
    setup_parser.add_argument("--no-torch", action="store_true")
    setup_parser.add_argument("--gpus", help="auto, none, nvidia-smi, or a gpustat-web URL")
    setup_parser.add_argument("--gpu-user", help="your account name on the lab GPU machines")
    setup_parser.add_argument("--name")
    setup_parser.add_argument("--port", type=int)
    setup_parser.add_argument("--apns-key", help="path to your AuthKey_XXXX.p8")
    setup_parser.add_argument("--apns-key-id")
    setup_parser.add_argument("--apns-team-id")
    setup_parser.add_argument("--apns-topic", help="the app's bundle ID")
    setup_parser.add_argument("--no-ssh-relay", action="store_true", help="don't set up the laptop SSH relay")
    setup_parser.add_argument("--no-services", action="store_true", help="only write config; don't start anything")
    commands.add_parser("serve")
    commands.add_parser("pair")
    commands.add_parser("status")
    commands.add_parser("uninstall")
    args = parser.parse_args()

    if args.command == "setup":
        setup(args)
        config = load_config()
        if not args.no_services:
            install_services(config)
        pair(config)
        laptop_instructions(config)
    elif args.command == "uninstall":
        uninstall()
    elif args.command == "serve":
        serve(load_config())
    elif args.command == "pair":
        pair(load_config())
    elif args.command == "status":
        status(load_config())
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
