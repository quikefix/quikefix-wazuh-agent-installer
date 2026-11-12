#!/usr/bin/env bash
# QFLM RECOVERY 6F2
# Admin user/role/permission management API, isolated only.
# Production API/DB/Compose remain unchanged.

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
ISO_DB="qflm_recovery6f2_test"
ISO_API="qflm-api-recovery6f2-test"
NET="qflm_backend"

EXPECTED_IMAGE="qflm-api:recovery6e2-candidate"
ISO_IMAGE="qflm-api:recovery6f2-candidate"

BOOT_USER_FILE="/opt/qflm/secrets/auth/bootstrap-admin-username"
BOOT_PASS_FILE="/opt/qflm/secrets/auth/bootstrap-admin-password"
RUNTIME_JWT="/opt/qflm/secrets/runtime-api/jwt-signing-key"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery6f2-$STAMP"
REPORT="$BACKUP/recovery6f2-report.txt"
SOURCE_BACKUP="$BACKUP/source-before-phase15f2.tgz"
DB_DUMP="$BACKUP/qflm-before-recovery6f2.dump"
ENV_FILE="$BACKUP/isolated-api.env"
PUBLISH="$ROOT/artifacts/api-publish-recovery6f2"
DOCKERFILE="$ROOT/Dockerfile.recovery6f2"

MUTATED=0
COMPLETED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

cleanup(){
    docker rm -f "$ISO_API" >/dev/null 2>&1 || true

    if [ "$COMPLETED" -ne 1 ] && [ "$MUTATED" -eq 1 ] && [ -s "$SOURCE_BACKUP" ]; then
        printf '\n=== SOURCE ROLLBACK ===\n'
        rm -f "$APP/Security/SecurityAdminModels.cs"
        rm -f "$APP/Security/ISecurityAdministrationService.cs"
        rm -f "$INFRA/Security/EfSecurityAdministrationService.cs"
        rm -f "$API_SRC/Controllers/AdminSecurityManagementController.cs"
        tar -xzf "$SOURCE_BACKUP" -C "$ROOT" >/dev/null 2>&1 || true
        printf '%s\n' "source_restore_attempted=YES"
    fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 6F2"
printf '%s\n' " ADMIN USER / ROLE / PERMISSION MANAGEMENT API"
printf '%s\n' " ISOLATED"
printf '%s\n' "======================================================"

printf '\n=== 1. PRODUCTION BASELINE ===\n'

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

[ "$IMG" = "$EXPECTED_IMAGE" ] || die "unexpected production API image"
[ "$RUN" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected production migration count"
[ "$AUTH_TABLES" = 6 ] || die "unexpected production auth table count"
[ -s "$BOOT_USER_FILE" ] || die "bootstrap username file missing"
[ -s "$BOOT_PASS_FILE" ] || die "bootstrap password file missing"
[ -s "$RUNTIME_JWT" ] || die "JWT runtime secret missing"

printf '%s\n' "production_baseline=PASS"

printf '\n=== 2. BACKUP SOURCE + DATABASE ===\n'

tar -czf "$SOURCE_BACKUP" -C "$ROOT" \
  "src/QFLM.Api" \
  "src/QFLM.Application" \
  "src/QFLM.Infrastructure/Security" \
  || die "source backup failed"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" -Fc > "$DB_DUMP" \
  || die "production DB backup failed"

[ -s "$DB_DUMP" ] || die "database backup empty"

printf 'source_backup_sha256=%s\n' "$(sha256sum "$SOURCE_BACKUP" | awk '{print $1}')"
printf 'database_backup_sha256=%s\n' "$(sha256sum "$DB_DUMP" | awk '{print $1}')"

MUTATED=1

printf '\n=== 3. ADD APPLICATION SECURITY ADMIN MODELS ===\n'

mkdir -p "$APP/Security"

cat > "$APP/Security/SecurityAdminModels.cs" <<'CS'
namespace QFLM.Application.Security;

public sealed record SecurityUserSummary(
    Guid Id,
    string Username,
    string? Email,
    bool IsActive,
    bool EmailConfirmed,
    int FailedAccessAttempts,
    DateTime? LockoutEndUtc,
    DateTime? LastLoginAtUtc,
    IReadOnlyList<string> Roles);

public sealed record SecurityRoleSummary(
    Guid Id,
    string Name,
    string? Description,
    bool IsSystem,
    IReadOnlyList<string> Permissions);

public sealed record SecurityPermissionSummary(
    Guid Id,
    string Code,
    string Name,
    string Category,
    string? Description,
    bool IsSystem);

public sealed record CreateSecurityUserCommand
{
    public required string Username { get; init; }
    public string? Email { get; init; }
    public required string Password { get; init; }
    public IReadOnlyList<Guid> RoleIds { get; init; } = Array.Empty<Guid>();
}

public sealed record CreateSecurityRoleCommand
{
    public required string Name { get; init; }
    public string? Description { get; init; }
    public IReadOnlyList<Guid> PermissionIds { get; init; } = Array.Empty<Guid>();
}

public sealed record SetSecurityUserStatusCommand
{
    public required bool IsActive { get; init; }
}

public sealed record SetSecurityUserRolesCommand
{
    public IReadOnlyList<Guid> RoleIds { get; init; } = Array.Empty<Guid>();
}

public sealed record SetSecurityRolePermissionsCommand
{
    public IReadOnlyList<Guid> PermissionIds { get; init; } = Array.Empty<Guid>();
}
CS

cat > "$APP/Security/ISecurityAdministrationService.cs" <<'CS'
namespace QFLM.Application.Security;

public interface ISecurityAdministrationService
{
    Task<IReadOnlyList<SecurityUserSummary>> GetUsersAsync(
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<SecurityRoleSummary>> GetRolesAsync(
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<SecurityPermissionSummary>> GetPermissionsAsync(
        CancellationToken cancellationToken = default);

    Task<SecurityUserSummary> CreateUserAsync(
        CreateSecurityUserCommand command,
        CancellationToken cancellationToken = default);

    Task<SecurityRoleSummary> CreateRoleAsync(
        CreateSecurityRoleCommand command,
        CancellationToken cancellationToken = default);

    Task SetUserStatusAsync(
        Guid userId,
        SetSecurityUserStatusCommand command,
        CancellationToken cancellationToken = default);

    Task SetUserRolesAsync(
        Guid userId,
        SetSecurityUserRolesCommand command,
        CancellationToken cancellationToken = default);

    Task SetRolePermissionsAsync(
        Guid roleId,
        SetSecurityRolePermissionsCommand command,
        CancellationToken cancellationToken = default);
}
CS

printf '%s\n' "security_admin_models=CREATED"

printf '\n=== 4. ADD EF SECURITY ADMINISTRATION SERVICE ===\n'

cat > "$INFRA/Security/EfSecurityAdministrationService.cs" <<'CS'
using Microsoft.EntityFrameworkCore;
using QFLM.Application.Security;
using QFLM.Domain.Security;
using QFLM.Infrastructure.Persistence;

namespace QFLM.Infrastructure.Security;

public sealed class EfSecurityAdministrationService
    : ISecurityAdministrationService
{
    private readonly QflmDbContext _db;
    private readonly Pbkdf2PasswordHasher _hasher;

    public EfSecurityAdministrationService(
        QflmDbContext db,
        Pbkdf2PasswordHasher hasher)
    {
        _db = db;
        _hasher = hasher;
    }

    public async Task<IReadOnlyList<SecurityUserSummary>> GetUsersAsync(
        CancellationToken cancellationToken = default)
    {
        var users = await _db.AuthUsers
            .AsNoTracking()
            .OrderBy(x => x.NormalizedUsername)
            .ToListAsync(cancellationToken);

        var userRoles = await (
            from ur in _db.AuthUserRoles.AsNoTracking()
            join r in _db.AuthRoles.AsNoTracking()
                on ur.RoleId equals r.Id
            select new { ur.UserId, r.Name }
        ).ToListAsync(cancellationToken);

        return users.Select(u =>
            new SecurityUserSummary(
                u.Id,
                u.Username,
                u.Email,
                u.IsActive,
                u.EmailConfirmed,
                u.FailedAccessAttempts,
                u.LockoutEndUtc,
                u.LastLoginAtUtc,
                userRoles
                    .Where(x => x.UserId == u.Id)
                    .Select(x => x.Name)
                    .OrderBy(x => x)
                    .ToArray()
            )).ToArray();
    }

    public async Task<IReadOnlyList<SecurityRoleSummary>> GetRolesAsync(
        CancellationToken cancellationToken = default)
    {
        var roles = await _db.AuthRoles
            .AsNoTracking()
            .OrderBy(x => x.NormalizedName)
            .ToListAsync(cancellationToken);

        var rolePermissions = await (
            from rp in _db.AuthRolePermissions.AsNoTracking()
            join p in _db.AuthPermissions.AsNoTracking()
                on rp.PermissionId equals p.Id
            select new { rp.RoleId, p.Code }
        ).ToListAsync(cancellationToken);

        return roles.Select(r =>
            new SecurityRoleSummary(
                r.Id,
                r.Name,
                r.Description,
                r.IsSystem,
                rolePermissions
                    .Where(x => x.RoleId == r.Id)
                    .Select(x => x.Code)
                    .OrderBy(x => x)
                    .ToArray()
            )).ToArray();
    }

    public async Task<IReadOnlyList<SecurityPermissionSummary>> GetPermissionsAsync(
        CancellationToken cancellationToken = default)
    {
        return await _db.AuthPermissions
            .AsNoTracking()
            .OrderBy(x => x.Category)
            .ThenBy(x => x.Code)
            .Select(x =>
                new SecurityPermissionSummary(
                    x.Id,
                    x.Code,
                    x.Name,
                    x.Category,
                    x.Description,
                    x.IsSystem))
            .ToListAsync(cancellationToken);
    }

    public async Task<SecurityUserSummary> CreateUserAsync(
        CreateSecurityUserCommand command,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(command.Username);
        ArgumentException.ThrowIfNullOrWhiteSpace(command.Password);

        var username = command.Username.Trim();
        var normalized = username.ToUpperInvariant();

        if (command.Password.Length < 14)
            throw new InvalidOperationException(
                "Password must contain at least 14 characters.");

        if (await _db.AuthUsers.AnyAsync(
                x => x.NormalizedUsername == normalized,
                cancellationToken))
            throw new InvalidOperationException(
                "Username already exists.");

        var roleIds = command.RoleIds
            .Distinct()
            .ToArray();

        if (roleIds.Length > 0)
        {
            var found = await _db.AuthRoles
                .CountAsync(
                    x => roleIds.Contains(x.Id),
                    cancellationToken);

            if (found != roleIds.Length)
                throw new InvalidOperationException(
                    "One or more roles do not exist.");
        }

        var email = string.IsNullOrWhiteSpace(command.Email)
            ? null
            : command.Email.Trim();

        var user = new AuthUser
        {
            Username = username,
            NormalizedUsername = normalized,
            Email = email,
            NormalizedEmail = email?.ToUpperInvariant(),
            PasswordHash = _hasher.Hash(command.Password),
            IsActive = true,
            EmailConfirmed = false,
            FailedAccessAttempts = 0,
            SecurityStamp = Guid.NewGuid().ToString("N")
        };

        _db.AuthUsers.Add(user);

        foreach (var roleId in roleIds)
        {
            _db.AuthUserRoles.Add(
                new AuthUserRole
                {
                    UserId = user.Id,
                    RoleId = roleId
                });
        }

        await _db.SaveChangesAsync(cancellationToken);

        var roleNames = await (
            from ur in _db.AuthUserRoles
            join r in _db.AuthRoles on ur.RoleId equals r.Id
            where ur.UserId == user.Id
            orderby r.Name
            select r.Name
        ).ToListAsync(cancellationToken);

        return new SecurityUserSummary(
            user.Id,
            user.Username,
            user.Email,
            user.IsActive,
            user.EmailConfirmed,
            user.FailedAccessAttempts,
            user.LockoutEndUtc,
            user.LastLoginAtUtc,
            roleNames);
    }

    public async Task<SecurityRoleSummary> CreateRoleAsync(
        CreateSecurityRoleCommand command,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(command.Name);

        var name = command.Name.Trim();
        var normalized = name.ToUpperInvariant();

        if (await _db.AuthRoles.AnyAsync(
                x => x.NormalizedName == normalized,
                cancellationToken))
            throw new InvalidOperationException(
                "Role already exists.");

        var permissionIds = command.PermissionIds
            .Distinct()
            .ToArray();

        if (permissionIds.Length > 0)
        {
            var found = await _db.AuthPermissions
                .CountAsync(
                    x => permissionIds.Contains(x.Id),
                    cancellationToken);

            if (found != permissionIds.Length)
                throw new InvalidOperationException(
                    "One or more permissions do not exist.");
        }

        var role = new AuthRole
        {
            Name = name,
            NormalizedName = normalized,
            Description = command.Description,
            IsSystem = false
        };

        _db.AuthRoles.Add(role);

        foreach (var permissionId in permissionIds)
        {
            _db.AuthRolePermissions.Add(
                new AuthRolePermission
                {
                    RoleId = role.Id,
                    PermissionId = permissionId
                });
        }

        await _db.SaveChangesAsync(cancellationToken);

        var permissionCodes = await (
            from rp in _db.AuthRolePermissions
            join p in _db.AuthPermissions
                on rp.PermissionId equals p.Id
            where rp.RoleId == role.Id
            orderby p.Code
            select p.Code
        ).ToListAsync(cancellationToken);

        return new SecurityRoleSummary(
            role.Id,
            role.Name,
            role.Description,
            role.IsSystem,
            permissionCodes);
    }

    public async Task SetUserStatusAsync(
        Guid userId,
        SetSecurityUserStatusCommand command,
        CancellationToken cancellationToken = default)
    {
        var user = await _db.AuthUsers
            .SingleOrDefaultAsync(
                x => x.Id == userId,
                cancellationToken)
            ?? throw new KeyNotFoundException(
                "User not found.");

        user.IsActive = command.IsActive;

        if (!command.IsActive)
        {
            var now = DateTime.UtcNow;

            var refreshTokens = await _db.AuthRefreshTokens
                .Where(x =>
                    x.UserId == userId &&
                    !x.RevokedAtUtc.HasValue)
                .ToListAsync(cancellationToken);

            foreach (var token in refreshTokens)
                token.RevokedAtUtc = now;
        }

        await _db.SaveChangesAsync(cancellationToken);
    }

    public async Task SetUserRolesAsync(
        Guid userId,
        SetSecurityUserRolesCommand command,
        CancellationToken cancellationToken = default)
    {
        if (!await _db.AuthUsers.AnyAsync(
                x => x.Id == userId,
                cancellationToken))
            throw new KeyNotFoundException(
                "User not found.");

        var roleIds = command.RoleIds
            .Distinct()
            .ToArray();

        var found = await _db.AuthRoles
            .CountAsync(
                x => roleIds.Contains(x.Id),
                cancellationToken);

        if (found != roleIds.Length)
            throw new InvalidOperationException(
                "One or more roles do not exist.");

        var existing = await _db.AuthUserRoles
            .Where(x => x.UserId == userId)
            .ToListAsync(cancellationToken);

        _db.AuthUserRoles.RemoveRange(existing);

        foreach (var roleId in roleIds)
        {
            _db.AuthUserRoles.Add(
                new AuthUserRole
                {
                    UserId = userId,
                    RoleId = roleId
                });
        }

        await _db.SaveChangesAsync(cancellationToken);
    }

    public async Task SetRolePermissionsAsync(
        Guid roleId,
        SetSecurityRolePermissionsCommand command,
        CancellationToken cancellationToken = default)
    {
        if (!await _db.AuthRoles.AnyAsync(
                x => x.Id == roleId,
                cancellationToken))
            throw new KeyNotFoundException(
                "Role not found.");

        var permissionIds = command.PermissionIds
            .Distinct()
            .ToArray();

        var found = await _db.AuthPermissions
            .CountAsync(
                x => permissionIds.Contains(x.Id),
                cancellationToken);

        if (found != permissionIds.Length)
            throw new InvalidOperationException(
                "One or more permissions do not exist.");

        var existing = await _db.AuthRolePermissions
            .Where(x => x.RoleId == roleId)
            .ToListAsync(cancellationToken);

        _db.AuthRolePermissions.RemoveRange(existing);

        foreach (var permissionId in permissionIds)
        {
            _db.AuthRolePermissions.Add(
                new AuthRolePermission
                {
                    RoleId = roleId,
                    PermissionId = permissionId
                });
        }

        await _db.SaveChangesAsync(cancellationToken);
    }
}
CS

printf '%s\n' "security_admin_service=CREATED"

printf '\n=== 5. ADD ADMIN SECURITY MANAGEMENT CONTROLLER ===\n'

cat > "$API_SRC/Controllers/AdminSecurityManagementController.cs" <<'CS'
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using QFLM.Application.Security;

namespace QFLM.Api.Controllers;

[ApiController]
[Route("api/v1/admin/security")]
[Authorize(Policy = "permission:security.admin")]
public sealed class AdminSecurityManagementController
    : ControllerBase
{
    private readonly ISecurityAdministrationService _service;

    public AdminSecurityManagementController(
        ISecurityAdministrationService service)
    {
        _service = service;
    }

    [HttpGet("users")]
    public async Task<IActionResult> Users(
        CancellationToken cancellationToken)
        => Ok(await _service.GetUsersAsync(cancellationToken));

    [HttpGet("roles")]
    public async Task<IActionResult> Roles(
        CancellationToken cancellationToken)
        => Ok(await _service.GetRolesAsync(cancellationToken));

    [HttpGet("permissions")]
    public async Task<IActionResult> Permissions(
        CancellationToken cancellationToken)
        => Ok(await _service.GetPermissionsAsync(cancellationToken));

    [HttpPost("users")]
    public async Task<IActionResult> CreateUser(
        [FromBody] CreateSecurityUserCommand command,
        CancellationToken cancellationToken)
    {
        try
        {
            return Ok(
                await _service.CreateUserAsync(
                    command,
                    cancellationToken));
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new
            {
                error = "SECURITY_ADMIN_VALIDATION",
                message = ex.Message
            });
        }
    }

    [HttpPost("roles")]
    public async Task<IActionResult> CreateRole(
        [FromBody] CreateSecurityRoleCommand command,
        CancellationToken cancellationToken)
    {
        try
        {
            return Ok(
                await _service.CreateRoleAsync(
                    command,
                    cancellationToken));
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new
            {
                error = "SECURITY_ADMIN_VALIDATION",
                message = ex.Message
            });
        }
    }

    [HttpPut("users/{userId:guid}/status")]
    public async Task<IActionResult> SetUserStatus(
        Guid userId,
        [FromBody] SetSecurityUserStatusCommand command,
        CancellationToken cancellationToken)
    {
        try
        {
            await _service.SetUserStatusAsync(
                userId,
                command,
                cancellationToken);

            return NoContent();
        }
        catch (KeyNotFoundException)
        {
            return NotFound();
        }
    }

    [HttpPut("users/{userId:guid}/roles")]
    public async Task<IActionResult> SetUserRoles(
        Guid userId,
        [FromBody] SetSecurityUserRolesCommand command,
        CancellationToken cancellationToken)
    {
        try
        {
            await _service.SetUserRolesAsync(
                userId,
                command,
                cancellationToken);

            return NoContent();
        }
        catch (KeyNotFoundException)
        {
            return NotFound();
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new
            {
                error = "SECURITY_ADMIN_VALIDATION",
                message = ex.Message
            });
        }
    }

    [HttpPut("roles/{roleId:guid}/permissions")]
    public async Task<IActionResult> SetRolePermissions(
        Guid roleId,
        [FromBody] SetSecurityRolePermissionsCommand command,
        CancellationToken cancellationToken)
    {
        try
        {
            await _service.SetRolePermissionsAsync(
                roleId,
                command,
                cancellationToken);

            return NoContent();
        }
        catch (KeyNotFoundException)
        {
            return NotFound();
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(new
            {
                error = "SECURITY_ADMIN_VALIDATION",
                message = ex.Message
            });
        }
    }
}
CS

printf '%s\n' "security_admin_controller=CREATED"

printf '\n=== 6. PATCH PROGRAM DI ===\n'

python3 - "$API_SRC/Program.cs" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
s=p.read_text()

if "EfSecurityAdministrationService" not in s:
    marker="builder.Services.AddSingleton<Pbkdf2PasswordHasher>();"
    pos=s.find(marker)
    if pos < 0:
        raise SystemExit("password hasher DI marker not found")

    block=(
        "builder.Services.AddScoped<\n"
        "    ISecurityAdministrationService,\n"
        "    EfSecurityAdministrationService>();\n\n"
    )

    s=s[:pos]+block+s[pos:]

p.write_text(s)
PY

grep -q 'EfSecurityAdministrationService' "$API_SRC/Program.cs" \
  || die "security administration DI missing"

printf '%s\n' "security_admin_di=PASS"

printf '\n=== 7. RELEASE BUILD ===\n'

dotnet build QuikeFix.LicenseManager.slnx -c Release \
  || die "Phase 15F.2 build failed"

printf '%s\n' "release_build=PASS"

printf '\n=== 8. BUILD ISOLATED PRODUCTION CLONE ===\n'

docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1 \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" >/dev/null

docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB"
docker exec "$PG" createdb -U qflm "$ISO_DB" \
  || die "isolated DB create failed"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges \
  | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null \
  || die "isolated DB clone failed"

ISO_MIG=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
ISO_AUTH=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name LIKE 'auth_%';" | xargs)

[ "$ISO_MIG" = 5 ] || die "isolated migration mismatch"
[ "$ISO_AUTH" = 6 ] || die "isolated auth table mismatch"

printf 'isolated_migrations=%s auth_tables=%s\n' "$ISO_MIG" "$ISO_AUTH"

printf '\n=== 9. PUBLISH + BUILD ISOLATED API ===\n'

rm -rf "$PUBLISH"

dotnet publish "$API_SRC/QFLM.Api.csproj" -c Release -o "$PUBLISH" \
  || die "publish failed"

cat > "$DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-recovery6f2/ ./
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

printf '\n=== 12. BOOTSTRAP ADMIN LOGIN ===\n'

BOOT_USER="$(cat "$BOOT_USER_FILE")"
BOOT_PASS="$(cat "$BOOT_PASS_FILE")"

LOGIN_JSON=$(python3 - "$BOOT_USER" "$BOOT_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)

LOGIN_RESPONSE=$(printf '%s' "$LOGIN_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -fsS -H 'Content-Type: application/json' \
      -X POST "http://$ISO_API:8080/api/v1/auth/login" \
      --data-binary @-) \
  || die "bootstrap admin login failed"

ADMIN_TOKEN=$(python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["accessToken"])
PY
)

[ -n "$ADMIN_TOKEN" ] || die "admin token missing"

printf '%s\n' "bootstrap_admin_login=PASS"

printf '\n=== 13. LIST USERS / ROLES / PERMISSIONS ===\n'

USERS_JSON=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -fsS -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://$ISO_API:8080/api/v1/admin/security/users") \
  || die "users list failed"

ROLES_JSON=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -fsS -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://$ISO_API:8080/api/v1/admin/security/roles") \
  || die "roles list failed"

PERMS_JSON=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -fsS -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://$ISO_API:8080/api/v1/admin/security/permissions") \
  || die "permissions list failed"

LIST_COUNTS=$(python3 - "$USERS_JSON" "$ROLES_JSON" "$PERMS_JSON" <<'PY'
import json,sys
u=json.loads(sys.argv[1])
r=json.loads(sys.argv[2])
p=json.loads(sys.argv[3])
print(f"{len(u)}|{len(r)}|{len(p)}")
PY
)

printf 'list_counts=%s\n' "$LIST_COUNTS"

printf '\n=== 14. CREATE LIMITED ROLE ===\n'

LIC_MANAGE_ID=$(python3 - "$PERMS_JSON" <<'PY'
import json,sys
for p in json.loads(sys.argv[1]):
    if p["code"]=="licensing.manage":
        print(p["id"])
        raise SystemExit(0)
raise SystemExit("licensing.manage permission not found")
PY
) || die "licensing.manage permission lookup failed"

ROLE_PAYLOAD=$(python3 - "$LIC_MANAGE_ID" <<'PY'
import json,sys
print(json.dumps({
  "name":"Licensing Operator Test",
  "description":"Phase 15F.2 isolated role",
  "permissionIds":[sys.argv[1]]
}))
PY
)

ROLE_RESPONSE=$(printf '%s' "$ROLE_PAYLOAD" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -fsS -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -X POST "http://$ISO_API:8080/api/v1/admin/security/roles" \
      --data-binary @-) \
  || die "role creation failed"

ROLE_ID=$(python3 - "$ROLE_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["id"])
PY
)

[ -n "$ROLE_ID" ] || die "created role id missing"

printf 'limited_role_id=%s\n' "$ROLE_ID"
printf '%s\n' "create_role=PASS"

printf '\n=== 15. CREATE LIMITED USER ===\n'

LIMITED_PASS="$(openssl rand -base64 30 | tr -d '\n')Aa9!"

USER_PAYLOAD=$(python3 - "$LIMITED_PASS" "$ROLE_ID" <<'PY'
import json,sys
print(json.dumps({
  "username":"recovery6f2-operator",
  "email":"recovery6f2-operator@example.invalid",
  "password":sys.argv[1],
  "roleIds":[sys.argv[2]]
}))
PY
)

USER_RESPONSE=$(printf '%s' "$USER_PAYLOAD" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -fsS -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -X POST "http://$ISO_API:8080/api/v1/admin/security/users" \
      --data-binary @-) \
  || die "user creation failed"

USER_ID=$(python3 - "$USER_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["id"])
PY
)

[ -n "$USER_ID" ] || die "created user id missing"

printf 'limited_user_id=%s\n' "$USER_ID"
printf '%s\n' "create_user=PASS"

printf '\n=== 16. LIMITED USER LOGIN + CLAIMS ===\n'

LIMITED_LOGIN_JSON=$(python3 - "$LIMITED_PASS" <<'PY'
import json,sys
print(json.dumps({
  "username":"recovery6f2-operator",
  "password":sys.argv[1]
}))
PY
)

LIMITED_LOGIN=$(printf '%s' "$LIMITED_LOGIN_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -fsS -H 'Content-Type: application/json' \
      -X POST "http://$ISO_API:8080/api/v1/auth/login" \
      --data-binary @-) \
  || die "limited user login failed"

LIMITED_TOKEN=$(python3 - "$LIMITED_LOGIN" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["accessToken"])
PY
)

LIMITED_ME=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -fsS -H "Authorization: Bearer $LIMITED_TOKEN" \
  "http://$ISO_API:8080/api/v1/auth/me") \
  || die "limited user /me failed"

python3 - "$LIMITED_ME" <<'PY'
import json,sys
obj=json.loads(sys.argv[1])
assert "Licensing Operator Test" in obj["roles"]
assert "licensing.manage" in obj["permissions"]
assert "security.admin" not in obj["permissions"]
print("limited_claims=PASS")
PY

printf '\n=== 17. LIMITED USER MUST NOT ACCESS SECURITY ADMIN ===\n'

LIMITED_ADMIN_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $LIMITED_TOKEN" \
  "http://$ISO_API:8080/api/v1/admin/security/users")

printf 'limited_admin_http=%s\n' "$LIMITED_ADMIN_HTTP"

[ "$LIMITED_ADMIN_HTTP" = 403 ] \
  || die "limited user unexpectedly accessed security admin"

printf '%s\n' "security_admin_rbac=PASS"

printf '\n=== 18. CHANGE ROLE PERMISSIONS TO SECURITY.ADMIN ===\n'

SEC_ADMIN_ID=$(python3 - "$PERMS_JSON" <<'PY'
import json,sys
for p in json.loads(sys.argv[1]):
    if p["code"]=="security.admin":
        print(p["id"])
        raise SystemExit(0)
raise SystemExit("security.admin permission not found")
PY
) || die "security.admin permission lookup failed"

ROLE_PERM_PAYLOAD=$(python3 - "$SEC_ADMIN_ID" <<'PY'
import json,sys
print(json.dumps({"permissionIds":[sys.argv[1]]}))
PY
)

ROLE_PERM_HTTP=$(printf '%s' "$ROLE_PERM_PAYLOAD" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -X PUT "http://$ISO_API:8080/api/v1/admin/security/roles/$ROLE_ID/permissions" \
      --data-binary @-)

printf 'set_role_permissions_http=%s\n' "$ROLE_PERM_HTTP"

[ "$ROLE_PERM_HTTP" = 204 ] || die "role permission update failed"

printf '%s\n' "set_role_permissions=PASS"

printf '\n=== 19. RELOGIN LIMITED USER; SECURITY.ADMIN NOW PRESENT ===\n'

LIMITED_LOGIN2=$(printf '%s' "$LIMITED_LOGIN_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -fsS -H 'Content-Type: application/json' \
      -X POST "http://$ISO_API:8080/api/v1/auth/login" \
      --data-binary @-) \
  || die "limited user relogin failed"

LIMITED_TOKEN2=$(python3 - "$LIMITED_LOGIN2" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["accessToken"])
PY
)

LIMITED_ADMIN_HTTP2=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $LIMITED_TOKEN2" \
  "http://$ISO_API:8080/api/v1/admin/security/users")

printf 'limited_admin_after_role_update_http=%s\n' "$LIMITED_ADMIN_HTTP2"

[ "$LIMITED_ADMIN_HTTP2" = 200 ] \
  || die "updated role permission did not take effect on relogin"

printf '%s\n' "role_permission_effective=PASS"

printf '\n=== 20. DEACTIVATE LIMITED USER ===\n'

STATUS_PAYLOAD='{"isActive":false}'

STATUS_HTTP=$(printf '%s' "$STATUS_PAYLOAD" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -X PUT "http://$ISO_API:8080/api/v1/admin/security/users/$USER_ID/status" \
      --data-binary @-)

printf 'deactivate_user_http=%s\n' "$STATUS_HTTP"

[ "$STATUS_HTTP" = 204 ] || die "user deactivation failed"

DEACTIVATED_LOGIN_HTTP=$(printf '%s' "$LIMITED_LOGIN_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -X POST "http://$ISO_API:8080/api/v1/auth/login" \
      --data-binary @-)

printf 'deactivated_login_http=%s\n' "$DEACTIVATED_LOGIN_HTTP"

[ "$DEACTIVATED_LOGIN_HTTP" = 401 ] \
  || die "deactivated user can still log in"

printf '%s\n' "user_deactivation=PASS"

printf '\n=== 21. DATABASE VERIFICATION ===\n'

ISO_USERS=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
ISO_ROLES=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
ISO_PERMS=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

printf 'isolated_users=%s isolated_roles=%s isolated_permissions=%s\n' \
  "$ISO_USERS" "$ISO_ROLES" "$ISO_PERMS"

[ "$ISO_USERS" -eq $((USERS + 1)) ] || die "isolated user count mismatch"
[ "$ISO_ROLES" -eq $((ROLES + 1)) ] || die "isolated role count mismatch"
[ "$ISO_PERMS" = "$PERMS" ] || die "isolated permission count changed unexpectedly"

printf '%s\n' "security_admin_persistence=PASS"

unset BOOT_PASS LIMITED_PASS ADMIN_TOKEN LIMITED_TOKEN LIMITED_TOKEN2
unset LOGIN_JSON LOGIN_RESPONSE LIMITED_LOGIN_JSON LIMITED_LOGIN LIMITED_LOGIN2
unset USERS_JSON ROLES_JSON PERMS_JSON ROLE_PAYLOAD ROLE_RESPONSE USER_PAYLOAD USER_RESPONSE

printf '\n=== 22. PRODUCTION FINAL SAFETY ===\n'

PIMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
PRUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PMIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
PUSERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
PROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PPERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
PLIC=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
PINST=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'image=%s running=%s migrations=%s users=%s roles=%s permissions=%s licenses=%s installations=%s\n' \
  "$PIMAGE" "$PRUN" "$PMIG" "$PUSERS" "$PROLES" "$PPERMS" "$PLIC" "$PINST"

[ "$PIMAGE" = "$IMG" ] || die "production image changed"
[ "$PRUN" = true ] || die "production API stopped"
[ "$PMIG" = "$MIG" ] || die "production migrations changed"
[ "$PUSERS" = "$USERS" ] || die "production users changed"
[ "$PROLES" = "$ROLES" ] || die "production roles changed"
[ "$PPERMS" = "$PERMS" ] || die "production permissions changed"
[ "$PLIC" = "$LIC" ] || die "production licenses changed"
[ "$PINST" = "$INST" ] || die "production installations changed"

printf '%s\n' "production_unchanged=PASS"

COMPLETED=1

printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 6F2 PASSED"
printf '%s\n' "======================================================"
printf '%s\n' "LIST USERS:                        PASS"
printf '%s\n' "LIST ROLES:                        PASS"
printf '%s\n' "LIST PERMISSIONS:                  PASS"
printf '%s\n' "CREATE ROLE:                       PASS"
printf '%s\n' "CREATE USER:                       PASS"
printf '%s\n' "ASSIGN ROLE:                       PASS"
printf '%s\n' "ROLE PERMISSION UPDATE:             PASS"
printf '%s\n' "PERMISSION CLAIM REFRESH ON LOGIN:  PASS"
printf '%s\n' "SECURITY.ADMIN RBAC:                PASS"
printf '%s\n' "USER DEACTIVATION:                  PASS"
printf '%s\n' "DEACTIVATED LOGIN -> 401:           PASS"
printf '%s\n' "PRODUCTION API/DB:                  UNCHANGED"
printf 'REPORT:                             %s\n' "$REPORT"
printf '%s\n' "NEXT: RECOVERY 6F3 - GUARDED PRODUCTION PROMOTION + BOOTSTRAP PASSWORD RETIREMENT"
printf '%s\n' "======================================================"