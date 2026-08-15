#!/usr/bin/env bash
# Phase 3: integration glue. Runs as root.
#
# What this does:
#   1. install /etc/systemd/system/tailscale-web.service + /etc/tailscale-woow.env
#   2. install /usr/local/sbin/pi-web-passwd-sync.sh (PAM hook target)
#   3. wire pam_exec into /etc/pam.d/common-password (idempotent, marker-guarded)
#   4. neutralize pi-agent's own scripts/set-password.sh (force the sync path)
#   5. seed the pi-web htpasswd with the CURRENT root shadow hash
#   6. set root password to '1234' if it is empty or locked (Armbian default)
#   7. enable + start tailscale-web
#
# After this runs, changing the Armbian root password (`passwd root`) will
# automatically update the pi-web htpasswd — no restart, no interactive step.

set -euo pipefail

: "${PI_USER:=pi}"
: "${REPO_ROOT:?REPO_ROOT is required}"
: "${SKIP_TS:=0}"

[ "$(id -u)" -eq 0 ] || { echo "phase3 must run as root" >&2; exit 1; }

say()  { printf '\033[1;34m==>\033[0m [phase3] %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m [phase3] %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m [phase3] %s\n' "$*" >&2; exit 1; }

# --- 1. tailscale-web unit + env --------------------------------------------
if [ "${SKIP_TS}" = "1" ]; then
  say "Skipping tailscale-web (per --skip-tailscale)"
else
  say "Installing tailscale-web system unit"
  install -m 0644 "${REPO_ROOT}/systemd/tailscale-web.service" /etc/systemd/system/tailscale-web.service
  # Only install env file if absent — do not overwrite operator's tuning.
  if [ ! -f /etc/tailscale-woow.env ]; then
    install -m 0644 "${REPO_ROOT}/etc/tailscale-woow.env" /etc/tailscale-woow.env
  else
    say "  /etc/tailscale-woow.env exists — leaving it alone"
  fi
  systemctl daemon-reload
  systemctl enable --now tailscale-web.service
  sleep 1
  systemctl is-active --quiet tailscale-web.service || warn "tailscale-web is not active — journalctl -u tailscale-web"
fi

# --- 2. PAM sync script ------------------------------------------------------
# /usr/local/sbin (not /bin) — this is a locally installed admin script, and
# putting it in sbin makes clear it should only run in root context.
say "Installing password sync script to /usr/local/sbin/pi-web-passwd-sync.sh"
install -m 0755 "${REPO_ROOT}/scripts/pi-web-passwd-sync.sh" /usr/local/sbin/pi-web-passwd-sync.sh

PAM_FILE=/etc/pam.d/common-password

# --- 3a. force sha512 crypt (yescrypt is unsupported by nginx-alpine) -------
# Verified on 2026-08-15: nginx:alpine's musl crypt() returns HTTP 500 when
# htpasswd contains a $y$ (yescrypt) hash. Armbian bookworm defaults to
# yescrypt via `pam_unix.so obscure yescrypt`. Rewrite that argument to
# `sha512` so future passwd changes produce $6$ hashes the sync script can
# copy verbatim into htpasswd.
if grep -qE '^password\s.*pam_unix\.so.*\byescrypt\b' "${PAM_FILE}"; then
  say "Switching ${PAM_FILE} pam_unix from yescrypt to sha512"
  cp -a "${PAM_FILE}" "${PAM_FILE}.bak-yescrypt-$(date +%s)"
  sed -i -E 's/(^password\s+.*pam_unix\.so\s+.*)\byescrypt\b/\1sha512/' "${PAM_FILE}"
fi

# --- 3b. PAM wiring for sync hook -------------------------------------------
# Append a pam_exec line to common-password if not already present. The
# marker ensures we do not append twice on re-run. We MUST use `optional`,
# not `required`: if our sync script ever breaks, users must still be able
# to change their password. Locking out a user because htpasswd sync failed
# would be a defect worse than the one we are fixing.
PAM_MARK="# Woow_H618_pi_agent_reference_machine: pi-web password sync"
say "Wiring pam_exec into ${PAM_FILE}"
if ! grep -qF "${PAM_MARK}" "${PAM_FILE}"; then
  # Back up before edit. common-password is core to system login; a bad edit
  # can lock you out. Keep a stamped copy.
  cp -a "${PAM_FILE}" "${PAM_FILE}.bak-$(date +%s)"
  {
    echo ""
    echo "${PAM_MARK}"
    echo "# quiet: suppress the script's stderr in the passwd caller's output"
    echo "# No 'type=update' — chpasswd (non-interactive) does not classify its"
    echo "#   PAM call as PAM_UPDATE_AUTHTOK, so type=update silently prevents"
    echo "#   the hook from firing. Verified 2026-08-15 on Armbian bookworm."
    echo "# No 'expose_authtok' — sync script reads shadow, never touches the"
    echo "#   plaintext. Firing 1-2 times per passwd is harmless (idempotent)."
    echo "password optional pam_exec.so quiet /usr/local/sbin/pi-web-passwd-sync.sh"
  } >> "${PAM_FILE}"
  say "  PAM hook appended"
else
  say "  PAM hook already present, skipping"
fi

# --- 4. neutralize pi-agent's own set-password.sh ---------------------------
# Requirement: pi-web password can ONLY be changed by changing the Armbian
# password. pi-agent's script writes to the same htpasswd directly. If left
# in place, the operator could bypass the sync path.
SETPW="/home/${PI_USER}/src/Woow_podman_pi_agent_package/scripts/set-password.sh"
if [ -f "${SETPW}" ]; then
  say "Neutralising pi-agent's independent set-password.sh"
  # Do NOT delete — the operator may re-clone the repo. Overwrite with a
  # stub that redirects them to the correct path. The stub is chmod 0755 so
  # `set -e` in a shell script still runs it (versus exec-bit removal, which
  # would surface as a shell error).
  chown "${PI_USER}:${PI_USER}" "${SETPW}" 2>/dev/null || true
  cat > "${SETPW}" <<'STUB'
#!/usr/bin/env bash
# NEUTRALISED by Woow_H618_pi_agent_reference_machine.
#
# The pi-web password is bound to the Armbian sudo user (root). Change it
# with `sudo passwd root`. That triggers a PAM hook which auto-updates this
# host's htpasswd — no restart needed.
#
# To re-enable the independent password path (NOT recommended on a reference
# machine — it desynchronises pi-web from Armbian), uninstall the PAM hook:
#   sudo /path/to/Woow_H618_pi_agent_reference_machine/uninstall.sh --pam-only
#
echo "This script is disabled on Woow H618 reference machines." >&2
echo "Change the pi-web password with:  sudo passwd root" >&2
exit 1
STUB
  chmod 0755 "${SETPW}"
fi

# --- 5. seed htpasswd from current /etc/shadow ------------------------------
# On a machine where root already has a non-empty shadow hash, mirror it now
# so pi-web is usable immediately (without waiting for the operator to run
# `passwd root`). The sync script does the same work as the PAM hook would.
say "Seeding pi-web htpasswd from current /etc/shadow (user 'root')"
PI_USER="${PI_USER}" /usr/local/sbin/pi-web-passwd-sync.sh --seed || \
  warn "Initial seed failed — the pi-web htpasswd is empty. Run: sudo passwd root"

# --- 5b. restart pi-agent-nginx to attach a fresh bind mount ----------------
# Podman bind-mounts the htpasswd file by INODE at container start. If phase
# 2 created a placeholder and phase 3 later `cp`s the real content over, the
# file's inode is preserved and the bind mount stays valid — but only if
# the container was started AFTER phase 2 created the placeholder. On an
# existing/upgraded box, the container may have an orphaned inode bind-
# mounted (from a previous mv-based swap). A one-shot restart re-resolves
# the bind mount against the current living inode. Cheap (~5s), idempotent.
if id -u "${PI_USER}" >/dev/null 2>&1; then
  say "Restarting pi-agent-nginx to attach current htpasswd inode"
  su - "${PI_USER}" -c "XDG_RUNTIME_DIR=/run/user/$(id -u ${PI_USER}) systemctl --user restart pi-agent-nginx.service" \
    2>/dev/null || warn "  restart failed; run manually: sudo -u ${PI_USER} systemctl --user restart pi-agent-nginx"
fi

# --- 6. root password fallback ----------------------------------------------
# If root shadow entry is empty (locked) — Armbian's post-first-boot state
# where root login was disabled — set it to '1234'. Chosen for parity with
# the Armbian factory default that operators expect on this class of device.
ROOT_SHADOW="$(getent shadow root | cut -d: -f2)"
case "${ROOT_SHADOW}" in
  ""|"!"|"!!"|"*")
    say "root shadow is empty/locked → setting root password to '1234' (Armbian default)"
    # chpasswd goes through PAM, which triggers the sync hook installed above,
    # so we do NOT need to also call the sync script here.
    echo "root:1234" | chpasswd
    ;;
  \$y\$*)
    # Existing root password uses yescrypt. Phase 3a switched PAM to sha512
    # for FUTURE passwd calls, but the existing shadow entry is untouched.
    # We do NOT force-reset the password (that would silently overwrite the
    # operator's chosen password). Instead, warn them: pi-web will 500 until
    # they run `passwd root` themselves. The sync script's seed step will
    # also have logged the same complaint.
    warn "root shadow uses yescrypt (\$y\$) — nginx-alpine cannot verify it."
    warn "  pi-web will return HTTP 500 for login until you run:"
    warn "      sudo passwd root"
    warn "  That regenerates the shadow hash as \$6\$ (sha512-crypt) and the"
    warn "  PAM hook syncs it into htpasswd automatically."
    ;;
  *)
    say "root already has a password — leaving it alone"
    ;;
esac

echo
say "Phase 3 complete."
