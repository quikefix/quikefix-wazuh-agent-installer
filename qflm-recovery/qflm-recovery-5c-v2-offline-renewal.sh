#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT=/opt/qflm/app/QuikeFix.LicenseManager
OFFLINE=$ROOT/src/QFLM.OfflineLicensing
SIGNING=$ROOT/src/QFLM.SigningService
API=qflm-api
PG=qflm-postgres
DB=qflm
NET=qflm_backend
EXPECTED=qflm-api:13e-candidate

SECRET_DIR=/opt/qflm/secrets/signing
RUNTIME_SECRET_DIR=/opt/qflm/secrets/signing-runtime
PUBLIC_KEY=$SECRET_DIR/qflm-ed25519-public.pem
KEY_ID_FILE=$SECRET_DIR/signing-key-id
RUNTIME_PRIVATE_KEY=$RUNTIME_SECRET_DIR/private.pem
RUNTIME_PUBLIC_KEY=$RUNTIME_SECRET_DIR/public.pem
RUNTIME_TOKEN_FILE=$RUNTIME_SECRET_DIR/token
RUNTIME_KEY_ID_FILE=$RUNTIME_SECRET_DIR/key-id

PUBLISH=$ROOT/artifacts/signing-publish-14c
DOCKERFILE=$ROOT/Dockerfile.signing14c
IMAGE=qflm-signing:14c-candidate
CONTAINER=qflm-signing-14c-test
TESTDIR=/tmp/qflm-recovery5c

die(){ echo "STOP: $*" >&2; exit 1; }
cleanup(){ docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$TESTDIR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "======================================================"
echo " QFLM RECOVERY 5C - QFREQ/QFL + RENEWAL + TAMPER STATE"
echo "======================================================"

cd "$ROOT" || die "project root missing"
IMG="$(docker inspect "$API" --format='{{.Config.Image}}')" || die "API missing"
RUN="$(docker inspect "$API" --format='{{.State.Running}}')"
MIG="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
LIC="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)"
INST="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)"

[ "$IMG" = "$EXPECTED" ] || die "unexpected API image"
[ "$RUN" = true ] || die "API not running"
[ "$MIG" = 2 ] || die "unexpected migration count"

for f in "$PUBLIC_KEY" "$KEY_ID_FILE" "$RUNTIME_PRIVATE_KEY" "$RUNTIME_PUBLIC_KEY" "$RUNTIME_TOKEN_FILE" "$RUNTIME_KEY_ID_FILE"; do
  [ -s "$f" ] || die "missing Phase 14B material: $f"
done

mkdir -p "$OFFLINE/Files" "$OFFLINE/Validation" "$OFFLINE/Verification" "$TESTDIR"

cat > "$OFFLINE/Files/OfflineFileCodec.cs" <<'CS'
using QFLM.OfflineLicensing.Models;
using QFLM.OfflineLicensing.Serialization;
namespace QFLM.OfflineLicensing.Files;
public static class OfflineFileCodec
{
    public static void WriteRequest(string path, OfflineLicenseRequest request) => File.WriteAllBytes(path, CanonicalJson.SerializeUtf8(request));
    public static OfflineLicenseRequest ReadRequest(string path) => CanonicalJson.Deserialize<OfflineLicenseRequest>(File.ReadAllBytes(path));
    public static void WriteLicense(string path, SignedOfflineLicense license) => File.WriteAllBytes(path, CanonicalJson.SerializeUtf8(license));
    public static SignedOfflineLicense ReadLicense(string path) => CanonicalJson.Deserialize<SignedOfflineLicense>(File.ReadAllBytes(path));
    public static string Sha256Hex(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream)).ToLowerInvariant();
    }
}
CS

cat > "$OFFLINE/Validation/OfflineRequestValidator.cs" <<'CS'
using QFLM.OfflineLicensing.Models;
namespace QFLM.OfflineLicensing.Validation;
public static class OfflineRequestValidator
{
    public static IReadOnlyCollection<string> Validate(OfflineLicenseRequest request)
    {
        var e=new List<string>();
        if(request.SchemaVersion!=1)e.Add("Unsupported schemaVersion.");
        if(!Guid.TryParse(request.RequestId,out _))e.Add("requestId must be a UUID.");
        if(!Guid.TryParse(request.InstallationId,out _))e.Add("installationId must be a UUID.");
        if(string.IsNullOrWhiteSpace(request.ProductCode))e.Add("productCode is required.");
        if(request.MachineFingerprintHash.Length<16)e.Add("machineFingerprintHash is invalid.");
        if(string.IsNullOrWhiteSpace(request.InstallationPublicKey))e.Add("installationPublicKey is required.");
        if(string.IsNullOrWhiteSpace(request.Nonce)||request.Nonce.Length<16)e.Add("nonce is invalid.");
        return e;
    }
}
CS

cat > "$OFFLINE/Verification/OfflineRuntimeState.cs" <<'CS'
namespace QFLM.OfflineLicensing.Verification;
public sealed record OfflineRuntimeState
{
    public required DateTime LastTrustedUtc { get; init; }
    public required long HighestLeaseSequence { get; init; }
    public required string LastLicenseDigest { get; init; }
}
public sealed record OfflineEvaluationResult(bool Accepted,string State,bool AllowWriteOperations,string Reason);
CS

cat > "$OFFLINE/Verification/OfflineStateEvaluator.cs" <<'CS'
using QFLM.OfflineLicensing.Models;
namespace QFLM.OfflineLicensing.Verification;
public static class OfflineStateEvaluator
{
    public static OfflineEvaluationResult Evaluate(OfflineLicenseClaims claims, OfflineRuntimeState? localState, DateTime observedUtc, TimeSpan rollbackTolerance)
    {
        if(localState is not null && OfflineLicensePolicy.IsClockRollback(localState.LastTrustedUtc,observedUtc,rollbackTolerance))
            return new(false,"CLOCK_ROLLBACK",false,"Observed clock is earlier than trusted local time.");
        if(localState is not null && claims.LeaseSequence<localState.HighestLeaseSequence)
            return new(false,"LEASE_ROLLBACK",false,"License lease sequence is older than local trusted state.");
        if(observedUtc<claims.NotBeforeUtc)
            return new(false,"NOT_YET_VALID",false,"License is not yet valid.");
        if(!claims.ExpiresAtUtc.HasValue || observedUtc<=claims.ExpiresAtUtc.Value)
            return new(true,"ACTIVE",true,"Offline license is active.");
        if(claims.GraceEndsAtUtc.HasValue && observedUtc<=claims.GraceEndsAtUtc.Value)
            return new(true,"GRACE",true,"Offline license is within grace period.");
        return new(true,"RESTRICTED",false,"Offline license is restricted after expiry/grace.");
    }
}
CS

cat > "$SIGNING/IssueOfflineLicenseRequest.cs" <<'CS'
using QFLM.OfflineLicensing.Models;
namespace QFLM.SigningService;
public sealed record IssueOfflineLicenseRequest { public required OfflineLicenseClaims Claims { get; init; } }
public sealed record RenewOfflineLicenseRequest
{
    public required OfflineLicenseClaims PreviousClaims { get; init; }
    public required OfflineRenewalRequest RenewalRequest { get; init; }
    public required DateTime NewExpiresAtUtc { get; init; }
    public required DateTime NewGraceEndsAtUtc { get; init; }
}
CS

cat > "$SIGNING/OfflineLicenseEnvelopeFactory.cs" <<'CS'
using QFLM.OfflineLicensing.Models;
using QFLM.OfflineLicensing.Serialization;
namespace QFLM.SigningService;
public sealed class OfflineLicenseEnvelopeFactory(OpenSslEd25519Signer signer)
{
    public async Task<SignedOfflineLicense> CreateAsync(OfflineLicenseClaims claims,CancellationToken ct)
    {
        var payload=CanonicalJson.SerializeUtf8(claims);
        var sig=await signer.SignAsync(payload,ct);
        return new SignedOfflineLicense { SchemaVersion=1,Algorithm="Ed25519",KeyId=signer.KeyId,PayloadBase64=Convert.ToBase64String(payload),SignatureBase64=Convert.ToBase64String(sig) };
    }
}
CS

python3 - <<'PY'
from pathlib import Path
p=Path("src/QFLM.SigningService/Program.cs")
s=p.read_text()
if "OfflineLicenseEnvelopeFactory" not in s:
    s=s.replace("builder.Services.AddSingleton<SigningTokenValidator>();","builder.Services.AddSingleton<SigningTokenValidator>();\nbuilder.Services.AddSingleton<OfflineLicenseEnvelopeFactory>();")
insert='''
app.MapPost("/internal/v1/offline-license/issue", async (HttpRequest request, IssueOfflineLicenseRequest body, SigningTokenValidator validator, OfflineLicenseEnvelopeFactory factory, CancellationToken ct) =>
{
    if (!validator.IsValid(request.Headers["X-QFLM-Signing-Token"].FirstOrDefault())) return Results.Unauthorized();
    if (body.Claims.SchemaVersion != 1 || body.Claims.LeaseSequence < 1 || !Guid.TryParse(body.Claims.InstallationId, out _))
        return Results.BadRequest(new { error = "Offline license claims are invalid." });
    return Results.Ok(await factory.CreateAsync(body.Claims, ct));
});

app.MapPost("/internal/v1/offline-license/renew", async (HttpRequest request, RenewOfflineLicenseRequest body, SigningTokenValidator validator, OfflineLicenseEnvelopeFactory factory, CancellationToken ct) =>
{
    if (!validator.IsValid(request.Headers["X-QFLM-Signing-Token"].FirstOrDefault())) return Results.Unauthorized();
    if (!string.Equals(body.PreviousClaims.LicenseId,body.RenewalRequest.LicenseId,StringComparison.OrdinalIgnoreCase) ||
        !string.Equals(body.PreviousClaims.InstallationId,body.RenewalRequest.InstallationId,StringComparison.OrdinalIgnoreCase) ||
        body.RenewalRequest.CurrentLeaseSequence != body.PreviousClaims.LeaseSequence ||
        !body.PreviousClaims.ExpiresAtUtc.HasValue ||
        body.NewExpiresAtUtc <= body.PreviousClaims.ExpiresAtUtc.Value ||
        body.NewGraceEndsAtUtc < body.NewExpiresAtUtc)
        return Results.BadRequest(new { error = "Offline renewal request is invalid." });

    var now=DateTime.UtcNow;
    var renewed=body.PreviousClaims with { IssuedAtUtc=now,NotBeforeUtc=now,ExpiresAtUtc=body.NewExpiresAtUtc,GraceEndsAtUtc=body.NewGraceEndsAtUtc,LeaseSequence=checked(body.PreviousClaims.LeaseSequence+1) };
    return Results.Ok(await factory.CreateAsync(renewed,ct));
});
'''
    s=s.replace("app.Run();",insert+"\napp.Run();")
p.write_text(s)
PY

dotnet build QuikeFix.LicenseManager.slnx -c Release
rm -rf "$PUBLISH"
dotnet publish "$SIGNING/QFLM.SigningService.csproj" -c Release -o "$PUBLISH" >/dev/null

cat > "$DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
USER root
RUN apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --chown=app:app artifacts/signing-publish-14c/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.SigningService.dll"]
DOCKER

docker build -f "$DOCKERFILE" -t "$IMAGE" . >/dev/null
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

docker run -d  --name "$CONTAINER"  --network "$NET"  --read-only  --cap-drop ALL  --security-opt no-new-privileges:true  --tmpfs /tmp:rw,noexec,nosuid,size=16m  -e ASPNETCORE_URLS=http://0.0.0.0:8080  -e Signing__PrivateKeyPath=/run/qflm-signing/private.pem  -e Signing__PublicKeyPath=/run/qflm-signing/public.pem  -e Signing__TokenPath=/run/qflm-signing/token  -e Signing__KeyIdPath=/run/qflm-signing/key-id  -v "$RUNTIME_PRIVATE_KEY:/run/qflm-signing/private.pem:ro"  -v "$RUNTIME_PUBLIC_KEY:/run/qflm-signing/public.pem:ro"  -v "$RUNTIME_TOKEN_FILE:/run/qflm-signing/token:ro"  -v "$RUNTIME_KEY_ID_FILE:/run/qflm-signing/key-id:ro"  "$IMAGE" >/dev/null

sleep 5
BASE=http://$CONTAINER:8080
docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS "$BASE/health/ready" >/dev/null || die "signing readiness failed"

TOKEN="$(cat "$RUNTIME_TOKEN_FILE")"
IID=88888888-8888-4888-8888-888888888888
LICENSE_ID=50000000-0000-4000-8000-000000000001

python3 - "$TESTDIR/issue.json" "$IID" "$LICENSE_ID" <<'PY'
import json,sys,datetime
obj={"claims":{"schemaVersion":1,"licenseId":sys.argv[3],"productCode":"QFLM-TEST-PRODUCT","installationId":sys.argv[2],"machineFingerprintHash":"0a0b0c0d0e0f10111213141516171819","licenseType":"Monthly","effectiveState":"ACTIVE","issuedAtUtc":"2026-11-12T12:00:00Z","notBeforeUtc":"2026-11-12T12:00:00Z","expiresAtUtc":"2026-12-12T12:00:00Z","graceEndsAtUtc":"2026-12-19T12:00:00Z","leaseSequence":1,"entitlements":[]}}
json.dump(obj,open(sys.argv[1],"w"))
PY

ISSUE="$(cat "$TESTDIR/issue.json" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -fsS -H 'Content-Type: application/json' -H "X-QFLM-Signing-Token: $TOKEN" -X POST "$BASE/internal/v1/offline-license/issue" --data-binary @-)"
printf '%s' "$ISSUE" > "$TESTDIR/issue-response.json"

python3 - "$TESTDIR/issue-response.json" "$TESTDIR/payload.bin" "$TESTDIR/sig.bin" <<'PY'
import json,base64,sys
o=json.load(open(sys.argv[1]))
open(sys.argv[2],"wb").write(base64.b64decode(o["payloadBase64"],validate=True))
open(sys.argv[3],"wb").write(base64.b64decode(o["signatureBase64"],validate=True))
assert o["algorithm"]=="Ed25519"
PY

openssl pkeyutl -verify -pubin -inkey "$PUBLIC_KEY" -rawin -in "$TESTDIR/payload.bin" -sigfile "$TESTDIR/sig.bin" >/dev/null 2>&1 || die "issued qfl signature invalid"

python3 - "$TESTDIR/renew.json" "$TESTDIR/payload.bin" <<'PY'
import json,sys
prev=json.loads(open(sys.argv[2],"rb").read())
obj={"previousClaims":prev,"renewalRequest":{"schemaVersion":1,"requestId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","licenseId":prev["licenseId"],"installationId":prev["installationId"],"currentLeaseSequence":prev["leaseSequence"],"clientObservedUtc":"2026-11-20T12:00:00Z","previousLicenseDigest":"0"*64,"nonce":"1234567890abcdef1234567890abcdef"},"newExpiresAtUtc":"2027-01-12T12:00:00Z","newGraceEndsAtUtc":"2027-01-19T12:00:00Z"}
json.dump(obj,open(sys.argv[1],"w"))
PY

RENEW="$(cat "$TESTDIR/renew.json" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -fsS -H 'Content-Type: application/json' -H "X-QFLM-Signing-Token: $TOKEN" -X POST "$BASE/internal/v1/offline-license/renew" --data-binary @-)"
printf '%s' "$RENEW" > "$TESTDIR/renew-response.json"

python3 - "$TESTDIR/renew-response.json" "$TESTDIR/renew-payload.bin" "$TESTDIR/renew-sig.bin" <<'PY'
import json,base64,sys
o=json.load(open(sys.argv[1]))
p=base64.b64decode(o["payloadBase64"],validate=True)
claims=json.loads(p)
assert claims["leaseSequence"]==2
open(sys.argv[2],"wb").write(p)
open(sys.argv[3],"wb").write(base64.b64decode(o["signatureBase64"],validate=True))
PY

openssl pkeyutl -verify -pubin -inkey "$PUBLIC_KEY" -rawin -in "$TESTDIR/renew-payload.bin" -sigfile "$TESTDIR/renew-sig.bin" >/dev/null 2>&1 || die "renewed qfl signature invalid"

mkdir -p "$TESTDIR/state-test"
cat > "$TESTDIR/state-test/state.csproj" <<XML
<Project Sdk="Microsoft.NET.Sdk">
<PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework></PropertyGroup>
<ItemGroup><ProjectReference Include="$OFFLINE/QFLM.OfflineLicensing.csproj" /></ItemGroup>
</Project>
XML
cat > "$TESTDIR/state-test/Program.cs" <<'CS'
using QFLM.OfflineLicensing.Models;
using QFLM.OfflineLicensing.Verification;
var claims=new OfflineLicenseClaims{LicenseId="x",ProductCode="p",InstallationId="i",MachineFingerprintHash="h",LicenseType="Monthly",EffectiveState="ACTIVE",IssuedAtUtc=DateTime.UtcNow,NotBeforeUtc=DateTime.UtcNow.AddMinutes(-1),ExpiresAtUtc=DateTime.UtcNow.AddDays(1),GraceEndsAtUtc=DateTime.UtcNow.AddDays(2),LeaseSequence=2};
var ok=OfflineStateEvaluator.Evaluate(claims,new OfflineRuntimeState{LastTrustedUtc=DateTime.UtcNow.AddMinutes(-1),HighestLeaseSequence=2,LastLicenseDigest="d"},DateTime.UtcNow,TimeSpan.FromMinutes(5));
var clock=OfflineStateEvaluator.Evaluate(claims,new OfflineRuntimeState{LastTrustedUtc=DateTime.UtcNow,HighestLeaseSequence=2,LastLicenseDigest="d"},DateTime.UtcNow.AddHours(-1),TimeSpan.FromMinutes(5));
var lease=OfflineStateEvaluator.Evaluate(claims with { LeaseSequence=1 },new OfflineRuntimeState{LastTrustedUtc=DateTime.UtcNow.AddMinutes(-1),HighestLeaseSequence=2,LastLicenseDigest="d"},DateTime.UtcNow,TimeSpan.FromMinutes(5));
if(!ok.Accepted || clock.State!="CLOCK_ROLLBACK" || lease.State!="LEASE_ROLLBACK") Environment.Exit(1);
Console.WriteLine("OFFLINE_STATE=PASS");
CS
dotnet run --project "$TESTDIR/state-test/state.csproj" -c Release | grep -q OFFLINE_STATE=PASS || die "offline state evaluator failed"

unset TOKEN ISSUE RENEW

IMG2="$(docker inspect "$API" --format='{{.Config.Image}}')"
RUN2="$(docker inspect "$API" --format='{{.State.Running}}')"
MIG2="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
LIC2="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)"
INST2="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)"

[ "$IMG2" = "$IMG" ] || die "production image changed"
[ "$RUN2" = true ] || die "production API stopped"
[ "$MIG2" = "$MIG" ] || die "migration count changed"
[ "$LIC2" = "$LIC" ] || die "license count changed"
[ "$INST2" = "$INST" ] || die "installation count changed"

echo "======================================================"
echo " QFLM RECOVERY 5C PASSED"
echo "======================================================"
echo "QFREQ FILE MODEL:             PASS"
echo "QFL SIGNED ENVELOPE:          PASS"
echo "OFFLINE ISSUE ENDPOINT:       PASS"
echo "OFFLINE RENEWAL ENDPOINT:     PASS"
echo "LEASE SEQUENCE 1->2:          PASS"
echo "PUBLIC-KEY VERIFY:            PASS"
echo "CLOCK ROLLBACK DETECTION:     PASS"
echo "LEASE ROLLBACK DETECTION:     PASS"
echo "SIGNING IMAGE:                qflm-signing:14c-candidate"
echo "PRODUCTION API/DB:            UNCHANGED"
echo "NEXT: RECOVERY 5D - OFFLINE PERSISTENCE + PRODUCTION PROMOTION"
echo "======================================================"
