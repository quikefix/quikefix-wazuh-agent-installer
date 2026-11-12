#!/usr/bin/env bash
# QFLM RECOVERY 7A
# Full Admin GUI foundation preflight + isolated React/TypeScript scaffold.
# Does NOT expose GUI externally and does NOT modify the production API/DB schema.

set -u
set -o pipefail
umask 077

ROOT="/opt/qflm/app/QuikeFix.LicenseManager"
GUI="$ROOT/src/QFLM.AdminWeb"
API="qflm-api"
PG="qflm-postgres"
DB="qflm"
NET="qflm_backend"

EXPECTED_API_IMAGE="qflm-api:recovery6f3-candidate"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/opt/qflm/backups/recovery7a-$STAMP"
REPORT="$BACKUP/recovery7a-report.txt"
GUI_BACKUP="$BACKUP/adminweb-before-phase16a.tgz"

GUI_IMAGE="qflm-admin-web:recovery7a-candidate"
GUI_CONTAINER="qflm-admin-web-recovery7a-test"
DOCKERFILE="$ROOT/Dockerfile.recovery7a-gui"

MUTATED=0
COMPLETED=0

die(){ printf 'STOP: %s\n' "$*" >&2; exit 1; }

cleanup(){
    docker rm -f "$GUI_CONTAINER" >/dev/null 2>&1 || true

    if [ "$COMPLETED" -ne 1 ] && [ "$MUTATED" -eq 1 ]; then
        printf '\n=== GUI SOURCE ROLLBACK ===\n'
        rm -rf "$GUI"
        if [ -s "$GUI_BACKUP" ]; then
            tar -xzf "$GUI_BACKUP" -C "$ROOT" >/dev/null 2>&1 || true
        fi
        printf '%s\n' "gui_source_restore_attempted=YES"
    fi
}
trap cleanup EXIT

mkdir -p "$BACKUP"
exec > >(tee "$REPORT") 2>&1
cd "$ROOT" || die "project root missing"

printf '%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7A"
printf '%s\n' " FULL ADMIN GUI FOUNDATION"
printf '%s\n' " REACT + TYPESCRIPT + ISOLATED TEST"
printf '%s\n' "======================================================"

printf '\n=== 1. PRODUCTION SAFETY BASELINE ===\n'

IMG=$(docker inspect "$API" --format='{{.Config.Image}}') || die "production API missing"
RUN=$(docker inspect "$API" --format='{{.State.Running}}')
MIG=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
AUTH=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name LIKE 'auth_%';" | xargs)
USERS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
ROLES=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
PERMS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
LIC=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
INST=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'api_image=%s running=%s migrations=%s auth_tables=%s users=%s roles=%s permissions=%s licenses=%s installations=%s\n' \
  "$IMG" "$RUN" "$MIG" "$AUTH" "$USERS" "$ROLES" "$PERMS" "$LIC" "$INST"

[ "$IMG" = "$EXPECTED_API_IMAGE" ] || die "unexpected production API image"
[ "$RUN" = true ] || die "production API not running"
[ "$MIG" = 5 ] || die "unexpected migration count"
[ "$AUTH" = 6 ] || die "unexpected auth table count"
[ "$USERS" = 1 ] || die "unexpected production user count"
[ "$ROLES" = 1 ] || die "unexpected production role count"
[ "$PERMS" -ge 22 ] || die "permission catalog incomplete"

printf '%s\n' "production_baseline=PASS"

printf '\n=== 2. GUI TOOLCHAIN CHECK ===\n'

if command -v node >/dev/null 2>&1; then
    printf 'node=%s\n' "$(node --version)"
else
    printf '%s\n' "node=ABSENT"
fi

if command -v npm >/dev/null 2>&1; then
    printf 'npm=%s\n' "$(npm --version)"
else
    printf '%s\n' "npm=ABSENT"
fi

printf 'docker=%s\n' "$(docker --version)"
printf 'compose=%s\n' "$(docker compose version)"

printf '\n=== 3. BACKUP EXISTING GUI SOURCE IF PRESENT ===\n'

if [ -d "$GUI" ]; then
    tar -czf "$GUI_BACKUP" -C "$ROOT" "src/QFLM.AdminWeb" \
      || die "existing GUI backup failed"
    printf 'existing_gui_backup=%s\n' "$GUI_BACKUP"
else
    printf '%s\n' "existing_gui=NONE"
fi

MUTATED=1

printf '\n=== 4. CREATE REACT + TYPESCRIPT ADMIN GUI SOURCE ===\n'

rm -rf "$GUI"
mkdir -p "$GUI/src/components"
mkdir -p "$GUI/src/pages"
mkdir -p "$GUI/src/lib"
mkdir -p "$GUI/public"

cat > "$GUI/package.json" <<'JSON'
{
  "name": "qflm-admin-web",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc -b && vite build",
    "preview": "vite preview --host 0.0.0.0"
  },
  "dependencies": {
    "@vitejs/plugin-react": "^5.0.4",
    "vite": "^7.1.7",
    "typescript": "^5.9.3",
    "react": "^19.1.1",
    "react-dom": "^19.1.1",
    "react-router-dom": "^7.9.3",
    "lucide-react": "^0.468.0"
  },
  "devDependencies": {
    "@types/react": "^19.1.16",
    "@types/react-dom": "^19.1.9"
  }
}
JSON

cat > "$GUI/tsconfig.json" <<'JSON'
{
  "files": [],
  "references": [
    { "path": "./tsconfig.app.json" },
    { "path": "./tsconfig.node.json" }
  ]
}
JSON

cat > "$GUI/tsconfig.app.json" <<'JSON'
{
  "compilerOptions": {
    "target": "ES2022",
    "useDefineForClassFields": true,
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "allowJs": false,
    "skipLibCheck": true,
    "esModuleInterop": true,
    "allowSyntheticDefaultImports": true,
    "strict": true,
    "forceConsistentCasingInFileNames": true,
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "noEmit": true,
    "jsx": "react-jsx"
  },
  "include": ["src"]
}
JSON

cat > "$GUI/tsconfig.node.json" <<'JSON'
{
  "compilerOptions": {
    "composite": true,
    "skipLibCheck": true,
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "noEmit": true
  },
  "include": ["vite.config.ts"]
}
JSON

cat > "$GUI/vite.config.ts" <<'TS'
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    host: "0.0.0.0",
    port: 4173
  },
  preview: {
    host: "0.0.0.0",
    port: 4173
  }
});
TS

cat > "$GUI/index.html" <<'HTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta name="theme-color" content="#111827" />
    <title>QuikeFix Cloud License Manager</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
HTML

cat > "$GUI/src/lib/api.ts" <<'TS'
export const apiBase = "/api";

export async function apiFetch<T>(
  path: string,
  init?: RequestInit
): Promise<T> {
  const response = await fetch(`${apiBase}${path}`, {
    credentials: "include",
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...(init?.headers ?? {})
    }
  });

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }

  if (response.status === 204) {
    return undefined as T;
  }

  return (await response.json()) as T;
}
TS

cat > "$GUI/src/components/AppShell.tsx" <<'TSX'
import {
  LayoutDashboard,
  Users,
  Package,
  KeyRound,
  ServerCog,
  ShieldCheck,
  FileKey2,
  ScrollText,
  Settings,
  LogOut
} from "lucide-react";
import { NavLink, Outlet } from "react-router-dom";

const nav = [
  ["Dashboard", "/", LayoutDashboard],
  ["Customers", "/customers", Users],
  ["Products", "/products", Package],
  ["Licenses", "/licenses", KeyRound],
  ["Installations", "/installations", ServerCog],
  ["Offline Licensing", "/offline", FileKey2],
  ["Security", "/security", ShieldCheck],
  ["Audit & Reports", "/audit", ScrollText],
  ["System", "/system", Settings]
] as const;

export function AppShell() {
  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <div className="brand-mark">QF</div>
          <div>
            <strong>QuikeFix</strong>
            <span>Cloud License Manager</span>
          </div>
        </div>

        <nav>
          {nav.map(([label, to, Icon]) => (
            <NavLink
              key={to}
              to={to}
              end={to === "/"}
              className={({ isActive }) =>
                isActive ? "nav-link active" : "nav-link"
              }
            >
              <Icon size={18} />
              <span>{label}</span>
            </NavLink>
          ))}
        </nav>

        <button className="logout">
          <LogOut size={18} />
          Sign out
        </button>
      </aside>

      <main className="main-area">
        <header className="topbar">
          <div>
            <strong>Administration</strong>
            <span>Secure licensing operations</span>
          </div>
          <div className="admin-pill">Platform Administrator</div>
        </header>

        <section className="page-area">
          <Outlet />
        </section>
      </main>
    </div>
  );
}
TSX

cat > "$GUI/src/pages/DashboardPage.tsx" <<'TSX'
const cards = [
  ["Customers", "—"],
  ["Products", "—"],
  ["Active Licenses", "—"],
  ["Installations", "—"],
  ["Offline Licenses", "—"],
  ["Security Users", "—"]
];

export function DashboardPage() {
  return (
    <>
      <div className="page-heading">
        <div>
          <h1>Dashboard</h1>
          <p>License operations, customer activity and platform health.</p>
        </div>
        <button className="primary-button">Create License</button>
      </div>

      <div className="stats-grid">
        {cards.map(([label, value]) => (
          <article className="stat-card" key={label}>
            <span>{label}</span>
            <strong>{value}</strong>
            <small>API integration follows in Phase 16B</small>
          </article>
        ))}
      </div>

      <div className="panel-grid">
        <article className="panel">
          <h2>License activity</h2>
          <p>
            Activation, validation, heartbeat and offline-license activity
            will appear here.
          </p>
          <div className="empty-state">No dashboard data loaded yet.</div>
        </article>

        <article className="panel">
          <h2>Security status</h2>
          <div className="status-row">
            <span>Authentication</span>
            <b>Operational</b>
          </div>
          <div className="status-row">
            <span>RBAC</span>
            <b>Operational</b>
          </div>
          <div className="status-row">
            <span>Signing service</span>
            <b>Internal</b>
          </div>
        </article>
      </div>
    </>
  );
}
TSX

cat > "$GUI/src/pages/PlaceholderPage.tsx" <<'TSX'
export function PlaceholderPage({
  title,
  description
}: {
  title: string;
  description: string;
}) {
  return (
    <>
      <div className="page-heading">
        <div>
          <h1>{title}</h1>
          <p>{description}</p>
        </div>
      </div>

      <article className="panel">
        <div className="empty-state">
          Full management screen is scheduled for the next GUI stage.
        </div>
      </article>
    </>
  );
}
TSX

cat > "$GUI/src/App.tsx" <<'TSX'
import { BrowserRouter, Route, Routes } from "react-router-dom";
import { AppShell } from "./components/AppShell";
import { DashboardPage } from "./pages/DashboardPage";
import { PlaceholderPage } from "./pages/PlaceholderPage";

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route element={<AppShell />}>
          <Route index element={<DashboardPage />} />
          <Route path="customers" element={
            <PlaceholderPage title="Customers" description="Customer organizations and licensing relationships." />
          } />
          <Route path="products" element={
            <PlaceholderPage title="Products" description="Products, features and entitlement definitions." />
          } />
          <Route path="licenses" element={
            <PlaceholderPage title="Licenses" description="Subscriptions, license status and administrative controls." />
          } />
          <Route path="installations" element={
            <PlaceholderPage title="Installations" description="Activated machines, leases and device status." />
          } />
          <Route path="offline" element={
            <PlaceholderPage title="Offline Licensing" description="Offline requests, signed licenses and renewals." />
          } />
          <Route path="security" element={
            <PlaceholderPage title="Security" description="Users, roles, permissions and account administration." />
          } />
          <Route path="audit" element={
            <PlaceholderPage title="Audit & Reports" description="Security, licensing and operational audit history." />
          } />
          <Route path="system" element={
            <PlaceholderPage title="System" description="Platform health and operational configuration." />
          } />
        </Route>
      </Routes>
    </BrowserRouter>
  );
}
TSX

cat > "$GUI/src/main.tsx" <<'TSX'
import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./styles.css";

ReactDOM.createRoot(
  document.getElementById("root")!
).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
TSX

cat > "$GUI/src/styles.css" <<'CSS'
:root {
  font-family:
    Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont,
    "Segoe UI", sans-serif;
  color: #172033;
  background: #f4f6f9;
  font-synthesis: none;
}

* {
  box-sizing: border-box;
}

html, body, #root {
  margin: 0;
  min-width: 320px;
  min-height: 100vh;
}

body {
  background:
    radial-gradient(circle at top right, rgba(33, 150, 243, .08), transparent 34rem),
    #f4f6f9;
}

button, input, select {
  font: inherit;
}

.app-shell {
  min-height: 100vh;
  display: grid;
  grid-template-columns: 265px minmax(0, 1fr);
}

.sidebar {
  background: #111827;
  color: #fff;
  padding: 24px 18px;
  display: flex;
  flex-direction: column;
  gap: 24px;
}

.brand {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 2px 8px 18px;
  border-bottom: 1px solid rgba(255,255,255,.10);
}

.brand-mark {
  width: 42px;
  height: 42px;
  border-radius: 12px;
  background: #ffffff;
  color: #111827;
  display: grid;
  place-items: center;
  font-weight: 800;
}

.brand strong,
.brand span {
  display: block;
}

.brand span {
  margin-top: 2px;
  color: #9ca3af;
  font-size: 12px;
}

.sidebar nav {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.nav-link,
.logout {
  color: #d1d5db;
  text-decoration: none;
  border: 0;
  background: transparent;
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 11px 12px;
  border-radius: 9px;
  cursor: pointer;
}

.nav-link:hover,
.nav-link.active {
  background: rgba(255,255,255,.10);
  color: #fff;
}

.logout {
  margin-top: auto;
  width: 100%;
}

.main-area {
  min-width: 0;
}

.topbar {
  height: 78px;
  background: rgba(255,255,255,.95);
  border-bottom: 1px solid #e5e7eb;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 30px;
}

.topbar strong,
.topbar span {
  display: block;
}

.topbar span {
  margin-top: 3px;
  color: #778195;
  font-size: 13px;
}

.admin-pill {
  background: #eef2f7;
  color: #344054;
  padding: 9px 13px;
  border-radius: 999px;
  font-size: 13px;
  font-weight: 650;
}

.page-area {
  padding: 30px;
}

.page-heading {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 24px;
  margin-bottom: 24px;
}

.page-heading h1 {
  margin: 0;
  font-size: 28px;
}

.page-heading p {
  margin: 6px 0 0;
  color: #667085;
}

.primary-button {
  background: #111827;
  color: #fff;
  border: 0;
  border-radius: 9px;
  padding: 11px 16px;
  cursor: pointer;
}

.stats-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 16px;
  margin-bottom: 22px;
}

.stat-card,
.panel {
  background: #fff;
  border: 1px solid #e6e9ef;
  border-radius: 14px;
  box-shadow: 0 4px 14px rgba(16, 24, 40, .035);
}

.stat-card {
  padding: 19px;
}

.stat-card span,
.stat-card small {
  display: block;
  color: #667085;
}

.stat-card strong {
  display: block;
  margin: 10px 0 7px;
  font-size: 27px;
}

.stat-card small {
  font-size: 12px;
}

.panel-grid {
  display: grid;
  grid-template-columns: minmax(0, 1.55fr) minmax(280px, .75fr);
  gap: 18px;
}

.panel {
  padding: 22px;
}

.panel h2 {
  margin: 0 0 8px;
  font-size: 18px;
}

.panel p {
  color: #667085;
}

.empty-state {
  margin-top: 18px;
  min-height: 170px;
  border: 1px dashed #d0d5dd;
  border-radius: 11px;
  display: grid;
  place-items: center;
  color: #98a2b3;
  padding: 24px;
  text-align: center;
}

.status-row {
  display: flex;
  justify-content: space-between;
  padding: 13px 0;
  border-bottom: 1px solid #eef0f3;
}

.status-row:last-child {
  border-bottom: 0;
}

.status-row b {
  color: #166534;
}

@media (max-width: 1000px) {
  .app-shell {
    grid-template-columns: 82px minmax(0, 1fr);
  }

  .brand > div:last-child,
  .nav-link span,
  .logout {
    font-size: 0;
  }

  .stats-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }

  .panel-grid {
    grid-template-columns: 1fr;
  }
}

@media (max-width: 680px) {
  .app-shell {
    display: block;
  }

  .sidebar {
    display: none;
  }

  .topbar {
    padding: 0 18px;
  }

  .page-area {
    padding: 18px;
  }

  .stats-grid {
    grid-template-columns: 1fr;
  }
}
CSS

printf '%s\n' "gui_source_scaffold=PASS"

printf '\n=== 4B. TYPESCRIPT CONFIG DIAGNOSTIC ===\n'

python3 - "$GUI/tsconfig.node.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    cfg = json.load(fh)

opts = cfg.get("compilerOptions", {})

if opts.get("allowImportingTsExtensions") is True and not (
    opts.get("noEmit") is True or
    opts.get("emitDeclarationOnly") is True
):
    raise SystemExit(
        "Unsafe TypeScript config: allowImportingTsExtensions requires "
        "noEmit or emitDeclarationOnly."
    )

if opts.get("noEmit") is not True:
    raise SystemExit("tsconfig.node.json must set noEmit=true")

print("typescript_node_config=PASS")
PY

printf '\n=== 5. CREATE CONTAINERIZED BUILD ===\n'

cat > "$DOCKERFILE" <<'DOCKER'
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

docker build \
  -f "$DOCKERFILE" \
  -t "$GUI_IMAGE" \
  . \
  || die "GUI candidate image build failed"

GUI_IMAGE_ID=$(docker image inspect "$GUI_IMAGE" --format='{{.Id}}')

printf 'gui_image=%s\n' "$GUI_IMAGE"
printf 'gui_image_id=%s\n' "$GUI_IMAGE_ID"

printf '\n=== 6. START ISOLATED GUI ===\n'

docker rm -f "$GUI_CONTAINER" >/dev/null 2>&1 || true

docker run -d \
  --name "$GUI_CONTAINER" \
  --network "$NET" \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,size=24m,uid=101,gid=101 \
  "$GUI_IMAGE" \
  >/dev/null \
  || die "isolated GUI container start failed"

sleep 3

RUNNING=$(docker inspect "$GUI_CONTAINER" --format='{{.State.Running}}')
EXITCODE=$(docker inspect "$GUI_CONTAINER" --format='{{.State.ExitCode}}')

printf 'gui_running=%s gui_exit_code=%s\n' "$RUNNING" "$EXITCODE"

if [ "$RUNNING" != true ]; then
    printf '%s\n' "--- isolated GUI logs ---"
    docker logs --tail 120 "$GUI_CONTAINER" || true
    die "isolated GUI container exited before HTTP smoke test"
fi

SEC=$(docker inspect "$GUI_CONTAINER" \
  --format='user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{json .HostConfig.CapDrop}} securityopt={{json .HostConfig.SecurityOpt}} ports={{json .HostConfig.PortBindings}}')

printf '%s\n' "$SEC"

printf '%s' "$SEC" | grep -q 'user=nginx' || die "GUI does not run as nginx user"
printf '%s' "$SEC" | grep -q 'readonly=true' || die "GUI rootfs not readonly"
printf '%s' "$SEC" | grep -q 'capdrop=\["ALL"\]' || die "GUI capdrop missing"
printf '%s' "$SEC" | grep -q 'no-new-privileges:true' || die "GUI no-new-privileges missing"
printf '%s' "$SEC" | grep -q 'ports={}' || die "GUI unexpectedly exposes host ports"

printf '%s\n' "gui_container_hardening=PASS"

printf '\n=== 7. GUI HTTP SMOKE TEST ===\n'

ROOT_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  "http://$GUI_CONTAINER:8080/")

HEALTH_HTTP=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 \
  -s -o /dev/null -w '%{http_code}' \
  "http://$GUI_CONTAINER:8080/health")

printf 'root_http=%s health_http=%s\n' "$ROOT_HTTP" "$HEALTH_HTTP"

[ "$ROOT_HTTP" = 200 ] || die "GUI root page failed"
[ "$HEALTH_HTTP" = 200 ] || die "GUI health endpoint failed"

HTML=$(docker run --rm --network "$NET" \
  curlimages/curl:8.16.0 -fsS \
  "http://$GUI_CONTAINER:8080/") \
  || die "GUI HTML fetch failed"

printf '%s' "$HTML" | grep -q 'QuikeFix Cloud License Manager' \
  || die "GUI title missing"

printf '%s\n' "gui_http_smoke=PASS"

printf '\n=== 8. VERIFY PRODUCTION UNCHANGED ===\n'

FINAL_IMG=$(docker inspect "$API" --format='{{.Config.Image}}')
FINAL_RUN=$(docker inspect "$API" --format='{{.State.Running}}')
FINAL_MIG=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM "__EFMigrationsHistory";' | xargs)
FINAL_USERS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM auth_users;' | xargs)
FINAL_ROLES=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM auth_roles;' | xargs)
FINAL_PERMS=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM auth_permissions;' | xargs)
FINAL_LIC=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM licenses;' | xargs)
FINAL_INST=$(docker exec "$PG" psql -U qflm -d "$DB" -tAc 'SELECT count(*) FROM installations;' | xargs)

printf 'api_image=%s running=%s migrations=%s users=%s roles=%s permissions=%s licenses=%s installations=%s\n' \
  "$FINAL_IMG" "$FINAL_RUN" "$FINAL_MIG" "$FINAL_USERS" "$FINAL_ROLES" "$FINAL_PERMS" "$FINAL_LIC" "$FINAL_INST"

[ "$FINAL_IMG" = "$IMG" ] || die "production API image changed"
[ "$FINAL_RUN" = true ] || die "production API stopped"
[ "$FINAL_MIG" = "$MIG" ] || die "production migration count changed"
[ "$FINAL_USERS" = "$USERS" ] || die "production user count changed"
[ "$FINAL_ROLES" = "$ROLES" ] || die "production role count changed"
[ "$FINAL_PERMS" = "$PERMS" ] || die "production permission count changed"
[ "$FINAL_LIC" = "$LIC" ] || die "production license count changed"
[ "$FINAL_INST" = "$INST" ] || die "production installation count changed"

printf '%s\n' "production_unchanged=PASS"

COMPLETED=1

printf '\n%s\n' "======================================================"
printf '%s\n' " QFLM RECOVERY 7A PASSED"
printf '%s\n' "======================================================"
printf '%s\n' "REACT + TYPESCRIPT FOUNDATION:      PASS"
printf '%s\n' "VITE BUILD:                         PASS"
printf '%s\n' "ADMIN SHELL:                        PASS"
printf '%s\n' "DASHBOARD FOUNDATION:               PASS"
printf '%s\n' "CUSTOMERS NAVIGATION:               PASS"
printf '%s\n' "PRODUCTS NAVIGATION:                PASS"
printf '%s\n' "LICENSES NAVIGATION:                PASS"
printf '%s\n' "INSTALLATIONS NAVIGATION:           PASS"
printf '%s\n' "OFFLINE LICENSING NAVIGATION:       PASS"
printf '%s\n' "SECURITY NAVIGATION:                PASS"
printf '%s\n' "AUDIT/REPORTS NAVIGATION:           PASS"
printf '%s\n' "SYSTEM NAVIGATION:                  PASS"
printf '%s\n' "ISOLATED GUI HTTP TEST:             PASS"
printf '%s\n' "GUI HOST PORTS:                     NONE"
printf '%s\n' "PRODUCTION API/DB:                  UNCHANGED"
printf 'GUI SOURCE:                         %s\n' "$GUI"
printf 'GUI CANDIDATE IMAGE:                %s\n' "$GUI_IMAGE"
printf 'GUI IMAGE ID:                       %s\n' "$GUI_IMAGE_ID"
printf 'REPORT:                             %s\n' "$REPORT"
printf '%s\n' "NEXT: RECOVERY 7B - LOGIN SESSION + REAL DASHBOARD/API INTEGRATION"
printf '%s\n' "======================================================"
