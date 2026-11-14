#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API="$ROOT/src/QFLM.Api"
APP="$ROOT/src/QFLM.Application"
DOMAIN="$ROOT/src/QFLM.Domain"
INFRA="$ROOT/src/QFLM.Infrastructure"

PROD_API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"
EXPECTED_PROD_IMAGE="qflm-api:recovery7k2-production"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7m2-sdk-contract-$STAMP"
REPORT="$BACKUP/recovery7m2-sdk-contract-report.txt"
CONTRACT="$BACKUP/qflm-client-sdk-contract.md"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7M2"
echo " CLIENT LICENSING API FOUNDATION / SDK CONTRACT"
echo " READ ONLY"
echo "======================================================"

echo
echo "=== 1. FINAL PRODUCTION BASELINE ==="

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

[ "$PROD_IMAGE" = "$EXPECTED_PROD_IMAGE" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"

echo "production_baseline=PASS"

echo
echo "=== 2. IDENTIFY CLIENT LICENSING CONTROLLERS ==="

mapfile -t CLIENT_CONTROLLERS < <(
  grep -RlE 'ILicensingService|ActivateAsync|DeactivateAsync|ValidateAsync|HeartbeatAsync|ActivationRequest|ValidationRequest|HeartbeatRequest|DeactivationRequest'     "$API/Controllers" --include='*.cs' | sort -u
)

[ "${#CLIENT_CONTROLLERS[@]}" -ge 1 ] || die "no client licensing controller found"

printf '%s\n' "${CLIENT_CONTROLLERS[@]}" | sed "s#^$ROOT/##"
echo "client_controller_discovery=PASS"

echo
echo "=== 3. EXACT CLIENT CONTROLLER SOURCE ==="

for file in "${CLIENT_CONTROLLERS[@]}"; do
  echo
  echo "----- ${file#$ROOT/} -----"
  sed -n '1,500p' "$file"
done

echo
echo "=== 4. LICENSING MODELS ==="

MODEL_FILE="$APP/Licensing/Models/LicensingModels.cs"
[ -f "$MODEL_FILE" ] || die "LicensingModels.cs missing"
sed -n '1,500p' "$MODEL_FILE"

echo
echo "=== 5. LICENSING SERVICE INTERFACE ==="

SERVICE_FILE="$APP/Licensing/Services/ILicensingService.cs"
[ -f "$SERVICE_FILE" ] || die "ILicensingService.cs missing"
sed -n '1,300p' "$SERVICE_FILE"

echo
echo "=== 6. SERVICE IMPLEMENTATION CONTRACT ==="

mapfile -t SERVICE_IMPLS < <(
  grep -Rl 'ILicensingService' "$INFRA" "$APP" --include='*.cs'     | grep -v '/Services/ILicensingService.cs$'     | sort -u
)

printf '%s\n' "${SERVICE_IMPLS[@]}" | sed "s#^$ROOT/##"

for file in "${SERVICE_IMPLS[@]}"; do
  echo
  echo "----- ${file#$ROOT/} -----"
  sed -n '1,700p' "$file"
done

echo
echo "=== 7. DOMAIN STATUS ENUMS ==="

find "$DOMAIN" -type f \(  -name '*LicenseStatus*.cs' -o  -name '*InstallationStatus*.cs' -o  -name '*SubscriptionStatus*.cs' \) -print | sort | while read -r file; do
  echo
  echo "----- ${file#$ROOT/} -----"
  cat "$file"
done

echo
echo "=== 8. ROUTE MATRIX ==="

{
  echo "# QFLM Client SDK Contract"
  echo
  echo "Generated UTC: $STAMP"
  echo
  echo "Production API image: $PROD_IMAGE"
  echo
  echo "## Client-facing routes"
  echo
  echo "| Controller | Base Route | HTTP Attribute | Authorization |"
  echo "|---|---|---|---|"

  for file in "${CLIENT_CONTROLLERS[@]}"; do
    controller="$(basename "$file")"
    base="$(grep -m1 -E '\[Route\(' "$file" | sed 's/^[[:space:]]*//')"
    auth="$(grep -m1 -E '\[(AllowAnonymous|Authorize)' "$file" | sed 's/^[[:space:]]*//' || true)"

    mapfile -t methods < <(grep -E '\[Http(Get|Post|Put|Patch|Delete)' "$file" | sed 's/^[[:space:]]*//')
    if [ "${#methods[@]}" -eq 0 ]; then
      printf '| %s | %s | %s | %s |\n' "$controller" "$base" 'NONE' "$auth"
    else
      for method in "${methods[@]}"; do
        printf '| %s | %s | %s | %s |\n' "$controller" "$base" "$method" "$auth"
      done
    fi
  done

  echo
  echo "## Request/response model source"
  echo
  cat "$MODEL_FILE"
  echo
  echo "## Licensing service interface"
  echo
  cat "$SERVICE_FILE"
} > "$CONTRACT"

chmod 400 "$CONTRACT"
echo "route_matrix_contract=PASS"

echo
echo "=== 9. OPENAPI CONTRACT AVAILABILITY ==="

grep -Rq 'AddOpenApi' "$API" --include='*.cs' || die "AddOpenApi missing"
grep -Rq 'MapOpenApi' "$API" --include='*.cs' || die "MapOpenApi missing"

echo "openapi_foundation=PASS"

echo
echo "=== 10. CLIENT CAPABILITY CHECKLIST ==="

for symbol in ActivationRequest DeactivationRequest ValidationRequest HeartbeatRequest; do
  if grep -Rq "$symbol" "$APP" "$API" --include='*.cs'; then
    echo "$symbol=FOUND"
  else
    echo "$symbol=MISSING"
  fi
done

for symbol in ActivateAsync DeactivateAsync ValidateAsync HeartbeatAsync; do
  if grep -Rq "$symbol" "$APP" "$INFRA" "$API" --include='*.cs'; then
    echo "$symbol=FOUND"
  else
    echo "$symbol=MISSING"
  fi
done

echo "client_capability_inventory=PASS"

echo
echo "=== 11. RELEASE BUILD ==="

cd "$ROOT" || die "project root missing"
dotnet build QuikeFix.LicenseManager.slnx -c Release || die "release build failed"

echo "release_build=PASS"

echo
echo "=== 12. FINAL NO-MUTATION CHECK ==="

FINAL_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

[ "$FINAL_IMAGE" = "$PROD_IMAGE" ] || die "production API image changed"
[ "$FINAL_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "migration count changed"

echo "no_mutation=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7M2 PASSED"
echo "======================================================"
echo "CLIENT CONTROLLERS:                 DISCOVERED"
echo "REQUEST/RESPONSE MODELS:            CAPTURED"
echo "LICENSING SERVICE CONTRACT:         CAPTURED"
echo "DOMAIN STATUS CONTRACT:             CAPTURED"
echo "OPENAPI FOUNDATION:                 PASS"
echo "PRODUCTION API/DB:                  UNCHANGED"
echo "SDK CONTRACT:                       $CONTRACT"
echo "REPORT:                             $REPORT"
echo "NEXT: RECOVERY 7M3 - .NET CLIENT SDK IMPLEMENTATION / ISOLATED TESTS"
echo "======================================================"
