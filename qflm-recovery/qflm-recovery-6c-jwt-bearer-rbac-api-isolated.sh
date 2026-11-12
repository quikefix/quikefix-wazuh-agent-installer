#!/usr/bin/env bash
# QFLM RECOVERY 6C
# JWT bearer middleware + authenticated/RBAC API routes.
# Full API test is isolated. Production API/DB/Compose/signing remain unchanged.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API_SRC="$ROOT/src/QFLM.Api"
INFRA="$ROOT/src/QFLM.Infrastructure"
MIGDIR="$INFRA/Persistence/Migrations"

PROD_API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"
ISO_DB="qflm_recovery6c_test"
ISO_API="qflm-api-recovery6c-test"
NET="qflm_backend"
EXPECTED_IMAGE="qflm-api:phase14d4-candidate"
ISO_IMAGE="qflm-api:recovery6c-candidate"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery6c-$STAMP"
REPORT="$BACKUP/recovery6c-report.txt"
SOURCE_BACKUP="$BACKUP/source-before-phase15d.tgz"
MIGSQL="$BACKUP/recovery6c-migrations.sql"
PUBLISH="$ROOT/artifacts/api-publish-recovery6c"
DOCKERFILE="$ROOT/Dockerfile.recovery6c"
JWT_KEY_FILE="$BACKUP/jwt-test-key.b64"
TEST_PASSWORD_FILE="$BACKUP/test-password.txt"

MUTATED=0
COMPLETED=0

die(){ echo "STOP: $*" >&2; exit 1; }

cleanup(){
  docker rm -f "$ISO_API" >/dev/null 2>&1 || true
  rm -f "$JWT_KEY_FILE" "$TEST_PASSWORD_FILE" >/dev/null 2>&1 || true

  if [ "$COMPLETED" -ne 1 ] && [ "$MUTATED" -eq 1 ] && [ -s "$SOURCE_BACKUP" ]; then
    echo
    echo "=== SOURCE ROLLBACK ==="
    rm -rf "$API_SRC/Security"
    rm -rf "$API_SRC/Controllers/AuthController.cs"
    rm -rf "$API_SRC/Controllers/AdminSecurityController.cs"
    rm -rf "$API_SRC/Program.cs"
    tar -xzf "$SOURCE_BACKUP" -C "$ROOT" || true
    echo "source_restore_attempted=YES"
  fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

echo "======================================================"
echo " QFLM RECOVERY 6C"
echo " JWT BEARER + AUTH/RBAC API ROUTES"
echo " ISOLATED"
echo "======================================================"

echo
echo "=== 1. PRODUCTION SAFETY BASELINE ==="
IMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
RUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
LIC=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
INST=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
AUTH_TABLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "
SELECT count(*)
FROM information_schema.tables
WHERE table_schema='public'
AND table_name LIKE 'auth_%';
" | xargs)

echo "image=$IMG running=$RUN migrations=$MIG licenses=$LIC installations=$INST production_auth_tables=$AUTH_TABLES"

[ "$IMG" = "$EXPECTED_IMAGE" ] || die "unexpected production API image"
[ "$RUN" = true ] || die "production API not running"
[ "$MIG" = 3 ] || die "unexpected production migration count"
[ "$AUTH_TABLES" = 0 ] || die "auth tables unexpectedly present in production"

echo
echo "=== 2. VERIFY PHASE 15C SOURCE ==="
for f in \
  "$INFRA/Security/Pbkdf2PasswordHasher.cs" \
  "$INFRA/Security/JwtTokenService.cs" \
  "$INFRA/Security/EfAuthenticationService.cs" \
  "$ROOT/src/QFLM.Application/Security/IAuthenticationService.cs" \
  "$ROOT/src/QFLM.Domain/Security/AuthRefreshToken.cs"
do
  [ -s "$f" ] || die "Phase 15C source missing: $f"
done

MIG15B=$(find "$MIGDIR" -maxdepth 1 -type f -name '*_AddAuthenticationRbac.cs' | sort | tail -n1)
MIG15C=$(find "$MIGDIR" -maxdepth 1 -type f -name '*_AddAuthRefreshTokens.cs' | sort | tail -n1)

[ -s "$MIG15B" ] || die "Phase 15B migration missing"
[ -s "$MIG15C" ] || die "Phase 15C migration missing"

echo "phase15c_source=PASS"
echo "auth_migrations=$(basename "$MIG15B"),$(basename "$MIG15C")"

echo
echo "=== 3. SOURCE BACKUP ==="
tar -czf "$SOURCE_BACKUP" -C "$ROOT" \
  "src/QFLM.Api" \
  || die "source backup failed"

echo "source_backup=$SOURCE_BACKUP"
echo "source_backup_sha256=$(sha256sum "$SOURCE_BACKUP" | awk '{print $1}')"
MUTATED=1

echo
echo "=== 4. ADD CUSTOM JWT BEARER AUTHENTICATION HANDLER ==="

mkdir -p "$API_SRC/Security"

cat > "$API_SRC/Security/QflmBearerAuthenticationHandler.cs" <<'CS'
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace QFLM.Api.Security;

public sealed class QflmBearerAuthenticationHandler
    : AuthenticationHandler<AuthenticationSchemeOptions>
{
    public const string SchemeName = "QFLM-Bearer";

    private readonly byte[] _key;
    private readonly string _issuer;
    private readonly string _audience;

    public QflmBearerAuthenticationHandler(
        IOptionsMonitor<AuthenticationSchemeOptions> options,
        ILoggerFactory logger,
        System.Text.Encodings.Web.UrlEncoder encoder,
        IConfiguration configuration)
        : base(options, logger, encoder)
    {
        var keyBase64 =
            configuration["Jwt:SigningKey"]
            ?? throw new InvalidOperationException(
                "Jwt:SigningKey is not configured.");

        _key =
            Convert.FromBase64String(keyBase64);

        if (_key.Length < 32)
        {
            throw new InvalidOperationException(
                "JWT signing key must be at least 256 bits.");
        }

        _issuer =
            configuration["Jwt:Issuer"]
            ?? "qflm";

        _audience =
            configuration["Jwt:Audience"]
            ?? "qflm-admin";
    }

    protected override Task<AuthenticateResult>
        HandleAuthenticateAsync()
    {
        var authorization =
            Request.Headers.Authorization
                .FirstOrDefault();

        if (string.IsNullOrWhiteSpace(authorization) ||
            !authorization.StartsWith(
                "Bearer ",
                StringComparison.OrdinalIgnoreCase))
        {
            return Task.FromResult(
                AuthenticateResult.NoResult());
        }

        var token =
            authorization["Bearer ".Length..]
                .Trim();

        try
        {
            var principal =
                Validate(token);

            var ticket =
                new AuthenticationTicket(
                    principal,
                    SchemeName);

            return Task.FromResult(
                AuthenticateResult.Success(ticket));
        }
        catch (Exception ex)
        {
            return Task.FromResult(
                AuthenticateResult.Fail(ex.Message));
        }
    }

    private ClaimsPrincipal Validate(
        string token)
    {
        var parts =
            token.Split('.');

        if (parts.Length != 3)
        {
            throw new InvalidOperationException(
                "Malformed bearer token.");
        }

        var signingInput =
            Encoding.ASCII.GetBytes(
                parts[0] + "." + parts[1]);

        using var hmac =
            new HMACSHA256(_key);

        var expected =
            Base64Url(
                hmac.ComputeHash(
                    signingInput));

        var expectedBytes =
            Encoding.ASCII.GetBytes(
                expected);

        var suppliedBytes =
            Encoding.ASCII.GetBytes(
                parts[2]);

        if (expectedBytes.Length !=
                suppliedBytes.Length ||
            !CryptographicOperations
                .FixedTimeEquals(
                    expectedBytes,
                    suppliedBytes))
        {
            throw new UnauthorizedAccessException(
                "Invalid bearer signature.");
        }

        using var payload =
            JsonDocument.Parse(
                Base64UrlDecode(
                    parts[1]));

        var root =
            payload.RootElement;

        var now =
            DateTimeOffset.UtcNow
                .ToUnixTimeSeconds();

        var exp =
            root.GetProperty("exp")
                .GetInt64();

        var nbf =
            root.GetProperty("nbf")
                .GetInt64();

        if (now >= exp)
        {
            throw new UnauthorizedAccessException(
                "Bearer token expired.");
        }

        if (now < nbf)
        {
            throw new UnauthorizedAccessException(
                "Bearer token is not yet valid.");
        }

        if (!string.Equals(
                root.GetProperty("iss")
                    .GetString(),
                _issuer,
                StringComparison.Ordinal))
        {
            throw new UnauthorizedAccessException(
                "Bearer issuer mismatch.");
        }

        if (!string.Equals(
                root.GetProperty("aud")
                    .GetString(),
                _audience,
                StringComparison.Ordinal))
        {
            throw new UnauthorizedAccessException(
                "Bearer audience mismatch.");
        }

        var claims =
            new List<Claim>
            {
                new(
                    ClaimTypes.NameIdentifier,
                    root.GetProperty("sub")
                        .GetString()
                    ?? string.Empty),
                new(
                    ClaimTypes.Name,
                    root.GetProperty("name")
                        .GetString()
                    ?? string.Empty)
            };

        if (root.TryGetProperty(
                "roles",
                out var roles) &&
            roles.ValueKind ==
                JsonValueKind.Array)
        {
            foreach (var role in
                     roles.EnumerateArray())
            {
                var value =
                    role.GetString();

                if (!string.IsNullOrWhiteSpace(
                        value))
                {
                    claims.Add(
                        new Claim(
                            ClaimTypes.Role,
                            value));
                }
            }
        }

        if (root.TryGetProperty(
                "permissions",
                out var permissions) &&
            permissions.ValueKind ==
                JsonValueKind.Array)
        {
            foreach (var permission in
                     permissions.EnumerateArray())
            {
                var value =
                    permission.GetString();

                if (!string.IsNullOrWhiteSpace(
                        value))
                {
                    claims.Add(
                        new Claim(
                            "permission",
                            value));
                }
            }
        }

        return new ClaimsPrincipal(
            new ClaimsIdentity(
                claims,
                SchemeName,
                ClaimTypes.Name,
                ClaimTypes.Role));
    }

    private static string Base64Url(
        byte[] data)
    {
        return Convert
            .ToBase64String(data)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    private static byte[] Base64UrlDecode(
        string value)
    {
        var normalized =
            value
                .Replace('-', '+')
                .Replace('_', '/');

        normalized +=
            (normalized.Length % 4) switch
            {
                2 => "==",
                3 => "=",
                _ => ""
            };

        return Convert.FromBase64String(
            normalized);
    }
}
CS

echo "custom_bearer_handler=CREATED"

echo
echo "=== 5. ADD PERMISSION AUTHORIZATION REQUIREMENT ==="

cat > "$API_SRC/Security/PermissionRequirement.cs" <<'CS'
using Microsoft.AspNetCore.Authorization;

namespace QFLM.Api.Security;

public sealed class PermissionRequirement
    : IAuthorizationRequirement
{
    public PermissionRequirement(
        string permission)
    {
        Permission = permission;
    }

    public string Permission { get; }
}
CS

cat > "$API_SRC/Security/PermissionAuthorizationHandler.cs" <<'CS'
using Microsoft.AspNetCore.Authorization;

namespace QFLM.Api.Security;

public sealed class PermissionAuthorizationHandler
    : AuthorizationHandler<PermissionRequirement>
{
    protected override Task HandleRequirementAsync(
        AuthorizationHandlerContext context,
        PermissionRequirement requirement)
    {
        if (context.User.HasClaim(
                "permission",
                requirement.Permission))
        {
            context.Succeed(requirement);
        }

        return Task.CompletedTask;
    }
}
CS

echo "permission_authorization=CREATED"

echo
echo "=== 6. ADD AUTH + RBAC CONTROLLERS ==="

cat > "$API_SRC/Controllers/AuthController.cs" <<'CS'
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using QFLM.Application.Security;

namespace QFLM.Api.Controllers;

[ApiController]
[Route("api/v1/auth")]
public sealed class AuthController : ControllerBase
{
    private readonly IAuthenticationService _authenticationService;

    public AuthController(
        IAuthenticationService authenticationService)
    {
        _authenticationService =
            authenticationService;
    }

    [AllowAnonymous]
    [HttpPost("login")]
    public async Task<IActionResult> Login(
        [FromBody] LoginCommand command,
        CancellationToken cancellationToken)
    {
        try
        {
            var result =
                await _authenticationService
                    .LoginAsync(
                        command with
                        {
                            ClientIp =
                                HttpContext
                                    .Connection
                                    .RemoteIpAddress?
                                    .ToString()
                        },
                        cancellationToken);

            return Ok(result);
        }
        catch (UnauthorizedAccessException)
        {
            return Unauthorized(
                new
                {
                    error =
                        "INVALID_CREDENTIALS"
                });
        }
    }

    [Authorize]
    [HttpGet("me")]
    public IActionResult Me()
    {
        return Ok(
            new
            {
                userId =
                    User.FindFirst(
                        System.Security.Claims
                            .ClaimTypes
                            .NameIdentifier)?
                        .Value,
                username =
                    User.Identity?.Name,
                roles =
                    User.FindAll(
                        System.Security.Claims
                            .ClaimTypes.Role)
                        .Select(
                            x => x.Value)
                        .ToArray(),
                permissions =
                    User.FindAll(
                        "permission")
                        .Select(
                            x => x.Value)
                        .ToArray()
            });
    }
}
CS

cat > "$API_SRC/Controllers/AdminSecurityController.cs" <<'CS'
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using QFLM.Api.Security;

namespace QFLM.Api.Controllers;

[ApiController]
[Route("api/v1/admin/security")]
[Authorize]
public sealed class AdminSecurityController
    : ControllerBase
{
    [HttpGet("probe")]
    [Authorize(
        Policy =
            "permission:security.admin")]
    public IActionResult Probe()
    {
        return Ok(
            new
            {
                status =
                    "AUTHORIZED",
                permission =
                    "security.admin"
            });
    }

    [HttpGet("offline-issue-probe")]
    [Authorize(
        Policy =
            "permission:offline.issue")]
    public IActionResult OfflineIssueProbe()
    {
        return Ok(
            new
            {
                status =
                    "AUTHORIZED",
                permission =
                    "offline.issue"
            });
    }
}
CS

echo "auth_rbac_controllers=CREATED"

echo
echo "=== 7. PATCH EXISTING PROGRAM WITH AUTHENTICATION/RBAC DI ==="

python3 - "$API_SRC/Program.cs" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

required_usings = [
    "using Microsoft.AspNetCore.Authentication;",
    "using Microsoft.AspNetCore.Authorization;",
    "using QFLM.Api.Security;",
    "using QFLM.Application.Security;",
    "using QFLM.Infrastructure.Security;",
]

builder_marker = "var builder = WebApplication.CreateBuilder(args);"
pos = s.find(builder_marker)
if pos < 0:
    raise SystemExit("Program builder marker not found")

prefix = s[:pos]
suffix = s[pos:]

for u in required_usings:
    if u not in prefix:
        prefix += u + "\n"

s = prefix + suffix

auth_block = r'''
builder.Services.AddSingleton<Pbkdf2PasswordHasher>();

var jwtKey =
    builder.Configuration["Jwt:SigningKey"]
    ?? throw new InvalidOperationException(
        "Jwt:SigningKey is not configured.");

var jwtIssuer =
    builder.Configuration["Jwt:Issuer"]
    ?? "qflm";

var jwtAudience =
    builder.Configuration["Jwt:Audience"]
    ?? "qflm-admin";

builder.Services.AddSingleton(
    new JwtTokenService(
        jwtKey,
        jwtIssuer,
        jwtAudience,
        TimeSpan.FromMinutes(15)));

builder.Services.AddScoped<
    QFLM.Application.Security.IAuthenticationService,
    EfAuthenticationService>();

builder.Services
    .AddAuthentication(
        options =>
        {
            options.DefaultAuthenticateScheme =
                QflmBearerAuthenticationHandler
                    .SchemeName;

            options.DefaultChallengeScheme =
                QflmBearerAuthenticationHandler
                    .SchemeName;
        })
    .AddScheme<
        AuthenticationSchemeOptions,
        QflmBearerAuthenticationHandler>(
        QflmBearerAuthenticationHandler
            .SchemeName,
        _ => { });

builder.Services.AddSingleton<
    IAuthorizationHandler,
    PermissionAuthorizationHandler>();

builder.Services.AddAuthorization(
    options =>
    {
        foreach (var permission in new[]
        {
            "security.admin",
            "offline.issue",
            "licensing.manage"
        })
        {
            options.AddPolicy(
                "permission:" + permission,
                policy =>
                    policy.Requirements.Add(
                        new PermissionRequirement(
                            permission)));
        }
    });

'''

if "EfAuthenticationService" not in s:
    marker = "builder.Services.AddOpenApi();"
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit("AddOpenApi marker not found")
    s = s[:pos] + auth_block + s[pos:]

middleware = '''app.UseAuthentication();
app.UseAuthorization();

'''

if "app.UseAuthentication();" not in s:
    marker = "app.MapControllers();"
    pos = s.find(marker)
    if pos < 0:
        raise SystemExit("MapControllers marker not found")
    s = s[:pos] + middleware + s[pos:]

p.write_text(s)
PY

grep -q 'QFLM.Application.Licensing.Data' "$API_SRC/Program.cs" \
  || die "existing licensing namespace was lost"

grep -q 'QFLM.Infrastructure.Licensing.Administration' "$API_SRC/Program.cs" \
  || die "existing administration namespace was lost"

grep -q 'IAdministrativeLicensingService' "$API_SRC/Program.cs" \
  || die "existing administrative DI was lost"

grep -q 'IAdministrativeLicensingDataStore' "$API_SRC/Program.cs" \
  || die "existing administrative datastore DI was lost"

grep -q 'QFLM.Application.Security.IAuthenticationService' "$API_SRC/Program.cs" \
  || die "fully-qualified QFLM authentication service registration missing"

grep -q 'AddAuthentication' "$API_SRC/Program.cs" \
  || die "authentication DI patch missing"

grep -q 'UseAuthentication' "$API_SRC/Program.cs" \
  || die "authentication middleware patch missing"

grep -q 'UseAuthorization' "$API_SRC/Program.cs" \
  || die "authorization middleware patch missing"

echo "existing_licensing_di_preserved=PASS"
echo "qflm_auth_interface_qualified=PASS"
echo "program_auth_rbac_patch=PASS"

echo "=== 8. PROGRAM DIAGNOSTIC ==="
echo "--- licensing/admin registrations preserved ---"
grep -nE   'ILicensingService|ILicensingDataStore|IInstallationActivityStore|IAdministrativeLicensingService|IAdministrativeLicensingDataStore'   "$API_SRC/Program.cs"

echo "--- auth registrations added ---"
grep -nE   'QFLM.Application.Security.IAuthenticationService|AddAuthentication|AddAuthorization|UseAuthentication|UseAuthorization'   "$API_SRC/Program.cs"

echo
echo "=== 9. RELEASE BUILD ==="

dotnet build \
  QuikeFix.LicenseManager.slnx \
  -c Release \
  || die "Phase 15D source build failed"

echo "release_build=PASS"

echo
echo "=== 10. GENERATE AUTH MIGRATION SQL ==="

dotnet tool restore >/dev/null \
  || die "dotnet tool restore failed"

dotnet tool run dotnet-ef migrations script \
  --project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj \
  --startup-project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj \
  --context QflmDbContext \
  --idempotent \
  --output "$MIGSQL" \
  || die "migration SQL generation failed"

[ -s "$MIGSQL" ] || die "migration SQL empty"

grep -q 'auth_users' "$MIGSQL" \
  || die "auth_users absent from migration SQL"

grep -q 'auth_refresh_tokens' "$MIGSQL" \
  || die "auth_refresh_tokens absent from migration SQL"

echo "migration_sql=PASS"

echo
echo "=== 11. BUILD ISOLATED DATABASE ==="

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
  || die "isolated database creation failed"

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

cat "$MIGSQL" \
  | docker exec -i "$PG" psql \
      -U qflm \
      -d "$ISO_DB" \
      -v ON_ERROR_STOP=1 \
      >/dev/null \
  || die "isolated auth migration failed"

ISO_MIG=$(docker exec "$PG" psql \
  -U qflm \
  -d "$ISO_DB" \
  -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' \
  | xargs)

AUTH_TABLE_COUNT=$(docker exec "$PG" psql \
  -U qflm \
  -d "$ISO_DB" \
  -tAc "
SELECT count(*)
FROM information_schema.tables
WHERE table_schema='public'
AND table_name LIKE 'auth_%';
" | xargs)

echo "isolated_migrations=$ISO_MIG auth_tables=$AUTH_TABLE_COUNT"

[ "$ISO_MIG" = 5 ] \
  || die "isolated migration count is not 5"

[ "$AUTH_TABLE_COUNT" = 6 ] \
  || die "isolated auth table count is not 6"

echo
echo "=== 12. SEED ISOLATED ADMIN + LIMITED USERS ==="

JWT_KEY="$(openssl rand -base64 48)"
TEST_PASSWORD="$(openssl rand -base64 30 | tr -d '\n')"

printf '%s' "$JWT_KEY" > "$JWT_KEY_FILE"
printf '%s' "$TEST_PASSWORD" > "$TEST_PASSWORD_FILE"
chmod 600 "$JWT_KEY_FILE" "$TEST_PASSWORD_FILE"

ADMIN_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
LIMITED_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
ADMIN_ROLE_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
LIMITED_ROLE_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"

P_ADMIN_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
P_OFFLINE_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
P_LIC_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"

ADMIN_HASH=$(python3 - "$TEST_PASSWORD" <<'PY'
import base64,hashlib,os,sys
pw=sys.argv[1].encode()
salt=os.urandom(16)
h=hashlib.pbkdf2_hmac("sha512",pw,salt,210000,32)
print("PBKDF2-SHA512$210000$%s$%s"%(
    base64.b64encode(salt).decode(),
    base64.b64encode(h).decode()))
PY
)

LIMITED_HASH="$ADMIN_HASH"

docker exec -i "$PG" psql \
  -U qflm \
  -d "$ISO_DB" \
  -v ON_ERROR_STOP=1 <<SQL >/dev/null

INSERT INTO auth_users (
  id,username,normalized_username,email,normalized_email,password_hash,
  is_active,email_confirmed,failed_access_attempts,security_stamp,
  created_at_utc,updated_at_utc
) VALUES
(
  '$ADMIN_ID','phase15-admin','PHASE15-ADMIN',
  'phase15-admin@example.invalid','PHASE15-ADMIN@EXAMPLE.INVALID',
  '$ADMIN_HASH',true,true,0,'adminstamp',NOW(),NOW()
),
(
  '$LIMITED_ID','phase15-limited','PHASE15-LIMITED',
  'phase15-limited@example.invalid','PHASE15-LIMITED@EXAMPLE.INVALID',
  '$LIMITED_HASH',true,true,0,'limitedstamp',NOW(),NOW()
);

INSERT INTO auth_roles (
  id,name,normalized_name,description,is_system,created_at_utc,updated_at_utc
) VALUES
(
  '$ADMIN_ROLE_ID','Platform Administrator','PLATFORM ADMINISTRATOR',
  'Isolated admin role',true,NOW(),NOW()
),
(
  '$LIMITED_ROLE_ID','Licensing Operator','LICENSING OPERATOR',
  'Isolated limited role',true,NOW(),NOW()
);

INSERT INTO auth_permissions (
  id,code,name,category,is_system,created_at_utc,updated_at_utc
) VALUES
(
  '$P_ADMIN_ID','security.admin','Administer Security','Security',true,NOW(),NOW()
),
(
  '$P_OFFLINE_ID','offline.issue','Issue Offline Licenses','Offline Licensing',true,NOW(),NOW()
),
(
  '$P_LIC_ID','licensing.manage','Manage Licensing','Licensing',true,NOW(),NOW()
);

INSERT INTO auth_user_roles (
  id,user_id,role_id,created_at_utc,updated_at_utc
) VALUES
(
  gen_random_uuid(),'$ADMIN_ID','$ADMIN_ROLE_ID',NOW(),NOW()
),
(
  gen_random_uuid(),'$LIMITED_ID','$LIMITED_ROLE_ID',NOW(),NOW()
);

INSERT INTO auth_role_permissions (
  id,role_id,permission_id,created_at_utc,updated_at_utc
) VALUES
(
  gen_random_uuid(),'$ADMIN_ROLE_ID','$P_ADMIN_ID',NOW(),NOW()
),
(
  gen_random_uuid(),'$ADMIN_ROLE_ID','$P_OFFLINE_ID',NOW(),NOW()
),
(
  gen_random_uuid(),'$ADMIN_ROLE_ID','$P_LIC_ID',NOW(),NOW()
),
(
  gen_random_uuid(),'$LIMITED_ROLE_ID','$P_LIC_ID',NOW(),NOW()
);
SQL

echo "isolated_users_seeded=PASS"
echo "test_password_displayed=NO"
echo "jwt_key_displayed=NO"

echo
echo "=== 13. PUBLISH + BUILD ISOLATED API IMAGE ==="

rm -rf "$PUBLISH"

dotnet publish \
  "$API_SRC/QFLM.Api.csproj" \
  -c Release \
  -o "$PUBLISH" \
  || die "API publish failed"

cat > "$DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-recovery6c/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER

docker build \
  -f "$DOCKERFILE" \
  -t "$ISO_IMAGE" \
  . \
  || die "isolated API image build failed"

echo "isolated_api_image=$ISO_IMAGE"
echo "isolated_api_image_id=$(docker image inspect "$ISO_IMAGE" --format '{{.Id}}')"

echo
echo "=== 14. START ISOLATED API CONTAINER ==="

ENV_FILE="$BACKUP/recovery6c-isolated.env"

docker inspect "$PROD_API" \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  > "$ENV_FILE" \
  || die "failed to capture production API environment"

chmod 600 "$ENV_FILE"

python3 - "$ENV_FILE" "$ISO_DB" "$JWT_KEY" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
iso_db = sys.argv[2]
jwt_key = sys.argv[3]

lines = []
db_overridden = False

for raw in path.read_text().splitlines():
    if not raw or "=" not in raw:
        continue

    key, value = raw.split("=", 1)
    normalized = key.replace("_", "").lower()

    if normalized.endswith("postgresqldatabase"):
        value = iso_db
        db_overridden = True

    if key.lower() in {
        "jwt__signingkey",
        "jwt__issuer",
        "jwt__audience",
    }:
        continue

    lines.append(f"{key}={value}")

if not db_overridden:
    raise SystemExit(
        "Could not locate PostgreSqlDatabase environment variable "
        "in production API environment.")

lines.extend([
    f"Jwt__SigningKey={jwt_key}",
    "Jwt__Issuer=qflm",
    "Jwt__Audience=qflm-admin",
])

path.write_text("\n".join(lines) + "\n")
PY

echo "isolated_environment_clone=PASS"
echo "production_secret_values_displayed=NO"

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

SEC=$(docker inspect "$ISO_API" \
  --format='user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .HostConfig.PortBindings}}')

echo "$SEC"

echo "$SEC" | grep -q 'user=app' \
  || die "isolated API user hardening missing"

echo "$SEC" | grep -q 'readonly=true' \
  || die "isolated API readonly rootfs missing"

echo "$SEC" | grep -q 'capdrop=\["ALL"\]' \
  || die "isolated API capdrop missing"

echo "$SEC" | grep -q 'no-new-privileges:true' \
  || die "isolated API NNP missing"

echo "$SEC" | grep -q 'ports={}' \
  || die "isolated API unexpectedly exposes host ports"

docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -fsS "http://$ISO_API:8080/health/ready" \
  >/dev/null \
  || {
      echo "=== ISOLATED API LOGS ==="
      docker logs --tail 120 "$ISO_API" || true
      die "isolated API readiness failed"
  }

echo "isolated_api_health=PASS"

echo "=== 15. LOGIN + BEARER/RBAC HTTP TEST MATRIX ==="

TEST_PASSWORD="$(cat "$TEST_PASSWORD_FILE")"

LOGIN_ADMIN=$(python3 - "$TEST_PASSWORD" <<'PY'
import json,sys
print(json.dumps({
  "username":"phase15-admin",
  "password":sys.argv[1]
}))
PY
)

LOGIN_LIMITED=$(python3 - "$TEST_PASSWORD" <<'PY'
import json,sys
print(json.dumps({
  "username":"phase15-limited",
  "password":sys.argv[1]
}))
PY
)

BAD_LOGIN='{"username":"phase15-admin","password":"wrong-password"}'

ADMIN_RESPONSE=$(printf '%s' "$LOGIN_ADMIN" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -fsS \
      -H 'Content-Type: application/json' \
      -X POST \
      "http://$ISO_API:8080/api/v1/auth/login" \
      --data-binary @-) \
  || die "admin login failed"

ADMIN_TOKEN=$(printf '%s' "$ADMIN_RESPONSE" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["accessToken"])')

[ -n "$ADMIN_TOKEN" ] \
  || die "admin access token missing"

echo "admin_login=PASS"

LIMITED_RESPONSE=$(printf '%s' "$LOGIN_LIMITED" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -fsS \
      -H 'Content-Type: application/json' \
      -X POST \
      "http://$ISO_API:8080/api/v1/auth/login" \
      --data-binary @-) \
  || die "limited login failed"

LIMITED_TOKEN=$(printf '%s' "$LIMITED_RESPONSE" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["accessToken"])')

[ -n "$LIMITED_TOKEN" ] \
  || die "limited access token missing"

echo "limited_login=PASS"

BAD_LOGIN_HTTP=$(printf '%s' "$BAD_LOGIN" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -X POST \
      "http://$ISO_API:8080/api/v1/auth/login" \
      --data-binary @-)

NO_TOKEN_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  "http://$ISO_API:8080/api/v1/auth/me")

INVALID_TOKEN_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H 'Authorization: Bearer invalid.token.value' \
  "http://$ISO_API:8080/api/v1/auth/me")

ME_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://$ISO_API:8080/api/v1/auth/me")

ADMIN_PROBE_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://$ISO_API:8080/api/v1/admin/security/probe")

LIMITED_ADMIN_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $LIMITED_TOKEN" \
  "http://$ISO_API:8080/api/v1/admin/security/probe")

LIMITED_OFFLINE_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $LIMITED_TOKEN" \
  "http://$ISO_API:8080/api/v1/admin/security/offline-issue-probe")

ADMIN_OFFLINE_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://$ISO_API:8080/api/v1/admin/security/offline-issue-probe")

echo "bad_login_http=$BAD_LOGIN_HTTP"
echo "no_token_me_http=$NO_TOKEN_HTTP"
echo "invalid_token_me_http=$INVALID_TOKEN_HTTP"
echo "valid_token_me_http=$ME_HTTP"
echo "admin_security_probe_http=$ADMIN_PROBE_HTTP"
echo "limited_security_probe_http=$LIMITED_ADMIN_HTTP"
echo "limited_offline_probe_http=$LIMITED_OFFLINE_HTTP"
echo "admin_offline_probe_http=$ADMIN_OFFLINE_HTTP"

[ "$BAD_LOGIN_HTTP" = 401 ] \
  || die "bad login was not rejected with 401"

[ "$NO_TOKEN_HTTP" = 401 ] \
  || die "missing bearer token was not rejected with 401"

[ "$INVALID_TOKEN_HTTP" = 401 ] \
  || die "invalid bearer token was not rejected with 401"

[ "$ME_HTTP" = 200 ] \
  || die "valid bearer token did not access /me"

[ "$ADMIN_PROBE_HTTP" = 200 ] \
  || die "admin permission probe failed"

[ "$LIMITED_ADMIN_HTTP" = 403 ] \
  || die "limited user did not receive 403 for security.admin"

[ "$LIMITED_OFFLINE_HTTP" = 403 ] \
  || die "limited user did not receive 403 for offline.issue"

[ "$ADMIN_OFFLINE_HTTP" = 200 ] \
  || die "admin offline.issue permission probe failed"

echo "jwt_bearer_http_authentication=PASS"
echo "rbac_http_authorization=PASS"

echo
echo "=== 16. VERIFY /ME CLAIMS ==="

ME_JSON=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -fsS \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://$ISO_API:8080/api/v1/auth/me")

python3 - "$ME_JSON" <<'PY'
import json,sys
obj=json.loads(sys.argv[1])
assert obj["username"]=="phase15-admin"
assert "Platform Administrator" in obj["roles"]
assert "security.admin" in obj["permissions"]
assert "offline.issue" in obj["permissions"]
assert "licensing.manage" in obj["permissions"]
print("me_claims=PASS")
PY

unset ADMIN_TOKEN
unset LIMITED_TOKEN
unset TEST_PASSWORD
unset JWT_KEY

echo
echo "=== 17. VERIFY LOGIN AUDIT STATE IN ISOLATED DB ==="

REFRESH_COUNT=$(docker exec "$PG" psql \
  -U qflm \
  -d "$ISO_DB" \
  -tAc 'SELECT count(*) FROM auth_refresh_tokens;' \
  | xargs)

LAST_LOGIN_COUNT=$(docker exec "$PG" psql \
  -U qflm \
  -d "$ISO_DB" \
  -tAc "
SELECT count(*)
FROM auth_users
WHERE last_login_at_utc IS NOT NULL;
" | xargs)

HASH_ONLY=$(docker exec "$PG" psql \
  -U qflm \
  -d "$ISO_DB" \
  -tAc "
SELECT count(*)
FROM auth_refresh_tokens
WHERE length(token_hash)=64;
" | xargs)

echo "refresh_tokens=$REFRESH_COUNT users_with_last_login=$LAST_LOGIN_COUNT sha256_refresh_hashes=$HASH_ONLY"

[ "$REFRESH_COUNT" = 2 ] \
  || die "expected two refresh tokens from two successful logins"

[ "$LAST_LOGIN_COUNT" = 2 ] \
  || die "last login timestamp not updated for both users"

[ "$HASH_ONLY" = "$REFRESH_COUNT" ] \
  || die "refresh token persistence is not hash-only"

echo "login_state_persistence=PASS"

echo
echo "=== 18. PRODUCTION FINAL SAFETY ==="

PIMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
PRUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PMIG=$(docker exec "$PG" psql \
  -U qflm \
  -d "$PROD_DB" \
  -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' \
  | xargs)

PROD_AUTH_TABLES=$(docker exec "$PG" psql \
  -U qflm \
  -d "$PROD_DB" \
  -tAc "
SELECT count(*)
FROM information_schema.tables
WHERE table_schema='public'
AND table_name LIKE 'auth_%';
" | xargs)

PLIC=$(docker exec "$PG" psql \
  -U qflm \
  -d "$PROD_DB" \
  -tAc 'SELECT count(*) FROM licenses;' \
  | xargs)

PINST=$(docker exec "$PG" psql \
  -U qflm \
  -d "$PROD_DB" \
  -tAc 'SELECT count(*) FROM installations;' \
  | xargs)

echo "image=$PIMG running=$PRUN migrations=$PMIG production_auth_tables=$PROD_AUTH_TABLES licenses=$PLIC installations=$PINST"

[ "$PIMG" = "$IMG" ] || die "production API image changed"
[ "$PRUN" = true ] || die "production API stopped"
[ "$PMIG" = "$MIG" ] || die "production migration count changed"
[ "$PROD_AUTH_TABLES" = 0 ] || die "auth tables unexpectedly appeared in production"
[ "$PLIC" = "$LIC" ] || die "production license count changed"
[ "$PINST" = "$INST" ] || die "production installation count changed"

COMPLETED=1

echo
echo "======================================================"
echo " QFLM RECOVERY 6C PASSED"
echo "======================================================"
echo "LOGIN HTTP ROUTE:                  PASS"
echo "CUSTOM JWT BEARER AUTH:            PASS"
echo "MISSING TOKEN -> 401:              PASS"
echo "INVALID TOKEN -> 401:              PASS"
echo "VALID TOKEN -> /ME 200:            PASS"
echo "ROLE CLAIMS:                       PASS"
echo "PERMISSION CLAIMS:                 PASS"
echo "SECURITY.ADMIN POLICY:             PASS"
echo "OFFLINE.ISSUE POLICY:              PASS"
echo "INSUFFICIENT PERMISSION -> 403:    PASS"
echo "REFRESH TOKENS HASH-ONLY:          PASS"
echo "PRODUCTION DATABASE:               UNCHANGED"
echo "PRODUCTION API/COMPOSE:            UNCHANGED"
echo "REPORT:                            $REPORT"
echo "NEXT: RECOVERY 6D - REFRESH/REVOKE + BOOTSTRAP ADMIN + GUARDED AUTH PROMOTION"
echo "======================================================"
echo "======================================================"