#!/usr/bin/env bash
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
ISO_DB="qflm_recovery6d_test"
ISO_API="qflm-api-recovery6d-test"
NET="qflm_backend"
EXPECTED_IMAGE="qflm-api:phase14d4-candidate"
ISO_IMAGE="qflm-api:recovery6d-candidate"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery6d-$STAMP"
REPORT="$BACKUP/recovery6d-report.txt"
SOURCE_BACKUP="$BACKUP/source-before-phase15e1.tgz"
MIGSQL="$BACKUP/auth-migrations.sql"
PUBLISH="$ROOT/artifacts/api-publish-recovery6d"
DOCKERFILE="$ROOT/Dockerfile.recovery6d"
MUTATED=0
COMPLETED=0

die(){ echo "STOP: $*" >&2; exit 1; }
cleanup(){
  docker rm -f "$ISO_API" >/dev/null 2>&1 || true
  if [ "$COMPLETED" -ne 1 ] && [ "$MUTATED" -eq 1 ] && [ -s "$SOURCE_BACKUP" ]; then
    echo
    echo "=== SOURCE ROLLBACK ==="
    rm -f "$APP/Security/RefreshTokenCommand.cs" "$APP/Security/RefreshTokenResult.cs" "$APP/Security/RevokeRefreshTokenCommand.cs" "$APP/Security/IRefreshTokenService.cs"
    rm -f "$INFRA/Security/EfRefreshTokenService.cs"
    tar -xzf "$SOURCE_BACKUP" -C "$ROOT" || true
    echo "source_restore_attempted=YES"
  fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

echo "======================================================"
echo " QFLM RECOVERY 6D"
echo " REFRESH ROTATION + REVOKE - ISOLATED"
echo "======================================================"

echo
echo(){ :; }

echo "=== 1. PRODUCTION BASELINE ==="
IMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
RUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
AUTH_TABLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name LIKE 'auth_%';" | xargs)
echo "image=$IMG running=$RUN migrations=$MIG production_auth_tables=$AUTH_TABLES"
[ "$IMG" = "$EXPECTED_IMAGE" ] || die "unexpected production API image"
[ "$RUN" = true ] || die "production API not running"
[ "$MIG" = 3 ] || die "unexpected production migration count"
[ "$AUTH_TABLES" = 0 ] || die "auth tables unexpectedly present in production"

echo "=== 2. VERIFY PHASE 15D SOURCE ==="
for f in \
  "$API_SRC/Security/QflmBearerAuthenticationHandler.cs" \
  "$API_SRC/Controllers/AuthController.cs" \
  "$INFRA/Security/EfAuthenticationService.cs" \
  "$INFRA/Security/JwtTokenService.cs"; do
  [ -s "$f" ] || die "missing Phase 15D source: $f"
done
grep -q 'UseAuthentication' "$API_SRC/Program.cs" || die "auth middleware missing"
echo "phase15d_source=PASS"

echo "=== 3. SOURCE BACKUP ==="
tar -czf "$SOURCE_BACKUP" -C "$ROOT" src/QFLM.Api src/QFLM.Application src/QFLM.Infrastructure/Security || die "source backup failed"
echo "source_backup=$SOURCE_BACKUP"
echo "source_backup_sha256=$(sha256sum "$SOURCE_BACKUP" | awk '{print $1}')"
MUTATED=1

echo "=== 4. ADD REFRESH/REVOKE CONTRACTS ==="
cat > "$APP/Security/RefreshTokenCommand.cs" <<'CS'
namespace QFLM.Application.Security;
public sealed record RefreshTokenCommand
{
    public required string RefreshToken { get; init; }
    public string? ClientIp { get; init; }
}
CS
cat > "$APP/Security/RefreshTokenResult.cs" <<'CS'
namespace QFLM.Application.Security;
public sealed record RefreshTokenResult
{
    public required string AccessToken { get; init; }
    public required DateTime AccessTokenExpiresAtUtc { get; init; }
    public required string RefreshToken { get; init; }
    public required DateTime RefreshTokenExpiresAtUtc { get; init; }
}
CS
cat > "$APP/Security/RevokeRefreshTokenCommand.cs" <<'CS'
namespace QFLM.Application.Security;
public sealed record RevokeRefreshTokenCommand
{
    public required Guid UserId { get; init; }
    public required string RefreshToken { get; init; }
    public string? ClientIp { get; init; }
}
CS
cat > "$APP/Security/IRefreshTokenService.cs" <<'CS'
namespace QFLM.Application.Security;
public interface IRefreshTokenService
{
    Task<RefreshTokenResult> RefreshAsync(RefreshTokenCommand command, CancellationToken cancellationToken = default);
    Task RevokeAsync(RevokeRefreshTokenCommand command, CancellationToken cancellationToken = default);
}
CS

echo "refresh_revoke_contracts=CREATED"

echo "=== 5. ADD REFRESH TOKEN SERVICE ==="
cat > "$INFRA/Security/EfRefreshTokenService.cs" <<'CS'
using System.Security.Cryptography;
using System.Text;
using Microsoft.EntityFrameworkCore;
using QFLM.Application.Security;
using QFLM.Domain.Security;
using QFLM.Infrastructure.Persistence;

namespace QFLM.Infrastructure.Security;

public sealed class EfRefreshTokenService : IRefreshTokenService
{
    private static readonly TimeSpan RefreshLifetime = TimeSpan.FromDays(30);
    private readonly QflmDbContext _db;
    private readonly JwtTokenService _jwt;

    public EfRefreshTokenService(QflmDbContext db, JwtTokenService jwt)
    {
        _db = db;
        _jwt = jwt;
    }

    public async Task<RefreshTokenResult> RefreshAsync(RefreshTokenCommand command, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(command.RefreshToken);
        var now = DateTime.UtcNow;
        var hash = Hash(command.RefreshToken);

        await using var tx = await _db.Database.BeginTransactionAsync(cancellationToken);
        var current = await _db.AuthRefreshTokens.Include(x => x.User)
            .SingleOrDefaultAsync(x => x.TokenHash == hash, cancellationToken);

        if (current is null || current.RevokedAtUtc.HasValue || current.ExpiresAtUtc <= now || current.User is null || !current.User.IsActive)
            throw new UnauthorizedAccessException("Invalid refresh token.");

        var roles = await (from ur in _db.AuthUserRoles join r in _db.AuthRoles on ur.RoleId equals r.Id where ur.UserId == current.UserId select r.Name)
            .Distinct().OrderBy(x => x).ToListAsync(cancellationToken);
        var permissions = await (from ur in _db.AuthUserRoles join rp in _db.AuthRolePermissions on ur.RoleId equals rp.RoleId join p in _db.AuthPermissions on rp.PermissionId equals p.Id where ur.UserId == current.UserId select p.Code)
            .Distinct().OrderBy(x => x).ToListAsync(cancellationToken);

        var access = _jwt.Issue(current.UserId, current.User.Username, roles, permissions);
        var nextRaw = Convert.ToBase64String(RandomNumberGenerator.GetBytes(48));
        var nextHash = Hash(nextRaw);
        var nextExpires = now.Add(RefreshLifetime);

        current.RevokedAtUtc = now;
        current.RevokedByIp = command.ClientIp;
        current.ReplacedByTokenHash = nextHash;

        _db.AuthRefreshTokens.Add(new AuthRefreshToken
        {
            UserId = current.UserId,
            TokenHash = nextHash,
            ExpiresAtUtc = nextExpires,
            CreatedByIp = command.ClientIp
        });

        await _db.SaveChangesAsync(cancellationToken);
        await tx.CommitAsync(cancellationToken);

        return new RefreshTokenResult
        {
            AccessToken = access.Token,
            AccessTokenExpiresAtUtc = access.ExpiresAtUtc,
            RefreshToken = nextRaw,
            RefreshTokenExpiresAtUtc = nextExpires
        };
    }

    public async Task RevokeAsync(RevokeRefreshTokenCommand command, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(command.RefreshToken);
        var hash = Hash(command.RefreshToken);
        var token = await _db.AuthRefreshTokens.SingleOrDefaultAsync(x => x.TokenHash == hash && x.UserId == command.UserId, cancellationToken);
        if (token is null)
            throw new UnauthorizedAccessException("Refresh token does not belong to authenticated user.");

        if (!token.RevokedAtUtc.HasValue)
        {
            token.RevokedAtUtc = DateTime.UtcNow;
            token.RevokedByIp = command.ClientIp;
            await _db.SaveChangesAsync(cancellationToken);
        }
    }

    private static string Hash(string token) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token))).ToLowerInvariant();
}
CS

echo "refresh_token_service=CREATED"

echo "=== 6. PATCH AUTH CONTROLLER ==="
python3 - "$API_SRC/Controllers/AuthController.cs" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old="""    private readonly IAuthenticationService _authenticationService;

    public AuthController(
        IAuthenticationService authenticationService)
    {
        _authenticationService =
            authenticationService;
    }
"""
new="""    private readonly IAuthenticationService _authenticationService;
    private readonly IRefreshTokenService _refreshTokenService;

    public AuthController(
        IAuthenticationService authenticationService,
        IRefreshTokenService refreshTokenService)
    {
        _authenticationService = authenticationService;
        _refreshTokenService = refreshTokenService;
    }
"""
if "IRefreshTokenService" not in s:
    if old not in s: raise SystemExit("AuthController constructor marker not found")
    s=s.replace(old,new,1)
methods='''    [AllowAnonymous]\n    [HttpPost("refresh")]\n    public async Task<IActionResult> Refresh([FromBody] RefreshTokenCommand command, CancellationToken cancellationToken)\n    {\n        try\n        {\n            var result = await _refreshTokenService.RefreshAsync(command with { ClientIp = HttpContext.Connection.RemoteIpAddress?.ToString() }, cancellationToken);\n            return Ok(result);\n        }\n        catch (UnauthorizedAccessException)\n        {\n            return Unauthorized(new { error = "INVALID_REFRESH_TOKEN" });\n        }\n    }\n\n    [Authorize]\n    [HttpPost("revoke")]\n    public async Task<IActionResult> Revoke([FromBody] RefreshTokenCommand command, CancellationToken cancellationToken)\n    {\n        var id = User.FindFirst(System.Security.Claims.ClaimTypes.NameIdentifier)?.Value;\n        if (!Guid.TryParse(id, out var userId)) return Unauthorized();\n        try\n        {\n            await _refreshTokenService.RevokeAsync(new RevokeRefreshTokenCommand { UserId = userId, RefreshToken = command.RefreshToken, ClientIp = HttpContext.Connection.RemoteIpAddress?.ToString() }, cancellationToken);\n            return NoContent();\n        }\n        catch (UnauthorizedAccessException)\n        {\n            return Forbid();\n        }\n    }\n\n'''
if '[HttpPost("refresh")]' not in s:
    marker='    [Authorize]\n    [HttpGet("me")]'
    pos=s.find(marker)
    if pos<0: raise SystemExit("AuthController me marker not found")
    s=s[:pos]+methods+s[pos:]
p.write_text(s)
PY

grep -q 'HttpPost("refresh")' "$API_SRC/Controllers/AuthController.cs" || die "refresh route missing"
grep -q 'HttpPost("revoke")' "$API_SRC/Controllers/AuthController.cs" || die "revoke route missing"
echo "auth_controller_patch=PASS"

echo "=== 7. PATCH PROGRAM DI ==="
python3 - "$API_SRC/Program.cs" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
block='''builder.Services.AddScoped<\n    IRefreshTokenService,\n    EfRefreshTokenService>();\n\n'''
if "EfRefreshTokenService" not in s:
    marker="builder.Services.AddSingleton<Pbkdf2PasswordHasher>();"
    pos=s.find(marker)
    if pos<0: raise SystemExit("DI marker not found")
    s=s[:pos]+block+s[pos:]
p.write_text(s)
PY

grep -q 'EfRefreshTokenService' "$API_SRC/Program.cs" || die "refresh DI missing"
echo "refresh_service_di=PASS"

echo "=== 8. RELEASE BUILD ==="
dotnet build QuikeFix.LicenseManager.slnx -c Release || die "Phase 15E.1 build failed"
echo "release_build=PASS"

echo "=== 9. BUILD ISOLATED DATABASE ==="
dotnet tool restore >/dev/null || die "dotnet tool restore failed"
dotnet tool run dotnet-ef migrations script \
  --project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj \
  --startup-project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj \
  --context QflmDbContext --idempotent --output "$MIGSQL" || die "migration SQL failed"

docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1 \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" >/dev/null

docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB"
docker exec "$PG" createdb -U qflm "$ISO_DB" || die "isolated DB create failed"
docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges \
  | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null || die "isolated clone failed"
cat "$MIGSQL" | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null || die "isolated migrations failed"
ISO_MIG=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
[ "$ISO_MIG" = 5 ] || die "isolated migration count is not 5"
echo "isolated_migrations=$ISO_MIG"

echo "=== 10. SEED ISOLATED ADMIN ==="
JWT_KEY="$(openssl rand -base64 48)"
TEST_PASSWORD="$(openssl rand -base64 30 | tr -d '\n')"
ADMIN_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
ROLE_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
PERM_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
ADMIN_HASH=$(python3 - "$TEST_PASSWORD" <<'PY'
import base64,hashlib,os,sys
pw=sys.argv[1].encode(); salt=os.urandom(16); h=hashlib.pbkdf2_hmac('sha512',pw,salt,210000,32)
print('PBKDF2-SHA512$210000$%s$%s'%(base64.b64encode(salt).decode(),base64.b64encode(h).decode()))
PY
)

docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 <<SQL >/dev/null
INSERT INTO auth_users (id,username,normalized_username,email,normalized_email,password_hash,is_active,email_confirmed,failed_access_attempts,security_stamp,created_at_utc,updated_at_utc)
VALUES ('$ADMIN_ID','phase15-admin','PHASE15-ADMIN','phase15-admin@example.invalid','PHASE15-ADMIN@EXAMPLE.INVALID','$ADMIN_HASH',true,true,0,'phase15e1',NOW(),NOW());
INSERT INTO auth_roles (id,name,normalized_name,description,is_system,created_at_utc,updated_at_utc)
VALUES ('$ROLE_ID','Platform Administrator','PLATFORM ADMINISTRATOR','Phase 15E.1 isolated admin',true,NOW(),NOW());
INSERT INTO auth_permissions (id,code,name,category,is_system,created_at_utc,updated_at_utc)
VALUES ('$PERM_ID','security.admin','Administer Security','Security',true,NOW(),NOW());
INSERT INTO auth_user_roles (id,user_id,role_id,created_at_utc,updated_at_utc)
VALUES (gen_random_uuid(),'$ADMIN_ID','$ROLE_ID',NOW(),NOW());
INSERT INTO auth_role_permissions (id,role_id,permission_id,created_at_utc,updated_at_utc)
VALUES (gen_random_uuid(),'$ROLE_ID','$PERM_ID',NOW(),NOW());
SQL

echo "isolated_admin_seed=PASS"
echo "secrets_displayed=NO"

echo "=== 11. PUBLISH + BUILD ISOLATED API ==="
rm -rf "$PUBLISH"
dotnet publish "$API_SRC/QFLM.Api.csproj" -c Release -o "$PUBLISH" || die "publish failed"
cat > "$DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-recovery6d/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER

docker build -f "$DOCKERFILE" -t "$ISO_IMAGE" . || die "image build failed"
echo "isolated_api_image=$ISO_IMAGE"

echo "=== 12. START ISOLATED API ==="
ENV_FILE="$BACKUP/recovery6d-isolated.env"
docker inspect "$PROD_API" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$ENV_FILE" || die "capture env failed"
chmod 600 "$ENV_FILE"
cat >> "$ENV_FILE" <<EOF
Qflm__PostgreSqlDatabase=$ISO_DB
PostgreSqlDatabase=$ISO_DB
Jwt__SigningKey=$JWT_KEY
Jwt__Issuer=qflm
Jwt__Audience=qflm-admin
EOF
chmod 600 "$ENV_FILE"
echo "isolated_database_override=$ISO_DB"
docker rm -f "$ISO_API" >/dev/null 2>&1 || true
docker run -d --name "$ISO_API" --network "$NET" --env-file "$ENV_FILE" --volumes-from "$PROD_API:ro" \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp:rw,noexec,nosuid,size=16m "$ISO_IMAGE" >/dev/null || die "isolated API start failed"
sleep 5
docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS "http://$ISO_API:8080/health/ready" >/dev/null || { docker logs --tail 100 "$ISO_API" || true; die "isolated API readiness failed"; }
echo "isolated_api_health=PASS"

echo "=== 13. LOGIN ==="
LOGIN_JSON=$(python3 - "$TEST_PASSWORD" <<'PY'
import json,sys; print(json.dumps({'username':'phase15-admin','password':sys.argv[1]}))
PY
)
LOGIN_RESPONSE=$(printf '%s' "$LOGIN_JSON" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -fsS -H 'Content-Type: application/json' -X POST "http://$ISO_API:8080/api/v1/auth/login" --data-binary @-) || die "login failed"
ACCESS1=$(python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys; print(json.loads(sys.argv[1])['accessToken'])
PY
)
REFRESH1=$(python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys; print(json.loads(sys.argv[1])['refreshToken'])
PY
)
[ -n "$ACCESS1" ] && [ -n "$REFRESH1" ] || die "login tokens missing"
echo "initial_login=PASS"

echo "=== 14. REFRESH ROTATION ==="
REFRESH_JSON=$(python3 - "$REFRESH1" <<'PY'
import json,sys; print(json.dumps({'refreshToken':sys.argv[1]}))
PY
)
REFRESH_RESPONSE=$(printf '%s' "$REFRESH_JSON" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -fsS -H 'Content-Type: application/json' -X POST "http://$ISO_API:8080/api/v1/auth/refresh" --data-binary @-) || die "refresh failed"
ACCESS2=$(python3 - "$REFRESH_RESPONSE" <<'PY'
import json,sys; print(json.loads(sys.argv[1])['accessToken'])
PY
)
REFRESH2=$(python3 - "$REFRESH_RESPONSE" <<'PY'
import json,sys; print(json.loads(sys.argv[1])['refreshToken'])
PY
)
[ "$REFRESH1" != "$REFRESH2" ] || die "refresh token did not rotate"
echo "refresh_rotation=PASS"

echo "=== 15. OLD TOKEN REPLAY MUST FAIL ==="
REPLAY_HTTP=$(printf '%s' "$REFRESH_JSON" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -X POST "http://$ISO_API:8080/api/v1/auth/refresh" --data-binary @-)
echo "old_refresh_replay_http=$REPLAY_HTTP"
[ "$REPLAY_HTTP" = 401 ] || die "old refresh replay not rejected"
echo "refresh_replay_rejection=PASS"

echo "=== 16. AUTHENTICATED SELF-REVOKE ==="
REVOKE_JSON=$(python3 - "$REFRESH2" <<'PY'
import json,sys; print(json.dumps({'refreshToken':sys.argv[1]}))
PY
)
REVOKE_HTTP=$(printf '%s' "$REVOKE_JSON" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "Authorization: Bearer $ACCESS2" -X POST "http://$ISO_API:8080/api/v1/auth/revoke" --data-binary @-)
echo "revoke_http=$REVOKE_HTTP"
[ "$REVOKE_HTTP" = 204 ] || die "self revoke failed"
echo "self_revoke=PASS"

echo "=== 17. REVOKED NEW TOKEN MUST FAIL ==="
REFRESH2_JSON=$(python3 - "$REFRESH2" <<'PY'
import json,sys; print(json.dumps({'refreshToken':sys.argv[1]}))
PY
)
REVOKED_HTTP=$(printf '%s' "$REFRESH2_JSON" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -X POST "http://$ISO_API:8080/api/v1/auth/refresh" --data-binary @-)
echo "revoked_refresh_http=$REVOKED_HTTP"
[ "$REVOKED_HTTP" = 401 ] || die "revoked token not rejected"
echo "revoked_refresh_rejection=PASS"

echo "=== 18. DB TOKEN CHAIN VERIFICATION ==="
TOTAL=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM auth_refresh_tokens;' | xargs)
REVOKED=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM auth_refresh_tokens WHERE revoked_at_utc IS NOT NULL;' | xargs)
REPLACED=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM auth_refresh_tokens WHERE replaced_by_token_hash IS NOT NULL;' | xargs)
HASH_ONLY=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM auth_refresh_tokens WHERE length(token_hash)=64;' | xargs)
echo "refresh_tokens=$TOTAL revoked=$REVOKED replaced=$REPLACED sha256_hashes=$HASH_ONLY"
[ "$TOTAL" = 2 ] || die "unexpected refresh token count"
[ "$REVOKED" = 2 ] || die "both tokens should be revoked"
[ "$REPLACED" = 1 ] || die "replacement chain missing"
[ "$HASH_ONLY" = 2 ] || die "tokens not hash-only"
echo "refresh_chain_persistence=PASS"

unset ACCESS1 ACCESS2 REFRESH1 REFRESH2 TEST_PASSWORD JWT_KEY

echo "=== 19. PRODUCTION FINAL SAFETY ==="
PIMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
PRUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PMIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
PAUTH=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name LIKE 'auth_%';" | xargs)
echo "image=$PIMG running=$PRUN migrations=$PMIG production_auth_tables=$PAUTH"
[ "$PIMG" = "$IMG" ] || die "production image changed"
[ "$PRUN" = true ] || die "production API stopped"
[ "$PMIG" = "$MIG" ] || die "production migrations changed"
[ "$PAUTH" = 0 ] || die "production auth tables appeared"

COMPLETED=1

echo "======================================================"
echo " QFLM RECOVERY 6D PASSED"
echo "======================================================"
echo "REFRESH TOKEN ROTATION:            PASS"
echo "OLD TOKEN REPLAY -> 401:           PASS"
echo "AUTHENTICATED SELF-REVOKE:         PASS"
echo "REVOKED TOKEN -> 401:              PASS"
echo "TOKEN REPLACEMENT CHAIN:           PASS"
echo "REFRESH STORAGE:                   HASH ONLY"
echo "PRODUCTION DATABASE:               UNCHANGED"
echo "PRODUCTION API/COMPOSE:            UNCHANGED"
echo "REPORT:                            $REPORT"
echo "NEXT: RECOVERY 6E - BOOTSTRAP ADMIN + GUARDED AUTH PRODUCTION PROMOTION"
echo "======================================================"
echo "======================================================"