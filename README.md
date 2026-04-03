# sec-audit

A single-script tool to **harden** or **audit** Ubuntu 24.04 LTS servers against a security baseline.

Run it on a fresh VM to apply all hardening at once, or on an existing server to get a pass/fail report of its current state.

## Quick Start

```bash
# Clone the repo
git clone https://github.com/BardSec/sec-audit.git
cd sec-audit

# Audit an existing server (read-only, changes nothing)
sudo ./sec-audit.sh --audit

# Harden a fresh server
sudo ./sec-audit.sh --harden

# Preview what would change without applying
sudo ./sec-audit.sh --harden --dry-run
```

### One-liner for a fresh VM

```bash
curl -fsSL https://raw.githubusercontent.com/BardSec/sec-audit/main/sec-audit.sh -o /tmp/sec-audit.sh && \
chmod +x /tmp/sec-audit.sh && \
sudo /tmp/sec-audit.sh --harden
```

## What It Checks

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
| **Kernel Hardening** | 17 sysctl parameters including SYN cookies, ICMP redirects, source routing, martian logging, ASLR (auto-adjusts IP forwarding for Tailscale) |
| **Audit Logging** | auditd installed and running |
| **Services** | Unnecessary services disabled (avahi-daemon, cups, rpcbind) |
| **Login Banner** | Authorized-use warning banner at `/etc/issue.net`, SSH configured to display it |
| **Users** | No empty passwords, sudo group membership listed |

## Modes

### `--audit` (read-only)

Checks every item and reports PASS, FAIL, WARN, or SKIP. Changes nothing. Exits with code 1 if any checks fail (useful for CI/monitoring).

```
  [PASS] Ubuntu 24.04 LTS detected
  [PASS] Root account is locked
  [FAIL] SSH PasswordAuthentication = yes (expected: no)
  [PASS] UFW is active
  [WARN] Unnecessary service running: cups
```

### `--harden`

Applies fixes for any failing checks. Safe to run multiple times (idempotent). SSH changes are written to a drop-in file (`/etc/ssh/sshd_config.d/99-sec-audit.conf`) to avoid modifying the system sshd_config.

```
  [PASS] Ubuntu 24.04 LTS detected
  [FIXED] Root account locked
  [FIXED] SSH hardening written to /etc/ssh/sshd_config.d/99-sec-audit.conf
  [FIXED] UFW enabled (default deny incoming, allow outgoing)
```

### `--harden --dry-run`

Shows what would change without applying anything.

```
  [DRY-RUN] Would: Lock root account (passwd -l root)
  [DRY-RUN] Would: Set SSH PasswordAuthentication = no (currently: yes)
```

## Configuration

Copy the example config and edit as needed:

```bash
cp sec-audit.conf.example sec-audit.conf
```

Or use a custom config file:

```bash
sudo ./sec-audit.sh --harden --config /path/to/my.conf
```

All settings have sensible defaults — the config file is optional. See `sec-audit.conf.example` for all available options.

### Common Customizations

**Change SSH port:**
```bash
SSH_PORT=2222
```

**Allow web traffic through the firewall:**
```bash
ALLOWED_PORTS_TCP=(80 443)
```

**Disable Tailscale checks (not every server uses it):**
```bash
TAILSCALE_ENABLED=false
```

**Adjust fail2ban thresholds:**
```bash
FAIL2BAN_MAXRETRY=3
FAIL2BAN_BANTIME=86400    # 24 hours
```

## Reporting

Save audit results to a file:

```bash
sudo ./sec-audit.sh --audit --report /tmp/audit-report.txt
```

Results are also logged to `/var/log/sec-audit.log`.

## Requirements

- Ubuntu 24.04 LTS (will warn on other versions)
- Root access (`sudo`)
- Internet access (for package installation in harden mode)

## How It Works

- Each security area is an independent check function
- In **audit mode**, checks report current state without modification
- In **harden mode**, checks fix any failing items and report what changed
- SSH hardening uses a drop-in file (`/etc/ssh/sshd_config.d/99-sec-audit.conf`) — your original `sshd_config` is never modified
- Kernel hardening uses `/etc/sysctl.d/99-sec-audit.conf`
- All managed config files include a comment header identifying them as sec-audit managed

## Contributing

Issues and pull requests are welcome. When adding a new check:

1. Add a `check_*` function following the existing pattern
2. Support both `audit` and `harden` modes (and `--dry-run`)
3. Use the `pass`, `fail`, `warn`, `changed`, `dry`, and `skip` helper functions
4. Make the check configurable via `sec-audit.conf` with a sensible default
5. Add the check to the `main` function's execution list
6. Update the README table

## License

MIT
