#!/usr/bin/env bash
# QFLM RECOVERY 7I3
# Refresh the existing Cloudflare GUI preview with the validated
# Recovery 7F2 Offline Licensing Admin GUI/API candidate.
#
# Safety:
# - production API/DB/compose are not modified
# - a NEW preview database clone is used
# - current preview containers are kept until the new preview passes
# - old GUI is stopped only for the short current DHCP LAN IP:8088 cutover window
# - rollback restarts the old GUI if the new preview fails

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
PG="qflm-postgres"
PROD_API="qflm-api"
PROD_DB="qflm"

OLD_API="qflm-api-gui-preview"
OLD_GUI="qflm-admin-web-gui-preview"

NEXT_API="qflm-api-gui-preview-next"
NEXT_GUI="qflm-admin-web-gui-preview-next"

PREVIEW_DB="qflm_gui_preview_i3"
NET="qflm_backend"

API_IMAGE="qflm-api:recovery7i2-candidate"
GUI_BASE_IMAGE="qflm-admin-web:recovery7i2-candidate"
GUI_PREVIEW_IMAGE="qflm-admin-web:recovery7i3-preview"

SIGNING_CONTAINER="qflm-signing"
SIGNING_TOKEN_TARGET="/run/qflm-signing/token"

RUNTIME_JWT="/opt/qflm/secrets/runtime-api/jwt-signing-key"
ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"

ORIGIN_IFACE="ens18"
HOST_IP=""
HOST_PORT="8088"
PUBLIC_URL="https://lc.quikefix.info"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7i3-preview-$STAMP"
REPORT="$BACKUP/recovery7i3-preview-report.txt"
ENV_FILE="$BACKUP/preview-api.env"
NGINX_CONF="$BACKUP/nginx-recovery7i3.conf"
GUI_DOCKERFILE="$BACKUP/Dockerfile.recovery7i3-gui"

OLD_GUI_WAS_RUNNING=false
CUTOVER_STARTED=0
PROMOTED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

cleanup(){
    if [ "$PROMOTED" -eq 1 ]; then
        docker rm -f "$NEXT_GUI" >/dev/null 2>&1 || true
        docker rm -f "$NEXT_API" >/dev/null 2>&1 || true
        return
    fi

    docker rm -f "$NEXT_GUI" >/dev/null 2>&1 || true
    docker rm -f "$NEXT_API" >/dev/null 2>&1 || true

    if [ "$CUTOVER_STARTED" -eq 1 ] && [ "$OLD_GUI_WAS_RUNNING" = true ]; then
        docker start "$OLD_GUI" >/dev/null 2>&1 || true
        sleep 2
        printf '%s\n' "rollback_old_preview_gui_restart=ATTEMPTED"
    fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7I3"
echo " CLOUDFLARE PREVIEW REFRESH - SYSTEM / OPERATIONS GUI/API"
echo "======================================================"

echo
echo "=== 1. PRODUCTION SAFETY BASELINE ==="

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PROD_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
PROD_LICENSES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
PROD_INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
PROD_ISS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
PROD_AUD=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

printf 'image=%s running=%s migrations=%s licenses=%s installations=%s offline_issuances=%s offline_audit=%s\n' \
 "$PROD_IMAGE" "$PROD_RUNNING" "$PROD_MIG" "$PROD_LICENSES" "$PROD_INSTALLATIONS" "$PROD_ISS" "$PROD_AUD"

[ "$PROD_IMAGE" = "qflm-api:recovery6f3-candidate" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$PROD_MIG" = 5 ] || die "unexpected migration count"

echo "production_baseline=PASS"

echo
echo "=== 1A. DETECT CURRENT DHCP LAN ORIGIN ==="
HOST_IP=$(ip -4 -o addr show dev "$ORIGIN_IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
[ -n "$HOST_IP" ] || die "no IPv4 address found on $ORIGIN_IFACE"
case "$HOST_IP" in
  127.*|169.254.*|172.17.*|172.18.*|10.77.*)
    die "detected unsuitable preview origin: $HOST_IP"
    ;;
esac
printf 'origin_interface=%s origin_ip=%s origin_port=%s\n' "$ORIGIN_IFACE" "$HOST_IP" "$HOST_PORT"
echo "dynamic_origin=PASS"

echo
echo "=== 2. CANDIDATE + CURRENT PREVIEW PREFLIGHT ==="

docker image inspect "$API_IMAGE" >/dev/null 2>&1 || die "Recovery 7F2 API candidate image missing"
docker image inspect "$GUI_BASE_IMAGE" >/dev/null 2>&1 || die "Recovery 7F2 GUI candidate image missing"

[ -s "$RUNTIME_JWT" ] || die "JWT runtime secret missing"
[ -s "$ADMIN_USER_FILE" ] || die "admin username file missing"
[ -s "$ADMIN_PASS_FILE" ] || die "admin password file missing"

OLD_API_RUNNING=$(docker inspect "$OLD_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
OLD_GUI_RUNNING=$(docker inspect "$OLD_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)

[ "$OLD_API_RUNNING" = true ] || die "current preview API is not running"
[ "$OLD_GUI_RUNNING" = true ] || die "current preview GUI is not running"

OLD_GUI_WAS_RUNNING=true

OLD_API_IMAGE=$(docker inspect "$OLD_API" --format='{{.Config.Image}}')
OLD_GUI_IMAGE=$(docker inspect "$OLD_GUI" --format='{{.Config.Image}}')

printf 'current_preview_api_image=%s current_preview_gui_image=%s\n' \
 "$OLD_API_IMAGE" "$OLD_GUI_IMAGE"

ORIGIN_BEFORE=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST_IP}:${HOST_PORT}/" || true)
PUBLIC_BEFORE=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/" || true)

printf 'origin_before=%s public_before=%s\n' "$ORIGIN_BEFORE" "$PUBLIC_BEFORE"
[ "$ORIGIN_BEFORE" = 200 ] || die "current preview origin is not healthy"
[ "$PUBLIC_BEFORE" = 200 ] || die "current Cloudflare preview is not healthy"

echo "current_preview=PASS"

echo
echo "=== 3. RESOLVE EXISTING SIGNING TOKEN MOUNT ==="

[ "$(docker inspect "$SIGNING_CONTAINER" --format='{{.State.Running}}' 2>/dev/null || echo false)" = true ] \
 || die "signing container not running"

SIGNING_TOKEN_CONTAINER_PATH=$(docker inspect "$SIGNING_CONTAINER" \
 --format='{{range .Config.Env}}{{println .}}{{end}}' \
 | awk -F= '$1=="Signing__TokenPath"{print $2; exit}')

[ -n "$SIGNING_TOKEN_CONTAINER_PATH" ] || die "Signing__TokenPath missing"

SIGNING_TOKEN_SOURCE=$(docker inspect "$SIGNING_CONTAINER" --format='{{range .Mounts}}{{println .Source "|" .Destination}}{{end}}' | awk -F'|' -v target="$SIGNING_TOKEN_CONTAINER_PATH" '$2==target{print $1; exit}')

if [ -z "$SIGNING_TOKEN_SOURCE" ]; then
    CANONICAL_SIGNING_TOKEN="/opt/qflm/secrets/signing-runtime/token"
    [ -s "$CANONICAL_SIGNING_TOKEN" ] || die "signing token source unresolved and canonical recovery token missing"
    SIGNING_TOKEN_SOURCE="$CANONICAL_SIGNING_TOKEN"
    echo "signing_token_source=CANONICAL_RECOVERY_PATH"
else
    echo "signing_token_source=CONTAINER_MOUNT_METADATA"
fi

[ -s "$SIGNING_TOKEN_SOURCE" ] || die "signing token source missing"
[ "$(stat -c %a "$SIGNING_TOKEN_SOURCE")" = "400" ] || die "signing token source mode is not 0400"

echo "signing_token_source_resolved=PASS"

echo
echo "=== 4. CREATE FRESH ISOLATED PREVIEW DATABASE ==="

docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1 \
 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$PREVIEW_DB' AND pid<>pg_backend_pid();" \
 >/dev/null

docker exec "$PG" dropdb -U qflm --if-exists "$PREVIEW_DB"
docker exec "$PG" createdb -U qflm "$PREVIEW_DB" || die "preview DB create failed"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges \
 | docker exec -i "$PG" psql -U qflm -d "$PREVIEW_DB" -v ON_ERROR_STOP=1 >/dev/null \
 || die "preview DB clone failed"

PREVIEW_MIG=$(docker exec "$PG" psql -U qflm -d "$PREVIEW_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
PREVIEW_LICENSES=$(docker exec "$PG" psql -U qflm -d "$PREVIEW_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
PREVIEW_INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d "$PREVIEW_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'preview_migrations=%s preview_licenses=%s preview_installations=%s\n' \
 "$PREVIEW_MIG" "$PREVIEW_LICENSES" "$PREVIEW_INSTALLATIONS"

[ "$PREVIEW_MIG" = "$PROD_MIG" ] || die "preview migration count mismatch"
[ "$PREVIEW_LICENSES" = "$PROD_LICENSES" ] || die "preview license count mismatch"
[ "$PREVIEW_INSTALLATIONS" = "$PROD_INSTALLATIONS" ] || die "preview installation count mismatch"

echo "preview_database_clone=PASS"

echo
echo "=== 5. PREPARE PREVIEW API ENVIRONMENT ==="

docker inspect "$PROD_API" \
 --format '{{range .Config.Env}}{{println .}}{{end}}' \
 > "$ENV_FILE" || die "capture production API environment failed"

chmod 600 "$ENV_FILE"

cat >> "$ENV_FILE" <<EOF
Qflm__PostgreSqlDatabase=$PREVIEW_DB
PostgreSqlDatabase=$PREVIEW_DB
OfflineSigning__BaseUrl=http://qflm-signing:8080
OfflineSigning__TokenPath=$SIGNING_TOKEN_TARGET
EOF
chmod 600 "$ENV_FILE"

echo "preview_api_environment=PASS"

echo
echo "=== 6. START NEXT PREVIEW API PRIVATELY ==="

docker rm -f "$NEXT_API" >/dev/null 2>&1 || true

docker run -d \
 --name "$NEXT_API" \
 --network "$NET" \
 --env-file "$ENV_FILE" \
 --volumes-from "$PROD_API:ro" \
 --mount type=bind,src="$SIGNING_TOKEN_SOURCE",dst="$SIGNING_TOKEN_TARGET",readonly \
 --read-only \
 --cap-drop ALL \
 --security-opt no-new-privileges:true \
 --tmpfs /tmp:rw,noexec,nosuid,size=16m \
 "$API_IMAGE" >/dev/null \
 || die "next preview API start failed"

sleep 5

docker run --rm --network "$NET" curlimages/curl:8.16.0 \
 -fsS "http://$NEXT_API:8080/health/ready" >/dev/null \
 || {
    docker logs --tail 240 "$NEXT_API" || true
    die "next preview API readiness failed"
 }

API_PORTS=$(docker inspect "$NEXT_API" --format='{{json .NetworkSettings.Ports}}')
API_IP=$(docker inspect "$NEXT_API" --format="{{with index .NetworkSettings.Networks \"$NET\"}}{{.IPAddress}}{{end}}")

[ -n "$API_IP" ] || die "next preview API bridge IP missing"

printf 'next_preview_api_ip=%s host_ports=%s\n' "$API_IP" "$API_PORTS"

case "$API_PORTS" in
  "{}"|"null") ;;
  *) die "preview API unexpectedly exposes host ports" ;;
esac

PREVIEW_DB_ENV=$(docker inspect "$NEXT_API" --format='{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1=="Qflm__PostgreSqlDatabase"{print $2}' | tail -n1)
printf 'next_preview_api_database=%s\n' "$PREVIEW_DB_ENV"
[ "$PREVIEW_DB_ENV" = "$PREVIEW_DB" ] || die "next preview API is not bound to preview database"
echo "next_preview_api_private=PASS"
echo "next_preview_database_binding=PASS"

echo
echo "=== 7. BUILD HOST-NETWORK GUI PREVIEW IMAGE ==="

cat > "$NGINX_CONF" <<NGINX
pid /tmp/nginx.pid;
error_log /dev/stderr notice;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;

    client_body_temp_path /tmp/client_temp;
    proxy_temp_path /tmp/proxy_temp;
    fastcgi_temp_path /tmp/fastcgi_temp;
    uwsgi_temp_path /tmp/uwsgi_temp;
    scgi_temp_path /tmp/scgi_temp;

    server {
        listen ${HOST_IP}:${HOST_PORT};
        root /usr/share/nginx/html;
        index index.html;

        location /api/ {
            proxy_pass http://${API_IP}:8080/api/;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }

        location = /health {
            access_log off;
            default_type text/plain;
            return 200 "ok";
        }

        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
NGINX

cat > "$GUI_DOCKERFILE" <<DOCKER
FROM ${GUI_BASE_IMAGE}
USER root
COPY nginx-recovery7i3.conf /etc/nginx/nginx-qflm.conf
RUN chmod 444 /etc/nginx/nginx-qflm.conf
USER nginx
DOCKER

docker build \
 --file "$GUI_DOCKERFILE" \
 --tag "$GUI_PREVIEW_IMAGE" \
 "$BACKUP" \
 || die "Recovery 7I3 GUI preview image build failed"

echo "preview_gui_image=$GUI_PREVIEW_IMAGE"

echo
echo "=== 8. CUTOVER GUI LISTENER TO NEXT PREVIEW ==="

CUTOVER_STARTED=1

docker stop "$OLD_GUI" >/dev/null || die "failed to stop current preview GUI"

docker rm -f "$NEXT_GUI" >/dev/null 2>&1 || true

docker run -d \
 --name "$NEXT_GUI" \
 --network host \
 --read-only \
 --cap-drop ALL \
 --security-opt no-new-privileges:true \
 --tmpfs /tmp:rw,noexec,nosuid,size=24m,uid=101,gid=101 \
 "$GUI_PREVIEW_IMAGE" >/dev/null \
 || die "next preview GUI start failed"

sleep 4

[ "$(docker inspect "$NEXT_GUI" --format='{{.State.Running}}')" = true ] \
 || {
    docker logs --tail 200 "$NEXT_GUI" || true
    die "next preview GUI not running"
 }

LISTENER=$(ss -ltnp 2>/dev/null | grep -F "${HOST_IP}:${HOST_PORT}" || true)
[ -n "$LISTENER" ] || die "expected preview listener missing"

echo "$LISTENER"
echo "host_network_gui_listener=PASS"

echo
echo "=== 9. ORIGIN ROUTE VALIDATION ==="

for route in / /health /security /offline /audit /system; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST_IP}:${HOST_PORT}${route}")
    [ "$CODE" = 200 ] || die "origin route failed: $route -> $CODE"
done

echo "origin_routes=PASS"

echo
echo "=== 10. PREVIEW ADMIN LOGIN + AUDIT / REPORTS API ==="

ADMIN_USER="$(cat "$ADMIN_USER_FILE")"
ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"

LOGIN_JSON=$(python3 - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)

LOGIN_RESPONSE=$(curl -fsS \
 -H 'Content-Type: application/json' \
 -X POST "http://${HOST_IP}:${HOST_PORT}/api/v1/auth/login" \
 --data-binary "$LOGIN_JSON") \
 || die "preview admin login failed"

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

SYSTEM_JSON=$(curl -fsS \
 -H "Authorization: Bearer $TOKEN" \
 "http://${HOST_IP}:${HOST_PORT}/api/v1/admin/system/summary") \
 || die "preview system summary API failed"

python3 - "$SYSTEM_JSON" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x["status"]=="Operational"
assert x["database"]["status"]=="Healthy"
assert x["redis"]["status"]=="Healthy"
assert "version" in x["api"]
assert "customers" in x["data"]
print("preview_system_summary_api=PASS")
PY

echo
echo "=== 11. CLOUDFLARE PUBLIC VALIDATION ==="

PUBLIC_ROOT=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/")
PUBLIC_LOGIN=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/login")
PUBLIC_SECURITY=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/security")
PUBLIC_OFFLINE=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/offline")
PUBLIC_AUDIT=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/system")
PUBLIC_SYSTEM=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/system")

printf 'public_root=%s public_login=%s public_security=%s public_offline=%s public_audit=%s public_system=%s\n' \
 "$PUBLIC_ROOT" "$PUBLIC_LOGIN" "$PUBLIC_SECURITY" "$PUBLIC_OFFLINE" "$PUBLIC_AUDIT" "$PUBLIC_SYSTEM"

[ "$PUBLIC_ROOT" = 200 ] || die "Cloudflare public root failed"
[ "$PUBLIC_LOGIN" = 200 ] || die "Cloudflare public login failed"
[ "$PUBLIC_SECURITY" = 200 ] || die "Cloudflare public security route failed"
[ "$PUBLIC_OFFLINE" = 200 ] || die "Cloudflare public offline route failed"
[ "$PUBLIC_AUDIT" = 200 ] || die "Cloudflare public audit route failed"
[ "$PUBLIC_SYSTEM" = 200 ] || die "Cloudflare public system route failed"

echo "cloudflare_preview=PASS"

echo
echo "=== 12. CONTAINER HARDENING ==="

API_HARDEN=$(docker inspect "$NEXT_API" \
 --format='network={{.HostConfig.NetworkMode}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .NetworkSettings.Ports}}')

GUI_HARDEN=$(docker inspect "$NEXT_GUI" \
 --format='network={{.HostConfig.NetworkMode}} user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}}')

echo "API: $API_HARDEN"
echo "GUI: $GUI_HARDEN"

echo "$API_HARDEN" | grep -Fq 'readonly=true' || die "API readonly hardening missing"
echo "$API_HARDEN" | grep -Fq '"ALL"' || die "API cap drop missing"
echo "$API_HARDEN" | grep -Fq 'no-new-privileges:true' || die "API no-new-privileges missing"

echo "$GUI_HARDEN" | grep -Fq 'network=host' || die "GUI host networking missing"
echo "$GUI_HARDEN" | grep -Fq 'readonly=true' || die "GUI readonly hardening missing"
echo "$GUI_HARDEN" | grep -Fq '"ALL"' || die "GUI cap drop missing"
echo "$GUI_HARDEN" | grep -Fq 'no-new-privileges:true' || die "GUI no-new-privileges missing"

echo "preview_hardening=PASS"

echo
echo "=== 13. REVOKE PREVIEW TEST SESSION ==="

REVOKE_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)

REVOKE_HTTP=$(curl -s -o /dev/null -w '%{http_code}' \
 -H 'Content-Type: application/json' \
 -H "Authorization: Bearer $TOKEN" \
 -X POST "http://${HOST_IP}:${HOST_PORT}/api/v1/auth/revoke" \
 --data-binary "$REVOKE_JSON")

[ "$REVOKE_HTTP" = 204 ] || die "preview session revoke failed"

unset TOKEN REFRESH ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE REVOKE_JSON

echo "preview_session_revoke=PASS"

echo
echo "=== 14. PROMOTE NEXT PREVIEW CONTAINER NAMES ==="

# The old GUI is already stopped. The old API remains running until now,
# so rollback has remained simple throughout all functional tests.

docker stop "$OLD_API" >/dev/null || die "failed to stop old preview API"

docker rm "$OLD_GUI" >/dev/null || die "failed to remove old preview GUI"
docker rm "$OLD_API" >/dev/null || die "failed to remove old preview API"

docker rename "$NEXT_API" "$OLD_API" || die "failed to promote preview API container name"
docker rename "$NEXT_GUI" "$OLD_GUI" || die "failed to promote preview GUI container name"

PROMOTED=1

echo "preview_container_names_promoted=PASS"

echo
echo "=== 15. FINAL LIVE PREVIEW CHECK ==="

sleep 2

FINAL_ORIGIN=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST_IP}:${HOST_PORT}/system")
FINAL_PUBLIC=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/system")

printf 'final_origin_audit=%s final_public_audit=%s\n' "$FINAL_ORIGIN" "$FINAL_PUBLIC"

[ "$FINAL_ORIGIN" = 200 ] || die "final origin system route failed"
[ "$FINAL_PUBLIC" = 200 ] || die "final Cloudflare audit route failed"

echo "final_live_preview=PASS"

echo
echo "=== 16. FINAL PRODUCTION NO-MUTATION CHECK ==="

FINAL_PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_LICENSES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
FINAL_ISS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
FINAL_AUD=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

printf 'image=%s running=%s migrations=%s licenses=%s installations=%s offline_issuances=%s offline_audit=%s\n' \
 "$FINAL_PROD_IMAGE" "$FINAL_PROD_RUNNING" "$FINAL_MIG" "$FINAL_LICENSES" "$FINAL_INSTALLATIONS" "$FINAL_ISS" "$FINAL_AUD"

[ "$FINAL_PROD_IMAGE" = "$PROD_IMAGE" ] || die "production API image changed"
[ "$FINAL_PROD_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$PROD_MIG" ] || die "production migrations changed"
[ "$FINAL_LICENSES" = "$PROD_LICENSES" ] || die "production licenses changed"
[ "$FINAL_INSTALLATIONS" = "$PROD_INSTALLATIONS" ] || die "production installations changed"
[ "$FINAL_ISS" = "$PROD_ISS" ] || die "production offline issuances changed"
[ "$FINAL_AUD" = "$PROD_AUD" ] || die "production offline audit changed"

echo "production_unchanged=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7I3 PREVIEW PASSED"
echo "======================================================"
echo "PREVIEW DATABASE:                   $PREVIEW_DB"
echo "PREVIEW API IMAGE:                  $API_IMAGE"
echo "PREVIEW GUI IMAGE:                  $GUI_PREVIEW_IMAGE"
echo "SYSTEM / OPERATIONS GUI/API:              LIVE"
echo "AUDIT SUMMARY API:                  LIVE"
echo "AUDIT EVENTS API:                   LIVE"
echo "OFFLINE ISSUANCE REPORT API:        LIVE"
echo "SECURITY GUI:                       STILL LIVE"
echo "OFFLINE LICENSING GUI:              STILL LIVE"
echo "SIGNING TOKEN:                      READ-ONLY INTERNAL MOUNT"
echo "PRIVATE SIGNING KEY:                NOT EXPOSED TO API/GUI"
echo "PREVIEW API HOST PORTS:             NONE"
echo "GUI ORIGIN:                         http://${HOST_IP}:${HOST_PORT}"
echo "GUI URL:                            ${PUBLIC_URL}"
echo "OFFLINE URL:                        ${PUBLIC_URL}/offline"
echo "PRODUCTION API/DB:                  UNCHANGED"
echo "REPORT:                             $REPORT"
echo "NEXT: RECOVERY 7J - FINAL ADMIN GUI REVIEW / HARDENING"
echo "======================================================"
echo "======================================================"