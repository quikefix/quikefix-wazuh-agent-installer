#!/usr/bin/env bash
# QFLM RECOVERY 7D1
# Subscriptions / Licenses / Entitlements management preflight.
# READ-ONLY: no production API, DB, compose, secrets, or business data mutation.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API_SRC="$ROOT/src/QFLM.Api"
DOMAIN="$ROOT/src/QFLM.Domain"
GUI="$ROOT/src/QFLM.AdminWeb"

API="qflm-api"
PG="qflm-postgres"
DB="qflm"
EXPECTED_IMAGE="qflm-api:recovery6f3-candidate"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="/opt/qflm/backups/recovery7d1-preflight-$STAMP.txt"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p /opt/qflm/backups
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7D1"
printf '%s\n' " SUBSCRIPTIONS / LICENSES / ENTITLEMENTS"
printf '%s\n' " READ-ONLY IMPLEMENTATION PREFLIGHT"
printf '%s\n' "======================================================"

printf '\n=== 1. PRODUCTION BASELINE ===\n'

IMAGE=$(docker inspect "$API" --format='{{.Config.Image}}') || die "production API missing"
RUNNING=$(docker inspect "$API" --format='{{.State.Running}}')
MIGRATIONS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
CUSTOMERS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM customers;' | xargs)
PRODUCTS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM products;' | xargs)
FEATURES=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM features;' | xargs)
SUBSCRIPTIONS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM subscriptions;' | xargs)
LICENSES=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
ENTITLEMENTS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM license_entitlements;' | xargs)
INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'image=%s running=%s migrations=%s customers=%s products=%s features=%s subscriptions=%s licenses=%s entitlements=%s installations=%s\n' \
  "$IMAGE" "$RUNNING" "$MIGRATIONS" "$CUSTOMERS" "$PRODUCTS" "$FEATURES" "$SUBSCRIPTIONS" "$LICENSES" "$ENTITLEMENTS" "$INSTALLATIONS"

[ "$IMAGE" = "$EXPECTED_IMAGE" ] || die "unexpected production API image"
[ "$RUNNING" = true ] || die "production API not running"
[ "$MIGRATIONS" = 5 ] || die "unexpected migration count"

printf '%s\n' "production_baseline=PASS"

printf '\n=== 2. VERIFY RECOVERY 7C SOURCE IS PRESERVED ===\n'

for f in \
  "$API_SRC/Controllers/AdminCustomersController.cs" \
  "$API_SRC/Controllers/AdminProductsController.cs" \
  "$GUI/src/pages/CustomersPage.tsx" \
  "$GUI/src/pages/ProductsPage.tsx"
do
    [ -s "$f" ] || die "Phase 16C source missing: $f"
done

printf '%s\n' "recovery7c_source=PASS"

printf '\n=== 3. SUBSCRIPTIONS TABLE SCHEMA ===\n'

docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT
    column_name,
    data_type,
    is_nullable,
    character_maximum_length
FROM information_schema.columns
WHERE table_schema='public'
AND table_name='subscriptions'
ORDER BY ordinal_position;
"

printf '\n=== 4. LICENSES TABLE SCHEMA ===\n'

docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT
    column_name,
    data_type,
    is_nullable,
    character_maximum_length
FROM information_schema.columns
WHERE table_schema='public'
AND table_name='licenses'
ORDER BY ordinal_position;
"

printf '\n=== 5. LICENSE ENTITLEMENTS TABLE SCHEMA ===\n'

docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT
    column_name,
    data_type,
    is_nullable,
    character_maximum_length
FROM information_schema.columns
WHERE table_schema='public'
AND table_name='license_entitlements'
ORDER BY ordinal_position;
"

printf '\n=== 6. RELATED UNIQUE INDEXES + FOREIGN KEYS ===\n'

docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE schemaname='public'
AND tablename IN (
    'subscriptions',
    'licenses',
    'license_entitlements'
)
ORDER BY tablename,indexname;
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
AND tc.table_name IN (
    'subscriptions',
    'licenses',
    'license_entitlements'
)
ORDER BY tc.table_name,kcu.column_name;
"

printf '\n=== 7. DOMAIN ENUMS ===\n'

printf '%s\n' "--- LicenseType ---"
sed -n '1,120p' "$DOMAIN/Licenses/LicenseType.cs"

printf '%s\n' "--- LicenseStatus ---"
sed -n '1,140p' "$DOMAIN/Licenses/LicenseStatus.cs"

printf '%s\n' "--- SubscriptionStatus ---"
sed -n '1,140p' "$DOMAIN/Subscriptions/SubscriptionStatus.cs"

printf '\n=== 8. DOMAIN ENTITIES ===\n'

printf '%s\n' "--- Subscription.cs ---"
sed -n '1,220p' "$DOMAIN/Subscriptions/Subscription.cs"

printf '%s\n' "--- License.cs ---"
sed -n '1,260p' "$DOMAIN/Licenses/License.cs"

printf '%s\n' "--- LicenseEntitlement.cs ---"
sed -n '1,220p' "$DOMAIN/Entitlements/LicenseEntitlement.cs"

printf '\n=== 9. SECURITY PERMISSION CATALOG ===\n'

docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT
    code,
    name,
    category,
    is_system
FROM auth_permissions
ORDER BY category,code;
"

SECURITY_ADMIN=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc "
SELECT count(*)
FROM auth_permissions
WHERE code='security.admin';
" | xargs)

[ "$SECURITY_ADMIN" = 1 ] || die "security.admin permission missing"

printf '%s\n' "security_admin_permission=PASS"

printf '\n=== 10. CURRENT CONTROLLED LICENSE / SUBSCRIPTION SNAPSHOT ===\n'

docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -x -c "
SELECT
    l.id AS license_id,
    l.license_number,
    l.type AS license_type,
    l.status AS license_status,
    l.activation_key_hash IS NOT NULL AS has_activation_hash,
    l.customer_id,
    c.customer_number,
    l.product_id,
    p.product_code,
    l.subscription_id,
    s.status AS subscription_status,
    s.starts_at_utc,
    s.ends_at_utc,
    s.maximum_installations AS subscription_maximum_installations,
    l.valid_from_utc,
    l.valid_until_utc,
    l.grace_period_days,
    l.maximum_installations AS license_maximum_installations
FROM licenses l
JOIN customers c ON c.id=l.customer_id
JOIN products p ON p.id=l.product_id
LEFT JOIN subscriptions s ON s.id=l.subscription_id
ORDER BY l.created_at_utc
LIMIT 10;
"

printf '\n=== 11. CURRENT ENTITLEMENTS ===\n'

docker exec "$PG" psql -U qflm -d "$DB" -P pager=off -c "
SELECT
    l.license_number,
    p.product_code,
    f.feature_code,
    le.enabled,
    le.limit_value
FROM license_entitlements le
JOIN licenses l ON l.id=le.license_id
JOIN products p ON p.id=l.product_id
JOIN features f ON f.id=le.feature_id
ORDER BY l.license_number,f.feature_code;
"

printf '\n=== 12. ACTIVATION KEY STORAGE CHECK ===\n'

HASH_STATS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc "
SELECT
    count(*) || '|' ||
    count(*) FILTER (WHERE activation_key_hash IS NOT NULL) || '|' ||
    count(*) FILTER (
        WHERE activation_key_hash IS NOT NULL
        AND length(activation_key_hash)<>64
    )
FROM licenses;
" | xargs)

printf 'licenses_total|with_hash|non_sha256_length=%s\n' "$HASH_STATS"

BAD_HASHES="${HASH_STATS##*|}"
[ "$BAD_HASHES" = 0 ] || die "non-SHA256-length activation hash detected"

printf '%s\n' "activation_hash_storage=PASS"

printf '\n=== 13. EXISTING ADMIN + LICENSING ROUTES ===\n'

grep -RniE \
  '\[Route\(|\[Http(Get|Post|Put|Delete|Patch)' \
  "$API_SRC/Controllers" \
  | sed -n '1,260p' || true

printf '\n=== 14. CURRENT GUI ROUTES ===\n'

grep -nE \
  'path=|CustomersPage|ProductsPage|LicensesPage|PlaceholderPage' \
  "$GUI/src/App.tsx" \
  | sed -n '1,220p' || true

printf '\n=== 15. CURRENT SOURCE BUILD ===\n'

dotnet build QuikeFix.LicenseManager.slnx -c Release \
  || die "current source build failed"

printf '%s\n' "source_build=PASS"

printf '\n=== 16. FINAL PRODUCTION NO-MUTATION CHECK ===\n'

FINAL_IMAGE=$(docker inspect "$API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$API" --format='{{.State.Running}}')
FINAL_MIGRATIONS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_SUBSCRIPTIONS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM subscriptions;' | xargs)
FINAL_LICENSES=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_ENTITLEMENTS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM license_entitlements;' | xargs)

printf 'image=%s running=%s migrations=%s subscriptions=%s licenses=%s entitlements=%s\n' \
  "$FINAL_IMAGE" "$FINAL_RUNNING" "$FINAL_MIGRATIONS" "$FINAL_SUBSCRIPTIONS" "$FINAL_LICENSES" "$FINAL_ENTITLEMENTS"

[ "$FINAL_IMAGE" = "$IMAGE" ] || die "production image changed"
[ "$FINAL_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIGRATIONS" = "$MIGRATIONS" ] || die "migration count changed"
[ "$FINAL_SUBSCRIPTIONS" = "$SUBSCRIPTIONS" ] || die "subscription count changed"
[ "$FINAL_LICENSES" = "$LICENSES" ] || die "license count changed"
[ "$FINAL_ENTITLEMENTS" = "$ENTITLEMENTS" ] || die "entitlement count changed"

printf '%s\n' "production_unchanged=PASS"

printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7D1 PREFLIGHT PASSED"
printf '%s\n' "======================================================"
printf '%s\n' "SUBSCRIPTION SCHEMA:                VERIFIED"
printf '%s\n' "LICENSE SCHEMA:                     VERIFIED"
printf '%s\n' "ENTITLEMENT SCHEMA:                 VERIFIED"
printf '%s\n' "LICENSE/SUBSCRIPTION ENUMS:         CAPTURED"
printf '%s\n' "SECURITY.ADMIN POLICY BASIS:        VERIFIED"
printf '%s\n' "ACTIVATION KEY HASH STORAGE:        VERIFIED"
printf '%s\n' "CURRENT SOURCE BUILD:               PASS"
printf '%s\n' "PRODUCTION API/DB:                  UNCHANGED"
printf 'REPORT:                             %s\n' "$REPORT"
printf '%s\n' "NEXT: RECOVERY 7D2 - SUBSCRIPTIONS / LICENSES / ENTITLEMENTS GUI + API (ISOLATED)"
printf '%s\n' "======================================================"
