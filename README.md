# sec-audit

Tools to **create**, **provision**, and **secure** Ubuntu 24.04 LTS servers — from VM creation on ESXi to full security hardening, in one command.

| Script | Purpose |
|---|---|
| `create-vm.sh` | Create a VM on ESXi from your Mac |
| `destroy-vm.sh` | Destroy a VM on ESXi from your Mac |
| `server-init.sh` | Install standard tooling (Docker, Tailscale, gh, cloudflared, etc.) |
| `sec-audit.sh` | Harden or audit the server against a security baseline |

## Quick Start

### Automated: Create a fully provisioned VM from your Mac

```bash
git clone https://github.com/BardSec/sec-audit.git
cd sec-audit

# Copy your config (see Configuration below)
cp create-vm.conf.example create-vm.conf
cp server-init.conf.example server-init.conf
# Edit both files with your credentials

# Create a VM — provisions and hardens automatically
./create-vm.sh --name my-server
```

This single command will:
1. Download the Ubuntu 24.04 cloud image (cached after first run)
2. Create a VM on your ESXi host
3. Boot with your user account and SSH key via cloud-init
4. Auto-join your Tailscale network
5. Install Docker, GitHub CLI, and Cloudflare Tunnel
6. Auto-create a Cloudflare tunnel named after the hostname
7. Apply full security hardening

When it's done:
```bash
ssh youruser@my-server    # Via Tailscale
```

### Manual: Provision an existing server

```bash
git clone https://github.com/BardSec/sec-audit.git
cd sec-audit

# 1. Provision
sudo ./server-init.sh

# 2. Harden
sudo ./sec-audit.sh --harden
```

### One-liner for an existing server

```bash
git clone https://github.com/BardSec/sec-audit.git /tmp/sec-audit && \
cd /tmp/sec-audit && \
sudo ./server-init.sh && \
sudo ./sec-audit.sh --harden
```

---

## create-vm.sh — VM Creation (ESXi)

Creates an Ubuntu 24.04 VM on VMware ESXi directly from your Mac. Works with ESXi 6.5+ including the free license (uses SSH + vim-cmd, not the vSphere API).

### Prerequisites (Mac)

```bash
brew install sshpass
```

SSH must be enabled on your ESXi host (Host → Actions → Services → Enable Secure Shell).

### Usage

```bash
./create-vm.sh --name my-server                          # Create with defaults
./create-vm.sh --name my-server --cpu 4 --memory 8192    # Custom specs
./create-vm.sh --name my-server --disk 100               # Custom disk size
./create-vm.sh --name my-server --dry-run                # Preview only
```

### Configuration

```bash
cp create-vm.conf.example create-vm.conf
```

Required settings:

```bash
ESXI_HOST="192.168.1.100"       # ESXi IP address
ESXI_PASSWORD="your-password"
ESXI_DATASTORE="datastore1"     # ESXi datastore name
ESXI_NETWORK="VM Network"       # ESXi port group name
```

Optional settings:

```bash
VM_USER="andylombardo"           # Ubuntu user to create
VM_SSH_PUBKEY="ssh-ed25519 ..."  # Defaults to ~/.ssh/id_ed25519.pub
VM_CPU=2                         # Default vCPUs
VM_MEMORY=4096                   # Default RAM in MB
VM_DISK=50                       # Default disk in GB
TAILSCALE_AUTH_KEY="tskey-..."   # Auto-join tailnet (no manual tailscale up)
```

### How It Works

1. Downloads Ubuntu 24.04 cloud image VMDK (cached at `~/.cache/sec-audit/`)
2. Uploads VMDK to ESXi datastore via SCP
3. Converts to ESXi-compatible format with `vmkfstools`
4. Creates a cloud-init seed ISO with your user/SSH key config
5. Generates a VMX file and registers the VM with `vim-cmd`
6. Powers on and waits for SSH to become available
7. Copies `server-init.conf` and runs `server-init.sh` + `sec-audit.sh --harden`

---

## destroy-vm.sh — VM Destruction (ESXi)

Powers off and destroys a VM on ESXi, deleting all associated files.

### Usage

```bash
./destroy-vm.sh --list                     # List all VMs and their power state
./destroy-vm.sh --name my-server           # Destroy a VM
./destroy-vm.sh --name my-server --dry-run # Preview without destroying
```

Uses the same `create-vm.conf` for ESXi credentials.

---

## server-init.sh — Provisioning

Installs and configures standard tooling on a fresh Ubuntu 24.04 VM. Idempotent — safe to rerun.

### Usage

```bash
sudo ./server-init.sh              # Install everything
sudo ./server-init.sh --dry-run    # Preview what would be installed
```

### What It Installs

| Component | Details |
|---|---|
| **Baseline packages** | curl, wget, git, htop, unzip, jq, tree, net-tools, ca-certificates, etc. |
| **Docker** | Docker Engine + Compose plugin via official repo |
| **Tailscale** | VPN client via official install script |
| **GitHub CLI** | `gh` via official repo |
| **Cloudflare Tunnel** | `cloudflared` via official repo, auto-creates tunnel via API |
| **Git config** | User name and email (optional) |
| **User setup** | Docker group membership, NOPASSWD sudo, SSH authorized key (optional) |

### Configuration

```bash
cp server-init.conf.example server-init.conf
```

Common customizations:

```bash
# User setup
SETUP_USER="andylombardo"
ADD_TO_DOCKER_GROUP=true
SETUP_NOPASSWD_SUDO=true

# Cloudflare Tunnel — auto-create via API
CLOUDFLARE_API_TOKEN="your-token"
CLOUDFLARE_ACCOUNT_ID="your-account-id"

# Extra packages
EXTRA_PACKAGES=(vim tmux rsync)

# Skip components you don't need
INSTALL_CLOUDFLARED=false
```

### Cloudflare Tunnel Setup

Two options:

**Option A: Fully automated via API (recommended)**
- Set `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` in config
- Script auto-creates a tunnel named after the hostname
- See `server-init.conf.example` for how to create the API token

**Option B: Manual token from dashboard**
- Create tunnel at https://one.dash.cloudflare.com → Networks → Tunnels
- Set `CLOUDFLARED_TOKEN` in config

### Post-install Steps

After running `server-init.sh`, you may need to:

- `sudo tailscale up` — authenticate to your tailnet (not needed if using `TAILSCALE_AUTH_KEY` in create-vm.conf)
- Log out and back in for docker group to take effect

---

## sec-audit.sh — Security Hardening & Audit

Hardens or audits a server against a security baseline. Each check works in both modes.

### Usage

```bash
sudo ./sec-audit.sh --audit              # Check current state (read-only)
sudo ./sec-audit.sh --harden             # Apply security baselines
sudo ./sec-audit.sh --harden --dry-run   # Preview changes
sudo ./sec-audit.sh --audit --report /tmp/report.txt  # Save results to file
```

### What It Checks

| Category | Checks |
|---|---|
| **OS** | Ubuntu 24.04 verification, pending package updates |
| **Root Account** | Root account locked via `passwd -l` |
| **SSH** | Root login disabled, password auth disabled, empty passwords disabled, max auth tries, login grace time, idle timeout, X11 forwarding disabled, configurable port |
| **Firewall (UFW)** | UFW active, default deny incoming, SSH port allowed, configurable additional ports |
| **Tailscale** | Installed and running, IPv4 address verified |
| **fail2ban** | Installed, running, SSH jail configured with tunable maxretry/bantime/findtime |
| **Unattended Upgrades** | Package installed, automatic security updates enabled |
| **File Permissions** | `/etc/passwd` (644), `/etc/shadow` (640), `/etc/group` (644), `/etc/gshadow` (640), `/etc/ssh/sshd_config` (600), world-writable file scan |
| **Kernel Hardening** | 17 sysctl parameters including SYN cookies, ICMP redirects, source routing, martian logging, ASLR (auto-adjusts for Tailscale and Docker) |
| **Audit Logging** | auditd installed and running |
| **Services** | Unnecessary services disabled (avahi-daemon, cups, rpcbind) |
| **Login Banner** | Authorized-use warning banner at `/etc/issue.net`, SSH configured to display it |
| **Users** | No empty passwords, sudo group membership listed |

### Modes

**`--audit`** — Read-only. Reports PASS/FAIL/WARN/SKIP. Exits with code 1 if any checks fail.

```
  [PASS] Ubuntu 24.04 LTS detected
  [PASS] Root account is locked
  [FAIL] SSH PasswordAuthentication = yes (expected: no)
  [PASS] UFW is active
```

**`--harden`** — Applies fixes. Idempotent. SSH changes go to a drop-in file (`/etc/ssh/sshd_config.d/99-sec-audit.conf`), not the original config.

```
  [PASS] Ubuntu 24.04 LTS detected
  [FIXED] Root account locked
  [FIXED] SSH hardening written to /etc/ssh/sshd_config.d/99-sec-audit.conf
  [FIXED] UFW enabled (default deny incoming, allow outgoing)
```

**`--harden --dry-run`** — Preview without applying.

```
  [DRY-RUN] Would: Lock root account (passwd -l root)
  [DRY-RUN] Would: Set SSH PasswordAuthentication = no (currently: yes)
```

### Configuration

```bash
cp sec-audit.conf.example sec-audit.conf
```

Common customizations:

```bash
SSH_PORT=2222
ALLOWED_PORTS_TCP=(80 443)
TAILSCALE_ENABLED=false
FAIL2BAN_MAXRETRY=3
FAIL2BAN_BANTIME=86400    # 24 hours
```

---

## Requirements

**For create-vm.sh / destroy-vm.sh (run from Mac):**
- macOS with Homebrew
- `sshpass` (`brew install sshpass`)
- VMware ESXi 6.5+ with SSH enabled
- SSH key pair

**For server-init.sh / sec-audit.sh (run on server):**
- Ubuntu 24.04 LTS (will warn on other versions)
- Root access (`sudo`)
- Internet access (for package installation)

## How It Works

- All scripts are idempotent — safe to run repeatedly
- `create-vm.sh` uses SSH + `vim-cmd` to manage ESXi (works with free license)
- `server-init.sh` uses official repos for Docker, GitHub CLI, and Cloudflare
- `sec-audit.sh` uses drop-in config files — originals are never modified
- All managed configs include a comment header identifying them as managed by these tools
- Results are logged to `/var/log/server-init.log` and `/var/log/sec-audit.log`

## Config Files

| File | Purpose | Sensitive | In repo |
|---|---|---|---|
| `create-vm.conf` | ESXi credentials, VM defaults | Yes | No (gitignored) |
| `server-init.conf` | Cloudflare API token, user setup | Yes | No (gitignored) |
| `sec-audit.conf` | Security tuning (ports, thresholds) | No | No (gitignored) |
| `*.conf.example` | Documented templates | No | Yes |

## Contributing

Issues and pull requests are welcome.

**Adding a check to `sec-audit.sh`:**
1. Add a `check_*` function supporting audit + harden + dry-run
2. Add a config variable with default
3. Add entry to `sec-audit.conf.example`
4. Call from `main`
5. Update the README table

**Adding a component to `server-init.sh`:**
1. Add an `install_*` function with idempotent check
2. Add a config toggle (e.g., `INSTALL_MYPACKAGE=true`)
3. Add entry to `server-init.conf.example`
4. Call from `main`

## License

MIT
