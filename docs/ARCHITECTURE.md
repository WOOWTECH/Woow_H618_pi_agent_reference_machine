# Architecture

This document explains how the H618 reference machine is built. It is aimed at someone who has to modify the deployment, not just run it.

## Layers, bottom-up

```
┌──────────────────────────────────────────────────────────────────┐
│  6. Public / remote access                                       │
│     - Cloudflare Tunnel  (outbound to CF, no inbound ports)      │
│     - Tailnet HTTPS      (via `tailscale serve --https=443`)     │
├──────────────────────────────────────────────────────────────────┤
│  5. LAN-facing services (system + user)                          │
│     :8088  tailscale-web         (system unit)                   │
│     :30142 pi-agent-nginx  →  pi-web (rootless podman)           │
│     :8888  cf-tunnel-webgui      (rootless podman)               │
├──────────────────────────────────────────────────────────────────┤
│  4. Container runtime                                            │
│     rootless podman 4.3.1, uid 1000 (pi), subuid 100000+         │
│     network:  pi-agent (bridge, 10.89.0.0/24)                    │
│     volumes:  pi-agent-data, cf-tunnel-webgui-data               │
├──────────────────────────────────────────────────────────────────┤
│  3. Service supervision                                          │
│     systemd --user (linger enabled) for the 3 podman containers  │
│     systemd system for tailscaled + tailscale-web                │
├──────────────────────────────────────────────────────────────────┤
│  2. Identity + auth                                              │
│     Armbian /etc/shadow (root's hash) → PAM common-password      │
│         └► pam_exec ─► /usr/local/sbin/pi-web-passwd-sync.sh     │
│                          └► ~pi/.config/pi-agent/htpasswd        │
├──────────────────────────────────────────────────────────────────┤
│  1. OS                                                           │
│     Armbian OS 26.08.0 bookworm (Debian 12), kernel 6.18-ophub   │
│     Vontar H618 (Allwinner H618, 4×A53, 4GB RAM, eMMC 32GB)      │
└──────────────────────────────────────────────────────────────────┘
```

## Why each piece is where it is

### Rootless podman (uid 1000)

The alternative is running podman as root. We do not, for two reasons:

1. A container escape from a rootless container lands on an unprivileged user (`pi`), not `root`. On a device you may hand to a customer, that difference is load-bearing.
2. Rootless services under `systemd --user` are supervised by the user session — no accidental interaction with the system-wide unit graph, no accidental starts of a service before the network is ready because someone edited `default.target`.

The cost is `subuid` + `subgid` + `linger`, which phase 1 sets up.

### Hand-crafted `podman run` systemd user units

Quadlet is the correct answer on Podman ≥ 4.4. Debian bookworm ships 4.3.1. We could:

- (a) Backport podman from bookworm-backports or a third-party PPA
- (b) Hand-write `podman run`-wrapping `.service` files

We chose (b). Rationale: bookworm-backports moves; a repo pinned to it in 2026 will drift. Third-party PPAs are worse. Hand-written units are boring, but they are the same shape you would get if Quadlet generated them — one `podman run --rm --name X ...` per unit, with an `ExecStartPre=-podman rm -f` for idempotency after crashes. When bookworm-backports ships Podman 4.4+, the `podman/*.service` files get replaced by `~/.config/containers/systemd/*.container` files and nothing else changes.

### tailscale-web on `0.0.0.0:8088`

The tailscale CLI ships `tailscale web` as an on-demand command. There is no packaged `tailscale-web.service` because tailscale's opinion is that different downstreams (Synology, QNAP, standalone) all wrap it differently. This repo is one such downstream.

Bind decision:
- `0.0.0.0:8088` — reachable from LAN, from `127.0.0.1`, and from `100.x.x.x` (tailnet) simultaneously. Also reachable from cloudflared, which lives on the LAN interface. **All three access paths converge on one port.**
- Not `100.x:5252` (tailscale default) — this hides the UI from LAN AND breaks cloudflared. Wrong for our topology.
- Not `127.0.0.1:8088` — then LAN operators can't use it without SSH port-forwarding, which we specifically want to avoid.

The security implication: anyone reachable to `:8088` can control tailscale on this host. Mitigation is at a higher layer (LAN is trusted, CF Access on public URL). We do **not** paper over it with a fake read-only mode.

### PAM `pam_exec` for password sync

Alternatives considered:

| Approach | Why not |
|---|---|
| **nginx-pam module** — nginx authenticates against `/etc/shadow` via PAM | Rootless nginx container cannot read `/etc/shadow` (owned by root, mode 640). Would need /etc/shadow bind-mounted with uid remapping. Fragile. |
| **inotify watcher on `/etc/shadow`** | Fires on any shadow write (including `chage -d` for password expiry, useradd, `pwck -q`). Not what we want. Also does not run under a systemd context that has easy access to the pi user's home. |
| **Wrapper around `passwd`** | Only fires when someone runs `passwd` specifically. Bypassed by `chpasswd`, provisioning scripts, Ansible, etc. |
| **`pam_exec` on `common-password`** ← chosen | Fires on every PAM-mediated password change, regardless of the tool. Runs synchronously as root, in a well-defined environment. Idempotent by design. |

The sync script reads `/etc/shadow` rather than PAM's `PAM_AUTHTOK` (the plaintext). This means:

- Even if PAM did not expose the plaintext (e.g., `chpasswd -e` which passes hashes only), sync still works — it always re-reads shadow.
- The plaintext is never handed to a script we wrote. Fewer places for it to leak.

The pam.d line uses `optional`, not `required`. If the sync script has a bug and exits non-zero, the user's `passwd` still succeeds — pi-web sync just doesn't happen. Failure mode: pi-web keeps the old password until the operator fixes the script or reruns `passwd root`. This is strictly better than "sync bug locks the operator out of both systems at once".

### The `podman run` unit contract

Each `podman/*.service` uses the pattern:

```ini
ExecStartPre=-/usr/bin/podman rm -f <name>
ExecStart=/usr/bin/podman run --rm --name <name> ... <image>
ExecStop=/usr/bin/podman stop -t 10 <name>
```

`--rm` + `ExecStartPre=-podman rm -f` is intentional. If the previous invocation exited badly (SIGKILL, OOM), the container name lingers; `--rm` alone does not clean it up because `--rm` fires on graceful exit only. The `ExecStartPre` with a leading `-` (ignore failure) guarantees a clean slate before every start.

Alternative would be `--replace` (podman 4.4+), which internally does the same thing. We use the explicit form because it works on 4.3.1.

### The nginx auth shim in front of pi-web

pi-web's `isApiRequestAllowed()` rejects any Host header that is not a loopback name or a raw IP, and any Origin that does not match. Traffic arriving under a hostname (like `pi-armbian-test.woowtech.io`) fails both halves — every auth-gated route (models, skills, plugins, sessions) answers 403 "Untrusted API request" while the UI still renders.

The nginx sidecar rewrites `Host: localhost` and `Origin: ""` before proxying. This is not a hack around pi-web's security; it is how pi-web is designed to be exposed. See `Woow_podman_pi_agent_package/config/nginx.conf` for the annotated original.

We add the Basic auth on top of this proxy. This keeps the surface simple: **one auth mechanism, one place to update the password.**

## Data flow: password change

```
$ sudo passwd root
                                     [PAM]
                                       │
                                       ▼
      /etc/pam.d/common-password ── stack executes ──► shadow write
                                       │                      │
                                       │              (line 3 above)
                                       ▼
        pam_exec ─► pi-web-passwd-sync.sh (root, sync)
                       │
                       ├─ getent shadow root → extract $6$hash
                       │
                       ├─ mkstemp in ~pi/.config/pi-agent/
                       │  write "root:$6$hash" mode 0600
                       │
                       └─ atomic rename → htpasswd
                                       │
                                       ▼
   (nginx reads htpasswd on next request — no restart needed)
```

Duration: <10ms after `passwd` returns. Failure of the sync script does not fail the `passwd` command.

## Data flow: pi-web request

```
Browser ──HTTP──► :30142 (pi-agent-nginx, published port)
                     │
                     │ 1. auth_basic check against /etc/nginx/htpasswd
                     │    (mounted from ~pi/.config/pi-agent/htpasswd:ro)
                     │
                     │ 2. rewrite Host: localhost, Origin: ""
                     │
                     │ 3. proxy_pass http://pi-web:30141
                     │    (name resolved via aardvark-dns on pi-agent network)
                     ▼
                  pi-web container (rootless, :30141)
                     │
                     ▼
               /data/pi-agent (podman volume)
```

Two hops, one network. nginx and pi-web are on the same bridge network (`pi-agent`, 10.89.0.0/24) so aardvark-dns resolves `pi-web` internally without host DNS involvement.

## What is deliberately not here

- **No reverse proxy in front of everything.** Each service publishes its own port on the host. Cloudflare Tunnel ingress rules do the routing when needed. This trades one layer of composition for one layer of "one thing running on one port".
- **No Home Assistant.** This box was HA + matter earlier; both were purged as out-of-scope. If you want them back, install them in their own rootless podman containers — but keep them off `:30142` and `:8088`.
- **No Docker.** rootless podman covers the container use case. Adding Docker doubles the surface without adding capability.
- **No Kubernetes.** For that, see the sibling repo `Woow_k3s_pi_agent_package`.
