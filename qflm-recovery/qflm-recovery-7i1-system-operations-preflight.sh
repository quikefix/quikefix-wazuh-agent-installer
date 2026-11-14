#!/usr/bin/env bash
# QFLM RECOVERY 7I1
# System / Operations GUI/API preflight - read-only.
set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API="$ROOT/src/QFLM.Api"
APP="$ROOT/src/QFLM.Application"
INFRA="$ROOT/src/QFLM.Infrastructure"
DOMAIN="$ROOT/src/QFLM.Domain"
GUI="$ROOT/src/QFLM.AdminWeb"

PG="qflm-postgres"
PROD_API="qflm-api"
PROD_DB="qflm"
PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="/opt/qflm/backups/recovery7i1-system-operations-preflight-$STAMP.txt"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p /opt/qflm/backups
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7I1"
echo " SYSTEM / OPERATIONS GUI/API PREFLIGHT"
echo " READ ONLY"
echo "======================================================"

echo
echo "=== 1. PRODUCTION SAFETY BASELINE ==="
PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
[ "$PROD_IMAGE" = "qflm-api:recovery6f3-candidate" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"
printf 'prod_image=%s running=%s migrations=%s\n' "$PROD_IMAGE" "$PROD_RUNNING" "$MIG"
echo "production_baseline=PASS"

echo
echo "=== 2. CURRENT PREVIEW BASELINE ==="
PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
[ "$PREVIEW_API_RUNNING" = true ] || die "preview API not running"
[ "$PREVIEW_GUI_RUNNING" = true ] || die "preview GUI not running"
[ "$PREVIEW_API_IMAGE" = "qflm-api:recovery7h2-candidate" ] || die "unexpected preview API image"
[ "$PREVIEW_GUI_IMAGE" = "qflm-admin-web:recovery7h3-preview" ] || die "unexpected preview GUI image"
printf 'preview_api=%s preview_gui=%s api_image=%s gui_image=%s\n' "$PREVIEW_API_RUNNING" "$PREVIEW_GUI_RUNNING" "$PREVIEW_API_IMAGE" "$PREVIEW_GUI_IMAGE"

HOST_IP=$(ip -4 -o addr show dev ens18 scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
[ -n "$HOST_IP" ] || die "no IPv4 address found on ens18"
for route in / /security /offline /audit; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST_IP:8088$route" || true)
  [ "$CODE" = 200 ] || die "preview route failed: $route -> $CODE"
done
echo "preview_baseline=PASS"

echo
echo "=== 3. CONTROLLER INVENTORY ==="
find "$API/Controllers" -maxdepth 1 -type f -name '*.cs' -print | sort
grep -RniE --exclude-dir=bin --exclude-dir=obj 'System|Operation|Operations|Health|Status|Runtime|Service|Environment|Version|Diagnostics|Metrics|Jobs|Queue|Background|Maintenance' "$API/Controllers" | sed -n '1,520p' || true
echo "controller_inventory=PASS"

echo
echo "=== 4. APPLICATION / INFRASTRUCTURE INVENTORY ==="
grep -RniE --exclude-dir=bin --exclude-dir=obj 'System|Operation|Operations|Health|Status|Runtime|Service|Environment|Version|Diagnostics|Metrics|Jobs|Queue|Background|Maintenance' "$APP" "$INFRA" "$DOMAIN" | sed -n '1,620p' || true
echo "operations_service_inventory=PASS"

echo
echo "=== 5. DATABASE OPERATIONS TABLE INVENTORY ==="
docker exec "$PG" psql -U qflm -d "$PROD_DB" -P pager=off -c "
SELECT tablename
FROM pg_tables
WHERE schemaname='public'
AND (
 tablename ILIKE '%job%' OR
 tablename ILIKE '%queue%' OR
 tablename ILIKE '%event%' OR
 tablename ILIKE '%health%' OR
 tablename ILIKE '%status%' OR
 tablename ILIKE '%operation%' OR
 tablename ILIKE '%history%'
)
ORDER BY tablename;"
echo "database_inventory=PASS"

echo
echo "=== 6. AUTHORIZATION PERMISSIONS ==="
docker exec "$PG" psql -U qflm -d "$PROD_DB" -P pager=off -c "
SELECT code,name,category,description,is_system
FROM auth_permissions
ORDER BY category,code;"

echo
echo "=== 7. CURRENT AUTHORIZATION POLICIES ==="
grep -nA40 -B6 'AddAuthorization' "$API/Program.cs" | sed -n '1,180p'

echo
echo "=== 8. HEALTH / STATUS ENDPOINTS ==="
grep -RniE --exclude-dir=bin --exclude-dir=obj 'health/|MapHealthChecks|HealthCheck|ready|live|status' "$API" | sed -n '1,420p' || true

echo
echo "=== 9. GUI ROUTES + PLACEHOLDERS ==="
grep -nE 'path=|PlaceholderPage' "$GUI/src/App.tsx" | sed -n '1,260p'

echo
echo "=== 10. GUI PAGE INVENTORY ==="
find "$GUI/src/pages" -maxdepth 1 -type f -name '*.tsx' -printf '%f\n' | sort

echo
echo "=== 11. GUI SYSTEM / OPERATIONS SURFACES ==="
grep -RniE --exclude-dir=node_modules 'system|operation|health|status|runtime|service|version|diagnostic|metric|job|queue|maintenance' "$GUI/src" | sed -n '1,520p' || true

echo
echo "=== 12. RUNNING CONTAINERS ==="
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Networks}}'

echo
echo "=== 13. RELEASE BUILD ==="
cd "$ROOT" || die "project root missing"
dotnet build QuikeFix.LicenseManager.slnx -c Release || die "release build failed"
echo "source_build=PASS"

echo
echo "=== 14. FINAL NO-MUTATION CHECK ==="
FINAL_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
FINAL_PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
[ "$FINAL_IMAGE" = "$PROD_IMAGE" ] || die "production image changed"
[ "$FINAL_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "production migrations changed"
[ "$FINAL_PREVIEW_API_IMAGE" = "$PREVIEW_API_IMAGE" ] || die "preview API image changed"
[ "$FINAL_PREVIEW_GUI_IMAGE" = "$PREVIEW_GUI_IMAGE" ] || die "preview GUI image changed"
echo "no_mutation=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7I1 PASSED"
echo "======================================================"
echo "PRODUCTION API/DB:                 UNCHANGED"
echo "CLOUDFLARE PREVIEW:                UNCHANGED"
echo "SYSTEM/OPERATIONS INVENTORY:       COMPLETE"
echo "REPORT:                            $REPORT"
echo "NEXT: RECOVERY 7I2 - SYSTEM / OPERATIONS GUI/API ISOLATED"
echo "======================================================"
