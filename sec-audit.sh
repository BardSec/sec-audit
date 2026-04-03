#!/usr/bin/env bash
# sec-audit — Harden or audit Ubuntu 24.04 LTS servers
# https://github.com/BardSec/sec-audit
#
# Usage:
#   sudo ./sec-audit.sh --audit          # Check current state, change nothing
#   sudo ./sec-audit.sh --harden         # Apply all hardening baselines
#   sudo ./sec-audit.sh --harden --dry-run  # Show what would change
#
# Configuration: copy sec-audit.conf.example to sec-audit.conf and edit as needed.
# The script works with sensible defaults if no config file is present.

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/sec-audit.conf"
LOG_FILE="/var/log/sec-audit.log"
REPORT_FILE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Counters
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0
CHANGED_COUNT=0

# =============================================================================
# Defaults (overridden by sec-audit.conf)
# =============================================================================

# SSH
SSH_PORT=22
PERMIT_ROOT_LOGIN="no"
PASSWORD_AUTH="no"
SSH_MAX_AUTH_TRIES=3
SSH_LOGIN_GRACE_TIME=30
SSH_IDLE_TIMEOUT=300
SSH_IDLE_COUNT_MAX=3

# Firewall
UFW_ENABLED=true
ALLOWED_PORTS=()  # Additional ports beyond SSH; Tailscale is handled separately
ALLOWED_PORTS_TCP=()
ALLOWED_PORTS_UDP=()

# Tailscale
TAILSCALE_ENABLED=true

# fail2ban
FAIL2BAN_ENABLED=true
FAIL2BAN_MAXRETRY=5
FAIL2BAN_BANTIME=3600
FAIL2BAN_FINDTIME=600

# Unattended upgrades
UNATTENDED_UPGRADES=true

# Kernel hardening
KERNEL_HARDENING=true

# Audit logging
AUDITD_ENABLED=true

# Users
DISABLE_ROOT_ACCOUNT=true

# =============================================================================
# Load config
# =============================================================================

if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

# =============================================================================
# Helpers
# =============================================================================

usage() {
    cat <<EOF
sec-audit v${VERSION} — Ubuntu 24.04 LTS server hardening and audit tool

Usage:
  sudo $0 --audit                Check current state (read-only)
  sudo $0 --harden              Apply security baselines
  sudo $0 --harden --dry-run    Show what would change without applying
  sudo $0 --version             Print version

Options:
  --audit           Run all checks in read-only mode
  --harden          Apply hardening configuration
  --dry-run         Preview changes without applying (requires --harden)
  --report FILE     Write results to a file (in addition to stdout)
  --config FILE     Use a custom config file
  --help            Show this help message
  --version         Print version and exit

Config:
  Place a sec-audit.conf file next to this script or use --config.
  See sec-audit.conf.example for all available options.
EOF
}

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

pass() {
    local msg="$1"
    echo -e "  ${GREEN}[PASS]${NC} $msg"
    PASS_COUNT=$((PASS_COUNT + 1))
    log "PASS: $msg"
    [[ -n "$REPORT_FILE" ]] && echo "[PASS] $msg" >> "$REPORT_FILE"
}

fail() {
    local msg="$1"
    echo -e "  ${RED}[FAIL]${NC} $msg"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "FAIL: $msg"
    [[ -n "$REPORT_FILE" ]] && echo "[FAIL] $msg" >> "$REPORT_FILE"
}

warn() {
    local msg="$1"
    echo -e "  ${YELLOW}[WARN]${NC} $msg"
    WARN_COUNT=$((WARN_COUNT + 1))
    log "WARN: $msg"
    [[ -n "$REPORT_FILE" ]] && echo "[WARN] $msg" >> "$REPORT_FILE"
}

skip() {
    local msg="$1"
    echo -e "  ${BLUE}[SKIP]${NC} $msg"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    log "SKIP: $msg"
    [[ -n "$REPORT_FILE" ]] && echo "[SKIP] $msg" >> "$REPORT_FILE"
}

changed() {
    local msg="$1"
    echo -e "  ${GREEN}[FIXED]${NC} $msg"
    CHANGED_COUNT=$((CHANGED_COUNT + 1))
    log "FIXED: $msg"
    [[ -n "$REPORT_FILE" ]] && echo "[FIXED] $msg" >> "$REPORT_FILE"
}

dry() {
    local msg="$1"
    echo -e "  ${YELLOW}[DRY-RUN]${NC} Would: $msg"
    log "DRY-RUN: $msg"
    [[ -n "$REPORT_FILE" ]] && echo "[DRY-RUN] Would: $msg" >> "$REPORT_FILE"
}

section() {
    echo ""
    echo -e "${BOLD}── $1 ──${NC}"
    log "=== $1 ==="
    [[ -n "$REPORT_FILE" ]] && echo "" >> "$REPORT_FILE" && echo "── $1 ──" >> "$REPORT_FILE"
}

# Check if a config directive exists in a file
config_value() {
    local file="$1" key="$2"
    grep -Ei "^\s*${key}\s" "$file" 2>/dev/null | tail -1 | awk '{print $2}'
}

# Set a config directive in a file (append or replace)
set_config() {
    local file="$1" key="$2" value="$3"
    if grep -qEi "^\s*#?\s*${key}\s" "$file" 2>/dev/null; then
        sed -i "s/^\s*#\?\s*${key}\s.*/${key} ${value}/" "$file"
    else
        echo "${key} ${value}" >> "$file"
    fi
}

# =============================================================================
# Checks — each function works in both audit and harden mode
# =============================================================================

check_os() {
    section "Operating System"

    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        if [[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]]; then
            pass "Ubuntu 24.04 LTS detected"
        else
            warn "Expected Ubuntu 24.04, found ${PRETTY_NAME:-unknown} — checks may not apply cleanly"
        fi
    else
        warn "Cannot determine OS — /etc/os-release not found"
    fi

    # Check if system is up to date
    if [[ "$MODE" == "harden" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            dry "Run apt update && apt upgrade -y"
        else
            echo -e "  ${BLUE}[INFO]${NC} Updating package lists..."
            timeout 60 apt-get update -qq > /dev/null 2>&1 || true
            local upgradable
            upgradable=$( (timeout 30 apt list --upgradable 2>/dev/null || true) | grep -c upgradable || echo 0)
            if [[ "$upgradable" -gt 0 ]]; then
                echo -e "  ${BLUE}[INFO]${NC} Upgrading ${upgradable} packages..."
                DEBIAN_FRONTEND=noninteractive timeout 300 apt-get upgrade -y -qq > /dev/null 2>&1
                changed "System packages upgraded (${upgradable} packages)"
            else
                pass "System packages are up to date"
            fi
        fi
    else
        local upgradable
        timeout 60 apt-get update -qq > /dev/null 2>&1 || true
        upgradable=$(timeout 30 apt list --upgradable 2>/dev/null | grep -c upgradable || true)
        if [[ "$upgradable" -gt 0 ]]; then
            fail "System has ${upgradable} upgradable packages"
        else
            pass "System packages are up to date"
        fi
    fi
}

check_root_account() {
    section "Root Account"

    if [[ "$DISABLE_ROOT_ACCOUNT" != true ]]; then
        skip "Root account hardening disabled in config"
        return
    fi

    # Check if root account is locked
    local root_status
    root_status=$(passwd -S root 2>/dev/null | awk '{print $2}')

    if [[ "$root_status" == "L" ]]; then
        pass "Root account is locked"
    else
        if [[ "$MODE" == "harden" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "Lock root account (passwd -l root)"
            else
                passwd -l root > /dev/null 2>&1
                changed "Root account locked"
            fi
        else
            fail "Root account is not locked (status: ${root_status})"
        fi
    fi
}

check_ssh() {
    section "SSH Configuration"

    local sshd_config="/etc/ssh/sshd_config"
    local sshd_dir="/etc/ssh/sshd_config.d"
    local needs_restart=false

    if [[ ! -f "$sshd_config" ]]; then
        fail "sshd_config not found — is OpenSSH installed?"
        return
    fi

    # Helper: get effective SSH config value (checks config.d overrides too)
    get_ssh_value() {
        local key="$1"
        local val=""
        # Check sshd_config.d files first (they override)
        if [[ -d "$sshd_dir" ]]; then
            val=$(grep -rhi "^\s*${key}\s" "$sshd_dir"/ 2>/dev/null | tail -1 | awk '{print tolower($2)}')
        fi
        if [[ -z "$val" ]]; then
            val=$(grep -hi "^\s*${key}\s" "$sshd_config" 2>/dev/null | tail -1 | awk '{print tolower($2)}')
        fi
        echo "$val"
    }

    # We write hardening overrides to a drop-in file for clean management
    local hardening_file="${sshd_dir}/99-sec-audit.conf"

    declare -A ssh_checks=(
        ["PermitRootLogin"]="$PERMIT_ROOT_LOGIN"
        ["PasswordAuthentication"]="$PASSWORD_AUTH"
        ["PermitEmptyPasswords"]="no"
        ["MaxAuthTries"]="$SSH_MAX_AUTH_TRIES"
        ["LoginGraceTime"]="$SSH_LOGIN_GRACE_TIME"
        ["ClientAliveInterval"]="$SSH_IDLE_TIMEOUT"
        ["ClientAliveCountMax"]="$SSH_IDLE_COUNT_MAX"
        ["X11Forwarding"]="no"
        ["Protocol"]="2"
    )

    # In harden mode, build the drop-in file
    local harden_lines=()

    for key in "${!ssh_checks[@]}"; do
        local expected="${ssh_checks[$key]}"
        local actual
        actual=$(get_ssh_value "$key")

        if [[ "${actual,,}" == "${expected,,}" ]]; then
            pass "SSH ${key} = ${expected}"
        else
            if [[ "$MODE" == "harden" ]]; then
                if [[ "$DRY_RUN" == true ]]; then
                    dry "Set SSH ${key} = ${expected} (currently: ${actual:-default})"
                else
                    harden_lines+=("${key} ${expected}")
                    needs_restart=true
                fi
            else
                fail "SSH ${key} = ${actual:-default} (expected: ${expected})"
            fi
        fi
    done

    # Check SSH port
    local current_port
    current_port=$(get_ssh_value "Port")
    current_port="${current_port:-22}"
    if [[ "$current_port" == "$SSH_PORT" ]]; then
        pass "SSH port = ${SSH_PORT}"
    else
        if [[ "$MODE" == "harden" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "Set SSH Port = ${SSH_PORT} (currently: ${current_port})"
            else
                harden_lines+=("Port ${SSH_PORT}")
                needs_restart=true
            fi
        else
            fail "SSH port = ${current_port} (expected: ${SSH_PORT})"
        fi
    fi

    # Write drop-in file if we have changes
    if [[ "$MODE" == "harden" && "$DRY_RUN" != true && ${#harden_lines[@]} -gt 0 ]]; then
        mkdir -p "$sshd_dir"
        printf "# Managed by sec-audit — do not edit manually\n" > "$hardening_file"
        for line in "${harden_lines[@]}"; do
            echo "$line" >> "$hardening_file"
        done
        changed "SSH hardening written to ${hardening_file}"
    fi

    # Restart SSH if needed
    if [[ "$needs_restart" == true && "$MODE" == "harden" && "$DRY_RUN" != true ]]; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        changed "SSH service restarted"
    fi
}

check_firewall() {
    section "Firewall (UFW)"

    if [[ "$UFW_ENABLED" != true ]]; then
        skip "UFW hardening disabled in config"
        return
    fi

    # Install UFW if missing
    if ! command -v ufw &> /dev/null; then
        if [[ "$MODE" == "harden" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "Install UFW"
            else
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw > /dev/null 2>&1
                changed "UFW installed"
            fi
        else
            fail "UFW is not installed"
            return
        fi
    fi

    # Check UFW status
    local ufw_status
    ufw_status=$(ufw status 2>/dev/null | head -1)

    if [[ "$ufw_status" == *"active"* ]]; then
        pass "UFW is active"
    else
        if [[ "$MODE" == "harden" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "Enable UFW with default deny incoming"
            else
                ufw default deny incoming > /dev/null 2>&1
                ufw default allow outgoing > /dev/null 2>&1
                ufw --force enable > /dev/null 2>&1
                changed "UFW enabled (default deny incoming, allow outgoing)"
            fi
        else
            fail "UFW is not active"
        fi
    fi

    # Ensure SSH port is allowed (so we don't lock ourselves out)
    if [[ "$MODE" == "harden" && "$DRY_RUN" != true ]]; then
        ufw allow "${SSH_PORT}/tcp" comment "SSH" > /dev/null 2>&1
        pass "UFW allows SSH on port ${SSH_PORT}"
    else
        if ufw status | grep -q "${SSH_PORT}/tcp.*ALLOW"; then
            pass "UFW allows SSH on port ${SSH_PORT}"
        else
            if [[ "$MODE" == "audit" ]]; then
                fail "UFW does not explicitly allow SSH on port ${SSH_PORT}"
            else
                dry "Allow SSH on port ${SSH_PORT}/tcp"
            fi
        fi
    fi

    # Additional allowed TCP ports
    for port in "${ALLOWED_PORTS_TCP[@]}"; do
        if [[ "$MODE" == "harden" && "$DRY_RUN" != true ]]; then
            ufw allow "${port}/tcp" > /dev/null 2>&1
            pass "UFW allows TCP port ${port}"
        fi
    done

    # Additional allowed UDP ports
    for port in "${ALLOWED_PORTS_UDP[@]}"; do
        if [[ "$MODE" == "harden" && "$DRY_RUN" != true ]]; then
            ufw allow "${port}/udp" > /dev/null 2>&1
            pass "UFW allows UDP port ${port}"
        fi
    done

    # Additional allowed ports (both protocols)
    for port in "${ALLOWED_PORTS[@]}"; do
        if [[ "$MODE" == "harden" && "$DRY_RUN" != true ]]; then
            ufw allow "${port}" > /dev/null 2>&1
            pass "UFW allows port ${port}"
        fi
    done

    # Check default incoming policy
    local default_incoming
    default_incoming=$(ufw status verbose 2>/dev/null | grep "Default:" | grep -o "deny (incoming)\|reject (incoming)" || true)
    if [[ -n "$default_incoming" ]]; then
        pass "UFW default incoming policy: deny/reject"
    else
        if [[ "$MODE" == "audit" ]]; then
            fail "UFW default incoming policy is not deny/reject"
        fi
    fi
}

check_tailscale() {
    section "Tailscale"

    if [[ "$TAILSCALE_ENABLED" != true ]]; then
        skip "Tailscale check disabled in config"
        return
    fi

    if command -v tailscale &> /dev/null; then
        pass "Tailscale is installed"

        local ts_status
        ts_status=$(tailscale status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4 || true)

        if [[ "$ts_status" == "Running" ]]; then
            pass "Tailscale is running"
            local ts_ip
            ts_ip=$(tailscale ip -4 2>/dev/null || true)
            if [[ -n "$ts_ip" ]]; then
                pass "Tailscale IPv4: ${ts_ip}"
            fi
        else
            warn "Tailscale is installed but not running (status: ${ts_status:-unknown})"
        fi
    else
        if [[ "$MODE" == "harden" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "Install Tailscale via official install script"
            else
                echo -e "  ${BLUE}[INFO]${NC} Installing Tailscale..."
                curl -fsSL https://tailscale.com/install.sh | sh > /dev/null 2>&1
                changed "Tailscale installed — run 'sudo tailscale up' to authenticate"
            fi
        else
            fail "Tailscale is not installed"
        fi
    fi
}

check_fail2ban() {
    section "fail2ban"

    if [[ "$FAIL2BAN_ENABLED" != true ]]; then
        skip "fail2ban hardening disabled in config"
        return
    fi

    # Install if missing
    if ! command -v fail2ban-client &> /dev/null; then
        if [[ "$MODE" == "harden" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "Install fail2ban"
            else
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban > /dev/null 2>&1
                changed "fail2ban installed"
            fi
        else
            fail "fail2ban is not installed"
            return
        fi
    else
        pass "fail2ban is installed"
    fi

    # Check if running
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        pass "fail2ban service is running"
    else
        if [[ "$MODE" == "harden" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "Enable and start fail2ban"
            else
                systemctl enable fail2ban > /dev/null 2>&1
                systemctl start fail2ban > /dev/null 2>&1
                changed "fail2ban enabled and started"
            fi
        else
            fail "fail2ban is not running"
        fi
    fi

    # Configure jail.local for SSH
    local jail_file="/etc/fail2ban/jail.local"
    local jail_expected="[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = ${FAIL2BAN_MAXRETRY}
bantime = ${FAIL2BAN_BANTIME}
findtime = ${FAIL2BAN_FINDTIME}"

    if [[ -f "$jail_file" ]] && grep -q "\[sshd\]" "$jail_file"; then
        local current_maxretry
        current_maxretry=$(grep -A5 "\[sshd\]" "$jail_file" | grep "maxretry" | awk '{print $3}')
        if [[ "$current_maxretry" == "$FAIL2BAN_MAXRETRY" ]]; then
            pass "fail2ban SSH jail configured (maxretry=${FAIL2BAN_MAXRETRY})"
        else
            if [[ "$MODE" == "harden" ]]; then
                if [[ "$DRY_RUN" == true ]]; then
                    dry "Update fail2ban SSH jail config"
                else
                    echo "$jail_expected" > "$jail_file"
                    systemctl restart fail2ban > /dev/null 2>&1
                    changed "fail2ban SSH jail updated"
                fi
            else
                fail "fail2ban SSH maxretry=${current_maxretry:-unset} (expected: ${FAIL2BAN_MAXRETRY})"
            fi
        fi
    else
        if [[ "$MODE" == "harden" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "Create fail2ban SSH jail config"
            else
                echo "$jail_expected" > "$jail_file"
                systemctl restart fail2ban > /dev/null 2>&1 || true
                changed "fail2ban SSH jail created"
            fi
        else
            fail "fail2ban SSH jail not configured"
        fi
    fi
}

check_unattended_upgrades() {
    section "Unattended Upgrades"

    if [[ "$UNATTENDED_UPGRADES" != true ]]; then
        skip "Unattended upgrades disabled in config"
        return
    fi

    if dpkg -l | grep -q unattended-upgrades 2>/dev/null; then
        pass "unattended-upgrades package installed"
    else
        if [[ "$MODE" == "harden" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "Install unattended-upgrades"
            else
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades > /dev/null 2>&1
                changed "unattended-upgrades installed"
            fi
        else
            fail "unattended-upgrades not installed"
        fi
    fi

    # Check if auto-update is enabled
    local auto_update="/etc/apt/apt.conf.d/20auto-upgrades"
    if [[ -f "$auto_update" ]] && grep -q 'APT::Periodic::Unattended-Upgrade "1"' "$auto_update"; then
        pass "Automatic security updates enabled"
    else
        if [[ "$MODE" == "harden" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "Enable automatic security updates"
            else
                cat > "$auto_update" <<APTEOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APTEOF
                changed "Automatic security updates enabled"
            fi
        else
            fail "Automatic security updates not configured"
        fi
    fi
}

check_file_permissions() {
    section "File Permissions"

    declare -A perm_checks=(
        ["/etc/passwd"]="644"
        ["/etc/shadow"]="640"
        ["/etc/group"]="644"
        ["/etc/gshadow"]="640"
        ["/etc/ssh/sshd_config"]="600"
    )

    for file in "${!perm_checks[@]}"; do
        local expected="${perm_checks[$file]}"
        if [[ ! -f "$file" ]]; then
            skip "${file} does not exist"
            continue
        fi

        local actual
        actual=$(stat -c "%a" "$file" 2>/dev/null)

        if [[ "$actual" == "$expected" ]]; then
            pass "${file} permissions: ${actual}"
        else
            if [[ "$MODE" == "harden" ]]; then
                if [[ "$DRY_RUN" == true ]]; then
                    dry "Set ${file} permissions to ${expected} (currently: ${actual})"
                else
                    chmod "$expected" "$file"
                    changed "${file} permissions set to ${expected} (was: ${actual})"
                fi
            else
                fail "${file} permissions: ${actual} (expected: ${expected})"
            fi
        fi
    done

    # Check for world-writable files in common directories
    local ww_count
    ww_count=$(find /etc /usr -xdev -type f -perm -0002 2>/dev/null | wc -l)
    if [[ "$ww_count" -eq 0 ]]; then
        pass "No world-writable files in /etc or /usr"
    else
        warn "Found ${ww_count} world-writable files in /etc or /usr"
    fi
}

check_kernel_hardening() {
    section "Kernel Hardening (sysctl)"

    if [[ "$KERNEL_HARDENING" != true ]]; then
        skip "Kernel hardening disabled in config"
        return
    fi

    declare -A sysctl_checks=(
        ["net.ipv4.ip_forward"]="0"
        ["net.ipv4.conf.all.send_redirects"]="0"
        ["net.ipv4.conf.default.send_redirects"]="0"
        ["net.ipv4.conf.all.accept_redirects"]="0"
        ["net.ipv4.conf.default.accept_redirects"]="0"
        ["net.ipv4.conf.all.accept_source_route"]="0"
        ["net.ipv4.conf.default.accept_source_route"]="0"
        ["net.ipv4.tcp_syncookies"]="1"
        ["net.ipv4.conf.all.log_martians"]="1"
        ["net.ipv4.conf.default.log_martians"]="1"
        ["net.ipv4.icmp_echo_ignore_broadcasts"]="1"
        ["net.ipv4.icmp_ignore_bogus_error_responses"]="1"
        ["net.ipv4.conf.all.rp_filter"]="1"
        ["net.ipv4.conf.default.rp_filter"]="1"
        ["net.ipv6.conf.all.accept_redirects"]="0"
        ["net.ipv6.conf.default.accept_redirects"]="0"
        ["kernel.randomize_va_space"]="2"
    )

    # Note: Tailscale requires ip_forward=1 — adjust if Tailscale is enabled
    if [[ "$TAILSCALE_ENABLED" == true ]]; then
        sysctl_checks["net.ipv4.ip_forward"]="1"
        sysctl_checks["net.ipv6.conf.all.forwarding"]="1"
    fi

    local sysctl_file="/etc/sysctl.d/99-sec-audit.conf"
    local sysctl_changes=()

    for key in $(echo "${!sysctl_checks[@]}" | tr ' ' '\n' | sort); do
        local expected="${sysctl_checks[$key]}"
        local actual
        actual=$(sysctl -n "$key" 2>/dev/null || echo "unknown")

        if [[ "$actual" == "$expected" ]]; then
            pass "sysctl ${key} = ${expected}"
        else
            if [[ "$MODE" == "harden" ]]; then
                if [[ "$DRY_RUN" == true ]]; then
                    dry "Set sysctl ${key} = ${expected} (currently: ${actual})"
                else
                    sysctl_changes+=("${key} = ${expected}")
                fi
            else
                fail "sysctl ${key} = ${actual} (expected: ${expected})"
            fi
        fi
    done

    if [[ "$MODE" == "harden" && "$DRY_RUN" != true && ${#sysctl_changes[@]} -gt 0 ]]; then
        printf "# Managed by sec-audit — do not edit manually\n" > "$sysctl_file"
        for line in "${sysctl_changes[@]}"; do
            echo "$line" >> "$sysctl_file"
        done
        sysctl --system > /dev/null 2>&1
        changed "Kernel parameters hardened via ${sysctl_file}"
    fi
}

check_auditd() {
    section "Audit Logging (auditd)"

    if [[ "$AUDITD_ENABLED" != true ]]; then
        skip "auditd disabled in config"
        return
    fi

    if dpkg -l | grep -q auditd 2>/dev/null; then
        pass "auditd is installed"
    else
        if [[ "$MODE" == "harden" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "Install auditd"
            else
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq auditd audispd-plugins > /dev/null 2>&1
                changed "auditd installed"
            fi
        else
            fail "auditd is not installed"
            return
        fi
    fi

    if systemctl is-active --quiet auditd 2>/dev/null; then
        pass "auditd service is running"
    else
        if [[ "$MODE" == "harden" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "Enable and start auditd"
            else
                systemctl enable auditd > /dev/null 2>&1
                systemctl start auditd > /dev/null 2>&1
                changed "auditd enabled and started"
            fi
        else
            fail "auditd is not running"
        fi
    fi
}

check_misc() {
    section "Additional Checks"

    # Check for unnecessary services
    local unnecessary_services=("avahi-daemon" "cups" "rpcbind")
    for svc in "${unnecessary_services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            if [[ "$MODE" == "harden" ]]; then
                if [[ "$DRY_RUN" == true ]]; then
                    dry "Disable unnecessary service: ${svc}"
                else
                    systemctl stop "$svc" > /dev/null 2>&1
                    systemctl disable "$svc" > /dev/null 2>&1
                    changed "Disabled unnecessary service: ${svc}"
                fi
            else
                warn "Unnecessary service running: ${svc}"
            fi
        else
            pass "Service ${svc} is not running"
        fi
    done

    # Check login banner
    if [[ -f /etc/issue.net ]] && [[ -s /etc/issue.net ]]; then
        local banner_content
        banner_content=$(cat /etc/issue.net)
        # Check it's not just the default Ubuntu banner
        if echo "$banner_content" | grep -qi "authorized\|warning\|notice\|consent"; then
            pass "Login banner is set (/etc/issue.net)"
        else
            if [[ "$MODE" == "harden" ]]; then
                if [[ "$DRY_RUN" == true ]]; then
                    dry "Set authorized-use-only login banner"
                else
                    cat > /etc/issue.net <<'BANNER'
*******************************************************************
*  WARNING: This system is for authorized use only.               *
*  Unauthorized access is prohibited and may be subject to        *
*  criminal and civil penalties. All activity is monitored.       *
*******************************************************************
BANNER
                    changed "Login banner set in /etc/issue.net"
                fi
            else
                fail "Login banner does not contain authorization warning"
            fi
        fi
    else
        if [[ "$MODE" == "harden" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "Create login banner at /etc/issue.net"
            else
                cat > /etc/issue.net <<'BANNER'
*******************************************************************
*  WARNING: This system is for authorized use only.               *
*  Unauthorized access is prohibited and may be subject to        *
*  criminal and civil penalties. All activity is monitored.       *
*******************************************************************
BANNER
                changed "Login banner created at /etc/issue.net"
            fi
        else
            fail "No login banner at /etc/issue.net"
        fi
    fi

    # Ensure SSH uses the banner
    local ssh_banner
    ssh_banner=$(grep -ri "^\s*Banner" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | tail -1 | awk '{print $2}')
    if [[ "$ssh_banner" == "/etc/issue.net" ]]; then
        pass "SSH Banner configured to /etc/issue.net"
    else
        if [[ "$MODE" == "harden" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                dry "Set SSH Banner to /etc/issue.net"
            else
                local hardening_file="/etc/ssh/sshd_config.d/99-sec-audit.conf"
                if [[ -f "$hardening_file" ]]; then
                    if ! grep -q "Banner" "$hardening_file"; then
                        echo "Banner /etc/issue.net" >> "$hardening_file"
                    fi
                else
                    echo -e "# Managed by sec-audit — do not edit manually\nBanner /etc/issue.net" > "$hardening_file"
                fi
                systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
                changed "SSH Banner set to /etc/issue.net"
            fi
        else
            fail "SSH Banner not set to /etc/issue.net"
        fi
    fi

    # Check for users with empty passwords
    local empty_pw
    empty_pw=$(awk -F: '($2 == "" ) { print $1 }' /etc/shadow 2>/dev/null || true)
    if [[ -z "$empty_pw" ]]; then
        pass "No users with empty passwords"
    else
        fail "Users with empty passwords: ${empty_pw}"
    fi

    # Check sudo group members
    local sudo_users
    sudo_users=$(getent group sudo 2>/dev/null | cut -d: -f4)
    if [[ -n "$sudo_users" ]]; then
        pass "Sudo users: ${sudo_users}"
    else
        pass "No additional sudo users (root only)"
    fi
}

# =============================================================================
# Main
# =============================================================================

MODE=""
DRY_RUN=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --audit)
                MODE="audit"
                shift
                ;;
            --harden)
                MODE="harden"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --report)
                REPORT_FILE="$2"
                shift 2
                ;;
            --config)
                CONF_FILE="$2"
                if [[ -f "$CONF_FILE" ]]; then
                    # shellcheck source=/dev/null
                    source "$CONF_FILE"
                else
                    echo "Error: config file not found: $CONF_FILE"
                    exit 1
                fi
                shift 2
                ;;
            --version)
                echo "sec-audit v${VERSION}"
                exit 0
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [[ -z "$MODE" ]]; then
        echo "Error: specify --audit or --harden"
        usage
        exit 1
    fi

    if [[ "$DRY_RUN" == true && "$MODE" != "harden" ]]; then
        echo "Error: --dry-run requires --harden"
        exit 1
    fi
}

main() {
    parse_args "$@"

    # Must run as root
    if [[ $EUID -ne 0 ]]; then
        echo "Error: this script must be run as root (use sudo)"
        exit 1
    fi

    echo ""
    echo -e "${BOLD}sec-audit v${VERSION}${NC}"
    echo -e "Mode: ${BOLD}${MODE}${NC}$(if [[ "$DRY_RUN" == true ]]; then echo " (dry-run)"; fi)"
    echo -e "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "Host: $(hostname)"

    if [[ -n "$REPORT_FILE" ]]; then
        echo "sec-audit v${VERSION} — ${MODE} report" > "$REPORT_FILE"
        echo "Date: $(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
        echo "Host: $(hostname)" >> "$REPORT_FILE"
    fi

    log "sec-audit ${MODE} started"

    # Run all checks
    check_os
    check_root_account
    check_ssh
    check_firewall
    check_fail2ban
    check_tailscale
    check_unattended_upgrades
    check_file_permissions
    check_kernel_hardening
    check_auditd
    check_misc

    # Summary
    echo ""
    echo -e "${BOLD}── Summary ──${NC}"
    echo -e "  ${GREEN}PASS: ${PASS_COUNT}${NC}"
    echo -e "  ${RED}FAIL: ${FAIL_COUNT}${NC}"
    echo -e "  ${YELLOW}WARN: ${WARN_COUNT}${NC}"
    echo -e "  ${BLUE}SKIP: ${SKIP_COUNT}${NC}"
    if [[ "$MODE" == "harden" ]]; then
        echo -e "  ${GREEN}FIXED: ${CHANGED_COUNT}${NC}"
    fi
    echo ""

    if [[ -n "$REPORT_FILE" ]]; then
        echo "" >> "$REPORT_FILE"
        echo "── Summary ──" >> "$REPORT_FILE"
        echo "PASS: ${PASS_COUNT}" >> "$REPORT_FILE"
        echo "FAIL: ${FAIL_COUNT}" >> "$REPORT_FILE"
        echo "WARN: ${WARN_COUNT}" >> "$REPORT_FILE"
        echo "SKIP: ${SKIP_COUNT}" >> "$REPORT_FILE"
        [[ "$MODE" == "harden" ]] && echo "FIXED: ${CHANGED_COUNT}" >> "$REPORT_FILE"
        echo -e "  Report saved to: ${REPORT_FILE}"
    fi

    log "sec-audit ${MODE} complete — pass:${PASS_COUNT} fail:${FAIL_COUNT} warn:${WARN_COUNT}"

    # Exit code: 0 if no failures, 1 if any
    if [[ "$FAIL_COUNT" -gt 0 && "$MODE" == "audit" ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
