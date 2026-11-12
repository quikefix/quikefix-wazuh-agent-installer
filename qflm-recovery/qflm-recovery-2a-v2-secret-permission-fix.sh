#!/usr/bin/env bash
set -u
set -o pipefail
umask 077
die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

PG="/opt/qflm/secrets/runtime-api/postgres_password"
RD="/opt/qflm/secrets/runtime-api/redis_password"

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -s "$PG" ] || die "postgres runtime secret missing"
[ -s "$RD" ] || die "redis runtime secret missing"

chmod 0444 "$PG" "$RD"
chown root:root "$PG" "$RD"

docker rm -f qflm-api-recovery2a >/dev/null 2>&1 || true

curl -fsSL https://raw.githubusercontent.com/quikefix/quikefix-wazuh-agent-installer/main/qflm-recovery/qflm-recovery-2a-source-scaffold.sh | bash
