# Troubleshooting

Real problems observed on real H618 boxes. If you hit something not listed, `journalctl` is the first stop.

## Quick sanity commands

```bash
# System-scope services
sudo systemctl status tailscaled tailscale-web
sudo journalctl -u tailscale-web -n 50

# User-scope services (run as pi)
systemctl --user status pi-web pi-agent-nginx cf-tunnel-webgui
journalctl --user -u pi-web -n 50

# Ports
sudo ss -tlnp | grep -E ':(8088|30142|8888|22)\s'

# Containers
podman ps -a
podman inspect pi-web --format '{{.State.Health.Status}}'

# Password sync log
sudo journalctl -t pi-web-passwd-sync -n 20 --no-pager

# tailscale state
tailscale status
tailscale netcheck
```

## Symptom index

- [pi-web returns 401 with the correct password](#pi-web-returns-401-with-the-correct-password)
- [pi-web returns 502 Bad Gateway](#pi-web-returns-502-bad-gateway)
- [CF public URL returns 502](#cf-public-url-returns-502)
- [tailscale-web page loads but "Log in" does nothing](#tailscale-web-page-loads-but-log-in-does-nothing)
- [`passwd root` succeeds but pi-web password is unchanged](#passwd-root-succeeds-but-pi-web-password-is-unchanged)
- [User services do not start at boot](#user-services-do-not-start-at-boot)
- [`podman run` fails with `newuidmap: write to uid_map failed`](#podman-run-fails-with-newuidmap-write-to-uid_map-failed)
- [phase 2 image build fails on the H618](#phase-2-image-build-fails-on-the-h618)
- [phase 2 fails at `systemctl --user`](#phase-2-fails-at-systemctl---user)
- [tailscale-web is bound to `100.x:5252` instead of `0.0.0.0:8088`](#tailscale-web-is-bound-to-100x5252-instead-of-0000088)
- [Everything works but "install.sh" complains repo missing](#everything-works-but-installsh-complains-repo-missing)

---

### pi-web returns 401 with the correct password

Cause candidates in order of likelihood:

1. **htpasswd file is empty.** phase 3 seeds it from the current shadow hash. If root has no shadow entry (empty or locked) at that moment, the seed silently succeeds-but-does-nothing. Fix:
   ```bash
   sudo passwd root                 # set a password
   sudo cat /home/pi/.config/pi-agent/htpasswd
   # should show:  root:$6$...
   ```
2. **Shadow hash format is not `$6$`.** Bookworm defaults to `$6$` (SHA-512 crypt). If you enabled yescrypt via `pam-auth-update`, shadow uses `$y$` — nginx-alpine's musl crypt may not verify it. Fix: revert to `$6$` in `/etc/pam.d/common-password`, then `sudo passwd root` again.
3. **Sync hook is not wired.** Check:
   ```bash
   grep -F 'Woow_H618' /etc/pam.d/common-password
   # should print the marker line
   ls -l /usr/local/sbin/pi-web-passwd-sync.sh
   # should be 0755
   ```
   Reinstall with `sudo ./install.sh --phase 3`.

### pi-web returns 502 Bad Gateway

nginx cannot reach `pi-web` on the container network. Usually:

1. **pi-web is not running.**
   ```bash
   systemctl --user status pi-web           # (as pi)
   podman logs pi-web --tail 50
   ```
2. **pi-web container name resolution is stale.** nginx resolves `pi-web` at startup; if pi-web was replaced, nginx has a dead IP. `pi-agent-nginx.service` is `PartOf=pi-web.service`, so restarting pi-web should restart nginx too. If it did not:
   ```bash
   systemctl --user restart pi-agent-nginx
   ```
3. **First-boot health check has not passed yet.** pi-web downloads ~720MB of video tooling on first start. It IS reachable during this download (the API is asynchronous), but `podman inspect pi-web --format '{{.State.Health.Status}}'` may say `starting` for several minutes. Wait it out or check `journalctl --user -u pi-web -f`.

### CF public URL returns 502

The tunnel is up but cloudflared cannot reach the backend it is configured to proxy. Verify:

```bash
# From this box, check what CF Tunnel is trying to reach:
curl -sSo /dev/null -w '%{http_code}\n' http://<box-lan-ip>:8088
curl -sSo /dev/null -w '%{http_code}\n' http://<box-lan-ip>:30142
```

If the LAN URL works but the public URL 502s:

1. **CF ingress hostname does not match** what you registered. Log into cf-webui at `:8888` and verify the "Public hostname" field matches the DNS record CF Zero Trust created.
2. **CF ingress service points at wrong port.** Common cause: someone reconfigured tailscale-web to `100.x:5252` (see the tailscale-guard section below); cf-webui still forwards to `<box-lan-ip>:8088`. Nothing listens there anymore.
3. **cloudflared child process crashed.** Check `podman logs cf-tunnel-webgui --tail 100`.

### tailscale-web page loads but "Log in" does nothing

`tailscaled` is not reachable from `tailscale web`. Very rare; usually means:

```bash
sudo systemctl status tailscaled
# → not running
```

Restart it:
```bash
sudo systemctl restart tailscaled tailscale-web
```

If tailscaled itself refuses to start, `journalctl -u tailscaled -n 100`. Common cause on ARM SBCs: `wireguard-go` fallback path (used when kernel WireGuard is missing) fails on a rebuilt kernel. Reboot; if it persists, check the kernel has `CONFIG_TUN=m` at minimum.

### `passwd root` succeeds but pi-web password is unchanged

1. **Check the sync ran:**
   ```bash
   sudo journalctl -t pi-web-passwd-sync -n 5 --no-pager
   ```
   A successful run prints `htpasswd for 'root' updated from root's shadow hash`. If there is no recent log line at all, the PAM hook is not firing — go to step 2. If the log line says "skipping" or "unrecognised hash prefix", the sync ran but decided the shadow entry was unusable — go to step 3.

2. **PAM wiring missing.** After a distro upgrade `common-password` sometimes gets rewritten by the package manager. Reinstall:
   ```bash
   sudo ./install.sh --phase 3
   ```
   (Idempotent; phase 3 only re-appends the hook if the marker is absent.)

3. **Shadow hash is empty/locked.** If root's shadow field is `""`, `!`, `!!`, or `*`, sync explicitly refuses to write a garbage htpasswd. Set a real password:
   ```bash
   sudo passwd root
   ```

4. **Browser cached the 401.** After a password change, browsers sometimes hold on to the old credentials. Open an incognito window or clear site data for the URL.

### User services do not start at boot

Linger is not enabled for the `pi` user:
```bash
loginctl show-user pi | grep Linger
# Linger=no  → problem
```

Fix:
```bash
sudo loginctl enable-linger pi
sudo systemctl restart user@$(id -u pi).service
```

Then `pi`'s services will start at every boot, before any login.

### `podman run` fails with `newuidmap: write to uid_map failed`

Missing subuid/subgid allocation for the pi user:
```bash
grep ^pi /etc/subuid /etc/subgid
# both should show:  pi:100000:65536
```

Fix:
```bash
sudo usermod --add-subuids 100000-165535 pi
sudo usermod --add-subgids 100000-165535 pi
# then, as pi:
podman system migrate
```

phase 1 does this automatically; if you got here it usually means phase 1 was skipped.

### phase 2 image build fails on the H618

Common causes:

1. **Out of disk.** `df -h ~pi/.local/share/containers` should show >3 GB free. Prune first: `podman image prune -a`.
2. **Out of memory during arm64 build.** The pi-agent image installs Chromium and Node modules; peak RSS can hit 1.5 GB. On a 4 GB H618 with HA running you might OOM. Free memory (which is why we removed HA), or add swap:
   ```bash
   sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
   sudo chmod 600 /swapfile
   sudo mkswap /swapfile
   sudo swapon /swapfile
   ```
3. **Slow build cache.** eMMC on H618 does ~40 MB/s writes. First build takes 10-15 minutes. Second build (with cache) is much faster.

If a specific layer fails, rerun with more logs:
```bash
cd ~/src/Woow_podman_pi_agent_package
podman build --format=docker --log-level=debug -t localhost/pi-agent:latest -f Containerfile . 2>&1 | tee /tmp/build.log
```

### phase 2 fails at `systemctl --user`

Usually one of:

1. **`XDG_RUNTIME_DIR` not set** in the sudo -u shell. phase 2 sets it defensively; if you invoked phase 2 by hand as pi and it still failed, verify:
   ```bash
   env | grep XDG_RUNTIME_DIR
   # should be:  XDG_RUNTIME_DIR=/run/user/1000
   ```
   Fix: `export XDG_RUNTIME_DIR=/run/user/$(id -u)`.
2. **`/run/user/1000` doesn't exist.** Happens on machines where pi has never logged in. phase 1 enables linger which creates it — but on a very fresh install the runtime dir may not appear until the first user session. Trigger it:
   ```bash
   sudo systemctl start user@$(id -u pi).service
   ```

### tailscale-web is bound to `100.x:5252` instead of `0.0.0.0:8088`

You (or a leftover `tailscale-guard.timer` from a prior install) have overridden the env file. Check:

```bash
cat /etc/tailscale-woow.env
# → WEB_LISTEN=0.0.0.0:8088     (correct)
# → WEB_LISTEN=100.x.x.x:5252   (wrong, and will break CF Tunnel)

systemctl list-unit-files | grep -i tailscale-guard
# → should show NOTHING
```

Fix:
```bash
sudo systemctl disable --now tailscale-guard.timer tailscale-guard.service 2>/dev/null
sudo rm -f /etc/systemd/system/tailscale-guard.{service,timer} /usr/local/bin/tailscale-guard.sh
sudo cp /path/to/Woow_H618_pi_agent_reference_machine/etc/tailscale-woow.env /etc/tailscale-woow.env
sudo systemctl daemon-reload
sudo systemctl restart tailscale-web
```

### Everything works but "install.sh" complains repo missing

`install.sh` uses `REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` — that resolves symlinks correctly. But if you `curl | bash`, `BASH_SOURCE` is empty and the resolution fails. Always `git clone` first:

```bash
git clone https://github.com/WOOWTECH/Woow_H618_pi_agent_reference_machine.git
cd Woow_H618_pi_agent_reference_machine
sudo ./install.sh
```

Do not `curl -sSL .../install.sh | sudo bash`. It will fail early with "phase1 script missing" and you will chase your tail wondering why.
