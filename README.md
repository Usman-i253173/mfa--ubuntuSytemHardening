# TOTP Multi-Factor Authentication for SSH & sudo

Adds time-based one-time password (TOTP) multi-factor authentication to SSH logins and `sudo` on Linux, using PAM and Google Authenticator. Originally built for Ubuntu 24.04 as a companion module to an existing hardening baseline (`secure_setup.sh`), and since generalized to auto-detect the package manager (apt/dnf/yum/pacman/zypper) and SSH service name, so it also works on other systemd-based distros.

## What this does

- Installs `libpam-google-authenticator`
- Enrolls a per-user TOTP secret (QR code + emergency scratch codes)
- Hooks TOTP verification into PAM for `sshd` and/or `sudo`
- Reconfigures `sshd` to require a code alongside the existing password/key
- Backs up every file it touches before changing it
- Validates SSH config syntax before ever reloading the service

## Requirements

- A Linux distro using PAM and systemd — tested logic covers:
  - Debian/Ubuntu (`apt`)
  - Fedora/RHEL/CentOS 8+ (`dnf`) — older RHEL/CentOS (`yum`) usually needs the EPEL repo enabled first
  - Arch (`pacman`), openSUSE (`zypper`)
- `sudo`/root access
- `openssh-server` installed **if** you want the SSH side (not required for sudo-only mode) — the script checks for this and stops with a clear message if it's missing
- An open source authenticator app on a separate device — **Aegis** or **FreeOTP** recommended

**Not covered:** non-systemd init systems, non-PAM authentication setups, or non-Linux systems (macOS, Windows, WSL without a real sshd). The script detects your package manager and SSH service name automatically rather than assuming Ubuntu specifically, but it hasn't been run against every distro/version combination — always test in a second session before trusting it, as the instructions below describe.

## Usage

```bash
chmod +x setup_mfa.sh
sudo ./setup_mfa.sh [ssh|sudo|both]
```

| Mode | Effect |
|---|---|
| `ssh` | Requires TOTP for SSH logins only |
| `sudo` | Requires TOTP for `sudo` only |
| `both` | Requires TOTP for both (default) |

During enrollment you'll be shown a QR code — scan it immediately with your authenticator app, then enter the 6-digit code it generates when prompted. Save the emergency scratch codes that print afterward somewhere **off this machine**.

## ⚠️ Precautions — read before running

- **Keep a second terminal/session open and logged in before running this**, and don't close it until you've confirmed a fresh login works. This is your rollback path if something breaks.
- **Test before enforcing.** The script leaves `nullok` in place initially, meaning login still works even without an enrolled code, so you can verify everything safely first. Do not manually remove `nullok` until you've tested.
- **Save your scratch codes off-machine.** If you lose the device running your authenticator app and don't have scratch codes, you can lock yourself out of your own account.
- **Never edit `/etc/pam.d/sshd`, `/etc/pam.d/sudo`, or `/etc/ssh/sshd_config` by hand without checking `sudo sshd -t` afterward.** A broken `sshd_config` can silently prevent all SSH access.
- **If you're testing over SSH from a remote machine (not local), the risk is higher** — a bad config can cut off your only access route. Prefer testing locally at the machine when possible.
- Treat your TOTP secret and scratch codes as credentials. If either is ever exposed (screenshot, shared screen, chat log), re-enroll to generate a fresh secret:
  ```bash
  rm ~/.google_authenticator
  sudo ./setup_mfa.sh both
  ```

## Verifying it worked

```bash
sudo whoami          # should prompt for a verification code
ssh user@localhost   # should prompt for password/key, then a code
```

## Enforcing (making MFA mandatory)

Only after the above tests succeed:
```bash
sudo sed -i 's/ nullok//' /etc/pam.d/sshd
sudo sed -i 's/ nullok//' /etc/pam.d/sudo
```
Test again afterward to confirm login now fails without a valid code.

## ⚠️ The `nullok` gotcha

`nullok` only skips the code check for accounts that have **never enrolled** a TOTP secret. Once you've run enrollment for an account (i.e. `~/.google_authenticator` exists for that user), `nullok` has no effect on that account anymore — PAM will always ask it for a code, whether `nullok` is present or not.

In practice this means: if you've already enrolled and want to stop being asked for a code, adding `nullok` back **will not work**. You have to remove the `pam_google_authenticator.so` line entirely (see `toggle_mfa.sh` below), or delete `~/.google_authenticator` to un-enroll.

## Quick on/off toggle

For repeated testing, use `toggle_mfa.sh` instead of hand-editing PAM files:

```bash
chmod +x toggle_mfa.sh
sudo ./toggle_mfa.sh off      # removes the code requirement entirely
sudo ./toggle_mfa.sh on       # adds it back
sudo ./toggle_mfa.sh status   # check current state without changing anything
```

It backs up both PAM files before every change and runs `sudo -K` automatically afterward, so cached sudo sessions don't make it look like the toggle didn't work.

**Also watch for caching when testing manually:** `sudo` remembers a successful login for ~15 minutes by default, and some SSH clients reuse an existing authenticated connection. If a wrong code still seems to "work," run `sudo -K` first and use a completely new SSH connection before concluding anything is broken.

## Disabling / rolling back

**Quick disable** (remove the code requirement — use `toggle_mfa.sh off`, or manually):
```bash
sudo sed -i '/pam_google_authenticator.so/d' /etc/pam.d/sshd
sudo sed -i '/pam_google_authenticator.so/d' /etc/pam.d/sudo
```

**Full rollback** (restore pre-MFA state, using the script's own backups):
```bash
ls /root/mfa-setup-backups/
sudo cp /root/mfa-setup-backups/<timestamp>/sshd.bak /etc/pam.d/sshd
sudo cp /root/mfa-setup-backups/<timestamp>/sudo.bak /etc/pam.d/sudo
sudo cp /root/mfa-setup-backups/<timestamp>/sshd_config.bak /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl reload ssh
```

**Full removal:**
```bash
rm ~/.google_authenticator
sudo apt remove --purge libpam-google-authenticator
```

**Locked out entirely, no working shell:** if you're local at the machine, reboot → hold Shift at GRUB → Advanced options → Recovery mode → root shell → `mount -o remount,rw /` → run the rollback commands above.

## Known limitations

- TOTP protects against credential reuse and offline brute-forcing, but is **not phishing-resistant** — a real-time relay attack can still capture and replay a code. For phishing resistance, a hardware key with `pam_u2f` (FIDO2/U2F) would be a stronger follow-up.
- This module is independent of network/process-level hardening (firewall, fail2ban, AppArmor, etc.) — it strengthens the authentication step specifically and should be layered with, not substituted for, those other defenses.

## Files in this repository

| File | Purpose |
|---|---|
| `setup_mfa.sh` | One-time installer: installs the package, enrolls TOTP, configures PAM/SSH, validates config |
| `toggle_mfa.sh` | Repeatable on/off switch for the code requirement, used during testing |
| `README.md` | This file |

## Files touched on the system

| File | Change |
|---|---|
| `/etc/pam.d/sshd` | Adds/removes `pam_google_authenticator.so` |
| `/etc/pam.d/sudo` | Adds/removes `pam_google_authenticator.so` |
| `/etc/ssh/sshd_config` | Sets `KbdInteractiveAuthentication yes` and `UsePAM yes` (does not force SSH key auth to be required — the code rides alongside whatever auth already works) |
| `~/.google_authenticator` | Per-user TOTP secret and scratch codes |
| `/root/mfa-setup-backups/<timestamp>/` | Backup of PAM/SSH files, created before any change by either script |
