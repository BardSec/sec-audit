# sec-audit

Tools to **provision** and **secure** Ubuntu 24.04 LTS servers. Two scripts, one workflow:

1. **`server-init.sh`** — Install standard tooling (Docker, Tailscale, GitHub CLI, Cloudflare Tunnel, etc.)
2. **`sec-audit.sh`** — Harden or audit the server against a security baseline

## Quick Start

```bash
git clone https://github.com/BardSec/sec-audit.git
cd sec-audit

# 1. Provision a fresh VM
sudo ./server-init.sh

# 2. Harden it
sudo ./sec-audit.sh --harden
```

### One-liner for a fresh VM

```bash
git clone https://github.com/BardSec/sec-audit.git /tmp/sec-audit && \
cd /tmp/sec-audit && \
sudo ./server-init.sh && \
sudo ./sec-audit.sh --harden
```

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
| **Cloudflare Tunnel** | `cloudflared` via official repo |
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

# Git
GIT_USER_NAME="Andy Lombardo"
GIT_USER_EMAIL="andy@example.com"

# Extra packages
EXTRA_PACKAGES=(vim tmux rsync)

# Skip components you don't need
INSTALL_CLOUDFLARED=false
```

### Post-install Steps

After running `server-init.sh`, you may need to:

- `sudo tailscale up` — authenticate to your tailnet
- `cloudflared tunnel login` — authenticate to Cloudflare
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

- Ubuntu 24.04 LTS (will warn on other versions)
- Root access (`sudo`)
- Internet access (for package installation)

## How It Works

- Both scripts are idempotent — safe to run repeatedly
- `server-init.sh` uses official repos for Docker, GitHub CLI, and Cloudflare
- `sec-audit.sh` uses drop-in config files — originals are never modified
- All managed configs include a comment header identifying them as managed by these tools
- Results are logged to `/var/log/server-init.log` and `/var/log/sec-audit.log`

## Contributing

Issues and pull requests are welcome. When adding a new check to `sec-audit.sh`:

1. Add a `check_*` function following the existing pattern
2. Support both `audit` and `harden` modes (and `--dry-run`)
3. Use the `pass`, `fail`, `warn`, `changed`, `dry`, and `skip` helper functions
4. Make the check configurable via `sec-audit.conf` with a sensible default
5. Add the check to the `main` function's execution list
6. Update the README table

When adding a new component to `server-init.sh`:

1. Add an `install_*` function following the existing pattern
2. Support `--dry-run` and idempotent behavior
3. Add a config toggle (e.g., `INSTALL_MYPACKAGE=true`)
4. Call the function from `main`

## License

MIT
