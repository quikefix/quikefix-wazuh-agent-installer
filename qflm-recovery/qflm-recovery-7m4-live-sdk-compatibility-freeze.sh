#!/usr/bin/env bash
# QFLM RECOVERY 7M4
# Live compatibility test + .NET Client SDK freeze.
# Uses deliberately invalid license credentials against production so
# no licensing records are created/updated. Freezes tested SDK artifacts.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
SDK="$ROOT/src/QFLM.ClientSdk"
TESTS="$ROOT/tests/QFLM.ClientSdk.Tests"

PROD_API="qflm-api"
PROD_GUI="qflm-admin-web-production"
PG="qflm-postgres"
PROD_DB="qflm"

EXPECTED_PROD_API_IMAGE="qflm-api:recovery7k2-production"
EXPECTED_PROD_GUI_IMAGE="qflm-admin-web:recovery7l3-production"

PUBLIC_URL="https://lc.quikefix.info"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7m4-sdk-final-freeze-$STAMP"
REPORT="$BACKUP/recovery7m4-sdk-final-freeze-report.txt"
MANIFEST="$BACKUP/qflm-dotnet-sdk-final-freeze.manifest"
LIVE_TEST="$BACKUP/live-compatibility"
PACKAGES="$BACKUP/packages"

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

mkdir -p "$BACKUP" "$LIVE_TEST" "$PACKAGES"
exec > >(tee "$REPORT") 2>&1

echo "======================================================"
echo " QFLM RECOVERY 7M4"
echo " LIVE COMPATIBILITY TEST / SDK FREEZE"
echo "======================================================"

echo
echo "=== 1. FINAL PRODUCTION BASELINE ==="

PROD_API_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_API_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
PROD_GUI_IMAGE=$(docker inspect "$PROD_GUI" --format='{{.Config.Image}}') || die "production GUI missing"
PROD_GUI_RUNNING=$(docker inspect "$PROD_GUI" --format='{{.State.Running}}')

[ "$PROD_API_IMAGE" = "$EXPECTED_PROD_API_IMAGE" ] || die "unexpected production API image"
[ "$PROD_API_RUNNING" = true ] || die "production API not running"
[ "$PROD_GUI_IMAGE" = "$EXPECTED_PROD_GUI_IMAGE" ] || die "unexpected production GUI image"
[ "$PROD_GUI_RUNNING" = true ] || die "production GUI not running"

MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
LICENSES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
ISSUANCES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
AUDIT=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

echo "production_baseline=PASS"

echo
echo "=== 2. SDK SOURCE / TEST BASELINE ==="

[ -f "$SDK/QFLM.ClientSdk.csproj" ] || die "SDK project missing"
[ -f "$SDK/QflmClient.cs" ] || die "SDK client missing"
[ -f "$TESTS/QFLM.ClientSdk.Tests.csproj" ] || die "SDK tests project missing"

dotnet build "$SDK/QFLM.ClientSdk.csproj" -c Release || die "SDK build failed"
DOTNET_ROLL_FORWARD=Major dotnet test "$TESTS/QFLM.ClientSdk.Tests.csproj" -c Release || die "SDK tests failed"

echo "sdk_source_tests=PASS"

echo
echo "=== 3. PACKAGE RELEASE SDK ==="

# Ensure NuGet package includes its README.
python3 - "$SDK/QFLM.ClientSdk.csproj" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

if '<PackageReadmeFile>README.md</PackageReadmeFile>' not in s:
    s = s.replace(
        '<Description>Official .NET client SDK for QuikeFix License Manager.</Description>',
        '<Description>Official .NET client SDK for QuikeFix License Manager.</Description>\n'
        '    <PackageReadmeFile>README.md</PackageReadmeFile>'
    )

if '<None Include="README.md" Pack="true" PackagePath="/"/>' not in s:
    s = s.replace(
        '</Project>',
        '  <ItemGroup>\n'
        '    <None Include="README.md" Pack="true" PackagePath="/"/>\n'
        '  </ItemGroup>\n'
        '</Project>'
    )

p.write_text(s)
PY

dotnet pack "$SDK/QFLM.ClientSdk.csproj" -c Release -o "$PACKAGES" || die "SDK package failed"

SDK_PACKAGE=$(find "$PACKAGES" -maxdepth 1 -type f -name 'QuikeFix.QFLM.ClientSdk*.nupkg' | head -n1)
[ -n "$SDK_PACKAGE" ] || die "SDK package missing"

SDK_SHA=$(sha256sum "$SDK_PACKAGE" | awk '{print $1}')

echo "sdk_package=$SDK_PACKAGE"
echo "sdk_sha256=$SDK_SHA"
echo "sdk_package=PASS"

echo
echo "=== 4. CREATE LIVE COMPATIBILITY HARNESS ==="

cat > "$LIVE_TEST/QFLM.LiveCompatibility.csproj" <<EOF
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="QuikeFix.QFLM.ClientSdk" Version="0.1.0" />
  </ItemGroup>
</Project>
EOF

cat > "$LIVE_TEST/Program.cs" <<'EOF'
using QFLM.ClientSdk;

var baseUri = new Uri(Environment.GetEnvironmentVariable("QFLM_BASE_URL")
    ?? throw new InvalidOperationException("QFLM_BASE_URL is required."));

var licenseKey = "QFLM-INVALID-COMPATIBILITY-TEST";
var productCode = "QFLM_INVALID_PRODUCT";
var installationId = Guid.NewGuid().ToString();
var fingerprint = QflmInstallationIdentity.ComputeFingerprint(
    "qflm-live-compatibility-test",
    installationId);

using var client = new QflmClient(new QflmClientOptions
{
    BaseUri = baseUri,
    Timeout = TimeSpan.FromSeconds(20)
});

static void AssertInvalid<T>(string operation, LicensingResponse<T> response)
{
    if (response.Success)
        throw new InvalidOperationException($"{operation}: unexpectedly succeeded.");

    if (response.Code != LicenseResultCode.InvalidLicense)
        throw new InvalidOperationException(
            $"{operation}: expected InvalidLicense, got {response.Code}: {response.Message}");

    Console.WriteLine($"{operation}=PASS code={response.Code}");
}

AssertInvalid("activate", await client.ActivateAsync(new ActivationRequest
{
    LicenseKey = licenseKey,
    ProductCode = productCode,
    InstallationId = installationId,
    MachineFingerprint = fingerprint
}));

AssertInvalid("validate", await client.ValidateAsync(new ValidationRequest
{
    LicenseKey = licenseKey,
    ProductCode = productCode,
    InstallationId = installationId,
    MachineFingerprint = fingerprint
}));

AssertInvalid("heartbeat", await client.HeartbeatAsync(new HeartbeatRequest
{
    LicenseKey = licenseKey,
    ProductCode = productCode,
    InstallationId = installationId,
    MachineFingerprint = fingerprint,
    Sequence = 1
}));

AssertInvalid("deactivate", await client.DeactivateAsync(new DeactivationRequest
{
    LicenseKey = licenseKey,
    ProductCode = productCode,
    InstallationId = installationId,
    MachineFingerprint = fingerprint
}));

Console.WriteLine("live_sdk_compatibility=PASS");
EOF

cat > "$LIVE_TEST/NuGet.Config" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="qflm-local" value="$PACKAGES" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
EOF

echo "live_harness_created=PASS"

echo
echo "=== 5. LIVE PUBLIC SDK COMPATIBILITY TEST ==="

cd "$LIVE_TEST" || die "live harness directory missing"
dotnet restore --configfile "$LIVE_TEST/NuGet.Config" || die "live harness restore failed"

DOTNET_ROLL_FORWARD=Major QFLM_BASE_URL="$PUBLIC_URL/" dotnet run -c Release --no-restore || die "live SDK compatibility failed"

echo "live_public_sdk_compatibility=PASS"

echo
echo "=== 6. PUBLIC ROUTE REGRESSION ==="

for route in / /login /customers /products /licenses /installations /offline /security /audit /system; do
    CODE=$(curl -L -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL$route" || true)
    [ "$CODE" = 200 ] || die "public GUI regression: $route -> $CODE"
done

echo "public_route_regression=PASS"

echo
echo "=== 7. PRODUCTION NO-MUTATION CHECK ==="

FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
FINAL_LICENSES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
FINAL_ISSUANCES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
FINAL_AUDIT=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

[ "$FINAL_MIG" = "$MIG" ] || die "migration count changed"
[ "$FINAL_USERS" = "$USERS" ] || die "users changed"
[ "$FINAL_ROLES" = "$ROLES" ] || die "roles changed"
[ "$FINAL_PERMS" = "$PERMS" ] || die "permissions changed"
[ "$FINAL_LICENSES" = "$LICENSES" ] || die "licenses changed"
[ "$FINAL_INSTALLATIONS" = "$INSTALLATIONS" ] || die "installations changed"
[ "$FINAL_ISSUANCES" = "$ISSUANCES" ] || die "offline issuances changed"
[ "$FINAL_AUDIT" = "$AUDIT" ] || die "offline audit changed"

FINAL_API_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_GUI_IMAGE=$(docker inspect "$PROD_GUI" --format='{{.Config.Image}}')

[ "$FINAL_API_IMAGE" = "$PROD_API_IMAGE" ] || die "production API image changed"
[ "$FINAL_GUI_IMAGE" = "$PROD_GUI_IMAGE" ] || die "production GUI image changed"

echo "production_no_mutation=PASS"

echo
echo "=== 8. FREEZE SDK SOURCE + PACKAGE ==="

tar -czf "$BACKUP/QFLM.ClientSdk.0.1.0-source.tgz"   -C "$ROOT"   src/QFLM.ClientSdk   tests/QFLM.ClientSdk.Tests   QuikeFix.LicenseManager.slnx

SOURCE_SHA=$(sha256sum "$BACKUP/QFLM.ClientSdk.0.1.0-source.tgz" | awk '{print $1}')

cat > "$MANIFEST" <<EOF
QFLM_DOTNET_SDK_FREEZE=RECOVERY_7M4
UTC=$STAMP
SDK_PACKAGE=$SDK_PACKAGE
SDK_PACKAGE_SHA256=$SDK_SHA
SDK_SOURCE_ARCHIVE=$BACKUP/QFLM.ClientSdk.0.1.0-source.tgz
SDK_SOURCE_SHA256=$SOURCE_SHA
SDK_VERSION=0.1.0
SDK_TARGET_FRAMEWORK=net8.0
PUBLIC_API_BASE=$PUBLIC_URL
ACTIVATE_ENDPOINT=/api/v1/activate
VALIDATE_ENDPOINT=/api/v1/validate
HEARTBEAT_ENDPOINT=/api/v1/heartbeat
DEACTIVATE_ENDPOINT=/api/v1/deactivate
PRODUCTION_API_IMAGE=$PROD_API_IMAGE
PRODUCTION_GUI_IMAGE=$PROD_GUI_IMAGE
MIGRATIONS=$MIG
USERS=$USERS
ROLES=$ROLES
PERMISSIONS=$PERMS
LICENSES=$LICENSES
INSTALLATIONS=$INSTALLATIONS
OFFLINE_ISSUANCES=$ISSUANCES
OFFLINE_AUDIT=$AUDIT
LIVE_COMPATIBILITY=PASS
PRODUCTION_MUTATION=NONE
EOF

chmod 400 "$MANIFEST"

echo "sdk_freeze=PASS"

echo
echo "======================================================"
echo " QFLM RECOVERY 7M4 FINAL SDK FREEZE PASSED"
echo "======================================================"
echo ".NET CLIENT SDK:                    FINAL FROZEN"
echo "SDK VERSION:                        0.1.0"
echo "LIVE PUBLIC COMPATIBILITY:          PASS"
echo "ACTIVATE:                           PASS"
echo "VALIDATE:                           PASS"
echo "HEARTBEAT:                          PASS"
echo "DEACTIVATE:                         PASS"
echo "PRODUCTION API/DB:                  UNCHANGED"
echo "SDK PACKAGE:                        $SDK_PACKAGE"
echo "SDK PACKAGE SHA256:                 $SDK_SHA"
echo "SDK SOURCE SHA256:                  $SOURCE_SHA"
echo "FREEZE MANIFEST:                    $MANIFEST"
echo "REPORT:                             $REPORT"
echo "STATUS:                             RECOVERY_7M4_SDK_FINAL_FROZEN"
echo "NEXT: RECOVERY 7N - DOCUMENTATION / DR / MONITORING"
echo "======================================================"
