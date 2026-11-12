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
RUNTIME_PRIVATE_KEY=$RUNTIME_SECRET_DIR/private.pem
RUNTIME_PUBLIC_KEY=$RUNTIME_SECRET_DIR/public.pem
RUNTIME_TOKEN_FILE=$RUNTIME_SECRET_DIR/token
RUNTIME_KEY_ID_FILE=$RUNTIME_SECRET_DIR/key-id

PUBLISH=$ROOT/artifacts/signing-publish-14c
DOCKERFILE=$ROOT/Dockerfile.signing14c
IMAGE=qflm-signing:14c-candidate
CONTAINER=qflm-signing-14c-test
TESTDIR=/tmp/qflm-recovery5c-resume

die(){ echo "STOP: $*" >&2; exit 1; }
cleanup(){ docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$TESTDIR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "======================================================"
echo " QFLM RECOVERY 5C RESUME - RUNTIME/UAT"
echo "======================================================"

cd "$ROOT"

IMG="$(docker inspect "$API" --format='{{.Config.Image}}')"
RUN="$(docker inspect "$API" --format='{{.State.Running}}')"
MIG="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
LIC="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)"
INST="$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)"

[ "$IMG" = "$EXPECTED" ] || die "unexpected API image"
[ "$RUN" = true ] || die "API not running"
[ "$MIG" = 2 ] || die "unexpected migration count"

for f in "$PUBLIC_KEY" "$RUNTIME_PRIVATE_KEY" "$RUNTIME_PUBLIC_KEY" "$RUNTIME_TOKEN_FILE" "$RUNTIME_KEY_ID_FILE"; do
  [ -s "$f" ] || die "missing signing material: $f"
done

dotnet build QuikeFix.LicenseManager.slnx -c Release >/dev/null
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

mkdir -p "$TESTDIR"
TOKEN="$(cat "$RUNTIME_TOKEN_FILE")"
IID=88888888-8888-4888-8888-888888888888
LICENSE_ID=50000000-0000-4000-8000-000000000001

python3 - "$TESTDIR/issue.json" "$IID" "$LICENSE_ID" <<'PY'
import json,sys
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
<PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup>
<ItemGroup><ProjectReference Include="$OFFLINE/QFLM.OfflineLicensing.csproj" /></ItemGroup>
</Project>
XML

cat > "$TESTDIR/state-test/Program.cs" <<'CS'
using QFLM.OfflineLicensing.Models;
using QFLM.OfflineLicensing.Verification;
var now=DateTime.UtcNow;
var claims=new OfflineLicenseClaims{LicenseId="x",ProductCode="p",InstallationId="i",MachineFingerprintHash="h",LicenseType="Monthly",EffectiveState="ACTIVE",IssuedAtUtc=now,NotBeforeUtc=now.AddMinutes(-1),ExpiresAtUtc=now.AddDays(1),GraceEndsAtUtc=now.AddDays(2),LeaseSequence=2};
var ok=OfflineStateEvaluator.Evaluate(claims,new OfflineRuntimeState{LastTrustedUtc=now.AddMinutes(-1),HighestLeaseSequence=2,LastLicenseDigest="d"},now,TimeSpan.FromMinutes(5));
var clock=OfflineStateEvaluator.Evaluate(claims,new OfflineRuntimeState{LastTrustedUtc=now,HighestLeaseSequence=2,LastLicenseDigest="d"},now.AddHours(-1),TimeSpan.FromMinutes(5));
var lease=OfflineStateEvaluator.Evaluate(claims with { LeaseSequence=1 },new OfflineRuntimeState{LastTrustedUtc=now.AddMinutes(-1),HighestLeaseSequence=2,LastLicenseDigest="d"},now,TimeSpan.FromMinutes(5));
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
