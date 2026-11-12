#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API="qflm-api"
PG="qflm-postgres"
DB="qflm"
NET="qflm_backend"

OLD_API_IMAGE="qflm-api:13e-candidate"
NEW_API_IMAGE="qflm-api:phase14d4-candidate"
SIGN_IMAGE="qflm-signing:14c-candidate"
SIGN_SERVICE="qflm-signing"

API_SECRET_DIR="/opt/qflm/secrets/runtime-api"
SIGN_SECRET_DIR="/opt/qflm/secrets/signing-runtime"
SIGN_COMPOSE="/opt/qflm/compose/signing.yml"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery5d2-$STAMP"
DB_BACKUP="$BACKUP/qflm-before-recovery5d2.dump"
MIG_FWD="$BACKUP/offline-forward.sql"
MIG_REV="$BACKUP/offline-reverse.sql"
PUBLISH="$ROOT/artifacts/api-publish-phase14d4"
DOCKERFILE="$ROOT/Dockerfile.phase14d4"

DB_MIGRATED=0
API_REPLACED=0
SIGNING_STARTED=0
COMPLETED=0

die(){ echo "STOP: $*" >&2; exit 1; }

rollback(){
  [ "$COMPLETED" -eq 1 ] && return 0
  echo
  echo "=== RECOVERY 5D2 AUTOMATIC ROLLBACK ==="

  if [ "$API_REPLACED" -eq 1 ]; then
    docker rm -f "$API" >/dev/null 2>&1 || true
    docker run -d       --name "$API"       --restart unless-stopped       --network "$NET"       --read-only       --cap-drop ALL       --security-opt no-new-privileges:true       --tmpfs /tmp:rw,noexec,nosuid,size=32m       -e ASPNETCORE_URLS=http://+:8080       -v "$API_SECRET_DIR/postgres_password:/run/secrets/postgres_password:ro"       -v "$API_SECRET_DIR/redis_password:/run/secrets/redis_password:ro"       "$OLD_API_IMAGE" >/dev/null 2>&1 || true
    echo "api_image_rollback=ATTEMPTED"
  fi

  if [ "$SIGNING_STARTED" -eq 1 ]; then
    docker compose -f "$SIGN_COMPOSE" down >/dev/null 2>&1 || true
    echo "signing_rollback=ATTEMPTED"
  fi

  if [ "$DB_MIGRATED" -eq 1 ] && [ -s "$MIG_REV" ]; then
    if cat "$MIG_REV" | docker exec -i "$PG" psql -U qflm -d "$DB" -v ON_ERROR_STOP=1 >/dev/null 2>&1; then
      echo "database_reverse_migration=PASS"
    else
      echo "database_reverse_migration=FAILED"
      echo "database_backup=$DB_BACKUP"
    fi
  fi
}
trap rollback EXIT

echo "======================================================"
echo " QFLM RECOVERY 5D2 - GUARDED PRODUCTION PROMOTION"
echo "======================================================"

cd "$ROOT"
mkdir -p "$BACKUP"

IMG="$(docker inspect "$API" --format='{{.Config.Image}}')" || die "API missing"
RUN="$(docker inspect "$API" --format='{{.State.Running}}')"
MIG="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
OFFT="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('offline_license_issuances','offline_license_audit_events');" | xargs)"
LIC="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)"
INST="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)"

[ "$IMG" = "$OLD_API_IMAGE" ] || die "unexpected API image: $IMG"
[ "$RUN" = true ] || die "API not running"
[ "$MIG" = 2 ] || die "expected 2 production migrations"
[ "$OFFT" = 0 ] || die "offline tables already exist"

NEW_MIG_FILE="$(find src/QFLM.Infrastructure/Persistence/Migrations -maxdepth 1 -type f -name '*_AddOfflineLicensePersistence.cs' | sort | tail -n1)"
[ -s "$NEW_MIG_FILE" ] || die "offline persistence migration missing"
NEW_MIG="$(basename "$NEW_MIG_FILE" .cs)"

mapfile -t APPLIED < <(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT "MigrationId" FROM "__EFMigrationsHistory" ORDER BY "MigrationId";')
[ "${#APPLIED[@]}" -eq 2 ] || die "unable to resolve previous migration"
OLD_MIG="${APPLIED[1]}"

echo "old_migration=$OLD_MIG"
echo "new_migration=$NEW_MIG"
echo "production_baseline=PASS"

for f in  "$API_SECRET_DIR/postgres_password"  "$API_SECRET_DIR/redis_password"  "$SIGN_SECRET_DIR/private.pem"  "$SIGN_SECRET_DIR/public.pem"  "$SIGN_SECRET_DIR/token"  "$SIGN_SECRET_DIR/key-id"
do
  [ -s "$f" ] || die "missing required runtime secret: $f"
done

docker image inspect "$SIGN_IMAGE" >/dev/null 2>&1 || die "Phase14C signing image missing"

dotnet build QuikeFix.LicenseManager.slnx -c Release || die "release build failed"
rm -rf "$PUBLISH"
dotnet publish src/QFLM.Api/QFLM.Api.csproj -c Release -o "$PUBLISH" >/dev/null
[ -s "$PUBLISH/QFLM.Api.dll" ] || die "API publish missing"

cat > "$DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-phase14d4/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER

docker build -f "$DOCKERFILE" -t "$NEW_API_IMAGE" . >/dev/null || die "API image build failed"

dotnet tool restore >/dev/null
dotnet tool run dotnet-ef migrations script  "$OLD_MIG" "$NEW_MIG"  --project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj  --startup-project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj  --context QflmDbContext  --output "$MIG_FWD" || die "forward migration SQL generation failed"

dotnet tool run dotnet-ef migrations script  "$NEW_MIG" "$OLD_MIG"  --project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj  --startup-project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj  --context QflmDbContext  --output "$MIG_REV" || die "reverse migration SQL generation failed"

grep -q offline_license_issuances "$MIG_FWD" || die "forward SQL missing issuance table"
grep -q offline_license_audit_events "$MIG_FWD" || die "forward SQL missing audit table"
grep -qi 'DROP TABLE.*offline_license' "$MIG_REV" || die "reverse SQL missing offline table rollback"

docker exec "$PG" pg_dump -U qflm -d "$DB" --format=custom --no-owner --no-privileges > "$DB_BACKUP"
[ -s "$DB_BACKUP" ] || die "database backup failed"

echo "database_backup=$DB_BACKUP"
echo "database_backup_sha256=$(sha256sum "$DB_BACKUP" | awk '{print $1}')"
echo "preflight=PASS"

cat > "$SIGN_COMPOSE" <<YAML
services:
  signing:
    image: qflm-signing:14c-candidate
    container_name: qflm-signing
    restart: unless-stopped
    user: app
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp:rw,noexec,nosuid,size=16m
    environment:
      ASPNETCORE_URLS: http://0.0.0.0:8080
      Signing__PrivateKeyPath: /run/qflm-signing/private.pem
      Signing__PublicKeyPath: /run/qflm-signing/public.pem
      Signing__TokenPath: /run/qflm-signing/token
      Signing__KeyIdPath: /run/qflm-signing/key-id
    volumes:
      - /opt/qflm/secrets/signing-runtime/private.pem:/run/qflm-signing/private.pem:ro
      - /opt/qflm/secrets/signing-runtime/public.pem:/run/qflm-signing/public.pem:ro
      - /opt/qflm/secrets/signing-runtime/token:/run/qflm-signing/token:ro
      - /opt/qflm/secrets/signing-runtime/key-id:/run/qflm-signing/key-id:ro
    networks:
      - qflm_backend

networks:
  qflm_backend:
    external: true
    name: qflm_backend
YAML
chmod 600 "$SIGN_COMPOSE"
docker compose -f "$SIGN_COMPOSE" config >/dev/null || die "signing compose invalid"

cat "$MIG_FWD" | docker exec -i "$PG" psql -U qflm -d "$DB" -v ON_ERROR_STOP=1 >/dev/null || die "production migration failed"
DB_MIGRATED=1

MIG2="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
OFFT2="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('offline_license_issuances','offline_license_audit_events');" | xargs)"
[ "$MIG2" = 3 ] || die "migration count did not reach 3"
[ "$OFFT2" = 2 ] || die "offline tables missing"

echo "production_migration=PASS"

docker compose -f "$SIGN_COMPOSE" up -d >/dev/null || die "signing service start failed"
SIGNING_STARTED=1
sleep 5

SIGNSEC="$(docker inspect "$SIGN_SERVICE" --format='user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .HostConfig.PortBindings}}')"
echo "$SIGNSEC" | grep -q 'user=app' || die "signing user invalid"
echo "$SIGNSEC" | grep -q 'readonly=true' || die "signing readonly missing"
echo "$SIGNSEC" | grep -q 'capdrop=\["ALL"\]' || die "signing capdrop missing"
echo "$SIGNSEC" | grep -q 'no-new-privileges:true' || die "signing NNP missing"
echo "$SIGNSEC" | grep -q 'ports={}' || die "signing host port exposed"

docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS "http://$SIGN_SERVICE:8080/health/ready" >/dev/null || die "signing health failed"

docker rm -f "$API" >/dev/null
docker run -d  --name "$API"  --restart unless-stopped  --network "$NET"  --read-only  --cap-drop ALL  --security-opt no-new-privileges:true  --tmpfs /tmp:rw,noexec,nosuid,size=32m  -e ASPNETCORE_URLS=http://+:8080  -v "$API_SECRET_DIR/postgres_password:/run/secrets/postgres_password:ro"  -v "$API_SECRET_DIR/redis_password:/run/secrets/redis_password:ro"  "$NEW_API_IMAGE" >/dev/null || die "new API container start failed"
API_REPLACED=1
sleep 6

APISEC="$(docker inspect "$API" --format='image={{.Config.Image}} running={{.State.Running}} restarts={{.RestartCount}} user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .HostConfig.PortBindings}}')"
echo "$APISEC"
echo "$APISEC" | grep -q "image=$NEW_API_IMAGE" || die "API image mismatch"
echo "$APISEC" | grep -q 'running=true' || die "API not running"
echo "$APISEC" | grep -q 'user=app' || die "API user invalid"
echo "$APISEC" | grep -q 'readonly=true' || die "API readonly missing"
echo "$APISEC" | grep -q 'capdrop=\["ALL"\]' || die "API capdrop missing"
echo "$APISEC" | grep -q 'no-new-privileges:true' || die "API NNP missing"
echo "$APISEC" | grep -q 'ports={}' || die "API host port exposed"

docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS "http://$API:8080/health/live" >/dev/null || die "API liveness failed"
docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS "http://$API:8080/health/ready" >/dev/null || die "API readiness failed"

CODE="$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' -X POST "http://$API:8080/api/v1/offline/issue")"
[ "$CODE" = 404 ] || [ "$CODE" = 405 ] || die "unexpected public offline issue endpoint: HTTP $CODE"

LIC2="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)"
INST2="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)"
ISS="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)"
AUD="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)"

[ "$LIC2" = "$LIC" ] || die "license count changed"
[ "$INST2" = "$INST" ] || die "installation count changed"
[ "$ISS" = 0 ] || die "offline issuance table not empty"
[ "$AUD" = 0 ] || die "offline audit table not empty"

COMPLETED=1

echo "======================================================"
echo " QFLM RECOVERY 5D2 PASSED"
echo "======================================================"
echo "OFFLINE PERSISTENCE MIGRATION:   PROMOTED"
echo "PRODUCTION MIGRATIONS:           3"
echo "OFFLINE TABLES:                  2 / EMPTY"
echo "INTERNAL SIGNING SERVICE:        PROMOTED"
echo "SIGNING HOST PORTS:              NONE"
echo "API IMAGE:                       $NEW_API_IMAGE"
echo "API HEALTH:                      PASS"
echo "SIGNING HEALTH:                  PASS"
echo "ONLINE LICENSE DATA:             UNCHANGED"
echo "PUBLIC OFFLINE ISSUE ENDPOINT:   NOT EXPOSED"
echo "DATABASE BACKUP:                 $DB_BACKUP"
echo "NEXT: RECOVERY 5E - OFFLINE ISSUANCE SERVICE INTEGRATION"
echo "======================================================"
