#!/usr/bin/env bash
set -u
set -o pipefail
umask 077
die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
PG="qflm-postgres"

echo "======================================================"
echo " QFLM RECOVERY 2B - CORE DOMAIN + INITIAL SCHEMA"
echo "======================================================"

[ "$(id -u)" -eq 0 ] || die "run as root"
cd "$ROOT" || die "source root missing"
[ "$(docker inspect "$PG" --format='{{.State.Health.Status}}' 2>/dev/null)" = healthy ] || die "postgres not healthy"

echo
echo "=== 1. CORE DOMAIN SOURCE ==="

mkdir -p  src/QFLM.Domain/Common  src/QFLM.Domain/Customers  src/QFLM.Domain/Products  src/QFLM.Domain/Subscriptions  src/QFLM.Domain/Licenses  src/QFLM.Domain/Installations  src/QFLM.Domain/Entitlements  src/QFLM.Infrastructure/Persistence

cat > src/QFLM.Domain/Common/BaseEntity.cs <<'CS'
namespace QFLM.Domain.Common;

public abstract class BaseEntity
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTime CreatedAtUtc { get; set; } = DateTime.UtcNow;
    public DateTime UpdatedAtUtc { get; set; } = DateTime.UtcNow;
}
CS

cat > src/QFLM.Domain/Customers/Customer.cs <<'CS'
using QFLM.Domain.Common;

namespace QFLM.Domain.Customers;

public sealed class Customer : BaseEntity
{
    public string CustomerNumber { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string? Email { get; set; }
    public string? CountryCode { get; set; }
    public bool IsActive { get; set; } = true;
}
CS

cat > src/QFLM.Domain/Products/Product.cs <<'CS'
using QFLM.Domain.Common;

namespace QFLM.Domain.Products;

public sealed class Product : BaseEntity
{
    public string ProductCode { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public bool IsActive { get; set; } = true;
}
CS

cat > src/QFLM.Domain/Products/Feature.cs <<'CS'
using QFLM.Domain.Common;

namespace QFLM.Domain.Products;

public sealed class Feature : BaseEntity
{
    public Guid ProductId { get; set; }
    public string FeatureCode { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public bool IsActive { get; set; } = true;
    public Product? Product { get; set; }
}
CS

cat > src/QFLM.Domain/Subscriptions/SubscriptionStatus.cs <<'CS'
namespace QFLM.Domain.Subscriptions;

public enum SubscriptionStatus
{
    Pending = 0,
    Active = 1,
    PastDue = 2,
    Suspended = 3,
    Cancelled = 4,
    Expired = 5
}
CS

cat > src/QFLM.Domain/Subscriptions/Subscription.cs <<'CS'
using QFLM.Domain.Common;
using QFLM.Domain.Customers;
using QFLM.Domain.Products;

namespace QFLM.Domain.Subscriptions;

public sealed class Subscription : BaseEntity
{
    public Guid CustomerId { get; set; }
    public Guid ProductId { get; set; }
    public SubscriptionStatus Status { get; set; } = SubscriptionStatus.Pending;
    public DateTime StartsAtUtc { get; set; }
    public DateTime? EndsAtUtc { get; set; }
    public int MaximumInstallations { get; set; } = 1;
    public Customer? Customer { get; set; }
    public Product? Product { get; set; }
}
CS

cat > src/QFLM.Domain/Licenses/LicenseType.cs <<'CS'
namespace QFLM.Domain.Licenses;

public enum LicenseType
{
    Trial = 0,
    Monthly = 1,
    Annual = 2,
    Perpetual = 3
}
CS

cat > src/QFLM.Domain/Licenses/LicenseStatus.cs <<'CS'
namespace QFLM.Domain.Licenses;

public enum LicenseStatus
{
    Draft = 0,
    Active = 1,
    Suspended = 2,
    Revoked = 3,
    Expired = 4,
    Grace = 5,
    Restricted = 6
}
CS

cat > src/QFLM.Domain/Licenses/License.cs <<'CS'
using QFLM.Domain.Common;
using QFLM.Domain.Customers;
using QFLM.Domain.Products;
using QFLM.Domain.Subscriptions;

namespace QFLM.Domain.Licenses;

public sealed class License : BaseEntity
{
    public string LicenseNumber { get; set; } = string.Empty;
    public Guid CustomerId { get; set; }
    public Guid ProductId { get; set; }
    public Guid? SubscriptionId { get; set; }
    public LicenseType Type { get; set; }
    public LicenseStatus Status { get; set; } = LicenseStatus.Draft;
    public DateTime? ValidFromUtc { get; set; }
    public DateTime? ValidUntilUtc { get; set; }
    public int GracePeriodDays { get; set; }
    public int MaximumInstallations { get; set; } = 1;
    public Customer? Customer { get; set; }
    public Product? Product { get; set; }
    public Subscription? Subscription { get; set; }
}
CS

cat > src/QFLM.Domain/Installations/InstallationStatus.cs <<'CS'
namespace QFLM.Domain.Installations;

public enum InstallationStatus
{
    Pending = 0,
    Active = 1,
    Suspended = 2,
    Deactivated = 3,
    Revoked = 4
}
CS

cat > src/QFLM.Domain/Installations/Installation.cs <<'CS'
using QFLM.Domain.Common;
using QFLM.Domain.Licenses;

namespace QFLM.Domain.Installations;

public sealed class Installation : BaseEntity
{
    public Guid LicenseId { get; set; }
    public Guid InstallationIdentifier { get; set; } = Guid.NewGuid();
    public string MachineFingerprintHash { get; set; } = string.Empty;
    public string? InstallationPublicKey { get; set; }
    public InstallationStatus Status { get; set; } = InstallationStatus.Pending;
    public DateTime? ActivatedAtUtc { get; set; }
    public DateTime? LastSeenAtUtc { get; set; }
    public long LastHeartbeatSequence { get; set; }
    public long HighestLeaseSequence { get; set; }
    public License? License { get; set; }
}
CS

cat > src/QFLM.Domain/Entitlements/LicenseEntitlement.cs <<'CS'
using QFLM.Domain.Common;
using QFLM.Domain.Licenses;
using QFLM.Domain.Products;

namespace QFLM.Domain.Entitlements;

public sealed class LicenseEntitlement : BaseEntity
{
    public Guid LicenseId { get; set; }
    public Guid FeatureId { get; set; }
    public bool Enabled { get; set; } = true;
    public int? LimitValue { get; set; }
    public License? License { get; set; }
    public Feature? Feature { get; set; }
}
CS

echo "core_domain=PASS"

echo
echo "=== 2. EF DB CONTEXT ==="

cat > src/QFLM.Infrastructure/Persistence/QflmDbContext.cs <<'CS'
using Microsoft.EntityFrameworkCore;
using QFLM.Domain.Customers;
using QFLM.Domain.Entitlements;
using QFLM.Domain.Installations;
using QFLM.Domain.Licenses;
using QFLM.Domain.Products;
using QFLM.Domain.Subscriptions;

namespace QFLM.Infrastructure.Persistence;

public sealed class QflmDbContext : DbContext
{
    public QflmDbContext(DbContextOptions<QflmDbContext> options) : base(options) { }

    public DbSet<Customer> Customers => Set<Customer>();
    public DbSet<Product> Products => Set<Product>();
    public DbSet<Feature> Features => Set<Feature>();
    public DbSet<Subscription> Subscriptions => Set<Subscription>();
    public DbSet<License> Licenses => Set<License>();
    public DbSet<Installation> Installations => Set<Installation>();
    public DbSet<LicenseEntitlement> LicenseEntitlements => Set<LicenseEntitlement>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);

        modelBuilder.Entity<Customer>(entity =>
        {
            entity.ToTable("customers");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.CustomerNumber).HasMaxLength(50).IsRequired();
            entity.HasIndex(x => x.CustomerNumber).IsUnique();
            entity.Property(x => x.Name).HasMaxLength(200).IsRequired();
            entity.Property(x => x.Email).HasMaxLength(320);
            entity.Property(x => x.CountryCode).HasMaxLength(2);
        });

        modelBuilder.Entity<Product>(entity =>
        {
            entity.ToTable("products");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.ProductCode).HasMaxLength(100).IsRequired();
            entity.HasIndex(x => x.ProductCode).IsUnique();
            entity.Property(x => x.Name).HasMaxLength(200).IsRequired();
        });

        modelBuilder.Entity<Feature>(entity =>
        {
            entity.ToTable("features");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.FeatureCode).HasMaxLength(100).IsRequired();
            entity.HasIndex(x => new { x.ProductId, x.FeatureCode }).IsUnique();
            entity.Property(x => x.Name).HasMaxLength(200).IsRequired();
            entity.HasOne(x => x.Product).WithMany().HasForeignKey(x => x.ProductId).OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<Subscription>(entity =>
        {
            entity.ToTable("subscriptions");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.Status).HasConversion<string>().HasMaxLength(30);
            entity.HasOne(x => x.Customer).WithMany().HasForeignKey(x => x.CustomerId).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Product).WithMany().HasForeignKey(x => x.ProductId).OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<License>(entity =>
        {
            entity.ToTable("licenses");
            entity.HasKey(x => x.Id);
            entity.Property(x => x.LicenseNumber).HasMaxLength(100).IsRequired();
            entity.HasIndex(x => x.LicenseNumber).IsUnique();
            entity.Property(x => x.Type).HasConversion<string>().HasMaxLength(30);
            entity.Property(x => x.Status).HasConversion<string>().HasMaxLength(30);
            entity.HasOne(x => x.Customer).WithMany().HasForeignKey(x => x.CustomerId).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Product).WithMany().HasForeignKey(x => x.ProductId).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Subscription).WithMany().HasForeignKey(x => x.SubscriptionId).OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<Installation>(entity =>
        {
            entity.ToTable("installations");
            entity.HasKey(x => x.Id);
            entity.HasIndex(x => x.InstallationIdentifier).IsUnique();
            entity.Property(x => x.MachineFingerprintHash).HasMaxLength(256).IsRequired();
            entity.Property(x => x.InstallationPublicKey).HasMaxLength(2048);
            entity.Property(x => x.Status).HasConversion<string>().HasMaxLength(30);
            entity.HasOne(x => x.License).WithMany().HasForeignKey(x => x.LicenseId).OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<LicenseEntitlement>(entity =>
        {
            entity.ToTable("license_entitlements");
            entity.HasKey(x => x.Id);
            entity.HasIndex(x => new { x.LicenseId, x.FeatureId }).IsUnique();
            entity.HasOne(x => x.License).WithMany().HasForeignKey(x => x.LicenseId).OnDelete(DeleteBehavior.Cascade);
            entity.HasOne(x => x.Feature).WithMany().HasForeignKey(x => x.FeatureId).OnDelete(DeleteBehavior.Restrict);
        });
    }
}
CS

cat > src/QFLM.Infrastructure/Persistence/QflmDbContextFactory.cs <<'CS'
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace QFLM.Infrastructure.Persistence;

public sealed class QflmDbContextFactory : IDesignTimeDbContextFactory<QflmDbContext>
{
    public QflmDbContext CreateDbContext(string[] args)
    {
        var options = new DbContextOptionsBuilder<QflmDbContext>()
            .UseNpgsql("Host=localhost;Port=5432;Database=qflm;Username=qflm;Password=design-time-only")
            .UseSnakeCaseNamingConvention()
            .Options;

        return new QflmDbContext(options);
    }
}
CS

echo "db_context=PASS"

echo
echo "=== 3. REGISTER DB CONTEXT IN API ==="

python3 - <<'PY'
from pathlib import Path
p=Path("src/QFLM.Api/Program.cs")
s=p.read_text()
needle='builder.Services.AddSingleton(NpgsqlDataSource.Create(pgConnection));'
replacement='''builder.Services.AddSingleton(NpgsqlDataSource.Create(pgConnection));
builder.Services.AddDbContext<QFLM.Infrastructure.Persistence.QflmDbContext>(options =>
    options.UseNpgsql(pgConnection).UseSnakeCaseNamingConvention());'''
if needle not in s:
    raise SystemExit("Program registration anchor missing")
s=s.replace(needle,replacement,1)
if 'using Microsoft.EntityFrameworkCore;' not in s:
    s='using Microsoft.EntityFrameworkCore;\n'+s
p.write_text(s)
PY

echo "api_db_context_registration=PASS"

echo
echo "=== 4. BUILD BEFORE MIGRATION ==="

dotnet restore QuikeFix.LicenseManager.slnx
dotnet build QuikeFix.LicenseManager.slnx -c Release --no-restore
echo "pre_migration_build=PASS"

echo
echo "=== 5. EF TOOL + INITIAL MIGRATION ==="

if [ ! -f .config/dotnet-tools.json ]; then
  dotnet new tool-manifest >/dev/null
fi
dotnet tool install dotnet-ef --version 10.0.4 >/dev/null 2>&1 || dotnet tool update dotnet-ef --version 10.0.4 >/dev/null

rm -rf src/QFLM.Infrastructure/Persistence/Migrations

dotnet tool run dotnet-ef migrations add InitialLicensingSchema   --project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj   --startup-project src/QFLM.Api/QFLM.Api.csproj   --context QflmDbContext   --output-dir Persistence/Migrations

MIGCOUNT="$(find src/QFLM.Infrastructure/Persistence/Migrations -maxdepth 1 -type f -name '*_InitialLicensingSchema.cs' | wc -l | xargs)"
[ "$MIGCOUNT" = 1 ] || die "initial migration was not generated exactly once"

echo "initial_migration=PASS"

echo
echo "=== 6. APPLY INITIAL SCHEMA ==="

TABLES_BEFORE="$(docker exec "$PG" psql -U qflm -d qflm -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name <> '__EFMigrationsHistory';" | xargs)"
[ "$TABLES_BEFORE" = 0 ] || die "qflm database is not empty before initial schema"

PGPASS="$(cat /opt/qflm/secrets/runtime-api/postgres_password)"
CONN="Host=127.0.0.1;Port=5432;Database=qflm;Username=qflm;Password=$PGPASS"

# EF runs from a temporary container-network tunnel because PostgreSQL has no host port.
docker rm -f qflm-pg-forward >/dev/null 2>&1 || true
docker run -d --name qflm-pg-forward --network qflm_backend -p 127.0.0.1:15432:15432 alpine/socat  TCP-LISTEN:15432,fork,reuseaddr TCP:qflm-postgres:5432 >/dev/null

sleep 2
CONN="Host=127.0.0.1;Port=15432;Database=qflm;Username=qflm;Password=$PGPASS"

dotnet tool run dotnet-ef database update   --project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj   --startup-project src/QFLM.Api/QFLM.Api.csproj   --context QflmDbContext   --connection "$CONN"

docker rm -f qflm-pg-forward >/dev/null
unset PGPASS CONN

echo "schema_apply=PASS"

echo
echo "=== 7. SCHEMA VERIFICATION ==="

TABLES="$(docker exec "$PG" psql -U qflm -d qflm -tAc "SELECT string_agg(table_name,',' ORDER BY table_name) FROM information_schema.tables WHERE table_schema='public';" | xargs)"
MIGRATIONS="$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"

echo "tables=$TABLES"
echo "migration_count=$MIGRATIONS"

for T in customers products features subscriptions licenses installations license_entitlements; do
  docker exec "$PG" psql -U qflm -d qflm -tAc "SELECT to_regclass('public.$T') IS NOT NULL;" | grep -qx t || die "missing table $T"
done

[ "$MIGRATIONS" = 1 ] || die "expected exactly one migration"

echo "schema_verification=PASS"

echo
echo "=== 8. FINAL RELEASE BUILD ==="

dotnet build QuikeFix.LicenseManager.slnx -c Release --no-restore
echo "final_build=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 2B PASSED"
echo "======================================================"
echo "CORE DOMAIN:             PASS"
echo "EF MODEL:                PASS"
echo "INITIAL MIGRATION:       PASS"
echo "DATABASE SCHEMA:         PASS"
echo "MIGRATION COUNT:         1"
echo "NEXT: RECOVERY 3 - ONLINE LICENSING FOUNDATION"
echo "======================================================"
