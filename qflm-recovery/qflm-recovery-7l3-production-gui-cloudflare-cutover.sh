#!/usr/bin/env bash
# QFLM RECOVERY 7L3
# Promote validated production Admin GUI to existing Cloudflare origin.
# Keeps old preview GUI container preserved for rollback.
# Production API/DB remain unchanged.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
PG="qflm-postgres"
PROD_DB="qflm"
PROD_API="qflm-api"

PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"
PROD_GUI_ISOLATED="qflm-admin-web-production-isolated"
PROD_GUI_LIVE="qflm-admin-web-production"
ROLLBACK_GUI="qflm-admin-web-recovery7l3-preview-rollback"

EXPECTED_PROD_API_IMAGE="qflm-api:recovery7k2-production"
EXPECTED_PREVIEW_API_IMAGE="qflm-api:recovery7i2-candidate"
EXPECTED_PREVIEW_GUI_IMAGE="qflm-admin-web:recovery7j3-preview"
EXPECTED_PROD_GUI_IMAGE="qflm-admin-web:recovery7l2-production-candidate"

ORIGIN_IFACE="ens18"
PREVIEW_PORT="8088"
ISOLATED_PORT="8090"
PUBLIC_URL="https://lc.quikefix.info"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7l3-production-gui-cutover-$STAMP"
REPORT="$BACKUP/recovery7l3-production-gui-cutover-report.txt"
NGINX_CONF="$BACKUP/nginx-recovery7l3.conf"
DOCKERFILE="$BACKUP/Dockerfile.recovery7l3"

CUTOVER_STARTED=0
PROMOTED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

rollback(){
    if [ "$PROMOTED" -eq 1 ]; then
        return
    fi
    if [ "$CUTOVER_STARTED" -eq 1 ]; then
        printf '\n=== AUTOMATIC GUI ROLLBACK ===\n'
        docker rm -f "$PROD_GUI_LIVE" >/dev/null 2>&1 || true
        if docker inspect "$ROLLBACK_GUI" >/dev/null 2>&1; then
            docker rename "$ROLLBACK_GUI" "$PREVIEW_GUI" >/dev/null 2>&1 || true
            docker start "$PREVIEW_GUI" >/dev/null 2>&1 || true
            sleep 3
        fi
        printf '%s\n' "gui_rollback_attempted=YES"
    fi
}
trap rollback EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7L3"
echo " PERMANENT CLOUDFLARE PRODUCTION GUI ROUTING"
echo "======================================================"

echo
echo "=== 1. SAFETY BASELINE ==="

PROD_API_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_API_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PROD_GUI_IMAGE=$(docker inspect "$PROD_GUI_ISOLATED" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PROD_GUI_RUNNING=$(docker inspect "$PROD_GUI_ISOLATED" --format='{{.State.Running}}' 2>/dev/null || echo missing)

[ "$PROD_API_IMAGE" = "$EXPECTED_PROD_API_IMAGE" ] || die "unexpected production API image"
[ "$PROD_API_RUNNING" = true ] || die "production API not running"
[ "$PREVIEW_API_IMAGE" = "$EXPECTED_PREVIEW_API_IMAGE" ] || die "unexpected preview API image"
[ "$PREVIEW_GUI_IMAGE" = "$EXPECTED_PREVIEW_GUI_IMAGE" ] || die "unexpected preview GUI image"
[ "$PROD_GUI_IMAGE" = "$EXPECTED_PROD_GUI_IMAGE" ] || die "unexpected isolated production GUI image"
[ "$PROD_GUI_RUNNING" = true ] || die "isolated production GUI not running"

MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

echo "safety_baseline=PASS"

echo
echo "=== 2. DETECT ORIGIN + API IP ==="

HOST_IP=$(ip -4 -o addr show dev "$ORIGIN_IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
[ -n "$HOST_IP" ] || die "no IPv4 address on $ORIGIN_IFACE"

PROD_API_IP=$(docker inspect "$PROD_API" --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
[ -n "$PROD_API_IP" ] || die "production API IP missing"

printf 'host_ip=%s cloudflare_origin_port=%s production_api_ip=%s\n'  "$HOST_IP" "$PREVIEW_PORT" "$PROD_API_IP"

echo "origin_detection=PASS"

echo
echo "=== 3. VERIFY CURRENT CLOUDFLARE PREVIEW ==="

for route in / /login /offline /security /audit /system; do
    CODE=$(curl -L -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL$route" || true)
    [ "$CODE" = 200 ] || die "current Cloudflare route failed: $route -> $CODE"
done

echo "cloudflare_before=PASS"

echo
echo "=== 4. BUILD LIVE PRODUCTION GUI IMAGE ==="

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
        listen ${HOST_IP}:${PREVIEW_PORT};
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

cp "$NGINX_CONF" "$ROOT/nginx-recovery7l3.conf"

cat > "$DOCKERFILE" <<'DOCKER'
FROM qflm-admin-web:recovery7l2-production-candidate
USER root
COPY nginx-recovery7l3.conf /etc/nginx/nginx-qflm.conf
RUN chmod 444 /etc/nginx/nginx-qflm.conf
USER nginx
ENTRYPOINT ["nginx","-c","/etc/nginx/nginx-qflm.conf","-g","daemon off;"]
DOCKER

cd "$ROOT" || die "project root missing"
docker build -f "$DOCKERFILE" -t qflm-admin-web:recovery7l3-production "$ROOT"  || die "live production GUI image build failed"

rm -f "$ROOT/nginx-recovery7l3.conf"

echo "live_gui_image_build=PASS"

echo
echo "=== 5. CONTROLLED GUI CUTOVER ==="

CUTOVER_STARTED=1

docker rm -f "$ROLLBACK_GUI" >/dev/null 2>&1 || true
docker stop "$PREVIEW_GUI" >/dev/null || die "failed to stop preview GUI"
docker rename "$PREVIEW_GUI" "$ROLLBACK_GUI" || die "failed to preserve preview GUI rollback"

docker rm -f "$PROD_GUI_LIVE" >/dev/null 2>&1 || true

docker run -d  --name "$PROD_GUI_LIVE"  --network host  --read-only  --cap-drop ALL  --security-opt no-new-privileges:true  --tmpfs /tmp:rw,noexec,nosuid,size=24m,uid=101,gid=101  qflm-admin-web:recovery7l3-production >/dev/null  || die "live production GUI start failed"

sleep 4

[ "$(docker inspect "$PROD_GUI_LIVE" --format='{{.State.Running}}')" = true ] || {
    docker logs --tail 200 "$PROD_GUI_LIVE" || true
    die "live production GUI not running"
}

ss -ltnp | grep -F "$HOST_IP:$PREVIEW_PORT" || die "production GUI origin listener missing"

echo "gui_cutover_listener=PASS"

echo
echo "=== 6. ORIGIN ROUTE VALIDATION ==="

for route in / /health /login /customers /products /licenses /installations /offline /security /audit /system; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST_IP:$PREVIEW_PORT$route" || true)
    [ "$CODE" = 200 ] || die "origin route failed: $route -> $CODE"
done

echo "origin_routes=PASS"

echo
echo "=== 7. CLOUDFLARE PUBLIC VALIDATION ==="

for route in / /login /customers /products /licenses /installations /offline /security /audit /system; do
    CODE=$(curl -L -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL$route" || true)
    [ "$CODE" = 200 ] || die "Cloudflare route failed: $route -> $CODE"
done

echo "cloudflare_public_routes=PASS"

echo
echo "=== 8. HARDENING ==="

GUI_HARDEN=$(docker inspect "$PROD_GUI_LIVE"  --format='network={{.HostConfig.NetworkMode}} user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}}')

echo "$GUI_HARDEN"

echo "$GUI_HARDEN" | grep -Fq 'network=host' || die "host network missing"
echo "$GUI_HARDEN" | grep -Fq 'user=nginx' || die "nonroot user missing"
echo "$GUI_HARDEN" | grep -Fq 'readonly=true' || die "readonly rootfs missing"
echo "$GUI_HARDEN" | grep -Fq '"ALL"' || die "capdrop missing"
echo "$GUI_HARDEN" | grep -Fq 'no-new-privileges:true' || die "no-new-privileges missing"

echo "production_gui_hardening=PASS"

echo
echo "=== 9. DATABASE / API NO-MUTATION CHECK ==="

FINAL_PROD_API_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_PROD_API_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

[ "$FINAL_PROD_API_IMAGE" = "$PROD_API_IMAGE" ] || die "production API image changed"
[ "$FINAL_PROD_API_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "migration count changed"
[ "$FINAL_USERS" = "$USERS" ] || die "user count changed"
[ "$FINAL_ROLES" = "$ROLES" ] || die "role count changed"
[ "$FINAL_PERMS" = "$PERMS" ] || die "permission count changed"

echo "production_api_database_unchanged=PASS"

PROMOTED=1

echo
echo "======================================================"
echo " QFLM RECOVERY 7L3 PASSED"
echo "======================================================"
echo "PRODUCTION GUI:                     LIVE"
echo "PRODUCTION GUI IMAGE:               qflm-admin-web:recovery7l3-production"
echo "PUBLIC URL:                         $PUBLIC_URL"
echo "CLOUDFLARE ORIGIN:                  http://$HOST_IP:$PREVIEW_PORT"
echo "PRODUCTION API:                     HEALTHY / UNCHANGED"
echo "PRODUCTION DATABASE:                UNCHANGED"
echo "PREVIEW GUI ROLLBACK:               $ROLLBACK_GUI"
echo "ISOLATED VALIDATION GUI:            $PROD_GUI_ISOLATED"
echo "REPORT:                             $REPORT"
echo "NEXT: RECOVERY 7L4 - PRODUCTION GUI FINAL FREEZE"
echo "======================================================"
