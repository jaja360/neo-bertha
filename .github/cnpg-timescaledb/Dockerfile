# CNPG-compatible PostgreSQL 16 image with TimescaleDB 2.x and Toolkit.
# Based on the official CloudNativePG operand image (keeps postgres UID/GID 26,
# PGDATA conventions and the instance-manager contract intact).
#
# NOTE: use the `-system` variant (Debian bookworm), which ships the
# `barman-cloud-*` binaries required by CNPG's in-tree `barmanObjectStore` WAL
# archiving. The `-standard-*` variants omit them, and the legacy bullseye
# `16.15` tag no longer builds (the bullseye PGDG apt repo is gone). A
# barman-less image silently breaks archiving and fills the WAL volume
# (see tracearr outage, Sep 2026).
FROM ghcr.io/cloudnative-pg/postgresql:16.15-system-bookworm@sha256:18db2679228571d798438a4cb9301bccd18acaf3c8a9f184e43f2d4aa5cdf507

USER root

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"; \
    mkdir -p /etc/apt/keyrings; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey \
      | gpg --dearmor --yes -o /etc/apt/keyrings/timescaledb.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/timescaledb.gpg] https://packagecloud.io/timescale/timescaledb/debian/ ${codename} main" \
      > /etc/apt/sources.list.d/timescaledb.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      timescaledb-2-postgresql-16=2.30.1* \
      timescaledb-2-loader-postgresql-16 \
      timescaledb-toolkit-postgresql-16=1:1.26.0*; \
    apt-get autoremove -y; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/*

# Guard: fail the build (and therefore the image roll) if the base image stops
# shipping the barman-cloud binaries that CNPG's in-tree `barmanObjectStore`
# WAL archiving needs. Keeps automated base bumps from silently re-breaking
# backups and filling the WAL volume.
RUN set -eux; \
    for b in \
      barman-cloud-wal-archive barman-cloud-wal-restore \
      barman-cloud-backup barman-cloud-restore; do \
      command -v "$b" >/dev/null 2>&1 || { echo "ERROR: $b not found in base image" >&2; exit 1; }; \
    done

USER 26
