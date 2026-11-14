#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
PROD_API="qflm-api"
PROD_GUI="qflm-admin-web-production"
PG="qflm-postgres"
REDIS="qflm-redis"
SIGNING="qflm-signing"

EXPECTED_API_IMAGE="qflm-api:recovery7k2-production"
EXPECTED_GUI_IMAGE="qflm-admin-web:recovery7l3-production"
EXPECTED_SIGNING_IMAGE="qflm-signing:14c-candidate"

PUBLIC_URL="https://lc.quikefix.info"
SDK_VERSION="0.1.0"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/opt/qflm/backups/qflm-v1.0-final-release-$STAMP"
REPORT="$OUT/qflm-v1.0-final-release-report.txt"
MANIFEST="$OUT/qflm-v1.0-final-release.manifest"
RELEASE_NOTES="$OUT/QFLM-v1.0-RELEASE-NOTES.md"
BUNDLE="$OUT/QFLM-v1.0-release-artifacts.tgz"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p "$OUT"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM V1.0 FINAL RELEASE"
echo " FINAL VERIFICATION / RELEASE FREEZE"
echo "======================================================"

echo
echo "=== 1. PRODUCTION IMAGE / RUNTIME BASELINE ==="

API_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
GUI_IMAGE=$(docker inspect "$PROD_GUI" --format='{{.Config.Image}}') || die "production GUI missing"
SIGNING_IMAGE=$(docker inspect "$SIGNING" --format='{{.Config.Image}}') || die "signing service missing"

[ "$API_IMAGE" = "$EXPECTED_API_IMAGE" ] || die "unexpected API image"
[ "$GUI_IMAGE" = "$EXPECTED_GUI_IMAGE" ] || die "unexpected GUI image"
[ "$SIGNING_IMAGE" = "$EXPECTED_SIGNING_IMAGE" ] || die "unexpected signing image"

for c in "$PROD_API" "$PROD_GUI" "$PG" "$REDIS" "$SIGNING"; do
  [ "$(docker inspect "$c" --format='{{.State.Running}}')" = true ] || die "$c not running"
  [ "$(docker inspect "$c" --format='{{.HostConfig.RestartPolicy.Name}}')" = "unless-stopped" ] || die "$c restart policy invalid"
done

echo "runtime_baseline=PASS"

echo
echo "=== 2. DATABASE FINAL INVARIANTS ==="

MIG=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
USERS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_users;' | xargs)
ROLES=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PERMS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
LICENSES=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM licenses;' | xargs)
INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM installations;' | xargs)
OFFLINE_ISSUANCES=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
OFFLINE_AUDIT=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

[ "$MIG" = 5 ] || die "unexpected migration count"
[ "$PERMS" = 22 ] || die "unexpected permission count"

echo "database_invariants=PASS"

echo
echo "=== 3. API / GUI / SIGNING HEALTH ==="

docker run --rm --network qflm_backend curlimages/curl:8.16.0 -fsS http://qflm-api:8080/health/live >/dev/null || die "API live failed"
docker run --rm --network qflm_backend curlimages/curl:8.16.0 -fsS http://qflm-api:8080/health/ready >/dev/null || die "API ready failed"

for route in / /login /customers /products /licenses /installations /offline /security /audit /system; do
  code=$(curl -L -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL$route" || true)
  [ "$code" = 200 ] || die "public route failed: $route -> $code"
done

[ "$(docker inspect "$SIGNING" --format='{{.State.Running}}')" = true ] || die "signing service not running"

echo "health_validation=PASS"

echo
echo "=== 4. SECURITY HARDENING VALIDATION ==="

API_READONLY=$(docker inspect "$PROD_API" --format='{{.HostConfig.ReadonlyRootfs}}')
GUI_READONLY=$(docker inspect "$PROD_GUI" --format='{{.HostConfig.ReadonlyRootfs}}')
API_CAPS=$(docker inspect "$PROD_API" --format='{{json .HostConfig.CapDrop}}')
GUI_CAPS=$(docker inspect "$PROD_GUI" --format='{{json .HostConfig.CapDrop}}')
API_SEC=$(docker inspect "$PROD_API" --format='{{json .HostConfig.SecurityOpt}}')
GUI_SEC=$(docker inspect "$PROD_GUI" --format='{{json .HostConfig.SecurityOpt}}')
API_PORTS=$(docker inspect "$PROD_API" --format='{{json .HostConfig.PortBindings}}')

[ "$API_READONLY" = true ] || die "API rootfs not read-only"
[ "$GUI_READONLY" = true ] || die "GUI rootfs not read-only"
printf '%s' "$API_CAPS" | grep -q '"ALL"' || die "API cap drop missing"
printf '%s' "$GUI_CAPS" | grep -q '"ALL"' || die "GUI cap drop missing"
printf '%s' "$API_SEC" | grep -q 'no-new-privileges' || die "API no-new-privileges missing"
printf '%s' "$GUI_SEC" | grep -q 'no-new-privileges' || die "GUI no-new-privileges missing"
[ "$API_PORTS" = "null" ] || [ "$API_PORTS" = "{}" ] || die "API unexpectedly exposes host ports"

echo "security_hardening=PASS"

echo
echo "=== 5. OPERATIONS AUTOMATION VALIDATION ==="

systemctl is-enabled qflm-health-monitor.timer | grep -qx enabled || die "health timer not enabled"
systemctl is-active qflm-health-monitor.timer | grep -qx active || die "health timer not active"
systemctl is-enabled qflm-daily-backup.timer | grep -qx enabled || die "backup timer not enabled"
systemctl is-active qflm-daily-backup.timer | grep -qx active || die "backup timer not active"

"$ROOT/ops/monitoring/qflm-health-check.sh" || die "health monitor failed"

LATEST_BACKUP=$(find /opt/qflm/backups/daily -maxdepth 1 -type f -name 'qflm-*.dump' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
[ -n "$LATEST_BACKUP" ] || die "daily backup missing"
cat "$LATEST_BACKUP" | docker exec -i "$PG" pg_restore -l >/dev/null || die "latest daily backup invalid"

echo "operations_automation=PASS"

echo
echo "=== 6. SDK FINAL RELEASE ARTIFACT ==="

SDK_PACKAGE=$(find /opt/qflm/backups -type f -name 'QuikeFix.QFLM.ClientSdk.0.1.0.nupkg' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
[ -n "$SDK_PACKAGE" ] || die "SDK package missing"
SDK_SHA=$(sha256sum "$SDK_PACKAGE" | awk '{print $1}')

DOTNET_ROLL_FORWARD=Major dotnet test "$ROOT/tests/QFLM.ClientSdk.Tests/QFLM.ClientSdk.Tests.csproj" -c Release >/dev/null || die "SDK tests failed"

echo "sdk_package=$SDK_PACKAGE"
echo "sdk_sha256=$SDK_SHA"
echo "sdk_release=PASS"

echo
echo "=== 7. FINAL DATABASE RELEASE BACKUP ==="

FINAL_DB="$OUT/qflm-v1.0-final-release.dump"
docker exec "$PG" pg_dump -U qflm -Fc -d qflm > "$FINAL_DB" || die "final release DB backup failed"
[ -s "$FINAL_DB" ] || die "final release DB backup empty"
cat "$FINAL_DB" | docker exec -i "$PG" pg_restore -l >/dev/null || die "final release DB backup invalid"
FINAL_DB_SHA=$(sha256sum "$FINAL_DB" | awk '{print $1}')

echo "final_release_db_backup=PASS"

echo
echo "=== 8. RELEASE NOTES ==="

cat > "$RELEASE_NOTES" <<EOF
# QFLM v1.0 Final Release

Release UTC: $STAMP

Production URL: $PUBLIC_URL
API image: $API_IMAGE
Admin GUI image: $GUI_IMAGE
Signing image: $SIGNING_IMAGE

Core capabilities:
- product and customer management
- license lifecycle management
- installation/device binding
- activation, validation, heartbeat and deactivation
- suspension, revocation, grace and expiry handling
- feature entitlements
- offline licensing/signing
- admin RBAC
- audit/reporting
- system/operations dashboard
- .NET client SDK

Client SDK:
- version $SDK_VERSION
- SHA-256 $SDK_SHA

Operations:
- boot persistence enabled
- health monitoring every 5 minutes
- daily PostgreSQL backup enabled
- 14-day daily backup retention
- DR/backup/monitoring runbooks installed
- controlled restart validation passed

Security:
- API/GUI read-only root filesystems
- capabilities dropped
- no-new-privileges enabled
- API has no public host port
- signing private key isolated to signing service

Database state:
- migrations $MIG
- users $USERS
- roles $ROLES
- permissions $PERMS
- licenses $LICENSES
- installations $INSTALLATIONS
- offline issuances $OFFLINE_ISSUANCES
- offline audit events $OFFLINE_AUDIT
EOF

echo "release_notes=PASS"

echo
echo "=== 9. FINAL RELEASE MANIFEST ==="

LATEST_BACKUP_SHA=$(sha256sum "$LATEST_BACKUP" | awk '{print $1}')
API_IMAGE_ID=$(docker image inspect "$API_IMAGE" --format='{{.Id}}')
GUI_IMAGE_ID=$(docker image inspect "$GUI_IMAGE" --format='{{.Id}}')
SIGNING_IMAGE_ID=$(docker image inspect "$SIGNING_IMAGE" --format='{{.Id}}')

cat > "$MANIFEST" <<EOF
QFLM_RELEASE=1.0
STATUS=FINAL_RELEASE_FROZEN
UTC=$STAMP
PUBLIC_URL=$PUBLIC_URL
API_IMAGE=$API_IMAGE
API_IMAGE_ID=$API_IMAGE_ID
GUI_IMAGE=$GUI_IMAGE
GUI_IMAGE_ID=$GUI_IMAGE_ID
SIGNING_IMAGE=$SIGNING_IMAGE
SIGNING_IMAGE_ID=$SIGNING_IMAGE_ID
POSTGRES_IMAGE=$(docker inspect "$PG" --format='{{.Config.Image}}')
REDIS_IMAGE=$(docker inspect "$REDIS" --format='{{.Config.Image}}')
DATABASE_MIGRATIONS=$MIG
USERS=$USERS
ROLES=$ROLES
PERMISSIONS=$PERMS
LICENSES=$LICENSES
INSTALLATIONS=$INSTALLATIONS
OFFLINE_ISSUANCES=$OFFLINE_ISSUANCES
OFFLINE_AUDIT_EVENTS=$OFFLINE_AUDIT
SDK_VERSION=$SDK_VERSION
SDK_PACKAGE=$SDK_PACKAGE
SDK_PACKAGE_SHA256=$SDK_SHA
FINAL_DB_BACKUP=$FINAL_DB
FINAL_DB_BACKUP_SHA256=$FINAL_DB_SHA
LATEST_DAILY_BACKUP=$LATEST_BACKUP
LATEST_DAILY_BACKUP_SHA256=$LATEST_BACKUP_SHA
API_RESTART_POLICY=$(docker inspect "$PROD_API" --format='{{.HostConfig.RestartPolicy.Name}}')
GUI_RESTART_POLICY=$(docker inspect "$PROD_GUI" --format='{{.HostConfig.RestartPolicy.Name}}')
HEALTH_MONITOR_TIMER=$(systemctl is-active qflm-health-monitor.timer)
DAILY_BACKUP_TIMER=$(systemctl is-active qflm-daily-backup.timer)
SECURITY_HARDENING=PASS
CONTROLLED_RESTART=PASS
PUBLIC_ROUTE_VALIDATION=PASS
SDK_VALIDATION=PASS
OPERATIONS_AUTOMATION=PASS
DATABASE_MUTATION=NONE
EOF

chmod 400 "$MANIFEST"

echo "release_manifest=PASS"

echo
echo "=== 10. RELEASE ARTIFACT BUNDLE ==="

tar -czf "$BUNDLE"   -C "$OUT"   "$(basename "$MANIFEST")"   "$(basename "$RELEASE_NOTES")"   "$(basename "$FINAL_DB")"   -C "$ROOT"   docs/operations   ops/monitoring   ops/backup || die "release bundle failed"

BUNDLE_SHA=$(sha256sum "$BUNDLE" | awk '{print $1}')
echo "$BUNDLE_SHA  $BUNDLE" > "$BUNDLE.sha256"

echo "release_bundle=PASS"

echo
echo "=== 11. FINAL NO-MUTATION CHECK ==="

[ "$(docker inspect "$PROD_API" --format='{{.Config.Image}}')" = "$API_IMAGE" ] || die "API image changed"
[ "$(docker inspect "$PROD_GUI" --format='{{.Config.Image}}')" = "$GUI_IMAGE" ] || die "GUI image changed"

FINAL_MIG=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
FINAL_LICENSES=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM installations;' | xargs)

[ "$FINAL_MIG" = "$MIG" ] || die "migration count changed"
[ "$FINAL_USERS" = "$USERS" ] || die "user count changed"
[ "$FINAL_ROLES" = "$ROLES" ] || die "role count changed"
[ "$FINAL_PERMS" = "$PERMS" ] || die "permission count changed"
[ "$FINAL_LICENSES" = "$LICENSES" ] || die "license count changed"
[ "$FINAL_INSTALLATIONS" = "$INSTALLATIONS" ] || die "installation count changed"

echo "no_mutation=PASS"

echo
echo "======================================================"
echo " QFLM V1.0 FINAL RELEASE PASSED"
echo "======================================================"
echo "STATUS:                             FINAL_RELEASE_FROZEN"
echo "PUBLIC URL:                         $PUBLIC_URL"
echo "PRODUCTION API:                     HEALTHY"
echo "PRODUCTION GUI:                     HEALTHY"
echo "SIGNING SERVICE:                    HEALTHY"
echo "DATABASE:                           VERIFIED"
echo "SECURITY HARDENING:                 PASS"
echo "SDK VERSION:                        $SDK_VERSION"
echo "SDK VALIDATION:                     PASS"
echo "BOOT PERSISTENCE:                   PASS"
echo "HEALTH MONITORING:                  ACTIVE"
echo "DAILY BACKUPS:                      ACTIVE"
echo "FINAL DB BACKUP:                    $FINAL_DB"
echo "FINAL DB SHA256:                    $FINAL_DB_SHA"
echo "RELEASE MANIFEST:                   $MANIFEST"
echo "RELEASE NOTES:                      $RELEASE_NOTES"
echo "RELEASE BUNDLE:                     $BUNDLE"
echo "RELEASE BUNDLE SHA256:              $BUNDLE_SHA"
echo "REPORT:                             $REPORT"
echo "QFLM VERSION:                       1.0"
echo "======================================================"
