#!/usr/bin/env bash
# QFLM RECOVERY 6B
# Password hashing + login service + JWT/refresh-token foundation.
# Full validation is isolated. Production API/DB/Compose/signing remain unchanged.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
DOMAIN="$ROOT/src/QFLM.Domain"
APP="$ROOT/src/QFLM.Application"
INFRA="$ROOT/src/QFLM.Infrastructure"
CTX="$INFRA/Persistence/QflmDbContext.cs"
MIGDIR="$INFRA/Persistence/Migrations"

API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"
ISO_DB="qflm_recovery6b_test"
EXPECTED_IMAGE="qflm-api:phase14d4-candidate"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery6b-$STAMP"
REPORT="$BACKUP/recovery6b-report.txt"
SOURCE_BACKUP="$BACKUP/source-before-phase15c.tgz"
MIGSQL="$BACKUP/recovery6b-migrations.sql"
HARNESS="$ROOT/test-harness/Recovery6B"

MUTATED=0
COMPLETED=0

die(){ echo "STOP: $*" >&2; exit 1; }

cleanup(){
  unset QFLM_TEST_CONNECTION 2>/dev/null || true
  unset QFLM_TEST_JWT_KEY 2>/dev/null || true
  unset QFLM_TEST_PASSWORD 2>/dev/null || true

  if [ "$COMPLETED" -ne 1 ] && [ "$MUTATED" -eq 1 ] && [ -s "$SOURCE_BACKUP" ]; then
    echo
    echo "=== SOURCE ROLLBACK ==="
    rm -rf "$APP/Security"
    rm -rf "$INFRA/Security"
    rm -rf "$HARNESS"
    rm -rf "$INFRA/Persistence"
    rm -rf "$DOMAIN/Security"
    tar -xzf "$SOURCE_BACKUP" -C "$ROOT" || true
    echo "source_restore_attempted=YES"
  fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

echo "======================================================"
echo " QFLM RECOVERY 6B"
echo " PASSWORD HASHING + LOGIN + JWT/REFRESH FOUNDATION"
echo " ISOLATED"
echo "======================================================"

echo
echo "=== 1. PRODUCTION SAFETY BASELINE ==="
IMG=$(docker inspect "$API" --format='{{.Config.Image}}') || die "production API missing"
RUN=$(docker inspect "$API" --format='{{.State.Running}}')
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
echo "=== 2. VERIFY PHASE 15B SOURCE ==="
for f in \
  "$DOMAIN/Security/AuthUser.cs" \
  "$DOMAIN/Security/AuthRole.cs" \
  "$DOMAIN/Security/AuthPermission.cs" \
  "$DOMAIN/Security/AuthUserRole.cs" \
  "$DOMAIN/Security/AuthRolePermission.cs"
do
  [ -s "$f" ] || die "Phase 15B source missing: $f"
done

MIG15B=$(find "$MIGDIR" -maxdepth 1 -type f \
  -name '*_AddAuthenticationRbac.cs' | sort | tail -n1)

[ -s "$MIG15B" ] || die "Phase 15B migration missing"

grep -q 'auth_users' "$MIG15B" || die "15B auth migration invalid"
grep -q 'DbSet<AuthUser>' "$CTX" || die "15B DbContext source missing"

echo "phase15b_source=PASS"
echo "phase15b_migration=$(basename "$MIG15B")"

echo
echo "=== 3. SOURCE BACKUP ==="
tar -czf "$SOURCE_BACKUP" -C "$ROOT" \
  "src/QFLM.Domain" \
  "src/QFLM.Application" \
  "src/QFLM.Infrastructure" \
  "test-harness" \
  || die "source backup failed"

echo "source_backup=$SOURCE_BACKUP"
echo "source_backup_sha256=$(sha256sum "$SOURCE_BACKUP" | awk '{print $1}')"
MUTATED=1

echo
echo "=== 4. ADD REFRESH TOKEN DOMAIN ENTITY ==="

cat > "$DOMAIN/Security/AuthRefreshToken.cs" <<'CS'
using QFLM.Domain.Common;

namespace QFLM.Domain.Security;

public sealed class AuthRefreshToken : BaseEntity
{
    public Guid UserId { get; set; }

    public string TokenHash { get; set; } = string.Empty;

    public DateTime ExpiresAtUtc { get; set; }

    public DateTime? RevokedAtUtc { get; set; }

    public string? ReplacedByTokenHash { get; set; }

    public string? CreatedByIp { get; set; }

    public string? RevokedByIp { get; set; }

    public AuthUser? User { get; set; }
}
CS

echo "refresh_token_entity=CREATED"

echo
echo "=== 5. PATCH DB CONTEXT STRUCTURALLY ==="

python3 - "$CTX" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

dbset = '''    public DbSet<AuthRefreshToken> AuthRefreshTokens =>
        Set<AuthRefreshToken>();

'''

method_marker = "    protected override void OnModelCreating("

if "DbSet<AuthRefreshToken>" not in s:
    pos = s.find(method_marker)
    if pos < 0:
        raise SystemExit("OnModelCreating method marker not found")
    s = s[:pos] + dbset + s[pos:]

mapping = '''
        modelBuilder.Entity<AuthRefreshToken>(entity =>
        {
            entity.ToTable("auth_refresh_tokens");

            entity.HasKey(x => x.Id);

            entity.Property(x => x.TokenHash)
                .HasMaxLength(64)
                .IsRequired();

            entity.HasIndex(x => x.TokenHash)
                .IsUnique();

            entity.HasIndex(x => x.UserId);

            entity.HasIndex(x => x.ExpiresAtUtc);

            entity.Property(x => x.ReplacedByTokenHash)
                .HasMaxLength(64);

            entity.Property(x => x.CreatedByIp)
                .HasMaxLength(64);

            entity.Property(x => x.RevokedByIp)
                .HasMaxLength(64);

            entity.HasOne(x => x.User)
                .WithMany()
                .HasForeignKey(x => x.UserId)
                .OnDelete(DeleteBehavior.Cascade);
        });
'''

if 'modelBuilder.Entity<AuthRefreshToken>' not in s:
    method_pos = s.find(method_marker)
    if method_pos < 0:
        raise SystemExit("OnModelCreating method not found")

    open_brace = s.find("{", method_pos)
    if open_brace < 0:
        raise SystemExit("OnModelCreating opening brace not found")

    depth = 0
    close_brace = None
    in_string = False
    escape = False
    verbatim = False
    i = open_brace

    while i < len(s):
        ch = s[i]

        if in_string:
            if verbatim:
                if ch == '"':
                    if i + 1 < len(s) and s[i + 1] == '"':
                        i += 2
                        continue
                    in_string = False
                    verbatim = False
            else:
                if escape:
                    escape = False
                elif ch == '\\':
                    escape = True
                elif ch == '"':
                    in_string = False
        else:
            if ch == '"':
                in_string = True
                if i > 0 and s[i - 1] == '@':
                    verbatim = True
            elif ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    close_brace = i
                    break

        i += 1

    if close_brace is None:
        raise SystemExit("OnModelCreating closing brace not found")

    s = s[:close_brace] + mapping + "\n" + s[close_brace:]

p.write_text(s)
PY

grep -q 'DbSet<AuthRefreshToken>' "$CTX" \
  || die "AuthRefreshToken DbSet missing"

grep -q 'auth_refresh_tokens' "$CTX" \
  || die "auth_refresh_tokens mapping missing"

echo "refresh_token_dbcontext_patch=PASS"

echo
echo "=== 6. ADD SECURITY APPLICATION CONTRACTS ==="

mkdir -p "$APP/Security"

cat > "$APP/Security/LoginCommand.cs" <<'CS'
namespace QFLM.Application.Security;

public sealed record LoginCommand
{
    public required string Username { get; init; }

    public required string Password { get; init; }

    public string? ClientIp { get; init; }
}
CS

cat > "$APP/Security/LoginResult.cs" <<'CS'
namespace QFLM.Application.Security;

public sealed record LoginResult
{
    public required Guid UserId { get; init; }

    public required string Username { get; init; }

    public required string AccessToken { get; init; }

    public required DateTime AccessTokenExpiresAtUtc { get; init; }

    public required string RefreshToken { get; init; }

    public required DateTime RefreshTokenExpiresAtUtc { get; init; }

    public required IReadOnlyCollection<string> Roles { get; init; }

    public required IReadOnlyCollection<string> Permissions { get; init; }
}
CS

cat > "$APP/Security/IAuthenticationService.cs" <<'CS'
namespace QFLM.Application.Security;

public interface IAuthenticationService
{
    Task<LoginResult> LoginAsync(
        LoginCommand command,
        CancellationToken cancellationToken = default);
}
CS

echo "security_application_contracts=CREATED"

echo
echo "=== 7. ADD PASSWORD HASHER ==="

mkdir -p "$INFRA/Security"

cat > "$INFRA/Security/Pbkdf2PasswordHasher.cs" <<'CS'
using System.Security.Cryptography;

namespace QFLM.Infrastructure.Security;

public sealed class Pbkdf2PasswordHasher
{
    private const int Iterations = 210_000;
    private const int SaltBytes = 16;
    private const int HashBytes = 32;

    public string Hash(string password)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(password);

        var salt =
            RandomNumberGenerator.GetBytes(SaltBytes);

        var hash =
            Rfc2898DeriveBytes.Pbkdf2(
                password,
                salt,
                Iterations,
                HashAlgorithmName.SHA512,
                HashBytes);

        return string.Join(
            "$",
            "PBKDF2-SHA512",
            Iterations.ToString(),
            Convert.ToBase64String(salt),
            Convert.ToBase64String(hash));
    }

    public bool Verify(
        string password,
        string encodedHash)
    {
        if (string.IsNullOrWhiteSpace(password) ||
            string.IsNullOrWhiteSpace(encodedHash))
        {
            return false;
        }

        var parts =
            encodedHash.Split('$');

        if (parts.Length != 4 ||
            !string.Equals(
                parts[0],
                "PBKDF2-SHA512",
                StringComparison.Ordinal) ||
            !int.TryParse(
                parts[1],
                out var iterations) ||
            iterations < 100_000)
        {
            return false;
        }

        try
        {
            var salt =
                Convert.FromBase64String(
                    parts[2]);

            var expected =
                Convert.FromBase64String(
                    parts[3]);

            var actual =
                Rfc2898DeriveBytes.Pbkdf2(
                    password,
                    salt,
                    iterations,
                    HashAlgorithmName.SHA512,
                    expected.Length);

            return
                CryptographicOperations
                    .FixedTimeEquals(
                        actual,
                        expected);
        }
        catch (FormatException)
        {
            return false;
        }
    }
}
CS

echo "password_hasher=CREATED"

echo
echo "=== 8. ADD STANDARD HS256 JWT SERVICE ==="

cat > "$INFRA/Security/JwtTokenService.cs" <<'CS'
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace QFLM.Infrastructure.Security;

public sealed record JwtIssueResult(
    string Token,
    DateTime ExpiresAtUtc);

public sealed class JwtTokenService
{
    private readonly byte[] _signingKey;
    private readonly string _issuer;
    private readonly string _audience;
    private readonly TimeSpan _accessLifetime;

    public JwtTokenService(
        string base64SigningKey,
        string issuer,
        string audience,
        TimeSpan accessLifetime)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(
            base64SigningKey);

        ArgumentException.ThrowIfNullOrWhiteSpace(
            issuer);

        ArgumentException.ThrowIfNullOrWhiteSpace(
            audience);

        _signingKey =
            Convert.FromBase64String(
                base64SigningKey);

        if (_signingKey.Length < 32)
        {
            throw new ArgumentException(
                "JWT signing key must be at least 256 bits.",
                nameof(base64SigningKey));
        }

        _issuer = issuer;
        _audience = audience;
        _accessLifetime = accessLifetime;
    }

    public JwtIssueResult Issue(
        Guid userId,
        string username,
        IReadOnlyCollection<string> roles,
        IReadOnlyCollection<string> permissions)
    {
        var now = DateTime.UtcNow;
        var expires =
            now.Add(_accessLifetime);

        var header =
            new Dictionary<string, object?>
            {
                ["alg"] = "HS256",
                ["typ"] = "JWT"
            };

        var payload =
            new Dictionary<string, object?>
            {
                ["sub"] = userId.ToString(),
                ["name"] = username,
                ["roles"] = roles,
                ["permissions"] = permissions,
                ["jti"] = Guid.NewGuid().ToString("N"),
                ["iss"] = _issuer,
                ["aud"] = _audience,
                ["iat"] =
                    new DateTimeOffset(now)
                        .ToUnixTimeSeconds(),
                ["nbf"] =
                    new DateTimeOffset(now)
                        .ToUnixTimeSeconds(),
                ["exp"] =
                    new DateTimeOffset(expires)
                        .ToUnixTimeSeconds()
            };

        var encodedHeader =
            Base64Url(
                JsonSerializer.SerializeToUtf8Bytes(
                    header));

        var encodedPayload =
            Base64Url(
                JsonSerializer.SerializeToUtf8Bytes(
                    payload));

        var signingInput =
            Encoding.ASCII.GetBytes(
                encodedHeader + "." +
                encodedPayload);

        using var hmac =
            new HMACSHA256(
                _signingKey);

        var signature =
            Base64Url(
                hmac.ComputeHash(
                    signingInput));

        return new JwtIssueResult(
            encodedHeader + "." +
            encodedPayload + "." +
            signature,
            expires);
    }

    public bool ValidateSignature(
        string token)
    {
        var parts =
            token.Split('.');

        if (parts.Length != 3)
            return false;

        var signingInput =
            Encoding.ASCII.GetBytes(
                parts[0] + "." +
                parts[1]);

        using var hmac =
            new HMACSHA256(
                _signingKey);

        var expected =
            Base64Url(
                hmac.ComputeHash(
                    signingInput));

        var left =
            Encoding.ASCII.GetBytes(
                expected);

        var right =
            Encoding.ASCII.GetBytes(
                parts[2]);

        return
            left.Length == right.Length &&
            CryptographicOperations
                .FixedTimeEquals(
                    left,
                    right);
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
}
CS

echo "jwt_service=CREATED"

echo
echo "=== 9. ADD AUTHENTICATION SERVICE ==="

cat > "$INFRA/Security/EfAuthenticationService.cs" <<'CS'
using System.Security.Cryptography;
using Microsoft.EntityFrameworkCore;
using QFLM.Application.Security;
using QFLM.Domain.Security;
using QFLM.Infrastructure.Persistence;

namespace QFLM.Infrastructure.Security;

public sealed class EfAuthenticationService
    : IAuthenticationService
{
    private const int MaxFailedAttempts = 5;

    private static readonly TimeSpan LockoutDuration =
        TimeSpan.FromMinutes(15);

    private static readonly TimeSpan RefreshTokenLifetime =
        TimeSpan.FromDays(30);

    private readonly QflmDbContext _dbContext;
    private readonly Pbkdf2PasswordHasher _passwordHasher;
    private readonly JwtTokenService _jwtTokenService;

    public EfAuthenticationService(
        QflmDbContext dbContext,
        Pbkdf2PasswordHasher passwordHasher,
        JwtTokenService jwtTokenService)
    {
        _dbContext = dbContext;
        _passwordHasher = passwordHasher;
        _jwtTokenService = jwtTokenService;
    }

    public async Task<LoginResult> LoginAsync(
        LoginCommand command,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(
            command.Username);

        ArgumentException.ThrowIfNullOrWhiteSpace(
            command.Password);

        var normalized =
            command.Username
                .Trim()
                .ToUpperInvariant();

        var now = DateTime.UtcNow;

        var user =
            await _dbContext.AuthUsers
                .SingleOrDefaultAsync(
                    x =>
                        x.NormalizedUsername ==
                        normalized,
                    cancellationToken);

        if (user is null)
        {
            throw new UnauthorizedAccessException(
                "Invalid credentials.");
        }

        if (!user.IsActive)
        {
            throw new UnauthorizedAccessException(
                "Account is inactive.");
        }

        if (user.LockoutEndUtc.HasValue &&
            user.LockoutEndUtc.Value > now)
        {
            throw new UnauthorizedAccessException(
                "Account is locked.");
        }

        if (!_passwordHasher.Verify(
                command.Password,
                user.PasswordHash))
        {
            user.FailedAccessAttempts =
                checked(
                    user.FailedAccessAttempts +
                    1);

            if (user.FailedAccessAttempts >=
                MaxFailedAttempts)
            {
                user.LockoutEndUtc =
                    now.Add(
                        LockoutDuration);
            }

            await _dbContext
                .SaveChangesAsync(
                    cancellationToken);

            throw new UnauthorizedAccessException(
                "Invalid credentials.");
        }

        user.FailedAccessAttempts = 0;
        user.LockoutEndUtc = null;
        user.LastLoginAtUtc = now;

        var roles =
            await (
                from ur in _dbContext.AuthUserRoles
                join role in _dbContext.AuthRoles
                    on ur.RoleId equals role.Id
                where ur.UserId == user.Id
                orderby role.NormalizedName
                select role.Name
            )
            .Distinct()
            .ToListAsync(
                cancellationToken);

        var permissions =
            await (
                from ur in _dbContext.AuthUserRoles
                join rp in
                    _dbContext.AuthRolePermissions
                    on ur.RoleId equals rp.RoleId
                join permission in
                    _dbContext.AuthPermissions
                    on rp.PermissionId equals
                    permission.Id
                where ur.UserId == user.Id
                orderby permission.Code
                select permission.Code
            )
            .Distinct()
            .ToListAsync(
                cancellationToken);

        var access =
            _jwtTokenService.Issue(
                user.Id,
                user.Username,
                roles,
                permissions);

        var refreshToken =
            Convert.ToBase64String(
                RandomNumberGenerator
                    .GetBytes(48));

        var refreshTokenHash =
            Convert.ToHexString(
                SHA256.HashData(
                    System.Text.Encoding.UTF8
                        .GetBytes(
                            refreshToken)))
                .ToLowerInvariant();

        var refreshExpires =
            now.Add(
                RefreshTokenLifetime);

        _dbContext.AuthRefreshTokens.Add(
            new AuthRefreshToken
            {
                UserId = user.Id,
                TokenHash =
                    refreshTokenHash,
                ExpiresAtUtc =
                    refreshExpires,
                CreatedByIp =
                    command.ClientIp
            });

        await _dbContext
            .SaveChangesAsync(
                cancellationToken);

        return new LoginResult
        {
            UserId =
                user.Id,
            Username =
                user.Username,
            AccessToken =
                access.Token,
            AccessTokenExpiresAtUtc =
                access.ExpiresAtUtc,
            RefreshToken =
                refreshToken,
            RefreshTokenExpiresAtUtc =
                refreshExpires,
            Roles =
                roles,
            Permissions =
                permissions
        };
    }
}
CS

echo "authentication_service=CREATED"

echo
echo "=== 10. RELEASE BUILD BEFORE MIGRATION ==="

dotnet build QuikeFix.LicenseManager.slnx \
  -c Release \
  || die "pre-migration build failed"

echo "pre_migration_build=PASS"

echo
echo "=== 11. GENERATE REFRESH TOKEN MIGRATION ==="

dotnet tool restore >/dev/null \
  || die "dotnet tool restore failed"

BEFORE_COUNT=$(find "$MIGDIR" -maxdepth 1 \
  -type f -name '*_*.cs' ! -name '*.Designer.cs' \
  | wc -l | xargs)

dotnet tool run dotnet-ef migrations add AddAuthRefreshTokens \
  --project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj \
  --startup-project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj \
  --context QflmDbContext \
  --output-dir Persistence/Migrations \
  || die "refresh-token migration generation failed"

AFTER_COUNT=$(find "$MIGDIR" -maxdepth 1 \
  -type f -name '*_*.cs' ! -name '*.Designer.cs' \
  | wc -l | xargs)

echo "migration_count_before=$BEFORE_COUNT after=$AFTER_COUNT"

[ "$AFTER_COUNT" -eq $((BEFORE_COUNT + 1)) ] \
  || die "expected exactly one new refresh-token migration"

MIG15C=$(find "$MIGDIR" -maxdepth 1 -type f \
  -name '*_AddAuthRefreshTokens.cs' | sort | tail -n1)

[ -s "$MIG15C" ] \
  || die "refresh-token migration missing"

grep -q 'auth_refresh_tokens' "$MIG15C" \
  || die "auth_refresh_tokens missing from migration"

echo "refresh_token_migration=$(basename "$MIG15C")"

echo
echo "=== 12. POST-MIGRATION RELEASE BUILD ==="

dotnet build QuikeFix.LicenseManager.slnx \
  -c Release --no-restore \
  || die "post-migration build failed"

echo "post_migration_build=PASS"

echo
echo "=== 13. GENERATE IDEMPOTENT AUTH MIGRATION SQL ==="

dotnet tool run dotnet-ef migrations script \
  --project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj \
  --startup-project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj \
  --context QflmDbContext \
  --idempotent \
  --output "$MIGSQL" \
  || die "auth migration SQL generation failed"

[ -s "$MIGSQL" ] || die "auth migration SQL empty"

for table in \
  auth_users \
  auth_roles \
  auth_permissions \
  auth_user_roles \
  auth_role_permissions \
  auth_refresh_tokens
do
  grep -q "$table" "$MIGSQL" \
    || die "$table missing from migration SQL"
done

echo "migration_sql=$MIGSQL"
echo "migration_sql_sha256=$(sha256sum "$MIGSQL" | awk '{print $1}')"

echo
echo "=== 14. REBUILD ISOLATED DATABASE ==="

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

ISO_BEFORE=$(docker exec "$PG" psql \
  -U qflm \
  -d "$ISO_DB" \
  -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' \
  | xargs)

echo "isolated_migrations_before=$ISO_BEFORE"

[ "$ISO_BEFORE" = 3 ] \
  || die "isolated baseline migration count must be 3"

echo
echo "=== 15. APPLY AUTH MIGRATIONS TO ISOLATED DB ==="

cat "$MIGSQL" \
  | docker exec -i "$PG" psql \
      -U qflm \
      -d "$ISO_DB" \
      -v ON_ERROR_STOP=1 \
      >/dev/null \
  || die "isolated auth migrations failed"

ISO_AFTER=$(docker exec "$PG" psql \
  -U qflm \
  -d "$ISO_DB" \
  -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' \
  | xargs)

echo "isolated_migrations_after=$ISO_AFTER"

[ "$ISO_AFTER" = 5 ] \
  || die "isolated migration history did not reach 5"

AUTH_TABLE_COUNT=$(docker exec "$PG" psql \
  -U qflm \
  -d "$ISO_DB" \
  -tAc "
SELECT count(*)
FROM information_schema.tables
WHERE table_schema='public'
AND table_name LIKE 'auth_%';
" | xargs)

echo "isolated_auth_tables=$AUTH_TABLE_COUNT"

[ "$AUTH_TABLE_COUNT" = 6 ] \
  || die "expected 6 isolated auth tables"

echo
echo "=== 16. CREATE AUTHENTICATION TEST HARNESS ==="

rm -rf "$HARNESS"
mkdir -p "$HARNESS"

cat > "$HARNESS/QFLM.Recovery6B.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>

  <ItemGroup>
    <ProjectReference Include="../../src/QFLM.Application/QFLM.Application.csproj" />
    <ProjectReference Include="../../src/QFLM.Domain/QFLM.Domain.csproj" />
    <ProjectReference Include="../../src/QFLM.Infrastructure/QFLM.Infrastructure.csproj" />
  </ItemGroup>
</Project>
XML

cat > "$HARNESS/Program.cs" <<'CS'
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using QFLM.Application.Security;
using QFLM.Domain.Security;
using QFLM.Infrastructure.Persistence;
using QFLM.Infrastructure.Security;

static string Required(string name) =>
    Environment.GetEnvironmentVariable(name)
    ?? throw new InvalidOperationException(
        $"Missing environment variable {name}.");

var connection =
    Required("QFLM_TEST_CONNECTION");

var jwtKey =
    Required("QFLM_TEST_JWT_KEY");

var password =
    Required("QFLM_TEST_PASSWORD");

var options =
    new DbContextOptionsBuilder<QflmDbContext>()
        .UseNpgsql(connection)
        .UseSnakeCaseNamingConvention()
        .Options;

await using var db =
    new QflmDbContext(options);

await db.AuthRefreshTokens.ExecuteDeleteAsync();
await db.AuthRolePermissions.ExecuteDeleteAsync();
await db.AuthUserRoles.ExecuteDeleteAsync();
await db.AuthPermissions.ExecuteDeleteAsync();
await db.AuthRoles.ExecuteDeleteAsync();
await db.AuthUsers.ExecuteDeleteAsync();

var passwordHasher =
    new Pbkdf2PasswordHasher();

var encodedHash =
    passwordHasher.Hash(password);

if (!passwordHasher.Verify(
        password,
        encodedHash))
{
    throw new InvalidOperationException(
        "Password hash verification failed.");
}

if (passwordHasher.Verify(
        password + "-wrong",
        encodedHash))
{
    throw new InvalidOperationException(
        "Wrong password unexpectedly verified.");
}

Console.WriteLine("password_hashing=PASS");

var admin =
    new AuthUser
    {
        Username =
            "phase15-admin",
        NormalizedUsername =
            "PHASE15-ADMIN",
        Email =
            "phase15-admin@example.invalid",
        NormalizedEmail =
            "PHASE15-ADMIN@EXAMPLE.INVALID",
        PasswordHash =
            encodedHash,
        IsActive =
            true,
        EmailConfirmed =
            true,
        SecurityStamp =
            Guid.NewGuid().ToString("N")
    };

var role =
    new AuthRole
    {
        Name =
            "Platform Administrator",
        NormalizedName =
            "PLATFORM ADMINISTRATOR",
        Description =
            "Phase 15 isolated administrator",
        IsSystem =
            true
    };

var permission1 =
    new AuthPermission
    {
        Code =
            "licensing.manage",
        Name =
            "Manage Licensing",
        Category =
            "Licensing",
        IsSystem =
            true
    };

var permission2 =
    new AuthPermission
    {
        Code =
            "offline.issue",
        Name =
            "Issue Offline Licenses",
        Category =
            "Offline Licensing",
        IsSystem =
            true
    };

db.AuthUsers.Add(admin);
db.AuthRoles.Add(role);

db.AuthPermissions.AddRange(
    permission1,
    permission2);

db.AuthUserRoles.Add(
    new AuthUserRole
    {
        UserId =
            admin.Id,
        RoleId =
            role.Id
    });

db.AuthRolePermissions.AddRange(
    new AuthRolePermission
    {
        RoleId =
            role.Id,
        PermissionId =
            permission1.Id
    },
    new AuthRolePermission
    {
        RoleId =
            role.Id,
        PermissionId =
            permission2.Id
    });

await db.SaveChangesAsync();

var jwt =
    new JwtTokenService(
        jwtKey,
        "qflm",
        "qflm-admin",
        TimeSpan.FromMinutes(15));

var auth =
    new EfAuthenticationService(
        db,
        passwordHasher,
        jwt);

var login =
    await auth.LoginAsync(
        new LoginCommand
        {
            Username =
                "phase15-admin",
            Password =
                password,
            ClientIp =
                "127.0.0.1"
        });

Console.WriteLine(
    $"login_success=PASS roles={login.Roles.Count} permissions={login.Permissions.Count}");

if (login.Roles.Count != 1 ||
    !login.Roles.Contains(
        "Platform Administrator"))
{
    throw new InvalidOperationException(
        "Role resolution failed.");
}

if (login.Permissions.Count != 2 ||
    !login.Permissions.Contains(
        "licensing.manage") ||
    !login.Permissions.Contains(
        "offline.issue"))
{
    throw new InvalidOperationException(
        "Permission resolution failed.");
}

if (!jwt.ValidateSignature(
        login.AccessToken))
{
    throw new InvalidOperationException(
        "JWT signature validation failed.");
}

var tokenParts =
    login.AccessToken.Split('.');

if (tokenParts.Length != 3)
{
    throw new InvalidOperationException(
        "JWT structure invalid.");
}

static byte[] Base64UrlDecode(
    string value)
{
    var s =
        value
            .Replace('-', '+')
            .Replace('_', '/');

    s += (s.Length % 4) switch
    {
        2 => "==",
        3 => "=",
        _ => ""
    };

    return Convert.FromBase64String(s);
}

using var payload =
    JsonDocument.Parse(
        Base64UrlDecode(
            tokenParts[1]));

var root =
    payload.RootElement;

if (root.GetProperty("sub")
        .GetString() !=
    admin.Id.ToString())
{
    throw new InvalidOperationException(
        "JWT subject mismatch.");
}

var permissionClaims =
    root.GetProperty("permissions")
        .EnumerateArray()
        .Select(x => x.GetString())
        .Where(x => x is not null)
        .ToArray();

if (!permissionClaims.Contains(
        "offline.issue"))
{
    throw new InvalidOperationException(
        "JWT permission claim missing.");
}

Console.WriteLine(
    "jwt_issue_and_signature=PASS");

Console.WriteLine(
    "jwt_rbac_claims=PASS");

var refreshHash =
    Convert.ToHexString(
        SHA256.HashData(
            Encoding.UTF8.GetBytes(
                login.RefreshToken)))
        .ToLowerInvariant();

var persisted =
    await db.AuthRefreshTokens
        .SingleAsync(
            x => x.UserId == admin.Id);

if (!string.Equals(
        persisted.TokenHash,
        refreshHash,
        StringComparison.Ordinal))
{
    throw new InvalidOperationException(
        "Refresh-token hash mismatch.");
}

if (string.Equals(
        persisted.TokenHash,
        login.RefreshToken,
        StringComparison.Ordinal))
{
    throw new InvalidOperationException(
        "Raw refresh token was persisted.");
}

Console.WriteLine(
    "refresh_token_hash_persistence=PASS");

Console.WriteLine(
    "raw_refresh_token_persisted=NO");

var wrongPasswordRejected =
    false;

try
{
    await auth.LoginAsync(
        new LoginCommand
        {
            Username =
                "phase15-admin",
            Password =
                password + "-wrong"
        });
}
catch (UnauthorizedAccessException)
{
    wrongPasswordRejected = true;
}

if (!wrongPasswordRejected)
{
    throw new InvalidOperationException(
        "Wrong password was not rejected.");
}

await db.Entry(admin)
    .ReloadAsync();

if (admin.FailedAccessAttempts != 1)
{
    throw new InvalidOperationException(
        "Failed login count did not increment.");
}

Console.WriteLine(
    "wrong_password_rejection=PASS");

Console.WriteLine(
    "failed_login_counter=PASS");

for (var i = 0; i < 4; i++)
{
    try
    {
        await auth.LoginAsync(
            new LoginCommand
            {
                Username =
                    "phase15-admin",
                Password =
                    password + "-wrong"
            });
    }
    catch (UnauthorizedAccessException)
    {
    }
}

await db.Entry(admin)
    .ReloadAsync();

if (admin.FailedAccessAttempts != 5 ||
    !admin.LockoutEndUtc.HasValue ||
    admin.LockoutEndUtc <= DateTime.UtcNow)
{
    throw new InvalidOperationException(
        "Lockout policy did not activate.");
}

Console.WriteLine(
    "lockout_after_five_failures=PASS");

var lockedRejected =
    false;

try
{
    await auth.LoginAsync(
        new LoginCommand
        {
            Username =
                "phase15-admin",
            Password =
                password
        });
}
catch (UnauthorizedAccessException)
{
    lockedRejected = true;
}

if (!lockedRejected)
{
    throw new InvalidOperationException(
        "Locked account was not rejected.");
}

Console.WriteLine(
    "locked_account_rejection=PASS");

admin.LockoutEndUtc = null;
admin.FailedAccessAttempts = 0;
admin.IsActive = false;

await db.SaveChangesAsync();

var inactiveRejected =
    false;

try
{
    await auth.LoginAsync(
        new LoginCommand
        {
            Username =
                "phase15-admin",
            Password =
                password
        });
}
catch (UnauthorizedAccessException)
{
    inactiveRejected = true;
}

if (!inactiveRejected)
{
    throw new InvalidOperationException(
        "Inactive account was not rejected.");
}

Console.WriteLine(
    "inactive_account_rejection=PASS");

Console.WriteLine(
    "RECOVERY6B_HARNESS=PASS");
CS

echo "harness=CREATED"

echo
echo "=== 17. BUILD HARNESS ==="

dotnet build \
  "$HARNESS/QFLM.Recovery6B.csproj" \
  -c Release \
  || die "Phase 15C harness build failed"

echo "harness_build=PASS"

echo
echo "=== 18. RUN ISOLATED AUTHENTICATION TESTS ==="

PG_IP=$(docker inspect "$PG" \
  --format="{{(index .NetworkSettings.Networks \"qflm_backend\").IPAddress}}")

[ -n "$PG_IP" ] \
  || die "PostgreSQL qflm_backend IP unavailable"

JWT_KEY="$(openssl rand -base64 48)"
TEST_PASSWORD="$(openssl rand -base64 30 | tr -d '\n')"

export QFLM_TEST_CONNECTION="Host=$PG_IP;Port=5432;Database=$ISO_DB;Username=qflm;Password=$(cat /opt/qflm/secrets/runtime-api/postgres_password);SSL Mode=Disable"
export QFLM_TEST_JWT_KEY="$JWT_KEY"
export QFLM_TEST_PASSWORD="$TEST_PASSWORD"

dotnet run \
  --project "$HARNESS/QFLM.Recovery6B.csproj" \
  -c Release \
  --no-build \
  || die "Phase 15C harness failed"

unset QFLM_TEST_CONNECTION
unset QFLM_TEST_JWT_KEY
unset QFLM_TEST_PASSWORD
unset JWT_KEY
unset TEST_PASSWORD

echo
echo "=== 19. ISOLATED DATABASE RESULTS ==="

UCOUNT=$(docker exec "$PG" psql \
  -U qflm \
  -d "$ISO_DB" \
  -tAc 'SELECT count(*) FROM auth_users;' \
  | xargs)

RCOUNT=$(docker exec "$PG" psql \
  -U qflm \
  -d "$ISO_DB" \
  -tAc 'SELECT count(*) FROM auth_roles;' \
  | xargs)

PCOUNT=$(docker exec "$PG" psql \
  -U qflm \
  -d "$ISO_DB" \
  -tAc 'SELECT count(*) FROM auth_permissions;' \
  | xargs)

RTCOUNT=$(docker exec "$PG" psql \
  -U qflm \
  -d "$ISO_DB" \
  -tAc 'SELECT count(*) FROM auth_refresh_tokens;' \
  | xargs)

NON_SHA256=$(docker exec "$PG" psql \
  -U qflm \
  -d "$ISO_DB" \
  -tAc "
SELECT count(*)
FROM auth_refresh_tokens
WHERE length(token_hash) <> 64;
" | xargs)

echo "users=$UCOUNT roles=$RCOUNT permissions=$PCOUNT refresh_tokens=$RTCOUNT non_sha256_refresh_hashes=$NON_SHA256"

[ "$UCOUNT" = 1 ] || die "isolated auth user count invalid"
[ "$RCOUNT" = 1 ] || die "isolated role count invalid"
[ "$PCOUNT" = 2 ] || die "isolated permission count invalid"
[ "$RTCOUNT" = 1 ] || die "isolated refresh token count invalid"
[ "$NON_SHA256" = 0 ] || die "refresh token hash storage invalid"

echo
echo "=== 20. PRODUCTION FINAL SAFETY ==="

PIMG=$(docker inspect "$API" --format='{{.Config.Image}}')
PRUN=$(docker inspect "$API" --format='{{.State.Running}}')
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

[ "$PIMG" = "$IMG" ] || die "production image changed"
[ "$PRUN" = true ] || die "production API stopped"
[ "$PMIG" = "$MIG" ] || die "production migration count changed"
[ "$PROD_AUTH_TABLES" = 0 ] || die "auth tables unexpectedly appeared in production"
[ "$PLIC" = "$LIC" ] || die "production license count changed"
[ "$PINST" = "$INST" ] || die "production installation count changed"

COMPLETED=1

echo
echo "======================================================"
echo " QFLM RECOVERY 6B PASSED"
echo "======================================================"
echo "PBKDF2-SHA512 PASSWORD HASHING:    PASS"
echo "PASSWORD FIXED-TIME VERIFICATION:  PASS"
echo "LOGIN SERVICE:                     PASS"
echo "ROLE RESOLUTION:                   PASS"
echo "PERMISSION RESOLUTION:             PASS"
echo "HS256 JWT FOUNDATION:              PASS"
echo "JWT RBAC CLAIMS:                   PASS"
echo "REFRESH TOKEN STORAGE:             HASH ONLY"
echo "WRONG PASSWORD REJECTION:          PASS"
echo "FAILED LOGIN COUNTER:              PASS"
echo "LOCKOUT AFTER 5 FAILURES:          PASS"
echo "LOCKED ACCOUNT REJECTION:          PASS"
echo "INACTIVE ACCOUNT REJECTION:        PASS"
echo "PRODUCTION DATABASE:               UNCHANGED"
echo "PRODUCTION API/COMPOSE:            UNCHANGED"
echo "REPORT:                            $REPORT"
echo "NEXT: RECOVERY 6C - JWT BEARER MIDDLEWARE + AUTH/RBAC API ROUTES"
echo "======================================================"