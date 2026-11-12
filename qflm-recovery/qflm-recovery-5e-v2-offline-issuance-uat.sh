#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
APP="$ROOT/src/QFLM.Application"
INFRA="$ROOT/src/QFLM.Infrastructure"
OFFLINE="$ROOT/src/QFLM.OfflineLicensing"

API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"
ISO_DB="qflm_recovery5e_test"
EXPECTED_IMAGE="qflm-api:phase14d4-candidate"
NET="qflm_backend"
SIGN_SERVICE="qflm-signing"
SIGN_SECRET="/opt/qflm/secrets/signing-runtime/token"
PG_SECRET="/opt/qflm/secrets/runtime-api/postgres_password"
HARNESS="$ROOT/test-harness/Recovery5E"

die(){ echo "STOP: $*" >&2; exit 1; }

cleanup(){
  docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1     -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
  docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "======================================================"
echo " QFLM RECOVERY 5E - OFFLINE ISSUANCE SERVICE UAT"
echo "======================================================"

cd "$ROOT"

IMG="$(docker inspect "$API" --format='{{.Config.Image}}')" || die "API missing"
RUN="$(docker inspect "$API" --format='{{.State.Running}}')"
MIG="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
OFFT="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('offline_license_issuances','offline_license_audit_events');" | xargs)"
ISS0="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)"
AUD0="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)"

[ "$IMG" = "$EXPECTED_IMAGE" ] || die "unexpected API image: $IMG"
[ "$RUN" = true ] || die "API not running"
[ "$MIG" = 3 ] || die "expected 3 production migrations"
[ "$OFFT" = 2 ] || die "offline tables missing"
[ -s "$SIGN_SECRET" ] || die "signing token missing"
[ -s "$PG_SECRET" ] || die "postgres password missing"

docker inspect "$SIGN_SERVICE" >/dev/null 2>&1 || die "signing service missing"
[ "$(docker inspect "$SIGN_SERVICE" --format='{{.State.Running}}')" = true ] || die "signing service not running"

echo "production_baseline=PASS"

mkdir -p "$APP/OfflineLicensing" "$INFRA/OfflineLicensing"

cat > "$APP/OfflineLicensing/OfflineIssueCommand.cs" <<'CS'
namespace QFLM.Application.OfflineLicensing;

public sealed record OfflineIssueCommand
{
    public required Guid LicenseId { get; init; }
    public required Guid InstallationIdentifier { get; init; }
    public required Guid RequestId { get; init; }
    public required string ProductCode { get; init; }
    public required string MachineFingerprintHash { get; init; }
    public required string InstallationPublicKey { get; init; }
    public required string RequestDigest { get; init; }
}
CS

cat > "$APP/OfflineLicensing/OfflineIssueResult.cs" <<'CS'
namespace QFLM.Application.OfflineLicensing;

public sealed record OfflineIssueResult
{
    public required Guid IssuanceId { get; init; }
    public required long LeaseSequence { get; init; }
    public required string SignedLicenseJson { get; init; }
    public required string LicenseDigest { get; init; }
}
CS

cat > "$APP/OfflineLicensing/IOfflineLicenseIssuanceService.cs" <<'CS'
namespace QFLM.Application.OfflineLicensing;

public interface IOfflineLicenseIssuanceService
{
    Task<OfflineIssueResult> IssueAsync(
        OfflineIssueCommand command,
        CancellationToken cancellationToken = default);
}
CS

cat > "$INFRA/OfflineLicensing/InternalSigningClient.cs" <<'CS'
using System.Net.Http.Json;
using System.Text.Json;
using QFLM.OfflineLicensing.Models;

namespace QFLM.Infrastructure.OfflineLicensing;

public sealed class InternalSigningClient
{
    private readonly HttpClient _httpClient;
    private readonly string _token;

    public InternalSigningClient(HttpClient httpClient, string token)
    {
        _httpClient = httpClient;
        _token = token;
    }

    public async Task<string> IssueAsync(
        OfflineLicenseClaims claims,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            "/internal/v1/offline-license/issue");

        request.Headers.Add("X-QFLM-Signing-Token", _token);
        request.Content = JsonContent.Create(new { claims });

        using var response = await _httpClient.SendAsync(
            request,
            cancellationToken);

        var json = await response.Content.ReadAsStringAsync(
            cancellationToken);

        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException(
                $"Signing service returned {(int)response.StatusCode}: {json}");

        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        if (!root.TryGetProperty("payloadBase64", out _) ||
            !root.TryGetProperty("signatureBase64", out _) ||
            !root.TryGetProperty("keyId", out _))
            throw new InvalidDataException(
                "Signing service returned an invalid offline license envelope.");

        return json;
    }
}
CS

cat > "$INFRA/OfflineLicensing/EfOfflineLicenseIssuanceService.cs" <<'CS'
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using QFLM.Application.OfflineLicensing;
using QFLM.Domain.OfflineLicensing;
using QFLM.OfflineLicensing.Models;
using QFLM.Infrastructure.Persistence;

namespace QFLM.Infrastructure.OfflineLicensing;

public sealed class EfOfflineLicenseIssuanceService : IOfflineLicenseIssuanceService
{
    private readonly QflmDbContext _dbContext;
    private readonly InternalSigningClient _signingClient;

    public EfOfflineLicenseIssuanceService(
        QflmDbContext dbContext,
        InternalSigningClient signingClient)
    {
        _dbContext = dbContext;
        _signingClient = signingClient;
    }

    public async Task<OfflineIssueResult> IssueAsync(
        OfflineIssueCommand command,
        CancellationToken cancellationToken = default)
    {
        var now = DateTime.UtcNow;

        await using var transaction =
            await _dbContext.Database.BeginTransactionAsync(
                cancellationToken);

        var license = await _dbContext.Licenses
            .Include(x => x.Product)
            .Include(x => x.Customer)
            .Include(x => x.Subscription)
            .SingleOrDefaultAsync(
                x => x.Id == command.LicenseId,
                cancellationToken)
            ?? throw new InvalidOperationException(
                "License was not found.");

        if (!string.Equals(
                license.Status.ToString(),
                "Active",
                StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException(
                "License is not active.");

        if (license.Product is null ||
            !license.Product.IsActive ||
            !string.Equals(
                license.Product.ProductCode,
                command.ProductCode,
                StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException(
                "Product mismatch.");

        if (license.Customer is null ||
            !license.Customer.IsActive)
            throw new InvalidOperationException(
                "Customer is inactive.");

        if (license.ValidFromUtc.HasValue &&
            now < license.ValidFromUtc.Value)
            throw new InvalidOperationException(
                "License is not active yet.");

        if (license.ValidUntilUtc.HasValue &&
            now > license.ValidUntilUtc.Value)
            throw new InvalidOperationException(
                "License is expired.");

        if (license.Subscription is not null)
        {
            var status = license.Subscription.Status.ToString();

            if (!string.Equals(
                    status,
                    "Active",
                    StringComparison.OrdinalIgnoreCase) ||
                now < license.Subscription.StartsAtUtc ||
                (license.Subscription.EndsAtUtc.HasValue &&
                 now > license.Subscription.EndsAtUtc.Value))
                throw new InvalidOperationException(
                    "Subscription is inactive.");
        }

        var installation = await _dbContext.Installations
            .SingleOrDefaultAsync(
                x =>
                    x.LicenseId == license.Id &&
                    x.InstallationIdentifier ==
                        command.InstallationIdentifier,
                cancellationToken)
            ?? throw new InvalidOperationException(
                "Installation was not found.");

        if (!string.Equals(
                installation.Status.ToString(),
                "Active",
                StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException(
                "Installation is not active.");

        if (!string.Equals(
                installation.MachineFingerprintHash,
                command.MachineFingerprintHash,
                StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException(
                "Machine fingerprint mismatch.");

        if (!string.IsNullOrWhiteSpace(
                installation.InstallationPublicKey) &&
            !string.Equals(
                installation.InstallationPublicKey,
                command.InstallationPublicKey,
                StringComparison.Ordinal))
            throw new InvalidOperationException(
                "Installation public key mismatch.");

        var duplicateRequest =
            await _dbContext.OfflineLicenseIssuances.AnyAsync(
                x => x.RequestId == command.RequestId,
                cancellationToken);

        if (duplicateRequest)
            throw new InvalidOperationException(
                "Offline request has already been used.");

        await _dbContext.Database.ExecuteSqlInterpolatedAsync(
            $"SELECT pg_advisory_xact_lock(hashtext({installation.InstallationIdentifier.ToString()}));",
            cancellationToken);

        await _dbContext.Entry(installation).ReloadAsync(
            cancellationToken);

        var nextLeaseSequence =
            checked(installation.HighestLeaseSequence + 1);

        var entitlements = await _dbContext.LicenseEntitlements
            .Where(x => x.LicenseId == license.Id)
            .Join(
                _dbContext.Features,
                le => le.FeatureId,
                f => f.Id,
                (le, f) => new
                {
                    le.Enabled,
                    le.LimitValue,
                    f.FeatureCode,
                    f.IsActive
                })
            .Where(x => x.IsActive)
            .Select(x => new OfflineEntitlement
            {
                FeatureCode = x.FeatureCode,
                Enabled = x.Enabled,
                Value = x.LimitValue.HasValue
                    ? x.LimitValue.Value.ToString()
                    : null
            })
            .ToListAsync(cancellationToken);

        var expiresAt = license.ValidUntilUtc;
        DateTime? graceEndsAt = expiresAt.HasValue
            ? expiresAt.Value.AddDays(license.GracePeriodDays)
            : null;

        var claims = new OfflineLicenseClaims
        {
            SchemaVersion = 1,
            LicenseId = license.Id.ToString(),
            ProductCode = license.Product.ProductCode,
            InstallationId =
                installation.InstallationIdentifier.ToString(),
            MachineFingerprintHash =
                installation.MachineFingerprintHash,
            LicenseType = license.Type.ToString(),
            EffectiveState = "ACTIVE",
            IssuedAtUtc = now,
            NotBeforeUtc = now,
            ExpiresAtUtc = expiresAt,
            GraceEndsAtUtc = graceEndsAt,
            LeaseSequence = nextLeaseSequence,
            Entitlements = entitlements
        };

        var signedLicenseJson =
            await _signingClient.IssueAsync(
                claims,
                cancellationToken);

        using var signedDocument =
            JsonDocument.Parse(signedLicenseJson);

        var keyId = signedDocument.RootElement
            .GetProperty("keyId")
            .GetString()
            ?? throw new InvalidDataException(
                "Signed license keyId is missing.");

        var licenseDigest =
            Convert.ToHexString(
                SHA256.HashData(
                    Encoding.UTF8.GetBytes(
                        signedLicenseJson)))
            .ToLowerInvariant();

        var issuance = new OfflineLicenseIssuance
        {
            LicenseId = license.Id,
            InstallationId = installation.Id,
            RequestId = command.RequestId,
            LeaseSequence = nextLeaseSequence,
            KeyId = keyId,
            RequestDigest = command.RequestDigest,
            LicenseDigest = licenseDigest,
            Status = OfflineIssuanceStatus.Issued,
            IssuedAtUtc = now,
            ExpiresAtUtc = expiresAt,
            GraceEndsAtUtc = graceEndsAt
        };

        installation.HighestLeaseSequence =
            nextLeaseSequence;

        if (string.IsNullOrWhiteSpace(
                installation.InstallationPublicKey))
            installation.InstallationPublicKey =
                command.InstallationPublicKey;

        _dbContext.OfflineLicenseIssuances.Add(issuance);

        _dbContext.OfflineLicenseAuditEvents.Add(
            new OfflineLicenseAuditEvent
            {
                LicenseId = license.Id,
                InstallationId = installation.Id,
                OfflineLicenseIssuanceId = issuance.Id,
                EventType = "OFFLINE_LICENSE_ISSUED",
                Outcome = "SUCCESS",
                RequestId = command.RequestId.ToString(),
                LeaseSequence = nextLeaseSequence,
                DetailsJson = JsonSerializer.Serialize(
                    new
                    {
                        keyId,
                        productCode =
                            license.Product.ProductCode
                    }),
                OccurredAtUtc = now
            });

        await _dbContext.SaveChangesAsync(
            cancellationToken);

        await transaction.CommitAsync(
            cancellationToken);

        return new OfflineIssueResult
        {
            IssuanceId = issuance.Id,
            LeaseSequence = nextLeaseSequence,
            SignedLicenseJson = signedLicenseJson,
            LicenseDigest = licenseDigest
        };
    }
}
CS

if ! grep -q 'QFLM.OfflineLicensing.csproj' "$APP/QFLM.Application.csproj"; then
  dotnet add "$APP/QFLM.Application.csproj" reference     "$OFFLINE/QFLM.OfflineLicensing.csproj" >/dev/null
fi

if ! grep -q 'QFLM.OfflineLicensing.csproj' "$INFRA/QFLM.Infrastructure.csproj"; then
  dotnet add "$INFRA/QFLM.Infrastructure.csproj" reference     "$OFFLINE/QFLM.OfflineLicensing.csproj" >/dev/null
fi

dotnet build QuikeFix.LicenseManager.slnx -c Release ||
  die "solution build failed"

echo "issuance_service_build=PASS"

docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1   -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" >/dev/null

docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB" >/dev/null
docker exec "$PG" createdb -U qflm "$ISO_DB" ||
  die "isolated DB create failed"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB"   --no-owner --no-privileges |
docker exec -i "$PG" psql -U qflm -d "$ISO_DB"   -v ON_ERROR_STOP=1 >/dev/null ||
  die "isolated DB clone failed"

ISO_MIG="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
[ "$ISO_MIG" = 3 ] || die "isolated migration count is not 3"

IID="11111111-1111-4111-8111-111111111111"
ROW_ID="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT id FROM installations WHERE installation_identifier='$IID';" | xargs)"

if [ -z "$ROW_ID" ]; then
  IID="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT installation_identifier FROM installations ORDER BY created_at_utc LIMIT 1;' | xargs)"
  ROW_ID="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT id FROM installations WHERE installation_identifier='$IID';" | xargs)"
fi

[ -n "$ROW_ID" ] || die "no installation fixture found"

LICENSE_ID="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT license_id FROM installations WHERE id='$ROW_ID';" | xargs)"
PRODUCT_CODE="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT p.product_code FROM licenses l JOIN products p ON p.id=l.product_id WHERE l.id='$LICENSE_ID';" | xargs)"
CUSTOMER_ID="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT customer_id FROM licenses WHERE id='$LICENSE_ID';" | xargs)"
SUB_ID="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT subscription_id FROM licenses WHERE id='$LICENSE_ID';" | xargs)"

FP_HASH="$(printf '%s' 'QFLM-RECOVERY5E-MACHINE' | sha256sum | awk '{print $1}')"

docker exec "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 <<SQL >/dev/null
UPDATE installations
SET machine_fingerprint_hash='$FP_HASH',
    installation_public_key=NULL,
    status='Active',
    highest_lease_sequence=0,
    updated_at_utc=NOW()
WHERE id='$ROW_ID';

UPDATE licenses
SET status='Active',
    valid_from_utc=NOW()-INTERVAL '1 day',
    valid_until_utc=NOW()+INTERVAL '30 days',
    updated_at_utc=NOW()
WHERE id='$LICENSE_ID';

UPDATE products
SET is_active=true,
    updated_at_utc=NOW()
WHERE id=(SELECT product_id FROM licenses WHERE id='$LICENSE_ID');

UPDATE customers
SET is_active=true,
    updated_at_utc=NOW()
WHERE id='$CUSTOMER_ID';

DELETE FROM offline_license_audit_events;
DELETE FROM offline_license_issuances;
SQL

if [ -n "$SUB_ID" ]; then
docker exec "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 <<SQL >/dev/null
UPDATE subscriptions
SET status='Active',
    starts_at_utc=NOW()-INTERVAL '1 day',
    ends_at_utc=NOW()+INTERVAL '30 days',
    updated_at_utc=NOW()
WHERE id='$SUB_ID';
SQL
fi

FP_DB="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT machine_fingerprint_hash FROM installations WHERE id='$ROW_ID';" | xargs)"
IID_DB="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT installation_identifier FROM installations WHERE id='$ROW_ID';" | xargs)"
STATUS_DB="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT status FROM installations WHERE id='$ROW_ID';" | xargs)"

[ -n "$FP_DB" ] || die "fixture fingerprint was not stored"
[ "$IID_DB" = "$IID" ] || die "fixture installation identifier mismatch"
[ "$STATUS_DB" = "Active" ] || die "fixture installation not active"

echo "fixture_fingerprint_length=${#FP_DB}"
echo "isolated_fixture=PASS"

rm -rf "$HARNESS"
mkdir -p "$HARNESS"

cat > "$HARNESS/QFLM.Recovery5E.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="../../src/QFLM.Application/QFLM.Application.csproj" />
    <ProjectReference Include="../../src/QFLM.Infrastructure/QFLM.Infrastructure.csproj" />
    <ProjectReference Include="../../src/QFLM.OfflineLicensing/QFLM.OfflineLicensing.csproj" />
  </ItemGroup>
</Project>
XML

cat > "$HARNESS/Program.cs" <<'CS'
using System.Security.Cryptography;
using System.Text;
using Microsoft.EntityFrameworkCore;
using QFLM.Application.OfflineLicensing;
using QFLM.Infrastructure.OfflineLicensing;
using QFLM.Infrastructure.Persistence;

static string Required(string name) =>
    Environment.GetEnvironmentVariable(name)
    ?? throw new InvalidOperationException(
        $"Missing {name}");

var options =
    new DbContextOptionsBuilder<QflmDbContext>()
        .UseNpgsql(Required("QFLM_TEST_CONNECTION"))
        .UseSnakeCaseNamingConvention()
        .Options;

await using var db = new QflmDbContext(options);

using var httpClient = new HttpClient
{
    BaseAddress = new Uri(
        Required("QFLM_SIGNING_BASE"))
};

var signingClient =
    new InternalSigningClient(
        httpClient,
        Required("QFLM_SIGNING_TOKEN"));

var service =
    new EfOfflineLicenseIssuanceService(
        db,
        signingClient);

var licenseId =
    Guid.Parse(Required("QFLM_LICENSE_ID"));
var installationId =
    Guid.Parse(Required("QFLM_INSTALLATION_IDENTIFIER"));
var productCode =
    Required("QFLM_PRODUCT_CODE");
var fingerprint =
    Required("QFLM_FINGERPRINT_HASH");

OfflineIssueCommand Make(
    Guid requestId,
    string digest,
    string? product = null) =>
    new()
    {
        LicenseId = licenseId,
        InstallationIdentifier = installationId,
        RequestId = requestId,
        ProductCode = product ?? productCode,
        MachineFingerprintHash = fingerprint,
        InstallationPublicKey =
            "RECOVERY5E-INSTALLATION-PUBLIC-KEY",
        RequestDigest = digest
    };

var request1 = Guid.NewGuid();
var digest1 =
    Convert.ToHexString(
        SHA256.HashData(
            Encoding.UTF8.GetBytes(
                request1.ToString())))
    .ToLowerInvariant();

var command1 = Make(request1, digest1);
var first = await service.IssueAsync(command1);

if (first.LeaseSequence != 1)
    throw new InvalidOperationException(
        "first lease is not 1");

var request2 = Guid.NewGuid();
var second =
    await service.IssueAsync(
        Make(request2, new string('a', 64)));

if (second.LeaseSequence != 2)
    throw new InvalidOperationException(
        "second lease is not 2");

var installation =
    await db.Installations.SingleAsync(
        x => x.InstallationIdentifier ==
             installationId);

var issuanceCount =
    await db.OfflineLicenseIssuances.CountAsync();
var auditCount =
    await db.OfflineLicenseAuditEvents.CountAsync();

if (issuanceCount != 2 ||
    auditCount != 2 ||
    installation.HighestLeaseSequence != 2 ||
    installation.InstallationPublicKey !=
        "RECOVERY5E-INSTALLATION-PUBLIC-KEY")
    throw new InvalidOperationException(
        "persistence verification failed");

var duplicateRejected = false;
try
{
    await service.IssueAsync(command1);
}
catch (InvalidOperationException)
{
    duplicateRejected = true;
}

if (!duplicateRejected)
    throw new InvalidOperationException(
        "duplicate request was accepted");

var wrongProductRejected = false;
try
{
    await service.IssueAsync(
        Make(
            Guid.NewGuid(),
            new string('b', 64),
            "WRONG-PRODUCT"));
}
catch (InvalidOperationException)
{
    wrongProductRejected = true;
}

if (!wrongProductRejected)
    throw new InvalidOperationException(
        "wrong product was accepted");

Console.WriteLine(
    "RECOVERY5E_HARNESS=PASS");
Console.WriteLine(
    $"issuances={issuanceCount} audits={auditCount} lease={installation.HighestLeaseSequence}");
Console.WriteLine(
    $"duplicate_rejected={duplicateRejected} wrong_product_rejected={wrongProductRejected}");
CS

dotnet build "$HARNESS/QFLM.Recovery5E.csproj" -c Release ||
  die "harness build failed"

PG_IP="$(docker inspect "$PG" --format="{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}")"
SIGN_IP="$(docker inspect "$SIGN_SERVICE" --format="{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}")"

[ -n "$PG_IP" ] || die "postgres network IP missing"
[ -n "$SIGN_IP" ] || die "signing network IP missing"

export QFLM_TEST_CONNECTION="Host=$PG_IP;Port=5432;Database=$ISO_DB;Username=qflm;Password=$(cat "$PG_SECRET");SSL Mode=Disable"
export QFLM_SIGNING_BASE="http://$SIGN_IP:8080"
export QFLM_SIGNING_TOKEN="$(cat "$SIGN_SECRET")"
export QFLM_LICENSE_ID="$LICENSE_ID"
export QFLM_INSTALLATION_IDENTIFIER="$IID"
export QFLM_PRODUCT_CODE="$PRODUCT_CODE"
export QFLM_FINGERPRINT_HASH="$FP_DB"

dotnet run   --project "$HARNESS/QFLM.Recovery5E.csproj"   -c Release   --no-build ||
  die "offline issuance harness failed"

unset QFLM_TEST_CONNECTION
unset QFLM_SIGNING_BASE
unset QFLM_SIGNING_TOKEN
unset QFLM_LICENSE_ID
unset QFLM_INSTALLATION_IDENTIFIER
unset QFLM_PRODUCT_CODE
unset QFLM_FINGERPRINT_HASH

I_COUNT="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)"
A_COUNT="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)"
LEASE="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT highest_lease_sequence FROM installations WHERE id='$ROW_ID';" | xargs)"
PUBKEY_SET="$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT CASE WHEN installation_public_key IS NULL OR installation_public_key='' THEN 0 ELSE 1 END FROM installations WHERE id='$ROW_ID';" | xargs)"

[ "$I_COUNT" = 2 ] || die "expected 2 isolated issuances"
[ "$A_COUNT" = 2 ] || die "expected 2 isolated audit events"
[ "$LEASE" = 2 ] || die "expected lease sequence 2"
[ "$PUBKEY_SET" = 1 ] || die "installation public key not persisted"

P_MIG="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
P_ISS="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)"
P_AUD="$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)"

[ "$P_MIG" = 3 ] || die "production migration count changed"
[ "$P_ISS" = "$ISS0" ] || die "production issuance count changed"
[ "$P_AUD" = "$AUD0" ] || die "production audit count changed"
[ "$(docker inspect "$API" --format='{{.Config.Image}}')" = "$EXPECTED_IMAGE" ] ||
  die "production API image changed"

echo "======================================================"
echo " QFLM RECOVERY 5E PASSED"
echo "======================================================"
echo "OFFLINE APPLICATION CONTRACTS:      PASS"
echo "INTERNAL SIGNING CLIENT:            PASS"
echo "DB-INTEGRATED ISSUANCE SERVICE:     PASS"
echo "FIRST ISSUANCE LEASE:               1"
echo "SECOND ISSUANCE LEASE:              2"
echo "ISSUANCE PERSISTENCE:               2 / PASS"
echo "AUDIT PERSISTENCE:                  2 / PASS"
echo "INSTALLATION PUBLIC KEY BINDING:    PASS"
echo "DUPLICATE REQUEST REJECTION:        PASS"
echo "WRONG PRODUCT REJECTION:            PASS"
echo "PRODUCTION DATA:                    UNCHANGED"
echo "PHASE 14 OFFLINE BACKEND:           COMPLETE"
echo "NEXT: RECOVERY 6 - PHASE 15 AUTHENTICATION + RBAC"
echo "======================================================"
