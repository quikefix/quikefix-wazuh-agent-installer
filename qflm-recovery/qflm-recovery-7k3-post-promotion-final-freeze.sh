#!/usr/bin/env bash
# QFLM RECOVERY 7K3
# Post-promotion soak / final freeze.
# Validates promoted production, preview, signing path, hardening and DB invariants.
# Keeps rollback container intact.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
PG="qflm-postgres"
PROD_DB="qflm"
PROD_API="qflm-api"
ROLLBACK_API="qflm-api-recovery7k2-rollback"
PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"
SIGNING_CONTAINER="qflm-signing"
NET="qflm_backend"

EXPECTED_PROD_IMAGE="qflm-api:recovery7k2-production"
EXPECTED_ROLLBACK_IMAGE="qflm-api:recovery6f3-candidate"
EXPECTED_PREVIEW_API_IMAGE="qflm-api:recovery7i2-candidate"
EXPECTED_PREVIEW_GUI_IMAGE="qflm-admin-web:recovery7j3-preview"

ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"

ORIGIN_IFACE="ens18"
HOST_PORT="8088"
PUBLIC_URL="https://lc.quikefix.info"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7k3-final-freeze-$STAMP"
REPORT="$BACKUP/recovery7k3-final-freeze-report.txt"
DB_DUMP="$BACKUP/qflm-final-freeze.dump"
FREEZE_FILE="$BACKUP/qflm-final-freeze.manifest"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7K3"
echo " POST-PROMOTION SOAK / FINAL FREEZE"
echo "======================================================"

echo
echo "=== 1. PROMOTED PRODUCTION BASELINE ==="

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PROD_STARTED=$(docker inspect "$PROD_API" --format='{{.State.StartedAt}}')
PROD_RESTARTS=$(docker inspect "$PROD_API" --format='{{.RestartCount}}')

[ "$PROD_IMAGE" = "$EXPECTED_PROD_IMAGE" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$PROD_RESTARTS" = 0 ] || die "production API restarted unexpectedly"

printf 'prod_image=%s running=%s started_at=%s restart_count=%s\n'  "$PROD_IMAGE" "$PROD_RUNNING" "$PROD_STARTED" "$PROD_RESTARTS"

echo "production_runtime_baseline=PASS"

echo
echo "=== 2. ROLLBACK CONTAINER PRESERVED ==="

ROLLBACK_IMAGE=$(docker inspect "$ROLLBACK_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
ROLLBACK_RUNNING=$(docker inspect "$ROLLBACK_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)

[ "$ROLLBACK_IMAGE" = "$EXPECTED_ROLLBACK_IMAGE" ] || die "rollback container/image missing"
[ "$ROLLBACK_RUNNING" = false ] || die "rollback container should remain stopped"

printf 'rollback_image=%s running=%s\n' "$ROLLBACK_IMAGE" "$ROLLBACK_RUNNING"
echo "rollback_preserved=PASS"

echo
echo "=== 3. DATABASE INVARIANTS ==="

MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
LICENSES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
ISSUANCES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
AUDIT=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

[ "$MIG" = 5 ] || die "unexpected migration count"
[ "$USERS" -ge 1 ] || die "no auth users"
[ "$ROLES" -ge 1 ] || die "no auth roles"
[ "$PERMS" = 22 ] || die "unexpected permission count"

printf 'migrations=%s users=%s roles=%s permissions=%s licenses=%s installations=%s issuances=%s audit=%s\n'  "$MIG" "$USERS" "$ROLES" "$PERMS" "$LICENSES" "$INSTALLATIONS" "$ISSUANCES" "$AUDIT"

echo "database_invariants=PASS"

echo
echo "=== 4. PRODUCTION HEALTH SOAK ==="

for n in 1 2 3 4 5; do
    docker run --rm --network "$NET" curlimages/curl:8.16.0       -fsS "http://$PROD_API:8080/health/live" >/dev/null       || die "production live health failed on sample $n"

    docker run --rm --network "$NET" curlimages/curl:8.16.0       -fsS "http://$PROD_API:8080/health/ready" >/dev/null       || die "production ready health failed on sample $n"

    sleep 2
done

echo "production_health_soak=PASS"

echo
echo "=== 5. PRODUCTION ADMIN API SOAK ==="

[ -s "$ADMIN_USER_FILE" ] || die "admin username missing"
[ -s "$ADMIN_PASS_FILE" ] || die "admin password missing"

ADMIN_USER="$(cat "$ADMIN_USER_FILE")"
ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"

LOGIN_JSON=$(python3 - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)

LOGIN_RESPONSE=$(printf '%s' "$LOGIN_JSON" | docker run --rm --network "$NET" -i  curlimages/curl:8.16.0 -fsS  -H 'Content-Type: application/json'  -X POST "http://$PROD_API:8080/api/v1/auth/login"  --data-binary @-) || die "production admin login failed"

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
 "/api/v1/admin/security/roles"
 "/api/v1/admin/security/permissions"
 "/api/v1/admin/audit-reports/summary"
 "/api/v1/admin/audit-reports/audit?limit=25"
 "/api/v1/admin/audit-reports/issuances?limit=25"
 "/api/v1/admin/system/summary"
)

for pass in 1 2 3; do
    for url in "${URLS[@]}"; do
        CODE=$(docker run --rm --network "$NET" curlimages/curl:8.16.0           -s -o /dev/null -w '%{http_code}'           -H "Authorization: Bearer $TOKEN"           "http://$PROD_API:8080$url")
        [ "$CODE" = 200 ] || die "production API soak failed: pass=$pass url=$url http=$CODE"
    done
done

echo "production_admin_api_soak=PASS"

echo
echo "=== 6. OFFLINE SIGNING RUNTIME CONTRACT ==="

SIGNING_RUNNING=$(docker inspect "$SIGNING_CONTAINER" --format='{{.State.Running}}' 2>/dev/null || echo missing)
[ "$SIGNING_RUNNING" = true ] || die "signing container not running"

OFFLINE_BASE=$(docker inspect "$PROD_API" --format='{{range .Config.Env}}{{println .}}{{end}}'  | awk -F= '$1=="OfflineSigning__BaseUrl"{print $2}' | tail -n1)
OFFLINE_TOKEN=$(docker inspect "$PROD_API" --format='{{range .Config.Env}}{{println .}}{{end}}'  | awk -F= '$1=="OfflineSigning__TokenPath"{print $2}' | tail -n1)
TOKEN_MOUNT=$(docker inspect "$PROD_API" --format='{{range .Mounts}}{{println .Destination}}{{end}}'  | grep -Fx "$OFFLINE_TOKEN" || true)

[ "$OFFLINE_BASE" = "http://qflm-signing:8080" ] || die "unexpected offline signing base URL"
[ -n "$OFFLINE_TOKEN" ] || die "offline signing token path missing"
[ -n "$TOKEN_MOUNT" ] || die "offline signing token mount missing"

echo "offline_signing_contract=PASS"

echo
echo "=== 7. PRODUCTION HARDENING ==="

PROD_HARDEN=$(docker inspect "$PROD_API"  --format='network={{.HostConfig.NetworkMode}} user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .NetworkSettings.Ports}}')

echo "PROD: $PROD_HARDEN"

echo "$PROD_HARDEN" | grep -Fq 'user=app' || die "production API nonroot user missing"
echo "$PROD_HARDEN" | grep -Fq 'readonly=true' || die "production API readonly missing"
echo "$PROD_HARDEN" | grep -Fq '"ALL"' || die "production API capdrop missing"
echo "$PROD_HARDEN" | grep -Fq 'no-new-privileges:true' || die "production API no-new-privileges missing"
echo "$PROD_HARDEN" | grep -Eq 'ports=\{\}|ports=null' || die "production API exposes host ports"

echo "production_hardening=PASS"

echo
echo "=== 8. CLOUDFLARE PREVIEW REGRESSION CHECK ==="

PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)

[ "$PREVIEW_API_IMAGE" = "$EXPECTED_PREVIEW_API_IMAGE" ] || die "preview API image changed"
[ "$PREVIEW_GUI_IMAGE" = "$EXPECTED_PREVIEW_GUI_IMAGE" ] || die "preview GUI image changed"
[ "$PREVIEW_API_RUNNING" = true ] || die "preview API not running"
[ "$PREVIEW_GUI_RUNNING" = true ] || die "preview GUI not running"

HOST_IP=$(ip -4 -o addr show dev "$ORIGIN_IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
[ -n "$HOST_IP" ] || die "no IPv4 address found on $ORIGIN_IFACE"

for route in / /login /customers /products /licenses /installations /offline /security /audit /system; do
    ORIGIN_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST_IP:$HOST_PORT$route" || true)
    PUBLIC_CODE=$(curl -L -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL$route" || true)
    [ "$ORIGIN_CODE" = 200 ] || die "preview origin route failed: $route"
    [ "$PUBLIC_CODE" = 200 ] || die "preview public route failed: $route"
done

echo "cloudflare_preview_regression=PASS"

echo
echo "=== 9. FINAL DATABASE BACKUP ==="

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" -Fc > "$DB_DUMP" || die "final database backup failed"
[ -s "$DB_DUMP" ] || die "final database backup empty"
DB_SHA=$(sha256sum "$DB_DUMP" | awk '{print $1}')

echo "final_database_backup=PASS"

echo
echo "=== 10. REVOKE TEST SESSION ==="

REVOKE_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)

REVOKE_HTTP=$(printf '%s' "$REVOKE_JSON" | docker run --rm --network "$NET" -i  curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}'  -H 'Content-Type: application/json'  -H "Authorization: Bearer $TOKEN"  -X POST "http://$PROD_API:8080/api/v1/auth/revoke"  --data-binary @-)

[ "$REVOKE_HTTP" = 204 ] || die "production session revoke failed"
unset TOKEN REFRESH ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE REVOKE_JSON

echo "production_session_revoke=PASS"

echo
echo "=== 11. FINAL FREEZE MANIFEST ==="

PROD_IMAGE_ID=$(docker image inspect "$EXPECTED_PROD_IMAGE" --format='{{.Id}}')
PROD_CONTAINER_ID=$(docker inspect "$PROD_API" --format='{{.Id}}')
ROLLBACK_CONTAINER_ID=$(docker inspect "$ROLLBACK_API" --format='{{.Id}}')

cat > "$FREEZE_FILE" <<EOF
QFLM_FINAL_FREEZE=RECOVERY_7K3
UTC=$STAMP
PRODUCTION_API_IMAGE=$EXPECTED_PROD_IMAGE
PRODUCTION_API_IMAGE_ID=$PROD_IMAGE_ID
PRODUCTION_CONTAINER_ID=$PROD_CONTAINER_ID
ROLLBACK_CONTAINER=$ROLLBACK_API
ROLLBACK_CONTAINER_ID=$ROLLBACK_CONTAINER_ID
ROLLBACK_IMAGE=$EXPECTED_ROLLBACK_IMAGE
PREVIEW_API_IMAGE=$PREVIEW_API_IMAGE
PREVIEW_GUI_IMAGE=$PREVIEW_GUI_IMAGE
MIGRATIONS=$MIG
USERS=$USERS
ROLES=$ROLES
PERMISSIONS=$PERMS
LICENSES=$LICENSES
INSTALLATIONS=$INSTALLATIONS
OFFLINE_ISSUANCES=$ISSUANCES
OFFLINE_AUDIT=$AUDIT
DATABASE_BACKUP=$DB_DUMP
DATABASE_BACKUP_SHA256=$DB_SHA
EOF
chmod 400 "$FREEZE_FILE"

echo "final_freeze_manifest=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7K3 FINAL FREEZE PASSED"
echo "======================================================"
echo "PRODUCTION API:                     HEALTHY"
echo "PRODUCTION ADMIN APIs:              PASS"
echo "OFFLINE SIGNING CONTRACT:           PASS"
echo "PRODUCTION HARDENING:               PASS"
echo "PRODUCTION DB:                      VERIFIED"
echo "CLOUDFLARE PREVIEW:                 VERIFIED"
echo "ROLLBACK CONTAINER:                 PRESERVED"
echo "FINAL DATABASE BACKUP:              $DB_DUMP"
echo "FREEZE MANIFEST:                    $FREEZE_FILE"
echo "REPORT:                             $REPORT"
echo "STATUS:                             RECOVERY_7K3_FINAL_FROZEN"
echo "======================================================"
