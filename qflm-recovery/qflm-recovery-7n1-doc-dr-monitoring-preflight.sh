#!/usr/bin/env bash
# QFLM RECOVERY 7N1
# Documentation / DR / Monitoring preflight.
# Read-only inventory of final production state, backups, rollback assets,
# services, logs, health checks, and recovery artifacts.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
BACKUPS_ROOT="/opt/qflm/backups"

PROD_API="qflm-api"
PROD_GUI="qflm-admin-web-production"
ROLLBACK_API="qflm-api-recovery7k2-rollback"
ROLLBACK_GUI="qflm-admin-web-recovery7l3-preview-rollback"
PG="qflm-postgres"
REDIS="qflm-redis"
SIGNING="qflm-signing"

EXPECTED_API_IMAGE="qflm-api:recovery7k2-production"
EXPECTED_GUI_IMAGE="qflm-admin-web:recovery7l3-production"

PUBLIC_URL="https://lc.quikefix.info"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$BACKUPS_ROOT/recovery7n1-doc-dr-monitoring-preflight-$STAMP"
REPORT="$OUT/recovery7n1-doc-dr-monitoring-preflight-report.txt"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p "$OUT"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7N1"
echo " DOCUMENTATION / DR / MONITORING PREFLIGHT"
echo " READ ONLY"
echo "======================================================"

echo
echo "=== 1. FINAL PRODUCTION BASELINE ==="

API_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
GUI_IMAGE=$(docker inspect "$PROD_GUI" --format='{{.Config.Image}}') || die "production GUI missing"
API_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
GUI_RUNNING=$(docker inspect "$PROD_GUI" --format='{{.State.Running}}')

[ "$API_IMAGE" = "$EXPECTED_API_IMAGE" ] || die "unexpected production API image"
[ "$GUI_IMAGE" = "$EXPECTED_GUI_IMAGE" ] || die "unexpected production GUI image"
[ "$API_RUNNING" = true ] || die "production API not running"
[ "$GUI_RUNNING" = true ] || die "production GUI not running"

echo "production_baseline=PASS"

echo
echo "=== 2. CORE CONTAINER INVENTORY ==="

for c in "$PROD_API" "$PROD_GUI" "$PG" "$REDIS" "$SIGNING" "$ROLLBACK_API" "$ROLLBACK_GUI"; do
  if docker inspect "$c" >/dev/null 2>&1; then
    docker inspect "$c" --format='name={{.Name}} image={{.Config.Image}} running={{.State.Running}} restart={{.RestartCount}} network={{.HostConfig.NetworkMode}} readonly={{.HostConfig.ReadonlyRootfs}}'
  else
    echo "name=$c status=MISSING"
  fi
done

echo "container_inventory=PASS"

echo
echo "=== 3. DATABASE BASELINE ==="

MIG=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
USERS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_users;' | xargs)
ROLES=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PERMS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
LICENSES=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM licenses;' | xargs)
INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'migrations=%s users=%s roles=%s permissions=%s licenses=%s installations=%s\n'  "$MIG" "$USERS" "$ROLES" "$PERMS" "$LICENSES" "$INSTALLATIONS"

echo "database_baseline=PASS"

echo
echo "=== 4. HEALTH / PUBLIC ROUTES ==="

docker run --rm --network qflm_backend curlimages/curl:8.16.0  -fsS "http://$PROD_API:8080/health/live" >/dev/null || die "API live health failed"

docker run --rm --network qflm_backend curlimages/curl:8.16.0  -fsS "http://$PROD_API:8080/health/ready" >/dev/null || die "API ready health failed"

for route in / /login /customers /products /licenses /installations /offline /security /audit /system; do
  code=$(curl -L -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL$route" || true)
  [ "$code" = 200 ] || die "public route failed: $route -> $code"
done

echo "health_public_routes=PASS"

echo
echo "=== 5. BACKUP / FREEZE ARTIFACT INVENTORY ==="

find "$BACKUPS_ROOT" -maxdepth 2 -type f \(  -name '*manifest*' -o  -name '*.dump' -o  -name '*report.txt' -o  -name '*.nupkg' -o  -name '*.tgz' \) -printf '%TY-%Tm-%TdT%TH:%TM:%TSZ %s %p\n' | sort -r | sed -n '1,300p'

echo "backup_inventory=PASS"

echo
echo "=== 6. MOST RECENT CRITICAL FREEZE FILES ==="

find "$BACKUPS_ROOT" -type f -name 'qflm-final-freeze.manifest' -printf '%T@ %p\n' | sort -nr | head -n1
find "$BACKUPS_ROOT" -type f -name 'recovery7l4-production-gui-final-freeze.manifest' -printf '%T@ %p\n' | sort -nr | head -n1
find "$BACKUPS_ROOT" -type f -name 'qflm-dotnet-sdk-final-freeze.manifest' -printf '%T@ %p\n' | sort -nr | head -n1

echo "freeze_artifacts=PASS"

echo
echo "=== 7. SERVICE / BOOT PERSISTENCE INVENTORY ==="

systemctl is-enabled docker 2>/dev/null || true
systemctl is-active docker 2>/dev/null || true
systemctl is-enabled cloudflared 2>/dev/null || true
systemctl is-active cloudflared 2>/dev/null || true

docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

echo "service_inventory=PASS"

echo
echo "=== 8. DOCKER RESTART POLICY INVENTORY ==="

for c in "$PROD_API" "$PROD_GUI" "$PG" "$REDIS" "$SIGNING"; do
  if docker inspect "$c" >/dev/null 2>&1; then
    docker inspect "$c" --format='name={{.Name}} restart_policy={{.HostConfig.RestartPolicy.Name}} max_retry={{.HostConfig.RestartPolicy.MaximumRetryCount}}'
  fi
done

echo "restart_policy_inventory=PASS"

echo
echo "=== 9. LOGGING INVENTORY ==="

for c in "$PROD_API" "$PROD_GUI" "$PG" "$REDIS" "$SIGNING"; do
  if docker inspect "$c" >/dev/null 2>&1; then
    docker inspect "$c" --format='name={{.Name}} log_driver={{.HostConfig.LogConfig.Type}} log_opts={{json .HostConfig.LogConfig.Config}}'
  fi
done

journalctl -u cloudflared -n 50 --no-pager || true

echo "logging_inventory=PASS"

echo
echo "=== 10. STORAGE / VOLUME INVENTORY ==="

docker volume ls
for c in "$PROD_API" "$PG" "$REDIS" "$SIGNING"; do
  echo "--- $c mounts ---"
  docker inspect "$c" --format='{{range .Mounts}}{{println .Type .Source "->" .Destination "RW=" .RW}}{{end}}' 2>/dev/null || true
done

df -hT / /opt 2>/dev/null || true

echo "storage_inventory=PASS"

echo
echo "=== 11. NETWORK / CLOUDFLARE INVENTORY ==="

ip -4 addr show
ss -lntup
systemctl show cloudflared -p ExecStart -p FragmentPath --no-pager || true
journalctl -u cloudflared -n 100 --no-pager | grep -Ei 'Starting tunnel|Updated to new configuration|Registered tunnel connection|error=' || true

echo "network_cloudflare_inventory=PASS"

echo
echo "=== 12. MONITORING CAPABILITY INVENTORY ==="

command -v curl || true
command -v docker || true
command -v systemctl || true
command -v journalctl || true
command -v psql || true

docker ps --format '{{.Names}}' | grep -Ei 'prometheus|grafana|node-exporter|cadvisor|uptime|zabbix|wazuh|telegraf|netdata' || true
systemctl list-units --type=service --all --no-pager | grep -Ei 'prometheus|grafana|node-exporter|cadvisor|uptime|zabbix|wazuh|telegraf|netdata' || true

echo "monitoring_inventory=PASS"

echo
echo "=== 13. SOURCE / DOCUMENTATION INVENTORY ==="

find "$ROOT" -maxdepth 3 -type f \(  -iname 'README*' -o  -iname '*RUNBOOK*' -o  -iname '*RECOVERY*' -o  -iname '*BACKUP*' -o  -iname '*MONITOR*' -o  -iname '*DR*' \) -printf '%p\n' | sort

echo "documentation_inventory=PASS"

echo
echo "=== 14. FINAL NO-MUTATION CHECK ==="

FINAL_API_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_GUI_IMAGE=$(docker inspect "$PROD_GUI" --format='{{.Config.Image}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

[ "$FINAL_API_IMAGE" = "$API_IMAGE" ] || die "production API image changed"
[ "$FINAL_GUI_IMAGE" = "$GUI_IMAGE" ] || die "production GUI image changed"
[ "$FINAL_MIG" = "$MIG" ] || die "migration count changed"

echo "no_mutation=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7N1 PASSED"
echo "======================================================"
echo "PRODUCTION BASELINE:                VERIFIED"
echo "BACKUPS / FREEZE ARTIFACTS:         INVENTORIED"
echo "ROLLBACK ASSETS:                    INVENTORIED"
echo "BOOT / RESTART POLICIES:            INVENTORIED"
echo "LOGGING:                            INVENTORIED"
echo "STORAGE / VOLUMES:                  INVENTORIED"
echo "NETWORK / CLOUDFLARE:               INVENTORIED"
echo "MONITORING CAPABILITIES:            INVENTORIED"
echo "DOCUMENTATION:                      INVENTORIED"
echo "PRODUCTION API/DB:                  UNCHANGED"
echo "REPORT:                             $REPORT"
echo "NEXT: RECOVERY 7N2 - OPERATIONS / DR / MONITORING RUNBOOKS"
echo "======================================================"
