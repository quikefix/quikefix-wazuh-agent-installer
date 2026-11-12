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
ISO_DB="qflm_recovery5d1_test"
EXPECTED_IMAGE="qflm-api:13e-candidate"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery5d1-$STAMP"
MIGSQL="$BACKUP/offline-persistence-idempotent.sql"

die(){ echo "STOP: $*" >&2; exit 1; }
cleanup(){ docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "======================================================"
echo " QFLM RECOVERY 5D1 - OFFLINE PERSISTENCE ISOLATED"
echo "======================================================"

cd "$ROOT"
mkdir -p "$BACKUP"

IMG="$(docker inspect "$API" --format='{{.Config.Image}}')" || die "API missing"
RUN="$(docker inspect "$API" --format='{{.State.Running}}')"
MIG="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
OFF="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('offline_license_issuances','offline_license_audit_events');" | xargs)"

[ "$IMG" = "$EXPECTED_IMAGE" ] || die "unexpected API image"
[ "$RUN" = true ] || die "API not running"
[ "$MIG" = 2 ] || die "unexpected production migration count"
[ "$OFF" = 0 ] || die "offline tables already exist in production"

echo "production_baseline=PASS"

mkdir -p "$DOMAIN/OfflineLicensing"

cat > "$DOMAIN/OfflineLicensing/OfflineIssuanceStatus.cs" <<'CS'
namespace QFLM.Domain.OfflineLicensing;
public enum OfflineIssuanceStatus
{
    Issued = 0,
    Renewed = 1,
    Superseded = 2,
    Revoked = 3
}
CS

cat > "$DOMAIN/OfflineLicensing/OfflineLicenseIssuance.cs" <<'CS'
using QFLM.Domain.Common;
using QFLM.Domain.Installations;
using QFLM.Domain.Licenses;
namespace QFLM.Domain.OfflineLicensing;
public sealed class OfflineLicenseIssuance : BaseEntity
{
    public Guid LicenseId { get; set; }
    public Guid InstallationId { get; set; }
    public Guid RequestId { get; set; }
    public long LeaseSequence { get; set; }
    public string KeyId { get; set; } = string.Empty;
    public string RequestDigest { get; set; } = string.Empty;
    public string LicenseDigest { get; set; } = string.Empty;
    public OfflineIssuanceStatus Status { get; set; } = OfflineIssuanceStatus.Issued;
    public DateTime IssuedAtUtc { get; set; }
    public DateTime? ExpiresAtUtc { get; set; }
    public DateTime? GraceEndsAtUtc { get; set; }
    public Guid? SupersedesIssuanceId { get; set; }
    public License? License { get; set; }
    public Installation? Installation { get; set; }
    public OfflineLicenseIssuance? SupersedesIssuance { get; set; }
}
CS

cat > "$DOMAIN/OfflineLicensing/OfflineLicenseAuditEvent.cs" <<'CS'
using QFLM.Domain.Common;
using QFLM.Domain.Installations;
using QFLM.Domain.Licenses;
namespace QFLM.Domain.OfflineLicensing;
public sealed class OfflineLicenseAuditEvent : BaseEntity
{
    public Guid LicenseId { get; set; }
    public Guid? InstallationId { get; set; }
    public Guid? OfflineLicenseIssuanceId { get; set; }
    public string EventType { get; set; } = string.Empty;
    public string Outcome { get; set; } = string.Empty;
    public string? RequestId { get; set; }
    public long? LeaseSequence { get; set; }
    public string? DetailsJson { get; set; }
    public DateTime OccurredAtUtc { get; set; }
    public License? License { get; set; }
    public Installation? Installation { get; set; }
    public OfflineLicenseIssuance? OfflineLicenseIssuance { get; set; }
}
CS

python3 - "$CTX" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()

if "using QFLM.Domain.OfflineLicensing;" not in s:
    marker="using QFLM.Domain.Licenses;\n"
    if marker not in s: raise SystemExit("using marker missing")
    s=s.replace(marker,marker+"using QFLM.Domain.OfflineLicensing;\n",1)

dbsets='''    public DbSet<OfflineLicenseIssuance> OfflineLicenseIssuances => Set<OfflineLicenseIssuance>();
    public DbSet<OfflineLicenseAuditEvent> OfflineLicenseAuditEvents => Set<OfflineLicenseAuditEvent>();

'''
marker='''    protected override void OnModelCreating(
        ModelBuilder modelBuilder)
'''
if "DbSet<OfflineLicenseIssuance>" not in s:
    if marker not in s: raise SystemExit("OnModelCreating marker missing")
    s=s.replace(marker,dbsets+marker,1)

mapping='''
        modelBuilder.Entity<OfflineLicenseIssuance>(entity =>
        {
            entity.ToTable("offline_license_issuances");
            entity.HasKey(x => x.Id);
            entity.HasIndex(x => x.RequestId).IsUnique();
            entity.HasIndex(x => new { x.InstallationId, x.LeaseSequence }).IsUnique();
            entity.HasIndex(x => x.LicenseId);
            entity.Property(x => x.KeyId).HasMaxLength(100).IsRequired();
            entity.Property(x => x.RequestDigest).HasMaxLength(64).IsRequired();
            entity.Property(x => x.LicenseDigest).HasMaxLength(64).IsRequired();
            entity.Property(x => x.Status).HasConversion<string>().HasMaxLength(30);
            entity.HasOne(x => x.License).WithMany().HasForeignKey(x => x.LicenseId).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Installation).WithMany().HasForeignKey(x => x.InstallationId).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.SupersedesIssuance).WithMany().HasForeignKey(x => x.SupersedesIssuanceId).OnDelete(DeleteBehavior.Restrict);
        });

        modelBuilder.Entity<OfflineLicenseAuditEvent>(entity =>
        {
            entity.ToTable("offline_license_audit_events");
            entity.HasKey(x => x.Id);
            entity.HasIndex(x => x.LicenseId);
            entity.HasIndex(x => x.InstallationId);
            entity.HasIndex(x => x.OfflineLicenseIssuanceId);
            entity.HasIndex(x => x.OccurredAtUtc);
            entity.Property(x => x.EventType).HasMaxLength(100).IsRequired();
            entity.Property(x => x.Outcome).HasMaxLength(50).IsRequired();
            entity.Property(x => x.RequestId).HasMaxLength(100);
            entity.Property(x => x.DetailsJson).HasColumnType("jsonb");
            entity.HasOne(x => x.License).WithMany().HasForeignKey(x => x.LicenseId).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.Installation).WithMany().HasForeignKey(x => x.InstallationId).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(x => x.OfflineLicenseIssuance).WithMany().HasForeignKey(x => x.OfflineLicenseIssuanceId).OnDelete(DeleteBehavior.Restrict);
        });
'''

if "modelBuilder.Entity<OfflineLicenseIssuance>" not in s:
    idx=s.rfind("\n    }\n}")
    if idx < 0: raise SystemExit("DbContext closing marker missing")
    s=s[:idx]+mapping+s[idx:]

p.write_text(s)
PY

dotnet build QuikeFix.LicenseManager.slnx -c Release || die "build failed"

dotnet tool restore >/dev/null

EXISTING="$(find "$MIGDIR" -maxdepth 1 -type f -name '*_AddOfflineLicensePersistence.cs' | sort | tail -n1 || true)"
if [ -z "$EXISTING" ]; then
  dotnet tool run dotnet-ef migrations add AddOfflineLicensePersistence     --project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj     --startup-project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj     --context QflmDbContext     --output-dir Persistence/Migrations || die "migration generation failed"
fi

NEW_MIG="$(find "$MIGDIR" -maxdepth 1 -type f -name '*_AddOfflineLicensePersistence.cs' | sort | tail -n1)"
[ -s "$NEW_MIG" ] || die "offline persistence migration missing"
grep -q offline_license_issuances "$NEW_MIG" || die "issuance table absent from migration"
grep -q offline_license_audit_events "$NEW_MIG" || die "audit table absent from migration"

dotnet build QuikeFix.LicenseManager.slnx -c Release --no-restore || die "post migration build failed"

dotnet tool run dotnet-ef migrations script   --project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj   --startup-project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj   --context QflmDbContext   --idempotent   --output "$MIGSQL" || die "migration SQL generation failed"

docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1   -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" >/dev/null

docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB" >/dev/null
docker exec "$PG" createdb -U qflm "$ISO_DB"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges   | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null

ISO_BEFORE="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
[ "$ISO_BEFORE" = 2 ] || die "isolated baseline migration count invalid"

cat "$MIGSQL" | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null

ISO_AFTER="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
TABLES="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('offline_license_issuances','offline_license_audit_events');" | xargs)"

[ "$ISO_AFTER" = 3 ] || die "isolated migration count did not reach 3"
[ "$TABLES" = 2 ] || die "offline tables missing in isolated DB"

IID="11111111-1111-4111-8111-111111111111"
ROW_ID="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT id FROM installations WHERE installation_identifier='$IID';" | xargs)"
LICENSE_ID="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT license_id FROM installations WHERE installation_identifier='$IID';" | xargs)"
[ -n "$ROW_ID" ] || die "fixture installation missing"
[ -n "$LICENSE_ID" ] || die "fixture license missing"

ISSUANCE_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
REQUEST_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
AUDIT_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
REQ_DIGEST="$(printf '%s' "$REQUEST_ID" | sha256sum | awk '{print $1}')"
LIC_DIGEST="$(printf '%s' "$ISSUANCE_ID" | sha256sum | awk '{print $1}')"
KEY_ID="$(cat /opt/qflm/secrets/signing/signing-key-id)"

docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 <<SQL >/dev/null
BEGIN;
INSERT INTO offline_license_issuances (
 id,license_id,installation_id,request_id,lease_sequence,key_id,request_digest,license_digest,status,
 issued_at_utc,expires_at_utc,grace_ends_at_utc,supersedes_issuance_id,created_at_utc,updated_at_utc
) VALUES (
 '$ISSUANCE_ID','$LICENSE_ID','$ROW_ID','$REQUEST_ID',1,'$KEY_ID','$REQ_DIGEST','$LIC_DIGEST','Issued',
 NOW(),NOW()+INTERVAL '30 days',NOW()+INTERVAL '37 days',NULL,NOW(),NOW()
);
INSERT INTO offline_license_audit_events (
 id,license_id,installation_id,offline_license_issuance_id,event_type,outcome,request_id,lease_sequence,details_json,
 occurred_at_utc,created_at_utc,updated_at_utc
) VALUES (
 '$AUDIT_ID','$LICENSE_ID','$ROW_ID','$ISSUANCE_ID','OFFLINE_LICENSE_ISSUED','SUCCESS','$REQUEST_ID',1,
 '{"recovery":"5D1","isolated":true}'::jsonb,NOW(),NOW(),NOW()
);
COMMIT;
SQL

I_COUNT="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)"
A_COUNT="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)"
[ "$I_COUNT" = 1 ] || die "isolated issuance persistence failed"
[ "$A_COUNT" = 1 ] || die "isolated audit persistence failed"

P_MIG="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
P_OFF="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('offline_license_issuances','offline_license_audit_events');" | xargs)"
[ "$P_MIG" = 2 ] || die "production migration count changed"
[ "$P_OFF" = 0 ] || die "production offline tables unexpectedly created"

echo "======================================================"
echo " QFLM RECOVERY 5D1 PASSED"
echo "======================================================"
echo "OFFLINE ISSUANCE ENTITY:       PASS"
echo "OFFLINE AUDIT ENTITY:          PASS"
echo "DB CONTEXT:                    PASS"
echo "MIGRATION GENERATED:           PASS"
echo "ISOLATED MIGRATIONS:           3"
echo "ISOLATED OFFLINE TABLES:       2"
echo "ISOLATED PERSISTENCE:          PASS"
echo "PRODUCTION MIGRATIONS:         2 / UNCHANGED"
echo "PRODUCTION OFFLINE TABLES:     0 / UNCHANGED"
echo "NEXT: RECOVERY 5D2 - GUARDED PRODUCTION PROMOTION"
echo "======================================================"
