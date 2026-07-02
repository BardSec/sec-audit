#!/usr/bin/env bash
# destroy-vm — Destroy a VM on Proxmox from your Mac
# https://github.com/BardSec/sec-audit
#
# Usage:
#   ./destroy-vm.sh --name my-server
#   ./destroy-vm.sh --id 103
#   ./destroy-vm.sh --name my-server --dry-run
#   ./destroy-vm.sh --list

set -euo pipefail

VERSION="2.0.0"
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
PVE_HOST=""
PVE_PORT=8006
PVE_USER="root@pam"
PVE_PASSWORD=""
PVE_NODE=""
VM_NAME=""
VM_ID=""
DRY_RUN=false
LIST_MODE=false

# Load config
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

usage() {
    cat <<EOF
destroy-vm v${VERSION} — Destroy a VM on Proxmox

Usage:
  $0 --name <vm-name>            Destroy VM by name
  $0 --id <vmid>                 Destroy VM by ID
  $0 --name <vm-name> --dry-run  Preview without destroying
  $0 --list                      List all VMs

Options:
  --name NAME     VM name to destroy
  --id N          VM ID to destroy
  --list          List all VMs and their power state
  --dry-run       Show what would happen without destroying
  --config FILE   Use a custom config file
  --help          Show this help message
EOF
}

json_val() {
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null
}

urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read().strip(), safe=''))"
}

# Proxmox API
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
        echo -e "  ${RED}[ERROR]${NC} Failed to authenticate to Proxmox"
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

pve_delete() {
    local path="$1"
    local params="${2:-}"
    curl -sk -b "PVEAuthCookie=${PVE_TICKET}" \
        -H "CSRFPreventionToken: ${PVE_CSRF}" \
        -X DELETE \
        "https://${PVE_HOST}:${PVE_PORT}/api2/json${path}${params:+?$params}" 2>&1
}

list_vms() {
    echo ""
    echo -e "${BOLD}VMs on ${PVE_HOST} (node: ${PVE_NODE}):${NC}"
    echo ""

    pve_get "/nodes/${PVE_NODE}/qemu" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
if not data:
    print('  No VMs found.')
    sys.exit(0)

print(f'  {\"ID\":<6s} {\"Name\":<30s} {\"Status\":<12s} {\"CPU\":<6s} {\"Memory\":<10s}')
print(f'  {\"------\":<6s} {\"------------------------------\":<30s} {\"------------\":<12s} {\"------\":<6s} {\"----------\":<10s}')

for vm in sorted(data, key=lambda x: x.get('vmid', 0)):
    vmid = vm.get('vmid', '??')
    name = vm.get('name', '??')
    status = vm.get('status', '??')
    cpus = vm.get('cpus', '?')
    mem_gb = vm.get('maxmem', 0) / 1024 / 1024 / 1024
    color = '\033[0;32m' if status == 'running' else '\033[0;31m'
    reset = '\033[0m'
    print(f'  {vmid:<6} {name:<30s} {color}{status:<12s}{reset} {cpus:<6} {mem_gb:.0f}GB')
"
    echo ""
}

resolve_vm_id() {
    # Resolve VM name to ID if --name was used
    if [[ -n "$VM_ID" ]]; then
        return
    fi

    VM_ID=$(pve_get "/nodes/${PVE_NODE}/qemu" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
for vm in data:
    if vm.get('name', '').lower() == '${VM_NAME}'.lower():
        print(vm['vmid'])
        sys.exit(0)
print('')
" 2>/dev/null || true)

    if [[ -z "$VM_ID" ]]; then
        echo -e "  ${RED}[ERROR]${NC} VM '${VM_NAME}' not found"
        echo ""
        list_vms
        exit 1
    fi
}

destroy_vm() {
    echo ""
    echo -e "${BOLD}destroy-vm v${VERSION}${NC}"

    resolve_vm_id

    # Get VM info
    local vm_name vm_status
    vm_name=$(pve_get "/nodes/${PVE_NODE}/qemu/${VM_ID}/status/current" | json_val "['data']['name']" 2>/dev/null || echo "unknown")
    vm_status=$(pve_get "/nodes/${PVE_NODE}/qemu/${VM_ID}/status/current" | json_val "['data']['status']" 2>/dev/null || echo "unknown")

    echo -e "  VM: ${BOLD}${vm_name}${NC} (ID: ${VM_ID})"
    echo -e "  Status: ${vm_status}"

    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        dry "Stop VM '${vm_name}' (ID: ${VM_ID})"
        dry "Destroy VM and delete all disks"
        echo ""
        return
    fi

    # Stop if running
    if [[ "$vm_status" == "running" ]]; then
        echo -e "  ${BLUE}[INFO]${NC} Stopping VM..."
        pve_post "/nodes/${PVE_NODE}/qemu/${VM_ID}/status/stop" > /dev/null
        sleep 5
    fi

    # Destroy
    echo -e "  ${BLUE}[INFO]${NC} Destroying VM and deleting disks..."
    local response
    response=$(pve_delete "/nodes/${PVE_NODE}/qemu/${VM_ID}" "destroy-unreferenced-disks=1&purge=1")

    echo -e "  ${GREEN}[OK]${NC} VM '${vm_name}' (ID: ${VM_ID}) destroyed"
    echo ""
}

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

    if [[ -z "$PVE_HOST" ]]; then
        echo "Error: PVE_HOST not configured. Set it in create-vm.conf"
        exit 1
    fi

    pve_auth

    # Auto-detect node
    if [[ -z "$PVE_NODE" ]]; then
        PVE_NODE=$(pve_get "/nodes" | json_val "['data'][0]['node']")
    fi

    if [[ "$LIST_MODE" == true ]]; then
        list_vms
        exit 0
    fi

    if [[ -z "$VM_NAME" ]] && [[ -z "$VM_ID" ]]; then
        echo "Error: --name or --id is required (or use --list)"
        usage
        exit 1
    fi

    destroy_vm
}

main "$@"
