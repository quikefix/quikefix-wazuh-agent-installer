#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API_SRC="$ROOT/src/QFLM.Api"
GUI="$ROOT/src/QFLM.AdminWeb"
PROD_API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"
ISO_DB="qflm_recovery7d2_test"
ISO_API="qflm-api-recovery7d2-test"
ISO_GUI="qflm-admin-web-recovery7d2-test"
NET="qflm_backend"
EXPECTED_API_IMAGE="qflm-api:recovery6f3-candidate"
API_IMAGE="qflm-api:recovery7d2-candidate"
GUI_IMAGE="qflm-admin-web:recovery7d2-candidate"
ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"
RUNTIME_JWT="/opt/qflm/secrets/runtime-api/jwt-signing-key"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7d2-$STAMP"
REPORT="$BACKUP/recovery7d2-report.txt"
SOURCE_BACKUP="$BACKUP/source-before-phase16d2.tgz"
DB_DUMP="$BACKUP/qflm-before-phase16d2.dump"
ENV_FILE="$BACKUP/isolated-api.env"
API_PUBLISH="$ROOT/artifacts/api-publish-recovery7d2"
API_DOCKERFILE="$ROOT/Dockerfile.recovery7d2-api"
GUI_DOCKERFILE="$ROOT/Dockerfile.recovery7d2-gui"
MUTATED=0
COMPLETED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

cleanup(){
  docker rm -f "$ISO_GUI" >/dev/null 2>&1 || true
  docker rm -f "$ISO_API" >/dev/null 2>&1 || true
  if [ "$COMPLETED" -ne 1 ] && [ "$MUTATED" -eq 1 ] && [ -s "$SOURCE_BACKUP" ]; then
    printf '\n=== SOURCE ROLLBACK ===\n'
    rm -f "$API_SRC/Controllers/AdminSubscriptionsController.cs"
    rm -f "$API_SRC/Controllers/AdminLicensesController.cs"
    rm -f "$GUI/src/pages/LicensesPage.tsx"
    tar -xzf "$SOURCE_BACKUP" -C "$ROOT" >/dev/null 2>&1 || true
    printf '%s\n' "source_restore_attempted=YES"
  fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7D2"
printf '%s\n' " SUBSCRIPTIONS / LICENSES / ENTITLEMENTS"
printf '%s\n' " MANAGEMENT GUI + API - ISOLATED"
printf '%s\n' "======================================================"

printf '\n=== 1. PRODUCTION SAFETY BASELINE ===\n'
IMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
RUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
SUBS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM subscriptions;' | xargs)
LICS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
ENTS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM license_entitlements;' | xargs)
INSTALLS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'image=%s running=%s migrations=%s subscriptions=%s licenses=%s entitlements=%s installations=%s\n' "$IMG" "$RUN" "$MIG" "$SUBS" "$LICS" "$ENTS" "$INSTALLS"
[ "$IMG" = "$EXPECTED_API_IMAGE" ] || die "unexpected production API image"
[ "$RUN" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"
[ -s "$ADMIN_USER_FILE" ] || die "platform admin username missing"
[ -s "$ADMIN_PASS_FILE" ] || die "platform admin password missing"
[ -s "$RUNTIME_JWT" ] || die "JWT runtime secret missing"
printf '%s\n' "production_baseline=PASS"

printf '\n=== 2. VERIFY RECOVERY 7C SOURCE + AUTH BASIS ===\n'
for f in "$API_SRC/Controllers/AdminCustomersController.cs" "$API_SRC/Controllers/AdminProductsController.cs" "$GUI/src/pages/CustomersPage.tsx" "$GUI/src/pages/ProductsPage.tsx"; do
  [ -s "$f" ] || die "Phase 16C source missing: $f"
done
SEC_ADMIN=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM auth_permissions WHERE code='security.admin';" | xargs)
[ "$SEC_ADMIN" = 1 ] || die "security.admin permission missing"
printf '%s\n' "recovery7c_source=PASS"
printf '%s\n' "management_policy=permission:security.admin"

printf '\n=== 3. BACKUP SOURCE + DATABASE ===\n'
tar -czf "$SOURCE_BACKUP" -C "$ROOT" "src/QFLM.Api" "src/QFLM.AdminWeb" || die "source backup failed"
docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" -Fc > "$DB_DUMP" || die "DB backup failed"
[ -s "$DB_DUMP" ] || die "DB backup empty"
printf 'source_backup_sha256=%s\n' "$(sha256sum "$SOURCE_BACKUP" | awk '{print $1}')"
printf 'database_backup_sha256=%s\n' "$(sha256sum "$DB_DUMP" | awk '{print $1}')"
MUTATED=1

printf '\n=== 4. ADD SUBSCRIPTION MANAGEMENT API ===\n'
cat > "$API_SRC/Controllers/AdminSubscriptionsController.cs" <<'CS'
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Npgsql;
using NpgsqlTypes;
using QFLM.Domain.Subscriptions;

namespace QFLM.Api.Controllers;

[ApiController]
[Route("api/v1/admin/subscriptions")]
[Authorize(Policy = "permission:security.admin")]
public sealed class AdminSubscriptionsController : ControllerBase
{
    private readonly NpgsqlDataSource _db;
    public AdminSubscriptionsController(NpgsqlDataSource db) => _db = db;

    [HttpGet]
    public async Task<IActionResult> List(CancellationToken ct)
    {
        const string sql =
            "SELECT s.id,s.customer_id,c.customer_number,c.name,s.product_id,p.product_code,p.name," +
            "s.status,s.starts_at_utc,s.ends_at_utc,s.maximum_installations " +
            "FROM subscriptions s JOIN customers c ON c.id=s.customer_id " +
            "JOIN products p ON p.id=s.product_id ORDER BY s.created_at_utc DESC;";
        var rows = new List<object>();
        await using var cmd = _db.CreateCommand(sql);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new {
                id=r.GetGuid(0), customerId=r.GetGuid(1), customerNumber=r.GetString(2),
                customerName=r.GetString(3), productId=r.GetGuid(4), productCode=r.GetString(5),
                productName=r.GetString(6), status=r.GetString(7), startsAtUtc=r.GetDateTime(8),
                endsAtUtc=r.IsDBNull(9)?(DateTime?)null:r.GetDateTime(9), maximumInstallations=r.GetInt32(10)
            });
        return Ok(rows);
    }

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] CreateSubscriptionRequest request, CancellationToken ct)
    {
        if (!Enum.TryParse<SubscriptionStatus>(request.Status,true,out var status))
            return BadRequest(new { error="INVALID_SUBSCRIPTION_STATUS" });
        if (request.MaximumInstallations < 1)
            return BadRequest(new { error="INVALID_MAXIMUM_INSTALLATIONS" });
        if (request.EndsAtUtc.HasValue && request.EndsAtUtc.Value <= request.StartsAtUtc)
            return BadRequest(new { error="INVALID_SUBSCRIPTION_DATES" });

        const string checkSql =
            "SELECT (SELECT count(*) FROM customers WHERE id=@c AND is_active=true)," +
            "(SELECT count(*) FROM products WHERE id=@p AND is_active=true);";
        await using (var check=_db.CreateCommand(checkSql))
        {
            check.Parameters.AddWithValue("c",request.CustomerId);
            check.Parameters.AddWithValue("p",request.ProductId);
            await using var rr=await check.ExecuteReaderAsync(ct);
            await rr.ReadAsync(ct);
            if (rr.GetInt64(0)!=1) return BadRequest(new { error="CUSTOMER_NOT_ACTIVE" });
            if (rr.GetInt64(1)!=1) return BadRequest(new { error="PRODUCT_NOT_ACTIVE" });
        }

        var id=Guid.NewGuid();
        const string sql =
            "INSERT INTO subscriptions(id,customer_id,product_id,status,starts_at_utc,ends_at_utc," +
            "maximum_installations,created_at_utc,updated_at_utc) " +
            "VALUES(@id,@c,@p,@s,@start,@end,@max,NOW(),NOW());";
        await using var cmd=_db.CreateCommand(sql);
        cmd.Parameters.AddWithValue("id",id);
        cmd.Parameters.AddWithValue("c",request.CustomerId);
        cmd.Parameters.AddWithValue("p",request.ProductId);
        cmd.Parameters.AddWithValue("s",status.ToString());
        cmd.Parameters.Add(new NpgsqlParameter("start",NpgsqlDbType.TimestampTz){Value=request.StartsAtUtc});
        cmd.Parameters.Add(new NpgsqlParameter("end",NpgsqlDbType.TimestampTz){Value=(object?)request.EndsAtUtc??DBNull.Value});
        cmd.Parameters.AddWithValue("max",request.MaximumInstallations);
        await cmd.ExecuteNonQueryAsync(ct);
        return Ok(new { id, status=status.ToString() });
    }

    [HttpPut("{id:guid}/status")]
    public async Task<IActionResult> SetStatus(Guid id,[FromBody] SetStatusRequest request,CancellationToken ct)
    {
        if (!Enum.TryParse<SubscriptionStatus>(request.Status,true,out var status))
            return BadRequest(new { error="INVALID_SUBSCRIPTION_STATUS" });
        await using var cmd=_db.CreateCommand("UPDATE subscriptions SET status=@s,updated_at_utc=NOW() WHERE id=@id;");
        cmd.Parameters.AddWithValue("s",status.ToString());
        cmd.Parameters.AddWithValue("id",id);
        return await cmd.ExecuteNonQueryAsync(ct)==0 ? NotFound() : NoContent();
    }

    public sealed record CreateSubscriptionRequest
    {
        public required Guid CustomerId { get; init; }
        public required Guid ProductId { get; init; }
        public required string Status { get; init; }
        public required DateTime StartsAtUtc { get; init; }
        public DateTime? EndsAtUtc { get; init; }
        public required int MaximumInstallations { get; init; }
    }
    public sealed record SetStatusRequest { public required string Status { get; init; } }
}
CS
printf '%s\n' "subscription_management_api=CREATED"

printf '\n=== 5. ADD LICENSE + ENTITLEMENT MANAGEMENT API ===\n'
cat > "$API_SRC/Controllers/AdminLicensesController.cs" <<'CS'
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Npgsql;
using NpgsqlTypes;
using QFLM.Domain.Licenses;

namespace QFLM.Api.Controllers;

[ApiController]
[Route("api/v1/admin/licenses")]
[Authorize(Policy = "permission:security.admin")]
public sealed class AdminLicensesController : ControllerBase
{
    private readonly NpgsqlDataSource _db;
    public AdminLicensesController(NpgsqlDataSource db) => _db = db;

    [HttpGet]
    public async Task<IActionResult> List(CancellationToken ct)
    {
        const string sql =
            "SELECT l.id,l.license_number,l.customer_id,c.customer_number,c.name,l.product_id," +
            "p.product_code,p.name,l.subscription_id,l.type,l.status,l.valid_from_utc,l.valid_until_utc," +
            "l.grace_period_days,l.maximum_installations,(l.activation_key_hash IS NOT NULL)," +
            "(SELECT count(*) FROM license_entitlements le WHERE le.license_id=l.id) " +
            "FROM licenses l JOIN customers c ON c.id=l.customer_id JOIN products p ON p.id=l.product_id " +
            "ORDER BY l.created_at_utc DESC;";
        var rows=new List<object>();
        await using var cmd=_db.CreateCommand(sql);
        await using var r=await cmd.ExecuteReaderAsync(ct);
        while(await r.ReadAsync(ct))
            rows.Add(new {
                id=r.GetGuid(0), licenseNumber=r.GetString(1), customerId=r.GetGuid(2),
                customerNumber=r.GetString(3), customerName=r.GetString(4), productId=r.GetGuid(5),
                productCode=r.GetString(6), productName=r.GetString(7),
                subscriptionId=r.IsDBNull(8)?(Guid?)null:r.GetGuid(8), type=r.GetString(9), status=r.GetString(10),
                validFromUtc=r.IsDBNull(11)?(DateTime?)null:r.GetDateTime(11), validUntilUtc=r.IsDBNull(12)?(DateTime?)null:r.GetDateTime(12),
                gracePeriodDays=r.GetInt32(13), maximumInstallations=r.GetInt32(14),
                hasActivationKey=r.GetBoolean(15), entitlementCount=r.GetInt64(16)
            });
        return Ok(rows);
    }

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] CreateLicenseRequest request,CancellationToken ct)
    {
        var number=request.LicenseNumber?.Trim().ToUpperInvariant();
        if(string.IsNullOrWhiteSpace(number) || number.Length>100)
            return BadRequest(new { error="INVALID_LICENSE_NUMBER" });
        if(!Enum.TryParse<LicenseType>(request.Type,true,out var type))
            return BadRequest(new { error="INVALID_LICENSE_TYPE" });
        if(!Enum.TryParse<LicenseStatus>(request.Status,true,out var status))
            return BadRequest(new { error="INVALID_LICENSE_STATUS" });
        if(request.MaximumInstallations<1) return BadRequest(new { error="INVALID_MAXIMUM_INSTALLATIONS" });
        if(request.GracePeriodDays<0 || request.GracePeriodDays>365) return BadRequest(new { error="INVALID_GRACE_PERIOD" });

        const string checkSql =
            "SELECT (SELECT count(*) FROM customers WHERE id=@c AND is_active=true)," +
            "(SELECT count(*) FROM products WHERE id=@p AND is_active=true)," +
            "CASE WHEN @sub::uuid IS NULL THEN 1 ELSE " +
            "(SELECT count(*) FROM subscriptions WHERE id=@sub::uuid AND customer_id=@c AND product_id=@p) END;";
        await using(var check=_db.CreateCommand(checkSql))
        {
            check.Parameters.AddWithValue("c",request.CustomerId);
            check.Parameters.AddWithValue("p",request.ProductId);
            check.Parameters.Add(new NpgsqlParameter("sub",NpgsqlDbType.Uuid){Value=(object?)request.SubscriptionId??DBNull.Value});
            await using var rr=await check.ExecuteReaderAsync(ct);
            await rr.ReadAsync(ct);
            if(rr.GetInt64(0)!=1) return BadRequest(new { error="CUSTOMER_NOT_ACTIVE" });
            if(rr.GetInt64(1)!=1) return BadRequest(new { error="PRODUCT_NOT_ACTIVE" });
            if(rr.GetInt64(2)!=1) return BadRequest(new { error="SUBSCRIPTION_RELATIONSHIP_INVALID" });
        }

        var id=Guid.NewGuid();
        var activationKey=GenerateActivationKey();
        var hash=HashActivationKey(activationKey);

        const string sql =
            "INSERT INTO licenses(id,license_number,activation_key_hash,customer_id,product_id,subscription_id," +
            "type,status,valid_from_utc,valid_until_utc,grace_period_days,maximum_installations,created_at_utc,updated_at_utc) " +
            "VALUES(@id,@n,@h,@c,@p,@sub,@type,@status,@vf,@vu,@g,@max,NOW(),NOW());";
        try
        {
            await using var cmd=_db.CreateCommand(sql);
            cmd.Parameters.AddWithValue("id",id);
            cmd.Parameters.AddWithValue("n",number);
            cmd.Parameters.AddWithValue("h",hash);
            cmd.Parameters.AddWithValue("c",request.CustomerId);
            cmd.Parameters.AddWithValue("p",request.ProductId);
            cmd.Parameters.Add(new NpgsqlParameter("sub",NpgsqlDbType.Uuid){Value=(object?)request.SubscriptionId??DBNull.Value});
            cmd.Parameters.AddWithValue("type",type.ToString());
            cmd.Parameters.AddWithValue("status",status.ToString());
            cmd.Parameters.Add(new NpgsqlParameter("vf",NpgsqlDbType.TimestampTz){Value=(object?)request.ValidFromUtc??DBNull.Value});
            cmd.Parameters.Add(new NpgsqlParameter("vu",NpgsqlDbType.TimestampTz){Value=(object?)request.ValidUntilUtc??DBNull.Value});
            cmd.Parameters.AddWithValue("g",request.GracePeriodDays);
            cmd.Parameters.AddWithValue("max",request.MaximumInstallations);
            await cmd.ExecuteNonQueryAsync(ct);
        }
        catch(PostgresException ex) when(ex.SqlState=="23505")
        {
            return Conflict(new { error="LICENSE_ALREADY_EXISTS" });
        }

        return Ok(new { id, licenseNumber=number, activationKey, activationKeyDisplay="ONE_TIME_ONLY", type=type.ToString(), status=status.ToString() });
    }

    [HttpPut("{id:guid}/status")]
    public async Task<IActionResult> SetStatus(Guid id,[FromBody] SetStatusRequest request,CancellationToken ct)
    {
        if(!Enum.TryParse<LicenseStatus>(request.Status,true,out var status))
            return BadRequest(new { error="INVALID_LICENSE_STATUS" });
        await using var cmd=_db.CreateCommand("UPDATE licenses SET status=@s,updated_at_utc=NOW() WHERE id=@id;");
        cmd.Parameters.AddWithValue("s",status.ToString());
        cmd.Parameters.AddWithValue("id",id);
        return await cmd.ExecuteNonQueryAsync(ct)==0 ? NotFound() : NoContent();
    }

    [HttpGet("{licenseId:guid}/entitlements")]
    public async Task<IActionResult> Entitlements(Guid licenseId,CancellationToken ct)
    {
        const string sql =
            "SELECT le.id,le.feature_id,f.feature_code,f.name,le.enabled,le.limit_value " +
            "FROM license_entitlements le JOIN features f ON f.id=le.feature_id " +
            "WHERE le.license_id=@id ORDER BY f.feature_code;";
        var rows=new List<object>();
        await using var cmd=_db.CreateCommand(sql);
        cmd.Parameters.AddWithValue("id",licenseId);
        await using var r=await cmd.ExecuteReaderAsync(ct);
        while(await r.ReadAsync(ct))
            rows.Add(new { id=r.GetGuid(0), featureId=r.GetGuid(1), featureCode=r.GetString(2),
                featureName=r.GetString(3), enabled=r.GetBoolean(4), limitValue=r.IsDBNull(5)?(int?)null:r.GetInt32(5) });
        return Ok(rows);
    }

    [HttpPut("{licenseId:guid}/entitlements/{featureId:guid}")]
    public async Task<IActionResult> SetEntitlement(Guid licenseId,Guid featureId,[FromBody] SetEntitlementRequest request,CancellationToken ct)
    {
        if(request.LimitValue.HasValue && request.LimitValue.Value<0)
            return BadRequest(new { error="INVALID_ENTITLEMENT_LIMIT" });

        await using(var check=_db.CreateCommand(
            "SELECT count(*) FROM licenses l JOIN features f ON f.product_id=l.product_id WHERE l.id=@l AND f.id=@f;"))
        {
            check.Parameters.AddWithValue("l",licenseId);
            check.Parameters.AddWithValue("f",featureId);
            if(Convert.ToInt64(await check.ExecuteScalarAsync(ct))!=1)
                return BadRequest(new { error="FEATURE_NOT_VALID_FOR_LICENSE_PRODUCT" });
        }

        const string sql =
            "INSERT INTO license_entitlements(id,license_id,feature_id,enabled,limit_value,created_at_utc,updated_at_utc) " +
            "VALUES(@id,@l,@f,@e,@v,NOW(),NOW()) " +
            "ON CONFLICT(license_id,feature_id) DO UPDATE SET enabled=EXCLUDED.enabled,limit_value=EXCLUDED.limit_value,updated_at_utc=NOW();";
        await using var cmd=_db.CreateCommand(sql);
        cmd.Parameters.AddWithValue("id",Guid.NewGuid());
        cmd.Parameters.AddWithValue("l",licenseId);
        cmd.Parameters.AddWithValue("f",featureId);
        cmd.Parameters.AddWithValue("e",request.Enabled);
        cmd.Parameters.Add(new NpgsqlParameter("v",NpgsqlDbType.Integer){Value=(object?)request.LimitValue??DBNull.Value});
        await cmd.ExecuteNonQueryAsync(ct);
        return NoContent();
    }

    private static string GenerateActivationKey()
    {
        var bytes=RandomNumberGenerator.GetBytes(32);
        var token=Convert.ToBase64String(bytes).TrimEnd('=').Replace('+','-').Replace('/','_');
        return $"QFLM-AK-{token}";
    }

    private static string HashActivationKey(string key)
    {
        var hash=SHA256.HashData(Encoding.UTF8.GetBytes(key.Trim()));
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    public sealed record CreateLicenseRequest
    {
        public required string LicenseNumber { get; init; }
        public required Guid CustomerId { get; init; }
        public required Guid ProductId { get; init; }
        public Guid? SubscriptionId { get; init; }
        public required string Type { get; init; }
        public required string Status { get; init; }
        public DateTime? ValidFromUtc { get; init; }
        public DateTime? ValidUntilUtc { get; init; }
        public required int GracePeriodDays { get; init; }
        public required int MaximumInstallations { get; init; }
    }
    public sealed record SetStatusRequest { public required string Status { get; init; } }
    public sealed record SetEntitlementRequest { public required bool Enabled { get; init; } public int? LimitValue { get; init; } }
}
CS
printf '%s\n' "license_entitlement_management_api=CREATED"

printf '\n=== 6. ADD GUI ===\n'
cat > "$GUI/src/pages/LicensesPage.tsx" <<'TSX'
import { FormEvent, useEffect, useState } from "react";
import { apiFetch } from "../lib/api";

type Customer={id:string;customerNumber:string;name:string;isActive:boolean};
type Product={id:string;productCode:string;name:string;isActive:boolean};
type Feature={id:string;featureCode:string;name:string;isActive:boolean};
type Subscription={id:string;customerId:string;customerNumber:string;productId:string;productCode:string;status:string;maximumInstallations:number};
type License={id:string;licenseNumber:string;customerId:string;customerNumber:string;productId:string;productCode:string;type:string;status:string;entitlementCount:number};
type Entitlement={id:string;featureId:string;featureCode:string;enabled:boolean;limitValue:number|null};

export function LicensesPage(){
  const [customers,setCustomers]=useState<Customer[]>([]);
  const [products,setProducts]=useState<Product[]>([]);
  const [subscriptions,setSubscriptions]=useState<Subscription[]>([]);
  const [licenses,setLicenses]=useState<License[]>([]);
  const [features,setFeatures]=useState<Feature[]>([]);
  const [entitlements,setEntitlements]=useState<Entitlement[]>([]);
  const [selected,setSelected]=useState<License|null>(null);
  const [oneTimeKey,setOneTimeKey]=useState("");
  const [error,setError]=useState("");

  const [sc,setSc]=useState(""); const [sp,setSp]=useState("");
  const [ss,setSs]=useState(""); const [se,setSe]=useState(""); const [sm,setSm]=useState("1");
  const [ln,setLn]=useState(""); const [lc,setLc]=useState(""); const [lp,setLp]=useState("");
  const [ls,setLs]=useState(""); const [lt,setLt]=useState("Monthly");
  const [lvf,setLvf]=useState(""); const [lvu,setLvu]=useState(""); const [lg,setLg]=useState("7"); const [lm,setLm]=useState("1");
  const [fid,setFid]=useState(""); const [limit,setLimit]=useState("");

  async function load(){
    const [c,p,s,l]=await Promise.all([
      apiFetch<Customer[]>("/v1/admin/customers"),
      apiFetch<Product[]>("/v1/admin/products"),
      apiFetch<Subscription[]>("/v1/admin/subscriptions"),
      apiFetch<License[]>("/v1/admin/licenses")
    ]);
    setCustomers(c.filter(x=>x.isActive)); setProducts(p.filter(x=>x.isActive)); setSubscriptions(s); setLicenses(l);
  }
  useEffect(()=>{load().catch(()=>setError("License data could not be loaded."));},[]);

  async function createSub(e:FormEvent){
    e.preventDefault();
    await apiFetch("/v1/admin/subscriptions",{method:"POST",body:JSON.stringify({
      customerId:sc,productId:sp,status:"Active",startsAtUtc:new Date(ss).toISOString(),
      endsAtUtc:se?new Date(se).toISOString():null,maximumInstallations:Number(sm)
    })}); await load();
  }

  async function createLicense(e:FormEvent){
    e.preventDefault();
    const r=await apiFetch<{activationKey:string}>("/v1/admin/licenses",{method:"POST",body:JSON.stringify({
      licenseNumber:ln,customerId:lc,productId:lp,subscriptionId:ls||null,type:lt,status:"Active",
      validFromUtc:lvf?new Date(lvf).toISOString():null,validUntilUtc:lvu?new Date(lvu).toISOString():null,
      gracePeriodDays:Number(lg),maximumInstallations:Number(lm)
    })});
    setOneTimeKey(r.activationKey); await load();
  }

  async function choose(x:License){
    setSelected(x);
    const [f,e]=await Promise.all([
      apiFetch<Feature[]>(`/v1/admin/products/${x.productId}/features`),
      apiFetch<Entitlement[]>(`/v1/admin/licenses/${x.id}/entitlements`)
    ]);
    setFeatures(f.filter(y=>y.isActive)); setEntitlements(e);
  }

  async function entitlement(e:FormEvent){
    e.preventDefault(); if(!selected||!fid)return;
    await apiFetch(`/v1/admin/licenses/${selected.id}/entitlements/${fid}`,{
      method:"PUT",body:JSON.stringify({enabled:true,limitValue:limit?Number(limit):null})
    });
    await choose(selected);
  }

  return <>
    <div className="page-heading"><div><h1>Subscriptions & Licenses</h1><p>Manage subscription terms, activation credentials and feature entitlements.</p></div></div>
    {error&&<div className="page-error">{error}</div>}
    {oneTimeKey&&<div className="credential-banner"><strong>Activation key — copy now</strong><code>{oneTimeKey}</code><small>Plaintext is returned only at creation. The database stores only its SHA-256 hash.</small></div>}

    <div className="management-grid">
      <article className="panel"><h2>Create subscription</h2><form className="management-form" onSubmit={createSub}>
        <label>Customer<select value={sc} onChange={e=>setSc(e.target.value)} required><option value="">Select customer</option>{customers.map(x=><option key={x.id} value={x.id}>{x.customerNumber} — {x.name}</option>)}</select></label>
        <label>Product<select value={sp} onChange={e=>setSp(e.target.value)} required><option value="">Select product</option>{products.map(x=><option key={x.id} value={x.id}>{x.productCode} — {x.name}</option>)}</select></label>
        <label>Starts<input type="datetime-local" value={ss} onChange={e=>setSs(e.target.value)} required/></label>
        <label>Ends<input type="datetime-local" value={se} onChange={e=>setSe(e.target.value)}/></label>
        <label>Maximum installations<input type="number" min="1" value={sm} onChange={e=>setSm(e.target.value)} required/></label>
        <button className="primary-button" type="submit">Create subscription</button>
      </form></article>
      <article className="panel"><h2>Subscriptions</h2><div className="table-wrap"><table><thead><tr><th>Customer</th><th>Product</th><th>Status</th><th>Max installs</th></tr></thead><tbody>
        {subscriptions.map(x=><tr key={x.id}><td>{x.customerNumber}</td><td>{x.productCode}</td><td>{x.status}</td><td>{x.maximumInstallations}</td></tr>)}
      </tbody></table></div></article>
    </div>

    <div className="management-grid">
      <article className="panel"><h2>Create license</h2><form className="management-form" onSubmit={createLicense}>
        <label>License number<input value={ln} onChange={e=>setLn(e.target.value.toUpperCase())} required/></label>
        <label>Customer<select value={lc} onChange={e=>setLc(e.target.value)} required><option value="">Select customer</option>{customers.map(x=><option key={x.id} value={x.id}>{x.customerNumber} — {x.name}</option>)}</select></label>
        <label>Product<select value={lp} onChange={e=>setLp(e.target.value)} required><option value="">Select product</option>{products.map(x=><option key={x.id} value={x.id}>{x.productCode} — {x.name}</option>)}</select></label>
        <label>Subscription<select value={ls} onChange={e=>setLs(e.target.value)}><option value="">No subscription</option>{subscriptions.filter(x=>(!lc||x.customerId===lc)&&(!lp||x.productId===lp)).map(x=><option key={x.id} value={x.id}>{x.customerNumber} / {x.productCode} / {x.status}</option>)}</select></label>
        <label>Type<select value={lt} onChange={e=>setLt(e.target.value)}><option>Trial</option><option>Monthly</option><option>Annual</option><option>Perpetual</option></select></label>
        <label>Valid from<input type="datetime-local" value={lvf} onChange={e=>setLvf(e.target.value)}/></label>
        <label>Valid until<input type="datetime-local" value={lvu} onChange={e=>setLvu(e.target.value)}/></label>
        <label>Grace days<input type="number" min="0" value={lg} onChange={e=>setLg(e.target.value)}/></label>
        <label>Maximum installations<input type="number" min="1" value={lm} onChange={e=>setLm(e.target.value)}/></label>
        <button className="primary-button" type="submit">Create license</button>
      </form></article>
      <article className="panel"><h2>Licenses</h2><div className="table-wrap"><table><thead><tr><th>License</th><th>Customer</th><th>Product</th><th>Type</th><th>Status</th><th>Entitlements</th></tr></thead><tbody>
        {licenses.map(x=><tr key={x.id}><td><button className="text-button" onClick={()=>choose(x)}>{x.licenseNumber}</button></td><td>{x.customerNumber}</td><td>{x.productCode}</td><td>{x.type}</td><td>{x.status}</td><td>{x.entitlementCount}</td></tr>)}
      </tbody></table></div></article>
    </div>

    <article className="panel feature-panel"><h2>Entitlements{selected?` — ${selected.licenseNumber}`:""}</h2>
      {!selected?<div className="empty-state">Select a license to manage its entitlements.</div>:
      <div className="feature-layout"><form className="management-form" onSubmit={entitlement}>
        <label>Feature<select value={fid} onChange={e=>setFid(e.target.value)} required><option value="">Select feature</option>{features.map(x=><option key={x.id} value={x.id}>{x.featureCode} — {x.name}</option>)}</select></label>
        <label>Limit value<input type="number" min="0" value={limit} onChange={e=>setLimit(e.target.value)}/></label>
        <button className="primary-button" type="submit">Enable entitlement</button>
      </form>
      <div className="table-wrap"><table><thead><tr><th>Feature</th><th>Enabled</th><th>Limit</th></tr></thead><tbody>
        {entitlements.map(x=><tr key={x.id}><td>{x.featureCode}</td><td>{x.enabled?"Yes":"No"}</td><td>{x.limitValue??"—"}</td></tr>)}
      </tbody></table></div></div>}
    </article>
  </>;
}
TSX

cat > "$GUI/src/App.tsx" <<'TSX'
import {
  BrowserRouter,
  Route,
  Routes
} from "react-router-dom";
import { AuthProvider } from "./auth/AuthContext";
import { ProtectedRoute } from "./auth/ProtectedRoute";
import { AppShell } from "./components/AppShell";
import { DashboardPage } from "./pages/DashboardPage";
import { CustomersPage } from "./pages/CustomersPage";
import { ProductsPage } from "./pages/ProductsPage";
import { LicensesPage } from "./pages/LicensesPage";
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

            <Route
              path="installations"
              element={
                <PlaceholderPage
                  title="Installations"
                  description="Activated machines, leases and device status."
                />
              }
            />

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

.credential-banner {
  display:grid;
  gap:7px;
  margin-bottom:18px;
  padding:16px 18px;
  border:1px solid #fde68a;
  background:#fffbeb;
  border-radius:12px;
  color:#78350f;
}
.credential-banner code {
  display:block;
  overflow-wrap:anywhere;
  background:#fff;
  border:1px solid #fde68a;
  border-radius:8px;
  padding:10px;
  user-select:all;
}
CSS

printf '%s\n' "subscriptions_licenses_entitlements_gui=CREATED"

printf '\n=== 6B. NULLABLE PROJECTION DIAGNOSTIC ===\n'

for pattern in \
  'endsAtUtc=r.IsDBNull(9)?(DateTime?)null:r.GetDateTime(9)' \
  'subscriptionId=r.IsDBNull(8)?(Guid?)null:r.GetGuid(8)' \
  'validFromUtc=r.IsDBNull(11)?(DateTime?)null:r.GetDateTime(11)' \
  'validUntilUtc=r.IsDBNull(12)?(DateTime?)null:r.GetDateTime(12)' \
  'limitValue=r.IsDBNull(5)?(int?)null:r.GetInt32(5)'
do
    grep -Fq "$pattern" \
      "$API_SRC/Controllers/AdminSubscriptionsController.cs" \
      "$API_SRC/Controllers/AdminLicensesController.cs" \
      || die "nullable projection fix missing: $pattern"
done

printf '%s\n' "nullable_projection_fix=PASS"

printf '\n=== 6C. GUI ROUTE SOURCE DIAGNOSTIC ===\n'

grep -Fq 'import { LicensesPage } from "./pages/LicensesPage";' "$GUI/src/App.tsx" \
  || die "LicensesPage import missing"

grep -Fq 'path="licenses"' "$GUI/src/App.tsx" \
  || die "licenses route missing"

grep -Fq 'element={<LicensesPage />}' "$GUI/src/App.tsx" \
  || die "LicensesPage route target missing"

grep -Fq '</Routes>' "$GUI/src/App.tsx" \
  || die "Routes closing tag missing"

grep -Fq '</BrowserRouter>' "$GUI/src/App.tsx" \
  || die "BrowserRouter closing tag missing"

printf '%s\n' "gui_route_source=PASS"

printf '\n=== 7. RELEASE BUILD ===\n'
dotnet build QuikeFix.LicenseManager.slnx -c Release || die "release build failed"
printf '%s\n' "release_build=PASS"

printf '\n=== 8. CLONE PRODUCTION DATABASE ===\n'
docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" >/dev/null
docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB"
docker exec "$PG" createdb -U qflm "$ISO_DB" || die "isolated DB create failed"
docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null || die "isolated DB clone failed"
printf '%s\n' "isolated_database_clone=PASS"

printf '\n=== 9. BUILD ISOLATED API IMAGE ===\n'
rm -rf "$API_PUBLISH"
dotnet publish "$API_SRC/QFLM.Api.csproj" -c Release -o "$API_PUBLISH" || die "API publish failed"
cat > "$API_DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-recovery7d2/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER
docker build -f "$API_DOCKERFILE" -t "$API_IMAGE" . || die "API image build failed"
printf 'api_candidate_image=%s\n' "$API_IMAGE"

printf '\n=== 10. PREPARE + START ISOLATED API ===\n'
docker inspect "$PROD_API" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$ENV_FILE" || die "environment capture failed"
chmod 600 "$ENV_FILE"
cat >> "$ENV_FILE" <<EOF
Qflm__PostgreSqlDatabase=$ISO_DB
PostgreSqlDatabase=$ISO_DB
EOF
chmod 600 "$ENV_FILE"

docker rm -f "$ISO_API" >/dev/null 2>&1 || true
docker run -d --name "$ISO_API" --network "$NET" --network-alias qflm-api-backend --env-file "$ENV_FILE" --volumes-from "$PROD_API:ro" --read-only --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp:rw,noexec,nosuid,size=16m "$API_IMAGE" >/dev/null || die "isolated API start failed"
sleep 5
docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS "http://$ISO_API:8080/health/ready" >/dev/null || { docker logs --tail 160 "$ISO_API" || true; die "isolated API readiness failed"; }
printf '%s\n' "isolated_api_health=PASS"
ISO_DB_ENV=$(docker inspect "$ISO_API" --format='{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1=="Qflm__PostgreSqlDatabase"{print $2}' | tail -n1)
printf 'isolated_api_database=%s\n' "$ISO_DB_ENV"
[ "$ISO_DB_ENV" = "$ISO_DB" ] || die "isolated API is not bound to isolated database"
printf '%s\n' "isolated_database_binding=PASS"

printf '\n=== 11. BUILD + START ISOLATED GUI ===\n'
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
' sendfile on;' \
' client_body_temp_path /tmp/client_temp;' \
' proxy_temp_path /tmp/proxy_temp;' \
' fastcgi_temp_path /tmp/fastcgi_temp;' \
' uwsgi_temp_path /tmp/uwsgi_temp;' \
' scgi_temp_path /tmp/scgi_temp;' \
' server {' \
'  listen 8080;' \
'  server_name _;' \
'  root /usr/share/nginx/html;' \
'  index index.html;' \
'  location /api/ {' \
'   proxy_pass http://qflm-api-backend:8080/api/;' \
'   proxy_http_version 1.1;' \
'   proxy_set_header Host $host;' \
'  }' \
'  location / { try_files $uri $uri/ /index.html; }' \
'  location = /health { access_log off; default_type text/plain; return 200 "ok\n"; }' \
' }' \
'}' > /etc/nginx/nginx-qflm.conf
RUN mkdir -p /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp && chown -R nginx:nginx /tmp /usr/share/nginx/html
USER nginx
EXPOSE 8080
ENTRYPOINT ["nginx","-c","/etc/nginx/nginx-qflm.conf","-g","daemon off;"]
DOCKER
docker build -f "$GUI_DOCKERFILE" -t "$GUI_IMAGE" . || die "GUI image build failed"
docker rm -f "$ISO_GUI" >/dev/null 2>&1 || true
docker run -d --name "$ISO_GUI" --network "$NET" --read-only --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp:rw,noexec,nosuid,size=24m,uid=101,gid=101 "$GUI_IMAGE" >/dev/null || die "isolated GUI start failed"
sleep 3
[ "$(docker inspect "$ISO_GUI" --format='{{.State.Running}}')" = true ] || die "isolated GUI not running"
printf '%s\n' "isolated_gui_running=PASS"

printf '\n=== 12. ADMIN LOGIN THROUGH GUI PROXY ===\n'
ADMIN_USER="$(cat "$ADMIN_USER_FILE")"
ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"
LOGIN_JSON=$(python3 - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)
LOGIN_RESPONSE=$(printf '%s' "$LOGIN_JSON" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -fsS -H 'Content-Type: application/json' -X POST "http://$ISO_GUI:8080/api/v1/auth/login" --data-binary @-) || die "admin login failed"
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
printf '%s\n' "gui_admin_login=PASS"

api_fail(){
  printf '%s\n' "--- isolated API logs ---"
  docker logs --tail 200 "$ISO_API" || true
  printf '%s\n' "--- isolated GUI logs ---"
  docker logs --tail 100 "$ISO_GUI" || true
  die "$1"
}

printf '\n=== 13. CREATE ISOLATED SUBSCRIPTION ===\n'
CUSTOMER_ID=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT id FROM customers WHERE is_active=true ORDER BY created_at_utc LIMIT 1;" | xargs)
PRODUCT_ID=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT id FROM products WHERE is_active=true ORDER BY created_at_utc LIMIT 1;" | xargs)
PRODUCT_CODE=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT product_code FROM products WHERE id='$PRODUCT_ID';" | xargs)
FEATURE_ID=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT id FROM features WHERE product_id='$PRODUCT_ID' AND is_active=true ORDER BY created_at_utc LIMIT 1;" | xargs)
START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
END_UTC="$(date -u -d '+30 days' +%Y-%m-%dT%H:%M:%SZ)"
SUB_PAYLOAD=$(python3 - "$CUSTOMER_ID" "$PRODUCT_ID" "$START_UTC" "$END_UTC" <<'PY'
import json,sys
print(json.dumps({"customerId":sys.argv[1],"productId":sys.argv[2],"status":"Active","startsAtUtc":sys.argv[3],"endsAtUtc":sys.argv[4],"maximumInstallations":3}))
PY
)
SUB_RESPONSE=$(printf '%s' "$SUB_PAYLOAD" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -fsS -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -X POST "http://$ISO_GUI:8080/api/v1/admin/subscriptions" --data-binary @-) || api_fail "subscription create failed"
SUB_ID=$(python3 - "$SUB_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["id"])
PY
)
printf 'subscription_create=PASS id=%s\n' "$SUB_ID"

printf '\n=== 14. CREATE ISOLATED LICENSE ===\n'
LICENSE_NUMBER="PH16D-$(date -u +%Y%m%d%H%M%S)"
LICENSE_PAYLOAD=$(python3 - "$LICENSE_NUMBER" "$CUSTOMER_ID" "$PRODUCT_ID" "$SUB_ID" "$START_UTC" "$END_UTC" <<'PY'
import json,sys
print(json.dumps({"licenseNumber":sys.argv[1],"customerId":sys.argv[2],"productId":sys.argv[3],"subscriptionId":sys.argv[4],"type":"Monthly","status":"Active","validFromUtc":sys.argv[5],"validUntilUtc":sys.argv[6],"gracePeriodDays":7,"maximumInstallations":3}))
PY
)
LICENSE_RESPONSE=$(printf '%s' "$LICENSE_PAYLOAD" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -fsS -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -X POST "http://$ISO_GUI:8080/api/v1/admin/licenses" --data-binary @-) || api_fail "license create failed"
LICENSE_ID=$(python3 - "$LICENSE_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["id"])
PY
)
ACTIVATION_KEY=$(python3 - "$LICENSE_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["activationKey"])
PY
)
HASH_LENGTH=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT length(activation_key_hash) FROM licenses WHERE id='$LICENSE_ID';" | xargs)
[ "$HASH_LENGTH" = 64 ] || die "activation key hash invalid"
printf 'license_create=PASS id=%s activation_key_plaintext_logged=NO hash_length=%s\n' "$LICENSE_ID" "$HASH_LENGTH"

printf '\n=== 15. END-TO-END ACTIVATION KEY TEST ===\n'
INSTALL_ID="33333333-3333-4333-8333-333333333333"
FINGERPRINT="QFLM-PHASE16D2-ISOLATED-FINGERPRINT"
ACTIVATE_PAYLOAD=$(python3 - "$ACTIVATION_KEY" "$PRODUCT_CODE" "$INSTALL_ID" "$FINGERPRINT" <<'PY'
import json,sys
print(json.dumps({"licenseKey":sys.argv[1],"productCode":sys.argv[2],"installationId":sys.argv[3],"machineFingerprint":sys.argv[4]}))
PY
)
ACTIVATE_RESPONSE=$(printf '%s' "$ACTIVATE_PAYLOAD" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -fsS -H 'Content-Type: application/json' -X POST "http://$ISO_GUI:8080/api/v1/activate" --data-binary @-) || api_fail "activation request failed"
ACTIVATE_SUCCESS=$(python3 - "$ACTIVATE_RESPONSE" <<'PY'
import json,sys
print(str(bool(json.loads(sys.argv[1]).get("success"))).lower())
PY
)
[ "$ACTIVATE_SUCCESS" = true ] || die "activation key compatibility failed"
printf '%s\n' "activation_key_end_to_end=PASS"

printf '\n=== 16. ENTITLEMENT UPSERT TEST ===\n'
ENT_HTTP=$(printf '%s' '{"enabled":true,"limitValue":50}' | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -X PUT "http://$ISO_GUI:8080/api/v1/admin/licenses/$LICENSE_ID/entitlements/$FEATURE_ID" --data-binary @-)
[ "$ENT_HTTP" = 204 ] || die "entitlement upsert failed"
ENT_COUNT=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc "SELECT count(*) FROM license_entitlements WHERE license_id='$LICENSE_ID' AND feature_id='$FEATURE_ID' AND enabled=true AND limit_value=50;" | xargs)
[ "$ENT_COUNT" = 1 ] || die "entitlement persistence failed"
printf '%s\n' "entitlement_management=PASS"

printf '\n=== 17. STATUS MANAGEMENT TEST ===\n'
SUB_HTTP=$(printf '%s' '{"status":"Suspended"}' | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -X PUT "http://$ISO_GUI:8080/api/v1/admin/subscriptions/$SUB_ID/status" --data-binary @-)
LIC_HTTP=$(printf '%s' '{"status":"Suspended"}' | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -X PUT "http://$ISO_GUI:8080/api/v1/admin/licenses/$LICENSE_ID/status" --data-binary @-)
[ "$SUB_HTTP" = 204 ] || die "subscription status failed"
[ "$LIC_HTTP" = 204 ] || die "license status failed"
printf '%s\n' "status_management=PASS"

printf '\n=== 18. GUI ROUTE TEST ===\n'
GUI_HTTP=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' "http://$ISO_GUI:8080/licenses")
[ "$GUI_HTTP" = 200 ] || die "licenses GUI route failed"
printf 'licenses_http=%s\n' "$GUI_HTTP"
printf '%s\n' "licenses_gui_route=PASS"

printf '\n=== 19. ISOLATED PERSISTENCE VERIFICATION ===\n'
ISO_SUBS=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM subscriptions;' | xargs)
ISO_LICS=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
ISO_ENTS=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM license_entitlements;' | xargs)
ISO_INSTALLS=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
[ "$ISO_SUBS" -eq $((SUBS+1)) ] || die "isolated subscriptions mismatch"
[ "$ISO_LICS" -eq $((LICS+1)) ] || die "isolated licenses mismatch"
[ "$ISO_ENTS" -eq $((ENTS+1)) ] || die "isolated entitlements mismatch"
[ "$ISO_INSTALLS" -eq $((INSTALLS+1)) ] || die "isolated installations mismatch"
printf 'isolated_subscriptions=%s isolated_licenses=%s isolated_entitlements=%s isolated_installations=%s\n' "$ISO_SUBS" "$ISO_LICS" "$ISO_ENTS" "$ISO_INSTALLS"
printf '%s\n' "isolated_persistence=PASS"

printf '\n=== 20. REVOKE TEST SESSION ===\n'
REVOKE_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)
REVOKE_HTTP=$(printf '%s' "$REVOKE_JSON" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -X POST "http://$ISO_GUI:8080/api/v1/auth/revoke" --data-binary @-)
[ "$REVOKE_HTTP" = 204 ] || die "session revoke failed"
printf '%s\n' "test_session_revoked=PASS"
unset TOKEN REFRESH ADMIN_PASS ACTIVATION_KEY LOGIN_JSON LOGIN_RESPONSE LICENSE_RESPONSE ACTIVATE_RESPONSE

printf '\n=== 21. PRODUCTION FINAL SAFETY ===\n'
FINAL_IMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_SUBS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM subscriptions;' | xargs)
FINAL_LICS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_ENTS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM license_entitlements;' | xargs)
FINAL_INSTALLS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
[ "$FINAL_IMG" = "$IMG" ] || die "production image changed"
[ "$FINAL_RUN" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "production migrations changed"
[ "$FINAL_SUBS" = "$SUBS" ] || die "production subscriptions changed"
[ "$FINAL_LICS" = "$LICS" ] || die "production licenses changed"
[ "$FINAL_ENTS" = "$ENTS" ] || die "production entitlements changed"
[ "$FINAL_INSTALLS" = "$INSTALLS" ] || die "production installations changed"
printf '%s\n' "production_unchanged=PASS"

COMPLETED=1
printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7D2 PASSED"
printf '%s\n' "======================================================"
printf '%s\n' "SUBSCRIPTION LIST/CREATE API:        PASS"
printf '%s\n' "SUBSCRIPTION STATUS API:             PASS"
printf '%s\n' "LICENSE LIST/CREATE API:             PASS"
printf '%s\n' "LICENSE STATUS API:                  PASS"
printf '%s\n' "ACTIVATION KEY DB STORAGE:           SHA256 ONLY"
printf '%s\n' "ACTIVATION KEY END-TO-END:           PASS"
printf '%s\n' "PLAINTEXT ACTIVATION KEY LOGGED:     NO"
printf '%s\n' "ENTITLEMENT UPSERT API:              PASS"
printf '%s\n' "SUBSCRIPTIONS / LICENSES GUI:        PASS"
printf '%s\n' "PRODUCTION API/DB:                   UNCHANGED"
printf 'REPORT:                              %s\n' "$REPORT"
printf '%s\n' "NEXT: RECOVERY 7E - INSTALLATIONS + LICENSE ADMIN ACTIONS GUI/API"
printf '%s\n' "======================================================"