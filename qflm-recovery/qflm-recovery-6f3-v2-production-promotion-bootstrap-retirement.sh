#!/usr/bin/env bash
# QFLM RECOVERY 6F3
# Guarded production promotion of password/security-admin APIs
# + bootstrap credential retirement.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API_SRC="$ROOT/src/QFLM.Api"

PROD_API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"
ISO_DB="qflm_recovery6f3_test"
ISO_API="qflm-api-recovery6f3-test"
NET="qflm_backend"

OLD_IMAGE="qflm-api:recovery6e2-candidate"
NEW_IMAGE="qflm-api:recovery6f3-candidate"

COMPOSE="/opt/qflm/compose/compose.yml"
OVERRIDE="/opt/qflm/compose/auth-phase15e2b.override.yml"

AUTH_SECRET_DIR="/opt/qflm/secrets/auth"
BOOT_USER_FILE="$AUTH_SECRET_DIR/bootstrap-admin-username"
BOOT_PASS_FILE="$AUTH_SECRET_DIR/bootstrap-admin-password"
PLATFORM_USER_FILE="$AUTH_SECRET_DIR/platform-admin-username"
PLATFORM_PASS_FILE="$AUTH_SECRET_DIR/platform-admin-password"
RUNTIME_JWT="/opt/qflm/secrets/runtime-api/jwt-signing-key"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery6f3-$STAMP"
REPORT="$BACKUP/recovery6f3-report.txt"
SOURCE_BACKUP="$BACKUP/source-before-phase15f3.tgz"
COMPOSE_BACKUP="$BACKUP/compose.yml.before-phase15f3"
OVERRIDE_BACKUP="$BACKUP/auth-override.before-phase15f3"
DB_DUMP="$BACKUP/qflm-before-recovery6f3.dump"
ENV_FILE="$BACKUP/isolated-api.env"
PUBLISH="$ROOT/artifacts/api-publish-recovery6f3"
DOCKERFILE="$ROOT/Dockerfile.recovery6f3"

COMPLETED=0
PROMOTION_STARTED=0
SERVICE_NAME=""

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

rollback_api(){
    printf '\n=== GUARDED API ROLLBACK ===\n'
    docker rm -f "$PROD_API" >/dev/null 2>&1 || true
    docker run -d \
      --name "$PROD_API" \
      --restart unless-stopped \
      --network "$NET" \
      -e Jwt__SigningKeyFile=/run/secrets/jwt_signing_key \
      -e Jwt__Issuer=qflm \
      -e Jwt__Audience=qflm-admin \
      --mount type=bind,src=/opt/qflm/secrets/runtime-api/postgres_password,dst=/run/secrets/postgres_password,readonly \
      --mount type=bind,src=/opt/qflm/secrets/runtime-api/redis_password,dst=/run/secrets/redis_password,readonly \
      --mount type=bind,src="$RUNTIME_JWT",dst=/run/secrets/jwt_signing_key,readonly \
      --read-only --cap-drop ALL --security-opt no-new-privileges:true \
      --tmpfs /tmp:rw,noexec,nosuid,size=16m \
      "$OLD_IMAGE" >/dev/null 2>&1 || true
    printf '%s\n' "api_rollback_attempted=YES"
}

cleanup(){
    docker rm -f "$ISO_API" >/dev/null 2>&1 || true

    if [ "$COMPLETED" -ne 1 ] && [ "$PROMOTION_STARTED" -eq 1 ] && [ -n "$SERVICE_NAME" ]; then
        rollback_api
    fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 6F3"
printf '%s\n' " SECURITY ADMIN API PRODUCTION PROMOTION"
printf '%s\n' " + BOOTSTRAP PASSWORD RETIREMENT"
printf '%s\n' "======================================================"

printf '\n=== 1. PRODUCTION BASELINE ===\n'

[ -s "$COMPOSE" ] || die "main compose file missing"
[ -s "$BOOT_USER_FILE" ] || die "bootstrap username file missing"
[ -s "$BOOT_PASS_FILE" ] || die "bootstrap password file missing"
[ -s "$RUNTIME_JWT" ] || die "JWT runtime secret missing"

IMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
RUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
AUTH_TABLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name LIKE 'auth_%';" | xargs)
USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
LIC=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
INST=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'image=%s running=%s migrations=%s auth_tables=%s users=%s roles=%s permissions=%s licenses=%s installations=%s\n' \
  "$IMG" "$RUN" "$MIG" "$AUTH_TABLES" "$USERS" "$ROLES" "$PERMS" "$LIC" "$INST"

[ "$IMG" = "$OLD_IMAGE" ] || die "unexpected production API image"
[ "$RUN" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"
[ "$AUTH_TABLES" = 6 ] || die "unexpected auth table count"
[ "$USERS" = 1 ] || die "unexpected production user count"
[ "$ROLES" = 1 ] || die "unexpected production role count"
[ "$PERMS" -ge 22 ] || die "permission catalog incomplete"

printf '%s\n' "production_baseline=PASS"

printf '\n=== 2. VERIFY PHASE 15F SOURCE ===\n'

for f in \
  "$ROOT/src/QFLM.Application/Security/ChangePasswordCommand.cs" \
  "$ROOT/src/QFLM.Application/Security/IPasswordManagementService.cs" \
  "$ROOT/src/QFLM.Infrastructure/Security/EfPasswordManagementService.cs" \
  "$ROOT/src/QFLM.Application/Security/SecurityAdminModels.cs" \
  "$ROOT/src/QFLM.Application/Security/ISecurityAdministrationService.cs" \
  "$ROOT/src/QFLM.Infrastructure/Security/EfSecurityAdministrationService.cs" \
  "$API_SRC/Controllers/AdminSecurityManagementController.cs"
do
    [ -s "$f" ] || die "required Phase 15F source missing: $f"
done

grep -q 'HttpPost("change-password")' "$API_SRC/Controllers/AuthController.cs" \
  || die "change-password route missing"

grep -q 'EfPasswordManagementService' "$API_SRC/Program.cs" \
  || die "password management DI missing"

grep -q 'EfSecurityAdministrationService' "$API_SRC/Program.cs" \
  || die "security administration DI missing"

printf '%s\n' "phase15f_source=PASS"

printf '\n=== 3. BACKUP SOURCE / DATABASE + STANDALONE API CONTRACT ===\n'

SERVICE_NAME="qflm-api"
printf '%s\n' "api_runtime=STANDALONE_DOCKER"

tar -czf "$SOURCE_BACKUP" -C "$ROOT" "src/QFLM.Api" \
  || die "API source backup failed"

cp -a "$COMPOSE" "$COMPOSE_BACKUP" \
  || die "compose backup failed"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" -Fc > "$DB_DUMP" \
  || die "production DB backup failed"

[ -s "$DB_DUMP" ] || die "production DB backup empty"

printf 'source_backup_sha256=%s\n' "$(sha256sum "$SOURCE_BACKUP" | awk '{print $1}')"
printf 'compose_backup_sha256=%s\n' "$(sha256sum "$COMPOSE_BACKUP" | awk '{print $1}')"
printf 'database_backup_sha256=%s\n' "$(sha256sum "$DB_DUMP" | awk '{print $1}')"
printf '%s\n' "standalone_api_contract=PASS"

printf '\n=== 4. RELEASE BUILD ===\n'

dotnet build QuikeFix.LicenseManager.slnx -c Release \
  || die "Phase 15F.3 source build failed"

printf '%s\n' "release_build=PASS"

printf '\n=== 5. PUBLISH + BUILD CANDIDATE IMAGE ===\n'

rm -rf "$PUBLISH"

dotnet publish "$API_SRC/QFLM.Api.csproj" -c Release -o "$PUBLISH" \
  || die "API publish failed"

cat > "$DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-recovery6f3/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER

docker build -f "$DOCKERFILE" -t "$NEW_IMAGE" . \
  || die "candidate image build failed"

NEW_IMAGE_ID=$(docker image inspect "$NEW_IMAGE" --format='{{.Id}}')

printf 'candidate_image=%s\n' "$NEW_IMAGE"
printf 'candidate_image_id=%s\n' "$NEW_IMAGE_ID"

printf '\n=== 6. BUILD ISOLATED PRODUCTION CLONE ===\n'

docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1 \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" \
  >/dev/null

docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB"
docker exec "$PG" createdb -U qflm "$ISO_DB" \
  || die "isolated database create failed"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges \
  | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null \
  || die "isolated production clone failed"

ISO_MIG=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
ISO_AUTH=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name LIKE 'auth_%';" | xargs)

[ "$ISO_MIG" = 5 ] || die "isolated migration count mismatch"
[ "$ISO_AUTH" = 6 ] || die "isolated auth table count mismatch"

printf 'isolated_migrations=%s auth_tables=%s\n' "$ISO_MIG" "$ISO_AUTH"

printf '\n=== 7. PREPARE ISOLATED ENVIRONMENT ===\n'

docker inspect "$PROD_API" \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  > "$ENV_FILE" \
  || die "capture production environment failed"

chmod 600 "$ENV_FILE"

cat >> "$ENV_FILE" <<EOF
Qflm__PostgreSqlDatabase=$ISO_DB
PostgreSqlDatabase=$ISO_DB
EOF
chmod 600 "$ENV_FILE"

printf '%s\n' "isolated_environment=PASS"

printf '\n=== 8. START ISOLATED CANDIDATE ===\n'

docker rm -f "$ISO_API" >/dev/null 2>&1 || true

docker run -d \
  --name "$ISO_API" \
  --network "$NET" \
  --env-file "$ENV_FILE" \
  --volumes-from "$PROD_API:ro" \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  "$NEW_IMAGE" >/dev/null \
  || die "isolated candidate start failed"

sleep 5

docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -fsS "http://$ISO_API:8080/health/ready" >/dev/null \
  || {
      docker logs --tail 150 "$ISO_API" || true
      die "isolated candidate readiness failed"
  }

printf '%s\n' "isolated_candidate_health=PASS"

printf '\n=== 9. ISOLATED AUTH + SECURITY ADMIN SMOKE ===\n'

BOOT_USER="$(cat "$BOOT_USER_FILE")"
BOOT_PASS="$(cat "$BOOT_PASS_FILE")"

LOGIN_JSON=$(python3 - "$BOOT_USER" "$BOOT_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)

LOGIN=$(printf '%s' "$LOGIN_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -fsS -H 'Content-Type: application/json' \
      -X POST "http://$ISO_API:8080/api/v1/auth/login" \
      --data-binary @-) \
  || die "isolated login failed"

TOKEN=$(python3 - "$LOGIN" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["accessToken"])
PY
)

[ -n "$TOKEN" ] || die "isolated token missing"

USERS_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" \
  "http://$ISO_API:8080/api/v1/admin/security/users")

ROLES_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" \
  "http://$ISO_API:8080/api/v1/admin/security/roles")

PERMS_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" \
  "http://$ISO_API:8080/api/v1/admin/security/permissions")

[ "$USERS_HTTP" = 200 ] || die "isolated users list failed"
[ "$ROLES_HTTP" = 200 ] || die "isolated roles list failed"
[ "$PERMS_HTTP" = 200 ] || die "isolated permissions list failed"

printf 'isolated_security_admin=PASS users=%s roles=%s permissions=%s\n' \
  "$USERS_HTTP" "$ROLES_HTTP" "$PERMS_HTTP"

unset TOKEN LOGIN LOGIN_JSON

printf '\n=== 10. VALIDATE STANDALONE PRODUCTION CONTRACT ===\n'

for f in \
  /opt/qflm/secrets/runtime-api/postgres_password \
  /opt/qflm/secrets/runtime-api/redis_password \
  "$RUNTIME_JWT"
do
  [ -s "$f" ] || die "required runtime secret missing: $f"
done

printf '%s\n' "standalone_runtime_secrets=PASS"

printf '\n=== 11. GUARDED STANDALONE PRODUCTION API PROMOTION ===\n'

PROMOTION_STARTED=1

docker rm -f "$PROD_API" >/dev/null 2>&1 || true

docker run -d \
  --name "$PROD_API" \
  --restart unless-stopped \
  --network "$NET" \
  -e Jwt__SigningKeyFile=/run/secrets/jwt_signing_key \
  -e Jwt__Issuer=qflm \
  -e Jwt__Audience=qflm-admin \
  --mount type=bind,src=/opt/qflm/secrets/runtime-api/postgres_password,dst=/run/secrets/postgres_password,readonly \
  --mount type=bind,src=/opt/qflm/secrets/runtime-api/redis_password,dst=/run/secrets/redis_password,readonly \
  --mount type=bind,src="$RUNTIME_JWT",dst=/run/secrets/jwt_signing_key,readonly \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  "$NEW_IMAGE" >/dev/null \
  || die "production API promotion failed"

sleep 6

PIMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
PRUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PSEC=$(docker inspect "$PROD_API" --format='user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .HostConfig.PortBindings}} restart={{.HostConfig.RestartPolicy.Name}}')

printf 'image=%s running=%s\n' "$PIMAGE" "$PRUN"
printf '%s\n' "$PSEC"

[ "$PIMAGE" = "$NEW_IMAGE" ] || die "production API image did not promote"
[ "$PRUN" = true ] || die "production API not running after promotion"
printf '%s' "$PSEC" | grep -q 'user=app' || die "production user is not app"
printf '%s' "$PSEC" | grep -q 'readonly=true' || die "production rootfs not readonly"
printf '%s' "$PSEC" | grep -q 'capdrop=\["ALL"\]' || die "production cap drop missing"
printf '%s' "$PSEC" | grep -q 'no-new-privileges:true' || die "production NNP missing"
printf '%s' "$PSEC" | grep -q 'ports={}' || die "production exposes host ports"
printf '%s' "$PSEC" | grep -q 'restart=unless-stopped' || die "production restart policy mismatch"

docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -fsS "http://$PROD_API:8080/health/ready" >/dev/null \
  || { docker logs --tail 180 "$PROD_API" || true; die "production readiness failed"; }

printf '%s\n' "production_health=PASS"

printf '\n=== 12. PRODUCTION SECURITY ADMIN SMOKE ===\n'

BOOT_PASS="$(cat "$BOOT_PASS_FILE")"

PROD_LOGIN_JSON=$(python3 - "$BOOT_USER" "$BOOT_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)

PROD_LOGIN=$(printf '%s' "$PROD_LOGIN_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -fsS -H 'Content-Type: application/json' \
      -X POST "http://$PROD_API:8080/api/v1/auth/login" \
      --data-binary @-) \
  || die "production login failed"

PROD_TOKEN=$(python3 - "$PROD_LOGIN" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["accessToken"])
PY
)

PROD_REFRESH=$(python3 - "$PROD_LOGIN" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["refreshToken"])
PY
)

[ -n "$PROD_TOKEN" ] || die "production token missing"
[ -n "$PROD_REFRESH" ] || die "production refresh token missing"

PROD_USERS_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $PROD_TOKEN" \
  "http://$PROD_API:8080/api/v1/admin/security/users")

PROD_ROLES_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $PROD_TOKEN" \
  "http://$PROD_API:8080/api/v1/admin/security/roles")

[ "$PROD_USERS_HTTP" = 200 ] || die "production users list failed"
[ "$PROD_ROLES_HTTP" = 200 ] || die "production roles list failed"

printf 'production_security_admin=PASS users=%s roles=%s\n' \
  "$PROD_USERS_HTTP" "$PROD_ROLES_HTTP"

printf '\n=== 13. CREATE PERMANENT PLATFORM ADMIN PASSWORD ===\n'

if [ -e "$PLATFORM_PASS_FILE" ]; then
    die "platform admin password file already exists; refusing overwrite"
fi

PLATFORM_PASS="$(openssl rand -base64 36 | tr -d '\n')Aa9!"

printf '%s\n' "$BOOT_USER" > "$PLATFORM_USER_FILE"
printf '%s\n' "$PLATFORM_PASS" > "$PLATFORM_PASS_FILE"

chown root:root "$PLATFORM_USER_FILE" "$PLATFORM_PASS_FILE"
chmod 600 "$PLATFORM_USER_FILE" "$PLATFORM_PASS_FILE"

printf 'platform_admin_username_file=%s\n' "$PLATFORM_USER_FILE"
printf 'platform_admin_password_file=%s\n' "$PLATFORM_PASS_FILE"
printf '%s\n' "platform_admin_password_displayed=NO"

printf '\n=== 14. CHANGE PRODUCTION ADMIN PASSWORD ===\n'

CHANGE_JSON=$(python3 - "$BOOT_PASS" "$PLATFORM_PASS" <<'PY'
import json,sys
print(json.dumps({
  "currentPassword":sys.argv[1],
  "newPassword":sys.argv[2]
}))
PY
)

CHANGE_HTTP=$(printf '%s' "$CHANGE_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $PROD_TOKEN" \
      -X POST "http://$PROD_API:8080/api/v1/auth/change-password" \
      --data-binary @-)

printf 'change_password_http=%s\n' "$CHANGE_HTTP"

[ "$CHANGE_HTTP" = 204 ] || die "production password change failed"

printf '%s\n' "production_password_change=PASS"

printf '\n=== 15. VERIFY BOOTSTRAP PASSWORD RETIRED ===\n'

OLD_LOGIN_HTTP=$(printf '%s' "$PROD_LOGIN_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -X POST "http://$PROD_API:8080/api/v1/auth/login" \
      --data-binary @-)

printf 'old_bootstrap_login_http=%s\n' "$OLD_LOGIN_HTTP"

[ "$OLD_LOGIN_HTTP" = 401 ] || die "old bootstrap password still works"

NEW_LOGIN_JSON=$(python3 - "$BOOT_USER" "$PLATFORM_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)

NEW_LOGIN=$(printf '%s' "$NEW_LOGIN_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -fsS -H 'Content-Type: application/json' \
      -X POST "http://$PROD_API:8080/api/v1/auth/login" \
      --data-binary @-) \
  || die "permanent platform admin login failed"

NEW_TOKEN=$(python3 - "$NEW_LOGIN" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["accessToken"])
PY
)

NEW_REFRESH=$(python3 - "$NEW_LOGIN" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["refreshToken"])
PY
)

[ -n "$NEW_TOKEN" ] || die "new platform admin token missing"
[ -n "$NEW_REFRESH" ] || die "new platform admin refresh token missing"

ME_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $NEW_TOKEN" \
  "http://$PROD_API:8080/api/v1/auth/me")

ADMIN_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $NEW_TOKEN" \
  "http://$PROD_API:8080/api/v1/admin/security/users")

[ "$ME_HTTP" = 200 ] || die "new platform admin /me failed"
[ "$ADMIN_HTTP" = 200 ] || die "new platform admin security access failed"

printf 'permanent_admin_login=PASS me_http=%s security_admin_http=%s\n' \
  "$ME_HTTP" "$ADMIN_HTTP"

printf '\n=== 16. REVOKE FINAL TEST REFRESH TOKEN ===\n'

REVOKE_JSON=$(python3 - "$NEW_REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)

REVOKE_HTTP=$(printf '%s' "$REVOKE_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $NEW_TOKEN" \
      -X POST "http://$PROD_API:8080/api/v1/auth/revoke" \
      --data-binary @-)

printf 'final_refresh_revoke_http=%s\n' "$REVOKE_HTTP"

[ "$REVOKE_HTTP" = 204 ] || die "final refresh revoke failed"

printf '%s\n' "final_refresh_revoked=PASS"

unset PLATFORM_PASS BOOT_PASS PROD_TOKEN PROD_REFRESH NEW_TOKEN NEW_REFRESH
unset PROD_LOGIN_JSON PROD_LOGIN CHANGE_JSON NEW_LOGIN_JSON NEW_LOGIN REVOKE_JSON

printf '\n=== 17. REMOVE BOOTSTRAP SECRET FILES ===\n'

rm -f "$BOOT_PASS_FILE" "$BOOT_USER_FILE"

[ ! -e "$BOOT_PASS_FILE" ] || die "bootstrap password file still exists"
[ ! -e "$BOOT_USER_FILE" ] || die "bootstrap username file still exists"

[ -s "$PLATFORM_PASS_FILE" ] || die "platform admin password file missing"
[ -s "$PLATFORM_USER_FILE" ] || die "platform admin username file missing"

printf '%s\n' "bootstrap_secret_files_removed=PASS"
printf '%s\n' "permanent_platform_admin_secret=PASS"

printf '\n=== 18. FINAL PRODUCTION STATE ===\n'

FINAL_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
FINAL_LIC=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_INST=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
ACTIVE_REFRESH=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_refresh_tokens WHERE revoked_at_utc IS NULL;' | xargs)

printf 'image=%s running=%s migrations=%s users=%s roles=%s permissions=%s licenses=%s installations=%s active_refresh=%s\n' \
  "$FINAL_IMAGE" "$FINAL_RUN" "$FINAL_MIG" "$FINAL_USERS" "$FINAL_ROLES" "$FINAL_PERMS" "$FINAL_LIC" "$FINAL_INST" "$ACTIVE_REFRESH"

[ "$FINAL_IMAGE" = "$NEW_IMAGE" ] || die "final production image mismatch"
[ "$FINAL_RUN" = true ] || die "production API stopped"
[ "$FINAL_MIG" = 5 ] || die "final migration count mismatch"
[ "$FINAL_USERS" = "$USERS" ] || die "production user count changed"
[ "$FINAL_ROLES" = "$ROLES" ] || die "production role count changed"
[ "$FINAL_PERMS" = "$PERMS" ] || die "production permission count changed"
[ "$FINAL_LIC" = "$LIC" ] || die "production license count changed"
[ "$FINAL_INST" = "$INST" ] || die "production installation count changed"
[ "$ACTIVE_REFRESH" = 0 ] || die "active refresh token remains after final revoke"

printf '%s\n' "final_production_state=PASS"
printf '%s\n' "external_exposure=UNCHANGED"

COMPLETED=1

printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 6F3 PASSED"
printf '%s\n' "======================================================"
printf '%s\n' "PASSWORD CHANGE API:                 PROMOTED"
printf '%s\n' "SECURITY ADMIN API:                  PROMOTED"
printf '%s\n' "USERS / ROLES / PERMISSIONS API:     PROMOTED"
printf '%s\n' "PLATFORM ADMIN PASSWORD:             ROTATED"
printf '%s\n' "BOOTSTRAP PASSWORD:                  RETIRED"
printf '%s\n' "BOOTSTRAP SECRET FILES:              REMOVED"
printf '%s\n' "ACTIVE TEST REFRESH TOKENS:          0"
printf '%s\n' "PRODUCTION DB MIGRATIONS:            5"
printf '%s\n' "LICENSING DATA:                      UNCHANGED"
printf '%s\n' "EXTERNAL EXPOSURE:                   UNCHANGED"
printf 'PRODUCTION IMAGE:                    %s\n' "$NEW_IMAGE"
printf 'PRODUCTION IMAGE ID:                 %s\n' "$NEW_IMAGE_ID"
printf 'PLATFORM ADMIN USERNAME FILE:        %s\n' "$PLATFORM_USER_FILE"
printf 'PLATFORM ADMIN PASSWORD FILE:        %s\n' "$PLATFORM_PASS_FILE"
printf 'DB BACKUP:                           %s\n' "$DB_DUMP"
printf 'REPORT:                              %s\n' "$REPORT"
printf '%s\n' "NEXT: RECOVERY 7 - FULL ADMIN GUI FOUNDATION"
printf '%s\n' "======================================================"
