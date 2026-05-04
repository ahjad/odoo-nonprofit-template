# Production hardening checklist

Apply this when forking the Odoo nonprofit template for a real deployment.
The template (this server) intentionally takes shortcuts that are NOT acceptable
in production. Items are tagged:

- **[MUST]** — do before any real data touches the system
- **[SHOULD]** — do within the first week
- **[NICE]** — do when you have time / scale demands it

---

## 1. Secrets and credentials

- [ ] **[MUST]** Rotate every secret. The template's `POSTGRES_PASSWORD`, `admin_passwd`, restic passphrase, and Odoo admin password were generated for the template — they exist in chat transcripts and possibly screenshots. Generate fresh ones.
- [ ] **[MUST]** Change Odoo admin password on first login; do not keep the deploy-time password.
- [ ] **[MUST]** Rename or disable the default `admin` user (login = `admin` is brute-force bait). Create a named admin account and demote the default.
- [ ] **[MUST]** Escrow the restic passphrase somewhere safe and separate (password manager, sealed envelope, second admin's vault). **Lose it = backups are unrecoverable.**
- [ ] **[SHOULD]** Document who has access to which secret in a written access matrix.
- [ ] **[NICE]** Move secrets out of `.env`/`odoo.conf` files into a secret manager (Vault, sops, Bitwarden Secrets Manager) injected at container start.

## 2. Backups and disaster recovery

- [ ] **[MUST]** Set up off-site backup (Hetzner Storage Box / B2 / S3). The template is single-disk only — disk loss = total loss.
- [ ] **[MUST]** Run a restore drill from off-site to a fresh server before going live. The runbook (`/home/deploy/scripts/RESTORE.md`) is theoretical until proven on a fresh box.
- [ ] **[MUST]** Document target RTO (recovery time objective) and RPO (recovery point objective) — e.g. "RPO 24h / RTO 4h." Drives everything else.
- [ ] **[SHOULD]** Quarterly restore drill — calendar reminder. An untested backup is not a backup.
- [ ] **[SHOULD]** Add a weekly `restic check --read-data` timer to detect bit-rot.
- [ ] **[SHOULD]** Backup health alerting — pipe failures to email or healthchecks.io ping.
- [ ] **[NICE]** Geographic separation: off-site backup in a different country / cloud than the primary server.

## 3. SSH and host access

- [ ] **[MUST]** Re-generate SSH host keys on the cloned server (don't ship a template image with the same host keys to multiple deployments — `sudo rm /etc/ssh/ssh_host_* && sudo dpkg-reconfigure openssh-server`).
- [ ] **[SHOULD]** Restrict SSH to known source IPs via UFW (`ufw allow from <ip> to any port 22`) instead of LIMIT-from-anywhere. Cuts brute-force log noise to zero.
- [ ] **[SHOULD]** Require SSH key passphrases (enforce with `ssh-keygen -p` or org policy). A stolen unlocked key = full server access.
- [ ] **[SHOULD]** Use a hardware-backed SSH key (YubiKey, Secure Enclave) for the primary admin.
- [ ] **[SHOULD]** Add a second admin user. Single-admin servers are an availability risk if that admin loses access or leaves.
- [ ] **[NICE]** Centralize SSH keys via your identity provider (Tailscale SSH, Teleport, AWS SSM) so offboarding is one click.
- [ ] **[NICE]** Move SSH off port 22 — purely reduces log noise, not real security.

## 4. Network and firewall

- [ ] **[MUST]** Audit `127.0.0.1:5432` exposure. Postgres is reachable from the host as anyone with shell access. If your threat model includes "deploy user gets compromised," remove the host port binding entirely and rely on the Docker network.
- [ ] **[SHOULD]** Put a CDN / DDoS shield in front (Cloudflare proxy mode is free) — also adds WAF, bot management, and rate limiting.
- [ ] **[SHOULD]** Enable rate limiting in Caddy for `/web/login` and `/web/session/authenticate` (mitigates credential stuffing).
- [ ] **[SHOULD]** Add a `DOCKER-USER` iptables rule to deny non-RFC1918 sources to docker-published ports — closes the UFW-bypass gap globally instead of relying on per-port `127.0.0.1:` discipline.
- [ ] **[NICE]** Network-segment Postgres onto a separate Docker network from Caddy — Caddy has no business reaching Postgres.

## 5. TLS and edge

- [ ] **[MUST]** Real domain with TLS before going live. Change Caddyfile's `:80` block to `your.domain { ... }` — Caddy auto-provisions Let's Encrypt and redirects HTTP→HTTPS. Already-set `proxy_mode=True` makes the switchover work without Odoo changes.
- [ ] **[MUST]** UFW already allows 443; verify it's still allowed after switchover (`sudo ufw status`).
- [ ] **[SHOULD]** Add security headers in Caddy: `Strict-Transport-Security`, `Content-Security-Policy`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`.
- [ ] **[SHOULD]** Set `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload` and submit to the HSTS preload list once you're confident HTTPS won't break.
- [ ] **[NICE]** Certificate Transparency monitoring (alerts on rogue cert issuance for your domain).

## 6. Container and Docker

- [ ] **[SHOULD]** Pin images to digests, not floating tags: `odoo:18.0@sha256:...`. `latest` and even `18.0` move under you. Update intentionally, not accidentally.
- [ ] **[SHOULD]** Add `mem_limit` and `cpus` per service in compose. Currently nothing caps Odoo — a runaway worker can OOM the host. Suggested: Odoo 5g, Postgres 2g, Caddy 256m.
- [ ] **[SHOULD]** Drop unused capabilities and add `security_opt: ["no-new-privileges:true"]` for each service.
- [ ] **[SHOULD]** Run a container image scanner (Trivy, Grype) in CI, alert on new HIGH/CRITICAL CVEs in your pinned digests.
- [ ] **[NICE]** Read-only root filesystem for Odoo and Caddy (`read_only: true` + tmpfs for `/tmp`).
- [ ] **[NICE]** Enable Docker user namespaces — container `root` ≠ host `root`.

## 7. Postgres

- [ ] **[MUST]** Stop using the Postgres superuser as Odoo's runtime user. Currently `POSTGRES_USER=odoo` makes `odoo` a superuser. Create a separate `odoo_app` non-superuser that owns its DBs and used by Odoo at runtime. Reserve the superuser for ops only.
- [ ] **[SHOULD]** Tune `postgresql.conf` for the workload (shared_buffers, effective_cache_size, work_mem, maintenance_work_mem). The Postgres image defaults are conservative.
- [ ] **[SHOULD]** Restrict `pg_hba.conf` to only the Docker bridge subnet — currently it accepts from anywhere reachable.
- [ ] **[NICE]** Enable Postgres SSL between Odoo and Postgres if they cross hosts. Same-host: not worth the complexity.

## 8. Odoo application

- [ ] **[MUST]** Install `auth_totp` (TOTP/2FA), enforce for all admins. Free and built-in to Odoo Community.
- [ ] **[MUST]** Audit installed modules. The template has `-i base` only; in production install only what you need (each module = attack surface).
- [ ] **[MUST]** Set `db_filter` to match the actual DB name on production (template uses `^nonprofit$`).
- [ ] **[SHOULD]** Install `auditlog` (OCA) to track changes to sensitive records (donors, financial transactions).
- [ ] **[SHOULD]** Configure outgoing mail (SMTP relay with proper SPF/DKIM/DMARC for the sending domain). Donation receipts marked as spam = donors lost.
- [ ] **[SHOULD]** Set Odoo `Settings → Permissions` properly. Default groups can leak data across roles.
- [ ] **[SHOULD]** Disable `web/database/manager` route in Caddy as defense in depth (we already have `list_db=False`, but add a Caddy `respond 404` for the path).
- [ ] **[NICE]** Run a penetration test against the public surface (login, websocket, longpolling, asset endpoints).

## 9. Monitoring and alerting

- [ ] **[MUST]** Uptime monitor for the public URL (UptimeRobot, healthchecks.io). 5-minute check minimum.
- [ ] **[MUST]** Backup-success monitor — if no successful backup in >24h, alert.
- [ ] **[SHOULD]** Disk space alert at 80% — Odoo filestore + Postgres can grow silently.
- [ ] **[SHOULD]** Memory / OOM alert. If swap is being used heavily, you need bigger RAM.
- [ ] **[SHOULD]** Fail2ban ban notifications via email so you notice attack patterns.
- [ ] **[SHOULD]** TLS certificate expiry alert (Caddy auto-renews, but alert if it ever fails 30+ days out).
- [ ] **[NICE]** Log shipping to a central store (Loki + Grafana, Papertrail, Datadog).
- [ ] **[NICE]** APM for Odoo (Sentry, Glitchtip for free) — surfaces exceptions before users report them.

## 10. Compliance and data protection

- [ ] **[MUST]** GDPR (if any EU residents in the data): Data Processing Agreement with Hetzner (download from console), privacy policy, DPO if required, retention policy.
- [ ] **[MUST]** Document where data lives (DB on host, filestore on host, backups in restic repo, off-site copy). Required for breach notification if compromised.
- [ ] **[MUST]** Implement right-to-erasure procedure for personal data (donor records, etc.).
- [ ] **[SHOULD]** Data retention policy — when do you delete old donor records? Old logs?
- [ ] **[SHOULD]** Encryption-at-rest for the live filesystem if jurisdiction requires (Hetzner CX disks are NOT encrypted by default; would need LUKS on a separate volume).
- [ ] **[NICE]** SOC2 / ISO 27001 alignment if your nonprofit needs to demonstrate to large grantors.

## 11. Operational hygiene

- [ ] **[MUST]** Document who is on-call and how they're reached.
- [ ] **[MUST]** Document the rebuild-from-scratch procedure (currently lives partly in the project memory file). Test it.
- [ ] **[SHOULD]** Staging environment — a second instance for testing Odoo upgrades, addon installs, custom dev. Before touching production.
- [ ] **[SHOULD]** Change-management — major changes (Odoo upgrade, addon install, schema change) require: backup → staging test → scheduled window → rollback plan.
- [ ] **[SHOULD]** Run `lynis audit system` periodically; address findings rated HIGH.
- [ ] **[NICE]** Apply CIS Ubuntu 24.04 benchmark relevant items (SSH, kernel, accounts).

## 12. Long-term and lifecycle

- [ ] Track Odoo 18 LTS support window. When a new LTS lands, plan an upgrade path (always test in staging from a backup restore).
- [ ] Track Postgres 16 EOL (Nov 2028 per current schedule). Plan upgrade to 17/18 well before then.
- [ ] Re-rotate secrets annually or on personnel changes.
- [ ] Review this checklist every 6 months — assumptions and threats drift.

---

## What's already in this template (for reference)

The Phase 0/1/2 work means the following are already configured. **Don't re-do them, but verify on the cloned server:**

- SSH: root disabled, password auth disabled, key-only (`/etc/ssh/sshd_config.d/`)
- UFW: 22 LIMIT, 80 ALLOW, 443 ALLOW, default deny incoming
- Fail2ban: sshd + recidive jails
- Unattended-upgrades: security pocket, auto-reboot 04:00 UTC
- Swap: 4 GB, swappiness=10
- Time: UTC + NTP
- Docker CE 29.x official repo (NOT distro `docker.io`)
- Postgres bound to `127.0.0.1:5432` only
- Odoo not host-published (internal Docker network)
- Caddy on `:80` only public service
- Odoo: `list_db=False`, `db_filter=^nonprofit$`, `proxy_mode=True`, `without_demo=True`, workers=7
- Restic backups: daily 03:30 UTC, 7d/4w/6m retention, restore-tested
- Passwordless sudo grant: removed
