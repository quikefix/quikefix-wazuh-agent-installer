#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
SIGNING="$ROOT/src/QFLM.SigningService"
OFFLINE="$ROOT/src/QFLM.OfflineLicensing"
API="qflm-api"
PG="qflm-postgres"
DB="qflm"
EXPECTED_IMAGE="qflm-api:13e-candidate"
NET="qflm_backend"

SECRET_DIR="/opt/qflm/secrets/signing"
PRIVATE_KEY="$SECRET_DIR/qflm-ed25519-private.pem"
PUBLIC_KEY="$SECRET_DIR/qflm-ed25519-public.pem"
TOKEN_FILE="$SECRET_DIR/signing-api-token"
KEY_ID_FILE="$SECRET_DIR/signing-key-id"

RUNTIME_SECRET_DIR="/opt/qflm/secrets/signing-runtime"
RUNTIME_PRIVATE_KEY="$RUNTIME_SECRET_DIR/private.pem"
RUNTIME_PUBLIC_KEY="$RUNTIME_SECRET_DIR/public.pem"
RUNTIME_TOKEN_FILE="$RUNTIME_SECRET_DIR/token"
RUNTIME_KEY_ID_FILE="$RUNTIME_SECRET_DIR/key-id"

PUBLISH="$ROOT/artifacts/signing-publish-14b"
DOCKERFILE="$ROOT/Dockerfile.signing14b"
IMAGE="qflm-signing:14b-candidate"
CONTAINER="qflm-signing-14b-test"
TESTDIR="/tmp/qflm-recovery5b"

die(){ echo "STOP: $*" >&2; exit 1; }

cleanup(){
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$TESTDIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "======================================================"
echo " QFLM RECOVERY 5B - PHASE 14B SIGNING KEY LIFECYCLE"
echo "======================================================"

cd "$ROOT" || die "project root missing"

IMG="$(docker inspect "$API" --format='{{.Config.Image}}')" || die "API missing"
RUN="$(docker inspect "$API" --format='{{.State.Running}}')"
MIG="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
LIC="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)"
INST="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)"

[ "$IMG" = "$EXPECTED_IMAGE" ] || die "unexpected API image"
[ "$RUN" = true ] || die "API not running"
[ "$MIG" = 2 ] || die "unexpected migration count"
[ -s "$OFFLINE/QFLM.OfflineLicensing.csproj" ] || die "offline project missing"
[ -s "$SIGNING/QFLM.SigningService.csproj" ] || die "signing project missing"
grep -q 'SignedOfflineLicense' "$OFFLINE/Models/OfflineLicenseModels.cs" || die "signed model missing"
grep -q 'OfflineLicenseRequest' "$OFFLINE/Models/OfflineLicenseModels.cs" || die "request model missing"

echo "baseline=PASS"

install -d -m 700 -o root -g root "$SECRET_DIR"

if [ ! -s "$PRIVATE_KEY" ]; then
  openssl genpkey -algorithm ED25519 -out "$PRIVATE_KEY" >/dev/null 2>&1
  chmod 600 "$PRIVATE_KEY"
fi

if [ ! -s "$PUBLIC_KEY" ]; then
  openssl pkey -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY" >/dev/null 2>&1
  chmod 644 "$PUBLIC_KEY"
fi

if [ ! -s "$TOKEN_FILE" ]; then
  openssl rand -hex 32 > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi

if [ ! -s "$KEY_ID_FILE" ]; then
  TMPDER="$(mktemp)"
  openssl pkey -pubin -in "$PUBLIC_KEY" -outform DER -out "$TMPDER" >/dev/null 2>&1
  KID="$(sha256sum "$TMPDER" | awk '{print substr($1,1,16)}')"
  rm -f "$TMPDER"
  printf 'qflm-ed25519-%s\n' "$KID" > "$KEY_ID_FILE"
  chmod 600 "$KEY_ID_FILE"
fi

TMPPUB="$(mktemp)"
openssl pkey -in "$PRIVATE_KEY" -pubout -out "$TMPPUB" >/dev/null 2>&1
cmp -s "$PUBLIC_KEY" "$TMPPUB" || die "public/private key mismatch"
rm -f "$TMPPUB"

KEY_ID="$(cat "$KEY_ID_FILE")"

APP_UID="$(docker run --rm --entrypoint /usr/bin/id mcr.microsoft.com/dotnet/aspnet:10.0 -u app | xargs)"
APP_GID="$(docker run --rm --entrypoint /usr/bin/id mcr.microsoft.com/dotnet/aspnet:10.0 -g app | xargs)"

install -d -m 700 -o root -g root "$RUNTIME_SECRET_DIR"
install -m 0400 -o "$APP_UID" -g "$APP_GID" "$PRIVATE_KEY" "$RUNTIME_PRIVATE_KEY"
install -m 0400 -o "$APP_UID" -g "$APP_GID" "$PUBLIC_KEY" "$RUNTIME_PUBLIC_KEY"
install -m 0400 -o "$APP_UID" -g "$APP_GID" "$TOKEN_FILE" "$RUNTIME_TOKEN_FILE"
install -m 0400 -o "$APP_UID" -g "$APP_GID" "$KEY_ID_FILE" "$RUNTIME_KEY_ID_FILE"

for f in "$RUNTIME_PRIVATE_KEY" "$RUNTIME_PUBLIC_KEY" "$RUNTIME_TOKEN_FILE" "$RUNTIME_KEY_ID_FILE"; do
  [ -s "$f" ] || die "runtime secret missing"
  [ "$(stat -c %a "$f")" = 400 ] || die "runtime secret mode invalid"
  [ "$(stat -c %u "$f")" = "$APP_UID" ] || die "runtime secret owner invalid"
done

echo "key_lifecycle=PASS"
echo "private_key_displayed=NO"
echo "signing_token_displayed=NO"

cat > "$SIGNING/SigningOptions.cs" <<'CS'
namespace QFLM.SigningService;
public sealed class SigningOptions
{
    public required string PrivateKeyPath { get; init; }
    public required string PublicKeyPath { get; init; }
    public required string TokenPath { get; init; }
    public required string KeyIdPath { get; init; }
}
CS

cat > "$SIGNING/SignPayloadRequest.cs" <<'CS'
namespace QFLM.SigningService;
public sealed record SignPayloadRequest { public required string PayloadBase64 { get; init; } }
public sealed record SignPayloadResponse
{
    public required string Algorithm { get; init; }
    public required string KeyId { get; init; }
    public required string SignatureBase64 { get; init; }
}
CS

cat > "$SIGNING/OpenSslEd25519Signer.cs" <<'CS'
using System.Diagnostics;
namespace QFLM.SigningService;
public sealed class OpenSslEd25519Signer(SigningOptions options)
{
    public string KeyId => File.ReadAllText(options.KeyIdPath).Trim();
    public string PublicKeyPem => File.ReadAllText(options.PublicKeyPath);

    public async Task<byte[]> SignAsync(byte[] payload, CancellationToken ct)
    {
        var input = Path.Combine(Path.GetTempPath(), $"qflm-sign-{Guid.NewGuid():N}.bin");
        var output = Path.Combine(Path.GetTempPath(), $"qflm-sig-{Guid.NewGuid():N}.bin");
        try
        {
            await File.WriteAllBytesAsync(input, payload, ct);
            var psi = new ProcessStartInfo("/usr/bin/openssl")
            {
                RedirectStandardError = true,
                UseShellExecute = false
            };
            foreach (var a in new[] {"pkeyutl","-sign","-inkey",options.PrivateKeyPath,"-rawin","-in",input,"-out",output}) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi) ?? throw new InvalidOperationException("OpenSSL start failed.");
            var err = p.StandardError.ReadToEndAsync(ct);
            await p.WaitForExitAsync(ct);
            var e = await err;
            if (p.ExitCode != 0) throw new InvalidOperationException($"Ed25519 signing failed: {e}");
            return await File.ReadAllBytesAsync(output, ct);
        }
        finally
        {
            try { File.Delete(input); } catch {}
            try { File.Delete(output); } catch {}
        }
    }
}
CS

cat > "$SIGNING/SigningTokenValidator.cs" <<'CS'
using System.Security.Cryptography;
using System.Text;
namespace QFLM.SigningService;
public sealed class SigningTokenValidator
{
    private readonly byte[] expected;
    public SigningTokenValidator(SigningOptions options) =>
        expected = SHA256.HashData(Encoding.UTF8.GetBytes(File.ReadAllText(options.TokenPath).Trim()));
    public bool IsValid(string? supplied)
    {
        if (string.IsNullOrWhiteSpace(supplied)) return false;
        var actual = SHA256.HashData(Encoding.UTF8.GetBytes(supplied.Trim()));
        return CryptographicOperations.FixedTimeEquals(expected, actual);
    }
}
CS

cat > "$SIGNING/Program.cs" <<'CS'
using QFLM.SigningService;
var builder = WebApplication.CreateBuilder(args);

string Get(string k) => builder.Configuration[k] ?? throw new InvalidOperationException($"Missing {k}");
var options = new SigningOptions
{
    PrivateKeyPath = Get("Signing:PrivateKeyPath"),
    PublicKeyPath = Get("Signing:PublicKeyPath"),
    TokenPath = Get("Signing:TokenPath"),
    KeyIdPath = Get("Signing:KeyIdPath")
};

foreach (var p in new[]{options.PrivateKeyPath,options.PublicKeyPath,options.TokenPath,options.KeyIdPath})
    if (!File.Exists(p)) throw new FileNotFoundException("Signing material missing", p);

builder.Services.AddSingleton(options);
builder.Services.AddSingleton<OpenSslEd25519Signer>();
builder.Services.AddSingleton<SigningTokenValidator>();

var app = builder.Build();
app.MapGet("/health/live", () => Results.Ok(new { status="live", service="qflm-signing" }));
app.MapGet("/health/ready", (OpenSslEd25519Signer s) => Results.Ok(new { status="ready", service="qflm-signing", algorithm="Ed25519", keyId=s.KeyId }));

app.MapGet("/internal/v1/public-key", (HttpRequest r, SigningTokenValidator v, OpenSslEd25519Signer s) =>
{
    if (!v.IsValid(r.Headers["X-QFLM-Signing-Token"].FirstOrDefault())) return Results.Unauthorized();
    return Results.Ok(new { algorithm="Ed25519", keyId=s.KeyId, publicKeyPem=s.PublicKeyPem });
});

app.MapPost("/internal/v1/sign", async (HttpRequest r, SignPayloadRequest body, SigningTokenValidator v, OpenSslEd25519Signer s, CancellationToken ct) =>
{
    if (!v.IsValid(r.Headers["X-QFLM-Signing-Token"].FirstOrDefault())) return Results.Unauthorized();
    byte[] payload;
    try { payload = Convert.FromBase64String(body.PayloadBase64); }
    catch { return Results.BadRequest(new { error="payloadBase64 is invalid." }); }
    if (payload.Length == 0 || payload.Length > 1048576) return Results.BadRequest(new { error="payload size is invalid." });
    var sig = await s.SignAsync(payload, ct);
    return Results.Ok(new SignPayloadResponse { Algorithm="Ed25519", KeyId=s.KeyId, SignatureBase64=Convert.ToBase64String(sig) });
});

app.Run();
CS

dotnet build QuikeFix.LicenseManager.slnx -c Release
rm -rf "$PUBLISH"
dotnet publish "$SIGNING/QFLM.SigningService.csproj" -c Release -o "$PUBLISH" >/dev/null

cat > "$DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
USER root
RUN apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --chown=app:app artifacts/signing-publish-14b/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.SigningService.dll"]
DOCKER

docker build -f "$DOCKERFILE" -t "$IMAGE" . >/dev/null

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d   --name "$CONTAINER"   --network "$NET"   --read-only   --cap-drop ALL   --security-opt no-new-privileges:true   --tmpfs /tmp:rw,noexec,nosuid,size=16m   -e ASPNETCORE_URLS=http://0.0.0.0:8080   -e Signing__PrivateKeyPath=/run/qflm-signing/private.pem   -e Signing__PublicKeyPath=/run/qflm-signing/public.pem   -e Signing__TokenPath=/run/qflm-signing/token   -e Signing__KeyIdPath=/run/qflm-signing/key-id   -v "$RUNTIME_PRIVATE_KEY:/run/qflm-signing/private.pem:ro"   -v "$RUNTIME_PUBLIC_KEY:/run/qflm-signing/public.pem:ro"   -v "$RUNTIME_TOKEN_FILE:/run/qflm-signing/token:ro"   -v "$RUNTIME_KEY_ID_FILE:/run/qflm-signing/key-id:ro"   "$IMAGE" >/dev/null

sleep 5

SEC="$(docker inspect "$CONTAINER" --format='user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .HostConfig.PortBindings}}')"
echo "$SEC" | grep -q 'user=app' || die "user hardening missing"
echo "$SEC" | grep -q 'readonly=true' || die "readonly missing"
echo "$SEC" | grep -q 'capdrop=\["ALL"\]' || die "capdrop missing"
echo "$SEC" | grep -q 'no-new-privileges:true' || die "NNP missing"
echo "$SEC" | grep -q 'ports={}' || die "host port exposed"

BASE="http://$CONTAINER:8080"
docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS "$BASE/health/ready" >/dev/null

UNAUTH="$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' "$BASE/internal/v1/public-key")"
[ "$UNAUTH" = 401 ] || die "unauthorized request not rejected"

mkdir -p "$TESTDIR"
printf '%s' '{"schemaVersion":1,"licenseId":"phase14b-test","productCode":"QFLM-TEST-PRODUCT","installationId":"99999999-9999-4999-8999-999999999999","effectiveState":"ACTIVE","leaseSequence":1}' > "$TESTDIR/payload.json"

TOKEN="$(cat "$RUNTIME_TOKEN_FILE")"
PAYLOAD64="$(base64 -w0 "$TESTDIR/payload.json")"
REQ="$(python3 - "$PAYLOAD64" <<'PY'
import json,sys
print(json.dumps({"payloadBase64":sys.argv[1]}))
PY
)"

RESP="$(printf '%s' "$REQ" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -fsS  -H 'Content-Type: application/json'  -H "X-QFLM-Signing-Token: $TOKEN"  -X POST "$BASE/internal/v1/sign" --data-binary @-)"

printf '%s' "$RESP" > "$TESTDIR/resp.json"

python3 - "$TESTDIR/resp.json" "$TESTDIR/signature.bin" "$KEY_ID" <<'PY'
import base64,json,sys
o=json.load(open(sys.argv[1]))
assert o["algorithm"]=="Ed25519"
assert o["keyId"]==sys.argv[3]
sig=base64.b64decode(o["signatureBase64"], validate=True)
assert len(sig)==64
open(sys.argv[2],"wb").write(sig)
PY

openssl pkeyutl -verify -pubin -inkey "$PUBLIC_KEY" -rawin -in "$TESTDIR/payload.json" -sigfile "$TESTDIR/signature.bin" >/dev/null 2>&1 || die "signature verify failed"

cp "$TESTDIR/payload.json" "$TESTDIR/tampered.json"
printf ' ' >> "$TESTDIR/tampered.json"
if openssl pkeyutl -verify -pubin -inkey "$PUBLIC_KEY" -rawin -in "$TESTDIR/tampered.json" -sigfile "$TESTDIR/signature.bin" >/dev/null 2>&1; then
  die "tamper detection failed"
fi

unset TOKEN PAYLOAD64 REQ RESP

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
echo " QFLM RECOVERY 5B PASSED"
echo "======================================================"
echo "PERSISTENT ED25519 KEYPAIR:      READY"
echo "RUNTIME SECRET COPIES:           READY / 0400"
echo "KEY ID:                          $KEY_ID"
echo "SIGNING TOKEN:                   READY / NOT DISPLAYED"
echo "INTERNAL SIGNING SERVICE:        PASS"
echo "UNAUTHORIZED REJECTION:          PASS"
echo "ED25519 SIGN/VERIFY:             PASS"
echo "TAMPER DETECTION:                PASS"
echo "HOST PORT EXPOSURE:              NONE"
echo "PRODUCTION API/DB:               UNCHANGED"
echo "NEXT: RECOVERY 5C - QFREQ/QFL RENEWAL + OFFLINE PERSISTENCE"
echo "======================================================"
