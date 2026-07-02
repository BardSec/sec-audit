#!/usr/bin/env bash
# create-vm — Create a fully provisioned Ubuntu 24.04 VM on Proxmox
# https://github.com/BardSec/sec-audit
#
# Usage:
#   ./create-vm.sh --name my-server
#   ./create-vm.sh --name my-server --cpu 4 --memory 8192 --disk 100
#   ./create-vm.sh --name my-server --dry-run
#
# Prerequisites:
#   - Proxmox API access (root or API token)
#   - SSH key pair (~/.ssh/id_ed25519.pub)
#   - curl and python3 on your Mac

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/create-vm.conf"
CACHE_DIR="${HOME}/.cache/sec-audit"
UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
UBUNTU_IMG_NAME="noble-server-cloudimg-amd64.img"

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

# Proxmox connection
PVE_HOST=""                      # e.g., "192.168.1.87" or Tailscale IP
PVE_PORT=8006
PVE_USER="root@pam"
PVE_PASSWORD=""
PVE_NODE=""                      # e.g., "proxmox" — auto-detected if empty

# VM placement
PVE_STORAGE="local-lvm"         # Storage for VM disks
PVE_ISO_STORAGE="local"         # Storage for cloud image download
PVE_BRIDGE="vmbr0"
PVE_VLAN=""                     # VLAN tag (e.g., "40"), empty for untagged

# VM defaults
VM_CPU=2
VM_MEMORY=4096                  # MB
VM_DISK=50                      # GB
VM_NAME=""
VM_ID=""                        # Proxmox VMID — auto-assigned if empty

# Network — static IP or DHCP
VM_IP=""                        # e.g., "192.168.40.10/24" — empty for DHCP
VM_GATEWAY=""                   # e.g., "192.168.40.1"
VM_NAMESERVER=""                # e.g., "192.168.40.1"

# Ubuntu user
VM_USER="andylombardo"
VM_SSH_PUBKEY=""                # Defaults to ~/.ssh/id_ed25519.pub

# Post-provision
RUN_SERVER_INIT=true
RUN_SEC_AUDIT=true
SEC_AUDIT_REPO="https://github.com/BardSec/sec-audit.git"

# Tailscale auth key (optional — avoids manual 'tailscale up')
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
create-vm v${VERSION} — Create a fully provisioned Ubuntu 24.04 VM on Proxmox

Usage:
  $0 --name <vm-name> [options]

Options:
  --name NAME        VM name (required, also used as hostname)
  --id N             Proxmox VM ID (auto-assigned if omitted)
  --cpu N            Number of CPUs (default: ${VM_CPU})
  --memory N         Memory in MB (default: ${VM_MEMORY})
  --disk N           Disk size in GB (default: ${VM_DISK})
  --ip CIDR          Static IP (e.g., 192.168.40.10/24). Omit for DHCP.
  --gateway IP       Gateway IP for static config
  --dry-run          Show what would happen without creating anything
  --config FILE      Use a custom config file
  --help             Show this help message
  --version          Print version and exit

Config:
  Place a create-vm.conf file next to this script or use --config.
  See create-vm.conf.example for all available options.

Workflow:
  1. Downloads Ubuntu 24.04 cloud image to Proxmox storage
  2. Creates VM with cloud-init (user, SSH key, network)
  3. Boots the VM and waits for SSH access
  4. Clones sec-audit repo and runs server-init.sh + sec-audit.sh --harden
  5. Optionally joins your Tailscale network
EOF
}

info() { echo -e "  ${BLUE}[INFO]${NC} $1"; }
ok() { echo -e "  ${GREEN}[OK]${NC} $1"; }
err() { echo -e "  ${RED}[ERROR]${NC} $1"; }
dry() { echo -e "  ${YELLOW}[DRY-RUN]${NC} Would: $1"; }
already() { echo -e "  ${GREEN}[CACHED]${NC} $1"; }

section() {
    echo ""
    echo -e "${BOLD}── $1 ──${NC}"
}

# JSON helper — extract a field from JSON via python3
json_val() {
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null
}

# URL-encode a string via python3
urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read().strip(), safe=''))"
}

# =============================================================================
# Proxmox API
# =============================================================================

PVE_TICKET=""
PVE_CSRF=""

pve_auth() {
    local response
    response=$(curl -sk -d "username=${PVE_USER}" \
        --data-urlencode "password=${PVE_PASSWORD}" \
        "https://${PVE_HOST}:${PVE_PORT}/api2/json/access/ticket" 2>&1)

    PVE_TICKET=$(echo "$response" | json_val "['data']['ticket']")
    PVE_CSRF=$(echo "$response" | json_val "['data']['CSRFPreventionToken']")

    if [[ -z "$PVE_TICKET" ]]; then
        err "Failed to authenticate to Proxmox at ${PVE_HOST}:${PVE_PORT}"
        err "Response: ${response}"
        exit 1
    fi
}

pve_get() {
    curl -sk -b "PVEAuthCookie=${PVE_TICKET}" \
        "https://${PVE_HOST}:${PVE_PORT}/api2/json$1" 2>&1
}

pve_post() {
    local path="$1"
    shift
    curl -sk -b "PVEAuthCookie=${PVE_TICKET}" \
        -H "CSRFPreventionToken: ${PVE_CSRF}" \
        -X POST "$@" \
        "https://${PVE_HOST}:${PVE_PORT}/api2/json${path}" 2>&1
}

pve_put() {
    local path="$1"
    shift
    curl -sk -b "PVEAuthCookie=${PVE_TICKET}" \
        -H "CSRFPreventionToken: ${PVE_CSRF}" \
        -X PUT "$@" \
        "https://${PVE_HOST}:${PVE_PORT}/api2/json${path}" 2>&1
}

pve_delete() {
    local path="$1"
    shift
    curl -sk -b "PVEAuthCookie=${PVE_TICKET}" \
        -H "CSRFPreventionToken: ${PVE_CSRF}" \
        -X DELETE \
        "https://${PVE_HOST}:${PVE_PORT}/api2/json${path}${1:+?$1}" 2>&1
}

pve_wait_task() {
    local upid="$1"
    local encoded
    encoded=$(echo "$upid" | urlencode)

    while true; do
        local body status exitstatus
        body=$(pve_get "/nodes/${PVE_NODE}/tasks/${encoded}/status")
        status=$(echo "$body" | json_val "['data']['status']")
        if [[ "$status" != "running" ]]; then
            # Proxmox task status is only running|stopped; real result is in exitstatus
            exitstatus=$(echo "$body" | json_val "['data']['exitstatus']")
            echo "$exitstatus"
            return
        fi
        sleep 2
    done
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

    if [[ -z "$PVE_HOST" ]]; then
        err "PVE_HOST is not set — configure in create-vm.conf"
        errors=$((errors + 1))
    fi

    if [[ -z "$PVE_PASSWORD" ]]; then
        err "PVE_PASSWORD is not set — configure in create-vm.conf"
        errors=$((errors + 1))
    fi

    if [[ -z "$VM_SSH_PUBKEY" ]]; then
        err "No SSH public key found — set VM_SSH_PUBKEY or create ~/.ssh/id_ed25519"
        errors=$((errors + 1))
    fi

    if [[ -n "$VM_IP" ]] && [[ -z "$VM_GATEWAY" ]]; then
        err "VM_GATEWAY is required when VM_IP is set"
        errors=$((errors + 1))
    fi

    if [[ "$errors" -gt 0 ]]; then
        echo ""
        err "Fix the above errors and try again"
        exit 1
    fi

    # Authenticate
    if [[ "$DRY_RUN" != true ]]; then
        info "Authenticating to Proxmox..."
        pve_auth
        ok "Authenticated as ${PVE_USER}"

        # Auto-detect node name if not set
        if [[ -z "$PVE_NODE" ]]; then
            PVE_NODE=$(pve_get "/nodes" | json_val "['data'][0]['node']")
            info "Auto-detected node: ${PVE_NODE}"
        fi

        # Auto-assign VM ID if not set
        if [[ -z "$VM_ID" ]]; then
            VM_ID=$(pve_get "/cluster/nextid" | json_val "['data']")
            info "Auto-assigned VM ID: ${VM_ID}"
        fi
    fi
}

# =============================================================================
# Steps
# =============================================================================

download_image() {
    section "Ubuntu Cloud Image"

    if [[ "$DRY_RUN" == true ]]; then
        dry "Download ${UBUNTU_IMG_NAME} to Proxmox storage '${PVE_ISO_STORAGE}'"
        return
    fi

    # Check if already downloaded
    local existing
    existing=$(pve_get "/nodes/${PVE_NODE}/storage/${PVE_ISO_STORAGE}/content" | \
        python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
for f in data:
    if '${UBUNTU_IMG_NAME}' in f.get('volid', ''):
        print('yes')
        break
" 2>/dev/null || true)

    if [[ "$existing" == "yes" ]]; then
        already "${UBUNTU_IMG_NAME} on ${PVE_ISO_STORAGE}"
        return
    fi

    info "Downloading ${UBUNTU_IMG_NAME} to Proxmox..."
    local response
    response=$(pve_post "/nodes/${PVE_NODE}/storage/${PVE_ISO_STORAGE}/download-url" \
        --data-urlencode "url=${UBUNTU_IMG_URL}" \
        -d "content=iso" \
        --data-urlencode "filename=${UBUNTU_IMG_NAME}")

    local upid
    upid=$(echo "$response" | json_val "['data']")

    if [[ -z "$upid" ]]; then
        err "Download failed: ${response}"
        exit 1
    fi

    info "Waiting for download to complete..."
    local status
    status=$(pve_wait_task "$upid")

    if [[ "$status" != "OK" ]]; then
        err "Download failed with status: ${status}"
        exit 1
    fi

    ok "Downloaded ${UBUNTU_IMG_NAME}"
}

create_vm() {
    section "Create VM"

    local net_config="virtio,bridge=${PVE_BRIDGE}"
    if [[ -n "$PVE_VLAN" ]]; then
        net_config="${net_config},tag=${PVE_VLAN}"
    fi

    local ip_config
    if [[ -n "$VM_IP" ]]; then
        ip_config="ip=${VM_IP},gw=${VM_GATEWAY}"
    else
        ip_config="ip=dhcp"
    fi

    # Reference the downloaded image by its Proxmox volume ID (storage-relative),
    # not a hardcoded filesystem path — import-from accepts a volid and this works
    # regardless of which storage PVE_ISO_STORAGE points at.
    local img_volid="${PVE_ISO_STORAGE}:iso/${UBUNTU_IMG_NAME}"

    if [[ "$DRY_RUN" == true ]]; then
        dry "Create VM '${VM_NAME}' (ID: ${VM_ID:-auto})"
        dry "  ${VM_CPU} CPU / ${VM_MEMORY}MB RAM / ${VM_DISK}GB disk"
        dry "  Network: ${net_config}"
        dry "  IP: ${ip_config}"
        dry "  User: ${VM_USER}"
        return
    fi

    info "Creating VM ${VM_ID} '${VM_NAME}'..."

    # URL-encode SSH key (Proxmox requires this)
    local encoded_key
    encoded_key=$(echo "$VM_SSH_PUBKEY" | urlencode)

    local response
    response=$(pve_post "/nodes/${PVE_NODE}/qemu" \
        -d "vmid=${VM_ID}" \
        --data-urlencode "name=${VM_NAME}" \
        -d "cores=${VM_CPU}" \
        -d "memory=${VM_MEMORY}" \
        -d "cpu=host" \
        -d "scsihw=virtio-scsi-single" \
        --data-urlencode "scsi0=${PVE_STORAGE}:0,import-from=${img_volid},ssd=1" \
        --data-urlencode "ide2=${PVE_STORAGE}:cloudinit" \
        --data-urlencode "net0=${net_config}" \
        --data-urlencode "boot=order=scsi0" \
        --data-urlencode "ipconfig0=${ip_config}" \
        --data-urlencode "ciuser=${VM_USER}" \
        --data-urlencode "sshkeys=${encoded_key}" \
        -d "agent=enabled%3D1" \
        -d "ostype=l26" \
        -d "vga=std" \
        ${VM_NAMESERVER:+--data-urlencode "nameserver=${VM_NAMESERVER}"})

    local upid
    upid=$(echo "$response" | json_val "['data']")

    if [[ -z "$upid" ]]; then
        err "VM creation failed: ${response}"
        exit 1
    fi

    info "Importing disk (this may take a minute)..."
    local status
    status=$(pve_wait_task "$upid")

    if [[ "$status" != "OK" ]]; then
        err "VM creation failed with status: ${status}"
        exit 1
    fi

    ok "VM created"

    # Resize disk
    if [[ "$VM_DISK" -gt 3 ]]; then
        info "Resizing disk to ${VM_DISK}GB..."
        pve_put "/nodes/${PVE_NODE}/qemu/${VM_ID}/resize" \
            -d "disk=scsi0" -d "size=${VM_DISK}G" > /dev/null
        ok "Disk resized"
    fi

    # Start VM
    info "Starting VM..."
    pve_post "/nodes/${PVE_NODE}/qemu/${VM_ID}/status/start" > /dev/null
    ok "VM started"
}

wait_for_ssh() {
    section "Wait for SSH"

    if [[ "$DRY_RUN" == true ]]; then
        dry "Wait for VM to boot and SSH to become available"
        return
    fi

    info "Waiting for VM to boot..."
    sleep 15

    # Try to get IP from QEMU guest agent
    local vm_ip=""
    local attempts=0
    local max_attempts=60

    while [[ -z "$vm_ip" ]] && [[ $attempts -lt $max_attempts ]]; do
        vm_ip=$(pve_get "/nodes/${PVE_NODE}/qemu/${VM_ID}/agent/network-get-interfaces" | \
            python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for iface in data.get('data', {}).get('result', []):
        if iface.get('name') == 'lo':
            continue
        for addr in iface.get('ip-addresses', []):
            ip = addr.get('ip-address', '')
            if addr.get('ip-address-type') == 'ipv4' and not ip.startswith('127.') and not ip.startswith('169.254.'):
                print(ip)
                sys.exit(0)
except:
    pass
" 2>/dev/null || true)

        # Also try static IP if configured
        if [[ -z "$vm_ip" ]] && [[ -n "$VM_IP" ]]; then
            local static_ip="${VM_IP%%/*}"
            if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes \
                "${VM_USER}@${static_ip}" "echo ready" > /dev/null 2>&1; then
                vm_ip="$static_ip"
            fi
        fi

        if [[ -z "$vm_ip" ]]; then
            attempts=$((attempts + 1))
            sleep 5
        fi
    done

    if [[ -z "$vm_ip" ]]; then
        err "Timed out waiting for IP address"
        err "Check the VM console in the Proxmox web UI"
        exit 1
    fi

    ok "VM IP: ${vm_ip}"

    # Wait for SSH
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
    VM_IP_ADDR="$vm_ip"
}

post_provision() {
    section "Post-Provision"

    if [[ "$DRY_RUN" == true ]]; then
        dry "SSH to VM, clone repos, run server-init.sh and sec-audit.sh --harden"
        return
    fi

    local ssh_cmd="ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_IP_ADDR}"

    # Install Tailscale first if auth key provided (gives us Tailscale SSH)
    if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
        info "Installing Tailscale..."
        $ssh_cmd "curl -fsSL https://tailscale.com/install.sh | sh && \
            sudo tailscale up --authkey=${TAILSCALE_AUTH_KEY} --hostname=${VM_NAME}" 2>/dev/null
        ok "Tailscale connected"
    fi

    # Clone sec-audit
    info "Cloning sec-audit..."
    $ssh_cmd "cd ~ && [ -d sec-audit ] || git clone ${SEC_AUDIT_REPO} sec-audit" 2>/dev/null

    # Copy server-init.conf if we have one locally
    local local_conf="${SCRIPT_DIR}/server-init.conf"
    if [[ -f "$local_conf" ]]; then
        info "Copying server-init.conf to VM..."
        scp -o StrictHostKeyChecking=no "$local_conf" \
            "${VM_USER}@${VM_IP_ADDR}:~/sec-audit/server-init.conf" 2>/dev/null
        ok "Config copied"
    fi

    # Copy sec-audit.conf if we have one locally
    local local_sec_conf="${SCRIPT_DIR}/sec-audit.conf"
    if [[ -f "$local_sec_conf" ]]; then
        info "Copying sec-audit.conf to VM..."
        scp -o StrictHostKeyChecking=no "$local_sec_conf" \
            "${VM_USER}@${VM_IP_ADDR}:~/sec-audit/sec-audit.conf" 2>/dev/null
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
    echo -e "  ${BOLD}VM ID:${NC}      ${VM_ID}"
    echo -e "  ${BOLD}SSH:${NC}        ssh ${VM_USER}@${VM_IP_ADDR}"
    if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
        echo -e "  ${BOLD}Tailscale:${NC}  ssh ${VM_USER}@${VM_NAME}"
    fi
    echo -e "  ${BOLD}Proxmox:${NC}    https://${PVE_HOST}:${PVE_PORT}"
    echo -e "  ${BOLD}Specs:${NC}      ${VM_CPU} CPU / ${VM_MEMORY}MB RAM / ${VM_DISK}GB disk"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

DRY_RUN=false
VM_IP_ADDR=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                VM_NAME="$2"
                shift 2
                ;;
            --id)
                VM_ID="$2"
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
            --ip)
                VM_IP="$2"
                shift 2
                ;;
            --gateway)
                VM_GATEWAY="$2"
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
    echo -e "${BOLD}create-vm v${VERSION}${NC} (Proxmox)"
    if [[ -n "$VM_NAME" ]]; then
        echo -e "VM: ${BOLD}${VM_NAME}${NC} (${VM_CPU} CPU / ${VM_MEMORY}MB / ${VM_DISK}GB)"
    fi
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "Mode: ${YELLOW}dry-run${NC}"
    fi

    validate

    download_image
    create_vm
    wait_for_ssh
    post_provision
    print_summary
}

main "$@"
