#!/usr/bin/env bash
# QFLM RECOVERY 7E2
# Installations management GUI/API + license admin API validation.
# ISOLATED ONLY. Existing Cloudflare preview and production remain unchanged.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API_SRC="$ROOT/src/QFLM.Api"
GUI="$ROOT/src/QFLM.AdminWeb"

PROD_API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"
ISO_DB="qflm_recovery7e2_test"
ISO_API="qflm-api-recovery7e2-test"
ISO_GUI="qflm-admin-web-recovery7e2-test"
NET="qflm_backend"

PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"

EXPECTED_PROD_IMAGE="qflm-api:recovery6f3-candidate"
API_IMAGE="qflm-api:recovery7e2-candidate"
GUI_IMAGE="qflm-admin-web:recovery7e2-candidate"

ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"
RUNTIME_JWT="/opt/qflm/secrets/runtime-api/jwt-signing-key"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7e2-$STAMP"
REPORT="$BACKUP/recovery7e2-report.txt"
SOURCE_BACKUP="$BACKUP/source-before-phase16e2.tgz"
DB_DUMP="$BACKUP/qflm-before-phase16e2.dump"
ENV_FILE="$BACKUP/isolated-api.env"

API_PUBLISH="$ROOT/artifacts/api-publish-recovery7e2"
API_DOCKERFILE="$ROOT/Dockerfile.recovery7e2-api"
GUI_DOCKERFILE="$ROOT/Dockerfile.recovery7e2-gui"

MUTATED=0
COMPLETED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

cleanup(){
    docker rm -f "$ISO_GUI" >/dev/null 2>&1 || true
    docker rm -f "$ISO_API" >/dev/null 2>&1 || true

    if [ "$COMPLETED" -ne 1 ] && [ "$MUTATED" -eq 1 ] && [ -s "$SOURCE_BACKUP" ]; then
        printf '\n=== SOURCE ROLLBACK ===\n'
        rm -f "$API_SRC/Controllers/AdminInstallationsController.cs"
        rm -f "$GUI/src/pages/InstallationsPage.tsx"
        tar -xzf "$SOURCE_BACKUP" -C "$ROOT" >/dev/null 2>&1 || true
        printf '%s\n' "source_restore_attempted=YES"
    fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7E2"
printf '%s\n' " INSTALLATIONS GUI/API + LICENSE ADMIN VALIDATION"
printf '%s\n' " ISOLATED ONLY"
printf '%s\n' "======================================================"

printf '\n=== 1. PRODUCTION + PREVIEW BASELINE ===\n'

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
LICS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
INST=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)

printf 'prod_image=%s prod_running=%s migrations=%s licenses=%s installations=%s preview_api=%s preview_gui=%s\n' \
 "$PROD_IMAGE" "$PROD_RUNNING" "$MIG" "$LICS" "$INST" "$PREVIEW_API_RUNNING" "$PREVIEW_GUI_RUNNING"

[ "$PROD_IMAGE" = "$EXPECTED_PROD_IMAGE" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"
[ -s "$ADMIN_USER_FILE" ] || die "admin username missing"
[ -s "$ADMIN_PASS_FILE" ] || die "admin password missing"
[ -s "$RUNTIME_JWT" ] || die "JWT secret missing"

printf '%s\n' "production_preview_baseline=PASS"

printf '\n=== 2. VERIFY PRIOR SOURCE ===\n'

for f in \
 "$API_SRC/Controllers/AdminLicensesController.cs" \
 "$GUI/src/pages/LicensesPage.tsx" \
 "$GUI/src/pages/CustomersPage.tsx" \
 "$GUI/src/pages/ProductsPage.tsx"
do
    [ -s "$f" ] || die "required prior source missing: $f"
done

grep -Fq '[HttpPut("{id:guid}/status")]' "$API_SRC/Controllers/AdminLicensesController.cs" \
  || die "license admin status endpoint missing"

printf '%s\n' "prior_source=PASS"
printf '%s\n' "license_admin_status_api=VERIFIED"

printf '\n=== 3. BACKUPS ===\n'

tar -czf "$SOURCE_BACKUP" -C "$ROOT" "src/QFLM.Api" "src/QFLM.AdminWeb" \
  || die "source backup failed"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" -Fc > "$DB_DUMP" \
  || die "database backup failed"

[ -s "$DB_DUMP" ] || die "database backup empty"

printf 'source_backup_sha256=%s\n' "$(sha256sum "$SOURCE_BACKUP" | awk '{print $1}')"
printf 'database_backup_sha256=%s\n' "$(sha256sum "$DB_DUMP" | awk '{print $1}')"

MUTATED=1

printf '\n=== 4. ADD INSTALLATION MANAGEMENT API ===\n'

cat > "$API_SRC/Controllers/AdminInstallationsController.cs" <<'CS'
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Npgsql;

namespace QFLM.Api.Controllers;

[ApiController]
[Route("api/v1/admin/installations")]
[Authorize(Policy = "permission:security.admin")]
public sealed class AdminInstallationsController : ControllerBase
{
    private readonly NpgsqlDataSource _dataSource;

    public AdminInstallationsController(NpgsqlDataSource dataSource)
    {
        _dataSource = dataSource;
    }

    [HttpGet]
    public async Task<IActionResult> List(CancellationToken cancellationToken)
    {
        const string sql =
            "SELECT i.id,i.license_id,l.license_number,l.status," +
            "c.customer_number,c.name,p.product_code,p.name," +
            "i.installation_identifier,i.status,i.activated_at_utc,i.last_seen_at_utc," +
            "i.last_heartbeat_sequence,i.highest_lease_sequence," +
            "(i.installation_public_key IS NOT NULL) " +
            "FROM installations i " +
            "JOIN licenses l ON l.id=i.license_id " +
            "JOIN customers c ON c.id=l.customer_id " +
            "JOIN products p ON p.id=l.product_id " +
            "ORDER BY i.created_at_utc DESC;";

        var result = new List<object>();

        await using var command = _dataSource.CreateCommand(sql);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            result.Add(new
            {
                id = reader.GetGuid(0),
                licenseId = reader.GetGuid(1),
                licenseNumber = reader.GetString(2),
                licenseStatus = reader.GetString(3),
                customerNumber = reader.GetString(4),
                customerName = reader.GetString(5),
                productCode = reader.GetString(6),
                productName = reader.GetString(7),
                installationIdentifier = reader.GetGuid(8),
                status = reader.GetString(9),
                activatedAtUtc = reader.IsDBNull(10) ? (DateTime?)null : reader.GetDateTime(10),
                lastSeenAtUtc = reader.IsDBNull(11) ? (DateTime?)null : reader.GetDateTime(11),
                lastHeartbeatSequence = reader.GetInt64(12),
                highestLeaseSequence = reader.GetInt64(13),
                hasPublicKey = reader.GetBoolean(14)
            });
        }

        return Ok(result);
    }

    [HttpPut("{installationIdentifier:guid}/status")]
    public async Task<IActionResult> SetStatus(
        Guid installationIdentifier,
        [FromBody] InstallationStatusRequest request,
        CancellationToken cancellationToken)
    {
        var target = request.Status?.Trim();

        if (target is not ("Active" or "Suspended" or "Revoked"))
            return BadRequest(new { error = "INVALID_INSTALLATION_STATUS" });

        const string currentSql =
            "SELECT status FROM installations WHERE installation_identifier=@id;";

        string? current;

        await using (var check = _dataSource.CreateCommand(currentSql))
        {
            check.Parameters.AddWithValue("id", installationIdentifier);
            current = (string?)await check.ExecuteScalarAsync(cancellationToken);
        }

        if (current is null)
            return NotFound();

        if (current is "Revoked" or "Replaced")
            return Conflict(new
            {
                error = "INSTALLATION_TERMINAL_STATE",
                currentStatus = current
            });

        var allowed =
            (current == "Active" && (target == "Suspended" || target == "Revoked")) ||
            (current == "Suspended" && (target == "Active" || target == "Revoked")) ||
            current == target;

        if (!allowed)
            return Conflict(new
            {
                error = "INVALID_INSTALLATION_TRANSITION",
                currentStatus = current,
                requestedStatus = target
            });

        const string sql =
            "UPDATE installations SET status=@status,updated_at_utc=NOW() " +
            "WHERE installation_identifier=@id;";

        await using var command = _dataSource.CreateCommand(sql);
        command.Parameters.AddWithValue("id", installationIdentifier);
        command.Parameters.AddWithValue("status", target);

        await command.ExecuteNonQueryAsync(cancellationToken);

        return Ok(new
        {
            installationIdentifier,
            previousStatus = current,
            status = target
        });
    }

    public sealed record InstallationStatusRequest
    {
        public required string Status { get; init; }
    }
}
CS

printf '%s\n' "installation_management_api=CREATED"

printf '\n=== 5. ADD INSTALLATIONS GUI ===\n'

cat > "$GUI/src/pages/InstallationsPage.tsx" <<'TSX'
import { useEffect, useMemo, useState } from "react";
import { apiFetch } from "../lib/api";

type Installation = {
  id: string;
  licenseId: string;
  licenseNumber: string;
  licenseStatus: string;
  customerNumber: string;
  customerName: string;
  productCode: string;
  productName: string;
  installationIdentifier: string;
  status: string;
  activatedAtUtc: string | null;
  lastSeenAtUtc: string | null;
  lastHeartbeatSequence: number;
  highestLeaseSequence: number;
  hasPublicKey: boolean;
};

export function InstallationsPage() {
  const [rows, setRows] = useState<Installation[]>([]);
  const [search, setSearch] = useState("");
  const [error, setError] = useState("");

  async function load() {
    const data = await apiFetch<Installation[]>("/v1/admin/installations");
    setRows(data);
  }

  useEffect(() => {
    load().catch(() => setError("Installations could not be loaded."));
  }, []);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return rows;

    return rows.filter((x) =>
      [
        x.installationIdentifier,
        x.licenseNumber,
        x.customerNumber,
        x.customerName,
        x.productCode,
        x.status
      ].some((value) => value.toLowerCase().includes(q))
    );
  }, [rows, search]);

  async function changeStatus(
    installationIdentifier: string,
    status: "Active" | "Suspended" | "Revoked"
  ) {
    if (
      status === "Revoked" &&
      !window.confirm("Revoke this installation? This is a terminal action.")
    ) {
      return;
    }

    try {
      await apiFetch(
        `/v1/admin/installations/${installationIdentifier}/status`,
        {
          method: "PUT",
          body: JSON.stringify({ status })
        }
      );

      setError("");
      await load();
    } catch {
      setError(`Installation could not be changed to ${status}.`);
    }
  }

  return (
    <>
      <div className="page-heading">
        <div>
          <h1>Installations</h1>
          <p>Review activated machines and control installation access.</p>
        </div>

        <input
          className="search-input"
          placeholder="Search installations"
          value={search}
          onChange={(event) => setSearch(event.target.value)}
        />
      </div>

      {error && <div className="page-error">{error}</div>}

      <article className="panel">
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Installation</th>
                <th>License</th>
                <th>Customer</th>
                <th>Product</th>
                <th>Status</th>
                <th>Last seen</th>
                <th>Lease seq.</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((x) => (
                <tr key={x.id}>
                  <td><code>{x.installationIdentifier}</code></td>
                  <td>{x.licenseNumber}</td>
                  <td>{x.customerNumber}</td>
                  <td>{x.productCode}</td>
                  <td>
                    <span className={`status-badge ${x.status.toLowerCase()}`}>
                      {x.status}
                    </span>
                  </td>
                  <td>
                    {x.lastSeenAtUtc
                      ? new Date(x.lastSeenAtUtc).toLocaleString()
                      : "Never"}
                  </td>
                  <td>{x.highestLeaseSequence}</td>
                  <td>
                    <div className="action-row">
                      {x.status === "Active" && (
                        <button
                          className="secondary-button"
                          onClick={() =>
                            changeStatus(x.installationIdentifier, "Suspended")
                          }
                        >
                          Suspend
                        </button>
                      )}

                      {x.status === "Suspended" && (
                        <button
                          className="secondary-button"
                          onClick={() =>
                            changeStatus(x.installationIdentifier, "Active")
                          }
                        >
                          Resume
                        </button>
                      )}

                      {(x.status === "Active" || x.status === "Suspended") && (
                        <button
                          className="danger-button"
                          onClick={() =>
                            changeStatus(x.installationIdentifier, "Revoked")
                          }
                        >
                          Revoke
                        </button>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </article>
    </>
  );
}
TSX

cat > "$GUI/src/App.tsx" <<'TSX'
import { BrowserRouter, Route, Routes } from "react-router-dom";
import { AuthProvider } from "./auth/AuthContext";
import { ProtectedRoute } from "./auth/ProtectedRoute";
import { AppShell } from "./components/AppShell";
import { DashboardPage } from "./pages/DashboardPage";
import { CustomersPage } from "./pages/CustomersPage";
import { ProductsPage } from "./pages/ProductsPage";
import { LicensesPage } from "./pages/LicensesPage";
import { InstallationsPage } from "./pages/InstallationsPage";
import { LoginPage } from "./pages/LoginPage";
import { PlaceholderPage } from "./pages/PlaceholderPage";

export default function App() {
  return (
    <BrowserRouter>
      <AuthProvider>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route
            element={
              <ProtectedRoute>
                <AppShell />
              </ProtectedRoute>
            }
          >
            <Route index element={<DashboardPage />} />
            <Route path="customers" element={<CustomersPage />} />
            <Route path="products" element={<ProductsPage />} />
            <Route path="licenses" element={<LicensesPage />} />
            <Route path="installations" element={<InstallationsPage />} />
            <Route
              path="offline"
              element={
                <PlaceholderPage
                  title="Offline Licensing"
                  description="Offline requests, signed licenses and renewals."
                />
              }
            />
            <Route
              path="security"
              element={
                <PlaceholderPage
                  title="Security"
                  description="Users, roles, permissions and account administration."
                />
              }
            />
            <Route
              path="audit"
              element={
                <PlaceholderPage
                  title="Audit & Reports"
                  description="Security, licensing and operational audit history."
                />
              }
            />
            <Route
              path="system"
              element={
                <PlaceholderPage
                  title="System"
                  description="Platform health and operational configuration."
                />
              }
            />
          </Route>
        </Routes>
      </AuthProvider>
    </BrowserRouter>
  );
}
TSX

cat >> "$GUI/src/styles.css" <<'CSS'

.search-input {
  min-width: 280px;
  max-width: 420px;
  padding: 10px 12px;
  border: 1px solid #d7deea;
  border-radius: 9px;
  background: #fff;
}

.action-row {
  display: flex;
  gap: 7px;
  flex-wrap: wrap;
}

.secondary-button,
.danger-button {
  border: 0;
  border-radius: 8px;
  padding: 8px 10px;
  cursor: pointer;
  font-weight: 600;
}

.secondary-button {
  background: #eef2ff;
  color: #3730a3;
}

.danger-button {
  background: #fee2e2;
  color: #991b1b;
}

.status-badge.suspended {
  background: #fef3c7;
  color: #92400e;
}

.status-badge.revoked {
  background: #fee2e2;
  color: #991b1b;
}
CSS

printf '%s\n' "installations_gui=CREATED"

printf '\n=== 6. RELEASE BUILD ===\n'

dotnet build QuikeFix.LicenseManager.slnx -c Release \
  || die "Phase 16E.2 release build failed"

printf '%s\n' "release_build=PASS"

printf '\n=== 7. CLONE PRODUCTION DATABASE ===\n'

docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1 \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" \
  >/dev/null

docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB"
docker exec "$PG" createdb -U qflm "$ISO_DB" || die "isolated DB create failed"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges \
  | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null \
  || die "isolated DB clone failed"

printf '%s\n' "isolated_database_clone=PASS"

printf '\n=== 8. BUILD API CANDIDATE ===\n'

rm -rf "$API_PUBLISH"

dotnet publish "$API_SRC/QFLM.Api.csproj" -c Release -o "$API_PUBLISH" \
  || die "API publish failed"

cat > "$API_DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-recovery7e2/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER

docker build -f "$API_DOCKERFILE" -t "$API_IMAGE" . \
  || die "API candidate build failed"

printf 'api_candidate_image=%s\n' "$API_IMAGE"

printf '\n=== 9. PREPARE + START ISOLATED API ===\n'

docker inspect "$PROD_API" \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  > "$ENV_FILE" \
  || die "capture production environment failed"

chmod 600 "$ENV_FILE"

cat >> "$ENV_FILE" <<EOF
Qflm__PostgreSqlDatabase=$ISO_DB
PostgreSqlDatabase=$ISO_DB
EOF
chmod 600 "$ENV_FILE"

docker rm -f "$ISO_API" >/dev/null 2>&1 || true

docker run -d \
  --name "$ISO_API" \
  --network "$NET" \
  --network-alias qflm-api-recovery7e2-backend \
  --env-file "$ENV_FILE" \
  --volumes-from "$PROD_API:ro" \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  "$API_IMAGE" >/dev/null \
  || die "isolated API start failed"

sleep 5

docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -fsS "http://$ISO_API:8080/health/ready" >/dev/null \
  || {
      docker logs --tail 160 "$ISO_API" || true
      die "isolated API readiness failed"
  }

printf '%s\n' "isolated_api_health=PASS"

ISO_DB_ENV=$(docker inspect "$ISO_API" --format='{{range .Config.Env}}{{println .}}{{end}}' \
  | awk -F= '$1=="Qflm__PostgreSqlDatabase"{print $2}' | tail -n1)
printf 'isolated_api_database=%s\n' "$ISO_DB_ENV"
[ "$ISO_DB_ENV" = "$ISO_DB" ] || die "isolated API is not bound to isolated database"
printf '%s\n' "isolated_database_binding=PASS"

printf '\n=== 10. BUILD + START ISOLATED GUI ===\n'

cat > "$GUI_DOCKERFILE" <<'DOCKER'
FROM node:24-bookworm-slim AS build
WORKDIR /src
COPY src/QFLM.AdminWeb/package*.json ./
RUN npm install --no-audit --no-fund
COPY src/QFLM.AdminWeb/ ./
RUN npm run build

FROM nginx:1.29-alpine
COPY --from=build /src/dist /usr/share/nginx/html

RUN printf '%s\n' \
  'pid /tmp/nginx.pid;' \
  'error_log /dev/stderr notice;' \
  'events { worker_connections 1024; }' \
  'http {' \
  ' include /etc/nginx/mime.types;' \
  ' default_type application/octet-stream;' \
  ' access_log /dev/stdout;' \
  ' client_body_temp_path /tmp/client_temp;' \
  ' proxy_temp_path /tmp/proxy_temp;' \
  ' fastcgi_temp_path /tmp/fastcgi_temp;' \
  ' uwsgi_temp_path /tmp/uwsgi_temp;' \
  ' scgi_temp_path /tmp/scgi_temp;' \
  ' server {' \
  '  listen 8080;' \
  '  root /usr/share/nginx/html;' \
  '  index index.html;' \
  '  location /api/ {' \
  '   proxy_pass http://qflm-api-recovery7e2-backend:8080/api/;' \
  '   proxy_http_version 1.1;' \
  '   proxy_set_header Host $host;' \
  '  }' \
  '  location / { try_files $uri $uri/ /index.html; }' \
  '  location = /health { access_log off; default_type text/plain; return 200 "ok\n"; }' \
  ' }' \
  '}' > /etc/nginx/nginx-qflm.conf

RUN mkdir -p /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp \
  && chown -R nginx:nginx /tmp /usr/share/nginx/html

USER nginx
EXPOSE 8080
ENTRYPOINT ["nginx","-c","/etc/nginx/nginx-qflm.conf","-g","daemon off;"]
DOCKER

docker build -f "$GUI_DOCKERFILE" -t "$GUI_IMAGE" . \
  || die "GUI candidate build failed"

docker rm -f "$ISO_GUI" >/dev/null 2>&1 || true

docker run -d \
  --name "$ISO_GUI" \
  --network "$NET" \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,size=24m,uid=101,gid=101 \
  "$GUI_IMAGE" >/dev/null \
  || die "isolated GUI start failed"

sleep 3

[ "$(docker inspect "$ISO_GUI" --format='{{.State.Running}}')" = true ] \
  || die "isolated GUI not running"

printf 'gui_candidate_image=%s\n' "$GUI_IMAGE"
printf '%s\n' "isolated_gui_running=PASS"

printf '\n=== 11. ADMIN LOGIN ===\n'

ADMIN_USER="$(cat "$ADMIN_USER_FILE")"
ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"

LOGIN_JSON=$(python3 - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import json,sys
print(json.dumps({"username": sys.argv[1], "password": sys.argv[2]}))
PY
)

LOGIN_RESPONSE=$(printf '%s' "$LOGIN_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 -fsS \
      -H 'Content-Type: application/json' \
      -X POST "http://$ISO_GUI:8080/api/v1/auth/login" \
      --data-binary @-) \
  || { docker logs --tail 180 "$ISO_API" || true; die "admin login failed"; }

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

printf '%s\n' "admin_login=PASS"

api_fail(){
  printf '%s\n' "--- isolated API logs ---"
  docker logs --tail 220 "$ISO_API" || true
  printf '%s\n' "--- isolated GUI logs ---"
  docker logs --tail 120 "$ISO_GUI" || true
  die "$1"
}

printf '\n=== 12. INSTALLATION LIST TEST ===\n'

INSTALL_JSON=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 -fsS \
  -H "Authorization: Bearer $TOKEN" \
  "http://$ISO_GUI:8080/api/v1/admin/installations") \
  || api_fail "installation list failed"

INSTALL_COUNT=$(python3 - "$INSTALL_JSON" <<'PY'
import json,sys
print(len(json.loads(sys.argv[1])))
PY
)

[ "$INSTALL_COUNT" -eq "$INST" ] || die "installation list count mismatch"

INSTALLATION_ONE=$(python3 - "$INSTALL_JSON" <<'PY'
import json,sys
rows=json.loads(sys.argv[1])
print(rows[0]["installationIdentifier"])
PY
)

INSTALLATION_TWO=$(python3 - "$INSTALL_JSON" <<'PY'
import json,sys
rows=json.loads(sys.argv[1])
print(rows[-1]["installationIdentifier"])
PY
)

printf 'installation_list=PASS count=%s\n' "$INSTALL_COUNT"

printf '\n=== 13. INSTALLATION SUSPEND / RESUME TEST ===\n'

SUSPEND_HTTP=$(printf '%s' '{"status":"Suspended"}' \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -X PUT "http://$ISO_GUI:8080/api/v1/admin/installations/$INSTALLATION_ONE/status" \
      --data-binary @-)

[ "$SUSPEND_HTTP" = 200 ] || die "installation suspend failed"

RESUME_HTTP=$(printf '%s' '{"status":"Active"}' \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -X PUT "http://$ISO_GUI:8080/api/v1/admin/installations/$INSTALLATION_ONE/status" \
      --data-binary @-)

[ "$RESUME_HTTP" = 200 ] || die "installation resume failed"

STATUS_ONE=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc \
  "SELECT status FROM installations WHERE installation_identifier='$INSTALLATION_ONE';" | xargs)

[ "$STATUS_ONE" = Active ] || die "installation resume persistence failed"

printf '%s\n' "installation_suspend_resume=PASS"

printf '\n=== 14. INSTALLATION REVOKE TERMINAL TEST ===\n'

REV_HTTP=$(printf '%s' '{"status":"Revoked"}' \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -X PUT "http://$ISO_GUI:8080/api/v1/admin/installations/$INSTALLATION_TWO/status" \
      --data-binary @-)

[ "$REV_HTTP" = 200 ] || die "installation revoke failed"

REACTIVATE_HTTP=$(printf '%s' '{"status":"Active"}' \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -X PUT "http://$ISO_GUI:8080/api/v1/admin/installations/$INSTALLATION_TWO/status" \
      --data-binary @-)

[ "$REACTIVATE_HTTP" = 409 ] || die "terminal state protection failed"

printf '%s\n' "installation_revoke_terminal=PASS"

printf '\n=== 15. EXISTING LICENSE ADMIN STATUS API TEST ===\n'

LICENSE_ID=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc \
  "SELECT id FROM licenses WHERE status='Active' ORDER BY created_at_utc LIMIT 1;" | xargs)

[ -n "$LICENSE_ID" ] || die "active isolated license missing"

L1=$(printf '%s' '{"status":"Suspended"}' \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -X PUT "http://$ISO_GUI:8080/api/v1/admin/licenses/$LICENSE_ID/status" \
      --data-binary @-)

L2=$(printf '%s' '{"status":"Active"}' \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -X PUT "http://$ISO_GUI:8080/api/v1/admin/licenses/$LICENSE_ID/status" \
      --data-binary @-)

[ "$L1" = 204 ] || die "license suspend API failed"
[ "$L2" = 204 ] || die "license resume API failed"

printf '%s\n' "license_admin_status_api=PASS"

printf '\n=== 16. GUI ROUTE TEST ===\n'

GUI_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  "http://$ISO_GUI:8080/installations")

[ "$GUI_HTTP" = 200 ] || die "installations GUI route failed"

printf 'installations_http=%s\n' "$GUI_HTTP"
printf '%s\n' "installations_gui_route=PASS"

printf '\n=== 17. REVOKE TEST SESSION ===\n'

REVOKE_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken": sys.argv[1]}))
PY
)

REVOKE_HTTP=$(printf '%s' "$REVOKE_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -X POST "http://$ISO_GUI:8080/api/v1/auth/revoke" \
      --data-binary @-)

[ "$REVOKE_HTTP" = 204 ] || die "session revoke failed"

printf '%s\n' "test_session_revoked=PASS"

unset TOKEN REFRESH ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE REVOKE_JSON

printf '\n=== 18. EXISTING CLOUDFLARE PREVIEW UNCHANGED ===\n'

PREVIEW_API_FINAL=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_FINAL=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)

printf 'preview_api_running=%s preview_gui_running=%s\n' \
 "$PREVIEW_API_FINAL" "$PREVIEW_GUI_FINAL"

[ "$PREVIEW_API_FINAL" = "$PREVIEW_API_RUNNING" ] || die "preview API state changed"
[ "$PREVIEW_GUI_FINAL" = "$PREVIEW_GUI_RUNNING" ] || die "preview GUI state changed"

printf '%s\n' "existing_preview_unchanged=PASS"

printf '\n=== 19. PRODUCTION FINAL SAFETY ===\n'

FINAL_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_LICS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_INST=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'image=%s running=%s migrations=%s licenses=%s installations=%s\n' \
 "$FINAL_IMAGE" "$FINAL_RUNNING" "$FINAL_MIG" "$FINAL_LICS" "$FINAL_INST"

[ "$FINAL_IMAGE" = "$PROD_IMAGE" ] || die "production API image changed"
[ "$FINAL_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "production migrations changed"
[ "$FINAL_LICS" = "$LICS" ] || die "production licenses changed"
[ "$FINAL_INST" = "$INST" ] || die "production installations changed"

printf '%s\n' "production_unchanged=PASS"

COMPLETED=1

printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7E2 PASSED"
printf '%s\n' "======================================================"
printf '%s\n' "INSTALLATION LIST API:              PASS"
printf '%s\n' "INSTALLATION SUSPEND/RESUME:        PASS"
printf '%s\n' "INSTALLATION REVOKE:                PASS"
printf '%s\n' "TERMINAL STATE PROTECTION:          PASS"
printf '%s\n' "EXISTING LICENSE ADMIN STATUS API:  PASS"
printf '%s\n' "INSTALLATIONS GUI:                  PASS"
printf '%s\n' "EXISTING PREVIEW STATE:             UNCHANGED"
printf '%s\n' "PRODUCTION API/DB:                  UNCHANGED"
printf 'API CANDIDATE IMAGE:                 %s\n' "$API_IMAGE"
printf 'GUI CANDIDATE IMAGE:                 %s\n' "$GUI_IMAGE"
printf 'REPORT:                              %s\n' "$REPORT"
printf '%s\n' "NOTE: REBIND REMAINS DEFERRED FOR A DEDICATED HARDENED ACTION."
printf '%s\n' "NEXT: RECOVERY 7E3 - PREVIEW/PROMOTION DECISION AFTER INSTALLATIONS GUI VALIDATION"
printf '%s\n' "======================================================"
printf '%s\n' "======================================================"