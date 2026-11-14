#!/usr/bin/env bash
# QFLM RECOVERY 7H2
# Audit & Reports GUI/API - isolated validation.
# Production and current Cloudflare preview remain untouched.
# Source changes are backed up and isolated API tests use a cloned database.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API="$ROOT/src/QFLM.Api"
GUI="$ROOT/src/QFLM.AdminWeb"

PROD_API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"

ISO_DB="qflm_recovery7h2_test"
ISO_API="qflm-api-recovery7h2-test"
ISO_GUI="qflm-admin-web-recovery7h2-test"
NET="qflm_backend"

PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"

EXPECTED_PROD_IMAGE="qflm-api:recovery6f3-candidate"
API_IMAGE="qflm-api:recovery7h2-candidate"
GUI_IMAGE="qflm-admin-web:recovery7h2-candidate"

ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7h2-$STAMP"
REPORT="$BACKUP/recovery7h2-report.txt"
SOURCE_BACKUP="$BACKUP/source-before-recovery7h2.tgz"
DB_DUMP="$BACKUP/qflm-before-recovery7h2.dump"
ENV_FILE="$BACKUP/isolated-api.env"
API_PUBLISH="$ROOT/artifacts/api-publish-recovery7h2"
API_DOCKERFILE="$ROOT/Dockerfile.recovery7h2-api"
GUI_DOCKERFILE="$ROOT/Dockerfile.recovery7h2-gui"
GUI_NGINX_CONF="$ROOT/artifacts/recovery7h2-nginx.conf"

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
echo " QFLM RECOVERY 7H2"
echo " AUDIT & REPORTS GUI/API"
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
PROD_AUDIT=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)
PROD_ISSUANCES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)

PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_API_IMAGE=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)

printf 'prod_image=%s running=%s migrations=%s users=%s roles=%s permissions=%s audit=%s issuances=%s\n'  "$PROD_IMAGE" "$PROD_RUNNING" "$MIG" "$PROD_USERS" "$PROD_ROLES" "$PROD_PERMS" "$PROD_AUDIT" "$PROD_ISSUANCES"
printf 'preview_api=%s preview_gui=%s api_image=%s gui_image=%s\n'  "$PREVIEW_API_RUNNING" "$PREVIEW_GUI_RUNNING" "$PREVIEW_API_IMAGE" "$PREVIEW_GUI_IMAGE"

[ "$PROD_IMAGE" = "$EXPECTED_PROD_IMAGE" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"
[ "$PREVIEW_API_RUNNING" = true ] || die "preview API not running"
[ "$PREVIEW_GUI_RUNNING" = true ] || die "preview GUI not running"
[ "$PREVIEW_API_IMAGE" = "qflm-api:recovery7f2-candidate" ] || die "unexpected preview API image"
[ "$PREVIEW_GUI_IMAGE" = "qflm-admin-web:recovery7g3-preview" ] || die "unexpected preview GUI image"
[ -s "$ADMIN_USER_FILE" ] || die "platform admin username missing"
[ -s "$ADMIN_PASS_FILE" ] || die "platform admin password missing"

echo "production_preview_baseline=PASS"

echo
echo "=== 2. VERIFY AUDIT / REPORT SOURCE CONTRACT ==="

for f in  "$API/Program.cs"  "$API/Security/PermissionAuthorizationHandler.cs"  "$API/Controllers/AdminOfflineLicensingController.cs"  "$GUI/src/App.tsx"  "$GUI/src/lib/api.ts"  "$GUI/src/styles.css"
do
    [ -s "$f" ] || die "required source missing: $f"
done

AUDIT_PERMISSION=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM auth_permissions WHERE code='audit.read';" | xargs)
REPORT_PERMISSION=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM auth_permissions WHERE code='reports.read';" | xargs)
[ "$AUDIT_PERMISSION" = 1 ] || die "audit.read permission missing"
[ "$REPORT_PERMISSION" = 1 ] || die "reports.read permission missing"
grep -Fq 'path="audit"' "$GUI/src/App.tsx" || die "GUI audit route missing"

echo "audit_report_contract=PASS"

echo
echo "=== 3. BACKUP SOURCE + PRODUCTION DATABASE ==="

tar -czf "$SOURCE_BACKUP" -C "$ROOT" "src/QFLM.Api" "src/QFLM.AdminWeb" || die "source backup failed"
docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" -Fc > "$DB_DUMP" || die "production DB backup failed"
[ -s "$SOURCE_BACKUP" ] || die "source backup empty"
[ -s "$DB_DUMP" ] || die "production DB backup empty"
printf 'source_backup_sha256=%s\n' "$(sha256sum "$SOURCE_BACKUP" | awk '{print $1}')"
printf 'database_backup_sha256=%s\n' "$(sha256sum "$DB_DUMP" | awk '{print $1}')"

MUTATED=1

echo
echo "=== 4. REGISTER AUDIT / REPORT AUTHORIZATION POLICIES ==="

python3 - "$API/Program.cs" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
s=p.read_text()

for permission in ("audit.read","reports.read"):
    needle=f'            "{permission}",'
    if needle in s:
        continue
    marker='            "products.manage"'
    if marker not in s:
        raise SystemExit("authorization permission marker missing")
    s=s.replace(marker, marker+',\n'+needle.rstrip(','), 1)

p.write_text(s)
PY

grep -Fq '"audit.read"' "$API/Program.cs" || die "audit.read policy registration failed"
grep -Fq '"reports.read"' "$API/Program.cs" || die "reports.read policy registration failed"
echo "authorization_policies=CREATED"

echo
echo "=== 5. CREATE AUDIT & REPORTS API ==="

cat > "$API/Controllers/AdminAuditReportsController.cs" <<'CS'
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Npgsql;

namespace QFLM.Api.Controllers;

[ApiController]
[Route("api/v1/admin/audit-reports")]
public sealed class AdminAuditReportsController : ControllerBase
{
    private readonly NpgsqlDataSource _dataSource;

    public AdminAuditReportsController(NpgsqlDataSource dataSource)
    {
        _dataSource = dataSource;
    }

    [HttpGet("summary")]
    [Authorize(Policy = "permission:reports.read")]
    public async Task<IActionResult> Summary(CancellationToken cancellationToken)
    {
        const string sql = """
SELECT
 (SELECT count(*) FROM customers),
 (SELECT count(*) FROM products),
 (SELECT count(*) FROM licenses),
 (SELECT count(*) FROM installations),
 (SELECT count(*) FROM offline_license_issuances),
 (SELECT count(*) FROM offline_license_audit_events),
 (SELECT count(*) FROM auth_users WHERE is_active=true),
 (SELECT count(*) FROM licenses WHERE status='Active'),
 (SELECT count(*) FROM installations WHERE status='Active');
""";

        await using var command = _dataSource.CreateCommand(sql);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        if (!await reader.ReadAsync(cancellationToken))
            return StatusCode(500);

        return Ok(new
        {
            customers = reader.GetInt64(0),
            products = reader.GetInt64(1),
            licenses = reader.GetInt64(2),
            installations = reader.GetInt64(3),
            offlineIssuances = reader.GetInt64(4),
            auditEvents = reader.GetInt64(5),
            activeUsers = reader.GetInt64(6),
            activeLicenses = reader.GetInt64(7),
            activeInstallations = reader.GetInt64(8),
            generatedAtUtc = DateTime.UtcNow
        });
    }

    [HttpGet("audit")]
    [Authorize(Policy = "permission:audit.read")]
    public async Task<IActionResult> Audit(
        [FromQuery] int limit = 200,
        CancellationToken cancellationToken = default)
    {
        limit = Math.Clamp(limit, 1, 500);

        const string sql = """
SELECT
 a.id,
 l.license_number,
 i.installation_identifier,
 a.event_type,
 a.outcome,
 a.request_id,
 a.lease_sequence,
 a.occurred_at_utc,
 c.customer_number,
 c.name,
 p.product_code
FROM offline_license_audit_events a
JOIN licenses l ON l.id=a.license_id
JOIN customers c ON c.id=l.customer_id
JOIN products p ON p.id=l.product_id
LEFT JOIN installations i ON i.id=a.installation_id
ORDER BY a.occurred_at_utc DESC
LIMIT @limit;
""";

        var result = new List<object>();

        await using var command = _dataSource.CreateCommand(sql);
        command.Parameters.AddWithValue("limit", limit);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            result.Add(new
            {
                id = reader.GetGuid(0),
                licenseNumber = reader.GetString(1),
                installationIdentifier = reader.IsDBNull(2) ? (Guid?)null : reader.GetGuid(2),
                eventType = reader.GetString(3),
                outcome = reader.GetString(4),
                requestId = reader.IsDBNull(5) ? null : reader.GetString(5),
                leaseSequence = reader.IsDBNull(6) ? (long?)null : reader.GetInt64(6),
                occurredAtUtc = reader.GetDateTime(7),
                customerNumber = reader.GetString(8),
                customerName = reader.GetString(9),
                productCode = reader.GetString(10)
            });
        }

        return Ok(result);
    }

    [HttpGet("issuances")]
    [Authorize(Policy = "permission:reports.read")]
    public async Task<IActionResult> Issuances(
        [FromQuery] int limit = 200,
        CancellationToken cancellationToken = default)
    {
        limit = Math.Clamp(limit, 1, 500);

        const string sql = """
SELECT
 oi.id,
 l.license_number,
 i.installation_identifier,
 oi.lease_sequence,
 oi.key_id,
 oi.status,
 oi.issued_at_utc,
 oi.expires_at_utc,
 oi.grace_ends_at_utc,
 c.customer_number,
 c.name,
 p.product_code
FROM offline_license_issuances oi
JOIN licenses l ON l.id=oi.license_id
JOIN installations i ON i.id=oi.installation_id
JOIN customers c ON c.id=l.customer_id
JOIN products p ON p.id=l.product_id
ORDER BY oi.issued_at_utc DESC
LIMIT @limit;
""";

        var result = new List<object>();

        await using var command = _dataSource.CreateCommand(sql);
        command.Parameters.AddWithValue("limit", limit);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            result.Add(new
            {
                id = reader.GetGuid(0),
                licenseNumber = reader.GetString(1),
                installationIdentifier = reader.GetGuid(2),
                leaseSequence = reader.GetInt64(3),
                keyId = reader.GetString(4),
                status = reader.GetString(5),
                issuedAtUtc = reader.GetDateTime(6),
                expiresAtUtc = reader.IsDBNull(7) ? (DateTime?)null : reader.GetDateTime(7),
                graceEndsAtUtc = reader.IsDBNull(8) ? (DateTime?)null : reader.GetDateTime(8),
                customerNumber = reader.GetString(9),
                customerName = reader.GetString(10),
                productCode = reader.GetString(11)
            });
        }

        return Ok(result);
    }
}
CS

grep -Fq '[Route("api/v1/admin/audit-reports")]' "$API/Controllers/AdminAuditReportsController.cs"  || die "audit reports controller route missing"
grep -Fq 'permission:audit.read' "$API/Controllers/AdminAuditReportsController.cs"  || die "audit policy missing"
grep -Fq 'permission:reports.read' "$API/Controllers/AdminAuditReportsController.cs"  || die "reports policy missing"
echo "audit_reports_api=CREATED"

echo
echo "=== 6. CREATE AUDIT & REPORTS GUI ==="

cat > "$GUI/src/pages/AuditReportsPage.tsx" <<'TSX'
import { useEffect, useState } from "react";
import { apiFetch } from "../lib/api";

type Summary = {
  customers: number;
  products: number;
  licenses: number;
  installations: number;
  offlineIssuances: number;
  auditEvents: number;
  activeUsers: number;
  activeLicenses: number;
  activeInstallations: number;
  generatedAtUtc: string;
};

type AuditEvent = {
  id: string;
  licenseNumber: string;
  installationIdentifier: string | null;
  eventType: string;
  outcome: string;
  requestId: string | null;
  leaseSequence: number | null;
  occurredAtUtc: string;
  customerNumber: string;
  customerName: string;
  productCode: string;
};

type Issuance = {
  id: string;
  licenseNumber: string;
  installationIdentifier: string;
  leaseSequence: number;
  keyId: string;
  status: string;
  issuedAtUtc: string;
  expiresAtUtc: string | null;
  graceEndsAtUtc: string | null;
  customerNumber: string;
  customerName: string;
  productCode: string;
};

type Tab = "audit" | "issuances";

function fmtDate(value: string | null): string {
  if (!value) return "-";
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? value : parsed.toLocaleString();
}

export function AuditReportsPage() {
  const [summary, setSummary] = useState<Summary | null>(null);
  const [audit, setAudit] = useState<AuditEvent[]>([]);
  const [issuances, setIssuances] = useState<Issuance[]>([]);
  const [tab, setTab] = useState<Tab>("audit");
  const [error, setError] = useState("");

  async function load() {
    const [s, a, i] = await Promise.all([
      apiFetch<Summary>("/v1/admin/audit-reports/summary"),
      apiFetch<AuditEvent[]>("/v1/admin/audit-reports/audit?limit=500"),
      apiFetch<Issuance[]>("/v1/admin/audit-reports/issuances?limit=500")
    ]);

    setSummary(s);
    setAudit(a);
    setIssuances(i);
  }

  useEffect(() => {
    load().catch(() => setError("Audit and reporting data could not be loaded."));
  }, []);

  return (
    <>
      <div className="page-heading">
        <div>
          <h1>Audit & Reports</h1>
          <p>Read-only licensing, installation, issuance and audit reporting.</p>
        </div>
      </div>

      {error && <div className="page-error">{error}</div>}

      <div className="audit-summary-grid">
        <article className="audit-summary-card"><span>Customers</span><strong>{summary?.customers ?? "-"}</strong></article>
        <article className="audit-summary-card"><span>Licenses</span><strong>{summary?.licenses ?? "-"}</strong><small>{summary ? summary.activeLicenses + " active" : ""}</small></article>
        <article className="audit-summary-card"><span>Installations</span><strong>{summary?.installations ?? "-"}</strong><small>{summary ? summary.activeInstallations + " active" : ""}</small></article>
        <article className="audit-summary-card"><span>Offline issuances</span><strong>{summary?.offlineIssuances ?? "-"}</strong></article>
        <article className="audit-summary-card"><span>Audit events</span><strong>{summary?.auditEvents ?? "-"}</strong></article>
        <article className="audit-summary-card"><span>Active users</span><strong>{summary?.activeUsers ?? "-"}</strong></article>
      </div>

      <div className="audit-tabs">
        <button className={tab === "audit" ? "active" : ""} onClick={() => setTab("audit")}>Audit events</button>
        <button className={tab === "issuances" ? "active" : ""} onClick={() => setTab("issuances")}>Offline issuances</button>
      </div>

      {tab === "audit" && (
        <article className="panel">
          <h2>Audit events</h2>
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Occurred</th>
                  <th>Event</th>
                  <th>Outcome</th>
                  <th>Customer</th>
                  <th>Product</th>
                  <th>License</th>
                  <th>Installation</th>
                  <th>Lease</th>
                </tr>
              </thead>
              <tbody>
                {audit.map((x) => (
                  <tr key={x.id}>
                    <td>{fmtDate(x.occurredAtUtc)}</td>
                    <td>{x.eventType}</td>
                    <td>{x.outcome}</td>
                    <td>{x.customerNumber} - {x.customerName}</td>
                    <td>{x.productCode}</td>
                    <td>{x.licenseNumber}</td>
                    <td>{x.installationIdentifier ?? "-"}</td>
                    <td>{x.leaseSequence ?? "-"}</td>
                  </tr>
                ))}
                {!audit.length && <tr><td colSpan={8}>No audit events recorded.</td></tr>}
              </tbody>
            </table>
          </div>
        </article>
      )}

      {tab === "issuances" && (
        <article className="panel">
          <h2>Offline issuance history</h2>
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Issued</th>
                  <th>Status</th>
                  <th>Customer</th>
                  <th>Product</th>
                  <th>License</th>
                  <th>Installation</th>
                  <th>Lease</th>
                  <th>Expires</th>
                </tr>
              </thead>
              <tbody>
                {issuances.map((x) => (
                  <tr key={x.id}>
                    <td>{fmtDate(x.issuedAtUtc)}</td>
                    <td>{x.status}</td>
                    <td>{x.customerNumber} - {x.customerName}</td>
                    <td>{x.productCode}</td>
                    <td>{x.licenseNumber}</td>
                    <td>{x.installationIdentifier}</td>
                    <td>{x.leaseSequence}</td>
                    <td>{fmtDate(x.expiresAtUtc)}</td>
                  </tr>
                ))}
                {!issuances.length && <tr><td colSpan={8}>No offline issuances recorded.</td></tr>}
              </tbody>
            </table>
          </div>
        </article>
      )}

      {summary && <div className="muted audit-generated">Generated {fmtDate(summary.generatedAtUtc)}</div>}
    </>
  );
}
TSX

python3 - "$GUI/src/App.tsx" <<'PY'
from pathlib import Path
import re,sys

p=Path(sys.argv[1])
s=p.read_text()

imp='import { AuditReportsPage } from "./pages/AuditReportsPage";'
if imp not in s:
    marker='import { SecurityPage } from "./pages/SecurityPage";'
    if marker not in s:
        raise SystemExit("SecurityPage import marker missing")
    s=s.replace(marker, marker+"\n"+imp, 1)

pattern=re.compile(
    r'\s*<Route\s+path="audit"\s+element=\{\s*<PlaceholderPage\s+title="Audit & Reports"\s+description="Security, licensing and operational audit history\."\s*/>\s*\}\s*/>',
    re.S
)

replacement='\n            <Route path="audit" element={<AuditReportsPage />} />'

if pattern.search(s):
    s=pattern.sub(replacement,s,count=1)
elif '<Route path="audit" element={<AuditReportsPage />} />' not in s:
    raise SystemExit("audit placeholder route marker missing")

p.write_text(s)
PY

cat >> "$GUI/src/styles.css" <<'CSS'

/* Phase 16H - Audit & Reports */
.audit-summary-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 14px;
  margin-bottom: 18px;
}
.audit-summary-card {
  display: grid;
  gap: 4px;
  padding: 18px;
  border: 1px solid #e4e9f1;
  border-radius: 12px;
  background: #fff;
}
.audit-summary-card span,
.audit-summary-card small,
.audit-generated {
  color: #667085;
}
.audit-summary-card strong {
  font-size: 28px;
}
.audit-tabs {
  display: flex;
  gap: 8px;
  margin: 0 0 18px;
  padding: 6px;
  border: 1px solid #e4e9f1;
  border-radius: 12px;
  background: #fff;
  width: fit-content;
}
.audit-tabs button {
  border: 0;
  border-radius: 8px;
  background: transparent;
  padding: 9px 14px;
  cursor: pointer;
}
.audit-tabs button.active {
  background: #eef2f7;
  font-weight: 700;
}
.audit-generated {
  margin-top: 14px;
  font-size: 12px;
}
@media (max-width: 900px) {
  .audit-summary-grid {
    grid-template-columns: 1fr;
  }
}
CSS

grep -Fq 'export function AuditReportsPage' "$GUI/src/pages/AuditReportsPage.tsx"  || die "AuditReportsPage source missing"
grep -Fq '<Route path="audit" element={<AuditReportsPage />} />' "$GUI/src/App.tsx"  || die "AuditReportsPage route patch failed"

echo "audit_reports_gui=CREATED"

echo
echo "=== 7. RELEASE BUILD ==="

dotnet build QuikeFix.LicenseManager.slnx -c Release || die "Recovery 7H2 release build failed"
echo "release_build=PASS"

echo
echo "=== 8. CLONE PRODUCTION DATABASE ==="

docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" >/dev/null
docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB"
docker exec "$PG" createdb -U qflm "$ISO_DB" || die "isolated DB create failed"
docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges  | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null  || die "isolated DB clone failed"

ISO_AUDIT=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)
ISO_ISSUANCES=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
[ "$ISO_AUDIT" = "$PROD_AUDIT" ] || die "isolated audit count mismatch"
[ "$ISO_ISSUANCES" = "$PROD_ISSUANCES" ] || die "isolated issuance count mismatch"

echo "isolated_database_clone=PASS"

echo
echo "=== 9. BUILD API CANDIDATE ==="

rm -rf "$API_PUBLISH"
dotnet publish "$API/QFLM.Api.csproj" -c Release -o "$API_PUBLISH" || die "API publish failed"

cat > "$API_DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-recovery7h2/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER

docker build -f "$API_DOCKERFILE" -t "$API_IMAGE" . || die "API candidate build failed"
echo "api_candidate_image=$API_IMAGE"

echo
echo "=== 10. PREPARE + START ISOLATED API ==="

docker inspect "$PROD_API" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$ENV_FILE"  || die "capture production API environment failed"
chmod 600 "$ENV_FILE"

python3 - "$ENV_FILE" "$ISO_DB" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
db=sys.argv[2]
out=[]
seen=False

for raw in p.read_text().splitlines():
    if not raw or "=" not in raw:
        continue
    key,value=raw.split("=",1)
    normalized=key.replace("_","").lower()
    if normalized.endswith("postgresqldatabase"):
        value=db
        seen=True
    out.append(f"{key}={value}")

if not seen:
    out.append(f"Qflm__PostgreSqlDatabase={db}")

p.write_text("\n".join(out)+"\n")
PY

docker rm -f "$ISO_API" >/dev/null 2>&1 || true
docker run -d  --name "$ISO_API"  --network "$NET"  --network-alias qflm-api-recovery7h2-backend  --env-file "$ENV_FILE"  --volumes-from "$PROD_API:ro"  --read-only  --cap-drop ALL  --security-opt no-new-privileges:true  --tmpfs /tmp:rw,noexec,nosuid,size=16m  "$API_IMAGE" >/dev/null  || die "isolated API start failed"

sleep 5

docker run --rm --network "$NET" curlimages/curl:8.16.0  -fsS "http://$ISO_API:8080/health/ready" >/dev/null  || {
    docker logs --tail 200 "$ISO_API" || true
    die "isolated API readiness failed"
 }

ISO_DB_ENV=$(docker inspect "$ISO_API" --format='{{range .Config.Env}}{{println .}}{{end}}'  | awk -F= '$1=="Qflm__PostgreSqlDatabase"{print $2}' | tail -n1)

[ "$ISO_DB_ENV" = "$ISO_DB" ] || die "isolated API database binding mismatch"
echo "isolated_api_health=PASS"
echo "isolated_database_binding=PASS"

echo
echo "=== 11. BUILD + START ISOLATED GUI ==="

cat > "$GUI_NGINX_CONF" <<'NGINX'
pid /tmp/nginx.pid;
error_log /dev/stderr notice;

events {
    worker_connections 1024;
}

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
            proxy_pass http://qflm-api-recovery7h2-backend:8080/api/;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
        }

        location = /health {
            access_log off;
            default_type text/plain;
            return 200 "ok";
        }

        location / {
            try_files $uri $uri/ /index.html;
        }
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
COPY artifacts/recovery7h2-nginx.conf /etc/nginx/nginx-qflm.conf
RUN mkdir -p /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp     && chown -R nginx:nginx /tmp /usr/share/nginx/html     && chmod 444 /etc/nginx/nginx-qflm.conf
USER nginx
EXPOSE 8080
ENTRYPOINT ["nginx","-c","/etc/nginx/nginx-qflm.conf","-g","daemon off;"]
DOCKER

docker build -f "$GUI_DOCKERFILE" -t "$GUI_IMAGE" . || die "Audit Reports GUI candidate build failed"

docker rm -f "$ISO_GUI" >/dev/null 2>&1 || true
docker run -d  --name "$ISO_GUI"  --network "$NET"  --read-only  --cap-drop ALL  --security-opt no-new-privileges:true  --tmpfs /tmp:rw,noexec,nosuid,size=24m,uid=101,gid=101  "$GUI_IMAGE" >/dev/null  || die "isolated Audit Reports GUI start failed"

sleep 3

[ "$(docker inspect "$ISO_GUI" --format='{{.State.Running}}')" = true ]  || {
    docker logs --tail 200 "$ISO_GUI" || true
    die "isolated Audit Reports GUI not running"
 }

echo "gui_candidate_image=$GUI_IMAGE"
echo "isolated_gui_running=PASS"

echo
echo "=== 12. ADMIN LOGIN + AUDIT / REPORT API TESTS ==="

ADMIN_USER="$(cat "$ADMIN_USER_FILE")"
ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"

LOGIN_JSON=$(python3 - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)

LOGIN_RESPONSE=$(printf '%s' "$LOGIN_JSON" | docker run --rm --network "$NET" -i  curlimages/curl:8.16.0 -fsS  -H 'Content-Type: application/json'  -X POST "http://$ISO_GUI:8080/api/v1/auth/login"  --data-binary @-) || die "admin login failed"

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

SUMMARY_JSON=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS  -H "Authorization: Bearer $TOKEN"  "http://$ISO_GUI:8080/api/v1/admin/audit-reports/summary")  || die "reports summary API failed"

AUDIT_JSON=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS  -H "Authorization: Bearer $TOKEN"  "http://$ISO_GUI:8080/api/v1/admin/audit-reports/audit?limit=500")  || die "audit API failed"

ISSUANCES_JSON=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS  -H "Authorization: Bearer $TOKEN"  "http://$ISO_GUI:8080/api/v1/admin/audit-reports/issuances?limit=500")  || die "issuances report API failed"

python3 - "$SUMMARY_JSON" "$AUDIT_JSON" "$ISSUANCES_JSON" "$PROD_AUDIT" "$PROD_ISSUANCES" <<'PY'
import json,sys

summary=json.loads(sys.argv[1])
audit=json.loads(sys.argv[2])
issuances=json.loads(sys.argv[3])
expected_audit=int(sys.argv[4])
expected_issuances=int(sys.argv[5])

required={
    "customers","products","licenses","installations",
    "offlineIssuances","auditEvents","activeUsers",
    "activeLicenses","activeInstallations","generatedAtUtc"
}
assert required.issubset(summary.keys())
assert summary["auditEvents"] == expected_audit
assert summary["offlineIssuances"] == expected_issuances
assert len(audit) == min(expected_audit,500)
assert len(issuances) == min(expected_issuances,500)
print("audit_reports_read_apis=PASS")
PY

echo
echo "=== 13. GUI ROUTE + HARDENING TEST ==="

AUDIT_HTTP=$(docker run --rm --network "$NET" curlimages/curl:8.16.0  -s -o /dev/null -w '%{http_code}' "http://$ISO_GUI:8080/audit")

[ "$AUDIT_HTTP" = 200 ] || die "Audit & Reports GUI route failed"

GUI_HARDEN=$(docker inspect "$ISO_GUI"  --format='readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .NetworkSettings.Ports}}')
API_HARDEN=$(docker inspect "$ISO_API"  --format='readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .NetworkSettings.Ports}}')

echo "$GUI_HARDEN" | grep -Fq 'readonly=true' || die "GUI readonly hardening missing"
echo "$GUI_HARDEN" | grep -Fq '"ALL"' || die "GUI cap drop missing"
echo "$GUI_HARDEN" | grep -Fq 'no-new-privileges:true' || die "GUI no-new-privileges missing"
echo "$API_HARDEN" | grep -Fq 'readonly=true' || die "API readonly hardening missing"
echo "$API_HARDEN" | grep -Fq '"ALL"' || die "API cap drop missing"
echo "$API_HARDEN" | grep -Fq 'no-new-privileges:true' || die "API no-new-privileges missing"

echo "audit_reports_gui_route=PASS"
echo "isolated_hardening=PASS"

echo
echo "=== 14. REVOKE TEST ADMIN SESSION ==="

REVOKE_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)

REVOKE_HTTP=$(printf '%s' "$REVOKE_JSON" | docker run --rm --network "$NET" -i  curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}'  -H 'Content-Type: application/json'  -H "Authorization: Bearer $TOKEN"  -X POST "http://$ISO_GUI:8080/api/v1/auth/revoke"  --data-binary @-)

[ "$REVOKE_HTTP" = 204 ] || die "admin test session revoke failed"

unset TOKEN REFRESH ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE SUMMARY_JSON AUDIT_JSON ISSUANCES_JSON REVOKE_JSON
echo "test_session_revoked=PASS"

echo
echo "=== 15. CURRENT CLOUDFLARE PREVIEW UNCHANGED ==="

PREVIEW_API_FINAL=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_FINAL=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_API_IMAGE_FINAL=$(docker inspect "$PREVIEW_API" --format='{{.Config.Image}}' 2>/dev/null || echo missing)
PREVIEW_GUI_IMAGE_FINAL=$(docker inspect "$PREVIEW_GUI" --format='{{.Config.Image}}' 2>/dev/null || echo missing)

[ "$PREVIEW_API_FINAL" = true ] || die "current preview API changed/stopped"
[ "$PREVIEW_GUI_FINAL" = true ] || die "current preview GUI changed/stopped"
[ "$PREVIEW_API_IMAGE_FINAL" = "$PREVIEW_API_IMAGE" ] || die "current preview API image changed"
[ "$PREVIEW_GUI_IMAGE_FINAL" = "$PREVIEW_GUI_IMAGE" ] || die "current preview GUI image changed"

echo "current_preview_unchanged=PASS"

echo
echo "=== 16. PRODUCTION FINAL SAFETY ==="

FINAL_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
FINAL_AUDIT=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)
FINAL_ISSUANCES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)

[ "$FINAL_IMAGE" = "$PROD_IMAGE" ] || die "production API image changed"
[ "$FINAL_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "production migrations changed"
[ "$FINAL_USERS" = "$PROD_USERS" ] || die "production users changed"
[ "$FINAL_ROLES" = "$PROD_ROLES" ] || die "production roles changed"
[ "$FINAL_PERMS" = "$PROD_PERMS" ] || die "production permissions changed"
[ "$FINAL_AUDIT" = "$PROD_AUDIT" ] || die "production audit events changed"
[ "$FINAL_ISSUANCES" = "$PROD_ISSUANCES" ] || die "production issuances changed"

echo "production_unchanged=PASS"

COMPLETED=1

echo
echo "======================================================"
echo " QFLM RECOVERY 7H2 PASSED"
echo "======================================================"
echo "AUDIT POLICY:                      PASS"
echo "REPORTS POLICY:                    PASS"
echo "AUDIT SUMMARY API:                 PASS"
echo "AUDIT EVENTS API:                  PASS"
echo "OFFLINE ISSUANCE REPORT API:       PASS"
echo "AUDIT & REPORTS GUI ROUTE:         PASS"
echo "ISOLATED API/GUI HARDENING:        PASS"
echo "CURRENT CLOUDFLARE PREVIEW:        UNCHANGED"
echo "PRODUCTION API/DB:                 UNCHANGED"
echo "API CANDIDATE IMAGE:               $API_IMAGE"
echo "GUI CANDIDATE IMAGE:               $GUI_IMAGE"
echo "REPORT:                            $REPORT"
echo "NEXT: RECOVERY 7H3 - REFRESH CLOUDFLARE PREVIEW WITH AUDIT & REPORTS"
echo "======================================================"
