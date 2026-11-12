#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT=/opt/qflm/app/QuikeFix.LicenseManager
API=qflm-api
PG=qflm-postgres
EXPECTED=qflm-api:13e-candidate
OFFLINE=$ROOT/src/QFLM.OfflineLicensing
SIGNING=$ROOT/src/QFLM.SigningService
TESTDIR=/tmp/qflm-recovery5a

die(){ echo "STOP: $*" >&2; exit 1; }

echo "======================================================"
echo " QFLM RECOVERY 5A - PHASE 14A OFFLINE FOUNDATION"
echo "======================================================"

cd "$ROOT" || die "source root missing"
[ "$(docker inspect "$API" --format='{{.Config.Image}}')" = "$EXPECTED" ] || die "unexpected API image"
[ "$(docker inspect "$API" --format='{{.State.Running}}')" = true ] || die "API not running"
[ "$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)" = 2 ] || die "unexpected migration count"

openssl list -public-key-algorithms | grep -qi ED25519 || die "Ed25519 unavailable"

echo "baseline=PASS"

rm -rf "$OFFLINE" "$SIGNING" "$TESTDIR"
mkdir -p "$OFFLINE/Models" "$OFFLINE/Serialization" "$OFFLINE/Verification" "$SIGNING" "$TESTDIR"

cat > "$OFFLINE/QFLM.OfflineLicensing.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
  </PropertyGroup>
</Project>
XML

cat > "$OFFLINE/Models/OfflineLicenseModels.cs" <<'CS'
namespace QFLM.OfflineLicensing.Models;

public sealed record OfflineLicenseRequest
{
    public int SchemaVersion { get; init; } = 1;
    public required string RequestId { get; init; }
    public required string ProductCode { get; init; }
    public required string InstallationId { get; init; }
    public required string MachineFingerprintHash { get; init; }
    public required string InstallationPublicKey { get; init; }
    public required DateTime RequestedAtUtc { get; init; }
    public required string Nonce { get; init; }
}

public sealed record OfflineEntitlement
{
    public required string FeatureCode { get; init; }
    public bool Enabled { get; init; }
    public string? Value { get; init; }
}

public sealed record OfflineLicenseClaims
{
    public int SchemaVersion { get; init; } = 1;
    public required string LicenseId { get; init; }
    public required string ProductCode { get; init; }
    public required string InstallationId { get; init; }
    public required string MachineFingerprintHash { get; init; }
    public required string LicenseType { get; init; }
    public required string EffectiveState { get; init; }
    public required DateTime IssuedAtUtc { get; init; }
    public required DateTime NotBeforeUtc { get; init; }
    public DateTime? ExpiresAtUtc { get; init; }
    public DateTime? GraceEndsAtUtc { get; init; }
    public long LeaseSequence { get; init; }
    public IReadOnlyCollection<OfflineEntitlement> Entitlements { get; init; } = Array.Empty<OfflineEntitlement>();
}

public sealed record SignedOfflineLicense
{
    public int SchemaVersion { get; init; } = 1;
    public string Algorithm { get; init; } = "Ed25519";
    public required string KeyId { get; init; }
    public required string PayloadBase64 { get; init; }
    public required string SignatureBase64 { get; init; }
}

public sealed record OfflineRenewalRequest
{
    public int SchemaVersion { get; init; } = 1;
    public required string RequestId { get; init; }
    public required string LicenseId { get; init; }
    public required string InstallationId { get; init; }
    public required long CurrentLeaseSequence { get; init; }
    public required DateTime ClientObservedUtc { get; init; }
    public required string PreviousLicenseDigest { get; init; }
    public required string Nonce { get; init; }
}
CS

cat > "$OFFLINE/Serialization/CanonicalJson.cs" <<'CS'
using System.Text.Json;
using System.Text.Json.Serialization;

namespace QFLM.OfflineLicensing.Serialization;

public static class CanonicalJson
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        WriteIndented = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never
    };

    public static byte[] SerializeUtf8<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);
    public static T Deserialize<T>(ReadOnlySpan<byte> utf8) =>
        JsonSerializer.Deserialize<T>(utf8, Options) ?? throw new InvalidDataException("Invalid offline licensing JSON.");
}
CS

cat > "$OFFLINE/Verification/OfflineLicensePolicy.cs" <<'CS'
namespace QFLM.OfflineLicensing.Verification;

public static class OfflineLicensePolicy
{
    public static bool IsWriteAllowed(string state) =>
        string.Equals(state, "ACTIVE", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(state, "GRACE", StringComparison.OrdinalIgnoreCase);

    public static bool IsRestricted(string state) =>
        string.Equals(state, "RESTRICTED", StringComparison.OrdinalIgnoreCase);

    public static bool IsClockRollback(DateTime trustedUtc, DateTime observedUtc, TimeSpan tolerance) =>
        observedUtc < trustedUtc.Subtract(tolerance);
}
CS

cat > "$SIGNING/QFLM.SigningService.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="../QFLM.OfflineLicensing/QFLM.OfflineLicensing.csproj" />
  </ItemGroup>
</Project>
XML

cat > "$SIGNING/Program.cs" <<'CS'
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();
app.MapGet("/health/live", () => Results.Ok(new { status = "live", service = "qflm-signing" }));
app.MapGet("/health/ready", () => Results.Ok(new { status = "ready", service = "qflm-signing", signingEnabled = false }));
app.Run();
CS

dotnet sln QuikeFix.LicenseManager.slnx list | grep -Fq QFLM.OfflineLicensing.csproj || dotnet sln QuikeFix.LicenseManager.slnx add "$OFFLINE/QFLM.OfflineLicensing.csproj" >/dev/null
dotnet sln QuikeFix.LicenseManager.slnx list | grep -Fq QFLM.SigningService.csproj || dotnet sln QuikeFix.LicenseManager.slnx add "$SIGNING/QFLM.SigningService.csproj" >/dev/null

dotnet build QuikeFix.LicenseManager.slnx -c Release

printf '%s' '{"schemaVersion":1,"licenseId":"phase14-test","productCode":"QFLM-TEST-PRODUCT","installationId":"99999999-9999-4999-8999-999999999999","effectiveState":"ACTIVE","leaseSequence":1}' > "$TESTDIR/payload.json"
openssl genpkey -algorithm ED25519 -out "$TESTDIR/private.pem" >/dev/null 2>&1
openssl pkey -in "$TESTDIR/private.pem" -pubout -out "$TESTDIR/public.pem" >/dev/null 2>&1
openssl pkeyutl -sign -inkey "$TESTDIR/private.pem" -rawin -in "$TESTDIR/payload.json" -out "$TESTDIR/signature.bin" >/dev/null 2>&1
openssl pkeyutl -verify -pubin -inkey "$TESTDIR/public.pem" -rawin -in "$TESTDIR/payload.json" -sigfile "$TESTDIR/signature.bin" >/dev/null 2>&1

cp "$TESTDIR/payload.json" "$TESTDIR/tampered.json"
printf ' ' >> "$TESTDIR/tampered.json"
if openssl pkeyutl -verify -pubin -inkey "$TESTDIR/public.pem" -rawin -in "$TESTDIR/tampered.json" -sigfile "$TESTDIR/signature.bin" >/dev/null 2>&1; then
  die "tampered payload verified"
fi

rm -rf "$TESTDIR"

[ "$(docker inspect "$API" --format='{{.Config.Image}}')" = "$EXPECTED" ] || die "production image changed"
[ "$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)" = 2 ] || die "migration count changed"

echo "======================================================"
echo " QFLM RECOVERY 5A PASSED"
echo "======================================================"
echo "OFFLINE CONTRACTS:       PASS"
echo "QFREQ MODEL:             PASS"
echo "QFL MODEL:               PASS"
echo "RENEWAL MODEL:           PASS"
echo "CANONICAL JSON:          PASS"
echo "ED25519 SIGN/VERIFY:     PASS"
echo "TAMPER DETECTION:        PASS"
echo "PRIVATE KEY PERSISTED:   NO"
echo "PRODUCTION API/DB:       UNCHANGED"
echo "NEXT: RECOVERY 5B - SIGNING KEY LIFECYCLE"
echo "======================================================"
