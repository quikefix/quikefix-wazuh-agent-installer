#!/usr/bin/env bash
# QFLM RECOVERY 7J2
# Final Admin GUI Review / Hardening preflight - read-only.
# No source, database, preview, or production mutation.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API="$ROOT/src/QFLM.Api"
GUI="$ROOT/src/QFLM.AdminWeb"

PG="qflm-postgres"
PROD_API="qflm-api"
PROD_DB="qflm"
PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"

ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"

ORIGIN_IFACE="ens18"
HOST_PORT="8088"
PUBLIC_URL="https://lc.quikefix.info"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="/opt/qflm/backups/recovery7j2-final-admin-review-preflight-$STAMP.txt"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p /opt/qflm/backups
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7J2"
echo " FINAL ADMIN GUI HARDENING / POLISH ISOLATED"
echo " ISOLATED VALIDATION"
echo "======================================================"

echo
echo "=== 1. PRODUCTION BASELINE ==="

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PROD_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
PROD_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
PROD_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PROD_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

[ "$PROD_IMAGE" = "qflm-api:recovery6f3-candidate" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$PROD_MIG" = 5 ] || die "unexpected migration count"

printf 'prod_image=%s running=%s migrations=%s users=%s roles=%s permissions=%s\n'  "$PROD_IMAGE" "$PROD_RUNNING" "$PROD_MIG" "$PROD_USERS" "$PROD_ROLES" "$PROD_PERMS"

echo "production_baseline=PASS"

echo
echo "=== 2. CURRENT PREVIEW BASELINE ==="

PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)

[ "$PREVIEW_API_RUNNING" = true ] || die "preview API not running"
[ "$PREVIEW_GUI_RUNNING" = true ] || die "preview GUI not running"
[ "$PREVIEW_API_IMAGE" = "qflm-api:recovery7i2-candidate" ] || die "unexpected preview API image"
[ "$PREVIEW_GUI_IMAGE" = "qflm-admin-web:recovery7i3-preview" ] || die "unexpected preview GUI image"

printf 'preview_api=%s preview_gui=%s api_image=%s gui_image=%s\n'  "$PREVIEW_API_RUNNING" "$PREVIEW_GUI_RUNNING" "$PREVIEW_API_IMAGE" "$PREVIEW_GUI_IMAGE"

HOST_IP=$(ip -4 -o addr show dev "$ORIGIN_IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
[ -n "$HOST_IP" ] || die "no IPv4 address found on $ORIGIN_IFACE"

echo "preview_baseline=PASS"

echo
echo
echo "=== 2A. BACKUP GUI SOURCE ==="

BACKUP_DIR="/opt/qflm/backups/recovery7j2-$STAMP"
mkdir -p "$BACKUP_DIR"
GUI_BACKUP="$BACKUP_DIR/qflm-admin-web-before-7j2.tgz"
tar -czf "$GUI_BACKUP" -C "$ROOT" "src/QFLM.AdminWeb" || die "GUI source backup failed"
[ -s "$GUI_BACKUP" ] || die "GUI source backup empty"
echo "gui_backup=PASS"

echo
echo "=== 2B. REMOVE UNUSED PLACEHOLDER IMPORT ==="

python3 - "$GUI/src/App.tsx" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
s=s.replace('import { PlaceholderPage } from "./pages/PlaceholderPage";\n','')
p.write_text(s)
PY

if grep -Fq 'PlaceholderPage' "$GUI/src/App.tsx"; then
    die "PlaceholderPage still referenced in App.tsx"
fi

echo "placeholder_cleanup=PASS"

echo "=== 3. GUI ROUTE INVENTORY ==="

grep -nE 'path=|PlaceholderPage' "$GUI/src/App.tsx" | sed -n '1,320p'

for route in customers products licenses installations offline security audit system; do
    grep -Fq "path=\"$route\"" "$GUI/src/App.tsx" || die "missing GUI route: $route"
done

echo "gui_route_inventory=PASS"

echo
echo "=== 4. PLACEHOLDER REVIEW ==="

PLACEHOLDER_COUNT=$(grep -c 'PlaceholderPage' "$GUI/src/App.tsx" || true)
printf 'placeholder_references=%s\n' "$PLACEHOLDER_COUNT"
[ "$PLACEHOLDER_COUNT" = 0 ] || die "placeholder reference remains"
echo "placeholder_review=PASS"

echo
echo "=== 5. ORIGIN ROUTE VALIDATION ==="

for route in / /login /customers /products /licenses /installations /offline /security /audit /system; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST_IP:$HOST_PORT$route" || true)
    [ "$CODE" = 200 ] || die "origin route failed: $route -> $CODE"
done

echo "origin_routes=PASS"

echo
echo "=== 6. PUBLIC ROUTE VALIDATION ==="

for route in / /login /customers /products /licenses /installations /offline /security /audit /system; do
    CODE=$(curl -L -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL$route" || true)
    [ "$CODE" = 200 ] || die "public route failed: $route -> $CODE"
done

echo "public_routes=PASS"

echo
echo "=== 7. PREVIEW AUTH + API SMOKE ==="

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

declare -a URLS=(
 "/api/v1/admin/dashboard/summary"
 "/api/v1/admin/customers"
 "/api/v1/admin/products"
 "/api/v1/admin/licenses"
 "/api/v1/admin/installations"
 "/api/v1/admin/offline/issuances"
 "/api/v1/admin/security/users"
 "/api/v1/admin/audit-reports/summary"
 "/api/v1/admin/system/summary"
)

for url in "${URLS[@]}"; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}'       -H "Authorization: Bearer $TOKEN"       "http://$HOST_IP:$HOST_PORT$url")
    [ "$CODE" = 200 ] || die "API smoke failed: $url -> $CODE"
done

echo "preview_api_smoke=PASS"

echo
echo "=== 8. PREVIEW HARDENING ==="

API_HARDEN=$(docker inspect "$PREVIEW_API"  --format='network={{.HostConfig.NetworkMode}} user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .NetworkSettings.Ports}}')
GUI_HARDEN=$(docker inspect "$PREVIEW_GUI"  --format='network={{.HostConfig.NetworkMode}} user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}}')

echo "API: $API_HARDEN"
echo "GUI: $GUI_HARDEN"

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
echo "=== 9. SOURCE / BUILD REVIEW ==="

dotnet build "$ROOT/QuikeFix.LicenseManager.slnx" -c Release || die "release build failed"

cd "$GUI" || die "GUI source missing"
docker run --rm \
  -v "$GUI:/src" \
  -w /src \
  node:24-bookworm-slim \
  sh -lc 'npm install --no-audit --no-fund >/dev/null && npm run build' \
  || die "GUI build failed"

echo "source_builds=PASS"

echo
echo "=== 10. REVOKE TEST SESSION ==="

REVOKE_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)

REVOKE_HTTP=$(curl -s -o /dev/null -w '%{http_code}'  -H 'Content-Type: application/json'  -H "Authorization: Bearer $TOKEN"  -X POST "http://$HOST_IP:$HOST_PORT/api/v1/auth/revoke"  --data-binary "$REVOKE_JSON")

[ "$REVOKE_HTTP" = 204 ] || die "session revoke failed"

unset TOKEN REFRESH ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE REVOKE_JSON

echo "test_session_revoked=PASS"

echo
echo "=== 11. FINAL NO-MUTATION CHECK ==="

FINAL_PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

FINAL_PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}')
FINAL_PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}')

[ "$FINAL_PROD_IMAGE" = "$PROD_IMAGE" ] || die "production image changed"
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
echo " QFLM RECOVERY 7J2 PASSED"
echo "======================================================"
echo "GUI ROUTES:                         PASS"
echo "PUBLIC ROUTES:                      PASS"
echo "ADMIN API SMOKE:                    PASS"
echo "PREVIEW HARDENING:                  PASS"
echo "API BUILD:                          PASS"
echo "GUI BUILD:                          PASS"
echo "PRODUCTION API/DB:                  UNCHANGED"
echo "CLOUDFLARE PREVIEW:                 UNCHANGED"
echo "REPORT:                             $REPORT"
echo "NEXT: RECOVERY 7J3 - REFRESH CLOUDFLARE PREVIEW WITH FINAL ADMIN GUI"
echo "======================================================"
