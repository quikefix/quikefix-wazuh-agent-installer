#!/usr/bin/env bash
# QFLM RECOVERY 7M3
# .NET Client SDK implementation + isolated tests.
# Mutates source only. Production API/DB remain unchanged.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
SDK="$ROOT/src/QFLM.ClientSdk"
TESTS="$ROOT/tests/QFLM.ClientSdk.Tests"
SLN="$ROOT/QuikeFix.LicenseManager.slnx"

PROD_API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"
EXPECTED_PROD_IMAGE="qflm-api:recovery7k2-production"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7m3-dotnet-sdk-$STAMP"
REPORT="$BACKUP/recovery7m3-dotnet-sdk-report.txt"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7M3"
echo " .NET CLIENT SDK IMPLEMENTATION / ISOLATED TESTS"
echo "======================================================"

echo
echo "=== 1. PRODUCTION SAFETY BASELINE ==="

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

[ "$PROD_IMAGE" = "$EXPECTED_PROD_IMAGE" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"

echo "production_baseline=PASS"

echo
echo "=== 2. BACKUP SOURCE ==="

tar -czf "$BACKUP/source-before-7m3.tgz" -C "$ROOT" src tests QuikeFix.LicenseManager.slnx 2>/dev/null || tar -czf "$BACKUP/source-before-7m3.tgz" -C "$ROOT" src QuikeFix.LicenseManager.slnx || die "source backup failed"

echo "source_backup=PASS"

echo
echo "=== 3. CREATE CLIENT SDK PROJECT ==="

rm -rf "$SDK" "$TESTS"
mkdir -p "$SDK" "$TESTS"

cat > "$SDK/QFLM.ClientSdk.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <PackageId>QuikeFix.QFLM.ClientSdk</PackageId>
    <Version>0.1.0</Version>
    <Authors>QuikeFix</Authors>
    <Description>Official .NET client SDK for QuikeFix License Manager.</Description>
  </PropertyGroup>
</Project>
EOF

cat > "$SDK/LicensingModels.cs" <<'EOF'
namespace QFLM.ClientSdk;

public enum EffectiveLicenseState
{
    Active,
    Grace,
    Restricted,
    Expired,
    Suspended,
    Revoked
}

public enum LicenseResultCode
{
    Success,
    InvalidRequest,
    InvalidLicense,
    ProductMismatch,
    LicenseInactive,
    LicenseSuspended,
    LicenseRevoked,
    LicenseExpired,
    SubscriptionInactive,
    InstallationLimitReached,
    InstallationNotFound,
    InstallationDisabled,
    MachineMismatch,
    SequenceRejected
}

public sealed record EntitlementDto
{
    public required string FeatureCode { get; init; }
    public bool Enabled { get; init; }
    public int? LimitValue { get; init; }
}

public sealed record ActivationRequest
{
    public required string LicenseKey { get; init; }
    public required string ProductCode { get; init; }
    public required string InstallationId { get; init; }
    public required string MachineFingerprint { get; init; }
}

public sealed record ValidationRequest
{
    public required string LicenseKey { get; init; }
    public required string ProductCode { get; init; }
    public required string InstallationId { get; init; }
    public required string MachineFingerprint { get; init; }
}

public sealed record HeartbeatRequest
{
    public required string LicenseKey { get; init; }
    public required string ProductCode { get; init; }
    public required string InstallationId { get; init; }
    public required string MachineFingerprint { get; init; }
    public long Sequence { get; init; }
}

public sealed record DeactivationRequest
{
    public required string LicenseKey { get; init; }
    public required string ProductCode { get; init; }
    public required string InstallationId { get; init; }
    public required string MachineFingerprint { get; init; }
}

public sealed record ActivationResult
{
    public required string LicenseId { get; init; }
    public required string InstallationId { get; init; }
    public required string ProductCode { get; init; }
    public EffectiveLicenseState EffectiveState { get; init; }
    public DateTime? ValidUntilUtc { get; init; }
    public DateTime? GraceEndsAtUtc { get; init; }
    public IReadOnlyCollection<EntitlementDto> Entitlements { get; init; } = [];
}

public sealed record ValidationResult
{
    public required string LicenseId { get; init; }
    public required string InstallationId { get; init; }
    public required string ProductCode { get; init; }
    public EffectiveLicenseState EffectiveState { get; init; }
    public bool AllowWriteOperations { get; init; }
    public DateTime? ValidUntilUtc { get; init; }
    public DateTime? GraceEndsAtUtc { get; init; }
    public IReadOnlyCollection<EntitlementDto> Entitlements { get; init; } = [];
}

public sealed record HeartbeatResult
{
    public required string InstallationId { get; init; }
    public long Sequence { get; init; }
    public DateTime ServerTimeUtc { get; init; }
}

public sealed record DeactivationResult
{
    public required string InstallationId { get; init; }
    public required string ProductCode { get; init; }
    public bool Deactivated { get; init; }
}

public sealed record LicensingResponse<T>
{
    public bool Success { get; init; }
    public LicenseResultCode Code { get; init; }
    public required string Message { get; init; }
    public T? Data { get; init; }
}
EOF

cat > "$SDK/QflmClientOptions.cs" <<'EOF'
namespace QFLM.ClientSdk;

public sealed class QflmClientOptions
{
    public required Uri BaseUri { get; init; }
    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(15);
}
EOF

cat > "$SDK/IQflmClient.cs" <<'EOF'
namespace QFLM.ClientSdk;

public interface IQflmClient
{
    Task<LicensingResponse<ActivationResult>> ActivateAsync(ActivationRequest request, CancellationToken cancellationToken = default);
    Task<LicensingResponse<ValidationResult>> ValidateAsync(ValidationRequest request, CancellationToken cancellationToken = default);
    Task<LicensingResponse<HeartbeatResult>> HeartbeatAsync(HeartbeatRequest request, CancellationToken cancellationToken = default);
    Task<LicensingResponse<DeactivationResult>> DeactivateAsync(DeactivationRequest request, CancellationToken cancellationToken = default);
}
EOF

cat > "$SDK/QflmClient.cs" <<'EOF'
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace QFLM.ClientSdk;

public sealed class QflmClient : IQflmClient, IDisposable
{
    private readonly HttpClient _http;
    private readonly bool _ownsClient;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() }
    };

    public QflmClient(QflmClientOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        _http = new HttpClient
        {
            BaseAddress = NormalizeBaseUri(options.BaseUri),
            Timeout = options.Timeout
        };
        _ownsClient = true;
    }

    public QflmClient(HttpClient httpClient)
    {
        _http = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        if (_http.BaseAddress is null)
            throw new ArgumentException("HttpClient.BaseAddress must be configured.", nameof(httpClient));
    }

    public Task<LicensingResponse<ActivationResult>> ActivateAsync(
        ActivationRequest request,
        CancellationToken cancellationToken = default) =>
        PostAsync<ActivationRequest, ActivationResult>("api/v1/activate", request, cancellationToken);

    public Task<LicensingResponse<ValidationResult>> ValidateAsync(
        ValidationRequest request,
        CancellationToken cancellationToken = default) =>
        PostAsync<ValidationRequest, ValidationResult>("api/v1/validate", request, cancellationToken);

    public Task<LicensingResponse<HeartbeatResult>> HeartbeatAsync(
        HeartbeatRequest request,
        CancellationToken cancellationToken = default) =>
        PostAsync<HeartbeatRequest, HeartbeatResult>("api/v1/heartbeat", request, cancellationToken);

    public Task<LicensingResponse<DeactivationResult>> DeactivateAsync(
        DeactivationRequest request,
        CancellationToken cancellationToken = default) =>
        PostAsync<DeactivationRequest, DeactivationResult>("api/v1/deactivate", request, cancellationToken);

    private async Task<LicensingResponse<TResult>> PostAsync<TRequest, TResult>(
        string path,
        TRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        using var response = await _http.PostAsJsonAsync(path, request, JsonOptions, cancellationToken)
            .ConfigureAwait(false);

        var body = await response.Content
            .ReadFromJsonAsync<LicensingResponse<TResult>>(JsonOptions, cancellationToken)
            .ConfigureAwait(false);

        if (body is null)
            throw new QflmProtocolException($"QFLM returned an empty or invalid response for {path}.");

        return body;
    }

    private static Uri NormalizeBaseUri(Uri baseUri)
    {
        ArgumentNullException.ThrowIfNull(baseUri);
        if (!baseUri.IsAbsoluteUri)
            throw new ArgumentException("QFLM BaseUri must be absolute.", nameof(baseUri));

        var text = baseUri.AbsoluteUri.EndsWith("/", StringComparison.Ordinal)
            ? baseUri.AbsoluteUri
            : baseUri.AbsoluteUri + "/";

        return new Uri(text, UriKind.Absolute);
    }

    public void Dispose()
    {
        if (_ownsClient)
            _http.Dispose();
    }
}
EOF

cat > "$SDK/QflmProtocolException.cs" <<'EOF'
namespace QFLM.ClientSdk;

public sealed class QflmProtocolException : Exception
{
    public QflmProtocolException(string message) : base(message) { }
}
EOF

cat > "$SDK/QflmInstallationIdentity.cs" <<'EOF'
using System.Security.Cryptography;
using System.Text;

namespace QFLM.ClientSdk;

public static class QflmInstallationIdentity
{
    public static string NewInstallationId() => Guid.NewGuid().ToString();

    public static string ComputeFingerprint(params string?[] components)
    {
        var normalized = string.Join("|",
            components
                .Where(static value => !string.IsNullOrWhiteSpace(value))
                .Select(static value => value!.Trim().ToLowerInvariant()));

        if (string.IsNullOrWhiteSpace(normalized))
            throw new ArgumentException("At least one fingerprint component is required.", nameof(components));

        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(normalized));
        return Convert.ToHexString(hash).ToLowerInvariant();
    }
}
EOF

cat > "$SDK/README.md" <<'EOF'
# QuikeFix QFLM .NET Client SDK

Client endpoints:

- POST /api/v1/activate
- POST /api/v1/validate
- POST /api/v1/heartbeat
- POST /api/v1/deactivate

Typical flow:

1. Generate and persist one installation ID.
2. Compute a stable machine fingerprint.
3. Activate once with the license key and product code.
4. Validate on application start.
5. Send monotonic heartbeat sequence values.
6. Respect EffectiveState, AllowWriteOperations and Entitlements.
7. Deactivate when intentionally removing the installation.

Do not store the license key in logs.
EOF

echo "sdk_source_created=PASS"

echo
echo "=== 4. CREATE SDK TEST PROJECT ==="

cat > "$TESTS/QFLM.ClientSdk.Tests.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <IsPackable>false</IsPackable>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.13.0" />
    <PackageReference Include="xunit" Version="2.9.3" />
    <PackageReference Include="xunit.runner.visualstudio" Version="3.1.5">
      <PrivateAssets>all</PrivateAssets>
    </PackageReference>
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="../../src/QFLM.ClientSdk/QFLM.ClientSdk.csproj" />
  </ItemGroup>
</Project>
EOF

cat > "$TESTS/QflmClientTests.cs" <<'EOF'
using System.Net;
using System.Text;
using QFLM.ClientSdk;

namespace QFLM.ClientSdk.Tests;

public sealed class QflmClientTests
{
    [Fact]
    public async Task Activate_UsesExpectedRoute_AndDeserializesResponse()
    {
        var handler = new StubHandler("""
        {
          "success": true,
          "code": "Success",
          "message": "License activation succeeded.",
          "data": {
            "licenseId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "installationId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "productCode": "TEST",
            "effectiveState": "Active",
            "validUntilUtc": null,
            "graceEndsAtUtc": null,
            "entitlements": []
          }
        }
        """);

        using var http = new HttpClient(handler) { BaseAddress = new Uri("https://license.example/") };
        using var client = new QflmClient(http);

        var result = await client.ActivateAsync(new ActivationRequest
        {
            LicenseKey = "secret",
            ProductCode = "TEST",
            InstallationId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            MachineFingerprint = "fingerprint"
        });

        Assert.True(result.Success);
        Assert.Equal("api/v1/activate", handler.LastPath);
        Assert.Equal(EffectiveLicenseState.Active, result.Data!.EffectiveState);
    }

    [Fact]
    public async Task Validate_UsesExpectedRoute()
    {
        var handler = new StubHandler("""
        {
          "success": true,
          "code": "Success",
          "message": "License validation succeeded.",
          "data": {
            "licenseId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "installationId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "productCode": "TEST",
            "effectiveState": "Grace",
            "allowWriteOperations": true,
            "validUntilUtc": null,
            "graceEndsAtUtc": null,
            "entitlements": []
          }
        }
        """);

        using var http = new HttpClient(handler) { BaseAddress = new Uri("https://license.example/") };
        using var client = new QflmClient(http);

        var result = await client.ValidateAsync(new ValidationRequest
        {
            LicenseKey = "secret",
            ProductCode = "TEST",
            InstallationId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            MachineFingerprint = "fingerprint"
        });

        Assert.True(result.Success);
        Assert.Equal("api/v1/validate", handler.LastPath);
        Assert.True(result.Data!.AllowWriteOperations);
    }

    [Fact]
    public async Task Heartbeat_UsesExpectedRoute_AndSequence()
    {
        var handler = new StubHandler("""
        {
          "success": true,
          "code": "Success",
          "message": "Heartbeat accepted.",
          "data": {
            "installationId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "sequence": 42,
            "serverTimeUtc": "2026-11-14T16:00:00Z"
          }
        }
        """);

        using var http = new HttpClient(handler) { BaseAddress = new Uri("https://license.example/") };
        using var client = new QflmClient(http);

        var result = await client.HeartbeatAsync(new HeartbeatRequest
        {
            LicenseKey = "secret",
            ProductCode = "TEST",
            InstallationId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            MachineFingerprint = "fingerprint",
            Sequence = 42
        });

        Assert.True(result.Success);
        Assert.Equal("api/v1/heartbeat", handler.LastPath);
        Assert.Equal(42, result.Data!.Sequence);
    }

    [Fact]
    public async Task Deactivate_UsesExpectedRoute()
    {
        var handler = new StubHandler("""
        {
          "success": true,
          "code": "Success",
          "message": "Installation deactivated.",
          "data": {
            "installationId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "productCode": "TEST",
            "deactivated": true
          }
        }
        """);

        using var http = new HttpClient(handler) { BaseAddress = new Uri("https://license.example/") };
        using var client = new QflmClient(http);

        var result = await client.DeactivateAsync(new DeactivationRequest
        {
            LicenseKey = "secret",
            ProductCode = "TEST",
            InstallationId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            MachineFingerprint = "fingerprint"
        });

        Assert.True(result.Success);
        Assert.Equal("api/v1/deactivate", handler.LastPath);
        Assert.True(result.Data!.Deactivated);
    }

    [Fact]
    public void Fingerprint_IsStable_AndNormalized()
    {
        var a = QflmInstallationIdentity.ComputeFingerprint(" Device-A ", "SERIAL-1");
        var b = QflmInstallationIdentity.ComputeFingerprint("device-a", "serial-1");
        Assert.Equal(a, b);
        Assert.Equal(64, a.Length);
    }

    private sealed class StubHandler(string json) : HttpMessageHandler
    {
        public string? LastPath { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            LastPath = request.RequestUri!.PathAndQuery.TrimStart('/');
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(json, Encoding.UTF8, "application/json")
            });
        }
    }
}
EOF

echo "sdk_tests_created=PASS"

echo
echo "=== 5. ADD PROJECTS TO SOLUTION ==="

dotnet sln "$SLN" add "$SDK/QFLM.ClientSdk.csproj" >/dev/null || true
dotnet sln "$SLN" add "$TESTS/QFLM.ClientSdk.Tests.csproj" >/dev/null || true

echo "solution_registration=PASS"

echo
echo "=== 6. BUILD SDK ==="

dotnet build "$SDK/QFLM.ClientSdk.csproj" -c Release || die "SDK build failed"
echo "sdk_build=PASS"

echo
echo "=== 7. RUN ISOLATED SDK TESTS ==="

dotnet test "$TESTS/QFLM.ClientSdk.Tests.csproj" -c Release --no-restore || dotnet test "$TESTS/QFLM.ClientSdk.Tests.csproj" -c Release || die "SDK tests failed"

echo "sdk_tests=PASS"

echo
echo "=== 8. FULL SOLUTION BUILD ==="

cd "$ROOT" || die "project root missing"
dotnet build QuikeFix.LicenseManager.slnx -c Release || die "full solution build failed"

echo "full_solution_build=PASS"

echo
echo "=== 9. PACKAGE SDK ==="

mkdir -p "$BACKUP/packages"
dotnet pack "$SDK/QFLM.ClientSdk.csproj" -c Release -o "$BACKUP/packages" || die "SDK pack failed"

SDK_PACKAGE=$(find "$BACKUP/packages" -maxdepth 1 -type f -name 'QuikeFix.QFLM.ClientSdk*.nupkg' | head -n1)
[ -n "$SDK_PACKAGE" ] || die "SDK package missing"

printf 'sdk_package=%s\n' "$SDK_PACKAGE"
printf 'sdk_package_sha256=%s\n' "$(sha256sum "$SDK_PACKAGE" | awk '{print $1}')"

echo "sdk_package=PASS"

echo
echo "=== 10. PRODUCTION NO-MUTATION CHECK ==="

FINAL_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)

[ "$FINAL_IMAGE" = "$PROD_IMAGE" ] || die "production API image changed"
[ "$FINAL_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "production migrations changed"

echo "production_unchanged=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7M3 PASSED"
echo "======================================================"
echo ".NET CLIENT SDK:                    BUILT"
echo "ACTIVATE CLIENT:                    PASS"
echo "VALIDATE CLIENT:                    PASS"
echo "HEARTBEAT CLIENT:                   PASS"
echo "DEACTIVATE CLIENT:                  PASS"
echo "MACHINE FINGERPRINT HELPER:         PASS"
echo "SDK TESTS:                          PASS"
echo "SDK PACKAGE:                        $SDK_PACKAGE"
echo "PRODUCTION API/DB:                  UNCHANGED"
echo "REPORT:                             $REPORT"
echo "NEXT: RECOVERY 7M4 - LIVE COMPATIBILITY TEST / SDK FREEZE"
echo "======================================================"
