# Security posture

This document is a threat model, not a compliance checklist. It says what this deployment defends against, what it does not, and where each control lives.

## What this box is exposed to

By default, once you complete the post-install steps:

| Interface | Reachable from | Auth |
|---|---|---|
| `:8088` tailscale-web | LAN, tailnet, cloudflared | none (any client can control tailscale) |
| `:30142` pi-agent-nginx | LAN, tailnet, cloudflared | HTTP Basic (root/1234 initially) |
| `:8888` cf-tunnel-webgui | LAN, tailnet, cloudflared | CSRF-double-submit; no user auth |
| `:22` sshd | LAN, tailnet | password (root/1234), pubkey |
| Public URL via CF Tunnel | internet | whatever CF Access rules you configure (none by default) |

**The reference machine is not hardened for direct internet exposure.** Its design point is "trusted LAN + tailnet + CF Tunnel with CF Access". If you skip CF Access on the public URL, you have chosen to publish an unauthenticated tailscale control panel on the internet. Do not do that.

## Design decisions and their rationale

### 1. pi-web password is bound to Armbian root

**Requirement:** the pi-web password can only be changed by changing the Armbian root password.

**Why:** two independent passwords guarantee drift within a month. The operator changes one and forgets the other. Over time, "root password" and "pi-web password" become two different secrets, and the operator does not know which one is current.

**Implementation:**
- PAM `pam_exec` on `common-password` calls `/usr/local/sbin/pi-web-passwd-sync.sh` after every successful password change.
- The sync script reads `/etc/shadow` (not PAM's plaintext), extracts the hash, writes it to `~pi/.config/pi-agent/htpasswd`.
- pi-agent's own `scripts/set-password.sh` is replaced with a stub that refuses to run and points the operator at `passwd root`.

**What this defends against:**
- Password drift over time
- Forgetting to update one system after rotating the other
- An operator who does not know which of two passwords is "the current one"

**What this does not defend against:**
- An attacker who can already run `sudo` on the box (they can change root's password and pi-web's password follows). This is the correct behaviour — a root-capable attacker has already won.
- An attacker who compromises the pi user (they can rewrite `htpasswd` directly, bypassing the shadow-sourced hash). The `htpasswd` file is `0600` and owned by pi; a pi-compromise trivially bypasses the sync.

### 2. Same hash format ($6$ SHA-512 crypt)

**Choice:** nginx reads `htpasswd` using its own crypt-compatible verifier. Debian bookworm's `/etc/shadow` uses `$6$` (SHA-512 crypt) by default. musl libc in `nginx:alpine` supports `$6$`. So the shadow hash is copied verbatim — no re-hashing, no plaintext passes through the sync script.

**Alternative rejected:** bcrypt. Would need re-hashing (from `$6$` to `$2b$`), which needs plaintext, which means the sync script would have to consume PAM_AUTHTOK from stdin. More moving parts, no security gain — the security of the hash is dominated by the choice of plaintext password (`1234` by default; the operator will change it).

**Caveat:** if you enable yescrypt on this box (via `pam-auth-update`, uncommon on bookworm arm64), shadow uses `$y$`. musl's crypt() may or may not verify `$y$` depending on nginx-alpine build. If your operator did this and pi-web login stops working after a `passwd root`, that is why. Workaround: leave the shadow encryption method at the bookworm default.

### 3. `pi ALL=(ALL) NOPASSWD:ALL`

**Requirement:** operator running `sudo` should not be prompted for a password.

**Rationale:** this matches the Armbian factory UX and matches how the box is actually used — the operator is often in the middle of a chain of commands and pausing for password prompts breaks workflow.

**What this defends against:** nothing. `NOPASSWD` is not a defence.

**What this does not defend against:**
- An attacker who gets a shell as `pi` (via a compromised podman container, a leaked SSH key, whatever) has instant root. The password prompt would slow them by seconds, not defeat them.

**Mitigation:** don't get compromised. Concretely: don't add attack surface on `pi`'s account — don't run untrusted code as `pi`, don't publish `pi`'s SSH port to the internet, do rotate `pi`'s password if you set one.

If your threat model requires the sudo prompt, remove `/etc/sudoers.d/pi` and set a password:
```bash
sudo rm /etc/sudoers.d/pi
sudo passwd pi
```
Then interactive sudo will prompt as normal.

### 4. tailscale-web has no `--readonly`

**Choice:** we run `tailscale web` in its CLI-default mode (read/write). Anyone who can reach `:8088` can disconnect the box from the tailnet, change its exit node, share nodes, etc.

**Rationale:** `--readonly` gives a false sense of security. Someone with LAN access to `:8088` can already SSH to `root@<box>` (unless you've hardened SSH). "Read-only tailscale UI + full SSH" is the same threat surface as "read-write tailscale UI + full SSH", modulo one extra click.

**Correct mitigation for restricting the tailscale UI:** put CF Access in front of the public URL. Then `curl https://<box-public-url>/` requires an OTP email link before it even reaches tailscale-web. LAN peers still have full access — that is what "trusted LAN" means.

### 5. cf-tunnel token is not in the repo

**Requirement:** the CF tunnel token is only entered in the cf-webui GUI, never committed anywhere.

**Rationale:** the token grants full control over your tunnel (create/delete DNS routes, publish new hostnames). Anyone with it can silently repoint your `pi-armbian-test.woowtech.io` at their own laptop. Treat it like a production API key.

**Implementation:** cf-webui stores it as a podman secret (encrypted at rest in `~/.local/share/containers/storage/`), never in a systemd env file, never in the repo, never in `podman inspect` output.

### 6. root password default = `1234`

**Choice:** phase 3 sets root's password to `1234` if it is currently unset or locked.

**Rationale:** this matches the Armbian factory default. Operators expect `1234` on a factory-fresh Armbian; setting it lets us hand-off the box in a known state.

**Immediate action expected of the operator:** rotate the password after taking the box into service.
```bash
sudo passwd root
# → PAM hook auto-updates pi-web at the same time
```
If the operator forgets, `1234` remains — but only reachable via LAN or (if they've configured it) the public CF URL. If the latter is exposed without CF Access, the box is trivially takeable. Do not skip that step.

## Attack surface changes vs. earlier reference builds

If you have the earlier configuration on the box from before this repo existed:

| Was | Now | Effect |
|---|---|---|
| `tailscale-guard.timer` rebinding to tailnet-only | removed | UI is LAN-visible; CF Tunnel works. See design decision (4). |
| `tailscale web --readonly` | no `--readonly` | UI is read-write. See design decision (4). |
| pi-web htpasswd independent of Armbian shadow | bound via PAM | one password to rotate. |
| pi-agent `scripts/set-password.sh` writable | neutralised on this box | no divergent path. |
| HA + matter installed as root podman | removed | ~80 MB reclaimed, one attack surface less. |

## What to do if you are considering exposing this to the internet

Before you flip on the CF public URL:

1. **Put CF Access in front of every hostname you publish.** The wizard in cf-webui does this per-route. Require email OTP or hard-key at minimum.
2. **Rotate root password** — the sync will follow.
3. **Consider closing SSH to the public URL.** cf-webui can be configured to only expose specific paths (not `/*`). Do that if you don't need SSH-over-CF.
4. **Set up tailscale exit node policies** in the tailscale admin console if you don't want peers to route their traffic through this box.
5. **Watch `journalctl -u cloudflared -f` for a few days** to see what actually hits the URL. If you see unexpected paths being scanned, revisit CF Access rules.

You do not need CF Access if you never publish the public hostname — LAN + tailnet is a perfectly cromulent access model for a home / small-office reference machine.
