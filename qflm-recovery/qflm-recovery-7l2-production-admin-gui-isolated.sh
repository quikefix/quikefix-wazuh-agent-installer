#!/usr/bin/env bash
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

PROD_GUI="qflm-admin-web-production-isolated"
PROD_GUI_IMAGE="qflm-admin-web:recovery7l2-production-candidate"

ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"

ORIGIN_IFACE="ens18"
ISOLATED_PORT="8090"
PUBLIC_PREVIEW_URL="https://lc.quikefix.info"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7l2-production-gui-isolated-$STAMP"
REPORT="$BACKUP/recovery7l2-production-gui-isolated-report.txt"
NGINX_CONF="$BACKUP/nginx-recovery7l2.conf"
DOCKERFILE="$BACKUP/Dockerfile.recovery7l2"

KEEP_ISOLATED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

cleanup(){
    if [ "$KEEP_ISOLATED" != 1 ]; then
        docker rm -f "$PROD_GUI" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7L2"
echo " PRODUCTION ADMIN GUI - ISOLATED DEPLOYMENT"
echo "======================================================"

echo
echo "=== 1. PRODUCTION / PREVIEW SAFETY BASELINE ==="

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PROD_RESTARTS=$(docker inspect "$PROD_API" --format='{{.RestartCount}}')

[ "$PROD_IMAGE" = "$EXPECTED_PROD_IMAGE" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$PROD_RESTARTS" = 0 ] || die "production API restart count unexpected"

PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)

[ "$PREVIEW_API_IMAGE" = "$EXPECTED_PREVIEW_API_IMAGE" ] || die "preview API image changed"
[ "$PREVIEW_GUI_IMAGE" = "$EXPECTED_PREVIEW_GUI_IMAGE" ] || die "preview GUI image changed"
[ "$PREVIEW_API_RUNNING" = true ] || die "preview API not running"
[ "$PREVIEW_GUI_RUNNING" = true ] || die "preview GUI not running"

MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
LICENSES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
ISSUANCES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
AUDIT=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

echo "safety_baseline=PASS"

echo
echo "=== 2. DETECT HOST + PRODUCTION API IP ==="

HOST_IP=$(ip -4 -o addr show dev "$ORIGIN_IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
[ -n "$HOST_IP" ] || die "no IPv4 address on $ORIGIN_IFACE"

PROD_API_IP=$(docker inspect "$PROD_API" --format="{{with index .NetworkSettings.Networks \"$NET\"}}{{.IPAddress}}{{end}}")
[ -n "$PROD_API_IP" ] || die "production API bridge IP missing"

printf 'host_ip=%s isolated_port=%s production_api_ip=%s\n' "$HOST_IP" "$ISOLATED_PORT" "$PROD_API_IP"

if ss -ltn | awk '{print $4}' | grep -Eq "(:|])$ISOLATED_PORT$"; then
    die "isolated port $ISOLATED_PORT already in use"
fi

echo "network_preflight=PASS"

echo
echo "=== 3. BUILD PRODUCTION GUI CANDIDATE ==="

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
        listen ${HOST_IP}:${ISOLATED_PORT};
        root /usr/share/nginx/html;
        index index.html;

        location /api/ {
            proxy_pass http://${PROD_API_IP}:8080/api/;
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

cat > "$DOCKERFILE" <<'DOCKER'
FROM node:24-bookworm-slim AS build
WORKDIR /src
COPY src/QFLM.AdminWeb/package*.json ./
RUN npm install --no-audit --no-fund
COPY src/QFLM.AdminWeb/ ./
RUN npm run build

FROM nginx:1.29-alpine
USER root
COPY --from=build /src/dist /usr/share/nginx/html
COPY nginx-recovery7l2.conf /etc/nginx/nginx-qflm.conf
RUN chmod -R a=rX /usr/share/nginx/html \
 && chmod 444 /etc/nginx/nginx-qflm.conf \
 && mkdir -p /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp \
 && chown -R nginx:nginx /tmp
USER nginx
ENTRYPOINT ["nginx","-c","/etc/nginx/nginx-qflm.conf","-g","daemon off;"]
DOCKER

cd "$ROOT" || die "project root missing"
docker build -f "$DOCKERFILE" -t "$PROD_GUI_IMAGE" "$ROOT" || die "production GUI candidate build failed"

echo "production_gui_candidate_build=PASS"

echo
echo "=== 4. START ISOLATED PRODUCTION GUI ==="

docker rm -f "$PROD_GUI" >/dev/null 2>&1 || true

docker run -d  --name "$PROD_GUI"  --network host  --read-only  --cap-drop ALL  --security-opt no-new-privileges:true  --tmpfs /tmp:rw,noexec,nosuid,size=24m,uid=101,gid=101  "$PROD_GUI_IMAGE" >/dev/null  || die "isolated production GUI start failed"

sleep 4

[ "$(docker inspect "$PROD_GUI" --format='{{.State.Running}}')" = true ] || {
    docker logs --tail 200 "$PROD_GUI" || true
    die "isolated production GUI not running"
}

ss -ltnp | grep -F "$HOST_IP:$ISOLATED_PORT" || die "isolated GUI listener missing"
echo "isolated_gui_listener=PASS"

echo
echo "=== 5. ISOLATED GUI ROUTE VALIDATION ==="

for route in / /health /login /customers /products /licenses /installations /offline /security /audit /system; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST_IP:$ISOLATED_PORT$route" || true)
    [ "$CODE" = 200 ] || die "isolated GUI route failed: $route -> $CODE"
done

echo "isolated_gui_routes=PASS"

echo
echo "=== 6. PRODUCTION ADMIN API VALIDATION THROUGH GUI ==="

[ -s "$ADMIN_USER_FILE" ] || die "admin username missing"
[ -s "$ADMIN_PASS_FILE" ] || die "admin password missing"

ADMIN_USER="$(cat "$ADMIN_USER_FILE")"
ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"

LOGIN_JSON=$(python3 - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)

LOGIN_RESPONSE=$(curl -fsS  -H 'Content-Type: application/json'  -X POST "http://$HOST_IP:$ISOLATED_PORT/api/v1/auth/login"  --data-binary "$LOGIN_JSON") || die "production GUI admin login failed"

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

for url in "${URLS[@]}"; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}'       -H "Authorization: Bearer $TOKEN"       "http://$HOST_IP:$ISOLATED_PORT$url")
    [ "$CODE" = 200 ] || die "production GUI API validation failed: $url -> $CODE"
done

echo "production_gui_api_validation=PASS"

echo
echo "=== 7. ISOLATED GUI HARDENING ==="

GUI_HARDEN=$(docker inspect "$PROD_GUI"  --format='network={{.HostConfig.NetworkMode}} user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}}')

echo "$GUI_HARDEN"

echo "$GUI_HARDEN" | grep -Fq 'network=host' || die "GUI host network missing"
echo "$GUI_HARDEN" | grep -Fq 'user=nginx' || die "GUI nonroot user missing"
echo "$GUI_HARDEN" | grep -Fq 'readonly=true' || die "GUI readonly rootfs missing"
echo "$GUI_HARDEN" | grep -Fq '"ALL"' || die "GUI capdrop missing"
echo "$GUI_HARDEN" | grep -Fq 'no-new-privileges:true' || die "GUI no-new-privileges missing"

echo "isolated_gui_hardening=PASS"

echo
echo "=== 8. REVOKE TEST SESSION ==="

REVOKE_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)

REVOKE_HTTP=$(curl -s -o /dev/null -w '%{http_code}'  -H 'Content-Type: application/json'  -H "Authorization: Bearer $TOKEN"  -X POST "http://$HOST_IP:$ISOLATED_PORT/api/v1/auth/revoke"  --data-binary "$REVOKE_JSON")

[ "$REVOKE_HTTP" = 204 ] || die "production GUI test session revoke failed"

unset TOKEN REFRESH ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE REVOKE_JSON
echo "test_session_revoke=PASS"

echo
echo "=== 9. PREVIEW REGRESSION CHECK ==="

for route in / /login /offline /security /audit /system; do
    CODE=$(curl -L -s -o /dev/null -w '%{http_code}' "$PUBLIC_PREVIEW_URL$route" || true)
    [ "$CODE" = 200 ] || die "preview regression: $route -> $CODE"
done

echo "preview_regression=PASS"

echo
echo "=== 10. PRODUCTION DATABASE NO-MUTATION CHECK ==="

FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
FINAL_LICENSES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
FINAL_ISSUANCES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
FINAL_AUDIT=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

[ "$FINAL_MIG" = "$MIG" ] || die "migrations changed"
[ "$FINAL_USERS" = "$USERS" ] || die "users changed"
[ "$FINAL_ROLES" = "$ROLES" ] || die "roles changed"
[ "$FINAL_PERMS" = "$PERMS" ] || die "permissions changed"
[ "$FINAL_LICENSES" = "$LICENSES" ] || die "licenses changed"
[ "$FINAL_INSTALLATIONS" = "$INSTALLATIONS" ] || die "installations changed"
[ "$FINAL_ISSUANCES" = "$ISSUANCES" ] || die "offline issuances changed"
[ "$FINAL_AUDIT" = "$AUDIT" ] || die "offline audit changed"

echo "production_database_unchanged=PASS"

KEEP_ISOLATED=1

echo
echo "======================================================"
echo " QFLM RECOVERY 7L2 PASSED"
echo "======================================================"
echo "PRODUCTION GUI IMAGE:               $PROD_GUI_IMAGE"
echo "PRODUCTION GUI CONTAINER:           $PROD_GUI"
echo "ISOLATED GUI URL:                   http://$HOST_IP:$ISOLATED_PORT"
echo "PRODUCTION API:                     UNCHANGED / HEALTHY"
echo "PRODUCTION DATABASE:                UNCHANGED"
echo "CLOUDFLARE PREVIEW:                 UNCHANGED"
echo "GUI HARDENING:                      PASS"
echo "ADMIN API THROUGH GUI:              PASS"
echo "REPORT:                             $REPORT"
echo "NEXT: RECOVERY 7L3 - PERMANENT CLOUDFLARE PRODUCTION GUI ROUTING"
echo "======================================================"
