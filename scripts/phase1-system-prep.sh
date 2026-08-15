#!/usr/bin/env bash
# Phase 1: system-level preparation. Runs as root.
#
# What this does:
#   1. apt install: podman, tailscale, tools (curl, jq, ca-certificates, ...)
#   2. ensure PI_USER exists (default: pi)
#   3. subuid/subgid allocation for rootless podman (100000:65536)
#   4. enable systemd linger for PI_USER (so user services survive logout/reboot)
#   5. install /etc/sudoers.d/pi (NOPASSWD:ALL — matches the Armbian defaults)
#   6. enable + start tailscaled (does NOT run `tailscale up` — that's phase 3)
#
# Idempotent — safe to re-run.

set -euo pipefail

: "${PI_USER:=pi}"
: "${REPO_ROOT:?REPO_ROOT is required}"

[ "$(id -u)" -eq 0 ] || { echo "phase1 must run as root" >&2; exit 1; }

say()  { printf '\033[1;34m==>\033[0m [phase1] %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m [phase1] %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m [phase1] %s\n' "$*" >&2; exit 1; }

# --- 1. distro check ---------------------------------------------------------
if [ -r /etc/os-release ]; then
  . /etc/os-release
  case "${ID:-}${VERSION_CODENAME:+ ${VERSION_CODENAME}}" in
    debian\ bookworm|ubuntu\ *|armbian*|*bookworm*) : ;;
    *) warn "OS '${PRETTY_NAME:-unknown}' is not Debian bookworm — proceed at your own risk" ;;
  esac
fi

# --- 2. apt install ----------------------------------------------------------
# The tailscale package needs its own apt repo. Add it before `apt install`
# so both podman and tailscale come from one `apt install` call.
say "Adding Tailscale apt repo (idempotent)"
if [ ! -s /etc/apt/sources.list.d/tailscale.list ]; then
  # The signed-by keyring pattern is Debian's preferred way to scope a key to
  # a single repo. Storing the key in /etc/apt/trusted.gpg.d would trust it
  # for ALL repos, which is wrong for a vendor key.
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
    -o /etc/apt/sources.list.d/tailscale.list
else
  say "  tailscale.list exists, skipping"
fi

say "apt update + install baseline packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  podman \
  uidmap slirp4netns fuse-overlayfs \
  tailscale \
  curl jq ca-certificates gnupg \
  git \
  openssl \
  systemd \
  libpam-modules

say "  podman:     $(podman --version 2>/dev/null || echo NOT INSTALLED)"
say "  tailscale:  $(tailscale version 2>/dev/null | head -1 || echo NOT INSTALLED)"

# Podman 4.3 (bookworm) has no Quadlet. This repo ships hand-crafted user
# units in podman/ that call `podman run` directly, so 4.3 is fine.
PODMAN_MAJOR=$(podman --version | awk '{print $3}' | cut -d. -f1)
PODMAN_MINOR=$(podman --version | awk '{print $3}' | cut -d. -f2)
if [ "${PODMAN_MAJOR}" -lt 4 ] || { [ "${PODMAN_MAJOR}" -eq 4 ] && [ "${PODMAN_MINOR}" -lt 3 ]; }; then
  die "podman >= 4.3 required, got $(podman --version)"
fi

# --- 3. ensure PI_USER exists ------------------------------------------------
if ! id "${PI_USER}" >/dev/null 2>&1; then
  say "Creating user '${PI_USER}'"
  # -m creates home dir; -s /bin/bash matches Armbian default shell
  useradd -m -s /bin/bash "${PI_USER}"
  # No password set — the operator can `passwd ${PI_USER}` later. Even without
  # a password the account is usable for su/sudo (via /etc/sudoers.d/pi below).
else
  say "User '${PI_USER}' already exists"
fi

# --- 4. subuid/subgid for rootless podman ------------------------------------
# Podman rootless needs sub-IDs to map container users into the host. On a
# fresh install /etc/subuid may exist but not have an entry for this user,
# which surfaces later as `newuidmap: write to uid_map failed`.
say "Ensuring subuid/subgid for '${PI_USER}'"
if ! grep -q "^${PI_USER}:" /etc/subuid 2>/dev/null; then
  usermod --add-subuids 100000-165535 "${PI_USER}"
fi
if ! grep -q "^${PI_USER}:" /etc/subgid 2>/dev/null; then
  usermod --add-subgids 100000-165535 "${PI_USER}"
fi
say "  $(grep ^${PI_USER}: /etc/subuid) / $(grep ^${PI_USER}: /etc/subgid)"

# --- 5. linger ---------------------------------------------------------------
# Without lingering, systemctl --user services stop at logout and do NOT start
# at boot. That silently breaks pi-web after any reboot.
say "Enabling linger for '${PI_USER}'"
loginctl enable-linger "${PI_USER}" || warn "enable-linger failed — user services will not survive reboot"
if [ ! -d "/run/user/$(id -u ${PI_USER})" ]; then
  # Nudge the runtime dir into existence so phase 2's systemctl --user calls
  # do not fail on a system that has never had a login for this user.
  say "  Waiting for /run/user/$(id -u ${PI_USER}) to appear"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -d "/run/user/$(id -u ${PI_USER})" ] && break
    sleep 1
  done
fi

# --- 6. sudoers.d ------------------------------------------------------------
# Matches the Armbian convention: the wheel user is sudo without a password
# prompt. This is deliberate for a reference machine — the box is behind a
# LAN + tailnet + CF Access; adding a password prompt on top adds friction
# without meaningful defence.
say "Installing /etc/sudoers.d/${PI_USER} (NOPASSWD:ALL)"
install -m 0440 "${REPO_ROOT}/etc/sudoers.d/pi-nopasswd" "/etc/sudoers.d/${PI_USER}"
# visudo -c reads /etc/sudoers.d/* — this catches typos before we log out.
visudo -c >/dev/null || die "sudoers validation failed — /etc/sudoers.d/${PI_USER} rolled back"

# --- 7. tailscaled -----------------------------------------------------------
# Enable + start. We do NOT run `tailscale up` here — that would either block
# waiting for the operator to paste an auth URL, or require TS_AUTHKEY. Phase
# 3 installs the tailscale-web unit; the operator does the browser-based
# login from there, which is the cleanest UX.
say "Enabling + starting tailscaled"
systemctl enable --now tailscaled.service
systemctl is-active --quiet tailscaled.service || die "tailscaled failed to start — check: journalctl -u tailscaled"
say "  $(tailscale status --peers=false 2>&1 | head -1 || true)"

echo
say "Phase 1 complete. Continue with:  ./install.sh --phase 2  (or run install.sh with no --phase)"
