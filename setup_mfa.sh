#!/usr/bin/env bash
#
# setup_mfa.sh
# Adds TOTP-based multi-factor authentication to SSH (and optionally sudo)
# using PAM + Google Authenticator. Works on Debian/Ubuntu (apt) and
# RHEL/Fedora/CentOS (dnf/yum) family distros with systemd.
#
# Usage: sudo ./setup_mfa.sh [ssh|sudo|both]
#   ssh   - require TOTP for SSH logins (adds to whatever auth already works --
#           password and/or key -- does NOT force key-based auth to be required)
#   sudo  - require TOTP for sudo commands
#   both  - do both (default if no arg given)
#
set -euo pipefail

MODE="${1:-both}"
BACKUP_DIR="/root/mfa-setup-backups/$(date +%Y%m%d-%H%M%S)"
LOG() { echo -e "\e[1;36m[mfa-setup]\e[0m $*"; }
WARN() { echo -e "\e[1;33m[warn]\e[0m $*"; }
ERR() { echo -e "\e[1;31m[error]\e[0m $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  ERR "Run this with sudo. Example: sudo ./setup_mfa.sh both"
  exit 1
fi

if [[ "$MODE" != "ssh" && "$MODE" != "sudo" && "$MODE" != "both" ]]; then
  ERR "Invalid mode '$MODE'. Use: ssh | sudo | both"
  exit 1
fi

mkdir -p "$BACKUP_DIR"
LOG "Backups of any file we touch will land in $BACKUP_DIR"

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "$BACKUP_DIR/$(basename "$f").bak"
  fi
}

# ---------------------------------------------------------------------------
# 1. Detect package manager and install the module
# ---------------------------------------------------------------------------
PAM_MODULE_PATH=""

install_pkg() {
  if command -v apt-get >/dev/null 2>&1; then
    LOG "Detected apt (Debian/Ubuntu). Installing libpam-google-authenticator..."
    apt-get update -qq
    apt-get install -y libpam-google-authenticator >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    LOG "Detected dnf (Fedora/RHEL/CentOS 8+). Installing google-authenticator..."
    dnf install -y google-authenticator qrencode-libs >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    LOG "Detected yum (older RHEL/CentOS). Installing google-authenticator..."
    LOG "Note: this package usually requires the EPEL repo to be enabled first."
    yum install -y google-authenticator >/dev/null
  elif command -v pacman >/dev/null 2>&1; then
    LOG "Detected pacman (Arch). Installing libpam-google-authenticator..."
    pacman -Sy --noconfirm libpam-google-authenticator >/dev/null
  elif command -v zypper >/dev/null 2>&1; then
    LOG "Detected zypper (openSUSE). Installing google-authenticator-libpam..."
    zypper install -y google-authenticator-libpam >/dev/null
  else
    ERR "No supported package manager found (apt-get, dnf, yum, pacman, zypper)."
    ERR "Install a PAM Google Authenticator module manually, then re-run this script."
    exit 1
  fi
}

install_pkg

# Locate the actual .so file -- path differs by distro/architecture
for candidate in \
  /lib/x86_64-linux-gnu/security/pam_google_authenticator.so \
  /lib/aarch64-linux-gnu/security/pam_google_authenticator.so \
  /lib64/security/pam_google_authenticator.so \
  /lib/security/pam_google_authenticator.so \
  /usr/lib64/security/pam_google_authenticator.so \
  /usr/lib/security/pam_google_authenticator.so
do
  if [[ -f "$candidate" ]]; then
    PAM_MODULE_PATH="$candidate"
    break
  fi
done

if [[ -z "$PAM_MODULE_PATH" ]]; then
  # Fall back to searching, in case of a nonstandard layout
  PAM_MODULE_PATH=$(find / -xdev -name "pam_google_authenticator.so" 2>/dev/null | head -n1 || true)
fi

if [[ -z "$PAM_MODULE_PATH" ]]; then
  ERR "Installed the package but couldn't locate pam_google_authenticator.so."
  ERR "The install may have failed silently -- check the output above."
  exit 1
fi
LOG "PAM module found at: $PAM_MODULE_PATH"

if ! command -v google-authenticator >/dev/null 2>&1; then
  ERR "google-authenticator command not found after install. Aborting."
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Per-user TOTP enrollment
# ---------------------------------------------------------------------------
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
  ERR "Could not resolve home directory for user '$TARGET_USER'."
  exit 1
fi

if [[ -f "$USER_HOME/.google_authenticator" ]]; then
  LOG "TOTP secret already exists for $TARGET_USER, skipping enrollment."
  LOG "Delete $USER_HOME/.google_authenticator first if you want to re-enroll."
else
  LOG "Enrolling TOTP for user: $TARGET_USER"
  LOG "You'll be shown a QR code and secret. Scan it with an authenticator"
  LOG "app (FreeOTP, Aegis, Google Authenticator) BEFORE continuing, and"
  LOG "save the printed emergency scratch codes somewhere safe."
  sudo -u "$TARGET_USER" google-authenticator \
    -t -d -f -r 3 -R 30 -W

  # -t: time-based, -d: disallow reuse of a code, -f: force write config,
  # -r 3 -R 30: allow 3 codes per 30s window (clock drift tolerance),
  # -W: rate-limit login attempts (throttling brute force)
fi

# ---------------------------------------------------------------------------
# 3. PAM configuration
# ---------------------------------------------------------------------------
configure_pam_for() {
  local service="$1"   # sshd | sudo
  local pam_file="/etc/pam.d/$service"

  if [[ ! -f "$pam_file" ]]; then
    ERR "$pam_file not found -- is this service installed on this system?"
    return 1
  fi

  backup_file "$pam_file"

  if grep -q "pam_google_authenticator.so" "$pam_file" 2>/dev/null; then
    LOG "$pam_file already configured, skipping."
    return
  fi

  LOG "Adding pam_google_authenticator.so to $pam_file"
  echo "auth required pam_google_authenticator.so nullok" >> "$pam_file"
  # nullok here only matters for accounts that have NEVER enrolled a secret --
  # it does NOT let an already-enrolled account skip the code (see README).
  # It's a safety net for other accounts on this box during initial testing.
}

# ---------------------------------------------------------------------------
# 4. Detect actual sshd service unit name (varies by distro)
# ---------------------------------------------------------------------------
detect_ssh_service() {
  for svc in ssh sshd; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
      echo "$svc"
      return
    fi
  done
  echo ""
}

if [[ "$MODE" == "ssh" || "$MODE" == "both" ]]; then
  if [[ ! -f /etc/pam.d/sshd ]]; then
    ERR "/etc/pam.d/sshd not found -- openssh-server does not appear to be installed."
    ERR "Install it first (e.g. 'apt install openssh-server' or 'dnf install openssh-server') and re-run."
    exit 1
  fi

  configure_pam_for sshd

  # -------------------------------------------------------------------
  # SSH daemon configuration
  # -------------------------------------------------------------------
  SSHD_CONFIG="/etc/ssh/sshd_config"
  if [[ ! -f "$SSHD_CONFIG" ]]; then
    ERR "$SSHD_CONFIG not found. Aborting SSH configuration."
    exit 1
  fi
  backup_file "$SSHD_CONFIG"

  LOG "Configuring sshd_config to allow PAM + keyboard-interactive..."
  # We deliberately do NOT force AuthenticationMethods to require a public
  # key. That would break systems that only use password auth. Instead we
  # just make sure keyboard-interactive/PAM is enabled -- the TOTP prompt
  # then rides alongside whatever auth method (password or key) already works.
  for pair in "KbdInteractiveAuthentication yes" "UsePAM yes"; do
    key="${pair%% *}"
    if grep -qE "^\s*${key}\b" "$SSHD_CONFIG"; then
      sed -i "s|^\s*${key}\b.*|${pair}|" "$SSHD_CONFIG"
    else
      echo "$pair" >> "$SSHD_CONFIG"
    fi
  done
  # Older distros/OpenSSH versions use ChallengeResponseAuthentication instead
  if grep -qE "^\s*ChallengeResponseAuthentication\b" "$SSHD_CONFIG"; then
    sed -i "s|^\s*ChallengeResponseAuthentication\b.*|ChallengeResponseAuthentication yes|" "$SSHD_CONFIG"
  fi

  LOG "Validating sshd_config syntax before reload..."
  SSHD_BIN=$(command -v sshd || echo /usr/sbin/sshd)
  if "$SSHD_BIN" -t; then
    LOG "Syntax OK."
  else
    ERR "sshd_config failed validation! Restoring backup, NOT reloading."
    cp -a "$BACKUP_DIR/sshd_config.bak" "$SSHD_CONFIG"
    exit 1
  fi

  SSH_SVC=$(detect_ssh_service)
  if [[ -z "$SSH_SVC" ]]; then
    WARN "Could not detect the SSH systemd service name automatically."
    WARN "Config was updated and validated, but you must reload it manually,"
    WARN "e.g.: systemctl reload ssh   OR   systemctl reload sshd"
  else
    LOG "Reloading $SSH_SVC..."
    systemctl reload "$SSH_SVC"
  fi

  WARN "IMPORTANT: keep your current session open. Open a SECOND"
  WARN "terminal/session and test a fresh login now, before closing this one."
fi

if [[ "$MODE" == "sudo" || "$MODE" == "both" ]]; then
  if [[ ! -f /etc/pam.d/sudo ]]; then
    ERR "/etc/pam.d/sudo not found. Aborting sudo configuration."
    exit 1
  fi
  configure_pam_for sudo
  LOG "sudo now requires a TOTP code (accounts without enrollment still"
  LOG "work because of 'nullok' until you remove it -- see README)."
fi

LOG "Done. Backups saved in $BACKUP_DIR"
LOG "Next steps:"
LOG "  1. Test a NEW login/sudo in a separate session before trusting this."
LOG "  2. Store scratch codes somewhere other than the machine itself."
LOG "  3. Use toggle_mfa.sh to flip the requirement on/off during testing."
