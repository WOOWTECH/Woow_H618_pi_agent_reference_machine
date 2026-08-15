#!/usr/bin/env bash
# Sync pi-web's htpasswd from Armbian /etc/shadow.
#
# Invoked in two ways:
#
#   1. PAM hook (during `passwd`, `chpasswd`, etc.):
#         pam_exec passes PAM_USER via env, and the new plaintext password
#         via stdin. This script IGNORES stdin — it reads the just-committed
#         shadow hash instead. That's why we can support arbitrary system
#         password-change tools (including `chpasswd -e` which bypasses
#         plaintext entirely), not just `passwd`.
#
#   2. Manual seed (phase 3, or operator-run):
#         `./pi-web-passwd-sync.sh --seed` — reads current /etc/shadow and
#         writes htpasswd without expecting any PAM env.
#
# The hash format used by /etc/shadow on Debian bookworm is $6$ (SHA-512
# crypt). nginx:alpine's musl libc supports $6$ verification through
# crypt(). So we can literally copy the shadow hash into htpasswd — no
# rehashing, no plaintext handled by this script.

set -euo pipefail

: "${PI_USER:=pi}"

MODE=hook
if [ "${1:-}" = "--seed" ]; then
  MODE=seed
fi

# In PAM_USER mode, pam_exec sets these environment variables:
#   PAM_USER           — the account whose password just changed
#   PAM_TYPE           — password
#   PAM_SERVICE        — passwd, chpasswd, ...
#
# We only care about `root`. Changing any other account's password should
# not touch pi-web. If PAM_USER is unset (seed mode), assume root.
TARGET_USER="${PAM_USER:-root}"
HTPASSWD_USER="root"    # Fixed: pi-web login name is always 'root'

if [ "${MODE}" = "hook" ] && [ "${TARGET_USER}" != "root" ]; then
  # A non-root user changed their password; nothing to do for pi-web.
  exit 0
fi

# Locate the pi user's htpasswd. If PI_USER is not present (should never
# happen at PAM time on a properly-installed box), fail silently so we do
# not break the passwd command that invoked us.
if ! HOME_DIR="$(getent passwd "${PI_USER}" | cut -d: -f6)" || [ -z "${HOME_DIR}" ]; then
  logger -t pi-web-passwd-sync "PI_USER '${PI_USER}' has no home dir — cannot update htpasswd"
  exit 0
fi
HTPASSWD_FILE="${HOME_DIR}/.config/pi-agent/htpasswd"

# Extract root's shadow hash. `getent shadow` respects nsswitch and works
# whether /etc/shadow is local, LDAP, or SSSD.
SHADOW_LINE="$(getent shadow "${TARGET_USER}" || true)"
if [ -z "${SHADOW_LINE}" ]; then
  logger -t pi-web-passwd-sync "no shadow entry for '${TARGET_USER}' — skipping"
  exit 0
fi
HASH="$(printf '%s' "${SHADOW_LINE}" | cut -d: -f2)"

# Reject placeholder shadow states. Writing "!" or "*" into htpasswd would
# make it unlockable but only by a matching magic string — a useless state.
case "${HASH}" in
  ""|"!"|"!!"|"*")
    logger -t pi-web-passwd-sync "'${TARGET_USER}' has no usable password (locked/empty) — htpasswd left unchanged"
    exit 0
    ;;
  \$6\$*|\$5\$*)
    # $6 SHA-512 crypt, $5 SHA-256 crypt. Both verified working with
    # nginx:alpine's musl crypt().
    :
    ;;
  \$y\$*)
    # yescrypt. Verified NOT supported by nginx:alpine's musl crypt()
    # (returns HTTP 500 on auth attempt). Refuse to write a broken htpasswd.
    # Phase 3 switches PAM to sha512 to prevent this; if you still see this,
    # your operator re-enabled yescrypt via pam-auth-update.
    logger -t pi-web-passwd-sync "'${TARGET_USER}' shadow uses yescrypt (\$y\$); nginx-alpine cannot verify it. Switch /etc/pam.d/common-password from 'yescrypt' to 'sha512' and re-run 'passwd ${TARGET_USER}'. htpasswd left unchanged."
    exit 0
    ;;
  *)
    logger -t pi-web-passwd-sync "unrecognised hash prefix in shadow for '${TARGET_USER}': ${HASH%%\$*}"
    exit 0
    ;;
esac

# IN-PLACE write, not mv. Podman bind-mounts the file by INODE at container
# start; `mv` swaps the pathname to a new inode and orphans the mount —
# nginx keeps seeing the old (now-deleted) inode indefinitely. We must
# preserve the inode: write to a tempfile first (for atomicity of content),
# then `cp` (which truncates + writes into the existing inode). nginx reads
# htpasswd per-request; a small cp is fast enough that the risk of reading
# a half-written file in practice is negligible for a 110-byte file.
#
# Mode 0644 (not 0600): the file is mounted read-only into nginx:alpine's
# rootless container. Host pi (uid 1000) maps to container root (uid 0);
# nginx worker inside the container runs as `nginx` (uid ~101). With 0600
# only container-root can read, and the worker gets EACCES → HTTP 500.
# 0644 lets the worker read. The hash is a KDF output, not a secret; other
# host users cannot escalate from reading it (they'd need to brute-force).
CONFIG_DIR="${HOME_DIR}/.config/pi-agent"
mkdir -p "${CONFIG_DIR}"

if [ ! -e "${HTPASSWD_FILE}" ]; then
  # First-time creation — plain write is fine, no bind-mount yet.
  printf '%s:%s\n' "${HTPASSWD_USER}" "${HASH}" > "${HTPASSWD_FILE}"
else
  # Existing file: preserve inode. Stage new contents, cp over the top.
  TMP="$(mktemp "${CONFIG_DIR}/.htpasswd.XXXXXX")"
  printf '%s:%s\n' "${HTPASSWD_USER}" "${HASH}" > "${TMP}"
  cp "${TMP}" "${HTPASSWD_FILE}"
  rm -f "${TMP}"
fi
chmod 0644 "${HTPASSWD_FILE}"
chown "${PI_USER}:${PI_USER}" "${HTPASSWD_FILE}"

# nginx reads htpasswd on each request; no restart is needed. But log it so
# the operator can confirm the sync fired.
logger -t pi-web-passwd-sync "htpasswd for '${HTPASSWD_USER}' updated from ${TARGET_USER}'s shadow hash"

exit 0
