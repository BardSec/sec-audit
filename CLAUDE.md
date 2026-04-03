# sec-audit

Bash scripts to provision and secure Ubuntu 24.04 LTS servers.

## Structure

Two standalone bash scripts — no build system, no dependencies beyond standard Ubuntu packages.

```
server-init.sh              # Provisioning (Docker, Tailscale, gh, cloudflared, etc.)
server-init.conf.example    # Provisioning config template
sec-audit.sh                # Security hardening + audit
sec-audit.conf.example      # Security config template
```

## Workflow

1. `sudo ./server-init.sh` — install standard tooling
2. `sudo ./sec-audit.sh --harden` — apply security baselines

## Key Patterns

### server-init.sh
- Each component is an `install_*` function
- Idempotent: checks if already installed before acting
- `$DRY_RUN` flag for preview mode
- Helpers: `ok`, `already`, `dry`, `err` for consistent output
- Uses official repos for Docker, GitHub CLI, Cloudflare

### sec-audit.sh
- Each security area is a `check_*` function that works in both audit and harden mode
- Mode determined by `$MODE` variable (`audit` or `harden`), with `$DRY_RUN` flag
- Helpers: `pass`, `fail`, `warn`, `changed`, `dry`, `skip` for consistent output
- SSH hardening writes to `/etc/ssh/sshd_config.d/99-sec-audit.conf` (drop-in, not inline edits)
- Kernel hardening writes to `/etc/sysctl.d/99-sec-audit.conf`
- Config is sourced as bash — variables override defaults
- Tailscale/Docker awareness: adjusts `ip_forward` and `rp_filter` accordingly

### Shared
- Both configs are optional bash files sourced at startup
- `set -euo pipefail` — avoid `dpkg -l | grep` pipes (use `dpkg-query` or `command -v` instead)
- Counter variables use `$((x + 1))` not `((x++))` to avoid set -e exits

## Adding New Components

### server-init.sh
1. Write an `install_*` function with idempotent check
2. Add a config toggle (e.g., `INSTALL_THING=true`)
3. Add entry to `server-init.conf.example`
4. Call from `main`

### sec-audit.sh
1. Write a `check_*` function supporting audit + harden + dry-run
2. Add config variable with default
3. Add entry to `sec-audit.conf.example`
4. Call from `main`

## Testing

Run on a VM — never on a production machine without `--dry-run` first:
```bash
sudo ./server-init.sh --dry-run
sudo ./sec-audit.sh --harden --dry-run
sudo ./sec-audit.sh --audit
```
