#!/usr/bin/env bash
# QFLM RECOVERY 7E1
# Installations + License Administrative Actions implementation preflight.
# READ-ONLY: no production API/DB/compose/business-data mutation.
# Existing Phase 16D.3 preview containers are left running.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API_SRC="$ROOT/src/QFLM.Api"
APP_SRC="$ROOT/src/QFLM.Application"
INFRA_SRC="$ROOT/src/QFLM.Infrastructure"
DOMAIN_SRC="$ROOT/src/QFLM.Domain"
GUI="$ROOT/src/QFLM.AdminWeb"

PROD_API="qflm-api"
PG="qflm-postgres"
DB="qflm"

PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"
PREVIEW_DB="qflm_gui_preview"

EXPECTED_PROD_IMAGE="qflm-api:recovery6f3-candidate"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="/opt/qflm/backups/recovery7e1-preflight-$STAMP.txt"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p /opt/qflm/backups
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7E1"
printf '%s\n' " INSTALLATIONS + LICENSE ADMIN ACTIONS"
printf '%s\n' " READ-ONLY IMPLEMENTATION PREFLIGHT"
printf '%s\n' "======================================================"

printf '\n=== 1. PRODUCTION BASELINE ===\n'

IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
LICS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
INST=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
ENTS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM license_entitlements;' | xargs)

printf 'image=%s running=%s migrations=%s licenses=%s installations=%s entitlements=%s\n' \
  "$IMAGE" "$RUNNING" "$MIG" "$LICS" "$INST" "$ENTS"

[ "$IMAGE" = "$EXPECTED_PROD_IMAGE" ] || die "unexpected production API image"
[ "$RUNNING" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"

printf '%s\n' "production_baseline=PASS"

printf '\n=== 2. PREVIEW STACK STATUS ===\n'

if docker inspect "$PREVIEW_API" >/dev/null 2>&1; then
    PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}')
else
    PREVIEW_API_RUNNING="missing"
fi

if docker inspect "$PREVIEW_GUI" >/dev/null 2>&1; then
    PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}')
else
    PREVIEW_GUI_RUNNING="missing"
fi

PREVIEW_DB_EXISTS=$(docker exec "$PG" psql -U qflm -d postgres -tAc \
  "SELECT count(*) FROM pg_database WHERE datname='$PREVIEW_DB';" | xargs)

printf 'preview_api_running=%s preview_gui_running=%s preview_db_exists=%s\n' \
  "$PREVIEW_API_RUNNING" "$PREVIEW_GUI_RUNNING" "$PREVIEW_DB_EXISTS"

printf '%s\n' "preview_stack_observed=PASS"

printf '\n=== 3. INSTALLATIONS TABLE SCHEMA ===\n'

docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT
    column_name,
    data_type,
    is_nullable,
    character_maximum_length
FROM information_schema.columns
WHERE table_schema='public'
AND table_name='installations'
ORDER BY ordinal_position;
"

printf '\n=== 4. INSTALLATION INDEXES + FOREIGN KEYS ===\n'

docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT
    indexname,
    indexdef
FROM pg_indexes
WHERE schemaname='public'
AND tablename='installations'
ORDER BY indexname;
"

docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT
    tc.table_name,
    kcu.column_name,
    ccu.table_name AS foreign_table,
    ccu.column_name AS foreign_column
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name=kcu.constraint_name
 AND tc.table_schema=kcu.table_schema
JOIN information_schema.constraint_column_usage ccu
  ON ccu.constraint_name=tc.constraint_name
 AND ccu.table_schema=tc.table_schema
WHERE tc.constraint_type='FOREIGN KEY'
AND tc.table_schema='public'
AND tc.table_name='installations'
ORDER BY kcu.column_name;
"

printf '\n=== 5. INSTALLATION DOMAIN MODEL ===\n'

for f in \
  "$DOMAIN_SRC/Installations/Installation.cs" \
  "$DOMAIN_SRC/Installations/InstallationStatus.cs"
do
    [ -s "$f" ] || die "missing domain file: $f"
    printf '\n--- %s ---\n' "${f#$ROOT/}"
    sed -n '1,260p' "$f"
done

printf '\n=== 6. CURRENT INSTALLATION DATA SNAPSHOT ===\n'

docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -x -c "
SELECT
    i.id,
    i.license_id,
    l.license_number,
    i.installation_identifier,
    i.machine_fingerprint_hash,
    i.installation_public_key IS NOT NULL AS has_public_key,
    i.status,
    i.activated_at_utc,
    i.last_seen_at_utc,
    i.last_heartbeat_sequence,
    i.highest_lease_sequence,
    i.created_at_utc,
    i.updated_at_utc
FROM installations i
JOIN licenses l ON l.id=i.license_id
ORDER BY i.created_at_utc;
"

printf '\n=== 7. EXISTING LICENSE ADMINISTRATION SOURCE ===\n'

grep -RniE \
  'Suspend|Unsuspend|Resume|Revoke|Rebind|Administrative|Installation' \
  "$APP_SRC/Licensing" \
  "$INFRA_SRC/Licensing" \
  "$API_SRC/Controllers" \
  | sed -n '1,360p' || true

printf '\n=== 8. EXISTING ADMIN API ROUTES ===\n'

grep -RniE \
  '\[Route\(|\[Http(Get|Post|Put|Delete|Patch)' \
  "$API_SRC/Controllers" \
  | sed -n '1,360p' || true

printf '\n=== 9. SECURITY PERMISSIONS RELEVANT TO PHASE 16E ===\n'

docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT code,name,category,is_system
FROM auth_permissions
WHERE code IN (
  'installations.read',
  'installations.manage',
  'licenses.read',
  'licenses.manage',
  'licensing.manage',
  'security.admin'
)
ORDER BY category,code;
"

for code in \
  installations.read \
  installations.manage \
  licenses.read \
  licenses.manage \
  licensing.manage \
  security.admin
do
    COUNT=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc \
      "SELECT count(*) FROM auth_permissions WHERE code='$code';" | xargs)

    [ "$COUNT" = 1 ] || die "required permission missing: $code"
done

printf '%s\n' "recovery7e_permission_catalog=PASS"

printf '\n=== 10. CURRENT GUI INSTALLATIONS ROUTE ===\n'

grep -nA12 -B4 'path="installations"' "$GUI/src/App.tsx" || true

if grep -Fq 'path="installations"' "$GUI/src/App.tsx"; then
    printf '%s\n' "installations_route_present=PASS"
else
    die "installations GUI route missing"
fi

printf '\n=== 11. RECOVERY 7D SOURCE PRESENCE ===\n'

for f in \
  "$API_SRC/Controllers/AdminCustomersController.cs" \
  "$API_SRC/Controllers/AdminProductsController.cs" \
  "$API_SRC/Controllers/AdminSubscriptionsController.cs" \
  "$API_SRC/Controllers/AdminLicensesController.cs" \
  "$GUI/src/pages/CustomersPage.tsx" \
  "$GUI/src/pages/ProductsPage.tsx" \
  "$GUI/src/pages/LicensesPage.tsx"
do
    [ -s "$f" ] || die "required prior-phase source missing: $f"
done

printf '%s\n' "recovery7d_source=PASS"

printf '\n=== 12. CURRENT SOURCE BUILD ===\n'

dotnet build QuikeFix.LicenseManager.slnx -c Release \
  || die "current source build failed"

printf '%s\n' "source_build=PASS"

printf '\n=== 13. FINAL PRODUCTION NO-MUTATION CHECK ===\n'

FINAL_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_LICS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_INST=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
FINAL_ENTS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM license_entitlements;' | xargs)

printf 'image=%s running=%s migrations=%s licenses=%s installations=%s entitlements=%s\n' \
  "$FINAL_IMAGE" "$FINAL_RUNNING" "$FINAL_MIG" "$FINAL_LICS" "$FINAL_INST" "$FINAL_ENTS"

[ "$FINAL_IMAGE" = "$IMAGE" ] || die "production image changed"
[ "$FINAL_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "production migrations changed"
[ "$FINAL_LICS" = "$LICS" ] || die "production licenses changed"
[ "$FINAL_INST" = "$INST" ] || die "production installations changed"
[ "$FINAL_ENTS" = "$ENTS" ] || die "production entitlements changed"

printf '%s\n' "production_unchanged=PASS"

printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7E1 PREFLIGHT PASSED"
printf '%s\n' "======================================================"
printf '%s\n' "INSTALLATION SCHEMA:                VERIFIED"
printf '%s\n' "INSTALLATION DOMAIN MODEL:          CAPTURED"
printf '%s\n' "ADMINISTRATION SOURCE:              INVENTORIED"
printf '%s\n' "RELEVANT RBAC PERMISSIONS:          VERIFIED"
printf '%s\n' "INSTALLATIONS GUI ROUTE:            VERIFIED"
printf '%s\n' "RECOVERY 7D SOURCE:                   VERIFIED"
printf '%s\n' "CURRENT SOURCE BUILD:               PASS"
printf '%s\n' "PRODUCTION API/DB:                  UNCHANGED"
printf '%s\n' "PREVIEW STACK:                      OBSERVED / LEFT UNCHANGED"
printf 'REPORT:                             %s\n' "$REPORT"
printf '%s\n' "NEXT: RECOVERY 7E2 - INSTALLATIONS + LICENSE ADMIN ACTIONS GUI/API (ISOLATED)"
printf '%s\n' "======================================================"
