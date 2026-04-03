#!/usr/bin/env bash
# destroy-vm — Destroy a VM on ESXi from your Mac
# https://github.com/BardSec/sec-audit
#
# Usage:
#   ./destroy-vm.sh --name my-server
#   ./destroy-vm.sh --name my-server --dry-run
#   ./destroy-vm.sh --list

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/create-vm.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Defaults
ESXI_HOST=""
ESXI_USER="root"
VM_NAME=""
DRY_RUN=false
LIST_MODE=false

# Load config
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

usage() {
    cat <<EOF
destroy-vm v${VERSION} — Destroy a VM on ESXi

Usage:
  $0 --name <vm-name>         Power off and destroy a VM
  $0 --name <vm-name> --dry-run  Preview without destroying
  $0 --list                   List all VMs on the ESXi host

Options:
  --name NAME     VM name to destroy (required unless --list)
  --list          List all VMs and their power state
  --dry-run       Show what would happen without destroying
  --config FILE   Use a custom config file
  --help          Show this help message
EOF
}

esxi_ssh() {
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        "${ESXI_USER}@${ESXI_HOST}" "$@"
}

list_vms() {
    echo ""
    echo -e "${BOLD}VMs on ${ESXI_HOST}:${NC}"
    echo ""

    local vm_list
    vm_list=$(esxi_ssh "vim-cmd vmsvc/getallvms 2>/dev/null | tail -n +2" || true)

    if [[ -z "$vm_list" ]]; then
        echo "  No VMs found."
        return
    fi

    # Header
    printf "  ${BOLD}%-6s %-30s %-12s${NC}\n" "ID" "Name" "Power State"
    printf "  %-6s %-30s %-12s\n" "------" "------------------------------" "------------"

    while IFS= read -r line; do
        local vmid vmname power_state
        vmid=$(echo "$line" | awk '{print $1}')
        vmname=$(echo "$line" | awk '{print $2}')

        power_state=$(esxi_ssh "vim-cmd vmsvc/power.getstate ${vmid} 2>/dev/null | tail -1" || echo "unknown")

        local color="$NC"
        if [[ "$power_state" == *"Powered on"* ]]; then
            color="$GREEN"
        elif [[ "$power_state" == *"Powered off"* ]]; then
            color="$RED"
        fi

        printf "  %-6s %-30s ${color}%-12s${NC}\n" "$vmid" "$vmname" "$power_state"
    done <<< "$vm_list"

    echo ""
}

destroy_vm() {
    echo ""
    echo -e "${BOLD}destroy-vm v${VERSION}${NC}"

    # Find the VM ID
    local vmid
    vmid=$(esxi_ssh "vim-cmd vmsvc/getallvms 2>/dev/null | grep ' ${VM_NAME} ' | awk '{print \$1}'" || true)

    if [[ -z "$vmid" ]]; then
        # Try matching at start of line with different spacing
        vmid=$(esxi_ssh "vim-cmd vmsvc/getallvms 2>/dev/null | awk '\$2 == \"${VM_NAME}\" {print \$1}'" || true)
    fi

    if [[ -z "$vmid" ]]; then
        echo -e "  ${RED}[ERROR]${NC} VM '${VM_NAME}' not found on ${ESXI_HOST}"
        echo ""
        echo "  Available VMs:"
        esxi_ssh "vim-cmd vmsvc/getallvms 2>/dev/null | tail -n +2 | awk '{print \"    \" \$2}'"
        exit 1
    fi

    echo -e "  VM: ${BOLD}${VM_NAME}${NC} (ID: ${vmid})"

    # Check power state
    local power_state
    power_state=$(esxi_ssh "vim-cmd vmsvc/power.getstate ${vmid} 2>/dev/null | tail -1" || echo "unknown")
    echo -e "  State: ${power_state}"

    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        echo -e "  ${YELLOW}[DRY-RUN]${NC} Would: Power off VM '${VM_NAME}'"
        echo -e "  ${YELLOW}[DRY-RUN]${NC} Would: Destroy VM and delete all files"
        echo ""
        return
    fi

    # Power off if running
    if [[ "$power_state" == *"Powered on"* ]]; then
        echo -e "  ${BLUE}[INFO]${NC} Powering off..."
        esxi_ssh "vim-cmd vmsvc/power.off ${vmid}" > /dev/null 2>&1 || true
        sleep 3
    fi

    # Destroy the VM (unregisters and deletes files)
    echo -e "  ${BLUE}[INFO]${NC} Destroying VM and deleting files..."
    esxi_ssh "vim-cmd vmsvc/destroy ${vmid}" > /dev/null 2>&1

    echo -e "  ${GREEN}[OK]${NC} VM '${VM_NAME}' destroyed"
    echo ""
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                VM_NAME="$2"
                shift 2
                ;;
            --list)
                LIST_MODE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --config)
                CONF_FILE="$2"
                if [[ -f "$CONF_FILE" ]]; then
                    source "$CONF_FILE"
                else
                    echo "Error: config file not found: $CONF_FILE"
                    exit 1
                fi
                shift 2
                ;;
            --version)
                echo "destroy-vm v${VERSION}"
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

    # Validate
    if [[ -z "$ESXI_HOST" ]]; then
        echo "Error: ESXI_HOST not configured. Set it in create-vm.conf"
        exit 1
    fi

    if [[ "$LIST_MODE" == true ]]; then
        list_vms
        exit 0
    fi

    if [[ -z "$VM_NAME" ]]; then
        echo "Error: --name is required (or use --list to see all VMs)"
        usage
        exit 1
    fi

    destroy_vm
}

main "$@"
