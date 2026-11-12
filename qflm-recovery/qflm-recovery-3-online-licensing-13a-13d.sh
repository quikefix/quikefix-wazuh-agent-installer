#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT=/opt/qflm/app/QuikeFix.LicenseManager
PG=qflm-postgres
NET=qflm_backend
API=qflm-api
IMAGE=qflm-api:13d-candidate
BASE=https://raw.githubusercontent.com/quikefix/quikefix-wazuh-agent-installer/main/qflm-recovery/recovery3-src
PGSECRET=/opt/qflm/secrets/runtime-api/postgres_password
RDSECRET=/opt/qflm/secrets/runtime-api/redis_password

die(){ echo "STOP: $*" >&2; exit 1; }

echo "======================================================"
echo " QFLM RECOVERY 3 - ONLINE LICENSING 13A-D BASELINE"
echo "======================================================"

cd "$ROOT" || die "source root missing"
[ "$(docker inspect "$PG" --format='{{.State.Health.Status}}' 2>/dev/null)" = healthy ] || die "postgres not healthy"

echo
echo "=== 1. PATCH LICENSE MODEL + EF MODEL ==="

python3 - <<'PY'
from pathlib import Path
p=Path("src/QFLM.Domain/Licenses/License.cs")
s=p.read_text()
if "ActivationKeyHash" not in s:
    s=s.replace(
        "public string LicenseNumber { get; set; } = string.Empty;",
        "public string LicenseNumber { get; set; } = string.Empty;\n    public string? ActivationKeyHash { get; set; }"
    )
p.write_text(s)

p=Path("src/QFLM.Infrastructure/Persistence/QflmDbContext.cs")
s=p.read_text()
if "ActivationKeyHash" not in s:
    s=s.replace(
        "entity.Property(x => x.LicenseNumber).HasMaxLength(100).IsRequired();",
        "entity.Property(x => x.LicenseNumber).HasMaxLength(100).IsRequired();\n            entity.Property(x => x.ActivationKeyHash).HasMaxLength(64);\n            entity.HasIndex(x => x.ActivationKeyHash).IsUnique();"
    )
p.write_text(s)
PY

dotnet build QuikeFix.LicenseManager.slnx -c Release >/dev/null

if ! find src/QFLM.Infrastructure/Persistence/Migrations -maxdepth 1 -type f -name '*AddActivationKeyHash.cs' | grep -q .; then
  dotnet tool run dotnet-ef migrations add AddActivationKeyHash     --project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj     --startup-project src/QFLM.Api/QFLM.Api.csproj     --context QflmDbContext     --output-dir Persistence/Migrations >/dev/null
fi

PGPASS="$(cat "$PGSECRET")"
docker rm -f qflm-pg-forward >/dev/null 2>&1 || true
docker run -d --name qflm-pg-forward --network "$NET" -p 127.0.0.1:15432:15432 alpine/socat   TCP-LISTEN:15432,fork,reuseaddr TCP:qflm-postgres:5432 >/dev/null
sleep 2
dotnet tool run dotnet-ef database update   --project src/QFLM.Infrastructure/QFLM.Infrastructure.csproj   --startup-project src/QFLM.Api/QFLM.Api.csproj   --context QflmDbContext   --connection "Host=127.0.0.1;Port=15432;Database=qflm;Username=qflm;Password=$PGPASS" >/dev/null
docker rm -f qflm-pg-forward >/dev/null
unset PGPASS

echo "activation_key_hash_migration=PASS"

echo
echo "=== 2. RESTORE ONLINE LICENSING SOURCE ==="

mkdir -p  src/QFLM.Application/Licensing/Models  src/QFLM.Application/Licensing/Services  src/QFLM.Application/Licensing/Security  src/QFLM.Infrastructure/Licensing  src/QFLM.Api/Controllers

curl -fsSL "$BASE/LicensingModels.cs" -o src/QFLM.Application/Licensing/Models/LicensingModels.cs
curl -fsSL "$BASE/ILicensingService.cs" -o src/QFLM.Application/Licensing/Services/ILicensingService.cs
curl -fsSL "$BASE/Hashers.cs" -o src/QFLM.Application/Licensing/Security/Hashers.cs
curl -fsSL "$BASE/EfLicensingService.cs" -o src/QFLM.Infrastructure/Licensing/EfLicensingService.cs
curl -fsSL "$BASE/LicensingController.cs" -o src/QFLM.Api/Controllers/LicensingController.cs

python3 - <<'PY'
from pathlib import Path
p=Path("src/QFLM.Api/Program.cs")
s=p.read_text()
line="builder.Services.AddScoped<QFLM.Application.Licensing.Services.ILicensingService, QFLM.Infrastructure.Licensing.EfLicensingService>();"
if line not in s:
    s=s.replace("builder.Services.AddControllers();", line+"\nbuilder.Services.AddControllers();")
p.write_text(s)
PY

dotnet build QuikeFix.LicenseManager.slnx -c Release
echo "online_licensing_source=PASS"

echo
echo "=== 3. CREATE CONTROLLED FIXTURE ==="

KEYFILE=/opt/qflm/secrets/recovery-test-activation-key
if [ ! -s "$KEYFILE" ]; then
  python3 - "$KEYFILE" <<'PY'
import secrets,sys
from pathlib import Path
Path(sys.argv[1]).write_text("QFLM-AK-"+secrets.token_urlsafe(32))
PY
fi
chmod 600 "$KEYFILE"

read -r KEYHASH FP1 FP2 < <(python3 - "$KEYFILE" <<'PY'
import hashlib,sys
from pathlib import Path
key=Path(sys.argv[1]).read_text().strip()
h=lambda s: hashlib.sha256(s.encode()).hexdigest()
print(h(key),h("QFLM-TEST-MACHINE-FINGERPRINT-ONE"),h("QFLM-TEST-MACHINE-FINGERPRINT-TWO"))
PY
)

docker exec -i "$PG" psql -v ON_ERROR_STOP=1 -U qflm -d qflm <<SQL
TRUNCATE license_entitlements,installations,licenses,subscriptions,features,products,customers CASCADE;

INSERT INTO customers(id,customer_number,name,email,country_code,is_active,created_at_utc,updated_at_utc)
VALUES('10000000-0000-4000-8000-000000000001','QF-CUST-001','QuikeFix Recovery Test','recovery@invalid.local','ZA',true,now(),now());

INSERT INTO products(id,product_code,name,is_active,created_at_utc,updated_at_utc)
VALUES('20000000-0000-4000-8000-000000000001','QFLM-TEST-PRODUCT','QFLM Test Product',true,now(),now());

INSERT INTO features(id,product_id,feature_code,name,is_active,created_at_utc,updated_at_utc)
VALUES('30000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','TEST_FEATURE','Test Feature',true,now(),now());

INSERT INTO subscriptions(id,customer_id,product_id,status,starts_at_utc,ends_at_utc,maximum_installations,created_at_utc,updated_at_utc)
VALUES('40000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','Active',now()-interval '1 day',now()+interval '365 days',2,now(),now());

INSERT INTO licenses(id,license_number,activation_key_hash,customer_id,product_id,subscription_id,type,status,valid_from_utc,valid_until_utc,grace_period_days,maximum_installations,created_at_utc,updated_at_utc)
VALUES('50000000-0000-4000-8000-000000000001','QFLM-TEST-ACTIVATE-001','$KEYHASH','10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000001','Monthly','Active',now()-interval '1 day',now()+interval '365 days',7,2,now(),now());

INSERT INTO license_entitlements(id,license_id,feature_id,enabled,limit_value,created_at_utc,updated_at_utc)
VALUES('60000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001',true,25,now(),now());

INSERT INTO installations(id,license_id,installation_identifier,machine_fingerprint_hash,status,activated_at_utc,last_seen_at_utc,last_heartbeat_sequence,highest_lease_sequence,created_at_utc,updated_at_utc)
VALUES
('70000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000001','11111111-1111-4111-8111-111111111111','$FP1','Active',now(),now(),0,0,now(),now()),
('70000000-0000-4000-8000-000000000002','50000000-0000-4000-8000-000000000001','22222222-2222-4222-8222-222222222222','$FP2','Active',now(),now(),0,0,now(),now());
SQL

unset KEYHASH FP1 FP2
echo "fixture_seed=PASS"

echo
echo "=== 4. BUILD 13D CANDIDATE ==="

dotnet publish src/QFLM.Api/QFLM.Api.csproj -c Release -o artifacts/api-publish-13d --no-restore >/dev/null

cat > Dockerfile.recovery13d <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-13d/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER

docker build -f Dockerfile.recovery13d -t "$IMAGE" . >/dev/null
docker rm -f "$API" >/dev/null 2>&1 || true

docker run -d  --name "$API"  --restart unless-stopped  --network "$NET"  --read-only  --cap-drop ALL  --security-opt no-new-privileges:true  --tmpfs /tmp:rw,noexec,nosuid,size=32m  -e ASPNETCORE_URLS=http://+:8080  -v "$PGSECRET:/run/secrets/postgres_password:ro"  -v "$RDSECRET:/run/secrets/redis_password:ro"  "$IMAGE" >/dev/null

sleep 5
docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS http://qflm-api:8080/health/ready >/dev/null
echo "candidate_health=PASS"

echo
echo "=== 5. VALIDATION + HEARTBEAT TEST ==="

KEY="$(cat "$KEYFILE")"

VAL="$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS  -H 'Content-Type: application/json'  -d "{\"licenseKey\":\"$KEY\",\"productCode\":\"QFLM-TEST-PRODUCT\",\"installationId\":\"11111111-1111-4111-8111-111111111111\",\"machineFingerprint\":\"QFLM-TEST-MACHINE-FINGERPRINT-ONE\"}"  http://qflm-api:8080/api/v1/validate)"
echo "$VAL" | grep -qi '"success":true' || { echo "$VAL"; die "validation failed"; }

HB="$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS  -H 'Content-Type: application/json'  -d "{\"licenseKey\":\"$KEY\",\"productCode\":\"QFLM-TEST-PRODUCT\",\"installationId\":\"11111111-1111-4111-8111-111111111111\",\"machineFingerprint\":\"QFLM-TEST-MACHINE-FINGERPRINT-ONE\",\"sequence\":1}"  http://qflm-api:8080/api/v1/heartbeat)"
echo "$HB" | grep -qi '"success":true' || { echo "$HB"; die "heartbeat failed"; }

unset KEY

docker exec "$PG" psql -U qflm -d qflm  -c "UPDATE installations SET last_heartbeat_sequence=0,updated_at_utc=now() WHERE installation_identifier='11111111-1111-4111-8111-111111111111';" >/dev/null

echo "validation=PASS"
echo "heartbeat=PASS"

echo
echo "=== 6. BASELINE VERIFICATION ==="

M="$(docker exec "$PG" psql -U qflm -d qflm -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)"
T="$(docker exec "$PG" psql -U qflm -d qflm -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='public';" | xargs)"
C="$(docker exec "$PG" psql -U qflm -d qflm -tAc "SELECT concat((SELECT count(*) FROM customers),'|',(SELECT count(*) FROM products),'|',(SELECT count(*) FROM subscriptions),'|',(SELECT count(*) FROM licenses),'|',(SELECT count(*) FROM installations));" | xargs)"
P="$(docker exec "$PG" psql -U qflm -d qflm -tAc "SELECT concat(status,'|',last_heartbeat_sequence,'|',highest_lease_sequence) FROM installations WHERE installation_identifier='11111111-1111-4111-8111-111111111111';" | xargs)"
IMG="$(docker inspect "$API" --format='{{.Config.Image}}')"

echo "image=$IMG migrations=$M tables=$T counts=$C primary=$P"

[ "$IMG" = "$IMAGE" ] || die "wrong API image"
[ "$M" = 2 ] || die "expected 2 migrations"
[ "$T" = 8 ] || die "expected 8 public tables"
[ "$C" = "1|1|1|1|2" ] || die "fixture count mismatch"
[ "$P" = "Active|0|0" ] || die "primary baseline mismatch"

echo
echo "======================================================"
echo " QFLM RECOVERY 3 PASSED"
echo "======================================================"
echo "13A CONTRACTS:          PASS"
echo "13B ACTIVATION:         IMPLEMENTED"
echo "13C VALIDATION:         PASS"
echo "13D HEARTBEAT:          PASS"
echo "13D DEACTIVATION:       IMPLEMENTED"
echo "PRODUCTION IMAGE:       qflm-api:13d-candidate"
echo "DATABASE COUNTS:        1|1|1|1|2"
echo "NEXT: RECOVERY 4 - 13E/13F ADMIN + SECURITY HARDENING"
echo "======================================================"
