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
#   - SSH key auth configured for ESXi host
#   - SSH key pair (~/.ssh/id_ed25519.pub)
#
# Configuration: copy create-vm.conf.example to create-vm.conf and edit.

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/create-vm.conf"
CACHE_DIR="${HOME}/.cache/sec-audit"
UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.vmdk"
UBUNTU_IMG_FILE="noble-server-cloudimg-amd64.vmdk"

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

    # Verify SSH key access to ESXi
    if [[ "$DRY_RUN" != true ]]; then
        if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${ESXI_USER}@${ESXI_HOST}" "echo ok" > /dev/null 2>&1; then
            err "Cannot SSH to ${ESXI_USER}@${ESXI_HOST} — configure SSH key auth first"
            errors=$((errors + 1))
        fi
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


download_image() {
    section "Ubuntu Cloud Image"

    mkdir -p "$CACHE_DIR"
    local img_path="${CACHE_DIR}/${UBUNTU_IMG_FILE}"

    if [[ -f "$img_path" ]]; then
        already "$img_path"
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        dry "Download Ubuntu 24.04 cloud image to ${img_path}"
        return
    fi

    info "Downloading Ubuntu 24.04 VMDK..."
    info "URL: ${UBUNTU_IMG_URL}"
    curl -fSL -o "$img_path" "$UBUNTU_IMG_URL"
    ok "Downloaded to ${img_path}"
}

already() {
    echo -e "  ${GREEN}[CACHED]${NC} $1"
}

create_seed_iso() {
    # Create a cloud-init seed ISO to inject user-data and meta-data
    local iso_path="${CACHE_DIR}/${VM_NAME}-seed.iso"
    local seed_dir="${CACHE_DIR}/${VM_NAME}-seed"

    mkdir -p "$seed_dir"

    # meta-data
    cat > "${seed_dir}/meta-data" <<METADATA
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
METADATA

    # user-data
    generate_cloud_init > "${seed_dir}/user-data"

    # Create ISO
    if command -v mkisofs &> /dev/null; then
        mkisofs -output "$iso_path" -volid cidata -joliet -rock \
            "${seed_dir}/user-data" "${seed_dir}/meta-data" > /dev/null 2>&1
    elif command -v hdiutil &> /dev/null; then
        # macOS approach
        hdiutil makehybrid -o "$iso_path" -hfs -joliet -iso -default-volume-name cidata \
            "$seed_dir" > /dev/null 2>&1
    else
        err "No ISO creation tool found (need mkisofs or hdiutil)"
        return 1
    fi

    rm -rf "$seed_dir"
    echo "$iso_path"
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

esxi_ssh() {
    # Run a command on ESXi via SSH (key auth)
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        "${ESXI_USER}@${ESXI_HOST}" "$@"
}

esxi_scp() {
    # Upload a file to ESXi via SCP (key auth)
    scp -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        "$1" "${ESXI_USER}@${ESXI_HOST}:$2"
}

deploy_vm() {
    section "Deploy VM"

    local img_path="${CACHE_DIR}/${UBUNTU_IMG_FILE}"
    local ds_path="/vmfs/volumes/${ESXI_DATASTORE}"
    local vm_dir="${ds_path}/${VM_NAME}"

    # Check if VM directory already exists
    if esxi_ssh "test -d '${vm_dir}'" 2>/dev/null; then
        err "VM directory '${VM_NAME}' already exists on datastore"
        err "Delete it first or choose a different name"
        exit 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        dry "Create VM '${VM_NAME}' (${VM_CPU} CPU, ${VM_MEMORY}MB RAM, ${VM_DISK}GB disk)"
        dry "Upload VMDK and cloud-init seed ISO"
        dry "Network: ${ESXI_NETWORK}, Datastore: ${ESXI_DATASTORE}"
        return
    fi

    # Create VM directory
    info "Creating VM directory..."
    esxi_ssh "mkdir -p '${vm_dir}'"

    # Upload the VMDK
    info "Uploading Ubuntu cloud image VMDK (this may take a few minutes)..."
    esxi_scp "$img_path" "${vm_dir}/ubuntu-source.vmdk"
    ok "VMDK uploaded"

    # Convert to ESXi-compatible disk using vmkfstools
    info "Converting disk to ESXi format and resizing to ${VM_DISK}GB..."
    esxi_ssh "vmkfstools -i '${vm_dir}/ubuntu-source.vmdk' '${vm_dir}/${VM_NAME}.vmdk' -d thin && \
              rm -f '${vm_dir}/ubuntu-source.vmdk' && \
              vmkfstools -X ${VM_DISK}G '${vm_dir}/${VM_NAME}.vmdk'"
    ok "Disk converted and resized"

    # Create and upload cloud-init seed ISO
    info "Creating cloud-init seed ISO..."
    local seed_iso
    seed_iso=$(create_seed_iso)

    info "Uploading seed ISO..."
    esxi_scp "$seed_iso" "${vm_dir}/seed.iso"
    rm -f "$seed_iso"
    ok "Seed ISO uploaded"

    # Generate VMX file locally and upload
    info "Creating VM configuration..."
    local local_vmx="${CACHE_DIR}/${VM_NAME}.vmx"
    cat > "$local_vmx" <<VMX
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "13"
displayName = "${VM_NAME}"
guestOS = "ubuntu-64"
memSize = "${VM_MEMORY}"
numvcpus = "${VM_CPU}"
firmware = "bios"
scsi0.virtualDev = "lsilogic"
scsi0.present = "TRUE"
scsi0:0.fileName = "${VM_NAME}.vmdk"
scsi0:0.present = "TRUE"
ide1:0.deviceType = "cdrom-image"
ide1:0.fileName = "seed.iso"
ide1:0.present = "TRUE"
ethernet0.virtualDev = "e1000"
ethernet0.networkName = "${ESXI_NETWORK}"
ethernet0.addressType = "generated"
ethernet0.present = "TRUE"
tools.syncTime = "TRUE"
VMX

    esxi_scp "$local_vmx" "${vm_dir}/${VM_NAME}.vmx"
    rm -f "$local_vmx"

    ok "VMX created"

    # Register the VM
    info "Registering VM with ESXi..."
    local vmid
    vmid=$(esxi_ssh "vim-cmd solo/registervm '${vm_dir}/${VM_NAME}.vmx'")
    ok "VM registered (ID: ${vmid})"

    # Power on
    info "Powering on '${VM_NAME}'..."
    esxi_ssh "vim-cmd vmsvc/power.on ${vmid}"
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

    # Get VM ID
    local vmid
    vmid=$(esxi_ssh "vim-cmd vmsvc/getallvms 2>/dev/null | grep '${VM_NAME}' | awk '{print \$1}'")

    while [[ -z "$vm_ip" ]] && [[ $attempts -lt $max_attempts ]]; do
        vm_ip=$(esxi_ssh "vim-cmd vmsvc/get.guest ${vmid} 2>/dev/null | grep -m1 'ipAddress = \"' | sed 's/.*ipAddress = \"//;s/\".*//' " || true)
        attempts=$((attempts + 1))
        if [[ -z "$vm_ip" ]]; then
            sleep 5
        fi
    done

    if [[ -z "$vm_ip" ]]; then
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

    download_image
    deploy_vm
    wait_for_ssh
    post_provision
    print_summary
}

main "$@"
