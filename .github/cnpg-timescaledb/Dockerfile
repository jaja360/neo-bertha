# CNPG-compatible PostgreSQL 16 image with TimescaleDB 2.32 and Toolkit.
#
# Purpose: bridge image for the PG 16 -> 18 major upgrade. TimescaleDB must be
# at a version whose library also exists in the PostgreSQL 18 image, otherwise
# pg_upgrade fails its "required libraries" check. This image carries
# TimescaleDB 2.32.1 for PostgreSQL 16, so the cluster can be updated to 2.32.1
# here, and the PG18 image (also 2.32.1) then accepts the upgrade.
#
# TimescaleDB publishes its apt packages per PostgreSQL patch release: the
# `~debian13-1616` build matches PostgreSQL 16.16. Base image and package
# versions must therefore be bumped together.
FROM ghcr.io/cloudnative-pg/postgresql:18.7-standard-trixie@sha256:1abcfd1cac6d53cda5185706819aab36d66a4ed88e99fc2ae44ab0826aa99f00

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
      timescaledb-2-postgresql-16=2.32.1~debian13-1616 \
      timescaledb-2-loader-postgresql-16=2.32.1~debian13-1616 \
      timescaledb-toolkit-postgresql-16=1:1.26.0~debian13; \
    apt-get autoremove -y; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/*

USER 26
