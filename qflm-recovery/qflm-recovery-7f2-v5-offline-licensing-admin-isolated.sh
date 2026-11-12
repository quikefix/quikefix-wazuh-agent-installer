#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API_SRC="$ROOT/src/QFLM.Api"
GUI="$ROOT/src/QFLM.AdminWeb"
PROGRAM="$API_SRC/Program.cs"

PROD_API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"
ISO_DB="qflm_recovery7f2_test"
ISO_API="qflm-api-recovery7f2-test"
ISO_GUI="qflm-admin-web-recovery7f2-test"
NET="qflm_backend"

PREVIEW_API="qflm-api-gui-preview"
PREVIEW_GUI="qflm-admin-web-gui-preview"
SIGNING_CONTAINER="qflm-signing"
SIGNING_TOKEN_TARGET="/run/qflm-signing/token"

EXPECTED_PROD_IMAGE="qflm-api:recovery6f3-candidate"
API_IMAGE="qflm-api:recovery7f2-candidate"
GUI_IMAGE="qflm-admin-web:recovery7f2-candidate"

ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"
RUNTIME_JWT="/opt/qflm/secrets/runtime-api/jwt-signing-key"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7f2-$STAMP"
REPORT="$BACKUP/recovery7f2-report.txt"
SOURCE_BACKUP="$BACKUP/source-before-phase16f2.tgz"
DB_DUMP="$BACKUP/qflm-before-phase16f2.dump"
ENV_FILE="$BACKUP/isolated-api.env"

API_PUBLISH="$ROOT/artifacts/api-publish-recovery7f2"
API_DOCKERFILE="$ROOT/Dockerfile.recovery7f2-api"
GUI_DOCKERFILE="$ROOT/Dockerfile.recovery7f2-gui"
GUI_NGINX_CONF="$ROOT/artifacts/recovery7f2-nginx.conf"

MUTATED=0
COMPLETED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

cleanup(){
    docker rm -f "$ISO_GUI" >/dev/null 2>&1 || true
    docker rm -f "$ISO_API" >/dev/null 2>&1 || true

    if [ "$COMPLETED" -ne 1 ] && [ "$MUTATED" -eq 1 ] && [ -s "$SOURCE_BACKUP" ]; then
        printf '\n=== SOURCE ROLLBACK ===\n'
        rm -f "$API_SRC/Controllers/AdminOfflineLicensingController.cs"
        rm -f "$GUI/src/pages/OfflineLicensingPage.tsx"
        tar -xzf "$SOURCE_BACKUP" -C "$ROOT" >/dev/null 2>&1 || true
        printf '%s\n' "source_restore_attempted=YES"
    fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

echo "======================================================"
echo " QFLM RECOVERY 7F2 V5"
echo " OFFLINE LICENSING ADMIN GUI/API"
echo " ISOLATED VALIDATION"
echo "======================================================"

echo
echo "=== 1. PRODUCTION + PREVIEW SAFETY BASELINE ==="

PROD_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
PROD_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
PROD_ISS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
PROD_AUD=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

PREVIEW_API_RUNNING=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_RUNNING=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)

printf 'prod_image=%s prod_running=%s migrations=%s offline_issuances=%s offline_audit=%s preview_api=%s preview_gui=%s\n' \
 "$PROD_IMAGE" "$PROD_RUNNING" "$MIG" "$PROD_ISS" "$PROD_AUD" "$PREVIEW_API_RUNNING" "$PREVIEW_GUI_RUNNING"

[ "$PROD_IMAGE" = "$EXPECTED_PROD_IMAGE" ] || die "unexpected production API image"
[ "$PROD_RUNNING" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"
[ -s "$ADMIN_USER_FILE" ] || die "platform admin username missing"
[ -s "$ADMIN_PASS_FILE" ] || die "platform admin password missing"
[ -s "$RUNTIME_JWT" ] || die "JWT runtime secret missing"

[ "$(docker inspect "$SIGNING_CONTAINER" --format='{{.State.Running}}' 2>/dev/null || echo false)" = true ] || die "signing container not running"

SIGNING_TOKEN_CONTAINER_PATH=$(docker inspect "$SIGNING_CONTAINER" --format='{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1=="Signing__TokenPath"{print $2; exit}')
[ -n "$SIGNING_TOKEN_CONTAINER_PATH" ] || die "signing token path environment missing"

SIGNING_TOKEN_SOURCE=$(docker inspect "$SIGNING_CONTAINER" --format='{{range .Mounts}}{{println .Source "|" .Destination}}{{end}}' | awk -F'|' -v target="$SIGNING_TOKEN_CONTAINER_PATH" '$2==target{print $1; exit}')

if [ -z "$SIGNING_TOKEN_SOURCE" ]; then
    CANONICAL_SIGNING_TOKEN="/opt/qflm/secrets/signing-runtime/token"
    [ -s "$CANONICAL_SIGNING_TOKEN" ] || die "signing token source not discoverable and canonical recovery token missing"
    SIGNING_TOKEN_SOURCE="$CANONICAL_SIGNING_TOKEN"
    echo "signing_token_source=CANONICAL_RECOVERY_PATH"
else
    echo "signing_token_source=CONTAINER_MOUNT_METADATA"
fi

[ -s "$SIGNING_TOKEN_SOURCE" ] || die "signing token host source missing"
[ "$(stat -c %a "$SIGNING_TOKEN_SOURCE")" = "400" ] || die "signing token host source mode is not 0400"

echo "signing_container=PASS token_source=RESOLVED"
echo "production_preview_baseline=PASS"

echo
echo "=== 2. VERIFY PRIOR SOURCE + OFFLINE SERVICE ==="

for f in \
 "$API_SRC/Controllers/AdminInstallationsController.cs" \
 "$API_SRC/Controllers/AdminLicensesController.cs" \
 "$GUI/src/pages/InstallationsPage.tsx" \
 "$GUI/src/pages/LicensesPage.tsx" \
 "$ROOT/src/QFLM.Application/OfflineLicensing/IOfflineLicenseIssuanceService.cs" \
 "$ROOT/src/QFLM.Application/OfflineLicensing/OfflineIssueCommand.cs" \
 "$ROOT/src/QFLM.Infrastructure/OfflineLicensing/EfOfflineLicenseIssuanceService.cs" \
 "$ROOT/src/QFLM.Infrastructure/OfflineLicensing/InternalSigningClient.cs"
do
    [ -s "$f" ] || die "required source missing: $f"
done

echo "prior_source=PASS"
echo "offline_signing_boundary=EXISTING_INTERNAL_SERVICE"

echo
echo "=== 3. BACKUP SOURCE + PRODUCTION DATABASE ==="

tar -czf "$SOURCE_BACKUP" -C "$ROOT" "src/QFLM.Api" "src/QFLM.AdminWeb" || die "source backup failed"
docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" -Fc > "$DB_DUMP" || die "production DB backup failed"
[ -s "$DB_DUMP" ] || die "production DB backup empty"

printf 'source_backup_sha256=%s\n' "$(sha256sum "$SOURCE_BACKUP" | awk '{print $1}')"
printf 'database_backup_sha256=%s\n' "$(sha256sum "$DB_DUMP" | awk '{print $1}')"

MUTATED=1

echo
echo "=== 4. REGISTER OFFLINE ISSUANCE + SIGNING CLIENT DI ==="

python3 - "$PROGRAM" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

marker = "QFLM RECOVERY OFFLINE DI"
if marker not in s:
    registration = r'''
// QFLM RECOVERY OFFLINE DI
builder.Services.AddScoped<
    QFLM.Application.OfflineLicensing.IOfflineLicenseIssuanceService,
    QFLM.Infrastructure.OfflineLicensing.EfOfflineLicenseIssuanceService>();

builder.Services.AddHttpClient("QFLM.Signing");

builder.Services.AddScoped<QFLM.Infrastructure.OfflineLicensing.InternalSigningClient>(
    serviceProvider =>
    {
        var configuration =
            serviceProvider.GetRequiredService<IConfiguration>();

        var baseUrl =
            configuration["OfflineSigning:BaseUrl"]
            ?? throw new InvalidOperationException(
                "Offline signing service base URL is not configured.");

        var tokenPath =
            configuration["OfflineSigning:TokenPath"]
            ?? throw new InvalidOperationException(
                "Offline signing token path is not configured.");

        if (!File.Exists(tokenPath))
            throw new InvalidOperationException(
                "Offline signing token file does not exist.");

        var token = File.ReadAllText(tokenPath).Trim();

        if (string.IsNullOrWhiteSpace(token))
            throw new InvalidOperationException(
                "Offline signing token is empty.");

        var factory =
            serviceProvider.GetRequiredService<IHttpClientFactory>();

        var client = factory.CreateClient("QFLM.Signing");
        client.BaseAddress = new Uri(baseUrl);

        return new QFLM.Infrastructure.OfflineLicensing.InternalSigningClient(
            client,
            token);
    });

'''
    pattern = r'(?m)^(\s*var\s+app\s*=\s*builder\.Build\(\);\s*)$'
    if not re.search(pattern, s):
        raise SystemExit("Program.cs builder.Build() anchor missing")
    s = re.sub(pattern, registration + r'\1', s, count=1)

p.write_text(s)
PY

grep -Fq 'IOfflineLicenseIssuanceService' "$PROGRAM" || die "offline issuance DI registration missing"
grep -Fq 'OfflineSigning:BaseUrl' "$PROGRAM" || die "offline signing base URL registration missing"
grep -Fq 'OfflineSigning:TokenPath' "$PROGRAM" || die "offline signing token-path registration missing"

echo "offline_issuance_di=CREATED"
echo "internal_signing_client_di=CREATED"

echo
echo "=== 5. CREATE OFFLINE ADMIN API ==="

cat > "$API_SRC/Controllers/AdminOfflineLicensingController.cs" <<'CS'
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Npgsql;
using QFLM.Application.OfflineLicensing;

namespace QFLM.Api.Controllers;

[ApiController]
[Route("api/v1/admin/offline")]
[Authorize(Policy = "permission:security.admin")]
public sealed class AdminOfflineLicensingController : ControllerBase
{
    private readonly NpgsqlDataSource _dataSource;
    private readonly IOfflineLicenseIssuanceService _issuanceService;

    public AdminOfflineLicensingController(
        NpgsqlDataSource dataSource,
        IOfflineLicenseIssuanceService issuanceService)
    {
        _dataSource = dataSource;
        _issuanceService = issuanceService;
    }

    [HttpGet("eligible-installations")]
    public async Task<IActionResult> EligibleInstallations(CancellationToken cancellationToken)
    {
        const string sql =
            "SELECT i.installation_identifier,l.id,l.license_number,l.status," +
            "p.product_code,p.name,c.customer_number,c.name,i.status," +
            "i.machine_fingerprint_hash,i.installation_public_key,i.highest_lease_sequence " +
            "FROM installations i " +
            "JOIN licenses l ON l.id=i.license_id " +
            "JOIN products p ON p.id=l.product_id " +
            "JOIN customers c ON c.id=l.customer_id " +
            "WHERE l.status='Active' AND i.status='Active' " +
            "ORDER BY c.name,l.license_number,i.created_at_utc;";

        var result = new List<object>();

        await using var command = _dataSource.CreateCommand(sql);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            result.Add(new
            {
                installationIdentifier = reader.GetGuid(0),
                licenseId = reader.GetGuid(1),
                licenseNumber = reader.GetString(2),
                licenseStatus = reader.GetString(3),
                productCode = reader.GetString(4),
                productName = reader.GetString(5),
                customerNumber = reader.GetString(6),
                customerName = reader.GetString(7),
                installationStatus = reader.GetString(8),
                machineFingerprintHash = reader.GetString(9),
                installationPublicKey = reader.IsDBNull(10) ? null : reader.GetString(10),
                highestLeaseSequence = reader.GetInt64(11)
            });
        }

        return Ok(result);
    }

    [HttpGet("issuances")]
    public async Task<IActionResult> Issuances(CancellationToken cancellationToken)
    {
        const string sql =
            "SELECT oi.id,l.license_number,i.installation_identifier,oi.request_id," +
            "oi.lease_sequence,oi.key_id,oi.license_digest,oi.status,oi.issued_at_utc," +
            "oi.expires_at_utc,oi.grace_ends_at_utc,c.customer_number,p.product_code " +
            "FROM offline_license_issuances oi " +
            "JOIN licenses l ON l.id=oi.license_id " +
            "JOIN installations i ON i.id=oi.installation_id " +
            "JOIN customers c ON c.id=l.customer_id " +
            "JOIN products p ON p.id=l.product_id " +
            "ORDER BY oi.issued_at_utc DESC;";

        var result = new List<object>();
        await using var command = _dataSource.CreateCommand(sql);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            result.Add(new
            {
                id = reader.GetGuid(0),
                licenseNumber = reader.GetString(1),
                installationIdentifier = reader.GetGuid(2),
                requestId = reader.GetGuid(3),
                leaseSequence = reader.GetInt64(4),
                keyId = reader.GetString(5),
                licenseDigest = reader.GetString(6),
                status = reader.GetString(7),
                issuedAtUtc = reader.GetDateTime(8),
                expiresAtUtc = reader.IsDBNull(9) ? (DateTime?)null : reader.GetDateTime(9),
                graceEndsAtUtc = reader.IsDBNull(10) ? (DateTime?)null : reader.GetDateTime(10),
                customerNumber = reader.GetString(11),
                productCode = reader.GetString(12)
            });
        }

        return Ok(result);
    }

    [HttpGet("audit")]
    public async Task<IActionResult> Audit(CancellationToken cancellationToken)
    {
        const string sql =
            "SELECT a.id,l.license_number,i.installation_identifier,a.event_type," +
            "a.outcome,a.request_id,a.lease_sequence,a.occurred_at_utc " +
            "FROM offline_license_audit_events a " +
            "JOIN licenses l ON l.id=a.license_id " +
            "JOIN installations i ON i.id=a.installation_id " +
            "ORDER BY a.occurred_at_utc DESC LIMIT 500;";

        var result = new List<object>();
        await using var command = _dataSource.CreateCommand(sql);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            result.Add(new
            {
                id = reader.GetGuid(0),
                licenseNumber = reader.GetString(1),
                installationIdentifier = reader.GetGuid(2),
                eventType = reader.GetString(3),
                outcome = reader.GetString(4),
                requestId = reader.IsDBNull(5) ? null : reader.GetString(5),
                leaseSequence = reader.IsDBNull(6) ? (long?)null : reader.GetInt64(6),
                occurredAtUtc = reader.GetDateTime(7)
            });
        }

        return Ok(result);
    }

    [HttpPost("issue")]
    public async Task<IActionResult> Issue(
        [FromBody] OfflineIssueRequest request,
        CancellationToken cancellationToken)
    {
        if (request.LicenseId == Guid.Empty ||
            request.InstallationIdentifier == Guid.Empty ||
            request.RequestId == Guid.Empty ||
            string.IsNullOrWhiteSpace(request.ProductCode) ||
            string.IsNullOrWhiteSpace(request.MachineFingerprintHash) ||
            string.IsNullOrWhiteSpace(request.InstallationPublicKey) ||
            string.IsNullOrWhiteSpace(request.RequestDigest))
        {
            return BadRequest(new { error = "OFFLINE_REQUEST_FIELDS_REQUIRED" });
        }

        try
        {
            var result = await _issuanceService.IssueAsync(
                new OfflineIssueCommand
                {
                    LicenseId = request.LicenseId,
                    InstallationIdentifier = request.InstallationIdentifier,
                    RequestId = request.RequestId,
                    ProductCode = request.ProductCode.Trim(),
                    MachineFingerprintHash = request.MachineFingerprintHash.Trim(),
                    InstallationPublicKey = request.InstallationPublicKey.Trim(),
                    RequestDigest = request.RequestDigest.Trim().ToLowerInvariant()
                },
                cancellationToken);

            return Ok(new
            {
                result.IssuanceId,
                result.LeaseSequence,
                result.LicenseDigest,
                signedLicenseJson = result.SignedLicenseJson
            });
        }
        catch (InvalidOperationException ex)
        {
            return Conflict(new { error = "OFFLINE_ISSUE_REJECTED", message = ex.Message });
        }
    }

    public sealed record OfflineIssueRequest
    {
        public required Guid LicenseId { get; init; }
        public required Guid InstallationIdentifier { get; init; }
        public required Guid RequestId { get; init; }
        public required string ProductCode { get; init; }
        public required string MachineFingerprintHash { get; init; }
        public required string InstallationPublicKey { get; init; }
        public required string RequestDigest { get; init; }
    }
}
CS

echo "offline_admin_api=CREATED"

echo
echo "=== 6. CREATE OFFLINE LICENSING GUI ==="

cat > "$GUI/src/pages/OfflineLicensingPage.tsx" <<'TSX'
import { useEffect, useMemo, useState } from "react";
import { apiFetch } from "../lib/api";

type Eligible = {
  installationIdentifier: string;
  licenseId: string;
  licenseNumber: string;
  productCode: string;
  customerNumber: string;
  machineFingerprintHash: string;
  installationPublicKey: string | null;
  highestLeaseSequence: number;
};

type Issuance = {
  id: string;
  licenseNumber: string;
  installationIdentifier: string;
  requestId: string;
  leaseSequence: number;
  keyId: string;
  licenseDigest: string;
  status: string;
  issuedAtUtc: string;
  customerNumber: string;
  productCode: string;
};

type Audit = {
  id: string;
  licenseNumber: string;
  installationIdentifier: string;
  eventType: string;
  outcome: string;
  requestId: string | null;
  leaseSequence: number | null;
  occurredAtUtc: string;
};

type IssueResult = {
  issuanceId: string;
  leaseSequence: number;
  licenseDigest: string;
  signedLicenseJson: string;
};

export function OfflineLicensingPage() {
  const [eligible, setEligible] = useState<Eligible[]>([]);
  const [issuances, setIssuances] = useState<Issuance[]>([]);
  const [audit, setAudit] = useState<Audit[]>([]);
  const [selected, setSelected] = useState("");
  const [publicKey, setPublicKey] = useState("");
  const [requestId, setRequestId] = useState<string>(crypto.randomUUID());
  const [requestDigest, setRequestDigest] = useState("");
  const [result, setResult] = useState<IssueResult | null>(null);
  const [error, setError] = useState("");

  async function load() {
    const [e, i, a] = await Promise.all([
      apiFetch<Eligible[]>("/v1/admin/offline/eligible-installations"),
      apiFetch<Issuance[]>("/v1/admin/offline/issuances"),
      apiFetch<Audit[]>("/v1/admin/offline/audit")
    ]);
    setEligible(e);
    setIssuances(i);
    setAudit(a);
  }

  useEffect(() => {
    load().catch(() => setError("Offline licensing data could not be loaded."));
  }, []);

  const selectedItem = useMemo(
    () => eligible.find((x) => x.installationIdentifier === selected) ?? null,
    [eligible, selected]
  );

  useEffect(() => {
    setPublicKey(selectedItem?.installationPublicKey ?? "");
  }, [selectedItem]);

  async function issue() {
    if (!selectedItem) {
      setError("Select an eligible installation.");
      return;
    }

    if (!publicKey.trim() || !requestDigest.trim()) {
      setError("Installation public key and request digest are required.");
      return;
    }

    try {
      const response = await apiFetch<IssueResult>("/v1/admin/offline/issue", {
        method: "POST",
        body: JSON.stringify({
          licenseId: selectedItem.licenseId,
          installationIdentifier: selectedItem.installationIdentifier,
          requestId,
          productCode: selectedItem.productCode,
          machineFingerprintHash: selectedItem.machineFingerprintHash,
          installationPublicKey: publicKey.trim(),
          requestDigest: requestDigest.trim()
        })
      });
      setResult(response);
      setError("");
      setRequestId(crypto.randomUUID());
      setRequestDigest("");
      await load();
    } catch {
      setError("Offline license could not be issued. Check request binding and license state.");
    }
  }

  function downloadLicense() {
    if (!result) return;
    const blob = new Blob([result.signedLicenseJson], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `qflm-${result.issuanceId}.qfl`;
    a.click();
    URL.revokeObjectURL(url);
  }

  return (
    <>
      <div className="page-heading">
        <div>
          <h1>Offline Licensing</h1>
          <p>Issue signed offline licenses and review issuance history and audit events.</p>
        </div>
      </div>

      {error && <div className="page-error">{error}</div>}

      <article className="panel">
        <h2>Issue offline license</h2>
        <div className="form-grid">
          <label>
            Eligible installation
            <select value={selected} onChange={(e) => setSelected(e.target.value)}>
              <option value="">Select installation</option>
              {eligible.map((x) => (
                <option key={x.installationIdentifier} value={x.installationIdentifier}>
                  {x.customerNumber} · {x.licenseNumber} · {x.productCode} · {x.installationIdentifier}
                </option>
              ))}
            </select>
          </label>

          <label>
            Request ID
            <input value={requestId} onChange={(e) => setRequestId(e.target.value)} />
          </label>

          <label className="form-grid-wide">
            Installation public key
            <textarea rows={4} value={publicKey} onChange={(e) => setPublicKey(e.target.value)}
              placeholder="Paste the public key from the .qfreq request" />
          </label>

          <label className="form-grid-wide">
            Request digest
            <input value={requestDigest} onChange={(e) => setRequestDigest(e.target.value)}
              placeholder="SHA-256 digest from the validated .qfreq request" />
          </label>
        </div>

        {selectedItem && (
          <div className="detail-strip">
            <span>License: <strong>{selectedItem.licenseNumber}</strong></span>
            <span>Product: <strong>{selectedItem.productCode}</strong></span>
            <span>Lease sequence: <strong>{selectedItem.highestLeaseSequence}</strong></span>
          </div>
        )}

        <button className="primary-button" onClick={issue}>Issue signed .qfl</button>

        {result && (
          <div className="success-panel">
            <strong>Offline license issued.</strong>
            <span>Lease sequence: {result.leaseSequence}</span>
            <span>Digest: <code>{result.licenseDigest}</code></span>
            <button className="secondary-button" onClick={downloadLicense}>Download .qfl</button>
          </div>
        )}
      </article>

      <article className="panel">
        <h2>Issuance history</h2>
        <div className="table-wrap">
          <table>
            <thead>
              <tr><th>Issued</th><th>License</th><th>Customer</th><th>Product</th><th>Lease</th><th>Status</th><th>Key</th><th>Digest</th></tr>
            </thead>
            <tbody>
              {issuances.map((x) => (
                <tr key={x.id}>
                  <td>{new Date(x.issuedAtUtc).toLocaleString()}</td>
                  <td>{x.licenseNumber}</td>
                  <td>{x.customerNumber}</td>
                  <td>{x.productCode}</td>
                  <td>{x.leaseSequence}</td>
                  <td>{x.status}</td>
                  <td><code>{x.keyId}</code></td>
                  <td><code>{x.licenseDigest.slice(0, 16)}…</code></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </article>

      <article className="panel">
        <h2>Offline audit</h2>
        <div className="table-wrap">
          <table>
            <thead>
              <tr><th>Occurred</th><th>Event</th><th>Outcome</th><th>License</th><th>Installation</th><th>Lease</th></tr>
            </thead>
            <tbody>
              {audit.map((x) => (
                <tr key={x.id}>
                  <td>{new Date(x.occurredAtUtc).toLocaleString()}</td>
                  <td>{x.eventType}</td>
                  <td>{x.outcome}</td>
                  <td>{x.licenseNumber}</td>
                  <td><code>{x.installationIdentifier}</code></td>
                  <td>{x.leaseSequence ?? "—"}</td>
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

python3 - "$GUI/src/App.tsx" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
imp='import { OfflineLicensingPage } from "./pages/OfflineLicensingPage";'
marker='import { InstallationsPage } from "./pages/InstallationsPage";'
if imp not in s:
    if marker not in s:
        raise SystemExit("InstallationsPage import marker missing")
    s=s.replace(marker, marker+"\n"+imp, 1)
old='''            <Route
              path="offline"
              element={
                <PlaceholderPage
                  title="Offline Licensing"
                  description="Offline requests, signed licenses and renewals."
                />
              }
            />'''
new='''            <Route path="offline" element={<OfflineLicensingPage />} />'''
if old not in s:
    raise SystemExit("offline placeholder route marker missing")
s=s.replace(old,new,1)
p.write_text(s)
PY

cat >> "$GUI/src/styles.css" <<'CSS'

.form-grid-wide { grid-column: 1 / -1; }
.form-grid textarea,
.form-grid select {
  width: 100%;
  border: 1px solid #d7deea;
  border-radius: 9px;
  padding: 10px 12px;
  background: #fff;
}
.detail-strip {
  display: flex;
  gap: 18px;
  flex-wrap: wrap;
  margin: 14px 0;
  padding: 12px;
  border-radius: 10px;
  background: #f8fafc;
}
.success-panel {
  display: grid;
  gap: 9px;
  margin-top: 16px;
  padding: 14px;
  border-radius: 10px;
  background: #ecfdf5;
}
CSS

echo "offline_admin_gui=CREATED"

echo
echo "=== 7. RELEASE BUILD ==="
dotnet build QuikeFix.LicenseManager.slnx -c Release || die "Phase 16F.2 release build failed"
echo "release_build=PASS"

echo
echo "=== 8. CLONE PRODUCTION DATABASE ==="
docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" >/dev/null
docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB"
docker exec "$PG" createdb -U qflm "$ISO_DB" || die "isolated DB create failed"
docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges  | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null  || die "isolated DB clone failed"
echo "isolated_database_clone=PASS"

echo
echo "=== 9. BUILD API CANDIDATE ==="
rm -rf "$API_PUBLISH"
dotnet publish "$API_SRC/QFLM.Api.csproj" -c Release -o "$API_PUBLISH" || die "API publish failed"

cat > "$API_DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-recovery7f2/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER

docker build -f "$API_DOCKERFILE" -t "$API_IMAGE" . || die "API candidate build failed"
echo "api_candidate_image=$API_IMAGE"

echo
echo "=== 10. PREPARE + START ISOLATED API ==="
docker inspect "$PROD_API" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$ENV_FILE" || die "capture production environment failed"
chmod 600 "$ENV_FILE"

cat >> "$ENV_FILE" <<EOF
Qflm__PostgreSqlDatabase=$ISO_DB
PostgreSqlDatabase=$ISO_DB
EOF
chmod 600 "$ENV_FILE"

printf '%s\n' "OfflineSigning__BaseUrl=http://qflm-signing:8080" >> "$ENV_FILE"
printf '%s\n' "OfflineSigning__TokenPath=$SIGNING_TOKEN_TARGET" >> "$ENV_FILE"

docker rm -f "$ISO_API" >/dev/null 2>&1 || true
docker run -d  --name "$ISO_API"  --network "$NET"  --network-alias qflm-api-recovery7f2-backend  --env-file "$ENV_FILE"  --volumes-from "$PROD_API:ro"   --mount type=bind,src="$SIGNING_TOKEN_SOURCE",dst="$SIGNING_TOKEN_TARGET",readonly  --read-only  --cap-drop ALL  --security-opt no-new-privileges:true  --tmpfs /tmp:rw,noexec,nosuid,size=16m  "$API_IMAGE" >/dev/null || die "isolated API start failed"

sleep 5
docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS "http://$ISO_API:8080/health/ready" >/dev/null  || { docker logs --tail 200 "$ISO_API" || true; die "isolated API readiness failed"; }
echo "isolated_api_health=PASS"
ISO_DB_ENV=$(docker inspect "$ISO_API" --format='{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1=="Qflm__PostgreSqlDatabase"{print $2}' | tail -n1)
printf 'isolated_api_database=%s\n' "$ISO_DB_ENV"
[ "$ISO_DB_ENV" = "$ISO_DB" ] || die "isolated API is not bound to isolated database"
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
            proxy_pass http://qflm-api-recovery7f2-backend:8080/api/;
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
COPY artifacts/recovery7f2-nginx.conf /etc/nginx/nginx-qflm.conf
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
echo "gui_candidate_image=$GUI_IMAGE"
echo "isolated_gui_running=PASS"

echo
echo "=== 12. ADMIN LOGIN ==="
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

echo "admin_login=PASS"

echo
echo "=== 13. OFFLINE LIST API TESTS ==="
ELIGIBLE_JSON=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS  -H "Authorization: Bearer $TOKEN"  "http://$ISO_GUI:8080/api/v1/admin/offline/eligible-installations") || die "eligible installations endpoint failed"

ELIGIBLE_COUNT=$(python3 - "$ELIGIBLE_JSON" <<'PY'
import json,sys
print(len(json.loads(sys.argv[1])))
PY
)
[ "$ELIGIBLE_COUNT" -ge 1 ] || die "no eligible active installation found"

ISS_BEFORE=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
AUD_BEFORE=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

echo "offline_list_api=PASS eligible=$ELIGIBLE_COUNT"

echo
echo "=== 14. END-TO-END OFFLINE SIGNED LICENSE TEST ==="

TEST_PAYLOAD=$(python3 - "$ELIGIBLE_JSON" <<'PY'
import json,sys,uuid,hashlib
x=json.loads(sys.argv[1])[0]
pub=x.get("installationPublicKey") or ("QFLM-ISOLATED-PREVIEW-PUBLIC-KEY-"+uuid.uuid4().hex)
rid=str(uuid.uuid4())
canonical="|".join([rid,x["licenseId"],x["installationIdentifier"],x["productCode"],x["machineFingerprintHash"],pub])
digest=hashlib.sha256(canonical.encode()).hexdigest()
print(json.dumps({
 "licenseId":x["licenseId"],
 "installationIdentifier":x["installationIdentifier"],
 "requestId":rid,
 "productCode":x["productCode"],
 "machineFingerprintHash":x["machineFingerprintHash"],
 "installationPublicKey":pub,
 "requestDigest":digest
}))
PY
)

ISSUE_HTTP=$(printf '%s' "$TEST_PAYLOAD" | docker run --rm --network "$NET" -i  curlimages/curl:8.16.0 -sS -o "$BACKUP/issue-response.json" -w '%{http_code}'  -H 'Content-Type: application/json'  -H "Authorization: Bearer $TOKEN"  -X POST "http://$ISO_GUI:8080/api/v1/admin/offline/issue"  --data-binary @-)

[ "$ISSUE_HTTP" = 200 ] || { cat "$BACKUP/issue-response.json" || true; docker logs --tail 240 "$ISO_API" || true; die "offline signed license issuance failed"; }

python3 - "$BACKUP/issue-response.json" <<'PY'
import json,sys
obj=json.load(open(sys.argv[1]))
assert obj.get("issuanceId")
assert int(obj.get("leaseSequence",0)) >= 1
assert len(obj.get("licenseDigest","")) == 64
signed=json.loads(obj["signedLicenseJson"])
assert signed.get("payloadBase64")
assert signed.get("signatureBase64")
assert signed.get("keyId")
print("offline_signed_envelope=PASS")
PY

rm -f "$BACKUP/issue-response.json"

ISS_AFTER=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
AUD_AFTER=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

[ "$ISS_AFTER" -eq $((ISS_BEFORE + 1)) ] || die "offline issuance persistence mismatch"
[ "$AUD_AFTER" -eq $((AUD_BEFORE + 1)) ] || die "offline audit persistence mismatch"

echo "offline_issuance_persistence=PASS"
echo "offline_audit_persistence=PASS"

echo
echo "=== 15. DUPLICATE REQUEST PROTECTION TEST ==="
DUP_HTTP=$(printf '%s' "$TEST_PAYLOAD" | docker run --rm --network "$NET" -i  curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}'  -H 'Content-Type: application/json'  -H "Authorization: Bearer $TOKEN"  -X POST "http://$ISO_GUI:8080/api/v1/admin/offline/issue"  --data-binary @-)

[ "$DUP_HTTP" = 409 ] || die "duplicate offline request protection failed"
echo "duplicate_request_protection=PASS"

echo
echo "=== 16. HISTORY + AUDIT API TEST ==="
HISTORY_JSON=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS  -H "Authorization: Bearer $TOKEN" "http://$ISO_GUI:8080/api/v1/admin/offline/issuances") || die "offline history failed"
AUDIT_JSON=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS  -H "Authorization: Bearer $TOKEN" "http://$ISO_GUI:8080/api/v1/admin/offline/audit") || die "offline audit failed"

HCOUNT=$(python3 - "$HISTORY_JSON" <<'PY'
import json,sys
print(len(json.loads(sys.argv[1])))
PY
)
ACOUNT=$(python3 - "$AUDIT_JSON" <<'PY'
import json,sys
print(len(json.loads(sys.argv[1])))
PY
)

[ "$HCOUNT" -ge 1 ] || die "offline history empty after issuance"
[ "$ACOUNT" -ge 1 ] || die "offline audit empty after issuance"

echo "offline_history_api=PASS count=$HCOUNT"
echo "offline_audit_api=PASS count=$ACOUNT"

echo
echo "=== 17. GUI ROUTE TEST ==="
GUI_HTTP=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' "http://$ISO_GUI:8080/offline")
[ "$GUI_HTTP" = 200 ] || die "offline GUI route failed"
echo "offline_gui_route=PASS"

echo
echo "=== 18. REVOKE TEST SESSION ==="
REVOKE_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)

REVOKE_HTTP=$(printf '%s' "$REVOKE_JSON" | docker run --rm --network "$NET" -i  curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}'  -H 'Content-Type: application/json'  -H "Authorization: Bearer $TOKEN"  -X POST "http://$ISO_GUI:8080/api/v1/auth/revoke"  --data-binary @-)

[ "$REVOKE_HTTP" = 204 ] || die "test session revoke failed"
echo "test_session_revoked=PASS"

unset TOKEN REFRESH ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE REVOKE_JSON TEST_PAYLOAD

echo
echo "=== 19. CURRENT CLOUDFLARE PREVIEW UNCHANGED ==="
PREVIEW_API_FINAL=$(docker inspect "$PREVIEW_API" --format='{{.State.Running}}' 2>/dev/null || echo missing)
PREVIEW_GUI_FINAL=$(docker inspect "$PREVIEW_GUI" --format='{{.State.Running}}' 2>/dev/null || echo missing)
printf 'preview_api_running=%s preview_gui_running=%s\n' "$PREVIEW_API_FINAL" "$PREVIEW_GUI_FINAL"
[ "$PREVIEW_API_FINAL" = "$PREVIEW_API_RUNNING" ] || die "preview API state changed"
[ "$PREVIEW_GUI_FINAL" = "$PREVIEW_GUI_RUNNING" ] || die "preview GUI state changed"
echo "existing_preview_unchanged=PASS"

echo
echo "=== 20. PRODUCTION FINAL SAFETY ==="
FINAL_IMAGE=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUNNING=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_ISS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_issuances;' | xargs)
FINAL_AUD=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM offline_license_audit_events;' | xargs)

printf 'image=%s running=%s migrations=%s offline_issuances=%s offline_audit=%s\n'  "$FINAL_IMAGE" "$FINAL_RUNNING" "$FINAL_MIG" "$FINAL_ISS" "$FINAL_AUD"

[ "$FINAL_IMAGE" = "$PROD_IMAGE" ] || die "production API image changed"
[ "$FINAL_RUNNING" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "production migrations changed"
[ "$FINAL_ISS" = "$PROD_ISS" ] || die "production offline issuances changed"
[ "$FINAL_AUD" = "$PROD_AUD" ] || die "production offline audit changed"

echo "production_unchanged=PASS"

COMPLETED=1

echo
echo "======================================================"
echo " QFLM RECOVERY 7F2 V5 PASSED"
echo "======================================================"
echo "OFFLINE DI REGISTRATION:             PASS"
echo "INTERNAL SIGNING CLIENT WIRING:      PASS"
echo "OFFLINE ELIGIBLE INSTALLATIONS API: PASS"
echo "SIGNED .QFL ISSUANCE:               PASS"
echo "SIGNING SERVICE BOUNDARY:           PASS"
echo "LEASE SEQUENCE PERSISTENCE:         PASS"
echo "OFFLINE ISSUANCE HISTORY:           PASS"
echo "OFFLINE AUDIT HISTORY:              PASS"
echo "DUPLICATE REQUEST PROTECTION:       PASS"
echo "OFFLINE GUI:                        PASS"
echo "CURRENT CLOUDFLARE PREVIEW:         UNCHANGED"
echo "PRODUCTION API/DB:                  UNCHANGED"
echo "API CANDIDATE IMAGE:                $API_IMAGE"
echo "GUI CANDIDATE IMAGE:                $GUI_IMAGE"
echo "REPORT:                             $REPORT"
echo "NEXT: PHASE 16F.3 - REFRESH CLOUDFLARE PREVIEW WITH OFFLINE LICENSING GUI"
echo "======================================================"