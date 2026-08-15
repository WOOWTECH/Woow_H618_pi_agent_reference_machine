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

# --- 3. PAM wiring -----------------------------------------------------------
# Append a pam_exec line to common-password if not already present. The
# marker ensures we do not append twice on re-run. We MUST use `optional`,
# not `required`: if our sync script ever breaks, users must still be able
# to change their password. Locking out a user because htpasswd sync failed
# would be a defect worse than the one we are fixing.
PAM_FILE=/etc/pam.d/common-password
PAM_MARK="# Woow_H618_pi_agent_reference_machine: pi-web password sync"
say "Wiring pam_exec into ${PAM_FILE}"
if ! grep -qF "${PAM_MARK}" "${PAM_FILE}"; then
  # Back up before edit. common-password is core to system login; a bad edit
  # can lock you out. Keep a stamped copy.
  cp -a "${PAM_FILE}" "${PAM_FILE}.bak-$(date +%s)"
  {
    echo ""
    echo "${PAM_MARK}"
    echo "# expose_authtok: pass the new password on stdin to the script"
    echo "# quiet:          do not print the script's stderr into passwd's output"
    echo "# type=update:    only fire on successful password change (not on the"
    echo "#                 initial validation call)"
    echo "password optional pam_exec.so expose_authtok quiet type=update /usr/local/sbin/pi-web-passwd-sync.sh"
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
  *)
    say "root already has a password — leaving it alone"
    ;;
esac

echo
say "Phase 3 complete."
