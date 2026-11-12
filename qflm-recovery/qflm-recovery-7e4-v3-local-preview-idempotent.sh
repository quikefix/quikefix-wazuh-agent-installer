#!/usr/bin/env bash
# QFLM RECOVERY 7E4
# Refresh Cloudflare GUI preview with Recovery 7E2 Installations GUI/API.
# Preview uses isolated cloned DB. Production API/DB/Compose remain unchanged.

set -u
set -o pipefail
umask 077

PROD_API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"
NET="qflm_backend"

EXPECTED_PROD_IMAGE="qflm-api:recovery6f3-candidate"
API_IMAGE="qflm-api:recovery7e2-candidate"
GUI_BASE_IMAGE="qflm-admin-web:recovery7e2-candidate"
GUI_PREVIEW_IMAGE="qflm-admin-web:recovery7e4-preview"

PREVIEW_DB="qflm_gui_preview"
PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"

ORIGIN_PORT="8088"
ORIGIN_IFACE="ens18"
ORIGIN_IP=""
CF_HOSTNAME="lc.quikefix.info"

ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"
RUNTIME_JWT="/opt/qflm/secrets/runtime-api/jwt-signing-key"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7e4-preview-$STAMP"
REPORT="$BACKUP/recovery7e4-preview-report.txt"
ENV_FILE="$BACKUP/preview-api.env"
NGINX_CONF="$BACKUP/nginx-preview.conf"
DOCKERFILE="$BACKUP/Dockerfile.preview-gui"

COMPLETED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

cleanup_failure(){
    if [ "$COMPLETED" -ne 1 ]; then
        printf '\n=== PREVIEW CLEANUP AFTER FAILURE ===\n'
        docker rm -f "$PREVIEW_GUI" >/dev/null 2>&1 || true
        docker rm -f "$PREVIEW_API" >/dev/null 2>&1 || true
        printf '%s\n' "preview_cleanup_attempted=YES"
    fi
}
trap cleanup_failure EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7E4"
printf '%s\n' " REFRESH CLOUDFLARE PREVIEW"
printf '%s\n' " INSTALLATIONS GUI + RECOVERY 7E2 API"
printf '%s\n' "======================================================"

printf '\n=== 1. PRODUCTION SAFETY BASELINE ===\n'

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PROD_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
PROD_LICS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
PROD_INST=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'image=%s running=%s migrations=%s licenses=%s installations=%s\n' \
  "$PROD_IMAGE" "$PROD_RUNNING" "$PROD_MIG" "$PROD_LICS" "$PROD_INST"

[ "$PROD_IMAGE" = "$EXPECTED_PROD_IMAGE" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$PROD_MIG" = 5 ] || die "unexpected migration count"
[ -s "$ADMIN_USER_FILE" ] || die "platform admin username missing"
[ -s "$ADMIN_PASS_FILE" ] || die "platform admin password missing"
[ -s "$RUNTIME_JWT" ] || die "JWT runtime secret missing"

docker image inspect "$API_IMAGE" >/dev/null 2>&1 || die "Recovery 7E2 API candidate image missing"
docker image inspect "$GUI_BASE_IMAGE" >/dev/null 2>&1 || die "Recovery 7E2 GUI candidate image missing"

printf '%s\n' "production_baseline=PASS"
printf '%s\n' "phase16e2_candidate_images=PASS"

printf '\n=== 2. DETECT CURRENT LAN ORIGIN ===\n'
ORIGIN_IP=$(ip -4 -o addr show dev "$ORIGIN_IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)

[ -n "$ORIGIN_IP" ] || die "no IPv4 address found on $ORIGIN_IFACE"

case "$ORIGIN_IP" in
  127.*|169.254.*|172.17.*|172.18.*|10.77.*)
    die "detected unsuitable origin address: $ORIGIN_IP"
    ;;
esac

printf 'origin_interface=%s origin_ip=%s origin_port=%s\n' "$ORIGIN_IFACE" "$ORIGIN_IP" "$ORIGIN_PORT"
printf '%s\n' "origin_address=PASS"

printf '\n=== 3. REMOVE EXPECTED OLD QFLM PREVIEW ===\n'
docker rm -f "$PREVIEW_GUI" >/dev/null 2>&1 || true
docker rm -f "$PREVIEW_API" >/dev/null 2>&1 || true
sleep 1

if ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)${ORIGIN_PORT}$"; then
  ss -ltnp | grep ":${ORIGIN_PORT}" || true
  die "origin port $ORIGIN_PORT is occupied by a non-QFLM process"
fi

printf '%s\n' "old_preview_removed=PASS"
printf '\n=== 4. REFRESH PREVIEW DATABASE FROM PRODUCTION ===\n'

docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1 \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$PREVIEW_DB' AND pid<>pg_backend_pid();" \
  >/dev/null

docker exec "$PG" dropdb -U qflm --if-exists "$PREVIEW_DB"
docker exec "$PG" createdb -U qflm "$PREVIEW_DB" || die "preview DB create failed"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges \
  | docker exec -i "$PG" psql -U qflm -d "$PREVIEW_DB" -v ON_ERROR_STOP=1 >/dev/null \
  || die "preview DB clone failed"

PREVIEW_MIG=$(docker exec "$PG" psql -U qflm -d "$PREVIEW_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
PREVIEW_LICS=$(docker exec "$PG" psql -U qflm -d "$PREVIEW_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
PREVIEW_INST=$(docker exec "$PG" psql -U qflm -d "$PREVIEW_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

[ "$PREVIEW_MIG" = "$PROD_MIG" ] || die "preview migration mismatch"
[ "$PREVIEW_LICS" = "$PROD_LICS" ] || die "preview license count mismatch"
[ "$PREVIEW_INST" = "$PROD_INST" ] || die "preview installation count mismatch"

printf 'preview_migrations=%s licenses=%s installations=%s\n' \
  "$PREVIEW_MIG" "$PREVIEW_LICS" "$PREVIEW_INST"

printf '%s\n' "preview_database_clone=PASS"

printf '\n=== 5. PREPARE PREVIEW API ENVIRONMENT ===\n'

docker inspect "$PROD_API" \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  > "$ENV_FILE" \
  || die "capture production environment failed"

chmod 600 "$ENV_FILE"

cat >> "$ENV_FILE" <<EOF
Qflm__PostgreSqlDatabase=$PREVIEW_DB
PostgreSqlDatabase=$PREVIEW_DB
EOF
chmod 600 "$ENV_FILE"

printf '%s\n' "preview_api_environment=PASS"

printf '\n=== 6. START RECOVERY 7E2 PREVIEW API ===\n'

docker run -d \
  --name "$PREVIEW_API" \
  --restart unless-stopped \
  --network "$NET" \
  --env-file "$ENV_FILE" \
  --volumes-from "$PROD_API:ro" \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  "$API_IMAGE" >/dev/null \
  || die "preview API start failed"

sleep 5

[ "$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}')" = true ] \
  || {
      docker logs --tail 160 "$PREVIEW_API" || true
      die "preview API not running"
  }

docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -fsS "http://$PREVIEW_API:8080/health/ready" >/dev/null \
  || {
      docker logs --tail 160 "$PREVIEW_API" || true
      die "preview API readiness failed"
  }

API_IP=$(docker inspect "$PREVIEW_API" \
  --format="{{with index .NetworkSettings.Networks \"$NET\"}}{{.IPAddress}}{{end}}")

[ -n "$API_IP" ] || die "preview API bridge IP unavailable"

printf 'preview_api_ip=%s host_ports=NONE\n' "$API_IP"
PREVIEW_DB_ENV=$(docker inspect "$PREVIEW_API" --format='{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1=="Qflm__PostgreSqlDatabase"{print $2}' | tail -n1)
[ "$PREVIEW_DB_ENV" = "$PREVIEW_DB" ] || die "preview API is not bound to preview database"
printf 'preview_api_database=%s\n' "$PREVIEW_DB_ENV"
printf '%s\n' "preview_api_health=PASS"

printf '\n=== 7. BUILD CLOUDFLARE PREVIEW GUI IMAGE ===\n'

cat > "$NGINX_CONF" <<EOF
pid /tmp/nginx.pid;
error_log /dev/stderr notice;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;
    sendfile on;

    client_body_temp_path /tmp/client_temp;
    proxy_temp_path /tmp/proxy_temp;
    fastcgi_temp_path /tmp/fastcgi_temp;
    uwsgi_temp_path /tmp/uwsgi_temp;
    scgi_temp_path /tmp/scgi_temp;

    server {
        listen ${ORIGIN_IP}:${ORIGIN_PORT};
        server_name _;

        root /usr/share/nginx/html;
        index index.html;

        location /api/ {
            proxy_pass http://${API_IP}:8080/api/;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$http_x_forwarded_proto;
        }

        location = /health {
            access_log off;
            default_type text/plain;
            return 200 "ok\n";
        }

        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF

cat > "$DOCKERFILE" <<'DOCKER'
FROM qflm-admin-web:recovery7e2-candidate
USER root
COPY nginx-preview.conf /etc/nginx/nginx-qflm-preview.conf
RUN chown root:root /etc/nginx/nginx-qflm-preview.conf \
    && chmod 444 /etc/nginx/nginx-qflm-preview.conf
USER nginx
ENTRYPOINT ["nginx","-c","/etc/nginx/nginx-qflm-preview.conf","-g","daemon off;"]
DOCKER

docker build \
  -f "$DOCKERFILE" \
  -t "$GUI_PREVIEW_IMAGE" \
  "$BACKUP" \
  || die "preview GUI image build failed"

printf 'preview_gui_image=%s\n' "$GUI_PREVIEW_IMAGE"

printf '\n=== 8. START HOST-NETWORK GUI ===\n'

docker run -d \
  --name "$PREVIEW_GUI" \
  --restart unless-stopped \
  --network host \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,size=24m,uid=101,gid=101 \
  "$GUI_PREVIEW_IMAGE" >/dev/null \
  || die "preview GUI start failed"

sleep 3

[ "$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}')" = true ] \
  || {
      docker logs --tail 160 "$PREVIEW_GUI" || true
      die "preview GUI not running"
  }

printf '%s\n' "preview_gui_running=PASS"

printf '\n=== 9. VERIFY ORIGIN + INSTALLATIONS ROUTE ===\n'

ss -ltnp | grep -F "${ORIGIN_IP}:${ORIGIN_PORT}" || {
    docker logs --tail 160 "$PREVIEW_GUI" || true
    die "host listener missing"
}

ROOT_HTTP=$(curl --max-time 10 -sS -o /dev/null -w '%{http_code}' \
  "http://${ORIGIN_IP}:${ORIGIN_PORT}/")

HEALTH_HTTP=$(curl --max-time 10 -sS -o /dev/null -w '%{http_code}' \
  "http://${ORIGIN_IP}:${ORIGIN_PORT}/health")

INSTALL_HTTP=$(curl --max-time 10 -sS -o /dev/null -w '%{http_code}' \
  "http://${ORIGIN_IP}:${ORIGIN_PORT}/installations")

printf 'root=%s health=%s installations=%s\n' \
  "$ROOT_HTTP" "$HEALTH_HTTP" "$INSTALL_HTTP"

[ "$ROOT_HTTP" = 200 ] || die "origin root failed"
[ "$HEALTH_HTTP" = 200 ] || die "origin health failed"
[ "$INSTALL_HTTP" = 200 ] || die "installations route failed"

printf '%s\n' "origin_routes=PASS"

printf '\n=== 10. LOGIN + INSTALLATION API THROUGH PREVIEW ===\n'

ADMIN_USER="$(cat "$ADMIN_USER_FILE")"
ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"

LOGIN_JSON=$(python3 - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import json,sys
print(json.dumps({"username": sys.argv[1], "password": sys.argv[2]}))
PY
)

LOGIN_RESPONSE=$(printf '%s' "$LOGIN_JSON" \
  | curl --max-time 15 -sS \
      -H 'Content-Type: application/json' \
      -X POST "http://${ORIGIN_IP}:${ORIGIN_PORT}/api/v1/auth/login" \
      --data-binary @-) \
  || die "preview login failed"

TOKEN=$(python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["accessToken"])
PY
)

[ -n "$TOKEN" ] || die "access token missing"

INSTALL_JSON=$(curl --max-time 15 -sS \
  -H "Authorization: Bearer $TOKEN" \
  "http://${ORIGIN_IP}:${ORIGIN_PORT}/api/v1/admin/installations") \
  || die "preview installation API failed"

INSTALL_COUNT=$(python3 - "$INSTALL_JSON" <<'PY'
import json,sys
print(len(json.loads(sys.argv[1])))
PY
)

[ "$INSTALL_COUNT" -eq "$PROD_INST" ] || die "preview installation API count mismatch"

printf 'preview_login=PASS installation_count=%s\n' "$INSTALL_COUNT"

unset ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE TOKEN INSTALL_JSON

printf '\n=== 11. CLOUDFLARE DEFERRED ===\n'
printf '%s\n' "cloudflare_modified=NO"
printf '%s\n' "cloudflare_reconnect=DEFERRED_TO_RECOVERY_7E5"

printf '\n=== 12. HARDENING CHECK ===\n'

API_SEC=$(docker inspect "$PREVIEW_API" \
  --format='network={{.HostConfig.NetworkMode}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .HostConfig.PortBindings}}')

GUI_SEC=$(docker inspect "$PREVIEW_GUI" \
  --format='network={{.HostConfig.NetworkMode}} user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}}')

printf 'preview_api_security=%s\n' "$API_SEC"
printf 'preview_gui_security=%s\n' "$GUI_SEC"

printf '%s' "$API_SEC" | grep -q 'readonly=true' || die "preview API rootfs not readonly"
printf '%s' "$API_SEC" | grep -q 'capdrop=\["ALL"\]' || die "preview API capdrop missing"
printf '%s' "$API_SEC" | grep -q 'ports={}' || die "preview API unexpectedly exposed"

printf '%s' "$GUI_SEC" | grep -q 'network=host' || die "preview GUI not on host network"
printf '%s' "$GUI_SEC" | grep -q 'readonly=true' || die "preview GUI rootfs not readonly"
printf '%s' "$GUI_SEC" | grep -q 'capdrop=\["ALL"\]' || die "preview GUI capdrop missing"

printf '%s\n' "preview_hardening=PASS"

printf '\n=== 13. PRODUCTION FINAL SAFETY ===\n'

FINAL_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_LICS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_INST=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'image=%s running=%s migrations=%s licenses=%s installations=%s\n' \
  "$FINAL_IMAGE" "$FINAL_RUNNING" "$FINAL_MIG" "$FINAL_LICS" "$FINAL_INST"

[ "$FINAL_IMAGE" = "$PROD_IMAGE" ] || die "production image changed"
[ "$FINAL_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$PROD_MIG" ] || die "production migrations changed"
[ "$FINAL_LICS" = "$PROD_LICS" ] || die "production licenses changed"
[ "$FINAL_INST" = "$PROD_INST" ] || die "production installations changed"

printf '%s\n' "production_unchanged=PASS"

COMPLETED=1

printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7E4 V3 LOCAL PREVIEW PASSED"
printf '%s\n' "======================================================"
printf '%s\n' "PREVIEW DATABASE:                   REFRESHED ISOLATED CLONE"
printf '%s\n' "PREVIEW API IMAGE:                  qflm-api:recovery7e2-candidate"
printf '%s\n' "PREVIEW GUI IMAGE:                  qflm-admin-web:recovery7e4-preview"
printf '%s\n' "INSTALLATIONS GUI:                  LIVE LOCALLY"
printf '%s\n' "INSTALLATION API:                   LIVE LOCALLY"
printf '%s\n' "PREVIEW API HOST PORTS:             NONE"
printf 'LOCAL GUI URL:                      http://%s:%s\n' "$ORIGIN_IP" "$ORIGIN_PORT"
printf 'LOCAL INSTALLATIONS URL:            http://%s:%s/installations\n' "$ORIGIN_IP" "$ORIGIN_PORT"
printf '%s\n' "CLOUDFLARE:                         NOT MODIFIED"
printf '%s\n' "PRODUCTION API/DB:                  UNCHANGED"
printf 'REPORT:                             %s\n' "$REPORT"
printf '%s\n' "NEXT: RECOVERY 7E5 - RECONNECT lc.quikefix.info AFTER LOCAL PREVIEW VALIDATION"
printf '%s\n' "======================================================"
