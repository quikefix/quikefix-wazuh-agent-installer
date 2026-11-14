#!/usr/bin/env bash
# QFLM RECOVERY 7N4
# Controlled restart / final operations freeze.
# Restarts production containers only, validates persistence/health/automation,
# and writes final operations freeze manifest. No application/schema mutation.

set -u
set -o pipefail
umask 077

PROD_API="qflm-api"
PROD_GUI="qflm-admin-web-production"
PG="qflm-postgres"
REDIS="qflm-redis"
SIGNING="qflm-signing"

EXPECTED_API_IMAGE="qflm-api:recovery7k2-production"
EXPECTED_GUI_IMAGE="qflm-admin-web:recovery7l3-production"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/opt/qflm/backups/recovery7n4-final-operations-freeze-$STAMP"
REPORT="$OUT/recovery7n4-final-operations-freeze-report.txt"
MANIFEST="$OUT/qflm-final-operations-freeze.manifest"
FINAL_DB="$OUT/qflm-final-operations-freeze.dump"

PUBLIC_URL="https://lc.quikefix.info"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p "$OUT"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7N4"
echo " CONTROLLED RESTART / FINAL OPERATIONS FREEZE"
echo "======================================================"

echo
echo "=== 1. PRE-RESTART BASELINE ==="

API_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
GUI_IMAGE=$(docker inspect "$PROD_GUI" --format='{{.Config.Image}}') || die "production GUI missing"

[ "$API_IMAGE" = "$EXPECTED_API_IMAGE" ] || die "unexpected API image"
[ "$GUI_IMAGE" = "$EXPECTED_GUI_IMAGE" ] || die "unexpected GUI image"

for c in "$PROD_API" "$PROD_GUI" "$PG" "$REDIS" "$SIGNING"; do
  policy=$(docker inspect "$c" --format='{{.HostConfig.RestartPolicy.Name}}') || die "$c missing"
  [ "$policy" = "unless-stopped" ] || die "$c restart policy is $policy"
done

MIG=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
USERS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_users;' | xargs)
ROLES=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PERMS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
LICENSES=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM licenses;' | xargs)
INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM installations;' | xargs)

[ "$MIG" = 5 ] || die "unexpected migration count"
[ "$PERMS" = 22 ] || die "unexpected permission count"

echo "pre_restart_baseline=PASS"

echo
echo "=== 2. FINAL PRE-RESTART DATABASE BACKUP ==="

docker exec "$PG" pg_dump -U qflm -Fc -d qflm > "$FINAL_DB" || die "final database backup failed"
[ -s "$FINAL_DB" ] || die "final database backup empty"
cat "$FINAL_DB" | docker exec -i "$PG" pg_restore -l >/dev/null || die "final database backup validation failed"

DB_SHA=$(sha256sum "$FINAL_DB" | awk '{print $1}')

echo "final_db_backup=$FINAL_DB"
echo "final_db_backup_sha256=$DB_SHA"
echo "final_db_backup=PASS"

echo
echo "=== 3. CONTROLLED CONTAINER RESTART ==="

docker restart "$PG" >/dev/null || die "postgres restart failed"

for i in $(seq 1 60); do
  health=$(docker inspect "$PG" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' 2>/dev/null || true)
  [ "$health" = "healthy" ] && break
  sleep 1
done
[ "$(docker inspect "$PG" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}')" = "healthy" ] || die "postgres not healthy"

docker restart "$REDIS" >/dev/null || die "redis restart failed"
for i in $(seq 1 30); do
  health=$(docker inspect "$REDIS" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' 2>/dev/null || true)
  [ "$health" = "healthy" ] && break
  sleep 1
done
[ "$(docker inspect "$REDIS" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}')" = "healthy" ] || die "redis not healthy"

docker restart "$SIGNING" >/dev/null || die "signing restart failed"
sleep 2
[ "$(docker inspect "$SIGNING" --format='{{.State.Running}}')" = true ] || die "signing not running"

docker restart "$PROD_API" >/dev/null || die "API restart failed"

for i in $(seq 1 60); do
  if docker run --rm --network qflm_backend curlimages/curl:8.16.0 -fsS http://qflm-api:8080/health/ready >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

docker run --rm --network qflm_backend curlimages/curl:8.16.0 -fsS http://qflm-api:8080/health/live >/dev/null || die "API live failed after restart"
docker run --rm --network qflm_backend curlimages/curl:8.16.0 -fsS http://qflm-api:8080/health/ready >/dev/null || die "API ready failed after restart"

docker restart "$PROD_GUI" >/dev/null || die "GUI restart failed"
sleep 2
[ "$(docker inspect "$PROD_GUI" --format='{{.State.Running}}')" = true ] || die "GUI not running"

echo "controlled_restart=PASS"

echo
echo "=== 4. PUBLIC ROUTE VALIDATION ==="

for route in / /login /customers /products /licenses /installations /offline /security /audit /system; do
  code="000"
  for i in $(seq 1 30); do
    code=$(curl -L -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL$route" || true)
    [ "$code" = 200 ] && break
    sleep 1
  done
  [ "$code" = 200 ] || die "public route failed after restart: $route -> $code"
done

echo "public_routes=PASS"

echo
echo "=== 5. AUTOMATION VALIDATION ==="

systemctl is-enabled qflm-health-monitor.timer | grep -qx enabled || die "health timer not enabled"
systemctl is-active qflm-health-monitor.timer | grep -qx active || die "health timer not active"
systemctl is-enabled qflm-daily-backup.timer | grep -qx enabled || die "backup timer not enabled"
systemctl is-active qflm-daily-backup.timer | grep -qx active || die "backup timer not active"

systemctl start qflm-health-monitor.service || die "health monitor service failed"
systemctl show qflm-health-monitor.service -p Result --value | grep -qx success || die "health monitor not successful"

echo "automation_validation=PASS"

echo
echo "=== 6. BACKUP FRESHNESS VALIDATION ==="

LATEST_BACKUP=$(find /opt/qflm/backups/daily -maxdepth 1 -type f -name 'qflm-*.dump' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
[ -n "$LATEST_BACKUP" ] || die "no automated daily backup found"

cat "$LATEST_BACKUP" | docker exec -i "$PG" pg_restore -l >/dev/null || die "latest daily backup invalid"

LATEST_EPOCH=$(stat -c %Y "$LATEST_BACKUP")
AGE=$(( $(date +%s) - LATEST_EPOCH ))
[ "$AGE" -le 93600 ] || die "latest automated backup is stale"

LATEST_SHA=$(sha256sum "$LATEST_BACKUP" | awk '{print $1}')

echo "latest_backup=$LATEST_BACKUP"
echo "latest_backup_sha256=$LATEST_SHA"
echo "latest_backup_age_seconds=$AGE"
echo "backup_freshness=PASS"

echo
echo "=== 7. FINAL DATABASE / IMAGE INVARIANTS ==="

FINAL_MIG=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
FINAL_LICENSES=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM installations;' | xargs)

[ "$FINAL_MIG" = "$MIG" ] || die "migration count changed"
[ "$FINAL_USERS" = "$USERS" ] || die "user count changed"
[ "$FINAL_ROLES" = "$ROLES" ] || die "role count changed"
[ "$FINAL_PERMS" = "$PERMS" ] || die "permission count changed"
[ "$FINAL_LICENSES" = "$LICENSES" ] || die "license count changed"
[ "$FINAL_INSTALLATIONS" = "$INSTALLATIONS" ] || die "installation count changed"

[ "$(docker inspect "$PROD_API" --format='{{.Config.Image}}')" = "$API_IMAGE" ] || die "API image changed"
[ "$(docker inspect "$PROD_GUI" --format='{{.Config.Image}}')" = "$GUI_IMAGE" ] || die "GUI image changed"

echo "final_invariants=PASS"

echo
echo "=== 8. FINAL OPERATIONS FREEZE MANIFEST ==="

API_RESTARTS=$(docker inspect "$PROD_API" --format='{{.RestartCount}}')
GUI_RESTARTS=$(docker inspect "$PROD_GUI" --format='{{.RestartCount}}')
PG_RESTARTS=$(docker inspect "$PG" --format='{{.RestartCount}}')
REDIS_RESTARTS=$(docker inspect "$REDIS" --format='{{.RestartCount}}')
SIGNING_RESTARTS=$(docker inspect "$SIGNING" --format='{{.RestartCount}}')

cat > "$MANIFEST" <<EOF
QFLM_FINAL_OPERATIONS_FREEZE=RECOVERY_7N4
UTC=$STAMP
PUBLIC_URL=$PUBLIC_URL
PRODUCTION_API_IMAGE=$API_IMAGE
PRODUCTION_GUI_IMAGE=$GUI_IMAGE
API_RESTART_POLICY=$(docker inspect "$PROD_API" --format='{{.HostConfig.RestartPolicy.Name}}')
GUI_RESTART_POLICY=$(docker inspect "$PROD_GUI" --format='{{.HostConfig.RestartPolicy.Name}}')
POSTGRES_RESTART_POLICY=$(docker inspect "$PG" --format='{{.HostConfig.RestartPolicy.Name}}')
REDIS_RESTART_POLICY=$(docker inspect "$REDIS" --format='{{.HostConfig.RestartPolicy.Name}}')
SIGNING_RESTART_POLICY=$(docker inspect "$SIGNING" --format='{{.HostConfig.RestartPolicy.Name}}')
API_RESTART_COUNT=$API_RESTARTS
GUI_RESTART_COUNT=$GUI_RESTARTS
POSTGRES_RESTART_COUNT=$PG_RESTARTS
REDIS_RESTART_COUNT=$REDIS_RESTARTS
SIGNING_RESTART_COUNT=$SIGNING_RESTARTS
DATABASE_MIGRATIONS=$FINAL_MIG
USERS=$FINAL_USERS
ROLES=$FINAL_ROLES
PERMISSIONS=$FINAL_PERMS
LICENSES=$FINAL_LICENSES
INSTALLATIONS=$FINAL_INSTALLATIONS
FINAL_DB_BACKUP=$FINAL_DB
FINAL_DB_BACKUP_SHA256=$DB_SHA
LATEST_AUTOMATED_BACKUP=$LATEST_BACKUP
LATEST_AUTOMATED_BACKUP_SHA256=$LATEST_SHA
HEALTH_TIMER_ENABLED=$(systemctl is-enabled qflm-health-monitor.timer)
HEALTH_TIMER_ACTIVE=$(systemctl is-active qflm-health-monitor.timer)
BACKUP_TIMER_ENABLED=$(systemctl is-enabled qflm-daily-backup.timer)
BACKUP_TIMER_ACTIVE=$(systemctl is-active qflm-daily-backup.timer)
CONTROLLED_RESTART=PASS
PUBLIC_ROUTE_VALIDATION=PASS
AUTOMATION_VALIDATION=PASS
BACKUP_VALIDATION=PASS
DATABASE_MUTATION=NONE
STATUS=RECOVERY_7N4_FINAL_OPERATIONS_FROZEN
EOF

chmod 400 "$MANIFEST"

echo "final_operations_freeze_manifest=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7N4 FINAL OPERATIONS FREEZE PASSED"
echo "======================================================"
echo "CONTROLLED RESTART:                 PASS"
echo "POSTGRES:                           HEALTHY"
echo "REDIS:                              HEALTHY"
echo "SIGNING:                            HEALTHY"
echo "PRODUCTION API:                     HEALTHY"
echo "PRODUCTION GUI:                     HEALTHY"
echo "PUBLIC ROUTES:                      PASS"
echo "BOOT PERSISTENCE:                   PASS"
echo "HEALTH MONITORING:                  ENABLED / ACTIVE"
echo "DAILY BACKUPS:                      ENABLED / ACTIVE"
echo "FINAL DB BACKUP:                    $FINAL_DB"
echo "FINAL DB SHA256:                    $DB_SHA"
echo "FREEZE MANIFEST:                    $MANIFEST"
echo "REPORT:                             $REPORT"
echo "STATUS:                             RECOVERY_7N4_FINAL_OPERATIONS_FROZEN"
echo "NEXT: QFLM V1.0 FINAL RELEASE"
echo "======================================================"
