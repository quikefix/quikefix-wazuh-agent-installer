#!/usr/bin/env bash
# QFLM RECOVERY 1
# PostgreSQL 17 + Redis 8 + qflm_backend + local runtime secret foundation.

set -u
set -o pipefail
umask 077

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

ROOT="/opt/qflm"
COMPOSE="$ROOT/compose/compose.yml"
SECRETS="$ROOT/secrets/runtime-api"

echo "======================================================"
echo " QFLM RECOVERY 1 - DATA SERVICES + SECRET FOUNDATION"
echo "======================================================"

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v docker >/dev/null || die "docker missing"
docker compose version >/dev/null 2>&1 || die "docker compose missing"
systemctl is-active --quiet docker || die "docker not active"
[ -d "$ROOT" ] || die "/opt/qflm missing"

echo
echo "=== 1. SECRET FOUNDATION ==="

install -d -m 0700 "$SECRETS"

PG_SECRET="$SECRETS/postgres_password"
REDIS_SECRET="$SECRETS/redis_password"

if [ ! -s "$PG_SECRET" ]; then
    openssl rand -base64 48 | tr -d '\n' > "$PG_SECRET"
fi
if [ ! -s "$REDIS_SECRET" ]; then
    openssl rand -base64 48 | tr -d '\n' > "$REDIS_SECRET"
fi

chmod 600 "$PG_SECRET" "$REDIS_SECRET"
chown root:root "$PG_SECRET" "$REDIS_SECRET"

[ "$(stat -c '%a' "$SECRETS")" = 700 ] || die "runtime secret dir mode invalid"
[ "$(stat -c '%a' "$PG_SECRET")" = 600 ] || die "postgres secret mode invalid"
[ "$(stat -c '%a' "$REDIS_SECRET")" = 600 ] || die "redis secret mode invalid"

echo "runtime_secrets=PASS"

echo
echo "=== 2. DOCKER NETWORK ==="

docker network inspect qflm_backend >/dev/null 2>&1 ||   docker network create --driver bridge qflm_backend >/dev/null

docker network inspect qflm_backend >/dev/null 2>&1 || die "qflm_backend missing"
echo "qflm_backend=PASS"

echo
echo "=== 3. WRITE DATA-SERVICE COMPOSE ==="

cat > "$COMPOSE" <<'YAML'
services:
  postgres:
    image: postgres:17
    container_name: qflm-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: qflm
      POSTGRES_DB: qflm
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
      TZ: UTC
    secrets:
      - postgres_password
    volumes:
      - qflm_postgres_data:/var/lib/postgresql/data
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U qflm -d qflm"]
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 10s
    security_opt:
      - no-new-privileges:true

  redis:
    image: redis:8
    container_name: qflm-redis
    restart: unless-stopped
    command:
      - sh
      - -c
      - exec redis-server --appendonly yes --requirepass "$$(cat /run/secrets/redis_password)"
    secrets:
      - redis_password
    volumes:
      - qflm_redis_data:/data
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"$$(cat /run/secrets/redis_password)\" ping 2>/dev/null | grep -q PONG"]
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 5s
    security_opt:
      - no-new-privileges:true

networks:
  backend:
    name: qflm_backend
    external: true

volumes:
  qflm_postgres_data:
    name: qflm_postgres_data
  qflm_redis_data:
    name: qflm_redis_data

secrets:
  postgres_password:
    file: /opt/qflm/secrets/runtime-api/postgres_password
  redis_password:
    file: /opt/qflm/secrets/runtime-api/redis_password
YAML

chmod 600 "$COMPOSE"
docker compose -f "$COMPOSE" config >/dev/null || die "compose validation failed"
echo "compose_contract=PASS"

echo
echo "=== 4. START POSTGRESQL + REDIS ==="

docker compose -f "$COMPOSE" pull
docker compose -f "$COMPOSE" up -d

echo
echo "=== 5. WAIT FOR HEALTH ==="

for i in $(seq 1 60); do
    PG_STATUS="$(docker inspect qflm-postgres --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    RD_STATUS="$(docker inspect qflm-redis --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    if [ "$PG_STATUS" = healthy ] && [ "$RD_STATUS" = healthy ]; then
        break
    fi
    sleep 2
done

PG_STATUS="$(docker inspect qflm-postgres --format='{{.State.Health.Status}}' 2>/dev/null || true)"
RD_STATUS="$(docker inspect qflm-redis --format='{{.State.Health.Status}}' 2>/dev/null || true)"

echo "postgres_status=$PG_STATUS"
echo "redis_status=$RD_STATUS"

[ "$PG_STATUS" = healthy ] || { docker logs --tail 120 qflm-postgres || true; die "postgres unhealthy"; }
[ "$RD_STATUS" = healthy ] || { docker logs --tail 120 qflm-redis || true; die "redis unhealthy"; }

echo "data_service_health=PASS"

echo
echo "=== 6. DATABASE CONNECTIVITY ==="

PG_RESULT="$(docker exec qflm-postgres psql -U qflm -d qflm -tAc 'SELECT 1;' | xargs)"
[ "$PG_RESULT" = 1 ] || die "postgres SELECT 1 failed"

PG_VERSION="$(docker exec qflm-postgres psql -U qflm -d qflm -tAc 'SHOW server_version;' | xargs)"
echo "postgres_version=$PG_VERSION"

echo "postgres_connectivity=PASS"

echo
echo "=== 7. REDIS AUTHENTICATED CONNECTIVITY ==="

REDIS_PASS="$(cat "$REDIS_SECRET")"
REDIS_RESULT="$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" qflm-redis redis-cli ping 2>/dev/null | xargs)"
unset REDIS_PASS

[ "$REDIS_RESULT" = PONG ] || die "redis authenticated PING failed"
echo "redis_connectivity=PASS"

echo
echo "=== 8. EXPOSURE + NETWORK CHECK ==="

PG_PORTS="$(docker inspect qflm-postgres --format='{{json .HostConfig.PortBindings}}')"
RD_PORTS="$(docker inspect qflm-redis --format='{{json .HostConfig.PortBindings}}')"

echo "postgres_host_ports=$PG_PORTS"
echo "redis_host_ports=$RD_PORTS"

[ "$PG_PORTS" = null ] || [ "$PG_PORTS" = '{}' ] || die "postgres has host published ports"
[ "$RD_PORTS" = null ] || [ "$RD_PORTS" = '{}' ] || die "redis has host published ports"

docker inspect qflm-postgres --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' | grep -q qflm_backend   || die "postgres not on qflm_backend"
docker inspect qflm-redis --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' | grep -q qflm_backend   || die "redis not on qflm_backend"

echo "private_data_services=PASS"

echo
echo "=== 9. FINAL STATUS ==="

docker ps --filter 'name=^/qflm-postgres$' --filter 'name=^/qflm-redis$'   --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

echo
echo "secret_values_displayed=NO"
echo "compose=$COMPOSE"
echo "runtime_secret_dir=$SECRETS"

echo
echo "======================================================"
echo " QFLM RECOVERY 1 PASSED"
echo "======================================================"
echo "POSTGRESQL 17:       PASS"
echo "REDIS 8:             PASS"
echo "QFLM BACKEND NETWORK:PASS"
echo "RUNTIME SECRETS:     PASS"
echo "HOST PORTS:          NONE"
echo "NEXT: RECOVERY 2 - QFLM SOURCE/APPLICATION RECONSTRUCTION"
echo "======================================================"
