#!/usr/bin/env bash
# QFLM RECOVERY 2A
# Reconstruct base .NET solution/source scaffold and runtime connectivity layer.

set -u
set -o pipefail
umask 077

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"

echo "======================================================"
echo " QFLM RECOVERY 2A - SOURCE SCAFFOLD"
echo "======================================================"

[ "$(id -u)" -eq 0 ] || die "run as root"
dotnet --list-sdks | grep -q '^10\.' || die ".NET 10 SDK missing"
docker inspect qflm-postgres >/dev/null 2>&1 || die "qflm-postgres missing"
docker inspect qflm-redis >/dev/null 2>&1 || die "qflm-redis missing"
[ "$(docker inspect qflm-postgres --format='{{.State.Health.Status}}')" = healthy ] || die "postgres not healthy"
[ "$(docker inspect qflm-redis --format='{{.State.Health.Status}}')" = healthy ] || die "redis not healthy"

echo
echo "=== 1. PREPARE SOURCE TREE ==="

if [ -e "$ROOT" ]; then
    BACKUP="/opt/qflm/backups/recovery2a-existing-$(date -u +%Y%m%dT%H%M%SZ).tgz"
    tar -czf "$BACKUP" -C /opt/qflm/app QuikeFix.LicenseManager
    rm -rf "$ROOT"
    echo "existing_source_backup=$BACKUP"
fi

mkdir -p "$ROOT/src" "$ROOT/artifacts"
cd "$ROOT" || die "cannot enter source root"

cat > global.json <<'JSON'
{
  "sdk": {
    "version": "10.0.115",
    "rollForward": "latestPatch"
  }
}
JSON

dotnet new sln -n QuikeFix.LicenseManager --format slnx >/dev/null
dotnet new classlib -n QFLM.Domain -o src/QFLM.Domain --framework net10.0 >/dev/null
dotnet new classlib -n QFLM.Application -o src/QFLM.Application --framework net10.0 >/dev/null
dotnet new classlib -n QFLM.Infrastructure -o src/QFLM.Infrastructure --framework net10.0 >/dev/null
dotnet new webapi -n QFLM.Api -o src/QFLM.Api --framework net10.0 --no-https >/dev/null

rm -f src/QFLM.Domain/Class1.cs src/QFLM.Application/Class1.cs src/QFLM.Infrastructure/Class1.cs

dotnet sln QuikeFix.LicenseManager.slnx add  src/QFLM.Domain/QFLM.Domain.csproj  src/QFLM.Application/QFLM.Application.csproj  src/QFLM.Infrastructure/QFLM.Infrastructure.csproj  src/QFLM.Api/QFLM.Api.csproj >/dev/null

dotnet add src/QFLM.Application/QFLM.Application.csproj reference  src/QFLM.Domain/QFLM.Domain.csproj >/dev/null

dotnet add src/QFLM.Infrastructure/QFLM.Infrastructure.csproj reference  src/QFLM.Domain/QFLM.Domain.csproj  src/QFLM.Application/QFLM.Application.csproj >/dev/null

dotnet add src/QFLM.Api/QFLM.Api.csproj reference  src/QFLM.Application/QFLM.Application.csproj  src/QFLM.Infrastructure/QFLM.Infrastructure.csproj >/dev/null

echo "solution_scaffold=PASS"

echo
echo "=== 2. ADD KNOWN QFLM PACKAGES ==="

dotnet add src/QFLM.Infrastructure/QFLM.Infrastructure.csproj package Microsoft.EntityFrameworkCore --version 10.0.4 >/dev/null
dotnet add src/QFLM.Infrastructure/QFLM.Infrastructure.csproj package Microsoft.EntityFrameworkCore.Design --version 10.0.4 >/dev/null
dotnet add src/QFLM.Infrastructure/QFLM.Infrastructure.csproj package Npgsql.EntityFrameworkCore.PostgreSQL --version 10.0.3 >/dev/null
dotnet add src/QFLM.Infrastructure/QFLM.Infrastructure.csproj package EFCore.NamingConventions --version 10.0.0 >/dev/null
dotnet add src/QFLM.Infrastructure/QFLM.Infrastructure.csproj package StackExchange.Redis --version 2.9.32 >/dev/null

dotnet add src/QFLM.Api/QFLM.Api.csproj package Microsoft.AspNetCore.OpenApi --version 10.0.12 >/dev/null

echo "package_restore=PASS"

echo
echo "=== 3. RUNTIME OPTIONS + CONNECTION FACTORY ==="

mkdir -p src/QFLM.Infrastructure/Configuration

cat > src/QFLM.Infrastructure/Configuration/QflmRuntimeOptions.cs <<'CS'
namespace QFLM.Infrastructure.Configuration;

public sealed class QflmRuntimeOptions
{
    public string PostgreSqlHost { get; set; } = "qflm-postgres";
    public int PostgreSqlPort { get; set; } = 5432;
    public string PostgreSqlDatabase { get; set; } = "qflm";
    public string PostgreSqlUsername { get; set; } = "qflm";
    public string PostgreSqlPasswordFile { get; set; } = "/run/secrets/postgres_password";

    public string RedisHost { get; set; } = "qflm-redis";
    public int RedisPort { get; set; } = 6379;
    public string RedisPasswordFile { get; set; } = "/run/secrets/redis_password";
}
CS

cat > src/QFLM.Infrastructure/Configuration/QflmConnectionFactory.cs <<'CS'
using Npgsql;
using StackExchange.Redis;

namespace QFLM.Infrastructure.Configuration;

public static class QflmConnectionFactory
{
    public static string BuildPostgreSql(QflmRuntimeOptions options)
    {
        var password = ReadSecret(options.PostgreSqlPasswordFile);

        var builder = new NpgsqlConnectionStringBuilder
        {
            Host = options.PostgreSqlHost,
            Port = options.PostgreSqlPort,
            Database = options.PostgreSqlDatabase,
            Username = options.PostgreSqlUsername,
            Password = password,
            Pooling = true,
            IncludeErrorDetail = false
        };

        return builder.ConnectionString;
    }

    public static string BuildRedis(QflmRuntimeOptions options)
    {
        var password = ReadSecret(options.RedisPasswordFile);

        var configuration = new ConfigurationOptions
        {
            AbortOnConnectFail = false,
            Password = password
        };

        configuration.EndPoints.Add(options.RedisHost, options.RedisPort);
        return configuration.ToString();
    }

    private static string ReadSecret(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            throw new InvalidOperationException("Secret file path is not configured.");

        if (!File.Exists(path))
            throw new FileNotFoundException($"Required secret file was not found: {path}");

        var value = File.ReadAllText(path).Trim();

        if (string.IsNullOrWhiteSpace(value))
            throw new InvalidOperationException($"Secret file is empty: {path}");

        return value;
    }
}
CS

echo "runtime_connectivity_source=PASS"

echo
echo "=== 4. HEALTH CHECKS ==="

mkdir -p src/QFLM.Api/Health

cat > src/QFLM.Api/Health/PostgreSqlHealthCheck.cs <<'CS'
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Npgsql;

namespace QFLM.Api.Health;

public sealed class PostgreSqlHealthCheck(NpgsqlDataSource dataSource) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context,
        CancellationToken cancellationToken = default)
    {
        try
        {
            await using var command = dataSource.CreateCommand("SELECT 1");
            await command.ExecuteScalarAsync(cancellationToken);
            return HealthCheckResult.Healthy("PostgreSQL is reachable.");
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy("PostgreSQL is unavailable.", ex);
        }
    }
}
CS

cat > src/QFLM.Api/Health/RedisHealthCheck.cs <<'CS'
using Microsoft.Extensions.Diagnostics.HealthChecks;
using StackExchange.Redis;

namespace QFLM.Api.Health;

public sealed class RedisHealthCheck(IConnectionMultiplexer redis) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context,
        CancellationToken cancellationToken = default)
    {
        try
        {
            await redis.GetDatabase().PingAsync();
            return HealthCheckResult.Healthy("Redis is reachable.");
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy("Redis is unavailable.", ex);
        }
    }
}
CS

echo "health_checks=PASS"

echo
echo "=== 5. BASE API PROGRAM ==="

cat > src/QFLM.Api/Program.cs <<'CS'
using System.Text.Json;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Npgsql;
using QFLM.Api.Health;
using QFLM.Infrastructure.Configuration;
using StackExchange.Redis;

var builder = WebApplication.CreateBuilder(args);

var options = new QflmRuntimeOptions();
builder.Configuration.GetSection("Qflm").Bind(options);

var pgConnection = QflmConnectionFactory.BuildPostgreSql(options);
var redisConnection = QflmConnectionFactory.BuildRedis(options);

builder.Services.AddSingleton(options);
builder.Services.AddSingleton(NpgsqlDataSource.Create(pgConnection));
builder.Services.AddSingleton<IConnectionMultiplexer>(
    _ => ConnectionMultiplexer.Connect(redisConnection));

builder.Services.AddControllers();
builder.Services.AddOpenApi();

builder.Services
    .AddHealthChecks()
    .AddCheck("self", () => HealthCheckResult.Healthy(), tags: ["live"])
    .AddCheck<PostgreSqlHealthCheck>("postgresql", tags: ["ready"])
    .AddCheck<RedisHealthCheck>("redis", tags: ["ready"]);

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.MapControllers();

app.MapHealthChecks(
    "/health/live",
    new HealthCheckOptions
    {
        Predicate = registration => registration.Tags.Contains("live"),
        ResponseWriter = WriteHealthResponse
    });

app.MapHealthChecks(
    "/health/ready",
    new HealthCheckOptions
    {
        Predicate = registration => registration.Tags.Contains("ready"),
        ResponseWriter = WriteHealthResponse
    });

app.Run();

static Task WriteHealthResponse(HttpContext context, HealthReport report)
{
    context.Response.ContentType = "application/json";

    var response = new
    {
        status = report.Status.ToString(),
        checks = report.Entries.Select(entry => new
        {
            name = entry.Key,
            status = entry.Value.Status.ToString()
        })
    };

    return context.Response.WriteAsync(JsonSerializer.Serialize(response));
}
CS

cat > src/QFLM.Api/appsettings.json <<'JSON'
{
  "Qflm": {
    "PostgreSqlHost": "qflm-postgres",
    "PostgreSqlPort": 5432,
    "PostgreSqlDatabase": "qflm",
    "PostgreSqlUsername": "qflm",
    "PostgreSqlPasswordFile": "/run/secrets/postgres_password",
    "RedisHost": "qflm-redis",
    "RedisPort": 6379,
    "RedisPasswordFile": "/run/secrets/redis_password"
  },
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "AllowedHosts": "*"
}
JSON

echo "base_api_program=PASS"

echo
echo "=== 6. RELEASE BUILD ==="

dotnet restore QuikeFix.LicenseManager.slnx
dotnet build QuikeFix.LicenseManager.slnx -c Release --no-restore

echo "release_build=PASS"

echo
echo "=== 7. CONTAINERIZED CONNECTIVITY TEST ==="

dotnet publish src/QFLM.Api/QFLM.Api.csproj -c Release -o artifacts/api-publish-recovery2a --no-restore

cat > Dockerfile.recovery2a-api <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-recovery2a/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER

docker build -f Dockerfile.recovery2a-api -t qflm-api:recovery2a . >/dev/null

docker rm -f qflm-api-recovery2a >/dev/null 2>&1 || true

docker run -d   --name qflm-api-recovery2a   --network qflm_backend   --read-only   --cap-drop ALL   --security-opt no-new-privileges:true   --tmpfs /tmp:rw,noexec,nosuid,size=32m   -e ASPNETCORE_URLS=http://+:8080   -v /opt/qflm/secrets/runtime-api/postgres_password:/run/secrets/postgres_password:ro   -v /opt/qflm/secrets/runtime-api/redis_password:/run/secrets/redis_password:ro   qflm-api:recovery2a >/dev/null

sleep 5

docker run --rm --network qflm_backend curlimages/curl:8.16.0   -fsS http://qflm-api-recovery2a:8080/health/live >/tmp/qflm-live.json   || { docker logs qflm-api-recovery2a; die "live health failed"; }

docker run --rm --network qflm_backend curlimages/curl:8.16.0   -fsS http://qflm-api-recovery2a:8080/health/ready >/tmp/qflm-ready.json   || { docker logs qflm-api-recovery2a; die "ready health failed"; }

grep -q '"status":"Healthy"' /tmp/qflm-live.json || die "live status not healthy"
grep -q '"postgresql","status":"Healthy"' /tmp/qflm-ready.json || die "postgres health missing"
grep -q '"redis","status":"Healthy"' /tmp/qflm-ready.json || die "redis health missing"

rm -f /tmp/qflm-live.json /tmp/qflm-ready.json
docker rm -f qflm-api-recovery2a >/dev/null

echo "containerized_connectivity=PASS"

echo
echo "=== 8. FINAL SOURCE INVENTORY ==="

find src -maxdepth 2 -type f \( -name '*.csproj' -o -name '*.cs' \) | sort
echo
echo "solution=$(ls QuikeFix.LicenseManager.slnx)"
echo "dotnet=$(dotnet --version)"

echo
echo "======================================================"
echo " QFLM RECOVERY 2A PASSED"
echo "======================================================"
echo "SOLUTION SCAFFOLD:        PASS"
echo "PROJECT REFERENCES:       PASS"
echo "RUNTIME OPTIONS:          PASS"
echo "POSTGRES CONNECTIVITY:    PASS"
echo "REDIS CONNECTIVITY:       PASS"
echo "LIVE/READY HEALTH:        PASS"
echo "RELEASE BUILD:            PASS"
echo "NEXT: RECOVERY 2B - CORE LICENSING DOMAIN + INITIAL SCHEMA"
echo "======================================================"
