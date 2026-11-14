#!/usr/bin/env bash
# QFLM RECOVERY 7I2
# System / Operations GUI/API - isolated validation.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API="$ROOT/src/QFLM.Api"
GUI="$ROOT/src/QFLM.AdminWeb"

PROD_API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"

ISO_DB="qflm_recovery7i2_test"
ISO_API="qflm-api-recovery7i2-test"
ISO_GUI="qflm-admin-web-recovery7i2-test"
NET="qflm_backend"

PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"

EXPECTED_PROD_IMAGE="qflm-api:recovery6f3-candidate"
API_IMAGE="qflm-api:recovery7i2-candidate"
GUI_IMAGE="qflm-admin-web:recovery7i2-candidate"

ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7i2-$STAMP"
REPORT="$BACKUP/recovery7i2-report.txt"
SOURCE_BACKUP="$BACKUP/source-before-recovery7i2.tgz"
DB_DUMP="$BACKUP/qflm-before-recovery7i2.dump"
ENV_FILE="$BACKUP/isolated-api.env"
API_PUBLISH="$ROOT/artifacts/api-publish-recovery7i2"
API_DOCKERFILE="$ROOT/Dockerfile.recovery7i2-api"
GUI_DOCKERFILE="$ROOT/Dockerfile.recovery7i2-gui"
GUI_NGINX_CONF="$ROOT/artifacts/recovery7i2-nginx.conf"

MUTATED=0
COMPLETED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

cleanup(){
    docker rm -f "$ISO_GUI" >/dev/null 2>&1 || true
    docker rm -f "$ISO_API" >/dev/null 2>&1 || true
    if [ "$COMPLETED" -ne 1 ] && [ "$MUTATED" -eq 1 ] && [ -s "$SOURCE_BACKUP" ]; then
        printf '\n=== SOURCE ROLLBACK ===\n'
        rm -rf "$API" "$GUI"
        mkdir -p "$ROOT/src"
        tar -xzf "$SOURCE_BACKUP" -C "$ROOT" >/dev/null 2>&1 || true
        printf '%s\n' "source_restore_attempted=YES"
    fi
}
trap cleanup EXIT

mkdir -p "$BACKUP" "$ROOT/artifacts"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

echo "======================================================"
echo " QFLM RECOVERY 7I2"
echo " SYSTEM / OPERATIONS GUI/API"
echo " ISOLATED VALIDATION"
echo "======================================================"

echo
echo "=== 1. PRODUCTION + PREVIEW SAFETY BASELINE ==="

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
PROD_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
PROD_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PROD_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)

[ "$PROD_IMAGE" = "$EXPECTED_PROD_IMAGE" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"
[ "$PREVIEW_API_RUNNING" = true ] || die "preview API not running"
[ "$PREVIEW_GUI_RUNNING" = true ] || die "preview GUI not running"
[ "$PREVIEW_API_IMAGE" = "qflm-api:recovery7h2-candidate" ] || die "unexpected preview API image"
[ "$PREVIEW_GUI_IMAGE" = "qflm-admin-web:recovery7h3-preview" ] || die "unexpected preview GUI image"

SYSTEM_PERMISSION=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM auth_permissions WHERE code='system.manage';" | xargs)
[ "$SYSTEM_PERMISSION" = 1 ] || die "system.manage permission missing"

echo "production_preview_baseline=PASS"

echo
echo "=== 2. BACKUP SOURCE + PRODUCTION DATABASE ==="

tar -czf "$SOURCE_BACKUP" -C "$ROOT" "src/QFLM.Api" "src/QFLM.AdminWeb" || die "source backup failed"
docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" -Fc > "$DB_DUMP" || die "production DB backup failed"
[ -s "$SOURCE_BACKUP" ] || die "source backup empty"
[ -s "$DB_DUMP" ] || die "database backup empty"

MUTATED=1

echo
echo "=== 3. REGISTER SYSTEM AUTHORIZATION POLICY ==="

python3 - "$API/Program.cs" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
if '"system.manage"' not in s:
    marker='            "audit.read"'
    if marker not in s:
        raise SystemExit("authorization marker missing")
    s=s.replace(marker, marker+',\n            "system.manage"', 1)
p.write_text(s)
PY

grep -Fq '"system.manage"' "$API/Program.cs" || die "system.manage policy registration failed"
echo "system_policy=CREATED"

echo
echo "=== 4. CREATE SYSTEM / OPERATIONS API ==="

cat > "$API/Controllers/AdminSystemOperationsController.cs" <<'CS'
using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Npgsql;
using StackExchange.Redis;

namespace QFLM.Api.Controllers;

[ApiController]
[Route("api/v1/admin/system")]
[Authorize(Policy = "permission:system.manage")]
public sealed class AdminSystemOperationsController : ControllerBase
{
    private readonly NpgsqlDataSource _dataSource;
    private readonly IConnectionMultiplexer _redis;

    public AdminSystemOperationsController(
        NpgsqlDataSource dataSource,
        IConnectionMultiplexer redis)
    {
        _dataSource = dataSource;
        _redis = redis;
    }

    [HttpGet("summary")]
    public async Task<IActionResult> Summary(CancellationToken cancellationToken)
    {
        var dbStarted = DateTime.UtcNow;
        await using var command = _dataSource.CreateCommand("""
SELECT
 (SELECT count(*) FROM customers),
 (SELECT count(*) FROM products),
 (SELECT count(*) FROM licenses),
 (SELECT count(*) FROM installations),
 (SELECT count(*) FROM auth_users WHERE is_active=true),
 (SELECT count(*) FROM offline_license_audit_events),
 NOW();
""");
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
            return StatusCode(500);

        var dbLatencyMs = Math.Max(0, (DateTime.UtcNow - dbStarted).TotalMilliseconds);

        var redisStarted = DateTime.UtcNow;
        var redisPing = await _redis.GetDatabase().PingAsync();
        var redisLatencyMs = Math.Max(0, redisPing.TotalMilliseconds);

        var assembly = Assembly.GetExecutingAssembly().GetName();

        return Ok(new
        {
            status = "Operational",
            generatedAtUtc = DateTime.UtcNow,
            api = new
            {
                name = assembly.Name,
                version = assembly.Version?.ToString() ?? "unknown",
                dotnet = Environment.Version.ToString(),
                os = RuntimeInformation.OSDescription,
                architecture = RuntimeInformation.ProcessArchitecture.ToString(),
                processorCount = Environment.ProcessorCount
            },
            database = new
            {
                status = "Healthy",
                latencyMs = Math.Round(dbLatencyMs, 2)
            },
            redis = new
            {
                status = "Healthy",
                latencyMs = Math.Round(redisLatencyMs, 2)
            },
            data = new
            {
                customers = reader.GetInt64(0),
                products = reader.GetInt64(1),
                licenses = reader.GetInt64(2),
                installations = reader.GetInt64(3),
                activeUsers = reader.GetInt64(4),
                auditEvents = reader.GetInt64(5),
                databaseUtc = reader.GetDateTime(6)
            }
        });
    }
}
CS

echo "system_operations_api=CREATED"

echo
echo "=== 5. CREATE SYSTEM / OPERATIONS GUI ==="

cat > "$GUI/src/pages/SystemPage.tsx" <<'TSX'
import { useEffect, useState } from "react";
import { apiFetch } from "../lib/api";

type SystemSummary = {
  status: string;
  generatedAtUtc: string;
  api: {
    name: string;
    version: string;
    dotnet: string;
    os: string;
    architecture: string;
    processorCount: number;
  };
  database: { status: string; latencyMs: number };
  redis: { status: string; latencyMs: number };
  data: {
    customers: number;
    products: number;
    licenses: number;
    installations: number;
    activeUsers: number;
    auditEvents: number;
    databaseUtc: string;
  };
};

export function SystemPage() {
  const [summary, setSummary] = useState<SystemSummary | null>(null);
  const [error, setError] = useState("");

  async function load() {
    setError("");
    try {
      setSummary(await apiFetch<SystemSummary>("/v1/admin/system/summary"));
    } catch {
      setError("System status could not be loaded.");
    }
  }

  useEffect(() => { load(); }, []);

  return (
    <>
      <div className="page-heading">
        <div>
          <h1>System</h1>
          <p>Platform health, runtime and operational status.</p>
        </div>
        <button className="secondary-button" onClick={load}>Refresh</button>
      </div>

      {error && <div className="page-error">{error}</div>}

      <div className="system-status-grid">
        <article className="panel">
          <h2>Platform</h2>
          <div className="status-row"><span>Status</span><b>{summary?.status ?? "Loading"}</b></div>
          <div className="status-row"><span>API</span><b>{summary?.api.name ?? "-"}</b></div>
          <div className="status-row"><span>Version</span><b>{summary?.api.version ?? "-"}</b></div>
          <div className="status-row"><span>.NET</span><b>{summary?.api.dotnet ?? "-"}</b></div>
        </article>

        <article className="panel">
          <h2>Dependencies</h2>
          <div className="status-row"><span>PostgreSQL</span><b>{summary?.database.status ?? "Loading"}</b></div>
          <div className="status-row"><span>DB latency</span><b>{summary ? summary.database.latencyMs + " ms" : "-"}</b></div>
          <div className="status-row"><span>Redis</span><b>{summary?.redis.status ?? "Loading"}</b></div>
          <div className="status-row"><span>Redis latency</span><b>{summary ? summary.redis.latencyMs + " ms" : "-"}</b></div>
        </article>

        <article className="panel">
          <h2>Runtime</h2>
          <div className="status-row"><span>OS</span><b>{summary?.api.os ?? "-"}</b></div>
          <div className="status-row"><span>Architecture</span><b>{summary?.api.architecture ?? "-"}</b></div>
          <div className="status-row"><span>Processors</span><b>{summary?.api.processorCount ?? "-"}</b></div>
          <div className="status-row"><span>Generated</span><b>{summary ? new Date(summary.generatedAtUtc).toLocaleString() : "-"}</b></div>
        </article>
      </div>

      <article className="panel">
        <h2>Operational data</h2>
        <div className="system-data-grid">
          <div><span>Customers</span><strong>{summary?.data.customers ?? "-"}</strong></div>
          <div><span>Products</span><strong>{summary?.data.products ?? "-"}</strong></div>
          <div><span>Licenses</span><strong>{summary?.data.licenses ?? "-"}</strong></div>
          <div><span>Installations</span><strong>{summary?.data.installations ?? "-"}</strong></div>
          <div><span>Active users</span><strong>{summary?.data.activeUsers ?? "-"}</strong></div>
          <div><span>Audit events</span><strong>{summary?.data.auditEvents ?? "-"}</strong></div>
        </div>
      </article>
    </>
  );
}
TSX

python3 - "$GUI/src/App.tsx" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text()
imp='import { SystemPage } from "./pages/SystemPage";'
if imp not in s:
    marker='import { AuditReportsPage } from "./pages/AuditReportsPage";'
    if marker not in s:
        raise SystemExit("AuditReportsPage import marker missing")
    s=s.replace(marker, marker+"\n"+imp, 1)

pattern=re.compile(
    r'\s*<Route\s+path="system"\s+element=\{\s*<PlaceholderPage\s+title="System"\s+description="Platform health and operational configuration\."\s*/>\s*\}\s*/>',
    re.S
)
replacement='\n            <Route path="system" element={<SystemPage />} />'
if pattern.search(s):
    s=pattern.sub(replacement,s,count=1)
elif '<Route path="system" element={<SystemPage />} />' not in s:
    raise SystemExit("system placeholder route marker missing")
p.write_text(s)
PY

cat >> "$GUI/src/styles.css" <<'CSS'

/* Phase 16I - System / Operations */
.system-status-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 16px;
  margin-bottom: 18px;
}
.system-data-grid {
  display: grid;
  grid-template-columns: repeat(6, minmax(0, 1fr));
  gap: 12px;
}
.system-data-grid > div {
  display: grid;
  gap: 6px;
  padding: 14px;
  border: 1px solid #e4e9f1;
  border-radius: 10px;
}
.system-data-grid span { color: #667085; font-size: 12px; }
.system-data-grid strong { font-size: 24px; }
@media (max-width: 1100px) {
  .system-status-grid { grid-template-columns: 1fr; }
  .system-data-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
CSS

grep -Fq '<Route path="system" element={<SystemPage />} />' "$GUI/src/App.tsx" || die "system route patch failed"
echo "system_operations_gui=CREATED"

echo
echo "=== 6. RELEASE BUILD ==="

dotnet build QuikeFix.LicenseManager.slnx -c Release || die "Recovery 7I2 release build failed"
echo "release_build=PASS"

echo
echo "=== 7. CLONE PRODUCTION DATABASE ==="

docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" >/dev/null
docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB"
docker exec "$PG" createdb -U qflm "$ISO_DB" || die "isolated DB create failed"
docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges  | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null  || die "isolated DB clone failed"

echo "isolated_database_clone=PASS"

echo
echo "=== 8. BUILD API CANDIDATE ==="

rm -rf "$API_PUBLISH"
dotnet publish "$API/QFLM.Api.csproj" -c Release -o "$API_PUBLISH" || die "API publish failed"

cat > "$API_DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-recovery7i2/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER

docker build -f "$API_DOCKERFILE" -t "$API_IMAGE" . || die "API candidate build failed"
echo "api_candidate_image=$API_IMAGE"

echo
echo "=== 9. START ISOLATED API ==="

docker inspect "$PROD_API" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$ENV_FILE" || die "capture production env failed"
chmod 600 "$ENV_FILE"

python3 - "$ENV_FILE" "$ISO_DB" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); db=sys.argv[2]
out=[]; seen=False
for raw in p.read_text().splitlines():
    if not raw or "=" not in raw: continue
    k,v=raw.split("=",1)
    if k.replace("_","").lower().endswith("postgresqldatabase"):
        v=db; seen=True
    out.append(f"{k}={v}")
if not seen: out.append(f"Qflm__PostgreSqlDatabase={db}")
p.write_text("\n".join(out)+"\n")
PY

docker rm -f "$ISO_API" >/dev/null 2>&1 || true
docker run -d  --name "$ISO_API"  --network "$NET"  --network-alias qflm-api-recovery7i2-backend  --env-file "$ENV_FILE"  --volumes-from "$PROD_API:ro"  --read-only  --cap-drop ALL  --security-opt no-new-privileges:true  --tmpfs /tmp:rw,noexec,nosuid,size=16m  "$API_IMAGE" >/dev/null || die "isolated API start failed"

sleep 5
docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS "http://$ISO_API:8080/health/ready" >/dev/null  || { docker logs --tail 200 "$ISO_API" || true; die "isolated API readiness failed"; }

echo "isolated_api_health=PASS"

echo
echo "=== 10. BUILD + START ISOLATED GUI ==="

cat > "$GUI_NGINX_CONF" <<'NGINX'
pid /tmp/nginx.pid;
error_log /dev/stderr notice;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;
    client_body_temp_path /tmp/client_temp;
    proxy_temp_path /tmp/proxy_temp;
    fastcgi_temp_path /tmp/fastcgi_temp;
    uwsgi_temp_path /tmp/uwsgi_temp;
    scgi_temp_path /tmp/scgi_temp;
    server {
        listen 8080;
        root /usr/share/nginx/html;
        index index.html;
        location /api/ {
            proxy_pass http://qflm-api-recovery7i2-backend:8080/api/;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
        }
        location = /health { access_log off; default_type text/plain; return 200 "ok"; }
        location / { try_files $uri $uri/ /index.html; }
    }
}
NGINX

cat > "$GUI_DOCKERFILE" <<'DOCKER'
FROM node:24-bookworm-slim AS build
WORKDIR /src
COPY src/QFLM.AdminWeb/package*.json ./
RUN npm install --no-audit --no-fund
COPY src/QFLM.AdminWeb/ ./
RUN npm run build

FROM nginx:1.29-alpine
COPY --from=build /src/dist /usr/share/nginx/html
COPY artifacts/recovery7i2-nginx.conf /etc/nginx/nginx-qflm.conf
RUN mkdir -p /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp \
 && chown -R nginx:nginx /tmp /usr/share/nginx/html \
 && chmod 444 /etc/nginx/nginx-qflm.conf
USER nginx
EXPOSE 8080
ENTRYPOINT ["nginx","-c","/etc/nginx/nginx-qflm.conf","-g","daemon off;"]
DOCKER

docker build -f "$GUI_DOCKERFILE" -t "$GUI_IMAGE" . || die "GUI candidate build failed"

docker rm -f "$ISO_GUI" >/dev/null 2>&1 || true
docker run -d  --name "$ISO_GUI"  --network "$NET"  --read-only  --cap-drop ALL  --security-opt no-new-privileges:true  --tmpfs /tmp:rw,noexec,nosuid,size=24m,uid=101,gid=101  "$GUI_IMAGE" >/dev/null || die "isolated GUI start failed"

sleep 3
[ "$(docker inspect "$ISO_GUI" --format='{{.State.Running}}')" = true ] || die "isolated GUI not running"

echo "isolated_gui_running=PASS"

echo
echo "=== 11. LOGIN + SYSTEM API VALIDATION ==="

ADMIN_USER="$(cat "$ADMIN_USER_FILE")"
ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"
LOGIN_JSON=$(python3 - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)

LOGIN_RESPONSE=$(printf '%s' "$LOGIN_JSON" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -fsS  -H 'Content-Type: application/json' -X POST "http://$ISO_GUI:8080/api/v1/auth/login" --data-binary @-)  || die "admin login failed"

TOKEN=$(python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["accessToken"])
PY
)
REFRESH=$(python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["refreshToken"])
PY
)

SYSTEM_JSON=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS  -H "Authorization: Bearer $TOKEN"  "http://$ISO_GUI:8080/api/v1/admin/system/summary") || die "system summary API failed"

python3 - "$SYSTEM_JSON" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x["status"]=="Operational"
assert x["database"]["status"]=="Healthy"
assert x["redis"]["status"]=="Healthy"
assert "version" in x["api"]
assert "customers" in x["data"]
print("system_summary_api=PASS")
PY

SYSTEM_HTTP=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' "http://$ISO_GUI:8080/system")
[ "$SYSTEM_HTTP" = 200 ] || die "system GUI route failed"
echo "system_gui_route=PASS"

echo
echo "=== 12. HARDENING ==="

GUI_HARDEN=$(docker inspect "$ISO_GUI" --format='readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}}')
API_HARDEN=$(docker inspect "$ISO_API" --format='readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .NetworkSettings.Ports}}')

echo "$GUI_HARDEN" | grep -Fq 'readonly=true' || die "GUI readonly missing"
echo "$GUI_HARDEN" | grep -Fq '"ALL"' || die "GUI capdrop missing"
echo "$API_HARDEN" | grep -Fq 'readonly=true' || die "API readonly missing"
echo "$API_HARDEN" | grep -Fq '"ALL"' || die "API capdrop missing"
echo "$API_HARDEN" | grep -Fq 'ports={}' || die "API exposed host ports"

echo "isolated_hardening=PASS"

echo
echo "=== 13. REVOKE TEST SESSION ==="

REVOKE_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)

REVOKE_HTTP=$(printf '%s' "$REVOKE_JSON" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0  -s -o /dev/null -w '%{http_code}'  -H 'Content-Type: application/json'  -H "Authorization: Bearer $TOKEN"  -X POST "http://$ISO_GUI:8080/api/v1/auth/revoke" --data-binary @-)

[ "$REVOKE_HTTP" = 204 ] || die "session revoke failed"
unset TOKEN REFRESH ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE SYSTEM_JSON REVOKE_JSON
echo "test_session_revoked=PASS"

echo
echo "=== 14. PREVIEW + PRODUCTION FINAL SAFETY ==="

FINAL_PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}')
FINAL_PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}')
FINAL_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)

[ "$FINAL_PREVIEW_API_IMAGE" = "$PREVIEW_API_IMAGE" ] || die "preview API image changed"
[ "$FINAL_PREVIEW_GUI_IMAGE" = "$PREVIEW_GUI_IMAGE" ] || die "preview GUI image changed"
[ "$FINAL_IMAGE" = "$PROD_IMAGE" ] || die "production image changed"
[ "$FINAL_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "production migrations changed"
[ "$FINAL_USERS" = "$PROD_USERS" ] || die "production users changed"
[ "$FINAL_ROLES" = "$PROD_ROLES" ] || die "production roles changed"
[ "$FINAL_PERMS" = "$PROD_PERMS" ] || die "production permissions changed"

echo "preview_unchanged=PASS"
echo "production_unchanged=PASS"

COMPLETED=1

echo
echo "======================================================"
echo " QFLM RECOVERY 7I2 PASSED"
echo "======================================================"
echo "SYSTEM POLICY:                     PASS"
echo "SYSTEM SUMMARY API:                PASS"
echo "SYSTEM GUI ROUTE:                  PASS"
echo "POSTGRESQL STATUS:                 PASS"
echo "REDIS STATUS:                      PASS"
echo "ISOLATED HARDENING:                PASS"
echo "CURRENT CLOUDFLARE PREVIEW:        UNCHANGED"
echo "PRODUCTION API/DB:                 UNCHANGED"
echo "API CANDIDATE IMAGE:               $API_IMAGE"
echo "GUI CANDIDATE IMAGE:               $GUI_IMAGE"
echo "REPORT:                            $REPORT"
echo "NEXT: RECOVERY 7I3 - REFRESH CLOUDFLARE PREVIEW WITH SYSTEM / OPERATIONS"
echo "======================================================"
