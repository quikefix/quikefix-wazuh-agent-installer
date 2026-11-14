#!/usr/bin/env bash
# QFLM RECOVERY 7H1
# Audit & Reports GUI/API preflight - read-only.
# No source, database, preview, or production mutation.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API="$ROOT/src/QFLM.Api"
APP="$ROOT/src/QFLM.Application"
INFRA="$ROOT/src/QFLM.Infrastructure"
DOMAIN="$ROOT/src/QFLM.Domain"
GUI="$ROOT/src/QFLM.AdminWeb"

PG="qflm-postgres"
PROD_API="qflm-api"
PROD_DB="qflm"
PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="/opt/qflm/backups/recovery7h1-audit-reports-preflight-$STAMP.txt"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p /opt/qflm/backups
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7H1"
echo " AUDIT & REPORTS GUI/API PREFLIGHT"
echo " READ ONLY"
echo "======================================================"

echo
echo "=== 1. PRODUCTION SAFETY BASELINE ==="

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

printf 'prod_image=%s running=%s migrations=%s\n' "$PROD_IMAGE" "$PROD_RUNNING" "$MIG"

[ "$PROD_IMAGE" = "qflm-api:recovery6f3-candidate" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"

echo "production_baseline=PASS"

echo
echo "=== 2. CURRENT PREVIEW BASELINE ==="

PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)

printf 'preview_api=%s preview_gui=%s api_image=%s gui_image=%s\n' \
 "$PREVIEW_API_RUNNING" "$PREVIEW_GUI_RUNNING" "$PREVIEW_API_IMAGE" "$PREVIEW_GUI_IMAGE"

[ "$PREVIEW_API_RUNNING" = true ] || die "preview API not running"
[ "$PREVIEW_GUI_RUNNING" = true ] || die "preview GUI not running"
[ "$PREVIEW_API_IMAGE" = "qflm-api:recovery7f2-candidate" ] || die "unexpected preview API image"
[ "$PREVIEW_GUI_IMAGE" = "qflm-admin-web:recovery7g3-preview" ] || die "unexpected preview GUI image"

HOST_IP=$(ip -4 -o addr show dev ens18 scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)
[ -n "$HOST_IP" ] || die "no IPv4 address found on ens18"
ORIGIN_AUDIT=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST_IP}:8088/audit" || true)
PUBLIC_SECURITY=$(curl -L -s -o /dev/null -w '%{http_code}' https://lc.quikefix.info/security || true)
PUBLIC_OFFLINE=$(curl -L -s -o /dev/null -w '%{http_code}' https://lc.quikefix.info/offline || true)

printf 'origin_ip=%s origin_audit=%s public_security=%s public_offline=%s\n' "$HOST_IP" "$ORIGIN_AUDIT" "$PUBLIC_SECURITY" "$PUBLIC_OFFLINE"
[ "$ORIGIN_AUDIT" = 200 ] || die "preview audit origin route not healthy"

[ "$PUBLIC_SECURITY" = 200 ] || die "security preview route not healthy"
[ "$PUBLIC_OFFLINE" = 200 ] || die "offline preview route not healthy"

echo "preview_baseline=PASS"

echo
echo "=== 3. CONTROLLER INVENTORY - AUDIT / REPORTS ==="

find "$API/Controllers" -maxdepth 1 -type f -name '*.cs' -print | sort

echo
echo "--- Matching audit/report controller symbols ---"
grep -RniE \
 --exclude-dir=bin \
 --exclude-dir=obj \
 'Audit|Report|Reporting|reports\.read|audit\.read' \
 "$API/Controllers" \
 | sed -n '1,420p' || true

echo "controller_inventory=PASS"

echo
echo "=== 4. APPLICATION / INFRASTRUCTURE INVENTORY ==="

grep -RniE \
 --exclude-dir=bin \
 --exclude-dir=obj \
 'Audit|Report|Reporting|AuditEvent|EventType|Outcome' \
 "$APP" "$INFRA" "$DOMAIN" \
 | sed -n '1,520p' || true

echo "audit_report_service_inventory=PASS"

echo
echo "=== 5. DATABASE AUDIT / REPORT TABLE INVENTORY ==="

docker exec "$PG" psql -U qflm -d "$PROD_DB" -P pager=off -c "
SELECT tablename
FROM pg_tables
WHERE schemaname='public'
  AND (
    tablename ILIKE '%audit%'
    OR tablename ILIKE '%event%'
    OR tablename ILIKE '%report%'
    OR tablename ILIKE '%history%'
    OR tablename ILIKE '%issuance%'
  )
ORDER BY tablename;
"

echo
echo "=== 6. TABLE COUNTS ==="

for t in \
  offline_license_audit_events \
  offline_license_issuances \
  installation_activity_events \
  licensing_audit_events \
  audit_events
do
    EXISTS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT to_regclass('public.$t') IS NOT NULL;" | xargs)
    if [ "$EXISTS" = t ]; then
        COUNT=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM $t;" | xargs)
        printf '%s=%s\n' "$t" "$COUNT"
    else
        printf '%s=NOT_PRESENT\n' "$t"
    fi
done

echo
echo "=== 7. AUDIT/REPORT TABLE COLUMN CONTRACTS ==="

docker exec "$PG" psql -U qflm -d "$PROD_DB" -P pager=off -c "
SELECT table_name,column_name,data_type,is_nullable
FROM information_schema.columns
WHERE table_schema='public'
  AND (
    table_name ILIKE '%audit%'
    OR table_name ILIKE '%event%'
    OR table_name ILIKE '%report%'
    OR table_name ILIKE '%history%'
    OR table_name ILIKE '%issuance%'
  )
ORDER BY table_name,ordinal_position;
"

echo
echo "=== 8. RECENT AUDIT / ACTIVITY SAMPLE - NONSECRET ==="

for t in offline_license_audit_events installation_activity_events licensing_audit_events audit_events; do
    EXISTS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT to_regclass('public.$t') IS NOT NULL;" | xargs)
    if [ "$EXISTS" = t ]; then
        echo
        echo "--- $t ---"
        docker exec "$PG" psql -U qflm -d "$PROD_DB" -P pager=off -c \
          "SELECT * FROM $t ORDER BY 1 DESC LIMIT 10;" 2>/dev/null || true
    fi
done

echo
echo "=== 9. EXACT AUDIT / REPORT PERMISSIONS ==="

docker exec "$PG" psql -U qflm -d "$PROD_DB" -P pager=off -c "
SELECT id,code,name,category,description,is_system
FROM auth_permissions
WHERE code IN ('audit.read','reports.read')
   OR category ILIKE '%audit%'
   OR category ILIKE '%report%'
ORDER BY category,code;
"

echo
echo "=== 10. CURRENT AUTHORIZATION POLICIES ==="

grep -nA28 -B6 'AddAuthorization' "$API/Program.cs" | sed -n '1,120p'

echo
echo "=== 11. CURRENT GUI AUDIT ROUTE ==="

grep -nA14 -B6 'path="audit"' "$GUI/src/App.tsx" || true

if grep -q 'path="audit"' "$GUI/src/App.tsx"; then
    echo "audit_route_present=PASS"
else
    die "audit route missing from GUI"
fi

echo
echo "=== 12. GUI PAGE INVENTORY ==="

find "$GUI/src/pages" -maxdepth 1 -type f -name '*.tsx' -printf '%f\n' | sort

echo
echo "=== 13. DASHBOARD / EXISTING REPORTING SURFACES ==="

grep -RniE \
 --exclude-dir=node_modules \
 'report|audit|event|activity|history|metric|dashboard' \
 "$GUI/src" \
 | sed -n '1,420p' || true

echo
echo "=== 14. RELEASE BUILD ==="

cd "$ROOT" || die "project root missing"
dotnet build QuikeFix.LicenseManager.slnx -c Release || die "release build failed"

echo "source_build=PASS"

echo
echo "=== 15. FINAL NO-MUTATION CHECK ==="

FINAL_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

[ "$FINAL_IMAGE" = "$PROD_IMAGE" ] || die "production image changed"
[ "$FINAL_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "production migrations changed"

FINAL_PREVIEW_API=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
FINAL_PREVIEW_GUI=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)

[ "$FINAL_PREVIEW_API" = true ] || die "preview API stopped"
[ "$FINAL_PREVIEW_GUI" = true ] || die "preview GUI stopped"

echo "production_preview_unchanged=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7H1 PREFLIGHT PASSED"
echo "======================================================"
echo "AUDIT CONTROLLERS/SERVICES: INVENTORIED"
echo "REPORTING SURFACES:         INVENTORIED"
echo "AUDIT/REPORT DB TABLES:     INVENTORIED"
echo "AUDIT/REPORT PERMISSIONS:   INVENTORIED"
echo "GUI AUDIT ROUTE:            PRESENT"
echo "CURRENT PREVIEW:            HEALTHY"
echo "PRODUCTION API/DB:          UNCHANGED"
echo "REPORT:                     $REPORT"
echo "NEXT: RECOVERY 7H2 - AUDIT & REPORTS GUI/API ISOLATED"
echo "======================================================"
