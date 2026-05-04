#!/usr/bin/env bash
# Bootstrap a fresh deployment of the Odoo 18 nonprofit template.
#
#   - Generates random secrets (POSTGRES_PASSWORD, ODOO_ADMIN_PASSWD)
#   - Renders .env and odoo/config/odoo.conf from their .template files
#   - Clones every OCA repo at the SHA pinned in oca-versions/<repo>.sha
#   - Creates runtime data directories with the right ownership/modes
#   - Prints next steps
#
# Run from the repo root after `git clone`:
#     ./bin/init.sh
#
# You will be prompted for sudo to chown files to the odoo container's
# uid (100). That's intrinsic to a Docker bind-mount setup; we don't avoid it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

red()    { printf "\033[31m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }

# ---- Pre-flight ------------------------------------------------------------

if [ -f .env ] || [ -f odoo/config/odoo.conf ]; then
    red "ERROR: .env or odoo/config/odoo.conf already exists."
    echo "       This script bootstraps a *fresh* deployment."
    echo "       If you really want to re-init, remove those files first:"
    echo "           rm .env odoo/config/odoo.conf"
    exit 1
fi

for cmd in openssl git sudo sed; do
    command -v "$cmd" >/dev/null 2>&1 || { red "missing dependency: $cmd"; exit 1; }
done

bold "== Odoo 18 nonprofit template — init =="
echo "Repo root: $REPO_ROOT"
echo ""

# ---- 1) Generate secrets ---------------------------------------------------

echo "== generating secrets"
gen_secret() { openssl rand -base64 32 | tr -d '/+=' | cut -c1-32; }
POSTGRES_PASSWORD=$(gen_secret)
ODOO_ADMIN_PASSWD=$(gen_secret)
green "  ok POSTGRES_PASSWORD generated (32 chars)"
green "  ok ODOO_ADMIN_PASSWD generated (32 chars)"

# ---- 2) Render templates ---------------------------------------------------

echo ""
echo "== rendering .env"
sed -e "s|__POSTGRES_PASSWORD__|${POSTGRES_PASSWORD}|" \
    -e "s|__ODOO_ADMIN_PASSWD__|${ODOO_ADMIN_PASSWD}|" \
    .env.template > .env
chmod 600 .env
green "  ok .env (mode 600)"

echo ""
echo "== rendering odoo/config/odoo.conf"
sed -e "s|__POSTGRES_PASSWORD__|${POSTGRES_PASSWORD}|" \
    -e "s|__ODOO_ADMIN_PASSWD__|${ODOO_ADMIN_PASSWD}|" \
    odoo/config/odoo.conf.template > odoo/config/odoo.conf
chmod 640 odoo/config/odoo.conf
green "  ok odoo/config/odoo.conf (mode 640)"

# ---- 3) Clone OCA repos at pinned SHAs ------------------------------------

echo ""
echo "== cloning OCA repos at pinned SHAs"
mkdir -p odoo/addons
shopt -s nullglob
SHA_FILES=(oca-versions/*.sha)
if [ "${#SHA_FILES[@]}" -eq 0 ]; then
    red "ERROR: no SHA pins found in oca-versions/"
    exit 1
fi

for sha_file in "${SHA_FILES[@]}"; do
    repo=$(basename "$sha_file" .sha)
    sha=$(tr -d '[:space:]' < "$sha_file")
    if [ -d "odoo/addons/${repo}/.git" ]; then
        echo "  - skipping ${repo} (already cloned)"
        continue
    fi
    printf "  - %-32s @ %s ... " "${repo}" "${sha:0:7}"
    if git clone --quiet "https://github.com/OCA/${repo}.git" "odoo/addons/${repo}" 2>/dev/null; then
        ( cd "odoo/addons/${repo}" && git checkout --quiet "$sha" )
        green "ok"
    else
        red "FAILED"
        echo "    Try manually: git clone https://github.com/OCA/${repo}.git odoo/addons/${repo}"
        exit 1
    fi
done

# ---- 4) Create runtime data dirs ------------------------------------------

echo ""
echo "== creating runtime data directories"
mkdir -p odoo/data postgres/data caddy/data caddy/config

# ---- 5) Sudo-required ownership fixes -------------------------------------

echo ""
yellow "== sudo step: chowning bind-mount paths to uid 100 (odoo container user)"
yellow "   you will be prompted for your sudo password"
sudo chown 100:101 odoo/config/odoo.conf
sudo chown -R 100:101 odoo/addons
sudo chown 100:101 odoo/data
sudo chmod 750 odoo/data
green "  ok odoo/config/odoo.conf, odoo/addons, odoo/data"

# ---- 6) Done ---------------------------------------------------------------

echo ""
bold "================================================================"
bold " Init complete. Next steps:"
bold "================================================================"
cat <<EOF

 1. Build the custom image (5-10 min for first build):

      sudo docker build -t odoo-nonprofit-template:18.0-latest .

 2. Start the stack:

      sudo docker compose --env-file .env up -d

 3. Initialize the 'nonprofit' database:

      sudo docker compose --env-file .env stop odoo
      sudo docker compose --env-file .env run --rm --no-deps odoo \\
          odoo -c /etc/odoo/odoo.conf -d nonprofit -i base \\
               --without-demo=all --stop-after-init --load-language=en_US
      sudo docker compose --env-file .env start odoo

    Default admin login is 'admin' / 'admin'. Change it on first login OR
    reset programmatically — see docs/CLAUDE.md.

 4. Install OCA module layers (see docs/CLAUDE.md "Modules installed by
    layer" section for the canonical 7-layer install order).

 5. Set up restic backups — copy the backup script + systemd units pattern
    from docs/SESSION-LOG-2026-05-04.md "Phase 2" section. Off-site backup
    target is YOUR responsibility per docs/PRODUCTION-CHECKLIST.md.

 6. **Read docs/PRODUCTION-CHECKLIST.md before going live** — 23 MUST items.

================================================================
 Secrets are now in .env and odoo/config/odoo.conf.
 Both are .gitignored. NEVER commit them.
================================================================
EOF
