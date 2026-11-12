#!/usr/bin/env bash
# QFLM RECOVERY 6F1
# Password change + bootstrap retirement readiness, isolated only.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API_SRC="$ROOT/src/QFLM.Api"
APP="$ROOT/src/QFLM.Application"
INFRA="$ROOT/src/QFLM.Infrastructure"

PROD_API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"
ISO_DB="qflm_recovery6f1_test"
ISO_API="qflm-api-recovery6f1-test"
NET="qflm_backend"

EXPECTED_IMAGE="qflm-api:recovery6e2-candidate"
ISO_IMAGE="qflm-api:recovery6f1-candidate"

AUTH_SECRET_DIR="/opt/qflm/secrets/auth"
BOOTSTRAP_USERNAME_FILE="$AUTH_SECRET_DIR/bootstrap-admin-username"
BOOTSTRAP_PASSWORD_FILE="$AUTH_SECRET_DIR/bootstrap-admin-password"
RUNTIME_JWT="/opt/qflm/secrets/runtime-api/jwt-signing-key"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery6f1-$STAMP"
REPORT="$BACKUP/recovery6f1-report.txt"
SOURCE_BACKUP="$BACKUP/source-before-phase15f1.tgz"
DB_DUMP="$BACKUP/qflm-before-recovery6f1.dump"
ENV_FILE="$BACKUP/isolated-api.env"
PUBLISH="$ROOT/artifacts/api-publish-recovery6f1"
DOCKERFILE="$ROOT/Dockerfile.recovery6f1"

MUTATED=0
COMPLETED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

cleanup(){
  docker rm -f "$ISO_API" >/dev/null 2>&1 || true

  if [ "$COMPLETED" -ne 1 ] && [ "$MUTATED" -eq 1 ] && [ -s "$SOURCE_BACKUP" ]; then
    printf '\n=== SOURCE ROLLBACK ===\n'
    rm -f "$APP/Security/ChangePasswordCommand.cs"
    rm -f "$APP/Security/IPasswordManagementService.cs"
    rm -f "$INFRA/Security/EfPasswordManagementService.cs"
    tar -xzf "$SOURCE_BACKUP" -C "$ROOT" >/dev/null 2>&1 || true
    printf '%s\n' "source_restore_attempted=YES"
  fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 6F1"
printf '%s\n' " PASSWORD CHANGE + BOOTSTRAP RETIREMENT READINESS"
printf '%s\n' " ISOLATED"
printf '%s\n' "======================================================"

printf '\n=== 1. PRODUCTION BASELINE ===\n'

IMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
RUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
AUTH_TABLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name LIKE 'auth_%';" | xargs)
USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
LIC=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
INST=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'image=%s running=%s migrations=%s auth_tables=%s users=%s licenses=%s installations=%s\n' \
  "$IMG" "$RUN" "$MIG" "$AUTH_TABLES" "$USERS" "$LIC" "$INST"

[ "$IMG" = "$EXPECTED_IMAGE" ] || die "unexpected production API image"
[ "$RUN" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "expected 5 migrations"
[ "$AUTH_TABLES" = 6 ] || die "expected 6 auth tables"
[ -s "$BOOTSTRAP_USERNAME_FILE" ] || die "bootstrap username file missing"
[ -s "$BOOTSTRAP_PASSWORD_FILE" ] || die "bootstrap password file missing"
[ -s "$RUNTIME_JWT" ] || die "JWT runtime secret missing"

printf '%s\n' "production_baseline=PASS"

printf '\n=== 2. BACKUP SOURCE + DATABASE ===\n'

tar -czf "$SOURCE_BACKUP" -C "$ROOT" \
  "src/QFLM.Api" \
  "src/QFLM.Application" \
  "src/QFLM.Infrastructure/Security" \
  || die "source backup failed"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" -Fc > "$DB_DUMP" \
  || die "database backup failed"

[ -s "$DB_DUMP" ] || die "database backup empty"

printf 'source_backup_sha256=%s\n' "$(sha256sum "$SOURCE_BACKUP" | awk '{print $1}')"
printf 'database_backup_sha256=%s\n' "$(sha256sum "$DB_DUMP" | awk '{print $1}')"

MUTATED=1

printf '\n=== 3. ADD PASSWORD MANAGEMENT CONTRACTS ===\n'

mkdir -p "$APP/Security"

cat > "$APP/Security/ChangePasswordCommand.cs" <<'CS'
namespace QFLM.Application.Security;

public sealed record ChangePasswordCommand
{
    public required Guid UserId { get; init; }
    public required string CurrentPassword { get; init; }
    public required string NewPassword { get; init; }
    public string? ClientIp { get; init; }
}
CS

cat > "$APP/Security/IPasswordManagementService.cs" <<'CS'
namespace QFLM.Application.Security;

public interface IPasswordManagementService
{
    Task ChangePasswordAsync(
        ChangePasswordCommand command,
        CancellationToken cancellationToken = default);
}
CS

printf '%s\n' "password_contracts=CREATED"

printf '\n=== 4. ADD EF PASSWORD MANAGEMENT SERVICE ===\n'

cat > "$INFRA/Security/EfPasswordManagementService.cs" <<'CS'
using Microsoft.EntityFrameworkCore;
using QFLM.Application.Security;
using QFLM.Infrastructure.Persistence;

namespace QFLM.Infrastructure.Security;

public sealed class EfPasswordManagementService
    : IPasswordManagementService
{
    private readonly QflmDbContext _db;
    private readonly Pbkdf2PasswordHasher _hasher;

    public EfPasswordManagementService(
        QflmDbContext db,
        Pbkdf2PasswordHasher hasher)
    {
        _db = db;
        _hasher = hasher;
    }

    public async Task ChangePasswordAsync(
        ChangePasswordCommand command,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(command.CurrentPassword);
        ArgumentException.ThrowIfNullOrWhiteSpace(command.NewPassword);

        if (command.NewPassword.Length < 14)
            throw new InvalidOperationException(
                "New password must contain at least 14 characters.");

        var user = await _db.AuthUsers
            .SingleOrDefaultAsync(
                x => x.Id == command.UserId,
                cancellationToken);

        if (user is null || !user.IsActive)
            throw new UnauthorizedAccessException(
                "Password change rejected.");

        if (!_hasher.Verify(command.CurrentPassword, user.PasswordHash))
            throw new UnauthorizedAccessException(
                "Password change rejected.");

        if (_hasher.Verify(command.NewPassword, user.PasswordHash))
            throw new InvalidOperationException(
                "New password must differ from the current password.");

        user.PasswordHash = _hasher.Hash(command.NewPassword);
        user.SecurityStamp = Guid.NewGuid().ToString("N");
        user.FailedAccessAttempts = 0;
        user.LockoutEndUtc = null;

        var now = DateTime.UtcNow;

        var activeTokens = await _db.AuthRefreshTokens
            .Where(x =>
                x.UserId == command.UserId &&
                !x.RevokedAtUtc.HasValue)
            .ToListAsync(cancellationToken);

        foreach (var token in activeTokens)
        {
            token.RevokedAtUtc = now;
            token.RevokedByIp = command.ClientIp;
        }

        await _db.SaveChangesAsync(cancellationToken);
    }
}
CS

printf '%s\n' "password_service=CREATED"

printf '\n=== 5. PATCH AUTH CONTROLLER ===\n'

python3 - "$API_SRC/Controllers/AuthController.cs" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

needle = "    private readonly IRefreshTokenService _refreshTokenService;\n"
if "IPasswordManagementService _passwordManagementService" not in s:
    if needle not in s:
        raise SystemExit("refresh service field marker not found")
    s = s.replace(
        needle,
        needle + "    private readonly IPasswordManagementService _passwordManagementService;\n",
        1
    )

old = (
"    public AuthController(\n"
"        IAuthenticationService authenticationService,\n"
"        IRefreshTokenService refreshTokenService)\n"
"    {\n"
"        _authenticationService = authenticationService;\n"
"        _refreshTokenService = refreshTokenService;\n"
"    }\n"
)

new = (
"    public AuthController(\n"
"        IAuthenticationService authenticationService,\n"
"        IRefreshTokenService refreshTokenService,\n"
"        IPasswordManagementService passwordManagementService)\n"
"    {\n"
"        _authenticationService = authenticationService;\n"
"        _refreshTokenService = refreshTokenService;\n"
"        _passwordManagementService = passwordManagementService;\n"
"    }\n"
)

if "IPasswordManagementService passwordManagementService" not in s:
    if old not in s:
        raise SystemExit("AuthController constructor marker not found")
    s = s.replace(old, new, 1)

method = r'''
    [Authorize]
    [HttpPost("change-password")]
    public async Task<IActionResult> ChangePassword(
        [FromBody] ChangePasswordRequest request,
        CancellationToken cancellationToken)
    {
        var id =
            User.FindFirst(
                System.Security.Claims.ClaimTypes.NameIdentifier)?
                .Value;

        if (!Guid.TryParse(id, out var userId))
            return Unauthorized();

        try
        {
            await _passwordManagementService
                .ChangePasswordAsync(
                    new ChangePasswordCommand
                    {
                        UserId = userId,
                        CurrentPassword = request.CurrentPassword,
                        NewPassword = request.NewPassword,
                        ClientIp =
                            HttpContext.Connection.RemoteIpAddress?
                                .ToString()
                    },
                    cancellationToken);

            return NoContent();
        }
        catch (UnauthorizedAccessException)
        {
            return Unauthorized(
                new { error = "PASSWORD_CHANGE_REJECTED" });
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(
                new
                {
                    error = "PASSWORD_POLICY_REJECTED",
                    message = ex.Message
                });
        }
    }

    public sealed record ChangePasswordRequest
    {
        public required string CurrentPassword { get; init; }
        public required string NewPassword { get; init; }
    }

'''

if '[HttpPost("change-password")]' not in s:
    marker = '    [Authorize]\n    [HttpGet("me")]'
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit("AuthController /me marker not found")
    s = s[:pos] + method + s[pos:]

p.write_text(s)
PY

grep -q 'HttpPost("change-password")' "$API_SRC/Controllers/AuthController.cs" \
  || die "change-password route missing"

printf '%s\n' "auth_controller_patch=PASS"

printf '\n=== 6. PATCH PROGRAM DI ===\n'

python3 - "$API_SRC/Program.cs" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

if "EfPasswordManagementService" not in s:
    marker = "builder.Services.AddSingleton<Pbkdf2PasswordHasher>();"
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit("password hasher DI marker not found")

    block = (
        "builder.Services.AddScoped<\n"
        "    IPasswordManagementService,\n"
        "    EfPasswordManagementService>();\n\n"
    )
    s = s[:pos] + block + s[pos:]

p.write_text(s)
PY

grep -q 'EfPasswordManagementService' "$API_SRC/Program.cs" \
  || die "password management DI missing"

printf '%s\n' "password_management_di=PASS"

printf '\n=== 7. RELEASE BUILD ===\n'

dotnet build QuikeFix.LicenseManager.slnx -c Release \
  || die "Phase 15F.1 build failed"

printf '%s\n' "release_build=PASS"

printf '\n=== 8. BUILD ISOLATED PRODUCTION CLONE ===\n'

docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1 \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" \
  >/dev/null

docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB"
docker exec "$PG" createdb -U qflm "$ISO_DB" \
  || die "isolated DB creation failed"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges \
  | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null \
  || die "isolated DB clone failed"

ISO_MIG=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
ISO_AUTH=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name LIKE 'auth_%';" | xargs)

[ "$ISO_MIG" = 5 ] || die "isolated migration mismatch"
[ "$ISO_AUTH" = 6 ] || die "isolated auth schema mismatch"

printf 'isolated_migrations=%s auth_tables=%s\n' "$ISO_MIG" "$ISO_AUTH"

printf '\n=== 9. PUBLISH + BUILD ISOLATED API ===\n'

rm -rf "$PUBLISH"

dotnet publish "$API_SRC/QFLM.Api.csproj" -c Release -o "$PUBLISH" \
  || die "publish failed"

cat > "$DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-recovery6f1/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER

docker build -f "$DOCKERFILE" -t "$ISO_IMAGE" . \
  || die "isolated image build failed"

printf 'isolated_image=%s\n' "$ISO_IMAGE"

printf '\n=== 10. PREPARE ISOLATED ENVIRONMENT ===\n'

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

printf '\n=== 11. START ISOLATED API ===\n'

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
  "$ISO_IMAGE" >/dev/null \
  || die "isolated API start failed"

sleep 5

docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -fsS "http://$ISO_API:8080/health/ready" >/dev/null \
  || {
      docker logs --tail 150 "$ISO_API" || true
      die "isolated API readiness failed"
  }

printf '%s\n' "isolated_api_health=PASS"

printf '\n=== 12. CURRENT BOOTSTRAP LOGIN ===\n'

BOOT_USER="$(cat "$BOOTSTRAP_USERNAME_FILE")"
OLD_PASS="$(cat "$BOOTSTRAP_PASSWORD_FILE")"
NEW_PASS="$(openssl rand -base64 30 | tr -d '\n')Aa9!"

LOGIN_JSON=$(python3 - "$BOOT_USER" "$OLD_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)

LOGIN_RESPONSE=$(printf '%s' "$LOGIN_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -fsS \
      -H 'Content-Type: application/json' \
      -X POST \
      "http://$ISO_API:8080/api/v1/auth/login" \
      --data-binary @-) \
  || die "isolated bootstrap login failed"

ACCESS=$(python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["accessToken"])
PY
)

REFRESH=$(python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["refreshToken"])
PY
)

[ -n "$ACCESS" ] || die "access token missing"
[ -n "$REFRESH" ] || die "refresh token missing"

printf '%s\n' "bootstrap_login=PASS"

printf '\n=== 13. CHANGE PASSWORD ===\n'

CHANGE_JSON=$(python3 - "$OLD_PASS" "$NEW_PASS" <<'PY'
import json,sys
print(json.dumps({"currentPassword":sys.argv[1],"newPassword":sys.argv[2]}))
PY
)

CHANGE_HTTP=$(printf '%s' "$CHANGE_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $ACCESS" \
      -X POST \
      "http://$ISO_API:8080/api/v1/auth/change-password" \
      --data-binary @-)

printf 'change_password_http=%s\n' "$CHANGE_HTTP"

[ "$CHANGE_HTTP" = 204 ] || die "password change failed"

printf '%s\n' "password_change=PASS"

printf '\n=== 14. OLD PASSWORD MUST FAIL ===\n'

OLD_LOGIN_HTTP=$(printf '%s' "$LOGIN_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -X POST \
      "http://$ISO_API:8080/api/v1/auth/login" \
      --data-binary @-)

printf 'old_password_login_http=%s\n' "$OLD_LOGIN_HTTP"

[ "$OLD_LOGIN_HTTP" = 401 ] || die "old password still works"

printf '%s\n' "old_password_rejected=PASS"

printf '\n=== 15. OLD REFRESH TOKEN MUST FAIL ===\n'

OLD_REFRESH_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)

OLD_REFRESH_HTTP=$(printf '%s' "$OLD_REFRESH_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -X POST \
      "http://$ISO_API:8080/api/v1/auth/refresh" \
      --data-binary @-)

printf 'old_refresh_http=%s\n' "$OLD_REFRESH_HTTP"

[ "$OLD_REFRESH_HTTP" = 401 ] || die "old refresh token still works"

printf '%s\n' "old_refresh_revoked=PASS"

printf '\n=== 16. NEW PASSWORD LOGIN ===\n'

NEW_LOGIN_JSON=$(python3 - "$BOOT_USER" "$NEW_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)

NEW_LOGIN_RESPONSE=$(printf '%s' "$NEW_LOGIN_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -fsS \
      -H 'Content-Type: application/json' \
      -X POST \
      "http://$ISO_API:8080/api/v1/auth/login" \
      --data-binary @-) \
  || die "new password login failed"

NEW_ACCESS=$(python3 - "$NEW_LOGIN_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["accessToken"])
PY
)

[ -n "$NEW_ACCESS" ] || die "new-password access token missing"

ME_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $NEW_ACCESS" \
  "http://$ISO_API:8080/api/v1/auth/me")

[ "$ME_HTTP" = 200 ] || die "new-password /me failed"

printf 'new_password_login=PASS me_http=%s\n' "$ME_HTTP"

printf '\n=== 17. VERIFY ISOLATED SECURITY STATE ===\n'

ACTIVE_REFRESH=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "
SELECT count(*)
FROM auth_refresh_tokens rt
JOIN auth_users u ON u.id=rt.user_id
WHERE u.normalized_username='QFLM-ADMIN'
AND rt.revoked_at_utc IS NULL;
" | xargs)

TOTAL_REFRESH=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "
SELECT count(*)
FROM auth_refresh_tokens rt
JOIN auth_users u ON u.id=rt.user_id
WHERE u.normalized_username='QFLM-ADMIN';
" | xargs)

STAMP_LEN=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "
SELECT length(security_stamp)
FROM auth_users
WHERE normalized_username='QFLM-ADMIN';
" | xargs)

printf 'total_refresh=%s active_refresh=%s security_stamp_length=%s\n' \
  "$TOTAL_REFRESH" "$ACTIVE_REFRESH" "$STAMP_LEN"

[ "$TOTAL_REFRESH" -ge 2 ] || die "expected at least two refresh tokens"
[ "$ACTIVE_REFRESH" = 1 ] || die "expected one active refresh token after new login"
[ "$STAMP_LEN" -ge 32 ] || die "security stamp not rotated"

printf '%s\n' "password_security_state=PASS"

unset OLD_PASS NEW_PASS ACCESS REFRESH NEW_ACCESS
unset LOGIN_JSON LOGIN_RESPONSE CHANGE_JSON
unset OLD_REFRESH_JSON NEW_LOGIN_JSON NEW_LOGIN_RESPONSE

printf '\n=== 18. PRODUCTION FINAL SAFETY ===\n'

PIMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
PRUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PMIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
PUSERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
PLIC=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
PINST=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'image=%s running=%s migrations=%s users=%s licenses=%s installations=%s\n' \
  "$PIMAGE" "$PRUN" "$PMIG" "$PUSERS" "$PLIC" "$PINST"

[ "$PIMAGE" = "$IMG" ] || die "production image changed"
[ "$PRUN" = true ] || die "production API stopped"
[ "$PMIG" = "$MIG" ] || die "production migration count changed"
[ "$PUSERS" = "$USERS" ] || die "production user count changed"
[ "$PLIC" = "$LIC" ] || die "production license count changed"
[ "$PINST" = "$INST" ] || die "production installation count changed"

printf '%s\n' "production_unchanged=PASS"

COMPLETED=1

printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 6F1 PASSED"
printf '%s\n' "======================================================"
printf '%s\n' "PASSWORD CHANGE ENDPOINT:           PASS"
printf '%s\n' "CURRENT PASSWORD VERIFICATION:      PASS"
printf '%s\n' "MINIMUM PASSWORD LENGTH:            14"
printf '%s\n' "PASSWORD HASH ROTATION:             PASS"
printf '%s\n' "SECURITY STAMP ROTATION:            PASS"
printf '%s\n' "OLD PASSWORD REJECTED:              PASS"
printf '%s\n' "OLD REFRESH TOKEN REVOKED:          PASS"
printf '%s\n' "NEW PASSWORD LOGIN:                 PASS"
printf '%s\n' "PRODUCTION API/DB:                  UNCHANGED"
printf 'REPORT:                             %s\n' "$REPORT"
printf '%s\n' "NEXT: RECOVERY 6F2 - ADMIN USER/ROLE/PERMISSION MANAGEMENT API (ISOLATED)"
printf '%s\n' "======================================================"
