#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
DOMAIN="$ROOT/src/QFLM.Domain"
INFRA="$ROOT/src/QFLM.Infrastructure"
CTX="$INFRA/Persistence/QflmDbContext.cs"
MIGDIR="$INFRA/Persistence/Migrations"
API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"
ISO_DB="qflm_recovery6a_test"
EXPECTED_IMAGE="qflm-api:phase14d4-candidate"

die(){ echo "STOP: $*" >&2; exit 1; }
cleanup(){
  docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1     -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
  docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "======================================================"
echo " QFLM RECOVERY 6A - AUTH/RBAC MODEL + ISOLATED MIGRATION"
echo "======================================================"

cd "$ROOT"

IMG="$(docker inspect "$API" --format='{{.Config.Image}}')" || die "API missing"
RUN="$(docker inspect "$API" --format='{{.State.Running}}')"
MIG="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
AUTH0="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('auth_users','auth_roles','auth_permissions','auth_user_roles','auth_role_permissions');" | xargs)"
LIC="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)"
INST="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)"

[ "$IMG" = "$EXPECTED_IMAGE" ] || die "unexpected API image: $IMG"
[ "$RUN" = true ] || die "API not running"
[ "$MIG" = 3 ] || die "expected 3 production migrations"
[ "$AUTH0" = 0 ] || die "auth tables already exist in production"

echo "production_baseline=PASS"

mkdir -p "$DOMAIN/Security"

cat > "$DOMAIN/Security/AuthUser.cs" <<'CS'
using QFLM.Domain.Common;
namespace QFLM.Domain.Security;
public sealed class AuthUser : BaseEntity
{
    public string Username { get; set; } = string.Empty;
    public string NormalizedUsername { get; set; } = string.Empty;
    public string? Email { get; set; }
    public string? NormalizedEmail { get; set; }
    public string PasswordHash { get; set; } = string.Empty;
    public bool IsActive { get; set; } = true;
    public bool EmailConfirmed { get; set; }
    public int FailedAccessAttempts { get; set; }
    public DateTime? LockoutEndUtc { get; set; }
    public DateTime? LastLoginAtUtc { get; set; }
    public string SecurityStamp { get; set; } = Guid.NewGuid().ToString("N");
}
CS

cat > "$DOMAIN/Security/AuthRole.cs" <<'CS'
using QFLM.Domain.Common;
namespace QFLM.Domain.Security;
public sealed class AuthRole : BaseEntity
{
    public string Name { get; set; } = string.Empty;
    public string NormalizedName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsSystem { get; set; }
}
CS

cat > "$DOMAIN/Security/AuthPermission.cs" <<'CS'
using QFLM.Domain.Common;
namespace QFLM.Domain.Security;
public sealed class AuthPermission : BaseEntity
{
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsSystem { get; set; } = true;
}
CS

cat > "$DOMAIN/Security/AuthUserRole.cs" <<'CS'
using QFLM.Domain.Common;
namespace QFLM.Domain.Security;
public sealed class AuthUserRole : BaseEntity
{
    public Guid UserId { get; set; }
    public Guid RoleId { get; set; }
    public AuthUser? User { get; set; }
    public AuthRole? Role { get; set; }
}
CS

cat > "$DOMAIN/Security/AuthRolePermission.cs" <<'CS'
using QFLM.Domain.Common;
namespace QFLM.Domain.Security;
public sealed class AuthRolePermission : BaseEntity
{
    public Guid RoleId { get; set; }
    public Guid PermissionId { get; set; }
    public AuthRole? Role { get; set; }
    public AuthPermission? Permission { get; set; }
}
CS

python3 - "$CTX" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
s=p.read_text()

if "using QFLM.Domain.Security;" not in s:
    ns=chr(10)+"namespace QFLM.Infrastructure.Persistence;"
    pos=s.find(ns)
    if pos < 0:
        raise SystemExit("DbContext namespace marker not found")
    s=s[:pos]+chr(10)+"using QFLM.Domain.Security;"+s[pos:]

dbsets='''    public DbSet<AuthUser> AuthUsers => Set<AuthUser>();
    public DbSet<AuthRole> AuthRoles => Set<AuthRole>();
    public DbSet<AuthPermission> AuthPermissions => Set<AuthPermission>();
    public DbSet<AuthUserRole> AuthUserRoles => Set<AuthUserRole>();
    public DbSet<AuthRolePermission> AuthRolePermissions => Set<AuthRolePermission>();

'''

method_marker="    protected override void OnModelCreating("
if "DbSet<AuthUser>" not in s:
    pos=s.find(method_marker)
    if pos < 0:
        raise SystemExit("OnModelCreating method marker not found")
    s=s[:pos]+dbsets+s[pos:]

mapping='''
        modelBuilder.Entity<AuthUser>(entity =>
        {
            entity.ToTable("auth_users");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.Username).HasMaxLength(100).IsRequired();
            entity.Property(x => x.NormalizedUsername).HasMaxLength(100).IsRequired();
            entity.HasIndex(x => x.NormalizedUsername).IsUnique();
            entity.Property(x => x.Email).HasMaxLength(320);
            entity.Property(x => x.NormalizedEmail).HasMaxLength(320);
            entity.HasIndex(x => x.NormalizedEmail);
            entity.Property(x => x.PasswordHash).HasMaxLength(512).IsRequired();
            entity.Property(x => x.SecurityStamp).HasMaxLength(64).IsRequired();
        });

        modelBuilder.Entity<AuthRole>(entity =>
        {
            entity.ToTable("auth_roles");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.Name).HasMaxLength(100).IsRequired();
            entity.Property(x => x.NormalizedName).HasMaxLength(100).IsRequired();
            entity.HasIndex(x => x.NormalizedName).IsUnique();
            entity.Property(x => x.Description).HasMaxLength(500);
        });

        modelBuilder.Entity<AuthPermission>(entity =>
        {
            entity.ToTable("auth_permissions");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.Code).HasMaxLength(150).IsRequired();
            entity.HasIndex(x => x.Code).IsUnique();
            entity.Property(x => x.Name).HasMaxLength(150).IsRequired();
            entity.Property(x => x.Category).HasMaxLength(100).IsRequired();
            entity.Property(x => x.Description).HasMaxLength(500);
        });

        modelBuilder.Entity<AuthUserRole>(entity =>
        {
            entity.ToTable("auth_user_roles");
            entity.HasKey(x => x.Id);
            entity.HasIndex(x => new { x.UserId, x.RoleId }).IsUnique();
            entity.HasOne(x => x.User).WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
            entity.HasOne(x => x.Role).WithMany().HasForeignKey(x => x.RoleId).OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<AuthRolePermission>(entity =>
        {
            entity.ToTable("auth_role_permissions");
            entity.HasKey(x => x.Id);
            entity.HasIndex(x => new { x.RoleId, x.PermissionId }).IsUnique();
            entity.HasOne(x => x.Role).WithMany().HasForeignKey(x => x.RoleId).OnDelete(DeleteBehavior.Cascade);
            entity.HasOne(x => x.Permission).WithMany().HasForeignKey(x => x.PermissionId).OnDelete(DeleteBehavior.Cascade);
        });
'''

if "modelBuilder.Entity<AuthUser>" not in s:
    method_pos=s.find(method_marker)
    if method_pos < 0:
        raise SystemExit("OnModelCreating method not found")
    open_brace=s.find("{",method_pos)
    if open_brace < 0:
        raise SystemExit("OnModelCreating opening brace not found")
    depth=0; close=None; ins=False; esc=False; verb=False
    i=open_brace
    while i < len(s):
        ch=s[i]
        if ins:
            if verb:
                if ch=='"':
                    if i+1 < len(s) and s[i+1]=='"':
                        i+=2; continue
                    ins=False; verb=False
            else:
                if esc: esc=False
                elif ch=='\\': esc=True
                elif ch=='"': ins=False
        else:
            if ch=='"':
                ins=True
                if i>0 and s[i-1]=='@': verb=True
            elif ch=='{': depth+=1
            elif ch=='}':
                depth-=1
                if depth==0:
                    close=i; break
        i+=1
    if close is None:
        raise SystemExit("OnModelCreating closing brace not found")
    s=s[:close]+mapping+chr(10)+s[close:]

p.write_text(s)
PY

[ "$(grep -c 'DbSet<Auth' "$CTX" || true)" = 5 ] || die "auth DbSet count invalid"
[ "$(grep -c 'modelBuilder.Entity<Auth' "$CTX" || true)" = 5 ] || die "auth mapping count invalid"

dotnet build QuikeFix.LicenseManager.slnx -c Release || die "pre-migration build failed"
dotnet tool restore >/dev/null

EXISTING="$(find "$MIGDIR" -maxdepth 1 -type f -name '*_AddAuthenticationRbac.cs' | sort | tail -n1 || true)"
if [ -z "$EXISTING" ]; then
  dotnet tool run dotnet-ef migrations add AddAuthenticationRbac     --project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj     --startup-project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj     --context QflmDbContext     --output-dir Persistence/Migrations || die "auth migration generation failed"
fi

NEW_MIG="$(find "$MIGDIR" -maxdepth 1 -type f -name '*_AddAuthenticationRbac.cs' | sort | tail -n1)"
[ -s "$NEW_MIG" ] || die "auth migration missing"

for t in auth_users auth_roles auth_permissions auth_user_roles auth_role_permissions; do
  grep -q "$t" "$NEW_MIG" || die "$t absent from migration"
done

dotnet build QuikeFix.LicenseManager.slnx -c Release --no-restore || die "post-migration build failed"

MIGSQL="/tmp/qflm-recovery6a-auth.sql"
dotnet tool run dotnet-ef migrations script   --project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj   --startup-project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj   --context QflmDbContext   --idempotent   --output "$MIGSQL" || die "auth migration SQL generation failed"

docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1   -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" >/dev/null

docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB" >/dev/null
docker exec "$PG" createdb -U qflm "$ISO_DB" || die "isolated DB create failed"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges   | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null   || die "isolated DB clone failed"

ISO_BEFORE="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
[ "$ISO_BEFORE" = 3 ] || die "isolated baseline migration count invalid"

cat "$MIGSQL" | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null || die "isolated auth migration failed"

ISO_AFTER="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
AUTH_TABLES="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('auth_users','auth_roles','auth_permissions','auth_user_roles','auth_role_permissions');" | xargs)"
[ "$ISO_AFTER" = 4 ] || die "isolated migration count did not reach 4"
[ "$AUTH_TABLES" = 5 ] || die "isolated auth table count invalid"

USER_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
ROLE_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
P1="$(python3 -c 'import uuid; print(uuid.uuid4())')"
P2="$(python3 -c 'import uuid; print(uuid.uuid4())')"
UR="$(python3 -c 'import uuid; print(uuid.uuid4())')"
RP1="$(python3 -c 'import uuid; print(uuid.uuid4())')"
RP2="$(python3 -c 'import uuid; print(uuid.uuid4())')"

docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 <<SQL >/dev/null
BEGIN;
INSERT INTO auth_users (
 id,username,normalized_username,email,normalized_email,password_hash,is_active,email_confirmed,
 failed_access_attempts,lockout_end_utc,last_login_at_utc,security_stamp,created_at_utc,updated_at_utc
) VALUES (
 '$USER_ID','phase15-admin','PHASE15-ADMIN','phase15@example.invalid','PHASE15@EXAMPLE.INVALID',
 'TEST-HASH-NOT-REAL',true,true,0,NULL,NULL,'recovery6astamp',NOW(),NOW()
);
INSERT INTO auth_roles (
 id,name,normalized_name,description,is_system,created_at_utc,updated_at_utc
) VALUES (
 '$ROLE_ID','Platform Administrator','PLATFORM ADMINISTRATOR','Recovery 6A isolated role',true,NOW(),NOW()
);
INSERT INTO auth_permissions (
 id,code,name,category,description,is_system,created_at_utc,updated_at_utc
) VALUES
 ('$P1','licensing.manage','Manage Licensing','Licensing','Manage licensing',true,NOW(),NOW()),
 ('$P2','offline.issue','Issue Offline Licenses','Offline Licensing','Issue offline licenses',true,NOW(),NOW());
INSERT INTO auth_user_roles (
 id,user_id,role_id,created_at_utc,updated_at_utc
) VALUES ('$UR','$USER_ID','$ROLE_ID',NOW(),NOW());
INSERT INTO auth_role_permissions (
 id,role_id,permission_id,created_at_utc,updated_at_utc
) VALUES
 ('$RP1','$ROLE_ID','$P1',NOW(),NOW()),
 ('$RP2','$ROLE_ID','$P2',NOW(),NOW());
COMMIT;
SQL

EFF="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "
SELECT count(*)
FROM auth_users u
JOIN auth_user_roles ur ON ur.user_id=u.id
JOIN auth_role_permissions rp ON rp.role_id=ur.role_id
JOIN auth_permissions p ON p.id=rp.permission_id
WHERE u.id='$USER_ID';
" | xargs)"
[ "$EFF" = 2 ] || die "effective RBAC resolution failed"

set +e
docker exec "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 -c "
INSERT INTO auth_users (
 id,username,normalized_username,password_hash,is_active,email_confirmed,failed_access_attempts,security_stamp,created_at_utc,updated_at_utc
) VALUES (
 gen_random_uuid(),'dup','PHASE15-ADMIN','x',true,false,0,'dupstamp',NOW(),NOW()
);" >/dev/null 2>&1
DUP_USER_RC=$?

docker exec "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 -c "
INSERT INTO auth_user_roles (id,user_id,role_id,created_at_utc,updated_at_utc)
VALUES (gen_random_uuid(),'$USER_ID','$ROLE_ID',NOW(),NOW());" >/dev/null 2>&1
DUP_UR_RC=$?

docker exec "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 -c "
INSERT INTO auth_role_permissions (id,role_id,permission_id,created_at_utc,updated_at_utc)
VALUES (gen_random_uuid(),'$ROLE_ID','$P1',NOW(),NOW());" >/dev/null 2>&1
DUP_RP_RC=$?
set -e

[ "$DUP_USER_RC" -ne 0 ] || die "duplicate username not rejected"
[ "$DUP_UR_RC" -ne 0 ] || die "duplicate user-role not rejected"
[ "$DUP_RP_RC" -ne 0 ] || die "duplicate role-permission not rejected"

PIMG="$(docker inspect "$API" --format='{{.Config.Image}}')"
PMIG="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
PAUTH="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('auth_users','auth_roles','auth_permissions','auth_user_roles','auth_role_permissions');" | xargs)"
PLIC="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)"
PINST="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)"

[ "$PIMG" = "$IMG" ] || die "production API image changed"
[ "$PMIG" = "$MIG" ] || die "production migration count changed"
[ "$PAUTH" = 0 ] || die "auth tables appeared in production"
[ "$PLIC" = "$LIC" ] || die "production license count changed"
[ "$PINST" = "$INST" ] || die "production installation count changed"

echo "======================================================"
echo " QFLM RECOVERY 6A PASSED"
echo "======================================================"
echo "AUTH USER ENTITY:              PASS"
echo "AUTH ROLE ENTITY:              PASS"
echo "AUTH PERMISSION ENTITY:        PASS"
echo "USER-ROLE MODEL:               PASS"
echo "ROLE-PERMISSION MODEL:         PASS"
echo "AUTH/RBAC MIGRATION:           GENERATED"
echo "ISOLATED MIGRATIONS:           4"
echo "ISOLATED AUTH TABLES:          5"
echo "RBAC RESOLUTION:               PASS"
echo "USERNAME UNIQUENESS:           PASS"
echo "USER-ROLE UNIQUENESS:          PASS"
echo "ROLE-PERMISSION UNIQUENESS:    PASS"
echo "PRODUCTION DATABASE:           UNCHANGED"
echo "PRODUCTION API:                UNCHANGED"
echo "NEXT: RECOVERY 6B - PASSWORD HASHING + LOGIN + JWT/REFRESH"
echo "======================================================"
