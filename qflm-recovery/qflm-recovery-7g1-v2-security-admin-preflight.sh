#!/usr/bin/env bash
# QFLM RECOVERY 7G1 V2
# Security Admin GUI/API preflight - read only.
set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API_SRC="$ROOT/src/QFLM.Api"
GUI="$ROOT/src/QFLM.AdminWeb"
PG="qflm-postgres"
PROD_API="qflm-api"
PROD_DB="qflm"
PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"
PREVIEW_DB="qflm_gui_preview_f3"
EXPECTED_PROD_IMAGE="qflm-api:recovery6f3-candidate"
EXPECTED_PREVIEW_API_IMAGE="qflm-api:recovery7f2-candidate"
EXPECTED_PREVIEW_GUI_IMAGE="qflm-admin-web:recovery7f3-preview"
ORIGIN_IFACE="ens18"
HOST_PORT="8088"
PUBLIC_URL="https://lc.quikefix.info"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="/opt/qflm/backups/recovery7g1-preflight-$STAMP.txt"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }
mkdir -p /opt/qflm/backups
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7G1"
echo " SECURITY ADMIN GUI/API PREFLIGHT"
echo " READ ONLY"
echo "======================================================"

echo
echo "=== 1. PRODUCTION SAFETY BASELINE ==="
PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
printf 'prod_image=%s running=%s migrations=%s\n' "$PROD_IMAGE" "$PROD_RUNNING" "$MIG"
[ "$PROD_IMAGE" = "$EXPECTED_PROD_IMAGE" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"
echo "production_baseline=PASS"

echo
echo "=== 2. CURRENT CLOUDFLARE PREVIEW BASELINE ==="
HOST_IP=$(ip -4 -o addr show dev "$ORIGIN_IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
[ -n "$HOST_IP" ] || die "no IPv4 address found on $ORIGIN_IFACE"

PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
printf 'preview_api_running=%s preview_gui_running=%s\n' "$PREVIEW_API_RUNNING" "$PREVIEW_GUI_RUNNING"
printf 'preview_api_image=%s preview_gui_image=%s\n' "$PREVIEW_API_IMAGE" "$PREVIEW_GUI_IMAGE"
[ "$PREVIEW_API_RUNNING" = true ] || die "preview API not running"
[ "$PREVIEW_GUI_RUNNING" = true ] || die "preview GUI not running"
[ "$PREVIEW_API_IMAGE" = "$EXPECTED_PREVIEW_API_IMAGE" ] || die "unexpected preview API image"
[ "$PREVIEW_GUI_IMAGE" = "$EXPECTED_PREVIEW_GUI_IMAGE" ] || die "unexpected preview GUI image"

ORIGIN_ROOT=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST_IP}:${HOST_PORT}/" || true)
PUBLIC_ROOT=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/" || true)
PUBLIC_OFFLINE=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/offline" || true)
printf 'origin_ip=%s origin_root=%s public_root=%s public_offline=%s\n' "$HOST_IP" "$ORIGIN_ROOT" "$PUBLIC_ROOT" "$PUBLIC_OFFLINE"
[ "$ORIGIN_ROOT" = 200 ] || die "preview origin failed"
[ "$PUBLIC_ROOT" = 200 ] || die "public preview failed"
[ "$PUBLIC_OFFLINE" = 200 ] || die "offline preview route failed"
echo "preview_baseline=PASS"

echo
echo "=== 3. PREVIEW DATABASE PRESENCE ==="
PREVIEW_EXISTS=$(docker exec "$PG" psql -U qflm -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$PREVIEW_DB';" | xargs)
[ "$PREVIEW_EXISTS" = 1 ] || die "preview DB missing"
echo "preview_database=$PREVIEW_DB"
echo "preview_database=PASS"

echo
echo "=== 4. SECURITY API CONTROLLER INVENTORY ==="
SEC_CTRL="$API_SRC/Controllers/AdminSecurityManagementController.cs"
[ -s "$SEC_CTRL" ] || die "AdminSecurityManagementController.cs missing"
grep -nE '\[Route|\[Http(Get|Post|Put|Delete|Patch)|Authorize|users|roles|permissions|sessions' "$SEC_CTRL" | sed -n '1,320p'
echo "security_controller=PASS"

echo
echo "=== 5. SECURITY SERVICE INVENTORY ==="
grep -RniE --exclude-dir=bin --exclude-dir=obj 'ISecurityAdministrationService|EfSecurityAdministrationService|Permission|Role|User.*Role|Role.*Permission' \
 "$ROOT/src/QFLM.Application/Security" "$ROOT/src/QFLM.Infrastructure/Security" 2>/dev/null | sed -n '1,360p'
echo "security_service_inventory=PASS"

echo
echo "=== 6. SECURITY DATA COUNTS ==="
for t in auth_users auth_roles auth_permissions auth_user_roles auth_role_permissions auth_refresh_tokens; do
  EXISTS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT to_regclass('public.$t') IS NOT NULL;" | xargs)
  if [ "$EXISTS" = t ]; then
    COUNT=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM $t;" | xargs)
    printf '%s=%s\n' "$t" "$COUNT"
  else
    printf '%s=NOT_PRESENT\n' "$t"
  fi
done

PERM_COUNT=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
[ "$PERM_COUNT" = 22 ] || die "unexpected permission count"
echo "security_permission_catalog=PASS count=$PERM_COUNT"

echo
echo "=== 7. CURRENT GUI SECURITY ROUTE ==="
grep -nA14 -B6 'path="security"' "$GUI/src/App.tsx" || true
grep -q 'path="security"' "$GUI/src/App.tsx" || die "security route missing from GUI"
echo "security_route_present=PASS"

echo
echo "=== 8. GUI API CLIENT PRESENT ==="
[ -s "$GUI/src/lib/api.ts" ] || die "GUI api.ts missing"
echo "gui_api_client=PASS"

echo
echo "=== 9. RELEASE BUILD ==="
cd "$ROOT" || die "project root missing"
dotnet build QuikeFix.LicenseManager.slnx -c Release || die "release build failed"
echo "source_build=PASS"

echo
echo "=== 10. FINAL PRODUCTION NO-MUTATION CHECK ==="
FINAL_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
printf 'image=%s running=%s migrations=%s\n' "$FINAL_IMAGE" "$FINAL_RUNNING" "$FINAL_MIG"
[ "$FINAL_IMAGE" = "$PROD_IMAGE" ] || die "production image changed"
[ "$FINAL_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "production migration count changed"
echo "production_unchanged=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7G1 V2 PREFLIGHT PASSED"
echo "======================================================"
echo "SECURITY CONTROLLER:      PRESENT"
echo "SECURITY SERVICE LAYER:   INVENTORIED"
echo "SECURITY DB/RBAC:         INVENTORIED"
echo "SECURITY GUI ROUTE:       PRESENT"
echo "CURRENT PREVIEW:          HEALTHY"
echo "PRODUCTION API/DB:        UNCHANGED"
echo "REPORT:                   $REPORT"
echo "NEXT: RECOVERY 7G2 - SECURITY ADMIN GUI/API ISOLATED"
echo "======================================================"
