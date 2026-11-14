#!/usr/bin/env bash
# QFLM RECOVERY 7L4
# Production GUI final freeze.
# Verifies live Cloudflare GUI, production API/DB invariants, hardening,
# rollback preservation, and writes final GUI freeze manifest.

set -u
set -o pipefail
umask 077

PG="qflm-postgres"
PROD_DB="qflm"
PROD_API="qflm-api"
PROD_GUI="qflm-admin-web-production"
ROLLBACK_GUI="qflm-admin-web-recovery7l3-preview-rollback"

EXPECTED_PROD_API_IMAGE="qflm-api:recovery7k2-production"
EXPECTED_PROD_GUI_IMAGE="qflm-admin-web:recovery7l3-production"
EXPECTED_ROLLBACK_GUI_IMAGE="qflm-admin-web:recovery7j3-preview"

PUBLIC_URL="https://lc.quikefix.info"
ORIGIN_IFACE="ens18"
ORIGIN_PORT="8088"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7l4-production-gui-final-freeze-$STAMP"
REPORT="$BACKUP/recovery7l4-production-gui-final-freeze-report.txt"
MANIFEST="$BACKUP/recovery7l4-production-gui-final-freeze.manifest"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7L4"
echo " PRODUCTION GUI FINAL FREEZE"
echo "======================================================"

echo
echo "=== 1. PRODUCTION API / GUI BASELINE ==="

PROD_API_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_API_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PROD_GUI_IMAGE=$(docker inspect "$PROD_GUI" --format='{{.Config.Image}}') || die "production GUI missing"
PROD_GUI_RUNNING=$(docker inspect "$PROD_GUI" --format='{{.State.Running}}')
PROD_GUI_RESTARTS=$(docker inspect "$PROD_GUI" --format='{{.RestartCount}}')

[ "$PROD_API_IMAGE" = "$EXPECTED_PROD_API_IMAGE" ] || die "unexpected production API image"
[ "$PROD_API_RUNNING" = true ] || die "production API not running"
[ "$PROD_GUI_IMAGE" = "$EXPECTED_PROD_GUI_IMAGE" ] || die "unexpected production GUI image"
[ "$PROD_GUI_RUNNING" = true ] || die "production GUI not running"
[ "$PROD_GUI_RESTARTS" = 0 ] || die "production GUI restart count unexpected"

echo "production_api_gui_baseline=PASS"

echo
echo "=== 2. ROLLBACK GUI PRESERVED ==="

ROLLBACK_GUI_IMAGE=$(docker inspect "$ROLLBACK_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
ROLLBACK_GUI_RUNNING=$(docker inspect "$ROLLBACK_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)

[ "$ROLLBACK_GUI_IMAGE" = "$EXPECTED_ROLLBACK_GUI_IMAGE" ] || die "rollback GUI image/container missing"
[ "$ROLLBACK_GUI_RUNNING" = false ] || die "rollback GUI should remain stopped"

echo "rollback_gui_preserved=PASS"

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

echo "database_invariants=PASS"

echo
echo "=== 4. ORIGIN + CLOUDFLARE ROUTE SOAK ==="

HOST_IP=$(ip -4 -o addr show dev "$ORIGIN_IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
[ -n "$HOST_IP" ] || die "no IPv4 address on $ORIGIN_IFACE"

for pass in 1 2 3; do
  for route in / /login /customers /products /licenses /installations /offline /security /audit /system; do
    ORIGIN_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST_IP:$ORIGIN_PORT$route" || true)
    PUBLIC_CODE=$(curl -L -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL$route" || true)

    [ "$ORIGIN_CODE" = 200 ] || die "origin route failed: pass=$pass route=$route http=$ORIGIN_CODE"
    [ "$PUBLIC_CODE" = 200 ] || die "public route failed: pass=$pass route=$route http=$PUBLIC_CODE"
  done
  sleep 2
done

echo "origin_cloudflare_route_soak=PASS"

echo
echo "=== 5. PRODUCTION GUI HARDENING ==="

GUI_HARDEN=$(docker inspect "$PROD_GUI"  --format='network={{.HostConfig.NetworkMode}} user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}}')

echo "$GUI_HARDEN"

echo "$GUI_HARDEN" | grep -Fq 'network=host' || die "GUI host network missing"
echo "$GUI_HARDEN" | grep -Fq 'user=nginx' || die "GUI nonroot user missing"
echo "$GUI_HARDEN" | grep -Fq 'readonly=true' || die "GUI readonly rootfs missing"
echo "$GUI_HARDEN" | grep -Fq '"ALL"' || die "GUI capdrop missing"
echo "$GUI_HARDEN" | grep -Fq 'no-new-privileges:true' || die "GUI no-new-privileges missing"

echo "production_gui_hardening=PASS"

echo
echo "=== 6. PRODUCTION API HEALTH ==="

docker run --rm --network qflm_backend curlimages/curl:8.16.0  -fsS "http://$PROD_API:8080/health/live" >/dev/null  || die "production API live health failed"

docker run --rm --network qflm_backend curlimages/curl:8.16.0  -fsS "http://$PROD_API:8080/health/ready" >/dev/null  || die "production API ready health failed"

echo "production_api_health=PASS"

echo
echo "=== 7. FINAL NO-MUTATION CHECK ==="

FINAL_PROD_API_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_PROD_GUI_IMAGE=$(docker inspect "$PROD_GUI" --format='{{.Config.Image}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
FINAL_LICENSES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
FINAL_ISSUANCES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
FINAL_AUDIT=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

[ "$FINAL_PROD_API_IMAGE" = "$PROD_API_IMAGE" ] || die "production API image changed"
[ "$FINAL_PROD_GUI_IMAGE" = "$PROD_GUI_IMAGE" ] || die "production GUI image changed"
[ "$FINAL_MIG" = "$MIG" ] || die "migrations changed"
[ "$FINAL_USERS" = "$USERS" ] || die "users changed"
[ "$FINAL_ROLES" = "$ROLES" ] || die "roles changed"
[ "$FINAL_PERMS" = "$PERMS" ] || die "permissions changed"
[ "$FINAL_LICENSES" = "$LICENSES" ] || die "licenses changed"
[ "$FINAL_INSTALLATIONS" = "$INSTALLATIONS" ] || die "installations changed"
[ "$FINAL_ISSUANCES" = "$ISSUANCES" ] || die "issuances changed"
[ "$FINAL_AUDIT" = "$AUDIT" ] || die "audit changed"

echo "no_mutation=PASS"

echo
echo "=== 8. WRITE FINAL GUI FREEZE MANIFEST ==="

PROD_API_ID=$(docker inspect "$PROD_API" --format='{{.Id}}')
PROD_GUI_ID=$(docker inspect "$PROD_GUI" --format='{{.Id}}')
PROD_GUI_IMAGE_ID=$(docker image inspect "$PROD_GUI_IMAGE" --format='{{.Id}}')
ROLLBACK_GUI_ID=$(docker inspect "$ROLLBACK_GUI" --format='{{.Id}}')

cat > "$MANIFEST" <<EOF
QFLM_FINAL_GUI_FREEZE=RECOVERY_7L4
UTC=$STAMP
PUBLIC_URL=$PUBLIC_URL
ORIGIN=http://$HOST_IP:$ORIGIN_PORT
PRODUCTION_API_IMAGE=$PROD_API_IMAGE
PRODUCTION_API_CONTAINER_ID=$PROD_API_ID
PRODUCTION_GUI_IMAGE=$PROD_GUI_IMAGE
PRODUCTION_GUI_IMAGE_ID=$PROD_GUI_IMAGE_ID
PRODUCTION_GUI_CONTAINER_ID=$PROD_GUI_ID
ROLLBACK_GUI_CONTAINER=$ROLLBACK_GUI
ROLLBACK_GUI_CONTAINER_ID=$ROLLBACK_GUI_ID
ROLLBACK_GUI_IMAGE=$ROLLBACK_GUI_IMAGE
MIGRATIONS=$MIG
USERS=$USERS
ROLES=$ROLES
PERMISSIONS=$PERMS
LICENSES=$LICENSES
INSTALLATIONS=$INSTALLATIONS
OFFLINE_ISSUANCES=$ISSUANCES
OFFLINE_AUDIT=$AUDIT
EOF

chmod 400 "$MANIFEST"

echo "final_gui_freeze_manifest=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7L4 FINAL FREEZE PASSED"
echo "======================================================"
echo "PRODUCTION GUI:                     FINAL FROZEN"
echo "PUBLIC URL:                         $PUBLIC_URL"
echo "PRODUCTION API:                     HEALTHY"
echo "PRODUCTION DATABASE:                VERIFIED"
echo "GUI HARDENING:                      PASS"
echo "ROLLBACK GUI:                       PRESERVED"
echo "FREEZE MANIFEST:                    $MANIFEST"
echo "REPORT:                             $REPORT"
echo "STATUS:                             RECOVERY_7L4_GUI_FINAL_FROZEN"
echo "NEXT: RECOVERY 7M - CLIENT LICENSING SDK / INTEGRATION"
echo "======================================================"
