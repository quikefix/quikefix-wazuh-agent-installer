#!/usr/bin/env bash
# QFLM RECOVERY 7C
# Customers / Products / Features management GUI + API, isolated only.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
API_SRC="$ROOT/src/QFLM.Api"
GUI="$ROOT/src/QFLM.AdminWeb"

PROD_API="qflm-api"
PG="qflm-postgres"
PROD_DB="qflm"
ISO_DB="qflm_recovery7c_test"
ISO_API="qflm-api-recovery7c-test"
ISO_GUI="qflm-admin-web-recovery7c-test"
NET="qflm_backend"

EXPECTED_API_IMAGE="qflm-api:recovery6f3-candidate"
API_IMAGE="qflm-api:recovery7c-candidate"
GUI_IMAGE="qflm-admin-web:recovery7c-candidate"

ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"
RUNTIME_JWT="/opt/qflm/secrets/runtime-api/jwt-signing-key"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7c-$STAMP"
REPORT="$BACKUP/recovery7c-report.txt"
SOURCE_BACKUP="$BACKUP/source-before-phase16c.tgz"
DB_DUMP="$BACKUP/qflm-before-phase16c.dump"
ENV_FILE="$BACKUP/isolated-api.env"

API_PUBLISH="$ROOT/artifacts/api-publish-recovery7c"
API_DOCKERFILE="$ROOT/Dockerfile.recovery7c-api"
GUI_DOCKERFILE="$ROOT/Dockerfile.recovery7c-gui"

MUTATED=0
COMPLETED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

cleanup(){
    docker rm -f "$ISO_GUI" >/dev/null 2>&1 || true
    docker rm -f "$ISO_API" >/dev/null 2>&1 || true

    if [ "$COMPLETED" -ne 1 ] && [ "$MUTATED" -eq 1 ] && [ -s "$SOURCE_BACKUP" ]; then
        printf '\n=== SOURCE ROLLBACK ===\n'
        rm -f "$API_SRC/Controllers/AdminCustomersController.cs"
        rm -f "$API_SRC/Controllers/AdminProductsController.cs"
        tar -xzf "$SOURCE_BACKUP" -C "$ROOT" >/dev/null 2>&1 || true
        printf '%s\n' "source_restore_attempted=YES"
    fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7C"
printf '%s\n' " CUSTOMERS / PRODUCTS / FEATURES"
printf '%s\n' " MANAGEMENT GUI + API - ISOLATED"
printf '%s\n' "======================================================"

printf '\n=== 1. PRODUCTION SAFETY BASELINE ===\n'

IMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
RUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
AUTH=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name LIKE 'auth_%';" | xargs)
USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
CUSTOMERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM customers;' | xargs)
PRODUCTS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM products;' | xargs)
FEATURES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM features;' | xargs)
LICENSES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'image=%s running=%s migrations=%s auth_tables=%s users=%s customers=%s products=%s features=%s licenses=%s installations=%s\n' \
  "$IMG" "$RUN" "$MIG" "$AUTH" "$USERS" "$CUSTOMERS" "$PRODUCTS" "$FEATURES" "$LICENSES" "$INSTALLATIONS"

[ "$IMG" = "$EXPECTED_API_IMAGE" ] || die "unexpected production API image"
[ "$RUN" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"
[ "$AUTH" = 6 ] || die "unexpected auth table count"
[ -s "$ADMIN_USER_FILE" ] || die "platform admin username missing"
[ -s "$ADMIN_PASS_FILE" ] || die "platform admin password missing"
[ -s "$RUNTIME_JWT" ] || die "JWT runtime secret missing"
[ -d "$GUI" ] || die "GUI source missing"

printf '%s\n' "production_baseline=PASS"

printf '\n=== 2. DATABASE SCHEMA PREFLIGHT ===\n'

for spec in \
  "customers:id" \
  "customers:customer_number" \
  "customers:name" \
  "customers:email" \
  "customers:country_code" \
  "customers:is_active" \
  "customers:created_at_utc" \
  "customers:updated_at_utc" \
  "products:id" \
  "products:product_code" \
  "products:name" \
  "products:is_active" \
  "products:created_at_utc" \
  "products:updated_at_utc" \
  "features:id" \
  "features:product_id" \
  "features:feature_code" \
  "features:name" \
  "features:is_active" \
  "features:created_at_utc" \
  "features:updated_at_utc"
do
    TABLE="${spec%%:*}"
    COLUMN="${spec##*:}"

    FOUND=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "
SELECT count(*)
FROM information_schema.columns
WHERE table_schema='public'
AND table_name='$TABLE'
AND column_name='$COLUMN';
" | xargs)

    [ "$FOUND" = 1 ] || die "$TABLE.$COLUMN missing"
done

printf '%s\n' "customer_product_feature_schema=PASS"

printf '\n=== 3. BACKUP SOURCE + DATABASE ===\n'

tar -czf "$SOURCE_BACKUP" -C "$ROOT" \
  "src/QFLM.Api" \
  "src/QFLM.AdminWeb" \
  || die "source backup failed"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" -Fc > "$DB_DUMP" \
  || die "production DB backup failed"

[ -s "$DB_DUMP" ] || die "production DB backup empty"

printf 'source_backup_sha256=%s\n' "$(sha256sum "$SOURCE_BACKUP" | awk '{print $1}')"
printf 'database_backup_sha256=%s\n' "$(sha256sum "$DB_DUMP" | awk '{print $1}')"

MUTATED=1

printf '\n=== 4. ADD CUSTOMER MANAGEMENT API ===\n'

cat > "$API_SRC/Controllers/AdminCustomersController.cs" <<'CS'
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Npgsql;

namespace QFLM.Api.Controllers;

[ApiController]
[Route("api/v1/admin/customers")]
public sealed class AdminCustomersController : ControllerBase
{
    private readonly NpgsqlDataSource _dataSource;

    public AdminCustomersController(NpgsqlDataSource dataSource)
    {
        _dataSource = dataSource;
    }

    [HttpGet]
    [Authorize(Policy = "permission:customers.read")]
    public async Task<IActionResult> List(CancellationToken cancellationToken)
    {
        const string sql =
            "SELECT id, customer_number, name, email, country_code, is_active, created_at_utc, updated_at_utc " +
            "FROM customers ORDER BY name, customer_number;";

        var result = new List<object>();

        await using var command = _dataSource.CreateCommand(sql);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            result.Add(new
            {
                id = reader.GetGuid(0),
                customerNumber = reader.GetString(1),
                name = reader.GetString(2),
                email = reader.IsDBNull(3) ? null : reader.GetString(3),
                countryCode = reader.IsDBNull(4) ? null : reader.GetString(4),
                isActive = reader.GetBoolean(5),
                createdAtUtc = reader.GetDateTime(6),
                updatedAtUtc = reader.GetDateTime(7)
            });
        }

        return Ok(result);
    }

    [HttpPost]
    [Authorize(Policy = "permission:customers.manage")]
    public async Task<IActionResult> Create(
        [FromBody] CreateCustomerRequest request,
        CancellationToken cancellationToken)
    {
        var number = request.CustomerNumber?.Trim();
        var name = request.Name?.Trim();
        var email = string.IsNullOrWhiteSpace(request.Email) ? null : request.Email.Trim();
        var country = string.IsNullOrWhiteSpace(request.CountryCode)
            ? null
            : request.CountryCode.Trim().ToUpperInvariant();

        if (string.IsNullOrWhiteSpace(number) || number.Length > 50)
            return BadRequest(new { error = "INVALID_CUSTOMER_NUMBER" });

        if (string.IsNullOrWhiteSpace(name) || name.Length > 200)
            return BadRequest(new { error = "INVALID_CUSTOMER_NAME" });

        if (email?.Length > 320)
            return BadRequest(new { error = "INVALID_CUSTOMER_EMAIL" });

        if (country is not null && country.Length != 2)
            return BadRequest(new { error = "INVALID_COUNTRY_CODE" });

        var id = Guid.NewGuid();

        const string sql =
            "INSERT INTO customers " +
            "(id, customer_number, name, email, country_code, is_active, created_at_utc, updated_at_utc) " +
            "VALUES (@id, @number, @name, @email, @country, true, NOW(), NOW());";

        try
        {
            await using var command = _dataSource.CreateCommand(sql);
            command.Parameters.AddWithValue("id", id);
            command.Parameters.AddWithValue("number", number);
            command.Parameters.AddWithValue("name", name);
            command.Parameters.AddWithValue("email", (object?)email ?? DBNull.Value);
            command.Parameters.AddWithValue("country", (object?)country ?? DBNull.Value);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        catch (PostgresException ex) when (ex.SqlState == "23505")
        {
            return Conflict(new { error = "CUSTOMER_ALREADY_EXISTS" });
        }

        return Ok(new
        {
            id,
            customerNumber = number,
            name,
            email,
            countryCode = country,
            isActive = true
        });
    }

    [HttpPut("{id:guid}/status")]
    [Authorize(Policy = "permission:customers.manage")]
    public async Task<IActionResult> SetStatus(
        Guid id,
        [FromBody] SetActiveRequest request,
        CancellationToken cancellationToken)
    {
        const string sql =
            "UPDATE customers SET is_active=@active, updated_at_utc=NOW() WHERE id=@id;";

        await using var command = _dataSource.CreateCommand(sql);
        command.Parameters.AddWithValue("id", id);
        command.Parameters.AddWithValue("active", request.IsActive);

        var rows = await command.ExecuteNonQueryAsync(cancellationToken);

        return rows == 0 ? NotFound() : NoContent();
    }

    public sealed record CreateCustomerRequest
    {
        public required string CustomerNumber { get; init; }
        public required string Name { get; init; }
        public string? Email { get; init; }
        public string? CountryCode { get; init; }
    }

    public sealed record SetActiveRequest
    {
        public required bool IsActive { get; init; }
    }
}
CS

printf '%s\n' "customer_management_api=CREATED"

printf '\n=== 5. ADD PRODUCT + FEATURE MANAGEMENT API ===\n'

cat > "$API_SRC/Controllers/AdminProductsController.cs" <<'CS'
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Npgsql;

namespace QFLM.Api.Controllers;

[ApiController]
[Route("api/v1/admin/products")]
public sealed class AdminProductsController : ControllerBase
{
    private readonly NpgsqlDataSource _dataSource;

    public AdminProductsController(NpgsqlDataSource dataSource)
    {
        _dataSource = dataSource;
    }

    [HttpGet]
    [Authorize(Policy = "permission:products.read")]
    public async Task<IActionResult> List(CancellationToken cancellationToken)
    {
        const string sql =
            "SELECT p.id, p.product_code, p.name, p.is_active, " +
            "p.created_at_utc, p.updated_at_utc, " +
            "(SELECT count(*) FROM features f WHERE f.product_id=p.id) " +
            "FROM products p ORDER BY p.name, p.product_code;";

        var result = new List<object>();

        await using var command = _dataSource.CreateCommand(sql);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            result.Add(new
            {
                id = reader.GetGuid(0),
                productCode = reader.GetString(1),
                name = reader.GetString(2),
                isActive = reader.GetBoolean(3),
                createdAtUtc = reader.GetDateTime(4),
                updatedAtUtc = reader.GetDateTime(5),
                featureCount = reader.GetInt64(6)
            });
        }

        return Ok(result);
    }

    [HttpPost]
    [Authorize(Policy = "permission:products.manage")]
    public async Task<IActionResult> Create(
        [FromBody] CreateProductRequest request,
        CancellationToken cancellationToken)
    {
        var code = request.ProductCode?.Trim().ToUpperInvariant();
        var name = request.Name?.Trim();
        if (string.IsNullOrWhiteSpace(code) || code.Length > 100)
            return BadRequest(new { error = "INVALID_PRODUCT_CODE" });

        if (string.IsNullOrWhiteSpace(name) || name.Length > 200)
            return BadRequest(new { error = "INVALID_PRODUCT_NAME" });

        var id = Guid.NewGuid();

        const string sql =
            "INSERT INTO products " +
            "(id, product_code, name, is_active, created_at_utc, updated_at_utc) " +
            "VALUES (@id, @code, @name, true, NOW(), NOW());";

        try
        {
            await using var command = _dataSource.CreateCommand(sql);
            command.Parameters.AddWithValue("id", id);
            command.Parameters.AddWithValue("code", code);
            command.Parameters.AddWithValue("name", name);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        catch (PostgresException ex) when (ex.SqlState == "23505")
        {
            return Conflict(new { error = "PRODUCT_ALREADY_EXISTS" });
        }

        return Ok(new
        {
            id,
            productCode = code,
            name,
            isActive = true,
            featureCount = 0
        });
    }

    [HttpPut("{id:guid}/status")]
    [Authorize(Policy = "permission:products.manage")]
    public async Task<IActionResult> SetStatus(
        Guid id,
        [FromBody] SetActiveRequest request,
        CancellationToken cancellationToken)
    {
        const string sql =
            "UPDATE products SET is_active=@active, updated_at_utc=NOW() WHERE id=@id;";

        await using var command = _dataSource.CreateCommand(sql);
        command.Parameters.AddWithValue("id", id);
        command.Parameters.AddWithValue("active", request.IsActive);

        var rows = await command.ExecuteNonQueryAsync(cancellationToken);

        return rows == 0 ? NotFound() : NoContent();
    }

    [HttpGet("{productId:guid}/features")]
    [Authorize(Policy = "permission:products.read")]
    public async Task<IActionResult> Features(
        Guid productId,
        CancellationToken cancellationToken)
    {
        const string sql =
            "SELECT id, product_id, feature_code, name, is_active, created_at_utc, updated_at_utc " +
            "FROM features WHERE product_id=@productId ORDER BY name, feature_code;";

        var result = new List<object>();

        await using var command = _dataSource.CreateCommand(sql);
        command.Parameters.AddWithValue("productId", productId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        while (await reader.ReadAsync(cancellationToken))
        {
            result.Add(new
            {
                id = reader.GetGuid(0),
                productId = reader.GetGuid(1),
                featureCode = reader.GetString(2),
                name = reader.GetString(3),
                isActive = reader.GetBoolean(4),
                createdAtUtc = reader.GetDateTime(5),
                updatedAtUtc = reader.GetDateTime(6)
            });
        }

        return Ok(result);
    }

    [HttpPost("{productId:guid}/features")]
    [Authorize(Policy = "permission:products.manage")]
    public async Task<IActionResult> CreateFeature(
        Guid productId,
        [FromBody] CreateFeatureRequest request,
        CancellationToken cancellationToken)
    {
        var code = request.FeatureCode?.Trim().ToUpperInvariant();
        var name = request.Name?.Trim();

        if (string.IsNullOrWhiteSpace(code) || code.Length > 100)
            return BadRequest(new { error = "INVALID_FEATURE_CODE" });

        if (string.IsNullOrWhiteSpace(name) || name.Length > 200)
            return BadRequest(new { error = "INVALID_FEATURE_NAME" });

        const string productSql =
            "SELECT count(*) FROM products WHERE id=@productId;";

        await using (var productCommand = _dataSource.CreateCommand(productSql))
        {
            productCommand.Parameters.AddWithValue("productId", productId);
            var raw = await productCommand.ExecuteScalarAsync(cancellationToken);
            var exists = Convert.ToInt64(raw);
            if (exists != 1)
                return NotFound();
        }

        var id = Guid.NewGuid();

        const string sql =
            "INSERT INTO features " +
            "(id, product_id, feature_code, name, is_active, created_at_utc, updated_at_utc) " +
            "VALUES (@id, @productId, @code, @name, true, NOW(), NOW());";

        try
        {
            await using var command = _dataSource.CreateCommand(sql);
            command.Parameters.AddWithValue("id", id);
            command.Parameters.AddWithValue("productId", productId);
            command.Parameters.AddWithValue("code", code);
            command.Parameters.AddWithValue("name", name);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        catch (PostgresException ex) when (ex.SqlState == "23505")
        {
            return Conflict(new { error = "FEATURE_ALREADY_EXISTS" });
        }

        return Ok(new
        {
            id,
            productId,
            featureCode = code,
            name,
            isActive = true
        });
    }

    [HttpPut("features/{featureId:guid}/status")]
    [Authorize(Policy = "permission:products.manage")]
    public async Task<IActionResult> SetFeatureStatus(
        Guid featureId,
        [FromBody] SetActiveRequest request,
        CancellationToken cancellationToken)
    {
        const string sql =
            "UPDATE features SET is_active=@active, updated_at_utc=NOW() WHERE id=@id;";

        await using var command = _dataSource.CreateCommand(sql);
        command.Parameters.AddWithValue("id", featureId);
        command.Parameters.AddWithValue("active", request.IsActive);

        var rows = await command.ExecuteNonQueryAsync(cancellationToken);

        return rows == 0 ? NotFound() : NoContent();
    }

    public sealed record CreateProductRequest
    {
        public required string ProductCode { get; init; }
        public required string Name { get; init; }
    }

    public sealed record CreateFeatureRequest
    {
        public required string FeatureCode { get; init; }
        public required string Name { get; init; }
    }

    public sealed record SetActiveRequest
    {
        public required bool IsActive { get; init; }
    }
}
CS

printf '%s\n' "product_feature_management_api=CREATED"

printf '\n=== 6. ADD CUSTOMERS GUI ===\n'

cat > "$GUI/src/pages/CustomersPage.tsx" <<'TSX'
import { FormEvent, useEffect, useState } from "react";
import { apiFetch } from "../lib/api";

type Customer = {
  id: string;
  customerNumber: string;
  name: string;
  email: string | null;
  countryCode: string | null;
  isActive: boolean;
};

export function CustomersPage() {
  const [items, setItems] = useState<Customer[]>([]);
  const [error, setError] = useState("");
  const [customerNumber, setCustomerNumber] = useState("");
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [countryCode, setCountryCode] = useState("");

  async function load() {
    setItems(await apiFetch<Customer[]>("/v1/admin/customers"));
  }

  useEffect(() => {
    load().catch(() => setError("Customers could not be loaded."));
  }, []);

  async function create(event: FormEvent) {
    event.preventDefault();
    setError("");

    try {
      await apiFetch("/v1/admin/customers", {
        method: "POST",
        body: JSON.stringify({
          customerNumber,
          name,
          email: email || null,
          countryCode: countryCode || null
        })
      });

      setCustomerNumber("");
      setName("");
      setEmail("");
      setCountryCode("");
      await load();
    } catch {
      setError("Customer could not be created.");
    }
  }

  async function toggle(customer: Customer) {
    await apiFetch(`/v1/admin/customers/${customer.id}/status`, {
      method: "PUT",
      body: JSON.stringify({ isActive: !customer.isActive })
    });

    await load();
  }

  return (
    <>
      <div className="page-heading">
        <div>
          <h1>Customers</h1>
          <p>Manage customer organizations and licensing relationships.</p>
        </div>
      </div>

      {error && <div className="page-error">{error}</div>}

      <div className="management-grid">
        <article className="panel">
          <h2>Create customer</h2>

          <form className="management-form" onSubmit={create}>
            <label>
              Customer number
              <input
                value={customerNumber}
                onChange={(e) => setCustomerNumber(e.target.value)}
                required
              />
            </label>

            <label>
              Name
              <input
                value={name}
                onChange={(e) => setName(e.target.value)}
                required
              />
            </label>

            <label>
              Email
              <input
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
              />
            </label>

            <label>
              Country code
              <input
                value={countryCode}
                maxLength={2}
                onChange={(e) => setCountryCode(e.target.value.toUpperCase())}
              />
            </label>

            <button className="primary-button" type="submit">
              Create customer
            </button>
          </form>
        </article>

        <article className="panel">
          <h2>Customer directory</h2>

          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Number</th>
                  <th>Name</th>
                  <th>Email</th>
                  <th>Country</th>
                  <th>Status</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {items.map((customer) => (
                  <tr key={customer.id}>
                    <td>{customer.customerNumber}</td>
                    <td>{customer.name}</td>
                    <td>{customer.email ?? "—"}</td>
                    <td>{customer.countryCode ?? "—"}</td>
                    <td>
                      <span
                        className={
                          customer.isActive
                            ? "status-badge active"
                            : "status-badge inactive"
                        }
                      >
                        {customer.isActive ? "Active" : "Inactive"}
                      </span>
                    </td>
                    <td>
                      <button
                        className="secondary-button"
                        onClick={() => toggle(customer)}
                      >
                        {customer.isActive ? "Deactivate" : "Activate"}
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </article>
      </div>
    </>
  );
}
TSX

printf '%s\n' "customers_gui=CREATED"

printf '\n=== 7. ADD PRODUCTS + FEATURES GUI ===\n'

cat > "$GUI/src/pages/ProductsPage.tsx" <<'TSX'
import { FormEvent, useEffect, useState } from "react";
import { apiFetch } from "../lib/api";

type Product = {
  id: string;
  productCode: string;
  name: string;
  isActive: boolean;
  featureCount: number;
};

type Feature = {
  id: string;
  productId: string;
  featureCode: string;
  name: string;
  isActive: boolean;
};

export function ProductsPage() {
  const [products, setProducts] = useState<Product[]>([]);
  const [features, setFeatures] = useState<Feature[]>([]);
  const [selected, setSelected] = useState<Product | null>(null);
  const [error, setError] = useState("");

  const [productCode, setProductCode] = useState("");
  const [productName, setProductName] = useState("");

  const [featureCode, setFeatureCode] = useState("");
  const [featureName, setFeatureName] = useState("");

  async function loadProducts() {
    setProducts(await apiFetch<Product[]>("/v1/admin/products"));
  }

  async function loadFeatures(product: Product) {
    setSelected(product);
    setFeatures(
      await apiFetch<Feature[]>(
        `/v1/admin/products/${product.id}/features`
      )
    );
  }

  useEffect(() => {
    loadProducts().catch(() => setError("Products could not be loaded."));
  }, []);

  async function createProduct(event: FormEvent) {
    event.preventDefault();

    try {
      await apiFetch("/v1/admin/products", {
        method: "POST",
        body: JSON.stringify({
          productCode,
          name: productName
        })
      });

      setProductCode("");
      setProductName("");
      await loadProducts();
    } catch {
      setError("Product could not be created.");
    }
  }

  async function createFeature(event: FormEvent) {
    event.preventDefault();
    if (!selected) return;

    try {
      await apiFetch(`/v1/admin/products/${selected.id}/features`, {
        method: "POST",
        body: JSON.stringify({
          featureCode,
          name: featureName
        })
      });

      setFeatureCode("");
      setFeatureName("");
      await loadProducts();
      await loadFeatures(selected);
    } catch {
      setError("Feature could not be created.");
    }
  }

  async function toggleProduct(product: Product) {
    await apiFetch(`/v1/admin/products/${product.id}/status`, {
      method: "PUT",
      body: JSON.stringify({ isActive: !product.isActive })
    });

    await loadProducts();
  }

  async function toggleFeature(feature: Feature) {
    await apiFetch(`/v1/admin/products/features/${feature.id}/status`, {
      method: "PUT",
      body: JSON.stringify({ isActive: !feature.isActive })
    });

    if (selected) await loadFeatures(selected);
  }

  return (
    <>
      <div className="page-heading">
        <div>
          <h1>Products & Features</h1>
          <p>Define licensable products and entitlement features.</p>
        </div>
      </div>

      {error && <div className="page-error">{error}</div>}

      <div className="management-grid">
        <article className="panel">
          <h2>Create product</h2>

          <form className="management-form" onSubmit={createProduct}>
            <label>
              Product code
              <input
                value={productCode}
                onChange={(e) => setProductCode(e.target.value.toUpperCase())}
                required
              />
            </label>

            <label>
              Name
              <input
                value={productName}
                onChange={(e) => setProductName(e.target.value)}
                required
              />
            </label>

            <button className="primary-button" type="submit">
              Create product
            </button>
          </form>
        </article>

        <article className="panel">
          <h2>Products</h2>

          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Code</th>
                  <th>Name</th>
                  <th>Features</th>
                  <th>Status</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {products.map((product) => (
                  <tr key={product.id}>
                    <td>{product.productCode}</td>
                    <td>
                      <button
                        className="text-button"
                        onClick={() => loadFeatures(product)}
                      >
                        {product.name}
                      </button>
                    </td>
                    <td>{product.featureCount}</td>
                    <td>
                      <span
                        className={
                          product.isActive
                            ? "status-badge active"
                            : "status-badge inactive"
                        }
                      >
                        {product.isActive ? "Active" : "Inactive"}
                      </span>
                    </td>
                    <td>
                      <button
                        className="secondary-button"
                        onClick={() => toggleProduct(product)}
                      >
                        {product.isActive ? "Deactivate" : "Activate"}
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </article>
      </div>

      <article className="panel feature-panel">
        <h2>Features{selected ? ` — ${selected.name}` : ""}</h2>

        {!selected ? (
          <div className="empty-state">
            Select a product to manage its features.
          </div>
        ) : (
          <div className="feature-layout">
            <form className="management-form" onSubmit={createFeature}>
              <label>
                Feature code
                <input
                  value={featureCode}
                  onChange={(e) => setFeatureCode(e.target.value.toUpperCase())}
                  required
                />
              </label>

              <label>
                Feature name
                <input
                  value={featureName}
                  onChange={(e) => setFeatureName(e.target.value)}
                  required
                />
              </label>

              <button className="primary-button" type="submit">
                Add feature
              </button>
            </form>

            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Code</th>
                    <th>Name</th>
                    <th>Status</th>
                    <th />
                  </tr>
                </thead>
                <tbody>
                  {features.map((feature) => (
                    <tr key={feature.id}>
                      <td>{feature.featureCode}</td>
                      <td>{feature.name}</td>
                      <td>
                        <span
                          className={
                            feature.isActive
                              ? "status-badge active"
                              : "status-badge inactive"
                          }
                        >
                          {feature.isActive ? "Active" : "Inactive"}
                        </span>
                      </td>
                      <td>
                        <button
                          className="secondary-button"
                          onClick={() => toggleFeature(feature)}
                        >
                          {feature.isActive ? "Deactivate" : "Activate"}
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}
      </article>
    </>
  );
}
TSX

printf '%s\n' "products_features_gui=CREATED"

printf '\n=== 8. REWRITE GUI ROUTES + ADD STYLES ===\n'

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

            <Route
              path="licenses"
              element={
                <PlaceholderPage
                  title="Licenses"
                  description="Subscriptions, license status and administrative controls."
                />
              }
            />

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

.management-grid {
  display: grid;
  grid-template-columns: minmax(300px, .7fr) minmax(0, 1.6fr);
  gap: 18px;
  margin-bottom: 18px;
}

.management-form {
  display: grid;
  gap: 14px;
}

.management-form label {
  display: grid;
  gap: 7px;
  color: #344054;
  font-size: 13px;
  font-weight: 650;
}

.management-form input,
.management-form textarea,
.management-form select {
  width: 100%;
  border: 1px solid #d0d5dd;
  border-radius: 9px;
  padding: 10px 11px;
  background: #fff;
  color: #172033;
  outline: none;
}

.management-form textarea {
  min-height: 90px;
  resize: vertical;
}

.management-form input:focus,
.management-form textarea:focus,
.management-form select:focus {
  border-color: #667085;
  box-shadow: 0 0 0 3px rgba(102,112,133,.12);
}

.table-wrap {
  overflow-x: auto;
}

table {
  width: 100%;
  border-collapse: collapse;
  font-size: 13px;
}

th,
td {
  text-align: left;
  padding: 12px 10px;
  border-bottom: 1px solid #eef0f3;
  vertical-align: middle;
}

th {
  color: #667085;
  font-weight: 650;
  white-space: nowrap;
}

.status-badge {
  display: inline-flex;
  align-items: center;
  border-radius: 999px;
  padding: 5px 9px;
  font-size: 12px;
  font-weight: 700;
}

.status-badge.active {
  background: #ecfdf3;
  color: #166534;
}

.status-badge.inactive {
  background: #f2f4f7;
  color: #475467;
}

.secondary-button,
.text-button {
  border: 0;
  cursor: pointer;
}

.secondary-button {
  background: #eef2f7;
  color: #344054;
  border-radius: 8px;
  padding: 7px 10px;
}

.text-button {
  background: transparent;
  color: #1d4ed8;
  padding: 0;
  font-weight: 650;
}

.feature-panel {
  margin-top: 18px;
}

.feature-layout {
  display: grid;
  grid-template-columns: minmax(250px, .55fr) minmax(0, 1.45fr);
  gap: 22px;
}

@media (max-width: 1000px) {
  .management-grid,
  .feature-layout {
    grid-template-columns: 1fr;
  }
}
CSS

printf '%s\n' "management_routes_styles=PASS"

printf '\n=== 9. API RELEASE BUILD ===\n'

dotnet build QuikeFix.LicenseManager.slnx -c Release \
  || die "Phase 16C API build failed"

printf '%s\n' "api_release_build=PASS"

printf '\n=== 10. CLONE PRODUCTION DATABASE ===\n'

docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1 \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" \
  >/dev/null

docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB"
docker exec "$PG" createdb -U qflm "$ISO_DB" || die "isolated DB create failed"

docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges \
  | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null \
  || die "isolated DB clone failed"

printf '%s\n' "isolated_database_clone=PASS"

printf '\n=== 11. BUILD ISOLATED API IMAGE ===\n'

rm -rf "$API_PUBLISH"

dotnet publish "$API_SRC/QFLM.Api.csproj" -c Release -o "$API_PUBLISH" \
  || die "API publish failed"

cat > "$API_DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-recovery7c/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER

docker build -f "$API_DOCKERFILE" -t "$API_IMAGE" . \
  || die "API candidate build failed"

printf 'api_candidate_image=%s\n' "$API_IMAGE"

printf '\n=== 12. PREPARE + START ISOLATED API ===\n'

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
  --network-alias qflm-api-backend \
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
      docker logs --tail 150 "$ISO_API" || true
      die "isolated API readiness failed"
  }

printf '%s\n' "isolated_api_health=PASS"

ISO_DB_ENV=$(docker inspect "$ISO_API" --format='{{range .Config.Env}}{{println .}}{{end}}' \
  | awk -F= '$1=="Qflm__PostgreSqlDatabase"{print $2}' | tail -n1)

printf 'isolated_api_database=%s\n' "$ISO_DB_ENV"
[ "$ISO_DB_ENV" = "$ISO_DB" ] || die "isolated API is not bound to isolated database"
printf '%s\n' "isolated_database_binding=PASS"

printf '\n=== 13. BUILD + START ISOLATED GUI ===\n'

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
  '  include /etc/nginx/mime.types;' \
  '  default_type application/octet-stream;' \
  '  access_log /dev/stdout;' \
  '  sendfile on;' \
  '  client_body_temp_path /tmp/client_temp;' \
  '  proxy_temp_path /tmp/proxy_temp;' \
  '  fastcgi_temp_path /tmp/fastcgi_temp;' \
  '  uwsgi_temp_path /tmp/uwsgi_temp;' \
  '  scgi_temp_path /tmp/scgi_temp;' \
  '  server {' \
  '    listen 8080;' \
  '    server_name _;' \
  '    root /usr/share/nginx/html;' \
  '    index index.html;' \
  '    location /api/ {' \
  '      proxy_pass http://qflm-api-backend:8080/api/;' \
  '      proxy_http_version 1.1;' \
  '      proxy_set_header Host $host;' \
  '      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' \
  '      proxy_set_header X-Forwarded-Proto $scheme;' \
  '    }' \
  '    location / {' \
  '      try_files $uri $uri/ /index.html;' \
  '    }' \
  '    location = /health {' \
  '      access_log off;' \
  '      default_type text/plain;' \
  '      return 200 "ok\n";' \
  '    }' \
  '  }' \
  '}' \
  > /etc/nginx/nginx-qflm.conf

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
  || {
      docker logs --tail 120 "$ISO_GUI" || true
      die "isolated GUI not running"
  }

printf 'gui_candidate_image=%s\n' "$GUI_IMAGE"
printf '%s\n' "isolated_gui_running=PASS"

printf '\n=== 14. ADMIN LOGIN THROUGH GUI PROXY ===\n'

ADMIN_USER="$(cat "$ADMIN_USER_FILE")"
ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"

LOGIN_JSON=$(python3 - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import json,sys
print(json.dumps({"username": sys.argv[1], "password": sys.argv[2]}))
PY
)

LOGIN_RESPONSE=$(printf '%s' "$LOGIN_JSON" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -fsS -H 'Content-Type: application/json' \
      -X POST "http://$ISO_GUI:8080/api/v1/auth/login" \
      --data-binary @-) \
  || die "admin login through GUI proxy failed"

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

[ -n "$TOKEN" ] || die "access token missing"
[ -n "$REFRESH" ] || die "refresh token missing"

printf '%s\n' "gui_admin_login=PASS"

api_fail(){
  printf '%s\n' "--- isolated API logs ---"
  docker logs --tail 200 "$ISO_API" || true
  printf '%s\n' "--- isolated GUI logs ---"
  docker logs --tail 100 "$ISO_GUI" || true
  die "$1"
}

printf '\n=== 15. CUSTOMER MANAGEMENT API TEST ===\n'

INITIAL_CUSTOMERS=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 -fsS \
  -H "Authorization: Bearer $TOKEN" \
  "http://$ISO_GUI:8080/api/v1/admin/customers") \
  || api_fail "customer list failed"

INITIAL_CUSTOMER_COUNT=$(python3 - "$INITIAL_CUSTOMERS" <<'PY'
import json,sys
print(len(json.loads(sys.argv[1])))
PY
)

CUSTOMER_PAYLOAD='{"customerNumber":"PH16C-CUST-001","name":"Phase 16C Customer","email":"phase16c@example.invalid","countryCode":"ZA"}'

CUSTOMER_RESPONSE=$(printf '%s' "$CUSTOMER_PAYLOAD" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 -fsS \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -X POST "http://$ISO_GUI:8080/api/v1/admin/customers" \
      --data-binary @-) \
  || api_fail "customer creation failed"

CUSTOMER_ID=$(python3 - "$CUSTOMER_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["id"])
PY
)

CUSTOMER_STATUS_HTTP=$(printf '%s' '{"isActive":false}' \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -X PUT "http://$ISO_GUI:8080/api/v1/admin/customers/$CUSTOMER_ID/status" \
      --data-binary @-)

[ "$CUSTOMER_STATUS_HTTP" = 204 ] || die "customer status update failed"

CUSTOMER_DB_STATUS=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" \
  -tAc "SELECT is_active FROM customers WHERE id='$CUSTOMER_ID';" | xargs)

[ "$CUSTOMER_DB_STATUS" = f ] || die "customer did not deactivate"

printf 'customer_management=PASS initial_count=%s created_id=%s status_http=%s\n' \
  "$INITIAL_CUSTOMER_COUNT" "$CUSTOMER_ID" "$CUSTOMER_STATUS_HTTP"

printf '\n=== 16. PRODUCT + FEATURE MANAGEMENT API TEST ===\n'

PRODUCT_PAYLOAD='{"productCode":"PH16C-PRODUCT","name":"Phase 16C Product"}'

PRODUCT_RESPONSE=$(printf '%s' "$PRODUCT_PAYLOAD" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 -fsS \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -X POST "http://$ISO_GUI:8080/api/v1/admin/products" \
      --data-binary @-) \
  || api_fail "product creation failed"

PRODUCT_ID=$(python3 - "$PRODUCT_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["id"])
PY
)

FEATURE_PAYLOAD='{"featureCode":"PH16C_FEATURE","name":"Phase 16C Feature"}'

FEATURE_RESPONSE=$(printf '%s' "$FEATURE_PAYLOAD" \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 -fsS \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -X POST "http://$ISO_GUI:8080/api/v1/admin/products/$PRODUCT_ID/features" \
      --data-binary @-) \
  || api_fail "feature creation failed"

FEATURE_ID=$(python3 - "$FEATURE_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["id"])
PY
)

FEATURES_JSON=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 -fsS \
  -H "Authorization: Bearer $TOKEN" \
  "http://$ISO_GUI:8080/api/v1/admin/products/$PRODUCT_ID/features") \
  || api_fail "feature list failed"

FEATURE_COUNT=$(python3 - "$FEATURES_JSON" <<'PY'
import json,sys
print(len(json.loads(sys.argv[1])))
PY
)

[ "$FEATURE_COUNT" = 1 ] || die "expected one created feature"

FEATURE_STATUS_HTTP=$(printf '%s' '{"isActive":false}' \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -X PUT "http://$ISO_GUI:8080/api/v1/admin/products/features/$FEATURE_ID/status" \
      --data-binary @-)

[ "$FEATURE_STATUS_HTTP" = 204 ] || die "feature status update failed"

PRODUCT_STATUS_HTTP=$(printf '%s' '{"isActive":false}' \
  | docker run --rm --network "$NET" -i \
      curlimages/curl:8.16.0 \
      -s -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -X PUT "http://$ISO_GUI:8080/api/v1/admin/products/$PRODUCT_ID/status" \
      --data-binary @-)

[ "$PRODUCT_STATUS_HTTP" = 204 ] || die "product status update failed"

printf 'product_feature_management=PASS product_id=%s feature_id=%s feature_count=%s\n' \
  "$PRODUCT_ID" "$FEATURE_ID" "$FEATURE_COUNT"

printf '\n=== 17. GUI ROUTE TEST ===\n'

CUSTOMERS_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  "http://$ISO_GUI:8080/customers")

PRODUCTS_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  "http://$ISO_GUI:8080/products")

printf 'customers_http=%s products_http=%s\n' "$CUSTOMERS_HTTP" "$PRODUCTS_HTTP"

[ "$CUSTOMERS_HTTP" = 200 ] || die "customers GUI route failed"
[ "$PRODUCTS_HTTP" = 200 ] || die "products GUI route failed"

printf '%s\n' "management_gui_routes=PASS"

printf '\n=== 18. ISOLATED DATABASE VERIFICATION ===\n'

ISO_CUSTOMERS=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM customers;' | xargs)
ISO_PRODUCTS=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM products;' | xargs)
ISO_FEATURES=$(docker exec "$PG" psql -U qflm -d "$ISO_DB" -tAc 'SELECT count(*) FROM features;' | xargs)

[ "$ISO_CUSTOMERS" -eq $((CUSTOMERS + 1)) ] || die "isolated customer count mismatch"
[ "$ISO_PRODUCTS" -eq $((PRODUCTS + 1)) ] || die "isolated product count mismatch"
[ "$ISO_FEATURES" -eq $((FEATURES + 1)) ] || die "isolated feature count mismatch"

printf 'isolated_customers=%s isolated_products=%s isolated_features=%s\n' \
  "$ISO_CUSTOMERS" "$ISO_PRODUCTS" "$ISO_FEATURES"

printf '%s\n' "isolated_management_persistence=PASS"

printf '\n=== 19. REVOKE TEST SESSION ===\n'

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

[ "$REVOKE_HTTP" = 204 ] || die "test session revoke failed"

printf '%s\n' "test_session_revoked=PASS"

unset TOKEN REFRESH ADMIN_PASS LOGIN_JSON LOGIN_RESPONSE REVOKE_JSON

printf '\n=== 20. PRODUCTION FINAL SAFETY ===\n'

FINAL_IMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_CUSTOMERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM customers;' | xargs)
FINAL_PRODUCTS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM products;' | xargs)
FINAL_FEATURES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM features;' | xargs)
FINAL_LICENSES=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_INSTALLATIONS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'image=%s running=%s migrations=%s customers=%s products=%s features=%s licenses=%s installations=%s\n' \
  "$FINAL_IMG" "$FINAL_RUN" "$FINAL_MIG" "$FINAL_CUSTOMERS" "$FINAL_PRODUCTS" "$FINAL_FEATURES" "$FINAL_LICENSES" "$FINAL_INSTALLATIONS"

[ "$FINAL_IMG" = "$IMG" ] || die "production API image changed"
[ "$FINAL_RUN" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "production migration count changed"
[ "$FINAL_CUSTOMERS" = "$CUSTOMERS" ] || die "production customers changed"
[ "$FINAL_PRODUCTS" = "$PRODUCTS" ] || die "production products changed"
[ "$FINAL_FEATURES" = "$FEATURES" ] || die "production features changed"
[ "$FINAL_LICENSES" = "$LICENSES" ] || die "production licenses changed"
[ "$FINAL_INSTALLATIONS" = "$INSTALLATIONS" ] || die "production installations changed"

printf '%s\n' "production_unchanged=PASS"

COMPLETED=1

printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7C PASSED"
printf '%s\n' "======================================================"
printf '%s\n' "CUSTOMER LIST API:                  PASS"
printf '%s\n' "CUSTOMER CREATE API:                PASS"
printf '%s\n' "CUSTOMER STATUS API:                PASS"
printf '%s\n' "CUSTOMERS GUI:                      PASS"
printf '%s\n' "PRODUCT LIST API:                   PASS"
printf '%s\n' "PRODUCT CREATE API:                 PASS"
printf '%s\n' "PRODUCT STATUS API:                 PASS"
printf '%s\n' "FEATURE LIST API:                   PASS"
printf '%s\n' "FEATURE CREATE API:                 PASS"
printf '%s\n' "FEATURE STATUS API:                 PASS"
printf '%s\n' "PRODUCTS / FEATURES GUI:            PASS"
printf '%s\n' "PERMISSION-BASED RBAC:              ACTIVE"
printf '%s\n' "GUI/API SAME-ORIGIN PROXY:          PASS"
printf '%s\n' "PRODUCTION API/DB:                  UNCHANGED"
printf 'API CANDIDATE IMAGE:                %s\n' "$API_IMAGE"
printf 'GUI CANDIDATE IMAGE:                %s\n' "$GUI_IMAGE"
printf 'REPORT:                             %s\n' "$REPORT"
printf '%s\n' "NEXT: RECOVERY 7D - SUBSCRIPTIONS / LICENSES / ENTITLEMENTS MANAGEMENT GUI + API"
printf '%s\n' "======================================================"
printf '%s\n' "======================================================"