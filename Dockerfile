FROM odoo:18.0

USER root

# OS packages needed by OCA Python deps that lack pure-python wheels.
# (libpq-dev intentionally NOT installed: odoo image already has psycopg2;
#  the postgres apt repo would force an incompatible libpq5 upgrade.)
#   - build-essential + pkg-config: native extension compiles
#   - libzbar0: runtime for pyzbar (server-ux/qr modules)
#   - poppler-utils: runtime for pdf2image (server-ux)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        libzbar0 \
        poppler-utils \
    && rm -rf /var/lib/apt/lists/*

# Install Python deps from all OCA repo requirements files, filtering out
# packages whose modules are NOT in the blueprint and which need fragile
# native builds (mysqlclient, pymssql — both only used by
# OCA/server-backend/base_external_dbsource_* which we don't install).
COPY requirements/ /tmp/requirements/
RUN set -ex \
    && cat /tmp/requirements/*.txt \
        | grep -vE '^(mysqlclient|pymssql)\b' \
        > /tmp/all-requirements.txt \
    && pip install --no-cache-dir --break-system-packages -r /tmp/all-requirements.txt \
    && rm -rf /tmp/requirements /tmp/all-requirements.txt

USER odoo
