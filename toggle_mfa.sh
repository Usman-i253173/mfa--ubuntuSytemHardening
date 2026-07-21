#!/usr/bin/env bash
#
# toggle_mfa.sh
# Quickly turn the TOTP code requirement on or off for sudo/SSH.
#
# IMPORTANT: nullok only skips the code for accounts that have NEVER
# enrolled a secret. Once you've run google-authenticator for an account,
# nullok does nothing for that account -- PAM will always ask it for a
# code. So "off" here means fully removing the check, not adding nullok.
#
# Usage:
#   sudo ./toggle_mfa.sh on     -> code required
#   sudo ./toggle_mfa.sh off    -> code not required at all
#   sudo ./toggle_mfa.sh status -> show current state
#
set -euo pipefail

ACTION="${1:-status}"
SSHD_PAM="/etc/pam.d/sshd"
SUDO_PAM="/etc/pam.d/sudo"
BACKUP_DIR="/root/mfa-setup-backups/toggle-$(date +%Y%m%d-%H%M%S)"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo, e.g.: sudo ./toggle_mfa.sh on"
  exit 1
fi

show_status() {
  for f in "$SSHD_PAM" "$SUDO_PAM"; do
    if grep -q "pam_google_authenticator.so" "$f" 2>/dev/null; then
      echo "$f: MFA code REQUIRED"
    else
      echo "$f: MFA not required (line removed)"
    fi
  done
}

backup_now() {
  mkdir -p "$BACKUP_DIR"
  cp -a "$SSHD_PAM" "$BACKUP_DIR/sshd.bak" 2>/dev/null || true
  cp -a "$SUDO_PAM" "$BACKUP_DIR/sudo.bak" 2>/dev/null || true
}

case "$ACTION" in
  on)
    backup_now
    for f in "$SSHD_PAM" "$SUDO_PAM"; do
      if ! grep -q "pam_google_authenticator.so" "$f"; then
        echo "auth required pam_google_authenticator.so" >> "$f"
      fi
    done
    echo "MFA code is now REQUIRED for sudo and SSH."
    ;;
  off)
    backup_now
    sed -i '/pam_google_authenticator.so/d' "$SSHD_PAM"
    sed -i '/pam_google_authenticator.so/d' "$SUDO_PAM"
    echo "MFA code is now NOT required for sudo and SSH (check removed)."
    ;;
  status)
    show_status
    exit 0
    ;;
  *)
    echo "Usage: sudo ./toggle_mfa.sh [on|off|status]"
    exit 1
    ;;
esac

echo "Clearing cached sudo auth so the change takes effect immediately..."
sudo -K
echo "Test now with: sudo whoami"
