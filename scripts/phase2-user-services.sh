#!/usr/bin/env bash
# Phase 2: user-scope service install. Runs as ${PI_USER}.
#
# What this does:
#   1. clone (or update) Woow_podman_pi_agent_package + Woow_cloudflare_tunnel_webgui into ~/src/
#   2. `podman build` both images (localhost/pi-agent:latest, localhost/cf-webui:latest)
#   3. create podman network + volumes
#   4. install three systemd user units in ~/.config/systemd/user/
#   5. enable + start all three units
#   6. install the initial nginx auth config (htpasswd will be filled by phase 3)
#
# Podman 4.3 (bookworm) has no Quadlet, so the units are hand-crafted
# `podman run` wrappers, mirroring what already runs on the reference box.
# On Podman >= 4.4 you could switch to Quadlet by dropping *.container files
# into ~/.config/containers/systemd/ — but the reference is 4.3.

set -euo pipefail

: "${REPO_ROOT:?REPO_ROOT is required}"
[ "$(id -u)" -ne 0 ] || { echo "phase2 must NOT run as root" >&2; exit 1; }

say()  { printf '\033[1;34m==>\033[0m [phase2] %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m [phase2] %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m [phase2] %s\n' "$*" >&2; exit 1; }

SRC_DIR="${HOME}/src"
PI_AGENT_REPO="${PI_AGENT_REPO:-https://github.com/WOOWTECH/Woow_podman_pi_agent_package.git}"
CF_WEBUI_REPO="${CF_WEBUI_REPO:-https://github.com/WOOWTECH/Woow_cloudflare_tunnel_webgui.git}"
PI_AGENT_DIR="${SRC_DIR}/Woow_podman_pi_agent_package"
CF_WEBUI_DIR="${SRC_DIR}/Woow_cloudflare_tunnel_webgui"

USER_SYSTEMD="${HOME}/.config/systemd/user"
CONFIG_PI_AGENT="${HOME}/.config/pi-agent"
CONFIG_CF_WEBUI="${HOME}/.config/cf-webui"

# systemctl --user needs XDG_RUNTIME_DIR pointing at /run/user/UID. sudo -u
# does not always propagate it. Set it defensively.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

# --- 1. clone/update source repos --------------------------------------------
say "Cloning source repos into ${SRC_DIR}"
mkdir -p "${SRC_DIR}"

clone_or_update() {
  local url="$1" dir="$2"
  if [ -d "${dir}/.git" ]; then
    say "  updating ${dir##*/}"
    git -C "${dir}" fetch --quiet --depth=1 origin || warn "  fetch failed — using local copy"
    git -C "${dir}" reset --hard --quiet FETCH_HEAD 2>/dev/null || true
  else
    say "  cloning ${url}"
    git clone --depth=1 --quiet "${url}" "${dir}"
  fi
}

clone_or_update "${PI_AGENT_REPO}" "${PI_AGENT_DIR}"
clone_or_update "${CF_WEBUI_REPO}" "${CF_WEBUI_DIR}"

# --- 2. build images ---------------------------------------------------------
# --format=docker is REQUIRED for pi-agent's HEALTHCHECK to work. OCI format
# silently drops it — the container comes up but `podman ps` never reports
# healthy, and dependent units cannot key off health.
say "Building pi-agent image (this takes 5-15 min on H618)"
cd "${PI_AGENT_DIR}"
podman build --format=docker \
  -t localhost/pi-agent:latest \
  -f Containerfile .

say "Building cf-webui image"
cd "${CF_WEBUI_DIR}"
podman build \
  -t localhost/cf-webui:latest \
  -f Dockerfile .

# --- 3. network + volumes ----------------------------------------------------
say "Ensuring podman network + volumes"
podman network exists pi-agent 2>/dev/null || podman network create pi-agent
podman volume exists pi-agent-data 2>/dev/null || podman volume create pi-agent-data
podman volume exists cf-tunnel-webgui-data 2>/dev/null || podman volume create cf-tunnel-webgui-data

# --- 4. nginx config for pi-agent -------------------------------------------
# pi-agent's own nginx.conf is shipped in the source repo. We reuse it
# verbatim — no need to duplicate. htpasswd and auth.conf are seeded here
# with placeholders; phase 3 overwrites htpasswd with the shadow-synced hash
# on its first pass.
say "Seeding ${CONFIG_PI_AGENT}"
mkdir -p "${CONFIG_PI_AGENT}"
install -m 0644 "${PI_AGENT_DIR}/config/nginx.conf" "${CONFIG_PI_AGENT}/nginx.conf"

# auth.conf: turn ON basic auth pointing at htpasswd. Do this even before the
# htpasswd is populated — an empty htpasswd file causes nginx to reject ALL
# requests, which is the safe default. Phase 3 fills the file within a
# fraction of a second, so the actual auth-off window is trivial.
cat > "${CONFIG_PI_AGENT}/auth.conf" <<'EOF'
# Managed by Woow_H618_pi_agent_reference_machine. Do not edit — phase 3
# rewrites this file on password sync from Armbian /etc/shadow.
auth_basic "Woow Pi Agent (Armbian sudo)";
auth_basic_user_file /etc/nginx/htpasswd;
EOF
chmod 644 "${CONFIG_PI_AGENT}/auth.conf"

# htpasswd: empty placeholder. Mode 0644 (not 0600) because the file is
# mounted read-only into nginx:alpine and nginx worker runs as uid ~101,
# which cannot read a 0600 file owned by container-root (= host pi). Phase 3
# fills it via the shadow-sync path.
if [ ! -f "${CONFIG_PI_AGENT}/htpasswd" ]; then
  install -m 0644 /dev/null "${CONFIG_PI_AGENT}/htpasswd"
fi

# --- 5. cf-webui env ---------------------------------------------------------
say "Seeding ${CONFIG_CF_WEBUI}"
mkdir -p "${CONFIG_CF_WEBUI}"
if [ ! -f "${CONFIG_CF_WEBUI}/env" ]; then
  # Random CSRF secret. Regenerating it invalidates existing sessions on the
  # cf-webui login page — that's the correct behaviour when this file is
  # re-seeded.
  CSRF="$(openssl rand -hex 32)"
  install -m 0600 /dev/null "${CONFIG_CF_WEBUI}/env"
  printf 'CSRF_SECRET=%s\n' "${CSRF}" > "${CONFIG_CF_WEBUI}/env"
fi

# --- 6. systemd user units ---------------------------------------------------
say "Installing systemd user units to ${USER_SYSTEMD}"
mkdir -p "${USER_SYSTEMD}"
for unit in pi-web.service pi-agent-nginx.service cf-tunnel-webgui.service; do
  install -m 0644 "${REPO_ROOT}/podman/${unit}" "${USER_SYSTEMD}/${unit}"
done

# cf-tunnel-webgui.service uses EnvironmentFile=%h/.config/cf-webui/env, so
# regenerating the env file must be paired with restart to pick up new CSRF.
# We do systemctl --user daemon-reload here explicitly; the phase 3 wrap-up
# handles restart.
systemctl --user daemon-reload

# --- 7. enable + start units -------------------------------------------------
# Order matters for the FIRST start. pi-web has to exist before nginx tries
# to resolve its hostname on the pi-agent bridge network. Requires= on the
# nginx unit handles the same-boot case, but on the very first `start`
# systemd starts them concurrently unless we serialize.
say "Enabling + starting user units"
systemctl --user enable --now pi-web.service
# Give pi-web ~10s to publish its port before nginx resolves the hostname.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  podman container inspect pi-web --format '{{.State.Health.Status}}' 2>/dev/null | grep -q healthy && break
  sleep 1
done
systemctl --user enable --now pi-agent-nginx.service
systemctl --user enable --now cf-tunnel-webgui.service

# Sanity: three units, all active.
sleep 2
for u in pi-web pi-agent-nginx cf-tunnel-webgui; do
  if systemctl --user is-active --quiet "${u}.service"; then
    say "  ${u}.service: active"
  else
    warn "  ${u}.service is NOT active — check: journalctl --user -u ${u}.service"
  fi
done

echo
say "Phase 2 complete. Continue with:  sudo ./install.sh --phase 3"
