#!/usr/bin/env bash
# Woow H618 pi-agent reference machine — top-level orchestrator.
#
# Two-phase install. Phase 1 runs as root (apt, users, system units, PAM).
# Phase 2 runs as pi (podman build, user units, linger). Phase 3 wires the
# two together: tailscale-web unit, password-sync hook, sudoers, tailscale
# instructions. Each phase script is idempotent — this script is safe to
# re-run after a partial failure.
#
# Usage:
#   ./install.sh                    (default: interactive, all phases)
#   ./install.sh --phase 1          (root only, system prep)
#   ./install.sh --phase 2          (pi only, user services)
#   ./install.sh --phase 3          (root only, integration glue)
#   ./install.sh --skip-tailscale   (skip tailscale entirely)
#   ./install.sh --no-color         (plain output)
#
# Environment variables (optional):
#   TS_AUTHKEY       — tailscale pre-auth key; if set, skip browser-based login
#   PI_USER          — non-root user that owns podman + services (default: pi)
#   REPO_ROOT        — override REPO_DIR autodetection

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${REPO_ROOT:=${REPO_DIR}}"
: "${PI_USER:=pi}"

# --- output helpers -----------------------------------------------------------
if [ -t 1 ] && [ "${NO_COLOR:-}" != "1" ] && [ "${1:-}" != "--no-color" ]; then
  C_BLUE=$'\033[1;34m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_RESET=$'\033[0m'
else
  C_BLUE=''; C_YELLOW=''; C_RED=''; C_GREEN=''; C_RESET=''
fi
say()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
warn() { printf '%s!!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
die()  { printf '%sXX%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
ok()   { printf '%sOK%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }

# --- arg parsing --------------------------------------------------------------
PHASE=all
SKIP_TS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --phase)         PHASE="${2:?--phase needs 1|2|3|all}"; shift 2 ;;
    --skip-tailscale) SKIP_TS=1; shift ;;
    --no-color)      shift ;;
    -h|--help)       sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown argument: $1" ;;
  esac
done

# --- sanity -------------------------------------------------------------------
[ -x "${REPO_ROOT}/scripts/phase1-system-prep.sh" ] || die "phase1 script missing at ${REPO_ROOT}/scripts/phase1-system-prep.sh"
[ -x "${REPO_ROOT}/scripts/phase2-user-services.sh" ] || die "phase2 script missing"
[ -x "${REPO_ROOT}/scripts/phase3-integration.sh" ] || die "phase3 script missing"

id "${PI_USER}" >/dev/null 2>&1 || warn "user '${PI_USER}' does not exist yet — phase 1 will create it"

run_phase() {
  local n="$1"
  case "$n" in
    1)
      say "PHASE 1 — system prep (root)"
      if [ "$(id -u)" -eq 0 ]; then
        REPO_ROOT="${REPO_ROOT}" PI_USER="${PI_USER}" \
          bash "${REPO_ROOT}/scripts/phase1-system-prep.sh"
      else
        REPO_ROOT="${REPO_ROOT}" PI_USER="${PI_USER}" \
          sudo -E bash "${REPO_ROOT}/scripts/phase1-system-prep.sh"
      fi
      ok "Phase 1 done"
      ;;
    2)
      say "PHASE 2 — user services as '${PI_USER}' (podman build + systemd user units)"
      if [ "$(id -un)" = "${PI_USER}" ]; then
        REPO_ROOT="${REPO_ROOT}" bash "${REPO_ROOT}/scripts/phase2-user-services.sh"
      else
        # su - preserves login environment (XDG_RUNTIME_DIR, DBUS, etc.)
        # which systemctl --user requires. sudo -u alone is not enough.
        sudo -u "${PI_USER}" -H env REPO_ROOT="${REPO_ROOT}" \
          bash -lc "${REPO_ROOT}/scripts/phase2-user-services.sh"
      fi
      ok "Phase 2 done"
      ;;
    3)
      say "PHASE 3 — integration glue (root)"
      if [ "$(id -u)" -eq 0 ]; then
        REPO_ROOT="${REPO_ROOT}" PI_USER="${PI_USER}" SKIP_TS="${SKIP_TS}" \
          bash "${REPO_ROOT}/scripts/phase3-integration.sh"
      else
        REPO_ROOT="${REPO_ROOT}" PI_USER="${PI_USER}" SKIP_TS="${SKIP_TS}" \
          sudo -E bash "${REPO_ROOT}/scripts/phase3-integration.sh"
      fi
      ok "Phase 3 done"
      ;;
    *) die "unknown phase: $n" ;;
  esac
}

case "${PHASE}" in
  all) run_phase 1; run_phase 2; run_phase 3 ;;
  1|2|3) run_phase "${PHASE}" ;;
  *) die "unknown --phase: ${PHASE}" ;;
esac

# --- post-install summary -----------------------------------------------------
if [ "${PHASE}" = "all" ] || [ "${PHASE}" = "3" ]; then
  HOST_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
  : "${HOST_IP:=<box-ip>}"
  cat <<EOF

${C_GREEN}Install complete.${C_RESET} Next steps:

  1. ${C_BLUE}Tailscale login${C_RESET}
     Open ${C_YELLOW}http://${HOST_IP}:8088${C_RESET} in a browser.
     Click "Log in" → complete Google/GitHub OAuth at login.tailscale.com.
     After it says "Connected", the box is on your tailnet.

  2. ${C_BLUE}pi-web (coding agent)${C_RESET}
     Local:   http://${HOST_IP}:30142
     Login:   ${C_YELLOW}root${C_RESET} / ${C_YELLOW}1234${C_RESET}  (same as Armbian sudo)
     Change:  ${C_YELLOW}sudo passwd root${C_RESET}   (PAM hook auto-syncs pi-web)

  3. ${C_BLUE}Cloudflare Tunnel GUI${C_RESET}
     http://${HOST_IP}:8888
     Paste your tunnel token there — it is not stored in this repo.

  4. ${C_BLUE}Reference docs${C_RESET}
     README.md, docs/ARCHITECTURE.md, docs/SECURITY.md, docs/TROUBLESHOOTING.md

EOF
fi
