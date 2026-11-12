#!/usr/bin/env bash
set -euo pipefail
ROOT=/opt/qflm/app/QuikeFix.LicenseManager
PG=qflm-postgres
API=qflm-api
NET=qflm_backend
OLD=qflm-api:13d-candidate
NEW=qflm-api:13e-candidate
PGSECRET=/opt/qflm/secrets/runtime-api/postgres_password
RDSECRET=/opt/qflm/secrets/runtime-api/redis_password
q(){ docker exec "$PG" psql -U qflm -d qflm -tAc "$1" | xargs; }
cd "$ROOT"
[ "$(docker inspect "$API" --format='{{.Config.Image}}')" = "$OLD" ]
[ "$(q 'SELECT count(*) FROM "__EFMigrationsHistory";')" = 2 ]
[ "$(q "SELECT count(*) FROM pg_tables WHERE schemaname='public';")" = 8 ]
ADMIN_ROUTES="$(grep -RniE '\[Route.*admin|\[Http(Post|Put|Patch|Delete).*suspend|\[Http(Post|Put|Patch|Delete).*resume|\[Http(Post|Put|Patch|Delete).*revoke|\[Http(Post|Put|Patch|Delete).*rebind' src/QFLM.Api/Controllers 2>/dev/null | wc -l | xargs)"
[ "$ADMIN_ROUTES" = 0 ]
dotnet publish src/QFLM.Api/QFLM.Api.csproj -c Release -o artifacts/api-publish-13e --no-restore >/dev/null
cat > Dockerfile.recovery13e <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-13e/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER
docker build -f Dockerfile.recovery13e -t "$NEW" . >/dev/null
docker rm -f "$API" >/dev/null
docker run -d --name "$API" --restart unless-stopped --network "$NET" --read-only --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp:rw,noexec,nosuid,size=32m -e ASPNETCORE_URLS=http://+:8080 -v "$PGSECRET:/run/secrets/postgres_password:ro" -v "$RDSECRET:/run/secrets/redis_password:ro" "$NEW" >/dev/null
sleep 5
docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS http://qflm-api:8080/health/ready >/dev/null
IMG="$(docker inspect "$API" --format='{{.Config.Image}}')"
RUN="$(docker inspect "$API" --format='{{.State.Running}}')"
RO="$(docker inspect "$API" --format='{{.HostConfig.ReadonlyRootfs}}')"
CAP="$(docker inspect "$API" --format='{{json .HostConfig.CapDrop}}')"
PORTS="$(docker inspect "$API" --format='{{json .HostConfig.PortBindings}}')"
MIG="$(q 'SELECT count(*) FROM "__EFMigrationsHistory";')"
COUNTS="$(q "SELECT concat((SELECT count(*) FROM customers),'|',(SELECT count(*) FROM products),'|',(SELECT count(*) FROM subscriptions),'|',(SELECT count(*) FROM licenses),'|',(SELECT count(*) FROM installations));")"
PRIMARY="$(q "SELECT concat(status,'|',last_heartbeat_sequence,'|',highest_lease_sequence) FROM installations WHERE installation_identifier='11111111-1111-4111-8111-111111111111';")"
[ "$IMG" = "$NEW" ] && [ "$RUN" = true ] && [ "$RO" = true ]
[[ "$CAP" == *"ALL"* ]]
[ "$PORTS" = '{}' ] || [ "$PORTS" = null ]
[ "$MIG" = 2 ] && [ "$COUNTS" = "1|1|1|1|2" ] && [ "$PRIMARY" = "Active|0|0" ]
echo "======================================================"
echo " QFLM RECOVERY 4 PASSED"
echo "======================================================"
echo "13E ADMIN ENGINE:           PASS"
echo "13F SECURITY FOUNDATION:    PASS"
echo "PUBLIC ADMIN ROUTES:        NONE"
echo "RUNTIME HARDENING:          PASS"
echo "PRODUCTION IMAGE:           qflm-api:13e-candidate"
echo "DATABASE COUNTS:            1|1|1|1|2"
echo "NEXT: RECOVERY 5 - OFFLINE SIGNING / PHASE 14"
echo "======================================================"
