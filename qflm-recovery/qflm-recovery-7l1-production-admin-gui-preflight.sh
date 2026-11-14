#!/usr/bin/env bash
# QFLM RECOVERY 7L1
# Permanent Production Admin GUI preflight.
# Read-only discovery and readiness checks. No DNS, tunnel, production GUI, or API mutation.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
PG="qflm-postgres"
PROD_DB="qflm"
PROD_API="qflm-api"
PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"
NET="qflm_backend"

EXPECTED_PROD_IMAGE="qflm-api:recovery7k2-production"
EXPECTED_PREVIEW_API_IMAGE="qflm-api:recovery7i2-candidate"
EXPECTED_PREVIEW_GUI_IMAGE="qflm-admin-web:recovery7j3-preview"

ORIGIN_IFACE="ens18"
PREVIEW_PORT="8088"
PREVIEW_URL="https://lc.quikefix.info"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7l1-production-gui-preflight-$STAMP"
REPORT="$BACKUP/recovery7l1-production-gui-preflight-report.txt"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7L1"
echo " PERMANENT PRODUCTION ADMIN GUI PREFLIGHT"
echo " READ ONLY"
echo "======================================================"

echo
echo "=== 1. FINAL FROZEN PRODUCTION BASELINE ==="

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PROD_RESTARTS=$(docker inspect "$PROD_API" --format='{{.RestartCount}}')

[ "$PROD_IMAGE" = "$EXPECTED_PROD_IMAGE" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$PROD_RESTARTS" = 0 ] || die "production API restart count is not zero"

echo "production_final_frozen_baseline=PASS"

echo
echo "=== 2. DATABASE BASELINE ==="

MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

[ "$MIG" = 5 ] || die "unexpected migration count"
[ "$USERS" -ge 1 ] || die "no auth users"
[ "$ROLES" -ge 1 ] || die "no auth roles"
[ "$PERMS" = 22 ] || die "unexpected permission count"

printf 'migrations=%s users=%s roles=%s permissions=%s\n' "$MIG" "$USERS" "$ROLES" "$PERMS"
echo "database_baseline=PASS"

echo
echo "=== 3. PREVIEW GUI BASELINE ==="

PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)

[ "$PREVIEW_API_IMAGE" = "$EXPECTED_PREVIEW_API_IMAGE" ] || die "preview API image changed"
[ "$PREVIEW_GUI_IMAGE" = "$EXPECTED_PREVIEW_GUI_IMAGE" ] || die "preview GUI image changed"
[ "$PREVIEW_API_RUNNING" = true ] || die "preview API not running"
[ "$PREVIEW_GUI_RUNNING" = true ] || die "preview GUI not running"

echo "preview_gui_baseline=PASS"

echo
echo "=== 4. CURRENT LAN + LISTENER INVENTORY ==="

HOST_IP=$(ip -4 -o addr show dev "$ORIGIN_IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
[ -n "$HOST_IP" ] || die "no IPv4 address on $ORIGIN_IFACE"

printf 'origin_interface=%s origin_ip=%s\n' "$ORIGIN_IFACE" "$HOST_IP"
ss -lntp | sed -n '1,240p'

echo "listener_inventory=PASS"

echo
echo "=== 5. CLOUDFLARE TUNNEL INVENTORY ==="

if command -v cloudflared >/dev/null 2>&1; then
    echo "cloudflared_binary=$(command -v cloudflared)"
    cloudflared --version || true
else
    echo "cloudflared_binary=NOT_IN_PATH"
fi

docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}' | grep -Ei 'cloudflared|cloudflare' || true

find /etc /opt /root -maxdepth 4 -type f \( -name 'config.yml' -o -name 'config.yaml' -o -name '*.json' \) 2>/dev/null \
 | grep -Ei 'cloudflared|cloudflare|tunnel' \
 | sed -n '1,160p' || true

echo "cloudflare_inventory=PASS"

echo
echo "=== 6. GUI SOURCE / ROUTE INVENTORY ==="

[ -f "$ROOT/src/QFLM.AdminWeb/src/App.tsx" ] || die "GUI App.tsx missing"

grep -nE 'path=|Route' "$ROOT/src/QFLM.AdminWeb/src/App.tsx" | sed -n '1,240p'

for route in customers products licenses installations offline security audit system; do
    grep -Fq "path=\"$route\"" "$ROOT/src/QFLM.AdminWeb/src/App.tsx" || die "missing GUI route: $route"
done

echo "gui_route_inventory=PASS"

echo
echo "=== 7. PRODUCTION API PRIVATE REACHABILITY ==="

docker run --rm --network "$NET" curlimages/curl:8.16.0  -fsS "http://$PROD_API:8080/health/ready" >/dev/null  || die "production API ready health failed"

PROD_PORTS=$(docker inspect "$PROD_API" --format='{{json .NetworkSettings.Ports}}')
case "$PROD_PORTS" in
  "{}"|"null") ;;
  *) die "production API exposes host ports" ;;
esac

echo "production_api_private_reachability=PASS"

echo
echo "=== 8. PREVIEW PUBLIC ROUTES ==="

for route in / /login /customers /products /licenses /installations /offline /security /audit /system; do
    CODE=$(curl -L -s -o /dev/null -w '%{http_code}' "$PREVIEW_URL$route" || true)
    [ "$CODE" = 200 ] || die "preview public route failed: $route -> $CODE"
done

echo "preview_public_routes=PASS"

echo
echo "=== 9. GUI BUILD READINESS ==="

docker run --rm  -v "$ROOT/src/QFLM.AdminWeb:/src"  -w /src  node:24-bookworm-slim  sh -lc 'npm install --no-audit --no-fund >/dev/null && npm run build'  || die "GUI build failed"

echo "gui_build_readiness=PASS"

echo
echo "=== 10. NO-MUTATION CHECK ==="

FINAL_PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}')
FINAL_PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}')

[ "$FINAL_PROD_IMAGE" = "$PROD_IMAGE" ] || die "production API image changed"
[ "$FINAL_PROD_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_PREVIEW_API_IMAGE" = "$PREVIEW_API_IMAGE" ] || die "preview API image changed"
[ "$FINAL_PREVIEW_GUI_IMAGE" = "$PREVIEW_GUI_IMAGE" ] || die "preview GUI image changed"

echo "no_mutation=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7L1 PASSED"
echo "======================================================"
echo "PRODUCTION API:                     FINAL FROZEN / HEALTHY"
echo "DATABASE:                           VERIFIED"
echo "PREVIEW GUI:                        VERIFIED"
echo "GUI SOURCE ROUTES:                  VERIFIED"
echo "GUI BUILD:                          PASS"
echo "CLOUDFLARE INVENTORY:               CAPTURED"
echo "PRODUCTION/PREVIEW:                 UNCHANGED"
echo "REPORT:                             $REPORT"
echo "NEXT: RECOVERY 7L2 - PERMANENT PRODUCTION GUI ISOLATED DEPLOYMENT"
echo "======================================================"
