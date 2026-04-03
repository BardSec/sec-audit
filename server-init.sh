#!/usr/bin/env bash
# server-init — Provision a fresh Ubuntu 24.04 LTS server with standard tooling
# https://github.com/BardSec/sec-audit
#
# Usage:
#   sudo ./server-init.sh                 # Install everything
#   sudo ./server-init.sh --dry-run       # Preview what would be installed
#
# Run this BEFORE sec-audit.sh --harden.
# Configuration: copy server-init.conf.example to server-init.conf and edit.

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/server-init.conf"
LOG_FILE="/var/log/server-init.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Counters
INSTALLED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

# =============================================================================
# Defaults (overridden by server-init.conf)
# =============================================================================

# Docker
INSTALL_DOCKER=true

# Tailscale
INSTALL_TAILSCALE=true

# GitHub CLI
INSTALL_GH=true

# Cloudflare Tunnel
INSTALL_CLOUDFLARED=true
CLOUDFLARED_TOKEN=""             # Tunnel token from Cloudflare dashboard (enables service setup)
CLOUDFLARE_API_TOKEN=""          # API token for auto-creating tunnels (overrides CLOUDFLARED_TOKEN)
CLOUDFLARE_ACCOUNT_ID=""         # Cloudflare account ID (required with API token)
CLOUDFLARE_TUNNEL_NAME=""        # Tunnel name (defaults to hostname if empty)

# Git config
GIT_USER_NAME=""
GIT_USER_EMAIL=""

# User setup
SETUP_USER=""                    # Username to configure (e.g., "andylombardo")
ADD_TO_DOCKER_GROUP=true
SETUP_NOPASSWD_SUDO=false       # Add NOPASSWD sudo for the user
SSH_AUTHORIZED_KEY=""            # Public key to add to authorized_keys

# Baseline packages
BASELINE_PACKAGES=(
    curl
    wget
    git
    htop
    unzip
    jq
    tree
    net-tools
    software-properties-common
    apt-transport-https
    ca-certificates
    gnupg
    lsb-release
)

# Extra packages (add your own in config)
EXTRA_PACKAGES=()

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
server-init v${VERSION} — Ubuntu 24.04 LTS server provisioning tool

Usage:
  sudo $0                  Install and configure all components
  sudo $0 --dry-run        Preview what would be installed
  sudo $0 --config FILE    Use a custom config file
  sudo $0 --help           Show this help message
  sudo $0 --version        Print version and exit

Config:
  Place a server-init.conf file next to this script or use --config.
  See server-init.conf.example for all available options.

Recommended workflow:
  1. sudo ./server-init.sh          # Provision the server
  2. sudo ./sec-audit.sh --harden   # Apply security baselines
EOF
}

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

info() {
    echo -e "  ${BLUE}[INFO]${NC} $1"
    log "INFO: $1"
}

ok() {
    local msg="$1"
    echo -e "  ${GREEN}[OK]${NC} $msg"
    INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
    log "OK: $msg"
}

already() {
    local msg="$1"
    echo -e "  ${GREEN}[ALREADY]${NC} $msg"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    log "ALREADY: $msg"
}

dry() {
    local msg="$1"
    echo -e "  ${YELLOW}[DRY-RUN]${NC} Would: $msg"
    log "DRY-RUN: $msg"
}

err() {
    local msg="$1"
    echo -e "  ${RED}[ERROR]${NC} $msg"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    log "ERROR: $msg"
}

section() {
    echo ""
    echo -e "${BOLD}── $1 ──${NC}"
    log "=== $1 ==="
}

# =============================================================================
# Install functions
# =============================================================================

install_baseline_packages() {
    section "Baseline Packages"

    local all_packages=("${BASELINE_PACKAGES[@]}" "${EXTRA_PACKAGES[@]}")
    local to_install=()

    for pkg in "${all_packages[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            already "${pkg} is installed"
        else
            to_install+=("$pkg")
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        for pkg in "${to_install[@]}"; do
            dry "Install ${pkg}"
        done
        return
    fi

    info "Installing ${#to_install[@]} packages..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${to_install[@]}" > /dev/null 2>&1
    for pkg in "${to_install[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            ok "${pkg} installed"
        else
            err "Failed to install ${pkg}"
        fi
    done
}

install_docker() {
    section "Docker"

    if [[ "$INSTALL_DOCKER" != true ]]; then
        info "Docker installation disabled in config"
        return
    fi

    if command -v docker &> /dev/null; then
        local docker_version
        docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
        already "Docker is installed (${docker_version})"

        # Check for Docker Compose plugin
        if docker compose version &> /dev/null; then
            local compose_version
            compose_version=$(docker compose version --short 2>/dev/null)
            already "Docker Compose plugin is installed (${compose_version})"
        else
            if [[ "$DRY_RUN" == true ]]; then
                dry "Install Docker Compose plugin"
            else
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin > /dev/null 2>&1
                ok "Docker Compose plugin installed"
            fi
        fi
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        dry "Install Docker Engine + Compose plugin via official repo"
        return
    fi

    info "Adding Docker GPG key and repository..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list

    apt-get update -qq > /dev/null 2>&1

    info "Installing Docker Engine..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1

    systemctl enable docker > /dev/null 2>&1
    systemctl start docker > /dev/null 2>&1

    if command -v docker &> /dev/null; then
        ok "Docker Engine installed"
        ok "Docker Compose plugin installed"
    else
        err "Docker installation failed"
    fi
}

install_tailscale() {
    section "Tailscale"

    if [[ "$INSTALL_TAILSCALE" != true ]]; then
        info "Tailscale installation disabled in config"
        return
    fi

    if command -v tailscale &> /dev/null; then
        local ts_version
        ts_version=$(tailscale version 2>/dev/null | head -1)
        already "Tailscale is installed (${ts_version})"
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        dry "Install Tailscale via official install script"
        return
    fi

    info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh > /dev/null 2>&1

    if command -v tailscale &> /dev/null; then
        systemctl enable tailscaled > /dev/null 2>&1
        systemctl start tailscaled > /dev/null 2>&1
        ok "Tailscale installed — run 'sudo tailscale up' to authenticate"
    else
        err "Tailscale installation failed"
    fi
}

install_gh() {
    section "GitHub CLI"

    if [[ "$INSTALL_GH" != true ]]; then
        info "GitHub CLI installation disabled in config"
        return
    fi

    if command -v gh &> /dev/null; then
        local gh_version
        gh_version=$(gh --version 2>/dev/null | head -1 | awk '{print $3}')
        already "GitHub CLI is installed (${gh_version})"
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        dry "Install GitHub CLI via official repo"
        return
    fi

    info "Adding GitHub CLI repository..."
    (type -p wget >/dev/null || (apt-get update -qq && apt-get install -y -qq wget > /dev/null 2>&1)) \
        && mkdir -p -m 755 /etc/apt/keyrings \
        && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
        && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null

    apt-get update -qq > /dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh > /dev/null 2>&1

    if command -v gh &> /dev/null; then
        ok "GitHub CLI installed"
    else
        err "GitHub CLI installation failed"
    fi
}

install_cloudflared() {
    section "Cloudflare Tunnel"

    if [[ "$INSTALL_CLOUDFLARED" != true ]]; then
        info "Cloudflare Tunnel installation disabled in config"
        return
    fi

    # Install cloudflared if missing
    if command -v cloudflared &> /dev/null; then
        local cf_version
        cf_version=$(cloudflared --version 2>/dev/null | awk '{print $3}')
        already "cloudflared is installed (${cf_version})"
    else
        if [[ "$DRY_RUN" == true ]]; then
            dry "Install cloudflared via official repo"
        else
            info "Adding Cloudflare repository..."
            mkdir -p -m 755 /etc/apt/keyrings
            curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /etc/apt/keyrings/cloudflare-main.gpg

            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
                > /etc/apt/sources.list.d/cloudflared.list

            apt-get update -qq > /dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cloudflared > /dev/null 2>&1

            if command -v cloudflared &> /dev/null; then
                ok "cloudflared installed"
            else
                err "cloudflared installation failed"
                return
            fi
        fi
    fi

    # If already running, nothing to do
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        already "cloudflared tunnel service is running"
        return
    fi

    # Option 1: Auto-create tunnel via Cloudflare API
    if [[ -n "$CLOUDFLARE_API_TOKEN" && -n "$CLOUDFLARE_ACCOUNT_ID" ]]; then
        _cloudflared_setup_via_api
        return
    fi

    # Option 2: Use a pre-existing tunnel token from the dashboard
    if [[ -n "$CLOUDFLARED_TOKEN" ]]; then
        _cloudflared_setup_via_token "$CLOUDFLARED_TOKEN"
        return
    fi

    info "No tunnel credentials configured — skipping service setup"
    info "Option A: Set CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID to auto-create tunnels"
    info "Option B: Set CLOUDFLARED_TOKEN from the Cloudflare dashboard"
}

_cloudflared_setup_via_api() {
    local tunnel_name="${CLOUDFLARE_TUNNEL_NAME:-$(hostname)}"
    local api_base="https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}"

    if [[ "$DRY_RUN" == true ]]; then
        dry "Create Cloudflare tunnel '${tunnel_name}' via API and install as service"
        return
    fi

    info "Checking for existing tunnel '${tunnel_name}'..."

    # List tunnels and look for one with our name that isn't deleted
    local existing
    existing=$(curl -sf \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "${api_base}/cfd_tunnel?name=${tunnel_name}&is_deleted=false" 2>/dev/null || true)

    local tunnel_id=""
    local tunnel_token=""

    if echo "$existing" | jq -e '.result[0].id' > /dev/null 2>&1; then
        tunnel_id=$(echo "$existing" | jq -r '.result[0].id')
        info "Found existing tunnel '${tunnel_name}' (${tunnel_id})"
    else
        # Create a new tunnel
        info "Creating tunnel '${tunnel_name}'..."
        local tunnel_secret
        tunnel_secret=$(openssl rand -base64 32)

        local create_response
        create_response=$(curl -sf \
            -X POST \
            -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"${tunnel_name}\", \"tunnel_secret\": \"${tunnel_secret}\"}" \
            "${api_base}/cfd_tunnel" 2>/dev/null || true)

        if echo "$create_response" | jq -e '.success' | grep -q 'true' 2>/dev/null; then
            tunnel_id=$(echo "$create_response" | jq -r '.result.id')
            ok "Tunnel '${tunnel_name}' created (${tunnel_id})"
        else
            local error_msg
            error_msg=$(echo "$create_response" | jq -r '.errors[0].message // "unknown error"' 2>/dev/null || echo "unknown error")
            err "Failed to create tunnel: ${error_msg}"
            return
        fi
    fi

    # Get the tunnel token
    info "Fetching tunnel token..."
    local token_response
    token_response=$(curl -sf \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "${api_base}/cfd_tunnel/${tunnel_id}/token" 2>/dev/null || true)

    if echo "$token_response" | jq -e '.success' | grep -q 'true' 2>/dev/null; then
        tunnel_token=$(echo "$token_response" | jq -r '.result')
    else
        err "Failed to fetch tunnel token — you may need to set it manually"
        return
    fi

    # Install the service with the token
    _cloudflared_setup_via_token "$tunnel_token"
}

_cloudflared_setup_via_token() {
    local token="$1"

    if [[ "$DRY_RUN" == true ]]; then
        dry "Install cloudflared as systemd service with tunnel token"
        return
    fi

    cloudflared service install "$token" > /dev/null 2>&1

    # Give it a moment to start
    sleep 2

    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        ok "cloudflared tunnel service installed and running"
    else
        systemctl start cloudflared > /dev/null 2>&1 || true
        sleep 2
        if systemctl is-active --quiet cloudflared 2>/dev/null; then
            ok "cloudflared tunnel service installed and running"
        else
            err "cloudflared service installed but failed to start — check 'systemctl status cloudflared'"
        fi
    fi
}

configure_git() {
    section "Git Configuration"

    if [[ -z "$GIT_USER_NAME" && -z "$GIT_USER_EMAIL" ]]; then
        info "No git user config specified — skipping"
        return
    fi

    # Apply git config system-wide
    if [[ -n "$GIT_USER_NAME" ]]; then
        local current_name
        current_name=$(git config --global user.name 2>/dev/null || true)
        if [[ "$current_name" == "$GIT_USER_NAME" ]]; then
            already "Git user.name = ${GIT_USER_NAME}"
        else
            if [[ "$DRY_RUN" == true ]]; then
                dry "Set git user.name = ${GIT_USER_NAME}"
            else
                # Set for the target user, not root
                if [[ -n "$SETUP_USER" ]]; then
                    su - "$SETUP_USER" -c "git config --global user.name '${GIT_USER_NAME}'" 2>/dev/null || true
                fi
                ok "Git user.name = ${GIT_USER_NAME}"
            fi
        fi
    fi

    if [[ -n "$GIT_USER_EMAIL" ]]; then
        local current_email
        current_email=$(git config --global user.email 2>/dev/null || true)
        if [[ "$current_email" == "$GIT_USER_EMAIL" ]]; then
            already "Git user.email = ${GIT_USER_EMAIL}"
        else
            if [[ "$DRY_RUN" == true ]]; then
                dry "Set git user.email = ${GIT_USER_EMAIL}"
            else
                if [[ -n "$SETUP_USER" ]]; then
                    su - "$SETUP_USER" -c "git config --global user.email '${GIT_USER_EMAIL}'" 2>/dev/null || true
                fi
                ok "Git user.email = ${GIT_USER_EMAIL}"
            fi
        fi
    fi
}

setup_user() {
    section "User Setup"

    if [[ -z "$SETUP_USER" ]]; then
        info "No user specified — skipping"
        return
    fi

    if ! id "$SETUP_USER" &> /dev/null; then
        info "User ${SETUP_USER} does not exist — skipping"
        return
    fi

    # Add to docker group
    if [[ "$ADD_TO_DOCKER_GROUP" == true && "$INSTALL_DOCKER" == true ]]; then
        if groups "$SETUP_USER" 2>/dev/null | grep -q docker; then
            already "${SETUP_USER} is in docker group"
        else
            if [[ "$DRY_RUN" == true ]]; then
                dry "Add ${SETUP_USER} to docker group"
            else
                usermod -aG docker "$SETUP_USER" 2>/dev/null || true
                ok "${SETUP_USER} added to docker group (re-login to take effect)"
            fi
        fi
    fi

    # NOPASSWD sudo
    if [[ "$SETUP_NOPASSWD_SUDO" == true ]]; then
        local sudoers_file="/etc/sudoers.d/${SETUP_USER}"
        if [[ -f "$sudoers_file" ]] && grep -q "NOPASSWD" "$sudoers_file" 2>/dev/null; then
            already "${SETUP_USER} has NOPASSWD sudo"
        else
            if [[ "$DRY_RUN" == true ]]; then
                dry "Grant ${SETUP_USER} NOPASSWD sudo"
            else
                echo "${SETUP_USER} ALL=(ALL) NOPASSWD: ALL" > "$sudoers_file"
                chmod 440 "$sudoers_file"
                ok "${SETUP_USER} granted NOPASSWD sudo"
            fi
        fi
    fi

    # SSH authorized key
    if [[ -n "$SSH_AUTHORIZED_KEY" ]]; then
        local user_home
        user_home=$(eval echo "~${SETUP_USER}")
        local auth_file="${user_home}/.ssh/authorized_keys"

        if [[ -f "$auth_file" ]] && grep -qF "$SSH_AUTHORIZED_KEY" "$auth_file" 2>/dev/null; then
            already "SSH authorized key is present"
        else
            if [[ "$DRY_RUN" == true ]]; then
                dry "Add SSH authorized key for ${SETUP_USER}"
            else
                mkdir -p "${user_home}/.ssh"
                echo "$SSH_AUTHORIZED_KEY" >> "$auth_file"
                chmod 700 "${user_home}/.ssh"
                chmod 600 "$auth_file"
                chown -R "${SETUP_USER}:${SETUP_USER}" "${user_home}/.ssh"
                ok "SSH authorized key added"
            fi
        fi
    fi
}

# =============================================================================
# Main
# =============================================================================

DRY_RUN=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
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
                echo "server-init v${VERSION}"
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
}

main() {
    parse_args "$@"

    # Must run as root
    if [[ $EUID -ne 0 ]]; then
        echo "Error: this script must be run as root (use sudo)"
        exit 1
    fi

    echo ""
    echo -e "${BOLD}server-init v${VERSION}${NC}"
    echo -e "Mode: ${BOLD}provision$(if [[ "$DRY_RUN" == true ]]; then echo " (dry-run)"; fi)${NC}"
    echo -e "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "Host: $(hostname)"

    log "server-init started"

    # Update package lists first
    if [[ "$DRY_RUN" != true ]]; then
        info "Updating package lists..."
        apt-get update -qq > /dev/null 2>&1
    fi

    install_baseline_packages
    install_docker
    install_tailscale
    install_gh
    install_cloudflared
    configure_git
    setup_user

    # Summary
    echo ""
    echo -e "${BOLD}── Summary ──${NC}"
    echo -e "  ${GREEN}INSTALLED: ${INSTALLED_COUNT}${NC}"
    echo -e "  ${GREEN}ALREADY OK: ${SKIPPED_COUNT}${NC}"
    if [[ "$FAILED_COUNT" -gt 0 ]]; then
        echo -e "  ${RED}FAILED: ${FAILED_COUNT}${NC}"
    fi
    echo ""

    if [[ "$DRY_RUN" != true ]]; then
        echo -e "${BOLD}Next steps:${NC}"
        if command -v tailscale &> /dev/null; then
            local ts_status
            ts_status=$(tailscale status --json 2>/dev/null | grep -o '"BackendState":\s*"[^"]*"' | cut -d'"' -f4 || true)
            if [[ "$ts_status" != "Running" ]]; then
                echo "  - Run: sudo tailscale up"
            fi
        fi
        if command -v cloudflared &> /dev/null && ! systemctl is-active --quiet cloudflared 2>/dev/null; then
            echo "  - Set CLOUDFLARED_TOKEN in server-init.conf and rerun, or run manually:"
            echo "    cloudflared service install <token>"
        fi
        echo "  - Run: sudo ./sec-audit.sh --harden"
    fi

    log "server-init complete — installed:${INSTALLED_COUNT} skipped:${SKIPPED_COUNT} failed:${FAILED_COUNT}"

    if [[ "$FAILED_COUNT" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
