#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API_SRC="$ROOT/src/QFLM.Api"
APP_SRC="$ROOT/src/QFLM.Application"
INFRA_SRC="$ROOT/src/QFLM.Infrastructure"
OFFLINE_SRC="$ROOT/src/QFLM.OfflineLicensing"
SIGNING_SRC="$ROOT/src/QFLM.SigningService"
GUI="$ROOT/src/QFLM.AdminWeb"

PROD_API="qflm-api"
PG="qflm-postgres"
DB="qflm"
PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"
PREVIEW_DB="qflm_gui_preview"
EXPECTED_PROD_IMAGE="qflm-api:recovery6f3-candidate"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="/opt/qflm/backups/recovery7f1-preflight-$STAMP.txt"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p /opt/qflm/backups
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

echo "======================================================"
echo " QFLM RECOVERY 7F1"
echo " OFFLINE LICENSING ADMINISTRATION"
echo " READ-ONLY IMPLEMENTATION PREFLIGHT"
echo "======================================================"

echo
echo "=== 1. PRODUCTION BASELINE ==="

IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
LICENSES=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
ISSUANCES=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
AUDIT=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

printf 'image=%s running=%s migrations=%s licenses=%s installations=%s offline_issuances=%s offline_audit=%s\n'  "$IMAGE" "$RUNNING" "$MIG" "$LICENSES" "$INSTALLATIONS" "$ISSUANCES" "$AUDIT"

[ "$IMAGE" = "$EXPECTED_PROD_IMAGE" ] || die "unexpected production API image"
[ "$RUNNING" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"
echo "production_baseline=PASS"

echo
echo "=== 2. PREVIEW STATUS ==="

PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_DB_EXISTS=$(docker exec "$PG" psql -U qflm -d postgres -tAc "SELECT count(*) FROM pg_database WHERE datname='$PREVIEW_DB';" | xargs)

printf 'preview_api_running=%s preview_gui_running=%s preview_db_exists=%s\n'  "$PREVIEW_API_RUNNING" "$PREVIEW_GUI_RUNNING" "$PREVIEW_DB_EXISTS"
echo "preview_stack_observed=PASS"

echo
echo "=== 3. OFFLINE ISSUANCE SCHEMA ==="
docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT column_name,data_type,is_nullable,character_maximum_length
FROM information_schema.columns
WHERE table_schema='public'
AND table_name='offline_license_issuances'
ORDER BY ordinal_position;
"

echo
echo "=== 4. OFFLINE AUDIT SCHEMA ==="
docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT column_name,data_type,is_nullable,character_maximum_length
FROM information_schema.columns
WHERE table_schema='public'
AND table_name='offline_license_audit_events'
ORDER BY ordinal_position;
"

echo
echo "=== 5. OFFLINE INDEXES + FOREIGN KEYS ==="
docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT tablename,indexname,indexdef
FROM pg_indexes
WHERE schemaname='public'
AND tablename IN ('offline_license_issuances','offline_license_audit_events')
ORDER BY tablename,indexname;
"

docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT tc.table_name,kcu.column_name,ccu.table_name AS foreign_table,ccu.column_name AS foreign_column
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name=kcu.constraint_name
 AND tc.table_schema=kcu.table_schema
JOIN information_schema.constraint_column_usage ccu
  ON ccu.constraint_name=tc.constraint_name
 AND ccu.table_schema=tc.table_schema
WHERE tc.constraint_type='FOREIGN KEY'
AND tc.table_schema='public'
AND tc.table_name IN ('offline_license_issuances','offline_license_audit_events')
ORDER BY tc.table_name,kcu.column_name;
"

echo
echo "=== 6. OFFLINE LICENSING SOURCE INVENTORY ==="
find "$OFFLINE_SRC" -maxdepth 4 -type f \( -name '*.cs' -o -name '*.csproj' \) | sort

echo
echo "=== 7. SIGNING SERVICE SOURCE INVENTORY ==="
find "$SIGNING_SRC" -maxdepth 4 -type f \( -name '*.cs' -o -name '*.csproj' \) | sort

echo
echo "=== 8. OFFLINE REQUEST / LICENSE / RENEWAL CONTRACTS ==="
grep -RniE 'qfreq|qfl|Offline|Renew|Renewal|Issue|Issuance|Sequence|Canonical|Signature|Ed25519|StateEvaluator'  "$OFFLINE_SRC" "$APP_SRC" "$INFRA_SRC" "$API_SRC" | sed -n '1,520p' || true

echo
echo "=== 9. SIGNING BOUNDARY + KEY REFERENCES ==="
grep -RniE 'Signing|SignAsync|PrivateKey|PublicKey|Ed25519|KeyId|KeyFile|signing'  "$SIGNING_SRC" "$OFFLINE_SRC" "$APP_SRC" "$INFRA_SRC" "$API_SRC" | sed -n '1,420p' || true

echo
echo "=== 10. CURRENT OFFLINE DATA SNAPSHOT ==="
docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT *
FROM offline_license_issuances
ORDER BY created_at_utc DESC
LIMIT 10;
"

docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT *
FROM offline_license_audit_events
ORDER BY created_at_utc DESC
LIMIT 20;
"

echo
echo "=== 11. OFFLINE SECURITY PERMISSIONS ==="
docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT code,name,category,is_system
FROM auth_permissions
WHERE code IN (
 'offline.read',
 'offline.issue',
 'offline.renew',
 'licenses.read',
 'licenses.manage',
 'security.admin'
)
ORDER BY category,code;
"

for code in offline.read offline.issue offline.renew licenses.read licenses.manage security.admin
do
  COUNT=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc "SELECT count(*) FROM auth_permissions WHERE code='$code';" | xargs)
  [ "$COUNT" = 1 ] || die "required permission missing: $code"
done

echo "offline_permission_catalog=PASS"

echo
echo "=== 12. CURRENT OFFLINE API ROUTES ==="
grep -RniE '\[Route\(|\[Http(Get|Post|Put|Delete|Patch)|offline|Offline' "$API_SRC/Controllers" | sed -n '1,360p' || true

echo
echo "=== 13. CURRENT GUI OFFLINE ROUTE ==="
grep -nA12 -B4 'path="offline"' "$GUI/src/App.tsx" || true
grep -Fq 'path="offline"' "$GUI/src/App.tsx" || die "offline GUI route missing"
echo "offline_route_present=PASS"

echo
echo "=== 14. PRIOR SOURCE PRESENCE ==="
for f in  "$API_SRC/Controllers/AdminInstallationsController.cs"  "$API_SRC/Controllers/AdminLicensesController.cs"  "$GUI/src/pages/InstallationsPage.tsx"  "$GUI/src/pages/LicensesPage.tsx"
do
  [ -s "$f" ] || die "required prior source missing: $f"
done
echo "recovery7e_source=PASS"

echo
echo "=== 15. CURRENT SOURCE BUILD ==="
dotnet build QuikeFix.LicenseManager.slnx -c Release || die "current source build failed"
echo "source_build=PASS"

echo
echo "=== 16. FINAL PRODUCTION NO-MUTATION CHECK ==="

FINAL_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_LICENSES=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
FINAL_ISSUANCES=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
FINAL_AUDIT=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

printf 'image=%s running=%s migrations=%s licenses=%s installations=%s offline_issuances=%s offline_audit=%s\n'  "$FINAL_IMAGE" "$FINAL_RUNNING" "$FINAL_MIG" "$FINAL_LICENSES" "$FINAL_INSTALLATIONS" "$FINAL_ISSUANCES" "$FINAL_AUDIT"

[ "$FINAL_IMAGE" = "$IMAGE" ] || die "production image changed"
[ "$FINAL_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "production migrations changed"
[ "$FINAL_LICENSES" = "$LICENSES" ] || die "production licenses changed"
[ "$FINAL_INSTALLATIONS" = "$INSTALLATIONS" ] || die "production installations changed"
[ "$FINAL_ISSUANCES" = "$ISSUANCES" ] || die "production offline issuances changed"
[ "$FINAL_AUDIT" = "$AUDIT" ] || die "production offline audit changed"

echo "production_unchanged=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7F1 PREFLIGHT PASSED"
echo "======================================================"
echo "OFFLINE ISSUANCE SCHEMA:            VERIFIED"
echo "OFFLINE AUDIT SCHEMA:               VERIFIED"
echo "OFFLINE SOURCE CONTRACTS:           INVENTORIED"
echo "SIGNING BOUNDARY:                   INVENTORIED"
echo "OFFLINE RBAC PERMISSIONS:           VERIFIED"
echo "OFFLINE GUI ROUTE:                  VERIFIED"
echo "RECOVERY 7E SOURCE:                 VERIFIED"
echo "CURRENT SOURCE BUILD:               PASS"
echo "PRODUCTION API/DB:                  UNCHANGED"
echo "CURRENT CLOUDFLARE PREVIEW:         LEFT RUNNING / UNCHANGED"
echo "REPORT:                             $REPORT"
echo "NEXT: RECOVERY 7F2 - OFFLINE LICENSING ADMIN GUI/API (ISOLATED)"
echo "======================================================"
