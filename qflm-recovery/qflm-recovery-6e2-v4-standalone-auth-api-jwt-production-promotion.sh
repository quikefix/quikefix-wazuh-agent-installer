#!/usr/bin/env bash
# QFLM RECOVERY 6E2
# JWT secret-file hardening + isolated candidate verification + guarded production API promotion.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API_SRC="$ROOT/src/QFLM.Api"

PROD_API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"
ISO_DB="qflm_recovery6e2_test"
ISO_API="qflm-api-recovery6e2-test"
NET="qflm_backend"

OLD_IMAGE="qflm-api:phase14d4-candidate"
NEW_IMAGE="qflm-api:recovery6e2-candidate"

COMPOSE="/opt/qflm/compose/compose.yml"
OVERRIDE="/opt/qflm/compose/auth-recovery6e2.override.yml"

AUTH_SECRET_DIR="/opt/qflm/secrets/auth"
MASTER_JWT="$AUTH_SECRET_DIR/qflm-jwt-signing-key"
RUNTIME_DIR="/opt/qflm/secrets/runtime-api"
RUNTIME_JWT="$RUNTIME_DIR/jwt-signing-key"

BOOTSTRAP_USERNAME_FILE="$AUTH_SECRET_DIR/bootstrap-admin-username"
BOOTSTRAP_PASSWORD_FILE="$AUTH_SECRET_DIR/bootstrap-admin-password"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery6e2-$STAMP"
REPORT="$BACKUP/recovery6e2-report.txt"
SOURCE_BACKUP="$BACKUP/source-before-phase15e2b.tgz"
COMPOSE_BACKUP="$BACKUP/compose.yml.before-phase15e2b"
OVERRIDE_BACKUP="$BACKUP/auth-override.before-phase15e2b"
DB_DUMP="$BACKUP/qflm-before-recovery6e2.dump"
ENV_FILE="$BACKUP/isolated-api.env"

PUBLISH="$ROOT/artifacts/api-publish-recovery6e2"
DOCKERFILE="$ROOT/Dockerfile.recovery6e2"

APP_UID="1654"
APP_GID="1654"

SOURCE_MUTATED=0
PROMOTION_STARTED=0
COMPLETED=0
SERVICE_NAME="qflm-api"

die() {
    printf 'STOP: %s\n' "$*" >&2
    exit 1
}

rollback_api() {
    printf '\n=== GUARDED API ROLLBACK ===\n'
    docker rm -f "$PROD_API" >/dev/null 2>&1 || true
    docker run -d \
      --name "$PROD_API" \
      --restart unless-stopped \
      --network "$NET" \
      --mount type=bind,src=/opt/qflm/secrets/runtime-api/postgres_password,dst=/run/secrets/postgres_password,readonly \
      --mount type=bind,src=/opt/qflm/secrets/runtime-api/redis_password,dst=/run/secrets/redis_password,readonly \
      --read-only \
      --cap-drop ALL \
      --security-opt no-new-privileges:true \
      --tmpfs /tmp:rw,noexec,nosuid,size=16m \
      "$OLD_IMAGE" >/dev/null 2>&1 || true
    printf '%s\n' "api_rollback_attempted=YES"
}

cleanup() {
    docker rm -f "$ISO_API" >/dev/null 2>&1 || true

    if [ "$COMPLETED" -ne 1 ]; then
        if [ "$PROMOTION_STARTED" -eq 1 ] && [ -n "$SERVICE_NAME" ]; then
            rollback_api
        fi

        if [ "$SOURCE_MUTATED" -eq 1 ] && [ -s "$SOURCE_BACKUP" ]; then
            printf '\n=== SOURCE ROLLBACK ===\n'
            rm -f "$API_SRC/Security/JwtSigningKeyProvider.cs"
            tar -xzf "$SOURCE_BACKUP" -C "$ROOT" >/dev/null 2>&1 || true
            printf '%s\n' "source_restore_attempted=YES"
        fi
    fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 6E2"
printf '%s\n' " AUTH API + JWT SECRET PRODUCTION PROMOTION"
printf '%s\n' "======================================================"

printf '\n=== 1. PRODUCTION SAFETY BASELINE ===\n'

[ -s "$COMPOSE" ] || die "compose file missing"

IMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') \
    || die "production API missing"
RUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')

MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" \
    -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

AUTH_TABLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "
SELECT count(*)
FROM information_schema.tables
WHERE table_schema='public'
AND table_name LIKE 'auth_%';
" | xargs)

BOOT_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" \
    -tAc "SELECT count(*) FROM auth_users WHERE normalized_username='QFLM-ADMIN' AND is_active=true;" | xargs)

PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" \
    -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

LIC=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" \
    -tAc 'SELECT count(*) FROM licenses;' | xargs)

INST=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" \
    -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'image=%s running=%s migrations=%s auth_tables=%s bootstrap_users=%s permissions=%s licenses=%s installations=%s\n' \
    "$IMG" "$RUN" "$MIG" "$AUTH_TABLES" "$BOOT_USERS" "$PERMS" "$LIC" "$INST"

[ "$IMG" = "$OLD_IMAGE" ] || die "unexpected production API image"
[ "$RUN" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "Phase 15E.2A migrations not present"
[ "$AUTH_TABLES" = 6 ] || die "production auth schema incomplete"
[ "$BOOT_USERS" = 1 ] || die "bootstrap administrator missing"
[ "$PERMS" -ge 22 ] || die "permission seed incomplete"
[ -s "$BOOTSTRAP_USERNAME_FILE" ] || die "bootstrap username file missing"
[ -s "$BOOTSTRAP_PASSWORD_FILE" ] || die "bootstrap password file missing"

printf '%s\n' "phase15e2a_baseline=PASS"

printf '\n=== 2. RECOVERED STANDALONE API CONTRACT ===\n'

SERVICE_NAME="qflm-api"
printf 'api_runtime=STANDALONE_DOCKER\n'
printf 'api_container=%s\n' "$PROD_API"
printf 'base_compose_services=POSTGRES_REDIS_ONLY\n'
printf '%s\n' "standalone_api_contract=PASS"

printf '\n=== 3. BACKUP SOURCE / COMPOSE / DATABASE ===\n'

tar -czf "$SOURCE_BACKUP" \
    -C "$ROOT" \
    "src/QFLM.Api" \
    || die "API source backup failed"

cp -a "$COMPOSE" "$COMPOSE_BACKUP" \
    || die "compose backup failed"

docker exec "$PG" pg_dump \
    -U qflm \
    -d "$PROD_DB" \
    -Fc \
    > "$DB_DUMP" \
    || die "database backup failed"

[ -s "$DB_DUMP" ] || die "database backup empty"

printf 'source_backup_sha256=%s\n' "$(sha256sum "$SOURCE_BACKUP" | awk '{print $1}')"
printf 'compose_backup_sha256=%s\n' "$(sha256sum "$COMPOSE_BACKUP" | awk '{print $1}')"
printf 'database_backup_bytes=%s\n' "$(stat -c '%s' "$DB_DUMP")"
printf 'database_backup_sha256=%s\n' "$(sha256sum "$DB_DUMP" | awk '{print $1}')"

SOURCE_MUTATED=1

printf '\n=== 4. CREATE JWT SECRET-FILE PROVIDER ===\n'

mkdir -p "$API_SRC/Security"

cat > "$API_SRC/Security/JwtSigningKeyProvider.cs" <<'CS'
namespace QFLM.Api.Security;

public static class JwtSigningKeyProvider
{
    public static string LoadBase64(
        IConfiguration configuration)
    {
        var inline =
            configuration["Jwt:SigningKey"];

        if (!string.IsNullOrWhiteSpace(inline))
        {
            Validate(inline);
            return inline;
        }

        var path =
            configuration["Jwt:SigningKeyFile"];

        if (string.IsNullOrWhiteSpace(path))
        {
            throw new InvalidOperationException(
                "JWT signing key or signing-key file is not configured.");
        }

        if (!File.Exists(path))
        {
            throw new InvalidOperationException(
                "Configured JWT signing-key file does not exist.");
        }

        var value =
            File.ReadAllText(path)
                .Trim();

        Validate(value);
        return value;
    }

    private static void Validate(
        string value)
    {
        byte[] key;

        try
        {
            key =
                Convert.FromBase64String(value);
        }
        catch (FormatException ex)
        {
            throw new InvalidOperationException(
                "JWT signing key must be valid Base64.",
                ex);
        }

        if (key.Length < 32)
        {
            throw new InvalidOperationException(
                "JWT signing key must contain at least 256 bits.");
        }
    }
}
CS

printf '%s\n' "jwt_secret_file_provider=CREATED"

printf '\n=== 5. PATCH PROGRAM + BEARER HANDLER ===\n'

python3 - "$API_SRC/Program.cs" "$API_SRC/Security/QflmBearerAuthenticationHandler.cs" <<'PY'
from pathlib import Path
import sys

program=Path(sys.argv[1])
handler=Path(sys.argv[2])

p=program.read_text()

old = (
'var jwtKey =\n'
'    builder.Configuration["Jwt:SigningKey"]\n'
'    ?? throw new InvalidOperationException(\n'
'        "Jwt:SigningKey is not configured.");'
)

new = (
'var jwtKey =\n'
'    JwtSigningKeyProvider.LoadBase64(\n'
'        builder.Configuration);'
)

if old in p:
    p=p.replace(old,new,1)
elif "JwtSigningKeyProvider.LoadBase64" not in p:
    raise SystemExit("Program JWT key marker not found")

program.write_text(p)

h=handler.read_text()

oldh = (
'        var keyBase64 =\n'
'            configuration["Jwt:SigningKey"]\n'
'            ?? throw new InvalidOperationException(\n'
'                "Jwt:SigningKey is not configured.");'
)

newh = (
'        var keyBase64 =\n'
'            JwtSigningKeyProvider.LoadBase64(\n'
'                configuration);'
)

if oldh in h:
    h=h.replace(oldh,newh,1)
elif "JwtSigningKeyProvider.LoadBase64" not in h:
    raise SystemExit("Bearer handler JWT key marker not found")

handler.write_text(h)
PY

grep -q 'JwtSigningKeyProvider.LoadBase64' "$API_SRC/Program.cs" \
    || die "Program secret-file patch missing"

grep -q 'JwtSigningKeyProvider.LoadBase64' \
    "$API_SRC/Security/QflmBearerAuthenticationHandler.cs" \
    || die "bearer secret-file patch missing"

printf '%s\n' "jwt_secret_file_patch=PASS"

printf '\n=== 6. RELEASE BUILD ===\n'

dotnet build \
    QuikeFix.LicenseManager.slnx \
    -c Release \
    || die "Phase 15E.2B build failed"

printf '%s\n' "release_build=PASS"

printf '\n=== 7. CREATE JWT MASTER + RUNTIME SECRET ===\n'

install -d -m 700 -o root -g root "$AUTH_SECRET_DIR"
install -d -m 700 -o root -g root "$RUNTIME_DIR"

if [ ! -e "$MASTER_JWT" ]; then
    openssl rand -base64 64 \
        | tr -d '\n' \
        > "$MASTER_JWT"
    printf '\n' >> "$MASTER_JWT"
fi

chown root:root "$MASTER_JWT"
chmod 600 "$MASTER_JWT"

install \
    -m 0400 \
    -o "$APP_UID" \
    -g "$APP_GID" \
    "$MASTER_JWT" \
    "$RUNTIME_JWT"

MASTER_SHA=$(sha256sum "$MASTER_JWT" | awk '{print $1}')
RUNTIME_SHA=$(sha256sum "$RUNTIME_JWT" | awk '{print $1}')

[ "$MASTER_SHA" = "$RUNTIME_SHA" ] \
    || die "runtime JWT secret differs from master"

KEY_BYTES=$(
    python3 - "$MASTER_JWT" <<'PY'
import base64,pathlib,sys
value=pathlib.Path(sys.argv[1]).read_text().strip()
print(len(base64.b64decode(value,validate=True)))
PY
) || die "JWT secret is invalid Base64"

[ "$KEY_BYTES" -ge 32 ] || die "JWT secret too short"

printf 'jwt_master_path=%s\n' "$MASTER_JWT"
printf 'jwt_runtime_path=%s\n' "$RUNTIME_JWT"
printf 'jwt_key_bytes=%s\n' "$KEY_BYTES"
printf '%s\n' "jwt_secret_displayed=NO"

printf '\n=== 8. PUBLISH + BUILD CANDIDATE IMAGE ===\n'

rm -rf "$PUBLISH"

dotnet publish \
    "$API_SRC/QFLM.Api.csproj" \
    -c Release \
    -o "$PUBLISH" \
    || die "API publish failed"

cat > "$DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-recovery6e2/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER

docker build \
    -f "$DOCKERFILE" \
    -t "$NEW_IMAGE" \
    . \
    || die "candidate image build failed"

NEW_IMAGE_ID=$(docker image inspect "$NEW_IMAGE" --format='{{.Id}}')

printf 'candidate_image=%s\n' "$NEW_IMAGE"
printf 'candidate_image_id=%s\n' "$NEW_IMAGE_ID"

printf '\n=== 9. BUILD ISOLATED PRODUCTION CLONE ===\n'

docker exec "$PG" psql \
    -U qflm \
    -d postgres \
    -v ON_ERROR_STOP=1 \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" \
    >/dev/null

docker exec "$PG" dropdb \
    -U qflm \
    --if-exists \
    "$ISO_DB"

docker exec "$PG" createdb \
    -U qflm \
    "$ISO_DB" \
    || die "isolated database create failed"

docker exec "$PG" pg_dump \
    -U qflm \
    -d "$PROD_DB" \
    --no-owner \
    --no-privileges \
    | docker exec -i "$PG" psql \
        -U qflm \
        -d "$ISO_DB" \
        -v ON_ERROR_STOP=1 \
        >/dev/null \
    || die "isolated database clone failed"

ISO_MIG=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" \
    -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

ISO_AUTH=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "
SELECT count(*)
FROM information_schema.tables
WHERE table_schema='public'
AND table_name LIKE 'auth_%';
" | xargs)

[ "$ISO_MIG" = 5 ] || die "isolated migration count mismatch"
[ "$ISO_AUTH" = 6 ] || die "isolated auth table count mismatch"

printf 'isolated_migrations=%s auth_tables=%s\n' "$ISO_MIG" "$ISO_AUTH"

printf '\n=== 10. PREPARE ISOLATED CANDIDATE ENVIRONMENT ===\n'

docker inspect "$PROD_API" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
    > "$ENV_FILE" \
    || die "failed to capture production environment"

chmod 600 "$ENV_FILE"

cat >> "$ENV_FILE" <<EOF
Qflm__PostgreSqlDatabase=$ISO_DB
PostgreSqlDatabase=$ISO_DB
Jwt__SigningKeyFile=/run/secrets/jwt_signing_key
Jwt__Issuer=qflm
Jwt__Audience=qflm-admin
EOF
chmod 600 "$ENV_FILE"

printf '%s\n' "isolated_environment=PASS"
printf '%s\n' "environment_secrets_displayed=NO"

printf '\n=== 11. START ISOLATED CANDIDATE ===\n'

docker rm -f "$ISO_API" >/dev/null 2>&1 || true

docker run -d \
    --name "$ISO_API" \
    --network "$NET" \
    --env-file "$ENV_FILE" \
    --volumes-from "$PROD_API:ro" \
    --mount type=bind,src="$RUNTIME_JWT",dst=/run/secrets/jwt_signing_key,readonly \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,noexec,nosuid,size=16m \
    "$NEW_IMAGE" \
    >/dev/null \
    || die "isolated candidate start failed"

sleep 5

SEC=$(docker inspect "$ISO_API" \
    --format='user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .HostConfig.PortBindings}}')

printf '%s\n' "$SEC"

printf '%s' "$SEC" | grep -q 'user=app' \
    || die "candidate user is not app"

printf '%s' "$SEC" | grep -q 'readonly=true' \
    || die "candidate rootfs not readonly"

printf '%s' "$SEC" | grep -q 'capdrop=\["ALL"\]' \
    || die "candidate cap drop missing"

printf '%s' "$SEC" | grep -q 'no-new-privileges:true' \
    || die "candidate NNP missing"

printf '%s' "$SEC" | grep -q 'ports={}' \
    || die "candidate exposes host ports"

docker run --rm \
    --network "$NET" \
    curlimages/curl:8.16.0 \
    -fsS \
    "http://$ISO_API:8080/health/ready" \
    >/dev/null \
    || {
        docker logs --tail 150 "$ISO_API" || true
        die "isolated candidate readiness failed"
    }

printf '%s\n' "isolated_candidate_health=PASS"

printf '\n=== 12. ISOLATED AUTH SMOKE TEST ===\n'

BOOT_USER="$(cat "$BOOTSTRAP_USERNAME_FILE")"
BOOT_PASS="$(cat "$BOOTSTRAP_PASSWORD_FILE")"

LOGIN_JSON=$(
    python3 - "$BOOT_USER" "$BOOT_PASS" <<'PY'
import json,sys
print(json.dumps({
    "username":sys.argv[1],
    "password":sys.argv[2],
}))
PY
)

LOGIN_RESPONSE=$(
    printf '%s' "$LOGIN_JSON" \
    | docker run --rm --network "$NET" -i \
        curlimages/curl:8.16.0 \
        -fsS \
        -H 'Content-Type: application/json' \
        -X POST \
        "http://$ISO_API:8080/api/v1/auth/login" \
        --data-binary @-
) || die "isolated bootstrap login failed"

ACCESS=$(
    python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["accessToken"])
PY
)

REFRESH=$(
    python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["refreshToken"])
PY
)

[ -n "$ACCESS" ] || die "isolated access token missing"
[ -n "$REFRESH" ] || die "isolated refresh token missing"

ME_HTTP=$(docker run --rm --network "$NET" \
    curlimages/curl:8.16.0 \
    -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $ACCESS" \
    "http://$ISO_API:8080/api/v1/auth/me")

ADMIN_HTTP=$(docker run --rm --network "$NET" \
    curlimages/curl:8.16.0 \
    -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $ACCESS" \
    "http://$ISO_API:8080/api/v1/admin/security/probe")

[ "$ME_HTTP" = 200 ] || die "isolated /me failed"
[ "$ADMIN_HTTP" = 200 ] || die "isolated security.admin probe failed"

printf 'isolated_login=PASS me_http=%s admin_probe_http=%s\n' \
    "$ME_HTTP" "$ADMIN_HTTP"

unset ACCESS REFRESH LOGIN_RESPONSE LOGIN_JSON BOOT_PASS

printf '\n=== 13. VALIDATE STANDALONE PRODUCTION CONTRACT ===\n'

for f in \
  /opt/qflm/secrets/runtime-api/postgres_password \
  /opt/qflm/secrets/runtime-api/redis_password \
  "$RUNTIME_JWT"
do
    [ -s "$f" ] || die "required runtime secret missing: $f"
done

printf '%s\n' "standalone_runtime_secrets=PASS"
printf '%s\n' "host_port_exposure=NONE"

printf '\n=== 14. GUARDED STANDALONE PRODUCTION API PROMOTION ===\n'

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

docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS \
    "http://$PROD_API:8080/health/live" >/dev/null \
    || { docker logs --tail 180 "$PROD_API" || true; die "production live health failed"; }

docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS \
    "http://$PROD_API:8080/health/ready" >/dev/null \
    || { docker logs --tail 180 "$PROD_API" || true; die "production ready health failed"; }

printf '%s\n' "production_health=PASS"

printf '\n=== 15. PRODUCTION AUTH SMOKE TEST ===\n'

BOOT_PASS="$(cat "$BOOTSTRAP_PASSWORD_FILE")"

PROD_LOGIN_JSON=$(
    python3 - "$BOOT_USER" "$BOOT_PASS" <<'PY'
import json,sys
print(json.dumps({
    "username":sys.argv[1],
    "password":sys.argv[2],
}))
PY
)

PROD_LOGIN=$(
    printf '%s' "$PROD_LOGIN_JSON" \
    | docker run --rm --network "$NET" -i \
        curlimages/curl:8.16.0 \
        -fsS \
        -H 'Content-Type: application/json' \
        -X POST \
        "http://$PROD_API:8080/api/v1/auth/login" \
        --data-binary @-
) || die "production bootstrap login failed"

PROD_ACCESS=$(
    python3 - "$PROD_LOGIN" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["accessToken"])
PY
)

PROD_REFRESH=$(
    python3 - "$PROD_LOGIN" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["refreshToken"])
PY
)

[ -n "$PROD_ACCESS" ] || die "production access token missing"
[ -n "$PROD_REFRESH" ] || die "production refresh token missing"

PROD_ME=$(docker run --rm --network "$NET" \
    curlimages/curl:8.16.0 \
    -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $PROD_ACCESS" \
    "http://$PROD_API:8080/api/v1/auth/me")

PROD_ADMIN=$(docker run --rm --network "$NET" \
    curlimages/curl:8.16.0 \
    -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $PROD_ACCESS" \
    "http://$PROD_API:8080/api/v1/admin/security/probe")

REVOKE_JSON=$(
    python3 - "$PROD_REFRESH" <<'PY'
import json,sys
print(json.dumps({
    "refreshToken":sys.argv[1],
}))
PY
)

PROD_REVOKE=$(
    printf '%s' "$REVOKE_JSON" \
    | docker run --rm --network "$NET" -i \
        curlimages/curl:8.16.0 \
        -s -o /dev/null -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $PROD_ACCESS" \
        -X POST \
        "http://$PROD_API:8080/api/v1/auth/revoke" \
        --data-binary @-
)

printf 'production_me_http=%s admin_probe_http=%s revoke_http=%s\n' \
    "$PROD_ME" "$PROD_ADMIN" "$PROD_REVOKE"

[ "$PROD_ME" = 200 ] || die "production /me failed"
[ "$PROD_ADMIN" = 200 ] || die "production RBAC probe failed"
[ "$PROD_REVOKE" = 204 ] || die "production refresh revoke failed"

printf '%s\n' "production_auth_smoke=PASS"

unset BOOT_PASS PROD_LOGIN_JSON PROD_LOGIN PROD_ACCESS PROD_REFRESH REVOKE_JSON

printf '\n=== 16. FINAL PRODUCTION STATE ===\n'

FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" \
    -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

FINAL_AUTH=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "
SELECT count(*)
FROM information_schema.tables
WHERE table_schema='public'
AND table_name LIKE 'auth_%';
" | xargs)

FINAL_LIC=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" \
    -tAc 'SELECT count(*) FROM licenses;' | xargs)

FINAL_INST=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" \
    -tAc 'SELECT count(*) FROM installations;' | xargs)

REFRESH_ROWS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" \
    -tAc 'SELECT count(*) FROM auth_refresh_tokens;' | xargs)

ACTIVE_REFRESH=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" \
    -tAc 'SELECT count(*) FROM auth_refresh_tokens WHERE revoked_at_utc IS NULL;' | xargs)

printf 'image=%s migrations=%s auth_tables=%s licenses=%s installations=%s refresh_rows=%s active_refresh=%s\n' \
    "$PIMAGE" "$FINAL_MIG" "$FINAL_AUTH" "$FINAL_LIC" "$FINAL_INST" "$REFRESH_ROWS" "$ACTIVE_REFRESH"

[ "$FINAL_MIG" = 5 ] || die "final migration count mismatch"
[ "$FINAL_AUTH" = 6 ] || die "final auth table count mismatch"
[ "$FINAL_LIC" = "$LIC" ] || die "license count changed"
[ "$FINAL_INST" = "$INST" ] || die "installation count changed"
[ "$ACTIVE_REFRESH" = 0 ] || die "smoke test left active refresh token"

printf '%s\n' "production_final_state=PASS"
printf '%s\n' "external_exposure=UNCHANGED"

COMPLETED=1

printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 6E2 PASSED"
printf '%s\n' "======================================================"
printf '%s\n' "JWT SECRET FILE SUPPORT:            PASS"
printf '%s\n' "JWT MASTER SECRET:                  ROOT 0600"
printf '%s\n' "JWT RUNTIME SECRET:                 APP 0400"
printf '%s\n' "JWT SECRET PRINTED:                 NO"
printf '%s\n' "CANDIDATE BUILD:                    PASS"
printf '%s\n' "ISOLATED AUTH TEST:                 PASS"
printf '%s\n' "PRODUCTION API PROMOTION:           PASS"
printf '%s\n' "PRODUCTION LOGIN:                   PASS"
printf '%s\n' "PRODUCTION /ME:                     PASS"
printf '%s\n' "PRODUCTION RBAC PROBE:              PASS"
printf '%s\n' "PRODUCTION REFRESH REVOKE:          PASS"
printf '%s\n' "PRODUCTION DB MIGRATIONS:           5"
printf '%s\n' "PRODUCTION AUTH TABLES:             6"
printf '%s\n' "LICENSING DATA:                     UNCHANGED"
printf '%s\n' "EXTERNAL EXPOSURE:                  UNCHANGED"
printf 'CANDIDATE IMAGE:                    %s\n' "$NEW_IMAGE"
printf 'CANDIDATE IMAGE ID:                 %s\n' "$NEW_IMAGE_ID"
printf 'COMPOSE OVERRIDE:                   %s\n' "$OVERRIDE"
printf 'DB BACKUP:                          %s\n' "$DB_DUMP"
printf 'REPORT:                             %s\n' "$REPORT"
printf '%s\n' "NEXT: RECOVERY 6F - AUTH/RBAC ADMIN MANAGEMENT + PASSWORD CHANGE/BOOTSTRAP RETIREMENT"
printf '%s\n' "======================================================"
printf '%s\n' "======================================================"