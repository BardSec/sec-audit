#!/usr/bin/env bash
# create-vm — Create a fully provisioned Ubuntu 24.04 VM on ESXi from your Mac
# https://github.com/BardSec/sec-audit
#
# Usage:
#   ./create-vm.sh --name my-server
#   ./create-vm.sh --name my-server --cpu 4 --memory 8192 --disk 100
#   ./create-vm.sh --name my-server --dry-run
#
# Prerequisites:
#   - govc (brew install govc)
#   - SSH key pair (~/.ssh/id_ed25519.pub)
#   - ESXi credentials in create-vm.conf or environment
#
# Configuration: copy create-vm.conf.example to create-vm.conf and edit.

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/create-vm.conf"
OVA_CACHE_DIR="${HOME}/.cache/sec-audit"
UBUNTU_OVA_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.ova"
UBUNTU_OVA_FILE="noble-server-cloudimg-amd64.ova"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# Defaults (overridden by create-vm.conf)
# =============================================================================

# ESXi connection
ESXI_HOST=""
ESXI_USER="root"
ESXI_PASSWORD=""
ESXI_INSECURE=true              # Skip TLS verification (common for ESXi 6.7)

# VM placement
ESXI_DATASTORE=""               # e.g., "datastore1"
ESXI_NETWORK=""                 # e.g., "VM Network"
ESXI_RESOURCE_POOL=""           # Leave empty for default

# VM defaults
VM_CPU=2
VM_MEMORY=4096                  # MB
VM_DISK=50                      # GB
VM_NAME=""

# Ubuntu user
VM_USER="andylombardo"
VM_SSH_PUBKEY=""                # Defaults to ~/.ssh/id_ed25519.pub

# Post-provision
RUN_SERVER_INIT=true
RUN_SEC_AUDIT=true
SEC_AUDIT_REPO="https://github.com/BardSec/sec-audit.git"
DOTFILES_REPO="git@github.com:BardSec/dotfiles.git"

# Tailscale auth key (optional — avoids manual 'tailscale up')
# Create at: https://login.tailscale.com/admin/settings/keys
TAILSCALE_AUTH_KEY=""

# =============================================================================
# Load config
# =============================================================================

if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

# Default SSH key
if [[ -z "$VM_SSH_PUBKEY" ]]; then
    for keyfile in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
        if [[ -f "$keyfile" ]]; then
            VM_SSH_PUBKEY=$(cat "$keyfile")
            break
        fi
    done
fi

# =============================================================================
# Helpers
# =============================================================================

usage() {
    cat <<EOF
create-vm v${VERSION} — Create a fully provisioned Ubuntu 24.04 VM on ESXi

Usage:
  $0 --name <vm-name> [options]

Options:
  --name NAME        VM name (required, also used as hostname)
  --cpu N            Number of CPUs (default: ${VM_CPU})
  --memory N         Memory in MB (default: ${VM_MEMORY})
  --disk N           Disk size in GB (default: ${VM_DISK})
  --dry-run          Show what would happen without creating anything
  --config FILE      Use a custom config file
  --help             Show this help message
  --version          Print version and exit

Config:
  Place a create-vm.conf file next to this script or use --config.
  See create-vm.conf.example for all available options.

Workflow:
  1. Downloads Ubuntu 24.04 cloud image OVA (cached locally)
  2. Deploys OVA to ESXi with cloud-init user data
  3. Boots the VM and waits for SSH access
  4. Clones sec-audit repo and runs server-init.sh + sec-audit.sh --harden
  5. Optionally joins your Tailscale network
EOF
}

info() { echo -e "  ${BLUE}[INFO]${NC} $1"; }
ok() { echo -e "  ${GREEN}[OK]${NC} $1"; }
err() { echo -e "  ${RED}[ERROR]${NC} $1"; }
dry() { echo -e "  ${YELLOW}[DRY-RUN]${NC} Would: $1"; }

section() {
    echo ""
    echo -e "${BOLD}── $1 ──${NC}"
}

# =============================================================================
# Validation
# =============================================================================

validate() {
    local errors=0

    if [[ -z "$VM_NAME" ]]; then
        err "--name is required"
        errors=$((errors + 1))
    fi

    if [[ -z "$ESXI_HOST" ]]; then
        err "ESXI_HOST is not set — configure in create-vm.conf"
        errors=$((errors + 1))
    fi

    if [[ -z "$ESXI_PASSWORD" ]]; then
        err "ESXI_PASSWORD is not set — configure in create-vm.conf"
        errors=$((errors + 1))
    fi

    if [[ -z "$ESXI_DATASTORE" ]]; then
        err "ESXI_DATASTORE is not set — configure in create-vm.conf"
        errors=$((errors + 1))
    fi

    if [[ -z "$ESXI_NETWORK" ]]; then
        err "ESXI_NETWORK is not set — configure in create-vm.conf"
        errors=$((errors + 1))
    fi

    if [[ -z "$VM_SSH_PUBKEY" ]]; then
        err "No SSH public key found — set VM_SSH_PUBKEY or create ~/.ssh/id_ed25519"
        errors=$((errors + 1))
    fi

    if ! command -v govc &> /dev/null; then
        err "govc is not installed — run: brew install govc"
        errors=$((errors + 1))
    fi

    if [[ "$errors" -gt 0 ]]; then
        echo ""
        err "Fix the above errors and try again"
        exit 1
    fi
}

# =============================================================================
# Steps
# =============================================================================

setup_govc_env() {
    export GOVC_URL="https://${ESXI_HOST}"
    export GOVC_USERNAME="${ESXI_USER}"
    export GOVC_PASSWORD="${ESXI_PASSWORD}"
    export GOVC_INSECURE="${ESXI_INSECURE}"
    if [[ -n "$ESXI_DATASTORE" ]]; then
        export GOVC_DATASTORE="${ESXI_DATASTORE}"
    fi
    if [[ -n "$ESXI_RESOURCE_POOL" ]]; then
        export GOVC_RESOURCE_POOL="${ESXI_RESOURCE_POOL}"
    fi
}

download_ova() {
    section "Ubuntu Cloud Image"

    mkdir -p "$OVA_CACHE_DIR"
    local ova_path="${OVA_CACHE_DIR}/${UBUNTU_OVA_FILE}"

    if [[ -f "$ova_path" ]]; then
        already "$ova_path"
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        dry "Download Ubuntu 24.04 cloud image to ${ova_path}"
        return
    fi

    info "Downloading Ubuntu 24.04 cloud image..."
    info "URL: ${UBUNTU_OVA_URL}"
    curl -fSL -o "$ova_path" "$UBUNTU_OVA_URL"
    ok "Downloaded to ${ova_path}"
}

already() {
    echo -e "  ${GREEN}[CACHED]${NC} $1"
}

generate_cloud_init() {
    # Generate cloud-init user-data
    local tailscale_cmds=""
    if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
        tailscale_cmds="
  - curl -fsSL https://tailscale.com/install.sh | sh
  - tailscale up --authkey=${TAILSCALE_AUTH_KEY} --hostname=${VM_NAME}"
    fi

    cat <<CLOUDINIT
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true

users:
  - name: ${VM_USER}
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${VM_SSH_PUBKEY}

package_update: true
packages:
  - git
  - curl
  - openssh-server

runcmd:
  - systemctl enable ssh
  - systemctl start ssh${tailscale_cmds}
  - |
    su - ${VM_USER} -c '
      git clone ${SEC_AUDIT_REPO} ~/sec-audit 2>/dev/null || true
      if [ -f ~/sec-audit/server-init.sh ]; then
        echo "cloud-init: sec-audit repo cloned"
      fi
    '

power_state:
  mode: reboot
  condition: true
CLOUDINIT
}

deploy_vm() {
    section "Deploy VM"

    local ova_path="${OVA_CACHE_DIR}/${UBUNTU_OVA_FILE}"

    # Check if VM already exists
    if govc vm.info "$VM_NAME" > /dev/null 2>&1; then
        err "VM '${VM_NAME}' already exists on ${ESXI_HOST}"
        err "Delete it first: govc vm.destroy ${VM_NAME}"
        exit 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        dry "Deploy OVA as '${VM_NAME}' (${VM_CPU} CPU, ${VM_MEMORY}MB RAM, ${VM_DISK}GB disk)"
        dry "Network: ${ESXI_NETWORK}, Datastore: ${ESXI_DATASTORE}"
        return
    fi

    info "Deploying OVA as '${VM_NAME}'..."

    # Deploy the OVA
    govc import.ova \
        -name "$VM_NAME" \
        -ds "$ESXI_DATASTORE" \
        -net "$ESXI_NETWORK" \
        "$ova_path"

    ok "OVA deployed"

    # Resize CPU and memory
    info "Configuring VM: ${VM_CPU} CPU, ${VM_MEMORY}MB RAM..."
    govc vm.change -vm "$VM_NAME" \
        -c "$VM_CPU" \
        -m "$VM_MEMORY"

    # Resize disk
    info "Resizing disk to ${VM_DISK}GB..."
    govc vm.disk.change -vm "$VM_NAME" \
        -size "${VM_DISK}G" 2>/dev/null || true

    # Inject cloud-init via guestinfo
    info "Injecting cloud-init configuration..."
    local userdata
    userdata=$(generate_cloud_init | base64)

    local metadata
    metadata=$(cat <<METADATA | base64
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
METADATA
    )

    govc vm.change -vm "$VM_NAME" \
        -e "guestinfo.metadata=${metadata}" \
        -e "guestinfo.metadata.encoding=base64" \
        -e "guestinfo.userdata=${userdata}" \
        -e "guestinfo.userdata.encoding=base64"

    ok "VM configured"

    # Power on
    info "Powering on '${VM_NAME}'..."
    govc vm.power -on "$VM_NAME"
    ok "VM powered on"
}

wait_for_ssh() {
    section "Wait for SSH"

    if [[ "$DRY_RUN" == true ]]; then
        dry "Wait for VM to boot and SSH to become available"
        return
    fi

    info "Waiting for VM to get an IP address..."
    local vm_ip=""
    local attempts=0
    local max_attempts=60  # 5 minutes

    while [[ -z "$vm_ip" || "$vm_ip" == "<nil>" ]] && [[ $attempts -lt $max_attempts ]]; do
        vm_ip=$(govc vm.ip "$VM_NAME" 2>/dev/null || true)
        attempts=$((attempts + 1))
        if [[ -z "$vm_ip" || "$vm_ip" == "<nil>" ]]; then
            sleep 5
        fi
    done

    if [[ -z "$vm_ip" || "$vm_ip" == "<nil>" ]]; then
        err "Timed out waiting for IP address"
        err "Check the VM console in the ESXi UI"
        exit 1
    fi

    ok "VM IP: ${vm_ip}"

    info "Waiting for SSH to become available..."
    attempts=0
    max_attempts=60

    while ! ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes \
        "${VM_USER}@${vm_ip}" "echo ready" > /dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge $max_attempts ]]; then
            err "Timed out waiting for SSH"
            err "VM is running at ${vm_ip} — try manually: ssh ${VM_USER}@${vm_ip}"
            exit 1
        fi
        sleep 5
    done

    ok "SSH is ready"

    # Export for post-provision steps
    VM_IP="$vm_ip"
}

post_provision() {
    section "Post-Provision"

    if [[ "$DRY_RUN" == true ]]; then
        dry "SSH to VM, clone repos, run server-init.sh and sec-audit.sh --harden"
        return
    fi

    local ssh_cmd="ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_IP}"

    # Clone sec-audit if not already there (cloud-init may have done it)
    info "Setting up sec-audit..."
    $ssh_cmd "cd ~ && [ -d sec-audit ] || git clone ${SEC_AUDIT_REPO} sec-audit" 2>/dev/null

    # Copy server-init.conf if we have one locally
    local local_conf="${SCRIPT_DIR}/server-init.conf"
    if [[ -f "$local_conf" ]]; then
        info "Copying server-init.conf to VM..."
        scp -o StrictHostKeyChecking=no "$local_conf" "${VM_USER}@${VM_IP}:~/sec-audit/server-init.conf" 2>/dev/null
        ok "Config copied"
    fi

    # Run server-init
    if [[ "$RUN_SERVER_INIT" == true ]]; then
        info "Running server-init.sh (this may take a few minutes)..."
        $ssh_cmd "cd ~/sec-audit && sudo ./server-init.sh" 2>/dev/null
        ok "server-init.sh complete"
    fi

    # Run sec-audit --harden
    if [[ "$RUN_SEC_AUDIT" == true ]]; then
        info "Running sec-audit.sh --harden..."
        $ssh_cmd "cd ~/sec-audit && sudo ./sec-audit.sh --harden" 2>/dev/null
        ok "sec-audit.sh --harden complete"
    fi
}

print_summary() {
    section "Complete"

    if [[ "$DRY_RUN" == true ]]; then
        info "Dry run complete — no changes made"
        return
    fi

    echo ""
    echo -e "  ${GREEN}VM '${VM_NAME}' is ready!${NC}"
    echo ""
    echo -e "  ${BOLD}SSH:${NC}        ssh ${VM_USER}@${VM_IP}"
    if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
        echo -e "  ${BOLD}Tailscale:${NC}  ssh ${VM_USER}@${VM_NAME}"
    fi
    echo -e "  ${BOLD}ESXi:${NC}       ${ESXI_HOST}"
    echo -e "  ${BOLD}Specs:${NC}      ${VM_CPU} CPU / ${VM_MEMORY}MB RAM / ${VM_DISK}GB disk"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

DRY_RUN=false
VM_IP=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                VM_NAME="$2"
                shift 2
                ;;
            --cpu)
                VM_CPU="$2"
                shift 2
                ;;
            --memory)
                VM_MEMORY="$2"
                shift 2
                ;;
            --disk)
                VM_DISK="$2"
                shift 2
                ;;
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
                echo "create-vm v${VERSION}"
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

    echo ""
    echo -e "${BOLD}create-vm v${VERSION}${NC}"
    if [[ -n "$VM_NAME" ]]; then
        echo -e "VM: ${BOLD}${VM_NAME}${NC} (${VM_CPU} CPU / ${VM_MEMORY}MB / ${VM_DISK}GB)"
    fi
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "Mode: ${YELLOW}dry-run${NC}"
    fi

    validate

    setup_govc_env
    download_ova
    deploy_vm
    wait_for_ssh
    post_provision
    print_summary
}

main "$@"
