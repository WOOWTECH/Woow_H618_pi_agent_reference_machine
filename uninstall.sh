#!/usr/bin/env bash
# Rollback Woow_H618_pi_agent_reference_machine.
#
# Usage:
#   sudo ./uninstall.sh                remove system pieces (PAM, tailscale-web, sudoers)
#                                      AND stop/remove user services
#   sudo ./uninstall.sh --keep-data    same as above but preserve podman volumes
#   sudo ./uninstall.sh --pam-only     remove ONLY the PAM sync hook
#                                      (re-enables independent pi-web password path)
#   sudo ./uninstall.sh --purge        remove EVERYTHING including the source repo clones
#                                      and podman volumes

set -euo pipefail

: "${PI_USER:=pi}"

[ "$(id -u)" -eq 0 ] || { echo "uninstall.sh must run as root" >&2; exit 1; }

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }

MODE=default
case "${1:-}" in
  --keep-data) MODE=keep_data; shift ;;
  --pam-only)  MODE=pam_only;  shift ;;
  --purge)     MODE=purge;     shift ;;
  "")          MODE=default ;;
  *)           echo "unknown arg: $1" >&2; exit 1 ;;
esac

remove_pam() {
  local file=/etc/pam.d/common-password
  local mark="# Woow_H618_pi_agent_reference_machine: pi-web password sync"
  if grep -qF "${mark}" "${file}"; then
    say "Removing PAM sync hook from ${file}"
    cp -a "${file}" "${file}.bak-$(date +%s)"
    # Delete the marker line, the 4 comment lines following it, the pam_exec
    # line, and the preceding blank line. Buffer the blank so we only print
    # it if it was NOT immediately followed by the marker. awk is easier to
    # reason about than a multi-line sed dance here.
    awk -v mark="${mark}" '
      buffered && $0 == mark { skipping = 5; buffered = 0; next }
      buffered { print prev; buffered = 0 }
      skipping > 0 { skipping--; next }
      /^$/ && !buffered { prev = $0; buffered = 1; next }
      { print }
      END { if (buffered) print prev }
    ' "${file}" > "${file}.new"
    mv "${file}.new" "${file}"
  fi
  rm -f /usr/local/sbin/pi-web-passwd-sync.sh
}

if [ "${MODE}" = "pam_only" ]; then
  remove_pam
  say "PAM hook removed. Independent pi-web password path is re-enabled."
  exit 0
fi

# --- stop + remove user services ---------------------------------------------
say "Stopping user services for '${PI_USER}'"
for unit in cf-tunnel-webgui pi-agent-nginx pi-web; do
  su - "${PI_USER}" -c "XDG_RUNTIME_DIR=/run/user/$(id -u ${PI_USER}) systemctl --user disable --now ${unit}.service" 2>/dev/null || true
done

say "Removing user unit files"
rm -f "/home/${PI_USER}/.config/systemd/user/pi-web.service"
rm -f "/home/${PI_USER}/.config/systemd/user/pi-agent-nginx.service"
rm -f "/home/${PI_USER}/.config/systemd/user/cf-tunnel-webgui.service"
rm -f "/home/${PI_USER}/.config/systemd/user/default.target.wants/pi-web.service"
rm -f "/home/${PI_USER}/.config/systemd/user/default.target.wants/pi-agent-nginx.service"
rm -f "/home/${PI_USER}/.config/systemd/user/default.target.wants/cf-tunnel-webgui.service"

say "Removing containers + network"
su - "${PI_USER}" -c 'podman rm -f pi-web pi-agent-nginx cf-tunnel-webgui' 2>/dev/null || true
su - "${PI_USER}" -c 'podman network rm pi-agent' 2>/dev/null || true

# --- system pieces -----------------------------------------------------------
say "Removing tailscale-web unit"
systemctl disable --now tailscale-web.service 2>/dev/null || true
rm -f /etc/systemd/system/tailscale-web.service
rm -f /etc/tailscale-woow.env
systemctl daemon-reload

remove_pam

say "Removing sudoers.d/${PI_USER}"
rm -f "/etc/sudoers.d/${PI_USER}"

# --- data ------------------------------------------------------------------
case "${MODE}" in
  keep_data)
    say "Preserving podman volumes (pi-agent-data, cf-tunnel-webgui-data)"
    ;;
  purge)
    warn "PURGE: removing podman volumes AND source repo clones"
    su - "${PI_USER}" -c 'podman volume rm pi-agent-data cf-tunnel-webgui-data' 2>/dev/null || true
    su - "${PI_USER}" -c 'podman image rm localhost/pi-agent:latest localhost/cf-webui:latest' 2>/dev/null || true
    rm -rf "/home/${PI_USER}/src/Woow_podman_pi_agent_package"
    rm -rf "/home/${PI_USER}/src/Woow_cloudflare_tunnel_webgui"
    rm -rf "/home/${PI_USER}/.config/pi-agent"
    rm -rf "/home/${PI_USER}/.config/cf-webui"
    ;;
  default)
    say "Removing podman volumes (pi-agent-data, cf-tunnel-webgui-data)"
    say "  Use --keep-data to preserve them, or --purge for a full wipe."
    su - "${PI_USER}" -c 'podman volume rm pi-agent-data cf-tunnel-webgui-data' 2>/dev/null || true
    ;;
esac

say "Untouched: tailscaled (system tailscale), linger, subuid/subgid, /etc/os-release."
say "  To fully wipe tailscale:  sudo apt purge tailscale && sudo rm -rf /var/lib/tailscale"
say "Uninstall complete."
