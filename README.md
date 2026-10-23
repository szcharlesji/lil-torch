# Lil Torch

Watch your NYU Torch jobs and the lab's GPUs from your iPhone, with no VPN.

There are two parts:

- **`install.sh`**: a one-line installer for the **Lil Torch agent**, a small per-user service. Run it on any lab machine you can log into. Lab machines are on NYU's network, so the agent reaches Torch directly.
- **The iOS app**: pair it with one or more agents over Tailscale.

```text
iPhone ──Tailscale──▶ agent on a lab machine (orion, Orin, …)
                       ├─ Torch:    ssh torch  (one shared NYU login: ControlMaster)
                       ├─ Lab GPUs: discovery's gpustat-web + your processes via SSH
                       ├─ events:   job finished/started, your GPU work ended, GPU freed
                       └─ SSH relay so laptops reach Torch without the VPN
```

## Install the agent

On a lab machine:

```sh
curl -fsSL https://raw.githubusercontent.com/szcharlesji/lil-torch/main/install.sh | sh
```

Or, from a checkout of this repo:

```sh
ssh orion 'sh -s' < install.sh
```

What it does:

- **Torch:** asks for your NetID and adds `Host torch` to `~/.ssh/config` with a shared, persistent connection (`ControlMaster auto`, `ControlPersist yes`). If you already have `Host torch`, it uses yours.
- **Lab GPUs:** turns on GPU monitoring when the machine can reach the lab's gpustat-web, or has local `nvidia-smi`.
- **Service:** installs `lil-torch-agent` as a systemd **user** service and enables linger, so it keeps running after you log out and starts at boot. It needs no root. Without user systemd, it falls back to cron.
- **Laptop relay:** sets up a loopback-only SSH relay, like the one on Orin, so laptops can `ssh` into Torch through this machine. It prints the laptop config at the end.
- **Pairing link:** prints a `liltorch://add?…` link. Open it on your phone, or paste it into **Clusters → Add a Cluster**.

The agent only listens on the machine's Tailscale address, and every request needs the token from the pairing link.

| Command | Effect |
|---|---|
| `sh install.sh` (again) | Upgrade in place; the token and pairing are kept |
| `sh install.sh --netid abc123` | Skip the NetID prompt (needed when there's no terminal, e.g. `ssh … 'sh -s'`) |
| `sh install.sh --gpus none` | Torch only (e.g. on Orin, which can't see gpustat-web) |
| `sh install.sh --uninstall` | Stop and remove the services |
| `~/.local/share/lil-torch/liltorch_agent.py pair` | Print the pairing link again |
| `systemctl --user status lil-torch-agent` | Check the service |

**Torch login.** When the shared NYU login drops, the app shows **Log in**. That opens a terminal on the agent running `ssh torch`; you enter your password and approve Duo there. That login becomes the shared connection again. The password goes from the terminal straight to `ssh`; nothing stores it.

## Notifications

The agent records events and the app shows them. Delivery has two modes:

- **Without an APNs key:** the app checks for events when it's open, or when iOS gives it background time. That can lag, and stops if you force-quit the app.
- **With an APNs key:** the agent pushes through Apple directly, and alerts arrive instantly even if the app is closed. To set it up, create a key in the developer portal (Keys → +, enable APNs). That needs the Admin or Account Holder role on the team. Then:

  ```sh
  sh install.sh --apns-key ~/AuthKey_ABC123.p8 --apns-key-id ABC123 --apns-team-id TEAMID
  ```

  The agent signs with `openssl` and sends with `curl --http2`. The key stays in `~/.config/lil-torch/apns/` with mode 600. Keep it on your own agents only.

## The app

- **Jobs:** your Torch Slurm jobs (running, queued, recent) and your processes on lab GPUs. Torch jobs have logs (follow mode) and cancel.
- **GPUs:** what's free and what's yours across the lab, plus per-GPU compute, memory, temperature, and who's using it.
- **Clusters:** paired agents, the Torch terminal and login, a shell on the agent machine, notification settings, and a test push.

To build: open `LilTorch.xcodeproj`, set your team, and run. On the first build, Xcode asks you to trust SwiftTerm's build plugin; it only writes SwiftTerm's version into a source file. Then:

- **APNs:** the app needs the Push Notifications capability. Automatic signing adds it once your team's agreement is accepted.
- **Installer link:** the app's Add a Cluster screen shows the curl one-liner from `AddClusterSheet.installCommand`; change it if you fork the repo.

## Layout

| Path | What |
|---|---|
| `agent/liltorch_agent.py` | The agent: standard library only, Python 3.8+ |
| `agent/test_agent.py` | `cd agent && python3 -m unittest` |
| `agent/install.sh.in`, `agent/build_installer.py` | `install.sh` is generated from these: `python3 agent/build_installer.py` |
| `install.sh` | The installer, with the agent embedded |
| `TorchKit/` | Swift client for the agent API (`swift test`) |
| `LilTorch/` | SwiftUI app (iOS 18+) |
| `tools/ssh-probe/` | The earlier direct-SSH transport (iPhone → Orin relay), kept as a Mac test tool |
