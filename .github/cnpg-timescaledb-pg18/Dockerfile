# CNPG-compatible PostgreSQL 18 image with TimescaleDB 2.x and Toolkit.
#
# Base: official CloudNativePG operand image, Debian trixie. The `-standard`
# variant is enough now that WAL archiving is handled by the Barman Cloud
# plugin, which runs outside the operand pod, so the image no longer needs the
# `barman-cloud-*` binaries shipped by the `-system` variant.
#
# TimescaleDB publishes its apt packages per PostgreSQL patch release: the
# `~debian13-1807` build matches PostgreSQL 18.7. Base image and package
# versions must therefore be bumped together (the build workflow fails on a
# mismatch).
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
      timescaledb-2-postgresql-18=2.32.1~debian13-1807 \
      timescaledb-2-loader-postgresql-18=2.32.1~debian13-1807 \
      timescaledb-toolkit-postgresql-18=1:1.26.0~debian13; \
    apt-get autoremove -y; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/*

USER 26
