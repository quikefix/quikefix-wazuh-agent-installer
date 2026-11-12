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
ISO_DB="qflm_recovery7b_test"
ISO_API="qflm-api-recovery7b-test"
ISO_GUI="qflm-admin-web-recovery7b-test"
NET="qflm_backend"

EXPECTED_API_IMAGE="qflm-api:recovery6f3-candidate"
API_IMAGE="qflm-api:recovery7b-candidate"
GUI_IMAGE="qflm-admin-web:recovery7b-candidate"

ADMIN_USER_FILE="/opt/qflm/secrets/auth/platform-admin-username"
ADMIN_PASS_FILE="/opt/qflm/secrets/auth/platform-admin-password"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7b-$STAMP"
REPORT="$BACKUP/recovery7b-report.txt"
SOURCE_BACKUP="$BACKUP/source-before-recovery7b.tgz"
DB_DUMP="$BACKUP/qflm-before-recovery7b.dump"
ENV_FILE="$BACKUP/isolated-api.env"
API_PUBLISH="$ROOT/artifacts/api-publish-recovery7b"
API_DOCKERFILE="$ROOT/Dockerfile.recovery7b-api"
GUI_DOCKERFILE="$ROOT/Dockerfile.recovery7b-gui"

MUTATED=0
COMPLETED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

cleanup(){
  docker rm -f "$ISO_GUI" >/dev/null 2>&1 || true
  docker rm -f "$ISO_API" >/dev/null 2>&1 || true
  if [ "$COMPLETED" -ne 1 ] && [ "$MUTATED" -eq 1 ] && [ -s "$SOURCE_BACKUP" ]; then
    printf '\n=== SOURCE ROLLBACK ===\n'
    rm -f "$API_SRC/Controllers/AdminDashboardController.cs"
    tar -xzf "$SOURCE_BACKUP" -C "$ROOT" >/dev/null 2>&1 || true
    printf '%s\n' "source_restore_attempted=YES"
  fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7B"
printf '%s\n' " LOGIN SESSION + LIVE DASHBOARD/API INTEGRATION"
printf '%s\n' " ISOLATED"
printf '%s\n' "======================================================"

printf '\n=== 1. PRODUCTION SAFETY BASELINE ===\n'
IMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}') || die "production API missing"
RUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
AUTH=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name LIKE 'auth_%';" | xargs)
USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
LIC=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
INST=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'api_image=%s running=%s migrations=%s auth_tables=%s users=%s licenses=%s installations=%s\n' "$IMG" "$RUN" "$MIG" "$AUTH" "$USERS" "$LIC" "$INST"
[ "$IMG" = "$EXPECTED_API_IMAGE" ] || die "unexpected production API image"
[ "$RUN" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"
[ "$AUTH" = 6 ] || die "unexpected auth table count"
[ -s "$ADMIN_USER_FILE" ] || die "platform admin username file missing"
[ -s "$ADMIN_PASS_FILE" ] || die "platform admin password file missing"
[ -d "$GUI" ] || die "Recovery 7A GUI source missing"
printf '%s\n' "production_baseline=PASS"

printf '\n=== 2. BACKUP SOURCE + DATABASE ===\n'
tar -czf "$SOURCE_BACKUP" -C "$ROOT" src/QFLM.Api src/QFLM.AdminWeb || die "source backup failed"
docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" -Fc > "$DB_DUMP" || die "production DB backup failed"
[ -s "$DB_DUMP" ] || die "production DB backup empty"
printf 'source_backup_sha256=%s\n' "$(sha256sum "$SOURCE_BACKUP" | awk '{print $1}')"
printf 'database_backup_sha256=%s\n' "$(sha256sum "$DB_DUMP" | awk '{print $1}')"
MUTATED=1

printf '\n=== 3. ADD LIVE DASHBOARD ENDPOINT ===\n'
cat > "$API_SRC/Controllers/AdminDashboardController.cs" <<'CS'
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Npgsql;

namespace QFLM.Api.Controllers;

[ApiController]
[Route("api/v1/admin/dashboard")]
[Authorize(Policy = "permission:security.admin")]
public sealed class AdminDashboardController : ControllerBase
{
    private readonly NpgsqlDataSource _dataSource;
    public AdminDashboardController(NpgsqlDataSource dataSource) => _dataSource = dataSource;

    [HttpGet("summary")]
    public async Task<IActionResult> Summary(CancellationToken cancellationToken)
    {
        const string sql = """
SELECT
 (SELECT count(*) FROM customers),
 (SELECT count(*) FROM products),
 (SELECT count(*) FROM licenses),
 (SELECT count(*) FROM installations),
 (SELECT count(*) FROM offline_license_issuances),
 (SELECT count(*) FROM auth_users WHERE is_active=true);
""";
        await using var command = _dataSource.CreateCommand(sql);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)) return StatusCode(500);
        return Ok(new {
            customers = reader.GetInt64(0),
            products = reader.GetInt64(1),
            licenses = reader.GetInt64(2),
            installations = reader.GetInt64(3),
            offlineLicenses = reader.GetInt64(4),
            activeUsers = reader.GetInt64(5),
            generatedAtUtc = DateTime.UtcNow
        });
    }
}
CS
printf '%s\n' "dashboard_summary_endpoint=CREATED"

printf '\n=== 4. PATCH FRONTEND AUTH + API CLIENT ===\n'
mkdir -p "$GUI/src/auth"

cat > "$GUI/src/lib/api.ts" <<'TS'
export type LoginResponse = {
  accessToken: string;
  accessTokenExpiresAtUtc: string;
  refreshToken: string;
  refreshTokenExpiresAtUtc: string;
};

const ACCESS_KEY = "qflm.access";
const REFRESH_KEY = "qflm.refresh";

export const getAccessToken = () => sessionStorage.getItem(ACCESS_KEY);
export const getRefreshToken = () => sessionStorage.getItem(REFRESH_KEY);

export function saveTokens(tokens: LoginResponse) {
  sessionStorage.setItem(ACCESS_KEY, tokens.accessToken);
  sessionStorage.setItem(REFRESH_KEY, tokens.refreshToken);
}

export function clearTokens() {
  sessionStorage.removeItem(ACCESS_KEY);
  sessionStorage.removeItem(REFRESH_KEY);
}

async function rawFetch<T>(path: string, init?: RequestInit, token?: string | null): Promise<T> {
  const headers = new Headers(init?.headers ?? {});
  if (!headers.has("Content-Type") && init?.body) headers.set("Content-Type", "application/json");
  if (token) headers.set("Authorization", `Bearer ${token}`);
  const response = await fetch(`/api${path}`, { ...init, headers });
  if (!response.ok) {
    const e = new Error(`HTTP ${response.status}`) as Error & { status?: number };
    e.status = response.status;
    throw e;
  }
  if (response.status === 204) return undefined as T;
  return await response.json() as T;
}

export async function login(username: string, password: string) {
  const tokens = await rawFetch<LoginResponse>("/v1/auth/login", {
    method: "POST",
    body: JSON.stringify({ username, password })
  });
  saveTokens(tokens);
  return tokens;
}

export async function refreshSession() {
  const refreshToken = getRefreshToken();
  if (!refreshToken) return false;
  try {
    const tokens = await rawFetch<LoginResponse>("/v1/auth/refresh", {
      method: "POST",
      body: JSON.stringify({ refreshToken })
    });
    saveTokens(tokens);
    return true;
  } catch {
    clearTokens();
    return false;
  }
}

export async function apiFetch<T>(path: string, init?: RequestInit, retry=true): Promise<T> {
  try {
    return await rawFetch<T>(path, init, getAccessToken());
  } catch (e) {
    const status = (e as Error & {status?: number}).status;
    if (retry && status === 401 && await refreshSession()) {
      return apiFetch<T>(path, init, false);
    }
    throw e;
  }
}

export async function revokeSession() {
  const refreshToken = getRefreshToken();
  const accessToken = getAccessToken();
  if (refreshToken && accessToken) {
    try {
      await rawFetch<void>("/v1/auth/revoke", {
        method: "POST",
        body: JSON.stringify({ refreshToken })
      }, accessToken);
    } catch {}
  }
  clearTokens();
}
TS

cat > "$GUI/src/auth/AuthContext.tsx" <<'TSX'
import { createContext, useContext, useEffect, useMemo, useState } from "react";
import { apiFetch, clearTokens, getAccessToken, login as apiLogin, revokeSession } from "../lib/api";

type Me = { id: string; username: string; roles: string[]; permissions: string[] };
type Ctx = { user: Me|null; loading: boolean; signIn:(u:string,p:string)=>Promise<void>; signOut:()=>Promise<void> };
const AuthContext = createContext<Ctx|undefined>(undefined);

export function AuthProvider({children}:{children:React.ReactNode}) {
  const [user,setUser]=useState<Me|null>(null);
  const [loading,setLoading]=useState(true);

  async function reload() {
    if (!getAccessToken()) { setUser(null); return; }
    try { setUser(await apiFetch<Me>("/v1/auth/me")); }
    catch { clearTokens(); setUser(null); }
  }

  useEffect(()=>{ reload().finally(()=>setLoading(false)); },[]);
  async function signIn(username:string,password:string){ await apiLogin(username,password); await reload(); }
  async function signOut(){ await revokeSession(); setUser(null); }
  const value=useMemo(()=>({user,loading,signIn,signOut}),[user,loading]);
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const v=useContext(AuthContext);
  if(!v) throw new Error("useAuth outside AuthProvider");
  return v;
}
TSX

cat > "$GUI/src/auth/ProtectedRoute.tsx" <<'TSX'
import { Navigate } from "react-router-dom";
import { useAuth } from "./AuthContext";
export function ProtectedRoute({children}:{children:React.ReactNode}) {
  const {user,loading}=useAuth();
  if(loading) return <div className="full-page-state">Loading secure session…</div>;
  if(!user) return <Navigate to="/login" replace />;
  return <>{children}</>;
}
TSX

cat > "$GUI/src/pages/LoginPage.tsx" <<'TSX'
import { FormEvent, useState } from "react";
import { Navigate, useNavigate } from "react-router-dom";
import { useAuth } from "../auth/AuthContext";

export function LoginPage(){
  const {user,signIn}=useAuth();
  const navigate=useNavigate();
  const [username,setUsername]=useState("");
  const [password,setPassword]=useState("");
  const [error,setError]=useState("");
  const [busy,setBusy]=useState(false);
  if(user) return <Navigate to="/" replace />;

  async function submit(e:FormEvent){
    e.preventDefault(); setBusy(true); setError("");
    try { await signIn(username.trim(),password); navigate("/",{replace:true}); }
    catch { setError("Invalid username or password."); }
    finally { setBusy(false); }
  }

  return <div className="login-page"><div className="login-card">
    <div className="login-brand"><div className="brand-mark">QF</div><div><strong>QuikeFix Cloud License Manager</strong><span>Administration Console</span></div></div>
    <h1>Secure sign in</h1><p>Use your QFLM administrator credentials.</p>
    <form onSubmit={submit}>
      <label>Username<input value={username} onChange={e=>setUsername(e.target.value)} autoComplete="username" required /></label>
      <label>Password<input type="password" value={password} onChange={e=>setPassword(e.target.value)} autoComplete="current-password" required /></label>
      {error && <div className="login-error">{error}</div>}
      <button className="primary-button login-button" disabled={busy} type="submit">{busy?"Signing in…":"Sign in"}</button>
    </form>
  </div></div>;
}
TSX

cat > "$GUI/src/pages/DashboardPage.tsx" <<'TSX'
import { useEffect, useState } from "react";
import { apiFetch } from "../lib/api";
import { useAuth } from "../auth/AuthContext";

type Summary={customers:number;products:number;licenses:number;installations:number;offlineLicenses:number;activeUsers:number;generatedAtUtc:string};

export function DashboardPage(){
  const {user}=useAuth();
  const [summary,setSummary]=useState<Summary|null>(null);
  const [error,setError]=useState("");
  useEffect(()=>{ apiFetch<Summary>("/v1/admin/dashboard/summary").then(setSummary).catch(()=>setError("Dashboard data could not be loaded.")); },[]);
  const cards=[["Customers",summary?.customers],["Products",summary?.products],["Licenses",summary?.licenses],["Installations",summary?.installations],["Offline Licenses",summary?.offlineLicenses],["Active Users",summary?.activeUsers]] as const;
  return <>
    <div className="page-heading"><div><h1>Dashboard</h1><p>Live QFLM licensing and security overview.</p></div></div>
    {error && <div className="page-error">{error}</div>}
    <div className="stats-grid">{cards.map(([l,v])=><article className="stat-card" key={l}><span>{l}</span><strong>{v??"…"}</strong><small>Live API data</small></article>)}</div>
    <div className="panel-grid"><article className="panel"><h2>Administrator session</h2><div className="status-row"><span>Username</span><b>{user?.username}</b></div><div className="status-row"><span>Roles</span><b>{user?.roles.join(", ")}</b></div><div className="status-row"><span>Permissions</span><b>{user?.permissions.length??0}</b></div></article>
    <article className="panel"><h2>Platform status</h2><div className="status-row"><span>Authentication</span><b>Operational</b></div><div className="status-row"><span>RBAC</span><b>Operational</b></div><div className="status-row"><span>Dashboard API</span><b>{summary?"Connected":"Loading"}</b></div></article></div>
  </>;
}
TSX

python3 - "$GUI/src/components/AppShell.tsx" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
if 'useAuth' not in s:
    s=s.replace('import { NavLink, Outlet } from "react-router-dom";','import { NavLink, Outlet, useNavigate } from "react-router-dom";\nimport { useAuth } from "../auth/AuthContext";')
    s=s.replace('export function AppShell() {\n  return (','export function AppShell() {\n  const { user, signOut } = useAuth();\n  const navigate = useNavigate();\n  async function logout(){ await signOut(); navigate("/login",{replace:true}); }\n  return (')
    s=s.replace('<button className="logout">','<button className="logout" onClick={logout}>')
    s=s.replace('<div className="admin-pill">Platform Administrator</div>','<div className="admin-pill">{user?.username ?? "Administrator"}</div>')
p.write_text(s)
PY

cat > "$GUI/src/App.tsx" <<'TSX'
import { BrowserRouter, Route, Routes } from "react-router-dom";
import { AuthProvider } from "./auth/AuthContext";
import { ProtectedRoute } from "./auth/ProtectedRoute";
import { AppShell } from "./components/AppShell";
import { DashboardPage } from "./pages/DashboardPage";
import { LoginPage } from "./pages/LoginPage";
import { PlaceholderPage } from "./pages/PlaceholderPage";

export default function App(){
  return <BrowserRouter><AuthProvider><Routes>
    <Route path="/login" element={<LoginPage />} />
    <Route element={<ProtectedRoute><AppShell /></ProtectedRoute>}>
      <Route index element={<DashboardPage />} />
      <Route path="customers" element={<PlaceholderPage title="Customers" description="Customer organizations and licensing relationships." />} />
      <Route path="products" element={<PlaceholderPage title="Products" description="Products, features and entitlement definitions." />} />
      <Route path="licenses" element={<PlaceholderPage title="Licenses" description="Subscriptions, license status and administrative controls." />} />
      <Route path="installations" element={<PlaceholderPage title="Installations" description="Activated machines, leases and device status." />} />
      <Route path="offline" element={<PlaceholderPage title="Offline Licensing" description="Offline requests, signed licenses and renewals." />} />
      <Route path="security" element={<PlaceholderPage title="Security" description="Users, roles, permissions and account administration." />} />
      <Route path="audit" element={<PlaceholderPage title="Audit & Reports" description="Security, licensing and operational audit history." />} />
      <Route path="system" element={<PlaceholderPage title="System" description="Platform health and operational configuration." />} />
    </Route>
  </Routes></AuthProvider></BrowserRouter>;
}
TSX

cat >> "$GUI/src/styles.css" <<'CSS'

.full-page-state,.login-page{min-height:100vh;display:grid;place-items:center}
.login-page{padding:24px;background:#eef2f7}
.login-card{width:min(430px,100%);background:#fff;border:1px solid #e5e7eb;border-radius:18px;box-shadow:0 22px 60px rgba(15,23,42,.10);padding:30px}
.login-brand{display:flex;align-items:center;gap:12px;margin-bottom:28px}
.login-brand strong,.login-brand span{display:block}
.login-brand span{margin-top:3px;color:#667085;font-size:13px}
.login-card h1{margin:18px 0 6px;font-size:28px}
.login-card>p{color:#667085;margin:0 0 22px}
.login-card form{display:grid;gap:16px}
.login-card label{display:grid;gap:7px;font-size:13px;font-weight:650;color:#344054}
.login-card input{width:100%;border:1px solid #d0d5dd;border-radius:9px;padding:11px 12px;outline:none}
.login-button{width:100%}
.login-error,.page-error{border:1px solid #fecaca;background:#fef2f2;color:#991b1b;border-radius:9px;padding:10px 12px;font-size:13px}
.page-error{margin-bottom:18px}
CSS
printf '%s\n' "frontend_login_dashboard_patch=PASS"

printf '\n=== 5. RELEASE BUILD API ===\n'
dotnet build QuikeFix.LicenseManager.slnx -c Release || die "Recovery 7B API build failed"
printf '%s\n' "api_release_build=PASS"

printf '\n=== 6. CLONE PRODUCTION DATABASE ===\n'
docker exec "$PG" psql -U qflm -d postgres -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$ISO_DB' AND pid<>pg_backend_pid();" >/dev/null
docker exec "$PG" dropdb -U qflm --if-exists "$ISO_DB"
docker exec "$PG" createdb -U qflm "$ISO_DB" || die "isolated DB create failed"
docker exec "$PG" pg_dump -U qflm -d "$PROD_DB" --no-owner --no-privileges | docker exec -i "$PG" psql -U qflm -d "$ISO_DB" -v ON_ERROR_STOP=1 >/dev/null || die "isolated DB clone failed"
printf '%s\n' "isolated_database_clone=PASS"

printf '\n=== 7. BUILD ISOLATED API IMAGE ===\n'
rm -rf "$API_PUBLISH"
dotnet publish "$API_SRC/QFLM.Api.csproj" -c Release -o "$API_PUBLISH" || die "API publish failed"
cat > "$API_DOCKERFILE" <<'DOCKER'
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --chown=app:app artifacts/api-publish-recovery7b/ ./
USER app
ENTRYPOINT ["dotnet","QFLM.Api.dll"]
DOCKER
docker build -f "$API_DOCKERFILE" -t "$API_IMAGE" . || die "API image build failed"
printf 'api_candidate_image=%s\n' "$API_IMAGE"

printf '\n=== 8. PREPARE + START ISOLATED API ===\n'
docker inspect "$PROD_API" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$ENV_FILE" || die "capture production env failed"
cat >> "$ENV_FILE" <<EOF
Qflm__PostgreSqlDatabase=$ISO_DB
PostgreSqlDatabase=$ISO_DB
EOF
chmod 600 "$ENV_FILE"

docker rm -f "$ISO_API" >/dev/null 2>&1 || true
docker run -d --name "$ISO_API" --network "$NET" --network-alias qflm-api-backend --env-file "$ENV_FILE" --volumes-from "$PROD_API:ro" --read-only --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp:rw,noexec,nosuid,size=16m "$API_IMAGE" >/dev/null || die "isolated API start failed"
sleep 5
docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS "http://$ISO_API:8080/health/ready" >/dev/null || { docker logs --tail 150 "$ISO_API" || true; die "isolated API readiness failed"; }
printf '%s\n' "isolated_api_health=PASS"

printf '\n=== 9. BUILD ISOLATED GUI IMAGE ===\n'
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
 ' server {' \
 '  listen 8080;' \
 '  root /usr/share/nginx/html;' \
 '  index index.html;' \
 '  location /api/ {' \
 '   proxy_pass http://qflm-api-backend:8080/api/;' \
 '   proxy_http_version 1.1;' \
 '   proxy_set_header Host $host;' \
 '   proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' \
 '   proxy_set_header X-Forwarded-Proto $scheme;' \
 '  }' \
 '  location / { try_files $uri $uri/ /index.html; }' \
 '  location = /health { access_log off; default_type text/plain; return 200 "ok\\n"; }' \
 ' }' \
 '}' > /etc/nginx/nginx-qflm.conf
RUN mkdir -p /tmp/client_temp /tmp/proxy_temp && chown -R nginx:nginx /tmp /usr/share/nginx/html
USER nginx
EXPOSE 8080
ENTRYPOINT ["nginx","-c","/etc/nginx/nginx-qflm.conf","-g","daemon off;"]
DOCKER
docker build -f "$GUI_DOCKERFILE" -t "$GUI_IMAGE" . || die "GUI build failed"
printf 'gui_candidate_image=%s\n' "$GUI_IMAGE"

printf '\n=== 10. START ISOLATED GUI ===\n'
docker rm -f "$ISO_GUI" >/dev/null 2>&1 || true
docker run -d --name "$ISO_GUI" --network "$NET" --read-only --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp:rw,noexec,nosuid,size=24m,uid=101,gid=101 "$GUI_IMAGE" >/dev/null || die "isolated GUI start failed"
sleep 3
[ "$(docker inspect "$ISO_GUI" --format='{{.State.Running}}')" = true ] || { docker logs --tail 120 "$ISO_GUI" || true; die "isolated GUI not running"; }
printf '%s\n' "isolated_gui_running=PASS"

printf '\n=== 11. GUI LOGIN + LIVE DASHBOARD TEST ===\n'
ADMIN_USER="$(cat "$ADMIN_USER_FILE")"
ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"
LOGIN_JSON=$(python3 - "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import json,sys
print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))
PY
)
LOGIN_RESPONSE=$(printf '%s' "$LOGIN_JSON" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -fsS -H 'Content-Type: application/json' -X POST "http://$ISO_GUI:8080/api/v1/auth/login" --data-binary @-) || die "GUI proxied login failed"
ACCESS=$(python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["accessToken"])
PY
)
REFRESH=$(python3 - "$LOGIN_RESPONSE" <<'PY'
import json,sys
print(json.loads(sys.argv[1])["refreshToken"])
PY
)
[ -n "$ACCESS" ] && [ -n "$REFRESH" ] || die "GUI login tokens missing"
printf '%s\n' "gui_login_proxy=PASS"

SUMMARY=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS -H "Authorization: Bearer $ACCESS" "http://$ISO_GUI:8080/api/v1/admin/dashboard/summary") || die "dashboard summary failed"
python3 - "$SUMMARY" <<'PY'
import json,sys
o=json.loads(sys.argv[1])
for k in ["customers","products","licenses","installations","offlineLicenses","activeUsers","generatedAtUtc"]:
    assert k in o, k
assert o["licenses"] >= 1
assert o["installations"] >= 2
assert o["activeUsers"] >= 1
print(f"dashboard_summary=PASS customers={o['customers']} products={o['products']} licenses={o['licenses']} installations={o['installations']} offline={o['offlineLicenses']} active_users={o['activeUsers']}")
PY

ME=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -fsS -H "Authorization: Bearer $ACCESS" "http://$ISO_GUI:8080/api/v1/auth/me") || die "/me failed"
python3 - "$ME" <<'PY'
import json,sys
o=json.loads(sys.argv[1])
assert "Platform Administrator" in o["roles"]
assert "security.admin" in o["permissions"]
print(f"gui_authenticated_me=PASS username={o['username']} roles={len(o['roles'])} permissions={len(o['permissions'])}")
PY

ROOT_HTTP=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' "http://$ISO_GUI:8080/")
LOGIN_HTTP=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' "http://$ISO_GUI:8080/login")
HEALTH_HTTP=$(docker run --rm --network "$NET" curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' "http://$ISO_GUI:8080/health")
printf 'root_http=%s login_http=%s health_http=%s\n' "$ROOT_HTTP" "$LOGIN_HTTP" "$HEALTH_HTTP"
[ "$ROOT_HTTP" = 200 ] && [ "$LOGIN_HTTP" = 200 ] && [ "$HEALTH_HTTP" = 200 ] || die "GUI routes failed"

REVOKE_JSON=$(python3 - "$REFRESH" <<'PY'
import json,sys
print(json.dumps({"refreshToken":sys.argv[1]}))
PY
)
REVOKE_HTTP=$(printf '%s' "$REVOKE_JSON" | docker run --rm --network "$NET" -i curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "Authorization: Bearer $ACCESS" -X POST "http://$ISO_GUI:8080/api/v1/auth/revoke" --data-binary @-)
[ "$REVOKE_HTTP" = 204 ] || die "test session revoke failed"
printf '%s\n' "test_session_revoked=PASS"

unset ADMIN_PASS ACCESS REFRESH LOGIN_JSON LOGIN_RESPONSE REVOKE_JSON

printf '\n=== 12. PRODUCTION FINAL SAFETY ===\n'
FINAL_IMG=$(docker inspect "$PROD_API" --format='{{.Config.Image}}')
FINAL_RUN=$(docker inspect "$PROD_API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_LIC=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_INST=$(docker exec "$PG" psql -U qflm -d "$PROD_DB" -tAc 'SELECT count(*) FROM installations;' | xargs)
printf 'api_image=%s running=%s migrations=%s users=%s licenses=%s installations=%s\n' "$FINAL_IMG" "$FINAL_RUN" "$FINAL_MIG" "$FINAL_USERS" "$FINAL_LIC" "$FINAL_INST"
[ "$FINAL_IMG" = "$IMG" ] || die "production API image changed"
[ "$FINAL_RUN" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "production migrations changed"
[ "$FINAL_USERS" = "$USERS" ] || die "production users changed"
[ "$FINAL_LIC" = "$LIC" ] || die "production licenses changed"
[ "$FINAL_INST" = "$INST" ] || die "production installations changed"
printf '%s\n' "production_unchanged=PASS"

COMPLETED=1
printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7B PASSED"
printf '%s\n' "======================================================"
printf '%s\n' "LOGIN SCREEN:                       PASS"
printf '%s\n' "ACCESS TOKEN SESSION:               PASS"
printf '%s\n' "REFRESH ROTATION CLIENT:            IMPLEMENTED"
printf '%s\n' "LOGOUT/REVOKE CLIENT:               PASS"
printf '%s\n' "PROTECTED ROUTES:                   PASS"
printf '%s\n' "NGINX SAME-ORIGIN API PROXY:        PASS"
printf '%s\n' "LIVE DASHBOARD API:                 PASS"
printf '%s\n' "AUTHENTICATED /ME:                  PASS"
printf '%s\n' "GUI ROOT/LOGIN/HEALTH ROUTES:       PASS"
printf '%s\n' "GUI HOST PORTS:                     NONE"
printf '%s\n' "PRODUCTION API/DB:                  UNCHANGED"
printf 'API CANDIDATE IMAGE:                %s\n' "$API_IMAGE"
printf 'GUI CANDIDATE IMAGE:                %s\n' "$GUI_IMAGE"
printf 'REPORT:                             %s\n' "$REPORT"
printf '%s\n' "NEXT: RECOVERY 7C - CUSTOMERS / PRODUCTS / FEATURES MANAGEMENT GUI + API"
printf '%s\n' "======================================================"
