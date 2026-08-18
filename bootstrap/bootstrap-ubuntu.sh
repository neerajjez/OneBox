#!/usr/bin/env bash
#===============================================================================
# bootstrap-ubuntu.sh — step 0 for a fresh Ubuntu server on OCI (ARM64/AMD64)
#===============================================================================
#
# Turns a bare Ubuntu 22.04/24.04 instance into a usable cloud workstation:
# Docker, Tailscale, XFCE + XRDP, hardened SSH, fail2ban, unattended upgrades.
#
# ADMINISTERED THROUGH: Tailscale, SSH, XRDP.
# DELIBERATELY NOT: RustDesk, VNC, TeamViewer, or any third-party relay — each
# is an inbound path through someone else's infrastructure, and the whole point
# of the Tailscale mesh is that there isn't one.
#
#   sudo ./bootstrap-ubuntu.sh
#
# Idempotent: safe to rerun. Every step checks before it acts.
#
#-------------------------------------------------------------------------------
# READ THIS BEFORE RUNNING IT ON A MACHINE YOU CARE ABOUT
#-------------------------------------------------------------------------------
# This script REWRITES /etc/ssh/sshd_config and can insert firewall rules. On a
# server you are already using, that is a lockout risk, not a convenience. It is
# written for a machine you just created and can afford to destroy.
#
# SAFETY_ABORT_IF_PROVISIONED (below) refuses to run on a host that already
# looks like a working server. Turn it off only when you mean to.
#
# Before running on anything remote: open a SECOND ssh session and leave it
# idle. If sshd comes back wrong, that idle session is the only way in.
#
#-------------------------------------------------------------------------------
# HARD-WON DETAILS BAKED IN HERE
#-------------------------------------------------------------------------------
# These each cost real debugging time on a previous build. They look like fussy
# details; they are not.
#
#  1. An sshd `Match` block applies to EVERY line until the next Match or EOF.
#     It therefore must be the LAST thing in the file. Put it in the middle and
#     it silently swallows every directive below it. Worse, `sshd -T` does NOT
#     print Match blocks, so the config will look correct while behaving
#     differently — you cannot audit this with `sshd -T` alone.
#
#  2. Docker publishes ports by writing into the DOCKER chain, which is
#     evaluated BEFORE UFW's chain. `-p 9090:9090` is reachable from the
#     internet even with UFW default-deny, and UFW will report it as blocked.
#     UFW is not a firewall for containers. Use `expose:` or bind 127.0.0.1.
#
#  3. XRDP: `Policy=Default` matches a reconnecting user on window GEOMETRY, so
#     connecting from a differently-sized client creates a SECOND session. The
#     orphan's D-Bus/agent then blocks the new session's window manager, and the
#     session closes about a second after a correct password. Looks like an auth
#     bug; is not. Policy=UB + reaping disconnected sessions fixes it.
#
#  4. Compositing in xfwm4 is pure cost over a WAN link — it renders effects
#     that then have to be encoded and shipped as pixels.
#
#===============================================================================

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a          # never prompt about restarting services

#===============================================================================
# FEATURE FLAGS — everything configurable lives here
#===============================================================================

# --- components ---------------------------------------------------------------
INSTALL_DOCKER=${INSTALL_DOCKER:-true}
INSTALL_TAILSCALE=${INSTALL_TAILSCALE:-true}
INSTALL_XRDP=${INSTALL_XRDP:-true}
INSTALL_XFCE=${INSTALL_XFCE:-true}
INSTALL_UTILITIES=${INSTALL_UTILITIES:-true}

INSTALL_FAIL2BAN=${INSTALL_FAIL2BAN:-true}
INSTALL_RCLONE=${INSTALL_RCLONE:-true}
INSTALL_QEMU_AGENT=${INSTALL_QEMU_AGENT:-true}
INSTALL_UNATTENDED_UPGRADES=${INSTALL_UNATTENDED_UPGRADES:-true}

# --- firewall -----------------------------------------------------------------
ENABLE_IPTABLES=${ENABLE_IPTABLES:-true}
ENABLE_UFW_RULES=${ENABLE_UFW_RULES:-true}   # only if UFW is ALREADY active
ALLOW_PORT_22=${ALLOW_PORT_22:-true}
ALLOW_PORT_3389=${ALLOW_PORT_3389:-true}
ALLOW_PORT_443=${ALLOW_PORT_443:-true}

# --- user ---------------------------------------------------------------------
CREATE_TNK_USER=${CREATE_TNK_USER:-true}
USERNAME=${USERNAME:-prodadmin}
# Set BOOTSTRAP_PASSWORD in the environment instead of editing this file — a
# password committed to git is a password that must be rotated. If left at the
# default the script sets it, warns loudly, and forces a change at first login.
PASSWORD=${BOOTSTRAP_PASSWORD:-ChangeMe123!}
FORCE_PASSWORD_CHANGE=${FORCE_PASSWORD_CHANGE:-true}

# --- ssh ----------------------------------------------------------------------
DISABLE_ROOT_SSH=${DISABLE_ROOT_SSH:-true}
ALLOW_TNK_PASSWORD_AUTH=${ALLOW_TNK_PASSWORD_AUTH:-true}

# --- behaviour ----------------------------------------------------------------
AUTO_REBOOT=${AUTO_REBOOT:-false}
SAFETY_ABORT_IF_PROVISIONED=${SAFETY_ABORT_IF_PROVISIONED:-true}

LOG_FILE=${LOG_FILE:-/var/log/bootstrap.log}
BACKUP_DIR=${BACKUP_DIR:-/var/backups/bootstrap}

#===============================================================================
# LOGGING
#===============================================================================

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m';  C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_BOLD=''
fi

_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Colour goes to the terminal; the log file gets plain text. Escape codes in a
# log make grep and `less` miserable six months later.
_log() {
  local level="$1" colour="$2"; shift 2
  printf '%s%-5s%s %s\n' "$colour" "$level" "$C_RESET" "$*"
  printf '%s [%-5s] %s\n' "$(_ts)" "$level" "$*" >> "$LOG_FILE" 2>/dev/null || true
}
log_info()  { _log INFO  "$C_BLU" "$@"; }
log_ok()    { _log OK    "$C_GRN" "$@"; }
log_warn()  { _log WARN  "$C_YEL" "$@"; }
log_error() { _log ERROR "$C_RED" "$@" >&2; }
log_step()  {
  printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_BLU" "$*" "$C_RESET"
  printf '%s [STEP ] == %s ==\n' "$(_ts)" "$*" >> "$LOG_FILE" 2>/dev/null || true
}
log_skip()  { _log SKIP  "$C_DIM" "$@"; }

#===============================================================================
# ERROR HANDLING
#===============================================================================

FAILED_STEP=""

on_error() {
  local rc=$? line=$1
  log_error "FAILED at line ${line} (exit ${rc})${FAILED_STEP:+ during: ${FAILED_STEP}}"
  log_error "Log: ${LOG_FILE}"
  log_error "Config backups (if any): ${BACKUP_DIR}"
  # If sshd config was touched but never validated, say so explicitly. That is
  # the one failure that can cost access to the machine.
  if [[ -f /etc/ssh/sshd_config ]] && ! sshd -t 2>/dev/null; then
    log_error "sshd config is INVALID right now. Do NOT close your session."
    log_error "Restore with: cp ${BACKUP_DIR}/sshd_config.* /etc/ssh/sshd_config && systemctl restart ssh"
  fi
  exit "$rc"
}
trap 'on_error $LINENO' ERR

#===============================================================================
# HELPERS
#===============================================================================

need_root() {
  [[ ${EUID} -eq 0 ]] || { log_error "must run as root: sudo $0"; exit 1; }
}

# Back up a file once per run, timestamped, before the first modification.
backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  mkdir -p "$BACKUP_DIR"
  local base stamp dest
  base="$(basename "$f")"; stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="${BACKUP_DIR}/${base}.${stamp}"
  [[ -f "$dest" ]] || cp -a "$f" "$dest"
  log_info "backed up $(basename "$f") -> ${dest}"
}

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }

# Install a list, tolerating packages that do not exist on this release.
# A single missing package must not abort the whole bootstrap — `yq` and
# `fd-find` in particular move between universe/main across Ubuntu versions.
apt_install() {
  local pkgs=("$@") missing=()
  for p in "${pkgs[@]}"; do pkg_installed "$p" || missing+=("$p"); done
  if [[ ${#missing[@]} -eq 0 ]]; then
    log_skip "already installed: ${pkgs[*]}"
    return 0
  fi
  if apt-get install -y -qq "${missing[@]}" >>"$LOG_FILE" 2>&1; then
    log_ok "installed: ${missing[*]}"
    return 0
  fi
  log_warn "bulk install failed; retrying individually to isolate the bad package"
  local failed=()
  for p in "${missing[@]}"; do
    if apt-get install -y -qq "$p" >>"$LOG_FILE" 2>&1; then
      log_ok "installed: $p"
    else
      failed+=("$p"); log_warn "unavailable on this release: $p"
    fi
  done
  [[ ${#failed[@]} -gt 0 ]] && SKIPPED_PACKAGES+=("${failed[@]}")
  return 0
}

svc_enable_now() {
  local unit="$1"
  if ! systemctl list-unit-files "$unit" >/dev/null 2>&1 \
     || ! systemctl list-unit-files | grep -q "^${unit}"; then
    log_warn "unit not present, skipping: $unit"; return 0
  fi
  systemctl enable --now "$unit" >>"$LOG_FILE" 2>&1 || log_warn "could not enable $unit"
  if systemctl is-active --quiet "$unit"; then log_ok "active: $unit"
  else log_warn "not active: $unit"; fi
}

port_listening() { ss -tlnH "sport = :$1" 2>/dev/null | grep -q .; }

#===============================================================================
# PREFLIGHT
#===============================================================================

SKIPPED_PACKAGES=()
OS_ID=""; OS_VER=""; ARCH=""; CODENAME=""

preflight() {
  log_step "Preflight"
  need_root

  mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"
  touch "$LOG_FILE"; chmod 600 "$LOG_FILE"

  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-unknown}"; CODENAME="${VERSION_CODENAME:-}"
  ARCH="$(dpkg --print-architecture)"

  [[ "$OS_ID" == "ubuntu" ]] || { log_error "Ubuntu only; found: $OS_ID"; exit 1; }
  case "$OS_VER" in
    22.04|24.04) log_ok "Ubuntu $OS_VER ($CODENAME) on $ARCH" ;;
    *) log_warn "untested Ubuntu $OS_VER — continuing, but package names may differ" ;;
  esac
  case "$ARCH" in
    arm64|amd64) : ;;
    *) log_error "unsupported architecture: $ARCH"; exit 1 ;;
  esac

  # Refuse to reprovision a machine that is already doing a job. This script
  # rewrites sshd_config; running it against a live server by accident is the
  # kind of mistake that ends with a support ticket to the cloud console.
  if [[ "$SAFETY_ABORT_IF_PROVISIONED" == "true" ]]; then
    local signals=()
    [[ -d /opt/server ]] && signals+=("/opt/server exists")
    command -v docker >/dev/null 2>&1 && \
      [[ "$(docker ps -q 2>/dev/null | wc -l)" -gt 3 ]] && signals+=("$(docker ps -q | wc -l) containers running")
    [[ -f /etc/ssh/sshd_config.d/99-bootstrap.conf ]] && signals+=("previous bootstrap ssh drop-in")
    if [[ ${#signals[@]} -gt 0 ]]; then
      log_error "This host looks already provisioned: ${signals[*]}"
      log_error "This script rewrites sshd_config and firewall rules."
      log_error "If you really mean to, rerun with SAFETY_ABORT_IF_PROVISIONED=false"
      exit 1
    fi
  fi

  if [[ "$PASSWORD" == "ChangeMe123!" && "$CREATE_TNK_USER" == "true" ]]; then
    log_warn "Using the DEFAULT password for '${USERNAME}'."
    log_warn "Set BOOTSTRAP_PASSWORD=... in the environment instead of editing this file."
    [[ "$FORCE_PASSWORD_CHANGE" == "true" ]] && log_warn "Password change will be forced at first login."
  fi

  log_info "log: ${LOG_FILE}   backups: ${BACKUP_DIR}"
}

#===============================================================================
# SYSTEM UPDATE + BASE PACKAGES
#===============================================================================

system_update() {
  log_step "System update"
  FAILED_STEP="system update"
  apt-get update -qq >>"$LOG_FILE" 2>&1
  log_ok "apt index updated"
  apt-get -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    full-upgrade >>"$LOG_FILE" 2>&1
  log_ok "full-upgrade complete"
  apt_install ca-certificates curl wget gnupg lsb-release \
              software-properties-common apt-transport-https
  FAILED_STEP=""
}

install_utilities() {
  [[ "$INSTALL_UTILITIES" == "true" ]] || { log_skip "utilities disabled"; return 0; }
  log_step "Utilities"
  FAILED_STEP="utilities"
  apt_install \
    btop htop iotop iftop \
    tmux screen \
    tree ncdu \
    jq yq \
    ripgrep fd-find \
    lsof strace \
    unzip zip p7zip-full \
    dnsutils traceroute mtr netcat-openbsd nmap tcpdump iperf3 \
    git \
    build-essential gcc g++ make \
    python3-pip \
    vim nano \
    rsync \
    neofetch
  [[ "$INSTALL_RCLONE" == "true" ]] && apt_install rclone
  # Ubuntu ships fd as `fdfind` to avoid a name clash. Nobody remembers that.
  if command -v fdfind >/dev/null 2>&1 && [[ ! -e /usr/local/bin/fd ]]; then
    ln -sf "$(command -v fdfind)" /usr/local/bin/fd
    log_ok "linked fdfind -> /usr/local/bin/fd"
  fi
  FAILED_STEP=""
}

#===============================================================================
# USER
#===============================================================================

create_user() {
  [[ "$CREATE_TNK_USER" == "true" ]] || { log_skip "user creation disabled"; return 0; }
  log_step "User: ${USERNAME}"
  FAILED_STEP="user creation"

  if id -u "$USERNAME" >/dev/null 2>&1; then
    log_info "user exists; updating password only"
  else
    useradd --create-home --shell /bin/bash "$USERNAME"
    log_ok "created ${USERNAME}"
  fi

  # chpasswd reads stdin, so the password never appears in `ps` or shell history.
  printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd
  log_ok "password set"

  if [[ "$FORCE_PASSWORD_CHANGE" == "true" && "$PASSWORD" == "ChangeMe123!" ]]; then
    chage -d 0 "$USERNAME" && log_ok "password change forced at first login"
  fi

  usermod -aG sudo "$USERNAME"
  log_ok "added to sudo"

  # Only if the group exists — this may run before Docker is installed.
  if getent group docker >/dev/null 2>&1; then
    usermod -aG docker "$USERNAME"; log_ok "added to docker"
  else
    log_info "docker group absent for now; will add after Docker installs"
  fi

  install -d -m 700 -o "$USERNAME" -g "$USERNAME" "/home/${USERNAME}/.ssh"
  touch "/home/${USERNAME}/.ssh/authorized_keys"
  chmod 600 "/home/${USERNAME}/.ssh/authorized_keys"
  chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.ssh/authorized_keys"
  log_ok "/home/${USERNAME}/.ssh prepared (add your public key)"
  FAILED_STEP=""
}

#===============================================================================
# SSH
#===============================================================================

configure_ssh() {
  log_step "SSH hardening"
  FAILED_STEP="ssh configuration"
  local cfg=/etc/ssh/sshd_config
  backup_file "$cfg"

  # Set a directive idempotently: replace it if present (commented or not),
  # append if absent. Only ever touches the main body, never a Match block.
  set_sshd() {
    local key="$1" val="$2"
    if grep -qE "^[#[:space:]]*${key}[[:space:]]" "$cfg"; then
      sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$cfg"
    else
      printf '%s %s\n' "$key" "$val" >> "$cfg"
    fi
  }

  # Strip any Match block WE previously appended, so reruns do not stack them.
  # Marked with a sentinel so a hand-written Match is never touched.
  if grep -q '^# >>> bootstrap-managed match block' "$cfg"; then
    sed -i '/^# >>> bootstrap-managed match block/,/^# <<< bootstrap-managed match block/d' "$cfg"
    log_info "removed previous bootstrap Match block"
  fi

  [[ "$DISABLE_ROOT_SSH" == "true" ]] && set_sshd PermitRootLogin no
  set_sshd PubkeyAuthentication yes
  set_sshd PasswordAuthentication no
  set_sshd ChallengeResponseAuthentication no
  set_sshd KbdInteractiveAuthentication no
  set_sshd UsePAM yes
  set_sshd X11Forwarding no
  set_sshd MaxAuthTries 4
  set_sshd LoginGraceTime 30
  set_sshd ClientAliveInterval 300
  set_sshd ClientAliveCountMax 2

  # THE MATCH BLOCK MUST BE LAST IN THE FILE.
  # A Match applies to every directive until the next Match or EOF, so anything
  # appended after it silently becomes conditional. Note also that `sshd -T`
  # does not print Match blocks: this config cannot be fully audited with it.
  if [[ "$ALLOW_TNK_PASSWORD_AUTH" == "true" && "$CREATE_TNK_USER" == "true" ]]; then
    cat >> "$cfg" <<EOF

# >>> bootstrap-managed match block — MUST remain the last thing in this file.
# Everything below a Match is conditional. Appending anything after it changes
# that directive's meaning. \`sshd -T\` will not show these lines.
Match User ${USERNAME}
    PasswordAuthentication yes
# <<< bootstrap-managed match block
EOF
    log_ok "password auth enabled for ${USERNAME} only (Match block appended last)"
  fi

  # sshd -t needs the privilege separation directory to exist. systemd creates
  # it via tmpfiles on a real host, but it is absent in a fresh container and
  # then `sshd -t` fails for a reason that has nothing to do with the config —
  # which would send you hunting through sshd_config for a bug that isn't there.
  [[ -d /run/sshd ]] || { mkdir -p /run/sshd && chmod 0755 /run/sshd; }

  # Validate BEFORE restarting. A broken sshd that is still running is
  # recoverable; a broken sshd that has been restarted is not.
  local sshd_err
  if ! sshd_err="$(sshd -t 2>&1)"; then
    log_error "sshd config INVALID — restoring backup, not restarting"
    # Print the actual reason. "Config invalid" with no detail is the least
    # useful possible message at the exact moment it matters most.
    while IFS= read -r l; do [[ -n "$l" ]] && log_error "  sshd: $l"; done <<< "$sshd_err"
    printf '%s\n' "$sshd_err" >> "$LOG_FILE"
    local latest
    latest="$(find "$BACKUP_DIR" -name 'sshd_config.*' -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)"
    [[ -n "$latest" ]] && { cp -a "$latest" "$cfg"; log_warn "restored ${latest}"; }
    return 1
  fi
  log_ok "sshd -t passed"

  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  sleep 1
  if port_listening 22; then
    log_ok "sshd restarted and listening on 22"
  else
    log_error "sshd is NOT listening on 22 — keep your current session open"
    return 1
  fi

  log_info "effective: root=$([[ "$DISABLE_ROOT_SSH" == true ]] && echo disabled || echo unchanged), \
global password auth=off, ${USERNAME}=password+key"
  FAILED_STEP=""
}

#===============================================================================
# DOCKER — official APT repository only
#===============================================================================

install_docker() {
  [[ "$INSTALL_DOCKER" == "true" ]] || { log_skip "docker disabled"; return 0; }
  log_step "Docker"
  FAILED_STEP="docker"

  # Distro packages ship an old, differently-named Docker; the convenience
  # script pipes the internet into a root shell. Neither belongs on a server.
  local conflicting=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)
  for p in "${conflicting[@]}"; do
    if pkg_installed "$p"; then
      apt-get remove -y -qq "$p" >>"$LOG_FILE" 2>&1 && log_info "removed conflicting: $p"
    fi
  done

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    log_ok "docker GPG key installed"
  else
    log_skip "docker GPG key present"
  fi

  local list=/etc/apt/sources.list.d/docker.list
  local want="deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable"
  if [[ ! -f "$list" ]] || ! grep -qF "$want" "$list"; then
    echo "$want" > "$list"
    log_ok "docker repo configured for ${CODENAME}/${ARCH}"
    apt-get update -qq >>"$LOG_FILE" 2>&1
  else
    log_skip "docker repo already configured"
  fi

  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Bound container log growth at the daemon level, so a service that forgets
  # its own logging block still cannot fill the disk. Merge rather than
  # overwrite: an existing daemon.json may hold data-root or registry settings
  # that matter more than this does.
  local dj=/etc/docker/daemon.json
  mkdir -p /etc/docker
  if [[ -f "$dj" ]]; then
    backup_file "$dj"
    if command -v jq >/dev/null 2>&1; then
      local merged; merged="$(jq -S '. * {"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' "$dj" 2>/dev/null || true)"
      if [[ -n "$merged" ]]; then
        printf '%s\n' "$merged" > "$dj"; log_ok "merged log limits into existing daemon.json"
      else
        log_warn "daemon.json is not valid JSON; leaving it alone"
      fi
    else
      log_warn "jq unavailable; leaving existing daemon.json alone"
    fi
  else
    cat > "$dj" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    log_ok "wrote /etc/docker/daemon.json"
  fi

  svc_enable_now docker.service
  svc_enable_now containerd.service
  systemctl restart docker >>"$LOG_FILE" 2>&1 || log_warn "docker restart reported an error"

  if docker version >>"$LOG_FILE" 2>&1; then
    log_ok "docker version: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
  else
    log_error "docker is installed but not responding"; return 1
  fi

  # The group exists now even if it did not during create_user().
  if [[ "$CREATE_TNK_USER" == "true" ]] && id -u "$USERNAME" >/dev/null 2>&1; then
    usermod -aG docker "$USERNAME"; log_ok "${USERNAME} added to docker group"
  fi
  FAILED_STEP=""
}

#===============================================================================
# TAILSCALE
#===============================================================================

install_tailscale() {
  [[ "$INSTALL_TAILSCALE" == "true" ]] || { log_skip "tailscale disabled"; return 0; }
  log_step "Tailscale"
  FAILED_STEP="tailscale"

  # APT repo, not their install.sh. Same reasoning as Docker: a shell pipe from
  # the internet to root is not an install method, and the repo gives updates.
  if [[ ! -f /usr/share/keyrings/tailscale-archive-keyring.gpg ]]; then
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg" \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    log_ok "tailscale GPG key installed"
  else
    log_skip "tailscale GPG key present"
  fi

  local list=/etc/apt/sources.list.d/tailscale.list
  if [[ ! -f "$list" ]]; then
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.tailscale-keyring.list" -o "$list" 2>/dev/null \
      || echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu ${CODENAME} main" > "$list"
    apt-get update -qq >>"$LOG_FILE" 2>&1
    log_ok "tailscale repo configured"
  else
    log_skip "tailscale repo already configured"
  fi

  apt_install tailscale
  svc_enable_now tailscaled.service

  # Deliberately NOT running `tailscale up`. It needs an interactive auth URL or
  # a pre-auth key, and silently joining a tailnet is not something a bootstrap
  # script should decide. Surfaced in the summary instead.
  if tailscale status >/dev/null 2>&1; then
    log_ok "already authenticated: $(tailscale ip -4 2>/dev/null | head -1)"
  else
    log_info "installed but NOT authenticated — run 'sudo tailscale up' yourself"
  fi
  FAILED_STEP=""
}

#===============================================================================
# XFCE
#===============================================================================

install_xfce() {
  [[ "$INSTALL_XFCE" == "true" ]] || { log_skip "xfce disabled"; return 0; }
  log_step "XFCE desktop"
  FAILED_STEP="xfce"
  # XFCE only. KDE/Plasma and anything Wayland-based either will not work over
  # XRDP or will cost far more CPU than 2 cores can spare.
  apt_install xfce4 xfce4-goodies dbus-x11 xorg
  log_ok "XFCE installed"
  FAILED_STEP=""
}

# Compositing renders shadows and fades that must then be encoded and shipped as
# pixels over the WAN. It is pure cost on a remote desktop.
disable_compositing_for() {
  local home="$1" owner="$2"
  local dir="${home}/.config/xfce4/xfconf/xfce-perchannel-xml"
  local file="${dir}/xfwm4.xml"
  install -d -o "$owner" -g "$owner" -m 755 "$dir"
  if [[ -f "$file" ]] && grep -q 'use_compositing' "$file"; then
    sed -i 's|\(<property name="use_compositing" type="bool" value="\)true"|\1false"|' "$file"
  elif [[ ! -f "$file" ]]; then
    cat > "$file" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <!-- Compositing off: on a remote desktop every effect becomes encoded
         pixels over the WAN. Costs CPU and bandwidth, adds nothing. -->
    <property name="use_compositing" type="bool" value="false"/>
    <property name="box_move" type="bool" value="true"/>
    <property name="box_resize" type="bool" value="true"/>
  </property>
</channel>
EOF
  fi
  chown -R "$owner:$owner" "${home}/.config" 2>/dev/null || true
}

#===============================================================================
# XRDP
#===============================================================================

install_xrdp() {
  [[ "$INSTALL_XRDP" == "true" ]] || { log_skip "xrdp disabled"; return 0; }
  log_step "XRDP"
  FAILED_STEP="xrdp"
  apt_install xrdp

  # xrdp runs as its own user and must read the host key material.
  if getent group ssl-cert >/dev/null 2>&1; then
    usermod -aG ssl-cert xrdp 2>/dev/null || true
  fi

  # --- session for every real user, plus root -------------------------------
  local homes=()
  while IFS=: read -r user _ uid _ _ home shell; do
    [[ "$uid" -ge 1000 && "$uid" -lt 65534 && "$shell" != */nologin && "$shell" != */false ]] || continue
    [[ -d "$home" ]] && homes+=("${user}:${home}")
  done < /etc/passwd
  [[ -d /root ]] && homes+=("root:/root")

  for entry in "${homes[@]}"; do
    local u="${entry%%:*}" h="${entry#*:}"
    if [[ ! -f "${h}/.xsession" ]]; then
      echo 'xfce4-session' > "${h}/.xsession"
      chown "${u}:$(id -gn "$u" 2>/dev/null || echo "$u")" "${h}/.xsession"
      chmod 644 "${h}/.xsession"
      log_ok "wrote ${h}/.xsession"
    else
      log_skip "${h}/.xsession exists (not overwriting a user's own choice)"
    fi
    [[ "$INSTALL_XFCE" == "true" ]] && disable_compositing_for "$h" "$u"
  done

  # --- xrdp.ini: tuned for WAN ----------------------------------------------
  local ini=/etc/xrdp/xrdp.ini
  if [[ -f "$ini" ]]; then
    backup_file "$ini"
    set_ini() {
      local k="$1" v="$2"
      if grep -qE "^[#;[:space:]]*${k}=" "$ini"; then
        sed -i -E "s|^[#;[:space:]]*${k}=.*|${k}=${v}|" "$ini"
      else
        sed -i "0,/^\[Globals\]/s//[Globals]\n${k}=${v}/" "$ini"
      fi
    }
    # 16bpp roughly halves the pixel payload; on a remote desktop over the
    # internet the bottleneck is bandwidth and encode time, not colour depth.
    set_ini max_bpp 16
    set_ini bitmap_cache true
    set_ini bitmap_compression true
    set_ini bulk_compression true
    set_ini tcp_nodelay true
    set_ini tcp_keepalive true
    log_ok "xrdp.ini tuned for WAN (max_bpp=16, caching + compression on)"
  fi

  # --- sesman.ini: the fix for "works sometimes" ----------------------------
  # Policy=Default reconnects a user only if bpp AND screen geometry match, so
  # a differently-sized client silently creates a SECOND session. The first
  # session's D-Bus and ssh-agent are already registered, the new session's
  # window manager refuses to start, and sesman tears it down about a second
  # after a correct password. It reads exactly like an auth failure.
  local sesman=/etc/xrdp/sesman.ini
  if [[ -f "$sesman" ]]; then
    backup_file "$sesman"
    set_sesman() {
      local k="$1" v="$2"
      if grep -qE "^[#;[:space:]]*${k}=" "$sesman"; then
        sed -i -E "s|^[#;[:space:]]*${k}=.*|${k}=${v}|" "$sesman"
      else
        sed -i "0,/^\[Sessions\]/s//[Sessions]\n${k}=${v}/" "$sesman"
      fi
    }
    set_sesman Policy UB                      # reconnect by User+Bpp, ignore geometry
    set_sesman KillDisconnected true          # bound how long a dead session lingers
    set_sesman DisconnectedTimeLimit 86400    # a day: reconnect tomorrow still works
    set_sesman IdleTimeLimit 0                # idle is not broken; never kill on idle
    log_ok "sesman.ini: Policy=UB, disconnected sessions reaped after 24h"
  fi

  svc_enable_now xrdp.service
  svc_enable_now xrdp-sesman.service
  systemctl restart xrdp >>"$LOG_FILE" 2>&1 || true
  sleep 1
  port_listening 3389 && log_ok "xrdp listening on 3389" || log_warn "xrdp NOT listening on 3389"
  FAILED_STEP=""
}

#===============================================================================
# FIREWALL
#===============================================================================

configure_iptables() {
  [[ "$ENABLE_IPTABLES" == "true" ]] || { log_skip "iptables disabled"; return 0; }
  log_step "iptables"
  FAILED_STEP="iptables"
  command -v iptables >/dev/null 2>&1 || apt_install iptables

  add_rule() {
    local port="$1"
    # -C tests for an identical rule; this is what makes reruns idempotent
    # instead of appending a duplicate every single time.
    if iptables -C INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null; then
      log_skip "rule exists: tcp/${port}"
    else
      iptables -A INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
      log_ok "allowed tcp/${port}"
    fi
  }
  [[ "$ALLOW_PORT_22" == "true" ]]   && add_rule 22
  [[ "$ALLOW_PORT_3389" == "true" ]] && add_rule 3389
  [[ "$ALLOW_PORT_443" == "true" ]]  && add_rule 443

  # Preseed so iptables-persistent does not prompt.
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
  apt_install iptables-persistent

  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
  log_ok "rules saved to /etc/iptables/rules.v4"
  FAILED_STEP=""
}

configure_ufw() {
  [[ "$ENABLE_UFW_RULES" == "true" ]] || { log_skip "ufw rules disabled"; return 0; }
  log_step "UFW"
  if ! command -v ufw >/dev/null 2>&1; then log_skip "ufw not installed"; return 0; fi
  if ! ufw status 2>/dev/null | grep -q "Status: active"; then
    # Never enable UFW unprompted: with no allow rule in place yet, enabling a
    # default-deny firewall over SSH disconnects you permanently.
    log_skip "UFW inactive — not enabling it (that would drop your SSH session)"
    return 0
  fi
  [[ "$ALLOW_PORT_22" == "true" ]]   && { ufw allow 22/tcp   >>"$LOG_FILE" 2>&1; log_ok "ufw allow 22/tcp"; }
  [[ "$ALLOW_PORT_3389" == "true" ]] && { ufw allow 3389/tcp >>"$LOG_FILE" 2>&1; log_ok "ufw allow 3389/tcp"; }
  [[ "$ALLOW_PORT_443" == "true" ]]  && { ufw allow 443/tcp  >>"$LOG_FILE" 2>&1; log_ok "ufw allow 443/tcp"; }

  if [[ "$INSTALL_DOCKER" == "true" ]]; then
    log_warn "UFW does NOT protect published Docker ports."
    log_warn "Docker writes into the DOCKER chain, evaluated BEFORE UFW's."
    log_warn "A '-p 9090:9090' container is internet-reachable while UFW reports it blocked."
    log_warn "Use 'expose:' or bind 127.0.0.1, or filter in the DOCKER-USER chain."
  fi
}

#===============================================================================
# SECURITY EXTRAS
#===============================================================================

install_security() {
  log_step "Security services"
  FAILED_STEP="security services"

  if [[ "$INSTALL_FAIL2BAN" == "true" ]]; then
    apt_install fail2ban
    # A local jail file; fail2ban's own jail.conf is replaced on upgrade.
    if [[ ! -f /etc/fail2ban/jail.local ]]; then
      cat > /etc/fail2ban/jail.local <<'EOF'
# Managed by bootstrap-ubuntu.sh. jail.conf is replaced on package upgrade —
# local overrides belong here.
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
# Never lock yourself out of your own admin path.
ignoreip = 127.0.0.1/8 ::1 100.64.0.0/10

[sshd]
enabled = true
EOF
      log_ok "wrote /etc/fail2ban/jail.local (tailnet in ignoreip)"
    else
      log_skip "jail.local exists"
    fi
    svc_enable_now fail2ban.service
  fi

  if [[ "$INSTALL_UNATTENDED_UPGRADES" == "true" ]]; then
    apt_install unattended-upgrades
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    # Security updates only, and no automatic reboot. An unattended reboot of a
    # workstation you are logged into is its own kind of outage.
    if [[ ! -f /etc/apt/apt.conf.d/51-bootstrap-unattended ]]; then
      cat > /etc/apt/apt.conf.d/51-bootstrap-unattended <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
    fi
    svc_enable_now unattended-upgrades.service
    log_ok "automatic security updates enabled (no auto-reboot)"
  fi

  if [[ "$INSTALL_QEMU_AGENT" == "true" ]]; then
    apt_install qemu-guest-agent
    svc_enable_now qemu-guest-agent.service
  fi
  FAILED_STEP=""
}

#===============================================================================
# VALIDATION
#===============================================================================

VALIDATION_FAILURES=0

validate() {
  log_step "Validation"
  local unit
  for unit in ssh docker containerd xrdp xrdp-sesman fail2ban qemu-guest-agent tailscaled; do
    systemctl list-unit-files | grep -q "^${unit}.service" || continue
    if systemctl is-active --quiet "${unit}.service"; then
      log_ok "active: ${unit}"
    else
      log_warn "NOT active: ${unit}"; VALIDATION_FAILURES=$((VALIDATION_FAILURES+1))
    fi
  done

  if [[ "$INSTALL_DOCKER" == "true" ]]; then
    if docker version >/dev/null 2>&1; then log_ok "docker responds"
    else log_warn "docker not responding"; VALIDATION_FAILURES=$((VALIDATION_FAILURES+1)); fi
  fi

  port_listening 22 && log_ok "listening: 22 (ssh)" \
    || { log_error "NOT listening: 22 — do not close your session"; VALIDATION_FAILURES=$((VALIDATION_FAILURES+1)); }

  if [[ "$INSTALL_XRDP" == "true" ]]; then
    port_listening 3389 && log_ok "listening: 3389 (xrdp)" \
      || { log_warn "NOT listening: 3389"; VALIDATION_FAILURES=$((VALIDATION_FAILURES+1)); }
  fi

  sshd -t 2>/dev/null && log_ok "sshd config valid" \
    || { log_error "sshd config INVALID"; VALIDATION_FAILURES=$((VALIDATION_FAILURES+1)); }
}

#===============================================================================
# SUMMARY
#===============================================================================

state_of() {
  systemctl list-unit-files | grep -q "^${1}.service" || { echo "not installed"; return; }
  systemctl is-active --quiet "${1}.service" && echo "active" || echo "inactive"
}

summary() {
  local ip4 ts_ip fw
  ip4="$(hostname -I 2>/dev/null | awk '{print $1}')"
  ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    fw="ufw active"
  elif [[ "$ENABLE_IPTABLES" == "true" ]]; then
    fw="iptables ($(iptables -S INPUT 2>/dev/null | grep -c ACCEPT) accept rules)"
  else
    fw="none configured"
  fi

  printf '\n%s=================================%s\n' "$C_BOLD$C_GRN" "$C_RESET"
  printf '%s      BOOTSTRAP COMPLETE%s\n'            "$C_BOLD$C_GRN" "$C_RESET"
  printf '%s=================================%s\n\n' "$C_BOLD$C_GRN" "$C_RESET"

  printf '  %-22s %s\n' "Hostname"     "$(hostname -f 2>/dev/null || hostname)"
  printf '  %-22s %s\n' "IP Address"   "${ip4:-unknown}"
  printf '  %-22s %s\n' "OS / Arch"    "Ubuntu ${OS_VER} (${CODENAME}) / ${ARCH}"
  printf '  %-22s %s\n' "User"         "${USERNAME}"
  echo
  printf '  %-22s %s\n' "Docker"       "$(state_of docker)"
  printf '  %-22s %s\n' "Containerd"   "$(state_of containerd)"
  printf '  %-22s %s\n' "Tailscale"    "$(state_of tailscaled)${ts_ip:+ (${ts_ip})}"
  printf '  %-22s %s\n' "XRDP"         "$(state_of xrdp)"
  printf '  %-22s %s\n' "XFCE"         "$([[ "$INSTALL_XFCE" == true ]] && command -v xfce4-session >/dev/null && echo installed || echo "not installed")"
  printf '  %-22s %s\n' "Fail2ban"     "$(state_of fail2ban)"
  printf '  %-22s %s\n' "SSH"          "$(state_of ssh)"
  printf '  %-22s %s\n' "Firewall"     "$fw"
  printf '  %-22s %s\n' "Unattended upgrades" "$(state_of unattended-upgrades)"

  if [[ ${#SKIPPED_PACKAGES[@]} -gt 0 ]]; then
    echo
    printf '  %sUnavailable on this release:%s %s\n' "$C_YEL" "$C_RESET" "${SKIPPED_PACKAGES[*]}"
  fi

  if [[ $VALIDATION_FAILURES -gt 0 ]]; then
    printf '\n  %s%d validation warning(s) — see %s%s\n' "$C_YEL" "$VALIDATION_FAILURES" "$LOG_FILE" "$C_RESET"
  fi

  printf '\n%s--- NEXT STEPS ---%s\n\n' "$C_BOLD" "$C_RESET"
  local n=1
  if [[ "$INSTALL_TAILSCALE" == "true" ]] && ! tailscale status >/dev/null 2>&1; then
    printf '  %d. Join the tailnet (not done automatically):\n       %ssudo tailscale up%s\n' "$n" "$C_BOLD" "$C_RESET"; n=$((n+1))
  fi
  if [[ "$INSTALL_DOCKER" == "true" ]]; then
    printf '  %d. Pick up docker group membership without logging out:\n       %snewgrp docker%s\n' "$n" "$C_BOLD" "$C_RESET"; n=$((n+1))
  fi
  printf '  %d. Add your SSH public key:\n       %s/home/%s/.ssh/authorized_keys%s\n' "$n" "$C_BOLD" "$USERNAME" "$C_RESET"; n=$((n+1))
  if [[ "$PASSWORD" == "ChangeMe123!" ]]; then
    printf '  %d. %sCHANGE THE DEFAULT PASSWORD%s for %s — it is the one in this script.\n' "$n" "$C_RED" "$C_RESET" "$USERNAME"; n=$((n+1))
  fi
  printf '  %d. Verify login in a NEW session before closing this one.\n' "$n"; n=$((n+1))
  if [[ "$INSTALL_XRDP" == "true" ]]; then
    printf '  %d. RDP to %s:3389 as %s (reach it over Tailscale, not the public IP).\n' "$n" "${ts_ip:-<tailscale-ip>}" "$USERNAME"; n=$((n+1))
  fi
  printf '\n  Log: %s\n  Backups: %s\n\n' "$LOG_FILE" "$BACKUP_DIR"

  if [[ "$AUTO_REBOOT" == "true" ]]; then
    log_warn "AUTO_REBOOT=true — rebooting in 10s (Ctrl-C to cancel)"
    sleep 10
    systemctl reboot
  else
    printf '  No reboot performed. Reboot when convenient to apply kernel updates.\n\n'
  fi
}

#===============================================================================
# MAIN
#===============================================================================

main() {
  preflight
  system_update
  install_utilities
  create_user
  install_docker        # before ssh: creates the docker group create_user wants
  install_tailscale
  install_xfce
  install_xrdp
  install_security
  configure_iptables
  configure_ufw
  configure_ssh         # LAST mutating step: if it breaks, everything else is done
  validate
  summary
}

main "$@"
