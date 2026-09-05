# CNPG-compatible PostgreSQL 16 image with TimescaleDB 2.x and Toolkit.
# Based on the official CloudNativePG operand image (keeps postgres UID/GID 26,
# PGDATA conventions and the instance-manager contract intact).
FROM ghcr.io/cloudnative-pg/postgresql:16.15

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
      timescaledb-2-postgresql-16=2.26.4* \
      timescaledb-2-loader-postgresql-16 \
      timescaledb-toolkit-postgresql-16=1:1.26.0*; \
    apt-get autoremove -y; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/*

USER 26
