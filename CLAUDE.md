# sec-audit

Bash script to harden or audit Ubuntu 24.04 LTS servers against a security baseline.

## Structure

Single-script tool — no build system, no dependencies beyond standard Ubuntu packages.

```
sec-audit.sh              # Main script (audit + harden modes)
sec-audit.conf.example    # Configuration template
```

## Key Patterns

- Each security area is a `check_*` function that works in both audit and harden mode
- Mode determined by `$MODE` variable (`audit` or `harden`), with `$DRY_RUN` flag
- Helper functions: `pass`, `fail`, `warn`, `changed`, `dry`, `skip` for consistent output
- SSH hardening writes to `/etc/ssh/sshd_config.d/99-sec-audit.conf` (drop-in, not inline edits)
- Kernel hardening writes to `/etc/sysctl.d/99-sec-audit.conf`
- Config is sourced as bash — variables override defaults
- Tailscale awareness: auto-adjusts `ip_forward` sysctl when Tailscale is enabled

## Adding a New Check

1. Write a `check_*` function following the existing pattern
2. Add a config variable with default at the top of the script
3. Add matching entry to `sec-audit.conf.example`
4. Call the function from `main`

## Testing

Run on a VM — never on a production machine without `--dry-run` first:
```bash
sudo ./sec-audit.sh --harden --dry-run
sudo ./sec-audit.sh --audit
```
