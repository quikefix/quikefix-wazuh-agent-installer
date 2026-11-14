#!/usr/bin/env bash
# QFLM RECOVERY 7K2
# Controlled production API promotion with rollback container preserved.
# Promotes validated Recovery 7I2 API candidate to production.
# Cloudflare preview remains unchanged.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
PG="qflm-postgres"
PROD_DB="qflm"
PROD_API="qflm-api"
NEXT_API="qflm-api-production-next"
ROLLBACK_API="qflm-api-recovery7k2-rollback"
NET="qflm_backend"

OLD_IMAGE_EXPECTED="qflm-api:recovery6f3-candidate"
CANDIDATE_IMAGE="qflm-api:recovery7i2-candidate"
PRODUCTION_IMAGE="qflm-api:recovery7k2-production"

PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"
EXPECTED_PREVIEW_API_IMAGE="qflm-api:recovery7i2-candidate"
EXPECTED_PREVIEW_GUI_IMAGE="qflm-admin-web:recovery7j3-preview"

ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"

SIGNING_CONTAINER="qflm-signing"
SIGNING_TOKEN_TARGET="/run/qflm-signing/token"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7k2-production-$STAMP"
REPORT="$BACKUP/recovery7k2-production-report.txt"
ENV_FILE="$BACKUP/production-api.env"
DB_DUMP="$BACKUP/qflm-before-production-promotion.dump"

CUTOVER_STARTED=0
PROMOTED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

rollback(){
    if [ "$PROMOTED" -eq 1 ]; then
        return
    fi

    if [ "$CUTOVER_STARTED" -eq 1 ]; then
        printf '\n=== AUTOMATIC PRODUCTION ROLLBACK ===\n'
        if docker inspect "$PROD_API" >/dev/null 2>&1; then
            docker rm -f "$PROD_API" >/dev/null 2>&1 || true
        fi
        if docker inspect "$ROLLBACK_API" >/dev/null 2>&1; then
            docker rename "$ROLLBACK_API" "$PROD_API" >/dev/null 2>&1 || true
            docker start "$PROD_API" >/dev/null 2>&1 || true
            sleep 3
        fi
        printf '%s\n' "production_rollback_attempted=YES"
    else
        docker rm -f "$NEXT_API" >/dev/null 2>&1 || true
    fi
}
trap rollback EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7K2"
echo " CONTROLLED PRODUCTION PROMOTION"
echo "======================================================"

echo
echo "=== 1. PRODUCTION + PREVIEW BASELINE ==="

OLD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
OLD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PROD_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
PROD_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
PROD_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PROD_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
PROD_AUDIT=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)
PROD_ISS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)

[ "$OLD_IMAGE" = "$OLD_IMAGE_EXPECTED" ] || die "unexpected current production API image"
[ "$OLD_RUNNING" = true ] || die "production API not running"
[ "$PROD_MIG" = 5 ] || die "unexpected migration count"

PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)

[ "$PREVIEW_API_RUNNING" = true ] || die "preview API not running"
[ "$PREVIEW_GUI_RUNNING" = true ] || die "preview GUI not running"
[ "$PREVIEW_API_IMAGE" = "$EXPECTED_PREVIEW_API_IMAGE" ] || die "unexpected preview API image"
[ "$PREVIEW_GUI_IMAGE" = "$EXPECTED_PREVIEW_GUI_IMAGE" ] || die "unexpected preview GUI image"

echo "production_preview_baseline=PASS"

echo
echo "=== 2. BACKUP PRODUCTION DATABASE ==="

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" -Fc > "$DB_DUMP" || die "production DB backup failed"
[ -s "$DB_DUMP" ] || die "production DB backup empty"
printf 'database_backup_sha256=%s\n' "$(sha256sum "$DB_DUMP" | awk '{print $1}')"
echo "production_database_backup=PASS"

echo
echo "=== 3. PREPARE PRODUCTION IMAGE + ENVIRONMENT ==="

docker image inspect "$CANDIDATE_IMAGE" >/dev/null 2>&1 || die "validated candidate image missing"
docker tag "$CANDIDATE_IMAGE" "$PRODUCTION_IMAGE" || die "production image tag failed"

docker inspect "$PROD_API" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$ENV_FILE"  || die "capture production API environment failed"
chmod 600 "$ENV_FILE"

DB_ENV=$(awk -F= '$1=="Qflm__PostgreSqlDatabase"{print $2}' "$ENV_FILE" | tail -n1)
if [ -n "$DB_ENV" ] && [ "$DB_ENV" != "$PROD_DB" ]; then
    die "production API environment points to unexpected database: $DB_ENV"
fi

echo
echo "=== 3A. RESOLVE OFFLINE SIGNING TOKEN ==="

[ "$(docker inspect "$SIGNING_CONTAINER" --format='{{.State.Running}}' 2>/dev/null || echo false)" = true ] \
 || die "signing container not running"

SIGNING_TOKEN_CONTAINER_PATH=$(docker inspect "$SIGNING_CONTAINER" \
 --format='{{range .Config.Env}}{{println .}}{{end}}' \
 | awk -F= '$1=="Signing__TokenPath"{print $2; exit}')

[ -n "$SIGNING_TOKEN_CONTAINER_PATH" ] || die "Signing__TokenPath missing"

SIGNING_TOKEN_SOURCE=$(docker inspect "$SIGNING_CONTAINER" \
 --format='{{range .Mounts}}{{println .Source "|" .Destination}}{{end}}' \
 | awk -F'|' -v target="$SIGNING_TOKEN_CONTAINER_PATH" '$2==target{print $1; exit}')

if [ -z "$SIGNING_TOKEN_SOURCE" ]; then
    SIGNING_TOKEN_SOURCE="/opt/qflm/secrets/signing-runtime/token"
fi

[ -s "$SIGNING_TOKEN_SOURCE" ] || die "signing token source missing"

cat >> "$ENV_FILE" <<EOF
OfflineSigning__BaseUrl=http://qflm-signing:8080
OfflineSigning__TokenPath=$SIGNING_TOKEN_TARGET
EOF
chmod 600 "$ENV_FILE"

echo "offline_signing_environment=PASS"
echo "production_environment_capture=PASS"

echo
echo "=== 4. START NEXT PRODUCTION API PRIVATELY ==="

docker rm -f "$NEXT_API" >/dev/null 2>&1 || true
docker rm -f "$ROLLBACK_API" >/dev/null 2>&1 || true

docker run -d  --name "$NEXT_API"  --network "$NET"  --network-alias qflm-api-production-next  --env-file "$ENV_FILE"  --volumes-from "$PROD_API:ro"  --mount type=bind,src="$SIGNING_TOKEN_SOURCE",dst="$SIGNING_TOKEN_TARGET",readonly  --read-only  --cap-drop ALL  --security-opt no-new-privileges:true  --tmpfs /tmp:rw,noexec,nosuid,size=16m  "$PRODUCTION_IMAGE" >/dev/null  || die "next production API start failed"

sleep 5

docker run --rm --network "$NET" curlimages/curl:8.16.0  -fsS "http://$NEXT_API:8080/health/ready" >/dev/null  || {
    docker logs --tail 240 "$NEXT_API" || true
    die "next production API readiness failed"
 }

NEXT_PORTS=$(docker inspect "$NEXT_API" --format='{{json .NetworkSettings.Ports}}')
case "$NEXT_PORTS" in
  "{}"|"null") ;;
  *) die "next production API unexpectedly exposes host ports" ;;
esac

echo "next_production_api_private=PASS"

echo
echo "=== 5. AUTHENTICATED CANDIDATE VALIDATION ==="

[ -s "$ADMIN_USER_FILE" ] || die "admin username missing"
[ -s "$ADMIN_PASS_FILE" ] || die "admin password missing"

ADMIN_USER="$(cat "$ADMIN_USER_FILE")"
ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"

LOGIN_JSON=$(python3 - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)

LOGIN_RESPONSE=$(printf '%s' "$LOGIN_JSON" | docker run --rm --network "$NET" -i  curlimages/curl:8.16.0 -fsS  -H 'Content-Type: application/json'  -X POST "http://$NEXT_API:8080/api/v1/auth/login"  --data-binary @-) || die "candidate admin login failed"

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
    CODE=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $TOKEN" \
      "http://$NEXT_API:8080$url")
    if [ "$CODE" != 200 ]; then
        echo "candidate_api_failure_url=$url http=$CODE"
        docker logs --tail 240 "$NEXT_API" || true
        die "candidate API validation failed: $url -> $CODE"
    fi
done

REVOKE_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)

REVOKE_HTTP=$(printf '%s' "$REVOKE_JSON" | docker run --rm --network "$NET" -i  curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}'  -H 'Content-Type: application/json'  -H "Authorization: Bearer $TOKEN"  -X POST "http://$NEXT_API:8080/api/v1/auth/revoke"  --data-binary @-)

[ "$REVOKE_HTTP" = 204 ] || die "candidate test session revoke failed"

unset TOKEN REFRESH ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE REVOKE_JSON

echo "candidate_functional_validation=PASS"

echo
echo "=== 6. CONTROLLED CUTOVER ==="

CUTOVER_STARTED=1

docker stop "$PROD_API" >/dev/null || die "failed to stop current production API"
docker rename "$PROD_API" "$ROLLBACK_API" || die "failed to preserve rollback production API"
docker rename "$NEXT_API" "$PROD_API" || die "failed to promote next production API"

sleep 4

[ "$(docker inspect "$PROD_API" --format='{{.State.Running}}')" = true ]  || die "promoted production API not running"

NEW_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
[ "$NEW_IMAGE" = "$PRODUCTION_IMAGE" ] || die "promoted production API image mismatch"

docker run --rm --network "$NET" curlimages/curl:8.16.0  -fsS "http://$PROD_API:8080/health/ready" >/dev/null  || {
    docker logs --tail 240 "$PROD_API" || true
    die "promoted production API readiness failed"
 }

echo "production_cutover=PASS"

echo
echo "=== 7. POST-CUTOVER ADMIN VALIDATION ==="

ADMIN_USER="$(cat "$ADMIN_USER_FILE")"
ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"

LOGIN_JSON=$(python3 - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)

LOGIN_RESPONSE=$(printf '%s' "$LOGIN_JSON" | docker run --rm --network "$NET" -i  curlimages/curl:8.16.0 -fsS  -H 'Content-Type: application/json'  -X POST "http://$PROD_API:8080/api/v1/auth/login"  --data-binary @-) || die "production admin login failed after promotion"

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

for url in "/api/v1/admin/dashboard/summary" "/api/v1/admin/audit-reports/summary" "/api/v1/admin/system/summary"; do
    CODE=$(docker run --rm --network "$NET" curlimages/curl:8.16.0       -s -o /dev/null -w '%{http_code}'       -H "Authorization: Bearer $TOKEN"       "http://$PROD_API:8080$url")
    [ "$CODE" = 200 ] || die "post-cutover API failed: $url -> $CODE"
done

REVOKE_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)

REVOKE_HTTP=$(printf '%s' "$REVOKE_JSON" | docker run --rm --network "$NET" -i  curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}'  -H 'Content-Type: application/json'  -H "Authorization: Bearer $TOKEN"  -X POST "http://$PROD_API:8080/api/v1/auth/revoke"  --data-binary @-)

[ "$REVOKE_HTTP" = 204 ] || die "post-cutover session revoke failed"

unset TOKEN REFRESH ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE REVOKE_JSON

echo "post_cutover_functional_validation=PASS"

echo
echo "=== 8. DATABASE + PREVIEW SAFETY CHECK ==="

FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
FINAL_AUDIT=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)
FINAL_ISS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)

[ "$FINAL_MIG" = "$PROD_MIG" ] || die "production migrations changed"
[ "$FINAL_USERS" = "$PROD_USERS" ] || die "production users changed"
[ "$FINAL_ROLES" = "$PROD_ROLES" ] || die "production roles changed"
[ "$FINAL_PERMS" = "$PROD_PERMS" ] || die "production permissions changed"
[ "$FINAL_AUDIT" = "$PROD_AUDIT" ] || die "production audit events changed unexpectedly"
[ "$FINAL_ISS" = "$PROD_ISS" ] || die "production issuances changed unexpectedly"

FINAL_PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}')
FINAL_PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}')
FINAL_PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}')
FINAL_PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}')

[ "$FINAL_PREVIEW_API_IMAGE" = "$PREVIEW_API_IMAGE" ] || die "preview API image changed"
[ "$FINAL_PREVIEW_GUI_IMAGE" = "$PREVIEW_GUI_IMAGE" ] || die "preview GUI image changed"
[ "$FINAL_PREVIEW_API_RUNNING" = true ] || die "preview API stopped"
[ "$FINAL_PREVIEW_GUI_RUNNING" = true ] || die "preview GUI stopped"

echo "production_database_unchanged=PASS"
echo "cloudflare_preview_unchanged=PASS"

PROMOTED=1

echo
echo "======================================================"
echo " QFLM RECOVERY 7K2 PRODUCTION PROMOTION PASSED"
echo "======================================================"
echo "PRODUCTION API IMAGE:               $PRODUCTION_IMAGE"
echo "PRODUCTION HEALTH:                  PASS"
echo "ADMIN API VALIDATION:               PASS"
echo "AUDIT & REPORTS API:                LIVE"
echo "SYSTEM / OPERATIONS API:            LIVE"
echo "PRODUCTION DB:                      UNCHANGED"
echo "CLOUDFLARE PREVIEW:                 UNCHANGED"
echo "ROLLBACK CONTAINER:                 $ROLLBACK_API"
echo "ROLLBACK IMAGE:                     $OLD_IMAGE"
echo "DATABASE BACKUP:                    $DB_DUMP"
echo "REPORT:                             $REPORT"
echo "NEXT: RECOVERY 7K3 - POST-PROMOTION SOAK / FINAL FREEZE"
echo "======================================================"
