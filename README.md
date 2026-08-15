# Woow H618 pi-agent reference machine

[![Podman](https://img.shields.io/badge/Podman-4.3.1%20rootless-892CA0)](https://podman.io)
[![Debian](https://img.shields.io/badge/Debian-bookworm%20%2F%20Armbian-red)](https://www.armbian.com)
[![Tailscale](https://img.shields.io/badge/Tailscale-1.100%2B-black?logo=tailscale)](https://tailscale.com)
[![Cloudflare Tunnel](https://img.shields.io/badge/Cloudflare-Tunnel-F38020?logo=cloudflare)](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**English** · [繁體中文](README_zh-TW.md)

A **turnkey deploy repo** for the Woow H618 (Vontar / Allwinner H618, arm64) reference machine that runs:

- **pi-web** — the pi coding agent web UI, behind an nginx auth shim, on rootless podman
- **cf-tunnel-webgui** — a browser interface to manage the machine's Cloudflare Tunnel
- **tailscale** — VPN + web management UI, LAN + tailnet reachable
- **PAM-backed password sync** — pi-web's login is bound to Armbian's `sudo passwd root`; the two cannot diverge

If you have a fresh H618 with Armbian OS 26.08 bookworm on it, you can go from `git clone` to a working box in ~15 minutes. Everything is idempotent — re-running `install.sh` after a failure is safe.

---

## What you get

| Service | URL | Login |
|---|---|---|
| Tailscale web UI | `http://<box>:8088` | click "Log in" → OAuth at login.tailscale.com |
| pi coding agent | `http://<box>:30142` | `root` / `1234` (same as Armbian sudo) |
| Cloudflare Tunnel GUI | `http://<box>:8888` | first-run wizard; paste your CF tunnel token |
| SSH | `ssh root@<box>` or `ssh pi@<box>` | `root/1234`; `pi` is passwordless sudo |

**Password model (the one non-obvious piece):**

- pi-web's HTTP Basic auth username is fixed to `root`. Its password hash comes from `/etc/shadow`.
- Change the pi-web password by running **`sudo passwd root`**. A PAM hook copies the new hash to pi-web's htpasswd atomically — no restart, no CLI on pi-web.
- pi-agent's own `scripts/set-password.sh` is neutralised on this box. **There is no independent path** to change the pi-web password.

---

## Prerequisites

**Target hardware:** any arm64 SBC that runs Armbian bookworm. Verified on Vontar H618 (Allwinner H618, 4×A53, 4GB RAM, eMMC).

**Target OS:** Armbian OS 26.08.0 bookworm (Debian 12). Bookworm ships **Podman 4.3.1** — this repo works with that. It also works on Debian bookworm proper and Ubuntu 24.04+, but 26.08 Armbian is what has been end-to-end tested.

**Assumed starting state:** vanilla Armbian first boot completed. Root has been logged into via SSH at least once (so `/etc/shadow` has a real hash for root, and `/root` exists).

**What `install.sh` will install for you:**

- `podman`, `uidmap`, `slirp4netns`, `fuse-overlayfs`
- `tailscale` (from `pkgs.tailscale.com/stable/debian/bookworm`)
- `curl`, `jq`, `ca-certificates`, `gnupg`, `git`, `openssl`, `libpam-modules`

**What you need before running install.sh:**

- Network reachable to `pkgs.tailscale.com`, `github.com`, `docker.io`, `ghcr.io`
- ~5 GB free disk (podman images: ~1 GB pi-agent + ~250 MB cf-webui + ~50 MB nginx + build cache)
- A Cloudflare Tunnel token (**only if you want the CF public URL**; the LAN + tailnet paths work without one)
- A tailscale account (free tier is fine)

---

## Install

```bash
# On the H618, as any sudo-capable user:
git clone https://github.com/WOOWTECH/Woow_H618_pi_agent_reference_machine.git
cd Woow_H618_pi_agent_reference_machine
sudo ./install.sh
```

That's it. The script has three phases and orchestrates them itself:

| Phase | Runs as | Time | What it does |
|---|---|---|---|
| 1 | root | ~2 min | apt install, add pi user, subuid/subgid, linger, sudoers, `tailscaled` |
| 2 | pi | ~10 min | clone sibling repos, build both podman images, install user units, enable services |
| 3 | root | ~30 s | tailscale-web unit, PAM sync hook, neutralise pi-agent's own set-password.sh, seed htpasswd, set root=`1234` if unset |

If phase 2 fails on an image build, you can re-run just that phase:

```bash
sudo ./install.sh --phase 2
```

If you want to skip tailscale entirely (e.g., you deploy behind a VPN already):

```bash
sudo ./install.sh --skip-tailscale
```

---

## Post-install: three things you do in a browser

### 1. Tailscale login

Open **`http://<box-ip>:8088`** in a browser (any laptop on the same LAN). The tailscale web UI shows "Not logged in" with a **Log in** button. Click it — the tailscale daemon opens `https://login.tailscale.com/a/<id>` in a new browser tab (or asks you to open one). Complete OAuth with Google/GitHub/Microsoft. The web UI auto-refreshes to show your tailnet state.

At this point:
- The box has a tailnet name like `armbian.tail-xxxx.ts.net` and a `100.x.x.x` IP.
- SSH works from any tailnet peer: `ssh root@armbian.tail-xxxx.ts.net`.

### 2. pi-web sanity check

Open **`http://<box-ip>:30142`**. HTTP Basic prompt: **`root`** / **`1234`**. You should see the pi coding agent UI. If you want a different password, don't set one in pi-web — change Armbian's:

```bash
sudo passwd root
# New password: ****
# Retype:       ****
# → PAM hook fires, htpasswd is updated, next request uses the new password
```

To verify sync worked, check the log:

```bash
sudo journalctl -t pi-web-passwd-sync -n 5
# pi-web-passwd-sync: htpasswd for 'root' updated from root's shadow hash
```

### 3. Cloudflare Tunnel

Open **`http://<box-ip>:8888`**. First-run wizard walks you through:
- **Tunnel token** — from Cloudflare Zero Trust dashboard → Networks → Tunnels → your tunnel → "Install and run a connector" → copy the token. Paste it here; the GUI stores it as a podman secret (never on disk in cleartext).
- **Public hostname** — the FQDN you want to route to this box (e.g., `pi-armbian-test.woowtech.io`).
- **Backend service** — `http://192.168.2.149:8088` for tailscale web, or `http://192.168.2.149:30142` for pi-agent. Or a catch-all forwarding to nginx-proxy-manager if you want dispatched routing.

Once the tunnel is running, `curl https://<your-hostname>` from anywhere on the internet reaches the box.

---

## Architecture

```
                    ┌────────────────────────────────────────────────────────────┐
                    │                     H618 Reference Machine                 │
                    │                                                            │
   Browser ─LAN──►  │  :8088  tailscale-web ────► tailscaled ────► login.ts.net │
   Browser ─LAN──►  │  :30142 pi-agent-nginx ──► pi-web (podman rootless)       │
   Browser ─LAN──►  │  :8888  cf-tunnel-webgui ─► cloudflared (child proc)      │
                    │                                                            │
   internet ─CF──►  │  :8088 or :30142 (via cloudflared, if configured)          │
   tailnet ────►    │  :8088 or :30142 (via tailscale0)                          │
                    └────────────────────────────────────────────────────────────┘

   passwd root ─► PAM (common-password)
                  └► pam_exec ─► /usr/local/sbin/pi-web-passwd-sync.sh
                                  └► reads /etc/shadow → writes ~pi/.config/pi-agent/htpasswd
```

See **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** for the full layered explanation, and **[docs/SECURITY.md](docs/SECURITY.md)** for the threat model.

---

## Repo layout

```
Woow_H618_pi_agent_reference_machine/
├── install.sh                        # orchestrator (calls phase 1/2/3)
├── uninstall.sh                      # rollback (partial or full)
├── scripts/
│   ├── phase1-system-prep.sh         # root: apt, users, linger, sudoers, tailscaled
│   ├── phase2-user-services.sh       # pi:   clone, build images, install user units
│   ├── phase3-integration.sh         # root: tailscale-web, PAM hook, htpasswd seed
│   └── pi-web-passwd-sync.sh         # PAM hook target: shadow → htpasswd
├── systemd/
│   └── tailscale-web.service         # system unit for the tailscale web UI
├── podman/
│   ├── pi-web.service                # pi user systemd unit (podman run wrapper)
│   ├── pi-agent-nginx.service        # pi user systemd unit
│   └── cf-tunnel-webgui.service      # pi user systemd unit
├── etc/
│   ├── tailscale-woow.env            # WEB_LISTEN=0.0.0.0:8088
│   ├── sudoers.d/pi-nopasswd         # pi ALL=(ALL) NOPASSWD:ALL
│   └── pam.d/                        # (reserved for future PAM snippets)
├── docs/
│   ├── ARCHITECTURE.md
│   ├── SECURITY.md
│   └── TROUBLESHOOTING.md
├── LICENSE
└── README.md / README_zh-TW.md
```

---

## Verification

After install, a healthy box shows:

```bash
# system services
$ systemctl is-active tailscaled tailscale-web
active
active

# user services (as pi)
$ systemctl --user is-active pi-web pi-agent-nginx cf-tunnel-webgui
active
active
active

# published ports
$ ss -tlnp 2>/dev/null | grep -E ':(8088|30142|8888)\s'
LISTEN 0 4096 *:8088   *:* users:(("tailscale",...))
LISTEN 0 4096 *:30142  *:*
LISTEN 0 4096 *:8888   *:*

# pi-web reachable + auth working
$ curl -sSo /dev/null -w '%{http_code}\n' http://localhost:30142
401
$ curl -sSo /dev/null -w '%{http_code}\n' -u root:1234 http://localhost:30142
200

# password sync working
$ sudo passwd root                  # (set to something else)
$ sudo journalctl -t pi-web-passwd-sync -n 1 --no-pager
... pi-web-passwd-sync: htpasswd for 'root' updated from root's shadow hash
```

---

## Uninstall

```bash
# Stop services, remove volumes:
sudo ./uninstall.sh

# Or preserve pi-web sessions and cf-tunnel state:
sudo ./uninstall.sh --keep-data

# Or remove only the PAM hook (re-enable independent pi-web password):
sudo ./uninstall.sh --pam-only

# Or nuke everything including cloned source repos:
sudo ./uninstall.sh --purge
```

Things `uninstall.sh` deliberately does not touch: tailscaled (system tailscale), linger for pi, subuid/subgid, `/etc/os-release`. To wipe tailscale entirely:

```bash
sudo apt purge tailscale && sudo rm -rf /var/lib/tailscale
```

---

## Design decisions worth reading

- **Why the pi-web password is bound to Armbian root:** a reference machine has exactly one operator. Two independent passwords guarantee drift within a month. See [docs/SECURITY.md](docs/SECURITY.md) for why we did NOT go with nginx-pam auth (rootless container can't read `/etc/shadow`), and why PAM `pam_exec` on password change is safer than an inotify watcher on `/etc/shadow`.
- **Why hand-crafted `podman run` systemd units instead of Quadlet:** bookworm ships Podman 4.3.1; Quadlet requires 4.4. This repo tracks the OS we deploy to, not the OS we wish existed. When bookworm-backports or trixie become baseline, the `podman/` directory gets rewritten to Quadlet `*.container` files without any other change.
- **Why tailscale-web on `0.0.0.0:8088`:** so a browser on the LAN can reach it, so cloudflared (which lives on the LAN interface) can proxy it, and so a tailnet peer at `100.x.x.x:8088` can also reach it. Tailscale's own default of `100.x:5252` (tailnet-only) is wrong for our topology.
- **Why we removed the `tailscale-guard`:** the prior box had a systemd timer that rebound tailscale-web from `0.0.0.0` to `100.x` every 30 s "for security". This broke Cloudflare Tunnel (which uses the LAN IP). The guard was a custom hack — tailscale itself has no such thing. Removed here; if you need to restrict, use CF Access on the public URL, not surgery on the tailscale-web bind.

---

## License

MIT. See [LICENSE](LICENSE).

## Sibling repos

- [`WOOWTECH/Woow_podman_pi_agent_package`](https://github.com/WOOWTECH/Woow_podman_pi_agent_package) — the pi coding agent, packaged for rootless podman
- [`WOOWTECH/Woow_cloudflare_tunnel_webgui`](https://github.com/WOOWTECH/Woow_cloudflare_tunnel_webgui) — the Cloudflare Tunnel web GUI
- [`WOOWTECH/Woow_ha_vpn_headscale_package`](https://github.com/WOOWTECH/Woow_ha_vpn_headscale_package) — a headscale variant (not used here, but this repo's tailscale-web patterns are derived from it)
