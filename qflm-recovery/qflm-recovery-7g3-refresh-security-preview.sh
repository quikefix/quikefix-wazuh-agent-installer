#!/usr/bin/env bash
# QFLM RECOVERY 7G3
# Refresh Cloudflare preview with validated Security Admin GUI.
# Existing preview API/database remain unchanged.
# Production API/database remain unchanged.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
PG="qflm-postgres"
PROD_API="qflm-api"
PROD_DB="qflm"

PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"
NEXT_GUI="qflm-admin-web-recovery7g3-preview-next"

NET="qflm_backend"
GUI_BASE_IMAGE="qflm-admin-web:recovery7g2-candidate"
GUI_PREVIEW_IMAGE="qflm-admin-web:recovery7g3-preview"

ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"

ORIGIN_IFACE="ens18"
HOST_IP=""
HOST_PORT="8088"
PUBLIC_URL="https://lc.quikefix.info"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7g3-preview-$STAMP"
REPORT="$BACKUP/recovery7g3-preview-report.txt"
NGINX_CONF="$BACKUP/nginx-recovery7g3.conf"
GUI_DOCKERFILE="$BACKUP/Dockerfile.recovery7g3-gui"

OLD_GUI_WAS_RUNNING=false
CUTOVER_STARTED=0
PROMOTED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

cleanup(){
    if [ "$PROMOTED" -eq 1 ]; then
        docker rm -f "$NEXT_GUI" >/dev/null 2>&1 || true
        return
    fi

    docker rm -f "$NEXT_GUI" >/dev/null 2>&1 || true

    if [ "$CUTOVER_STARTED" -eq 1 ] && [ "$OLD_GUI_WAS_RUNNING" = true ]; then
        docker start "$PREVIEW_GUI" >/dev/null 2>&1 || true
        sleep 2
        printf '%s\n' "rollback_old_preview_gui_restart=ATTEMPTED"
    fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7G3"
echo " CLOUDFLARE PREVIEW REFRESH - SECURITY ADMIN GUI"
echo "======================================================"

echo
echo "=== 1. PRODUCTION SAFETY BASELINE ==="

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PROD_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
PROD_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
PROD_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PROD_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

printf 'image=%s running=%s migrations=%s users=%s roles=%s permissions=%s\n' \
 "$PROD_IMAGE" "$PROD_RUNNING" "$PROD_MIG" "$PROD_USERS" "$PROD_ROLES" "$PROD_PERMS"

[ "$PROD_IMAGE" = "qflm-api:recovery6f3-candidate" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$PROD_MIG" = 5 ] || die "unexpected migration count"

echo "production_baseline=PASS"

echo
echo "=== 1A. DETECT CURRENT DHCP LAN ORIGIN ==="
HOST_IP=$(ip -4 -o addr show dev "$ORIGIN_IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
[ -n "$HOST_IP" ] || die "no IPv4 address found on $ORIGIN_IFACE"
printf 'origin_interface=%s origin_ip=%s origin_port=%s\n' "$ORIGIN_IFACE" "$HOST_IP" "$HOST_PORT"
echo "dynamic_origin=PASS"

echo
echo "=== 2. CURRENT PREVIEW + CANDIDATE PREFLIGHT ==="

docker image inspect "$GUI_BASE_IMAGE" >/dev/null 2>&1 || die "Recovery 7G2 GUI candidate image missing"

PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE_OLD=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)

[ "$PREVIEW_API_RUNNING" = true ] || die "preview API not running"
[ "$PREVIEW_GUI_RUNNING" = true ] || die "preview GUI not running"
[ "$PREVIEW_API_IMAGE" = "qflm-api:recovery7f2-candidate" ] || die "unexpected preview API image"
[ "$PREVIEW_GUI_IMAGE_OLD" = "qflm-admin-web:recovery7f3-preview" ] || die "unexpected preview GUI image"

OLD_GUI_WAS_RUNNING=true

PREVIEW_API_IP=$(docker inspect "$PREVIEW_API" \
 --format="{{with index .NetworkSettings.Networks \"$NET\"}}{{.IPAddress}}{{end}}")

[ -n "$PREVIEW_API_IP" ] || die "preview API bridge IP missing"

printf 'preview_api_image=%s preview_gui_image=%s preview_api_ip=%s\n' \
 "$PREVIEW_API_IMAGE" "$PREVIEW_GUI_IMAGE_OLD" "$PREVIEW_API_IP"

ORIGIN_BEFORE=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST_IP}:${HOST_PORT}/" || true)
PUBLIC_BEFORE=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/" || true)
PUBLIC_OFFLINE_BEFORE=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/offline" || true)

printf 'origin_before=%s public_before=%s offline_before=%s\n' \
 "$ORIGIN_BEFORE" "$PUBLIC_BEFORE" "$PUBLIC_OFFLINE_BEFORE"

[ "$ORIGIN_BEFORE" = 200 ] || die "current preview origin is not healthy"
[ "$PUBLIC_BEFORE" = 200 ] || die "current public preview is not healthy"
[ "$PUBLIC_OFFLINE_BEFORE" = 200 ] || die "current offline route is not healthy"

[ -s "$ADMIN_USER_FILE" ] || die "admin username file missing"
[ -s "$ADMIN_PASS_FILE" ] || die "admin password file missing"

echo "preview_preflight=PASS"

echo
echo "=== 3. BUILD PHASE 16G.3 HOST-NETWORK GUI IMAGE ==="

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
            proxy_pass http://${PREVIEW_API_IP}:8080/api/;
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
COPY nginx-recovery7g3.conf /etc/nginx/nginx-qflm.conf
RUN chmod 444 /etc/nginx/nginx-qflm.conf
USER nginx
DOCKER

docker build \
 --file "$GUI_DOCKERFILE" \
 --tag "$GUI_PREVIEW_IMAGE" \
 "$BACKUP" \
 || die "Recovery 7G3 GUI image build failed"

echo "preview_gui_image=$GUI_PREVIEW_IMAGE"

echo
echo "=== 4. CUTOVER GUI LISTENER ==="

CUTOVER_STARTED=1

docker stop "$PREVIEW_GUI" >/dev/null || die "failed to stop current preview GUI"
docker rm -f "$NEXT_GUI" >/dev/null 2>&1 || true

docker run -d \
 --name "$NEXT_GUI" \
 --network host \
 --read-only \
 --cap-drop ALL \
 --security-opt no-new-privileges:true \
 --tmpfs /tmp:rw,noexec,nosuid,size=24m,uid=101,gid=101 \
 "$GUI_PREVIEW_IMAGE" >/dev/null \
 || die "new preview GUI start failed"

sleep 4

[ "$(docker inspect "$NEXT_GUI" --format='{{.State.Running}}')" = true ] \
 || {
    docker logs --tail 200 "$NEXT_GUI" || true
    die "new preview GUI is not running"
 }

LISTENER=$(ss -ltnp 2>/dev/null | grep -F "${HOST_IP}:${HOST_PORT}" || true)
[ -n "$LISTENER" ] || die "expected preview listener missing"

echo "$LISTENER"
echo "host_network_gui_listener=PASS"

echo
echo "=== 5. ORIGIN ROUTE VALIDATION ==="

ORIGIN_ROOT=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST_IP}:${HOST_PORT}/")
ORIGIN_HEALTH=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST_IP}:${HOST_PORT}/health")
ORIGIN_SECURITY=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST_IP}:${HOST_PORT}/security")
ORIGIN_OFFLINE=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST_IP}:${HOST_PORT}/offline")

printf 'origin_root=%s health=%s security=%s offline=%s\n' \
 "$ORIGIN_ROOT" "$ORIGIN_HEALTH" "$ORIGIN_SECURITY" "$ORIGIN_OFFLINE"

[ "$ORIGIN_ROOT" = 200 ] || die "origin root failed"
[ "$ORIGIN_HEALTH" = 200 ] || die "origin health failed"
[ "$ORIGIN_SECURITY" = 200 ] || die "origin security route failed"
[ "$ORIGIN_OFFLINE" = 200 ] || die "origin offline route regressed"

echo "origin_routes=PASS"

echo
echo "=== 6. SECURITY ADMIN LOGIN + READ API VALIDATION ==="

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

USERS_JSON=$(curl -fsS \
 -H "Authorization: Bearer $TOKEN" \
 "http://${HOST_IP}:${HOST_PORT}/api/v1/admin/security/users") \
 || die "security users API failed"

ROLES_JSON=$(curl -fsS \
 -H "Authorization: Bearer $TOKEN" \
 "http://${HOST_IP}:${HOST_PORT}/api/v1/admin/security/roles") \
 || die "security roles API failed"

PERMS_JSON=$(curl -fsS \
 -H "Authorization: Bearer $TOKEN" \
 "http://${HOST_IP}:${HOST_PORT}/api/v1/admin/security/permissions") \
 || die "security permissions API failed"

COUNTS=$(python3 - "$USERS_JSON" "$ROLES_JSON" "$PERMS_JSON" <<'PY'
import json,sys
print(
    len(json.loads(sys.argv[1])),
    len(json.loads(sys.argv[2])),
    len(json.loads(sys.argv[3]))
)
PY
)

read -r USERS_COUNT ROLES_COUNT PERMS_COUNT <<<"$COUNTS"

[ "$USERS_COUNT" -ge 1 ] || die "security users list empty"
[ "$ROLES_COUNT" -ge 1 ] || die "security roles list empty"
[ "$PERMS_COUNT" -eq 22 ] || die "unexpected permission count"

printf 'security_users=%s security_roles=%s security_permissions=%s\n' \
 "$USERS_COUNT" "$ROLES_COUNT" "$PERMS_COUNT"

echo "security_read_apis=PASS"

echo
echo "=== 7. CLOUDFLARE PUBLIC VALIDATION ==="

PUBLIC_ROOT=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/")
PUBLIC_LOGIN=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/login")
PUBLIC_SECURITY=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/security")
PUBLIC_OFFLINE=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/offline")

printf 'public_root=%s login=%s security=%s offline=%s\n' \
 "$PUBLIC_ROOT" "$PUBLIC_LOGIN" "$PUBLIC_SECURITY" "$PUBLIC_OFFLINE"

[ "$PUBLIC_ROOT" = 200 ] || die "public root failed"
[ "$PUBLIC_LOGIN" = 200 ] || die "public login failed"
[ "$PUBLIC_SECURITY" = 200 ] || die "public security route failed"
[ "$PUBLIC_OFFLINE" = 200 ] || die "public offline route regressed"

echo "cloudflare_preview=PASS"

echo
echo "=== 8. GUI HARDENING ==="

GUI_HARDEN=$(docker inspect "$NEXT_GUI" \
 --format='network={{.HostConfig.NetworkMode}} user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}}')

echo "$GUI_HARDEN"

echo "$GUI_HARDEN" | grep -Fq 'network=host' || die "GUI host-network mode missing"
echo "$GUI_HARDEN" | grep -Fq 'user=nginx' || die "GUI nonroot user missing"
echo "$GUI_HARDEN" | grep -Fq 'readonly=true' || die "GUI readonly rootfs missing"
echo "$GUI_HARDEN" | grep -Fq '"ALL"' || die "GUI cap drop missing"
echo "$GUI_HARDEN" | grep -Fq 'no-new-privileges:true' || die "GUI no-new-privileges missing"

echo "preview_gui_hardening=PASS"

echo
echo "=== 9. REVOKE PREVIEW TEST SESSION ==="

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

unset ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE TOKEN REFRESH REVOKE_JSON USERS_JSON ROLES_JSON PERMS_JSON

echo "preview_session_revoke=PASS"

echo
echo "=== 10. PROMOTE PREVIEW GUI CONTAINER NAME ==="

docker rm "$PREVIEW_GUI" >/dev/null || die "failed to remove old preview GUI"
docker rename "$NEXT_GUI" "$PREVIEW_GUI" || die "failed to promote new preview GUI name"

PROMOTED=1

echo "preview_gui_container_promoted=PASS"

echo
echo "=== 11. FINAL LIVE PREVIEW CHECK ==="

sleep 2

FINAL_ORIGIN_SECURITY=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST_IP}:${HOST_PORT}/security")
FINAL_PUBLIC_SECURITY=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/security")
FINAL_PUBLIC_OFFLINE=$(curl -L -s -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/offline")

printf 'final_origin_security=%s final_public_security=%s final_public_offline=%s\n' \
 "$FINAL_ORIGIN_SECURITY" "$FINAL_PUBLIC_SECURITY" "$FINAL_PUBLIC_OFFLINE"

[ "$FINAL_ORIGIN_SECURITY" = 200 ] || die "final origin security route failed"
[ "$FINAL_PUBLIC_SECURITY" = 200 ] || die "final public security route failed"
[ "$FINAL_PUBLIC_OFFLINE" = 200 ] || die "final public offline route regressed"

echo "final_live_preview=PASS"

echo
echo "=== 12. FINAL PRODUCTION NO-MUTATION CHECK ==="

FINAL_PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

printf 'image=%s running=%s migrations=%s users=%s roles=%s permissions=%s\n' \
 "$FINAL_PROD_IMAGE" "$FINAL_PROD_RUNNING" "$FINAL_MIG" "$FINAL_USERS" "$FINAL_ROLES" "$FINAL_PERMS"

[ "$FINAL_PROD_IMAGE" = "$PROD_IMAGE" ] || die "production API image changed"
[ "$FINAL_PROD_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$PROD_MIG" ] || die "production migrations changed"
[ "$FINAL_USERS" = "$PROD_USERS" ] || die "production users changed"
[ "$FINAL_ROLES" = "$PROD_ROLES" ] || die "production roles changed"
[ "$FINAL_PERMS" = "$PROD_PERMS" ] || die "production permissions changed"

echo "production_unchanged=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7G3 PREVIEW PASSED"
echo "======================================================"
echo "SECURITY ADMIN GUI:                 LIVE"
echo "SECURITY USERS API:                 LIVE"
echo "SECURITY ROLES API:                 LIVE"
echo "SECURITY PERMISSIONS API:           LIVE"
echo "OFFLINE LICENSING GUI:              STILL LIVE"
echo "PREVIEW API:                        UNCHANGED"
echo "PREVIEW GUI IMAGE:                  $GUI_PREVIEW_IMAGE"
echo "PREVIEW GUI HARDENING:              PASS"
echo "GUI URL:                            ${PUBLIC_URL}"
echo "SECURITY URL:                       ${PUBLIC_URL}/security"
echo "OFFLINE URL:                        ${PUBLIC_URL}/offline"
echo "PRODUCTION API/DB:                  UNCHANGED"
echo "REPORT:                             $REPORT"
echo "NEXT: RECOVERY 7H - AUDIT & REPORTS GUI"
echo "======================================================"