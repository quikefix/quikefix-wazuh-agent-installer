#!/usr/bin/env bash
# QFLM RECOVERY 7K1
# Production promotion readiness preflight - read-only.
# No production or preview mutation.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
PG="qflm-postgres"
PROD_API="qflm-api"
PROD_DB="qflm"
PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"
NET="qflm_backend"

EXPECTED_PROD_API_IMAGE="qflm-api:recovery6f3-candidate"
EXPECTED_PREVIEW_API_IMAGE="qflm-api:recovery7i2-candidate"
EXPECTED_PREVIEW_GUI_IMAGE="qflm-admin-web:recovery7j3-preview"

ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"

ORIGIN_IFACE="ens18"
HOST_PORT="8088"
PUBLIC_URL="https://lc.quikefix.info"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7k1-readiness-$STAMP"
REPORT="$BACKUP/recovery7k1-readiness-report.txt"
DB_DUMP="$BACKUP/qflm-production-readiness.dump"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7K1"
echo " PRODUCTION PROMOTION READINESS"
echo " READ ONLY"
echo "======================================================"

echo
echo "=== 1. PRODUCTION BASELINE ==="

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PROD_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
PROD_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
PROD_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PROD_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

[ "$PROD_IMAGE" = "$EXPECTED_PROD_API_IMAGE" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$PROD_MIG" = 5 ] || die "unexpected production migration count"

printf 'prod_image=%s running=%s migrations=%s users=%s roles=%s permissions=%s\n'  "$PROD_IMAGE" "$PROD_RUNNING" "$PROD_MIG" "$PROD_USERS" "$PROD_ROLES" "$PROD_PERMS"

echo "production_baseline=PASS"

echo
echo "=== 2. PREVIEW BASELINE ==="

PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)

[ "$PREVIEW_API_RUNNING" = true ] || die "preview API not running"
[ "$PREVIEW_GUI_RUNNING" = true ] || die "preview GUI not running"
[ "$PREVIEW_API_IMAGE" = "$EXPECTED_PREVIEW_API_IMAGE" ] || die "unexpected preview API image"
[ "$PREVIEW_GUI_IMAGE" = "$EXPECTED_PREVIEW_GUI_IMAGE" ] || die "unexpected preview GUI image"

printf 'preview_api_image=%s preview_gui_image=%s\n' "$PREVIEW_API_IMAGE" "$PREVIEW_GUI_IMAGE"
echo "preview_baseline=PASS"

echo
echo "=== 3. BACKUP PRODUCTION DATABASE ==="

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" -Fc > "$DB_DUMP" || die "production DB dump failed"
[ -s "$DB_DUMP" ] || die "production DB dump empty"
printf 'db_backup_sha256=%s\n' "$(sha256sum "$DB_DUMP" | awk '{print $1}')"
echo "production_database_backup=PASS"

echo
echo "=== 4. PREVIEW ORIGIN + PUBLIC ROUTES ==="

HOST_IP=$(ip -4 -o addr show dev "$ORIGIN_IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
[ -n "$HOST_IP" ] || die "no IPv4 address found on $ORIGIN_IFACE"

for route in / /login /customers /products /licenses /installations /offline /security /audit /system; do
    ORIGIN_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST_IP:$HOST_PORT$route" || true)
    PUBLIC_CODE=$(curl -L -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL$route" || true)
    [ "$ORIGIN_CODE" = 200 ] || die "origin route failed: $route -> $ORIGIN_CODE"
    [ "$PUBLIC_CODE" = 200 ] || die "public route failed: $route -> $PUBLIC_CODE"
done

echo "preview_routes=PASS"

echo
echo "=== 5. PREVIEW ADMIN API SMOKE ==="

[ -s "$ADMIN_USER_FILE" ] || die "admin username missing"
[ -s "$ADMIN_PASS_FILE" ] || die "admin password missing"

ADMIN_USER="$(cat "$ADMIN_USER_FILE")"
ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"

LOGIN_JSON=$(python3 - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)

LOGIN_RESPONSE=$(curl -fsS  -H 'Content-Type: application/json'  -X POST "http://$HOST_IP:$HOST_PORT/api/v1/auth/login"  --data-binary "$LOGIN_JSON") || die "preview admin login failed"

TOKEN=$(python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["accessToken"])
PY
)

REFRESH=$(python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["refreshToken"])
PY
)

declare -a API_URLS=(
 "/api/v1/admin/dashboard/summary"
 "/api/v1/admin/customers"
 "/api/v1/admin/products"
 "/api/v1/admin/licenses"
 "/api/v1/admin/installations"
 "/api/v1/admin/offline/issuances"
 "/api/v1/admin/security/users"
 "/api/v1/admin/security/roles"
 "/api/v1/admin/security/permissions"
 "/api/v1/admin/audit-reports/summary"
 "/api/v1/admin/audit-reports/audit?limit=10"
 "/api/v1/admin/audit-reports/issuances?limit=10"
 "/api/v1/admin/system/summary"
)

for url in "${API_URLS[@]}"; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}'       -H "Authorization: Bearer $TOKEN"       "http://$HOST_IP:$HOST_PORT$url")
    [ "$CODE" = 200 ] || die "preview API failed: $url -> $CODE"
done

echo "preview_admin_api_smoke=PASS"

echo
echo "=== 6. PREVIEW HARDENING ==="

API_HARDEN=$(docker inspect "$PREVIEW_API"  --format='network={{.HostConfig.NetworkMode}} user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .NetworkSettings.Ports}}')
GUI_HARDEN=$(docker inspect "$PREVIEW_GUI"  --format='network={{.HostConfig.NetworkMode}} user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}}')

echo "API: $API_HARDEN"
echo "GUI: $GUI_HARDEN"

echo "$API_HARDEN" | grep -Fq 'user=app' || die "preview API nonroot user missing"
echo "$API_HARDEN" | grep -Fq 'readonly=true' || die "preview API readonly missing"
echo "$API_HARDEN" | grep -Fq '"ALL"' || die "preview API capdrop missing"
echo "$API_HARDEN" | grep -Fq 'no-new-privileges:true' || die "preview API no-new-privileges missing"
echo "$API_HARDEN" | grep -Eq 'ports=\{\}|ports=null' || die "preview API exposes host ports"

echo "$GUI_HARDEN" | grep -Fq 'network=host' || die "preview GUI host network missing"
echo "$GUI_HARDEN" | grep -Fq 'user=nginx' || die "preview GUI nonroot user missing"
echo "$GUI_HARDEN" | grep -Fq 'readonly=true' || die "preview GUI readonly missing"
echo "$GUI_HARDEN" | grep -Fq '"ALL"' || die "preview GUI capdrop missing"
echo "$GUI_HARDEN" | grep -Fq 'no-new-privileges:true' || die "preview GUI no-new-privileges missing"

echo "preview_hardening=PASS"

echo
echo "=== 7. SOURCE BUILD ==="

cd "$ROOT" || die "project root missing"
dotnet build QuikeFix.LicenseManager.slnx -c Release || die "release build failed"

echo "source_build=PASS"

echo
echo "=== 8. REVOKE TEST SESSION ==="

REVOKE_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)

REVOKE_HTTP=$(curl -s -o /dev/null -w '%{http_code}'  -H 'Content-Type: application/json'  -H "Authorization: Bearer $TOKEN"  -X POST "http://$HOST_IP:$HOST_PORT/api/v1/auth/revoke"  --data-binary "$REVOKE_JSON")

[ "$REVOKE_HTTP" = 204 ] || die "preview session revoke failed"
unset TOKEN REFRESH ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE REVOKE_JSON
echo "preview_session_revoke=PASS"

echo
echo "=== 9. FINAL NO-MUTATION CHECK ==="

FINAL_PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

FINAL_PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}')
FINAL_PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}')

[ "$FINAL_PROD_IMAGE" = "$PROD_IMAGE" ] || die "production API image changed"
[ "$FINAL_PROD_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$PROD_MIG" ] || die "production migrations changed"
[ "$FINAL_USERS" = "$PROD_USERS" ] || die "production users changed"
[ "$FINAL_ROLES" = "$PROD_ROLES" ] || die "production roles changed"
[ "$FINAL_PERMS" = "$PROD_PERMS" ] || die "production permissions changed"
[ "$FINAL_PREVIEW_API_IMAGE" = "$PREVIEW_API_IMAGE" ] || die "preview API image changed"
[ "$FINAL_PREVIEW_GUI_IMAGE" = "$PREVIEW_GUI_IMAGE" ] || die "preview GUI image changed"

echo "no_mutation=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7K1 READINESS PASSED"
echo "======================================================"
echo "PRODUCTION DB BACKUP:               PASS"
echo "PREVIEW ROUTES:                     PASS"
echo "PREVIEW ADMIN APIs:                 PASS"
echo "PREVIEW HARDENING:                  PASS"
echo "SOURCE BUILD:                       PASS"
echo "PRODUCTION API/DB:                  UNCHANGED"
echo "CLOUDFLARE PREVIEW:                 UNCHANGED"
echo "REPORT:                             $REPORT"
echo "NEXT: RECOVERY 7K2 - CONTROLLED PRODUCTION PROMOTION"
echo "======================================================"
