#!/usr/bin/env bash
# QFLM RECOVERY 7M1
# Client Licensing SDK / Integration preflight.
# Read-only inventory of production-facing licensing, activation,
# installation and offline-license APIs. No mutation.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API="$ROOT/src/QFLM.Api"
APP="$ROOT/src/QFLM.Application"
DOMAIN="$ROOT/src/QFLM.Domain"
INFRA="$ROOT/src/QFLM.Infrastructure"
OFFLINE="$ROOT/src/QFLM.OfflineLicensing"

PROD_API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"

EXPECTED_PROD_IMAGE="qflm-api:recovery7k2-production"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7m1-client-sdk-preflight-$STAMP"
REPORT="$BACKUP/recovery7m1-client-sdk-preflight-report.txt"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7M1"
echo " CLIENT LICENSING SDK / INTEGRATION PREFLIGHT"
echo " READ ONLY"
echo "======================================================"

echo
echo "=== 1. FINAL FROZEN PRODUCTION BASELINE ==="

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

[ "$PROD_IMAGE" = "$EXPECTED_PROD_IMAGE" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"

echo "production_baseline=PASS"

echo
echo "=== 2. CONTROLLER INVENTORY ==="

find "$API/Controllers" -maxdepth 1 -type f -name '*.cs' -printf '%f\n' | sort

echo
echo "=== 3. ROUTE / HTTP METHOD INVENTORY ==="

grep -RInE '\[Route\(|\[Http(Get|Post|Put|Patch|Delete)' "$API/Controllers"  | sed "s#^$ROOT/##"  | sort  | sed -n '1,500p'

echo
echo "=== 4. LICENSING / ACTIVATION / INSTALLATION KEYWORDS ==="

grep -RInE 'activat|deactivat|validat|license|installation|fingerprint|machine|device|heartbeat|check.?in|entitlement|feature|grace|revok|suspend|offline|token|key'  "$API" "$APP" "$DOMAIN" "$INFRA" "$OFFLINE"  --include='*.cs'  | sed "s#^$ROOT/##"  | sed -n '1,1200p'

echo
echo "=== 5. PUBLIC / ANONYMOUS ENDPOINT REVIEW ==="

grep -RInE 'AllowAnonymous|Authorize|Policy *=|AuthenticationSchemes' "$API/Controllers"  | sed "s#^$ROOT/##"  | sed -n '1,500p'

echo
echo "=== 6. DTO / REQUEST / RESPONSE INVENTORY ==="

find "$API" "$APP" -type f \( -name '*Request*.cs' -o -name '*Response*.cs' -o -name '*Dto*.cs' -o -name '*DTO*.cs' \)  -printf '%p\n'  | sed "s#^$ROOT/##"  | sort  | sed -n '1,500p'

echo
echo "=== 7. DATABASE LICENSING TABLE INVENTORY ==="

docker exec "$PG" psql -U qflm -d "$PROD_DB" -Atc "
SELECT tablename
FROM pg_tables
WHERE schemaname='public'
ORDER BY tablename;
" | sed -n '1,300p'

echo
echo "=== 8. LICENSE / INSTALLATION SCHEMA ==="

for table in licenses installations products customers offline_license_issuances offline_license_audit_events; do
  echo "--- $table ---"
  docker exec "$PG" psql -U qflm -d "$PROD_DB" -c "\\d+ $table" 2>/dev/null || true
done

echo
echo "=== 9. API OPENAPI / SWAGGER DISCOVERY ==="

grep -RInE 'Swagger|OpenApi|MapOpenApi|AddOpenApi|UseSwagger|SwaggerUI' "$API" --include='*.cs'  | sed "s#^$ROOT/##"  | sed -n '1,300p' || true

echo
echo "=== 10. RELEASE BUILD ==="

cd "$ROOT" || die "project root missing"
dotnet build QuikeFix.LicenseManager.slnx -c Release || die "release build failed"

echo "release_build=PASS"

echo
echo "=== 11. FINAL NO-MUTATION CHECK ==="

FINAL_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

[ "$FINAL_IMAGE" = "$PROD_IMAGE" ] || die "production API image changed"
[ "$FINAL_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "migration count changed"

echo "no_mutation=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7M1 PASSED"
echo "======================================================"
echo "PRODUCTION API/DB:                  UNCHANGED"
echo "CLIENT API INVENTORY:               CAPTURED"
echo "AUTHORIZATION INVENTORY:            CAPTURED"
echo "LICENSING SCHEMA:                   CAPTURED"
echo "RELEASE BUILD:                      PASS"
echo "REPORT:                             $REPORT"
echo "NEXT: RECOVERY 7M2 - CLIENT LICENSING API FOUNDATION / SDK CONTRACT"
echo "======================================================"
